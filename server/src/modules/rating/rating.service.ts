import { BadRequestException, ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource, EntityManager, QueryFailedError } from 'typeorm';

import { Order } from '../order/order.entity';
import {
  RATING_COMMENT_MAX,
  RATING_SCORE_MAX,
  RATING_SCORE_MIN,
} from '../worker/worker-grade.constants';
import { GradeProgress } from './worker-grade.rules';
import { RatingSummary, WorkerGradeService } from './worker-grade.service';

/** 五维评分入参（DTO 已按 1–10 整数校验；service 再兜一层，防"绕过管道"的内部调用） */
export interface RatingInput {
  skill: unknown;
  emotion: unknown;
  stress: unknown;
  voice: unknown;
  shop: unknown;
  comment?: unknown;
}

/** 重复评价（一单一评）—— 事务内查重与唯一键兜底**用的是同一句话** */
const DUPLICATE_MESSAGE = '该订单已评价过，不能重复评价';

/** 非本人订单（403；与"订单不存在"的 404 刻意分开，验收口径要求 403/400） */
const NOT_YOURS_MESSAGE = '只能评价自己的订单';

/** 未完成订单 */
const NOT_COMPLETED_MESSAGE = '订单完成后才能评价';

/**
 * 五维评分落库（`POST /user/orders/:id/rating`，负责人已审批 2026-10-17）
 *
 * ## 一个事务里做完四件事（缺一件都会出现"数据不一致"）
 *
 * 1. 锁订单行 → 校验**归属**（`order.user_id` = JWT `sub`）与**状态**（`completed`）；
 * 2. 事务内查重 `order_id`（**一单一评**）→ 插 `worker_rating`；
 * 3. **重算** `worker_rating_agg`（一条 `INSERT … SELECT AVG/COUNT … ON DUPLICATE KEY UPDATE`）；
 * 4. 调 `WorkerGradeService.evaluate()`（**同事务**，自动升级 + `operation_log` 一起提交）。
 *
 * ③④ 放在同一事务的理由：评分写进去了、均分或等级没跟上，老板端会立刻出现
 * 「我给了 10 分，打手主页还是旧均分」这种对不上的状态；而等级升级与它的审计若是两条连接，
 * 又会出现"升级了没留痕 / 留痕了没升级"。**一并成功、一并回滚**是这里唯一正确的语义。
 *
 * ## 归属铁律（docs/04）
 *
 * 主体 id **只从 JWT `sub` 取**（控制器 `@CurrentUser()`）；请求体里**没有** workerId 字段
 * （全局管道 `forbidNonWhitelisted` 会把多带的字段 400 掉），
 * `worker_rating.worker_id` 一律由 `order.worker_id` 快照而来 ——
 * 「给谁打分」在协议层面不可指定。
 *
 * ## 评价自愿
 *
 * 本服务只负责"评了就正确落库并计入"；**没有任何地方强制或催评**，
 * 只有一个表级唯一键（一单一评）与两处查重。没评的订单不产生任何行 ——
 * 聚合里不会出现"默认满分"这种填充，样本数 `< 10` 时按制度**不参与升级判定**。
 */
@Injectable()
export class RatingService {
  private readonly logger = new Logger('Rating');

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly grade: WorkerGradeService,
  ) {}

  /**
   * 提交五维评分
   *
   * @param userId 会话主体（JWT `sub`，role=user 的老板）—— **绝不来自请求体**
   * @param orderId 路径参数 `:id`
   */
  async submit(
    userId: string,
    orderId: string,
    dto: RatingInput,
  ): Promise<{
    ok: true;
    orderId: string;
    workerId: string;
    ratingId: string;
    agg: RatingSummary;
    grade: { before: number; after: number; upgraded: boolean; gradeLabel: string; gradeName: string };
    progress: GradeProgress;
  }> {
    const scores = this.normalizeScores(dto);
    const comment = this.normalizeComment(dto.comment);
    const id = String(orderId ?? '').trim();

    const created = await this.dataSource
      .transaction(async (em) => {
        /**
         * ① 锁订单行。
         *
         * 刻意**先按 id 取、再判归属**（而不是 `where: { id, userId }` 直接 404）：
         * 验收口径要求"非本人订单 → 403/400"，而 `where:{id,userId}` 只能给出统一的 404，
         * 无法区分"单不存在"与"不是你的单"。两句话都**不含订单内容**（只有一个结论），
         * 不泄漏订单号/金额/打手，因此不构成 docs/04 意义上的存在性预言机。
         */
        const order = await em.findOne(Order, {
          where: { id },
          lock: { mode: 'pessimistic_write' },
        });
        if (!order) throw new NotFoundException('订单不存在');
        if (String(order.userId) !== String(userId)) throw new ForbiddenException(NOT_YOURS_MESSAGE);
        if (order.status !== 'completed') throw new BadRequestException(NOT_COMPLETED_MESSAGE);

        // 打手档案：订单没有接单打手（历史脏数据）时不能评 —— 没有"给谁打分"这个对象
        const workerId = order.workerId == null ? '' : String(order.workerId);
        if (!workerId) throw new BadRequestException('该订单没有接单打手，不能评价');

        // ② 事务内查重（判定点；`UK_wrating_order` 是并发下的第二层兜底，见 catch）
        const dup = (await em.query('SELECT id FROM worker_rating WHERE order_id = ? LIMIT 1', [
          order.id,
        ])) as Array<{ id: string }>;
        if (dup.length) throw new BadRequestException(DUPLICATE_MESSAGE);

        const inserted = (await em.query(
          `INSERT INTO worker_rating
             (order_id, worker_id, r_skill, r_emotion, r_stress, r_voice, r_shop, r_comment, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW(3))`,
          [
            order.id,
            workerId,
            scores.skill,
            scores.emotion,
            scores.stress,
            scores.voice,
            scores.shop,
            comment,
          ],
        )) as { insertId?: number | string };

        // ③ 重算五维聚合（写入侧唯一实现）
        await this.recomputeAggInTx(em, workerId);

        // ④ 升级检查（**同事务**：等级变更与它的 operation_log 一起提交）
        const decision = await this.grade.evaluate(workerId, em);

        return {
          ratingId: String(inserted?.insertId ?? ''),
          orderId: String(order.id),
          workerId,
          decision,
        };
      })
      .catch((e: unknown) => {
        // 并发下第二个 INSERT 撞 `UK_wrating_order` → 中文 400（不是 500）
        if (e instanceof QueryFailedError && (e as unknown as { code?: string }).code === 'ER_DUP_ENTRY') {
          throw new BadRequestException(DUPLICATE_MESSAGE);
        }
        throw e;
      });

    // 事务外读一次"落库后的最终状态"（聚合与进度都由同一份数据算出，客户端无需再取一次）
    const detail = await this.grade.detail(created.workerId);
    this.logger.log(
      `五维评分 order=${created.orderId} worker=${created.workerId} ` +
        `skill=${scores.skill} emotion=${scores.emotion} stress=${scores.stress} voice=${scores.voice} shop=${scores.shop} ` +
        `grade=${created.decision.before}→${created.decision.after}${created.decision.upgraded ? '（自动升级）' : ''}`,
    );

    return {
      ok: true,
      orderId: created.orderId,
      workerId: created.workerId,
      ratingId: created.ratingId,
      agg: detail.rating,
      grade: {
        before: created.decision.before,
        after: created.decision.after,
        upgraded: created.decision.upgraded,
        gradeLabel: detail.gradeLabel,
        gradeName: detail.gradeName,
      },
      progress: detail.progress,
    };
  }

  /** 该订单的五维评分（客户端回显"已评价"；未评价返回 `null`，不是 404） */
  async mine(userId: string, orderId: string) {
    const id = String(orderId ?? '').trim();
    const order = await this.dataSource.getRepository(Order).findOne({ where: { id } });
    if (!order) throw new NotFoundException('订单不存在');
    if (String(order.userId) !== String(userId)) throw new ForbiddenException(NOT_YOURS_MESSAGE);
    const rows = (await this.dataSource.query(
      `SELECT id, r_skill AS skill, r_emotion AS emotion, r_stress AS stress,
              r_voice AS voice, r_shop AS shop, r_comment AS comment, created_at AS createdAt
         FROM worker_rating WHERE order_id = ? LIMIT 1`,
      [order.id],
    )) as Array<Record<string, unknown>>;
    const r = rows[0];
    if (!r) return null;
    return {
      ratingId: String(r.id),
      skill: Number(r.skill),
      emotion: Number(r.emotion),
      stress: Number(r.stress),
      voice: Number(r.voice),
      shop: Number(r.shop),
      comment: (r.comment as string | null) ?? null,
      createdAt: r.createdAt,
    };
  }

  /**
   * 重算五维聚合（**写入侧唯一实现**，必须传入调用方事务的 `EntityManager`）
   *
   * 一条语句幂等完成：`AVG` 五列 + `COUNT(*)` 按打手分组，`ON DUPLICATE KEY UPDATE` 覆盖。
   * 刻意不写"先 DELETE 再 INSERT"：那会留出一个"聚合行不存在"的窗口（并发读会看到 0 分）。
   * `ROUND(…, 2)` 与列定义 `decimal(4,2)` 对齐，避免隐式四舍五入与代码里的 `round2` 打架。
   */
  async recomputeAggInTx(em: EntityManager, workerId: string): Promise<void> {
    await em.query(
      `INSERT INTO worker_rating_agg
         (worker_id, skill, emotion, stress, voice, shop, sample_count, updated_at)
       SELECT worker_id,
              ROUND(AVG(r_skill), 2),
              ROUND(AVG(r_emotion), 2),
              ROUND(AVG(r_stress), 2),
              ROUND(AVG(r_voice), 2),
              ROUND(AVG(r_shop), 2),
              COUNT(*),
              NOW(3)
         FROM worker_rating
        WHERE worker_id = ?
        GROUP BY worker_id
       ON DUPLICATE KEY UPDATE
         skill = VALUES(skill),
         emotion = VALUES(emotion),
         stress = VALUES(stress),
         voice = VALUES(voice),
         shop = VALUES(shop),
         sample_count = VALUES(sample_count),
         updated_at = VALUES(updated_at)`,
      [workerId],
    );
  }

  /** 五维分数归一化：必须是 1–10 的整数（越界/小数/非数字 → 中文 400） */
  private normalizeScores(dto: RatingInput): {
    skill: number;
    emotion: number;
    stress: number;
    voice: number;
    shop: number;
  } {
    const pick = (raw: unknown): number => {
      const n = Number(raw);
      if (!Number.isInteger(n) || n < RATING_SCORE_MIN || n > RATING_SCORE_MAX) {
        throw new BadRequestException(`五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数`);
      }
      return n;
    };
    return {
      skill: pick(dto.skill),
      emotion: pick(dto.emotion),
      stress: pick(dto.stress),
      voice: pick(dto.voice),
      shop: pick(dto.shop),
    };
  }

  /** 评价正文：trim + 上限；空串按未填处理（与 `order_review.remark` 同一口径） */
  private normalizeComment(raw: unknown): string | null {
    const text = String(raw ?? '').trim();
    if (text.length > RATING_COMMENT_MAX) {
      throw new BadRequestException(`评价最多 ${RATING_COMMENT_MAX} 字`);
    }
    return text.length ? text : null;
  }
}
