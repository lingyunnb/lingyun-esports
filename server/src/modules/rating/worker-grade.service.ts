import { BadRequestException, ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource, EntityManager } from 'typeorm';

import { ReviewService } from '../review/review.service';
import {
  AUTO_MAX_GRADE,
  DEFAULT_WORKER_GRADE,
  RATING_DIMS,
  WORKER_GRADE_MAX,
  WORKER_GRADE_MIN,
  gradeLabel,
  gradeName,
} from '../worker/worker-grade.constants';
import {
  GradeMetrics,
  GradeProgress,
  GradeTierResult,
  buildGradeProgress,
  evaluateGradeTier,
  ratingAvgOf,
} from './worker-grade.rules';

/** 自动升级审计的操作者标识（`operation_log.admin_name`，`admin_id` 为 NULL 表示"没有具体人"） */
const SYSTEM_ACTOR_NAME = '系统自动判定';

/** `operation_log.module` 固定值（审批表指定） */
const LOG_MODULE = 'worker_grade';

/** 人工设置等级时的审计动作名 */
const ACTION_MANUAL = 'worker_grade:manual-set';

/** 自动判定升级时的审计动作名 */
const ACTION_AUTO = 'worker_grade:auto-upgrade';

/** 五维均分 + 样本数（对外形状；`avg` 是五列的均值，判级门槛比较的就是它） */
export interface RatingSummary {
  skill: number;
  emotion: number;
  stress: number;
  voice: number;
  shop: number;
  /** 五维均分（五列 AVG 的均值，两位小数） */
  avg: number;
  /** 样本数（< 10 不参与升级判定） */
  samples: number;
}

/** 等级详情（`GET /public/workers/:id` 与 `GET /worker/grade` **共用同一形状**） */
export interface WorkerGradeDetail {
  grade: number;
  gradeLabel: string;
  gradeName: string;
  rating: RatingSummary;
  progress: GradeProgress;
}

export interface GradeEvaluateResult {
  workerId: string;
  /** 判定前等级 */
  before: number;
  /** 判定后等级（**只升不降**：`max(before, 指标够到的档位)`） */
  after: number;
  upgraded: boolean;
  metrics: GradeMetrics;
  /** 逐档明细（2..4），审计/排查用 */
  tiers: GradeTierResult[];
  /** 最高达标档的命中指标（中文） */
  hits: string[];
}

/** 人工设置等级的操作者上下文（审计用；来自控制器，绝不从请求体来） */
export interface GradeActor {
  adminUserId: string;
  ip?: string | null;
  requestId?: string | null;
  /** 触发路径（写进 `operation_log.path`，便于按接口反查） */
  path?: string;
  method?: string;
}

/**
 * 打手等级服务（**判级唯一实现**，负责人已审批 2026-10-17）
 *
 * ## 对外只有两件事
 *
 * 1. **[evaluate]（自动判定）** —— 每次五维评分落库后**在同一事务内**调用；
 *    读 `worker_stats`（完成单/结算额）+ `order_review`（好评率，经 `ReviewService` 唯一口径）
 *    + `worker_rating_agg`（五维均分/样本数），算出应达档位，**只升不降**，并写 `operation_log`。
 * 2. **[setManualGrade]（人工设置）** —— `PUT /admin/workers/:id/grade`，**仅超管**；
 *    LV5（最高档）**只能**走这条路径（自动判定封顶 `AUTO_MAX_GRADE = 4`）。
 *
 * ## 为什么判级读的是"真实值"而不是"展示值"
 *
 * `worker_stats` 上还有 `display_completed_orders` / `display_satisfied_rate` 两列（运营人设数字，
 * 2026-10-16 引入，负责人口径「**数字可调、评价必须真实**」）。判级**一律不用展示值**：
 * 展示值是给老板端看的话术，等级是平台的**真实履约评价** —— 让运营改个数字就能升级，
 * 等于把制度交给运营的手输框。因此这里读 `ReviewService.workerStatsView().real`
 * （真实值 + 真实好评率），并在 SQL 里只取 `total_amount`（结算累计，本就无展示值）。
 *
 * ## 审计为什么是"同事务裸 INSERT"而不是 `OperationLogService.log()`
 *
 * `OperationLogService.log()` 是 **fire-and-forget**（`void (async …)()`，自己一条独立连接）——
 * 它适合"管理端请求已经成功、留痕慢半拍无伤大雅"的场景。但自动升级发生在**评价事务内部**：
 * 用 fire-and-forget 会出现两种不可接受的状态：
 * ① 事务回滚了，日志却已经写进去（审计撒谎）；
 * ② 事务提交了，进程正好崩在异步写之前（**升级了却没有留痕**）。
 * 因此本服务在**同一个 EntityManager** 里写 `operation_log`（列与形状和 `OperationLogService` 完全一致，
 * 需要 `admin_id/admin_name/module/action/method/path/request_body/ip/request_id/result`），
 * 让"等级变了"与"为什么变、谁让它变的"**要么一起生效、要么一起没有**。
 * 人工设置那条也走同一个私有方法 —— 两条路径的留痕形状**只有一份实现**。
 */
@Injectable()
export class WorkerGradeService {
  private readonly logger = new Logger('WorkerGrade');

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    /**
     * 「好评率」与「完成单数」的**唯一口径出口**（`workerStatsView().real`）。
     * 刻意不在这里重写 `SUM(satisfied)/COUNT(*)`：那是 `ReviewService.satisfiedRateText()` 的领地，
     * 复制一份就会立刻出现"公开页 98.2 / 判级 98.0"这类两套口径（安全审计 F1 的同一类根因）。
     */
    private readonly review: ReviewService,
  ) {}

  // ------------------------------------------------------------------ 自动判定

  /**
   * **升级检查唯一实现**（审批表指定：`worker-grade.service.ts` 的 `evaluate(workerId)`）
   *
   * @param workerId 打手档案 id（`worker.id`）
   * @param em 可选：调用方已在事务里时传入，本方法就**不新开事务**（评分落库路径就是这么用的）
   */
  async evaluate(workerId: string, em?: EntityManager): Promise<GradeEvaluateResult> {
    const id = this.normalizeWorkerId(workerId);
    if (em) return this.evaluateIn(em, id);
    // 没带事务（例如运维手工触发）→ 自己开一个：等级更新与审计必须同生共死
    return this.dataSource.transaction((m) => this.evaluateIn(m, id));
  }

  private async evaluateIn(em: EntityManager, workerId: string): Promise<GradeEvaluateResult> {
    const before = await this.currentGrade(workerId, em);
    const metrics = await this.metricsOf(workerId, em);
    const decision = evaluateGradeTier(metrics);

    /**
     * **只升不降**的**唯一比较点**（全项目仅此一处）：
     * 指标够到 4 档也好、掉回 1 档的成本也罢，`after` 永远不会小于 `before` ——
     * 门槛不再满足时这里只是"不升"（暂缓下一次升级），**绝不降级**。
     */
    const after = Math.max(before, decision.grade);
    const upgraded = after > before;

    if (upgraded) {
      const note = this.autoNote(after, decision.hits);
      await em.query(
        `INSERT INTO worker_grade (worker_id, grade, upgraded_at, upgraded_by, note)
         VALUES (?, ?, NOW(3), NULL, ?)
         ON DUPLICATE KEY UPDATE
           grade = VALUES(grade),
           upgraded_at = VALUES(upgraded_at),
           upgraded_by = VALUES(upgraded_by),
           note = VALUES(note)`,
        [workerId, after, note],
      );
      await this.writeAudit(em, {
        workerId,
        before,
        after,
        hits: decision.hits,
        metrics,
        auto: true,
        note,
      });
      this.logger.log(
        `自动升级 worker=${workerId} ${before}→${after}（${decision.hits.join('；') || '—'}）`,
      );
    }

    return {
      workerId,
      before,
      after,
      upgraded,
      metrics,
      tiers: decision.tiers,
      hits: decision.hits,
    };
  }

  // ------------------------------------------------------------------ 人工设置

  /**
   * 超管人工设置等级（`PUT /admin/workers/:id/grade`，**含最高档 5**）
   *
   * @param workerId 打手档案 id（路径参数 `:id`，不是 user.id）
   * @param input.grade 1–5 的整数（越界 → 中文 400）
   * @param input.note 备注 ≤100 字（落 `worker_grade.note`，同时进审计）
   * @param actor 操作者上下文（**只从 `@CurrentUser()` / `@Req()` 来**，请求体里的任何 id 一律不认）
   */
  async setManualGrade(
    workerId: string,
    input: { grade: unknown; note?: unknown },
    actor: GradeActor,
  ): Promise<{
    ok: true;
    workerId: string;
    before: number;
    after: number;
    gradeLabel: string;
    gradeName: string;
    note: string | null;
  }> {
    const id = this.normalizeWorkerId(workerId);
    const grade = Number(input.grade);
    if (!Number.isInteger(grade) || grade < WORKER_GRADE_MIN || grade > WORKER_GRADE_MAX) {
      throw new BadRequestException(`等级必须是 ${WORKER_GRADE_MIN}-${WORKER_GRADE_MAX} 的整数`);
    }
    const rawNote = String(input.note ?? '').trim();
    if (rawNote.length > 100) throw new BadRequestException('备注最多 100 字');
    const note = rawNote.length ? rawNote : null;

    const result = await this.dataSource.transaction(async (em) => {
      // 档案必须存在（`worker_grade` 没有外键，"设置一个不存在的打手的等级"必须在这里挡住）
      const rows = (await em.query('SELECT id FROM worker WHERE id = ? LIMIT 1', [id])) as Array<{
        id: string;
      }>;
      if (!rows.length) throw new NotFoundException('打手不存在');

      const before = await this.currentGrade(id, em);
      if (before === grade) throw new BadRequestException('目标等级与当前等级相同');

      await em.query(
        `INSERT INTO worker_grade (worker_id, grade, upgraded_at, upgraded_by, note)
         VALUES (?, ?, NOW(3), ?, ?)
         ON DUPLICATE KEY UPDATE
           grade = VALUES(grade),
           upgraded_at = VALUES(upgraded_at),
           upgraded_by = VALUES(upgraded_by),
           note = VALUES(note)`,
        [id, grade, actor.adminUserId, note],
      );

      const metrics = await this.metricsOf(id, em);
      await this.writeAudit(em, {
        workerId: id,
        before,
        after: grade,
        hits: [`人工设置：${gradeLabel(grade)} ${gradeName(grade)}`],
        metrics,
        auto: false,
        note,
        actor,
      });

      return { before, after: grade };
    });

    this.logger.log(
      `人工设置等级 worker=${id} ${result.before}→${result.after} by admin=${actor.adminUserId}`,
    );
    return {
      ok: true,
      workerId: id,
      before: result.before,
      after: result.after,
      gradeLabel: gradeLabel(result.after),
      gradeName: gradeName(result.after),
      note,
    };
  }

  // ------------------------------------------------------------------ 读

  /** 单个打手的等级详情（公开详情 / 打手态「我的」**共用**，含五维与升级进度） */
  async detail(workerId: string, em?: EntityManager): Promise<WorkerGradeDetail> {
    const id = this.normalizeWorkerId(workerId);
    const m = em ?? this.dataSource.manager;
    const grade = await this.currentGrade(id, m);
    const metrics = await this.metricsOf(id, m);
    return this.buildDetail(grade, metrics, await this.ratingSummary(id, m));
  }

  /** 打手态「我的」：按**会话主体**（JWT sub = user.id）找自己的档案，找不到 → 403 中文 */
  async myDetail(userId: string): Promise<WorkerGradeDetail> {
    const worker = await this.workerIdOfUser(userId);
    if (!worker) throw new ForbiddenException('该账号没有打手档案，无法查看打手等级');
    return this.detail(worker);
  }

  /**
   * 批量取等级（列表用，**无 N+1**：整页 id 一次 `IN (...)`，固定 1 条 SQL）
   *
   * 返回值里**没有五维**：找陪玩列表按负责人硬规则只给「名字 + 介绍（+ 展示数值）」，
   * 五维与进度一律进详情页（`GET /public/workers/:id`）。
   */
  async batchGrades(
    workerIds: Array<string | number | null | undefined>,
  ): Promise<Map<string, { grade: number; gradeLabel: string; gradeName: string }>> {
    const map = new Map<string, { grade: number; gradeLabel: string; gradeName: string }>();
    const ids: string[] = [];
    for (const raw of workerIds) {
      const id = String(raw ?? '').trim();
      if (!/^\d+$/.test(id) || map.has(id)) continue;
      // 无行 = 默认档（不是错误、也不是 0）
      map.set(id, this.gradeShape(DEFAULT_WORKER_GRADE));
      ids.push(id);
    }
    if (!ids.length) return map;

    const rows = (await this.dataSource.query(
      `SELECT worker_id AS workerId, grade FROM worker_grade WHERE worker_id IN (${ids.map(() => '?').join(',')})`,
      ids,
    )) as Array<{ workerId: string | number; grade: number | string }>;
    for (const r of rows) {
      map.set(String(r.workerId), this.gradeShape(Number(r.grade)));
    }
    return map;
  }

  /** 等级 → 对外三件套（`grade` / `gradeLabel` / `gradeName`；唯一转换点） */
  gradeShape(grade: number | string): { grade: number; gradeLabel: string; gradeName: string } {
    const g = Number(grade) || DEFAULT_WORKER_GRADE;
    return { grade: g, gradeLabel: gradeLabel(g), gradeName: gradeName(g) };
  }

  // ------------------------------------------------------------------ 内部

  /** 指标（**全部真实值**；见类注释「为什么读真实值」） */
  async metricsOf(workerId: string, em?: EntityManager): Promise<GradeMetrics> {
    const m = em ?? this.dataSource.manager;
    /**
     * ① 完成单 + 好评率：`ReviewService.workerStatsView().real`（口径唯一一处）。
     *    打手不存在时它抛中文 404 —— 这正是判级/详情要的行为。
     */
    const view = await this.review.workerStatsView(workerId);
    /** ② 结算累计：`worker_stats.total_amount`（真实战绩，无展示值；无行按 0） */
    const settleRows = (await m.query(
      'SELECT COALESCE(total_amount, 0) AS settlementAmount FROM worker_stats WHERE worker_id = ? LIMIT 1',
      [workerId],
    )) as Array<{ settlementAmount: number | string }>;
    /**
     * ③ 五维均分/样本数：**只读 `worker_rating_agg`**（老板评价的真实聚合）。
     *
     * ⚠️ **红线（负责人 2026-10-18，不可改）**：`worker_rating_manual`（管理端手填六维）
     * **绝不参与等级判定**，本方法**不读它**、本服务也不注入 `WorkerRatingManualService`。
     * 理由一句话：**管理端手填值只影响展示，不影响等级判定，否则改分即可刷等级** ——
     * 等级是平台对真实履约的评价；让运营改个数字就能升级，等于把制度交给手输框。
     * 手填值只在展示路径生效（`WorkerRatingManualService.resolveRating` →
     * `GET /public/workers/:id` 的 `rating.score` / `rating.sources`）。
     */
    const agg = await this.ratingRow(workerId, m);

    return {
      completedOrders: Number(view.real.completedOrders) || 0,
      satisfiedRatePercent: view.real.satisfiedRate == null ? null : Number(view.real.satisfiedRate),
      ratingAvg: ratingAvgOf(agg),
      ratingSamples: Number(agg.samples) || 0,
      settlementAmount: Number(settleRows[0]?.settlementAmount ?? 0) || 0,
    };
  }

  /** 五维聚合行（无行 → 全 0 + 样本 0；**不编造分数**） */
  private async ratingRow(
    workerId: string,
    m: EntityManager,
  ): Promise<{ skill: number; emotion: number; stress: number; voice: number; shop: number; samples: number }> {
    const rows = (await m.query(
      `SELECT skill, emotion, stress, voice, shop, sample_count AS samples
         FROM worker_rating_agg WHERE worker_id = ? LIMIT 1`,
      [workerId],
    )) as Array<Record<string, number | string>>;
    const r = rows[0];
    return {
      skill: Number(r?.skill ?? 0) || 0,
      emotion: Number(r?.emotion ?? 0) || 0,
      stress: Number(r?.stress ?? 0) || 0,
      voice: Number(r?.voice ?? 0) || 0,
      shop: Number(r?.shop ?? 0) || 0,
      samples: Number(r?.samples ?? 0) || 0,
    };
  }

  /** 对外五维摘要（`rating.avg` 与判级用的是**同一个** `ratingAvgOf`） */
  private async ratingSummary(workerId: string, m: EntityManager): Promise<RatingSummary> {
    const agg = await this.ratingRow(workerId, m);
    return {
      skill: agg.skill,
      emotion: agg.emotion,
      stress: agg.stress,
      voice: agg.voice,
      shop: agg.shop,
      avg: ratingAvgOf(agg),
      samples: agg.samples,
    };
  }

  private buildDetail(grade: number, metrics: GradeMetrics, rating: RatingSummary): WorkerGradeDetail {
    return {
      ...this.gradeShape(grade),
      rating,
      progress: buildGradeProgress(grade, metrics),
    };
  }

  /** 当前等级（无行 → 默认档；**不写库**，避免只读请求产生写入） */
  private async currentGrade(workerId: string, m: EntityManager): Promise<number> {
    const rows = (await m.query('SELECT grade FROM worker_grade WHERE worker_id = ? LIMIT 1', [
      workerId,
    ])) as Array<{ grade: number | string }>;
    if (!rows.length) return DEFAULT_WORKER_GRADE;
    const g = Number(rows[0].grade);
    return Number.isInteger(g) && g >= WORKER_GRADE_MIN && g <= WORKER_GRADE_MAX ? g : DEFAULT_WORKER_GRADE;
  }

  /** 会话主体 → 打手档案 id（只按 `user.id` 查，绝不接受请求体里的 workerId） */
  private async workerIdOfUser(userId: string): Promise<string | null> {
    const id = String(userId ?? '').trim();
    if (!/^\d+$/.test(id)) return null;
    const rows = (await this.dataSource.query('SELECT id FROM worker WHERE user_id = ? LIMIT 1', [
      id,
    ])) as Array<{ id: string }>;
    return rows.length ? String(rows[0].id) : null;
  }

  /** 打手 id 归一化（非法格式一律中文 404，不泄漏"格式对不对"之外的任何信息） */
  private normalizeWorkerId(workerId: string): string {
    const id = String(workerId ?? '').trim();
    if (!/^\d+$/.test(id)) throw new NotFoundException('打手不存在');
    return id;
  }

  /** 自动升级的 `worker_grade.note`（≤100 字：只放命中指标摘要，便于管理端一眼看出凭什么升的） */
  private autoNote(grade: number, hits: string[]): string {
    const text = `自动升级至 ${gradeLabel(grade)}：${hits.join('；') || '—'}`;
    return text.slice(0, 100);
  }

  /**
   * 审计留痕（**唯一实现**，自动/人工两条路径共用）
   *
   * 列与形状对齐 `OperationLogService`：`admin_id`（自动升级为 NULL = 没有具体人）、
   * `admin_name`（自动升级写「系统自动判定」并在 `request_body.actor` 里再注明一次）、
   * `module='worker_grade'`、`request_body` = 变更前后等级 + 命中指标 + 指标快照。
   * **不含任何隐私**（没有手机号/真实姓名/评价正文），只有 id、数字与中文指标描述。
   */
  private async writeAudit(
    em: EntityManager,
    ctx: {
      workerId: string;
      before: number;
      after: number;
      hits: string[];
      metrics: GradeMetrics;
      auto: boolean;
      note: string | null;
      actor?: GradeActor;
    },
  ): Promise<void> {
    const actor = ctx.actor;
    const requestBody = JSON.stringify({
      workerId: ctx.workerId,
      before: ctx.before,
      after: ctx.after,
      beforeLabel: gradeLabel(ctx.before),
      afterLabel: gradeLabel(ctx.after),
      // 自动升级无法归属到人：admin_id 留空，并在正文里**明确注明**是系统自动判定
      actor: ctx.auto ? SYSTEM_ACTOR_NAME : `admin:${actor?.adminUserId ?? ''}`,
      auto: ctx.auto,
      hits: ctx.hits,
      metrics: ctx.metrics,
      note: ctx.note,
    }).slice(0, 4000);

    await em.query(
      `INSERT INTO operation_log
         (admin_id, admin_name, module, action, method, path, request_body, ip, request_id, result, error_msg)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'success', NULL)`,
      [
        ctx.auto ? null : (actor?.adminUserId ?? null),
        ctx.auto ? SYSTEM_ACTOR_NAME : '',
        LOG_MODULE,
        ctx.auto ? ACTION_AUTO : ACTION_MANUAL,
        ctx.auto ? 'SYSTEM' : (actor?.method ?? 'PUT'),
        (ctx.auto ? 'worker-grade:evaluate' : (actor?.path ?? '/admin/workers/:id/grade')).slice(0, 255),
        requestBody,
        actor?.ip?.slice(0, 64) ?? null,
        actor?.requestId?.slice(0, 64) ?? null,
      ],
    );
  }

  /** 五维字段名（对外契约；顺序即 `RATING_DIMS`） */
  static readonly dims = RATING_DIMS;
  /** 自动判定上限（对外说明用；**5 级永不自动给**） */
  static readonly autoMaxGrade = AUTO_MAX_GRADE;
}
