import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, QueryFailedError, Repository } from 'typeorm';

import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { UserNotification } from '../friend/user-notification.entity';
import { Order } from '../order/order.entity';
import { User } from '../user/user.entity';
import { Worker } from '../worker/worker.entity';
import { OrderReview } from './order-review.entity';

/** 评价原文上限（与 `order_review.remark` varchar(200) 同口径，唯一一处常量） */
export const REVIEW_REMARK_MAX = 200;

/** 公开打手页一次下发的最近评价条数（"查看更多"走 `GET /public/workers/:id/reviews`） */
export const PUBLIC_REVIEW_LIMIT = 20;

/** 「一单一评」的重复提交文案（**服务层事务内查重**与**唯一键兜底**共用同一句） */
export const REVIEW_DUPLICATE_MESSAGE = '该订单已评价';

/** 只有 `completed` 可评（docs/05 状态机；其它状态的文案） */
export const REVIEW_NOT_COMPLETED_MESSAGE = '订单完成后才能评价';

/** 公开打手页的 404 文案（不存在 / 档案停用 / 账号封禁**共用一句**，不泄漏具体原因） */
export const WORKER_NOT_PUBLIC_MESSAGE = '打手不存在或已停用';

/** 隐藏时必填原因 */
export const REVIEW_HIDE_REASON_REQUIRED_MESSAGE = '请填写隐藏原因';
export const REVIEW_HIDE_REASON_TOO_LONG_MESSAGE = '隐藏原因最多 200 字';

/** 公开接口下发的单条评价（**只给脱敏昵称**，见 [maskNickname]） */
export interface PublicReviewItem {
  satisfied: boolean;
  remark: string | null;
  createdAt: Date;
  nicknameMasked: string;
}

/**
 * 公开卡片上的三个数值 —— `GET /public/workers/:id`（单人）、`GET /public/players`（列表）与
 * `GET /public/home` 的 `players` 子块**共用同一段实现**（[ReviewService.publicWorkerStats]），
 * 因此这里的形状就是对外口径本身：
 *
 * - `completedOrders`：**生效值** —— 管理端设过展示值则为展示值，否则 `worker_stats.completed_orders`
 *   （**与榜单同源**，不另算一套）；
 * - `reviewCount`：`order_review` 中 `worker_id = 本打手 AND hidden = 0` 的条数（**永远真实**，不提供覆盖）；
 * - `satisfiedRate`：**百分数字符串、保留 1 位小数**（如 `"98.2"`），**无评价时为 `null`**
 *   —— 不是 0–1 比率、不是 0、更不许编 100（`satisfiedRateText()` 是真实值的唯一生成点，
 *   展示值与它走**同一个出口**）。
 */
export interface PublicWorkerStats {
  completedOrders: number;
  reviewCount: number;
  satisfiedRate: string | null;
}

/**
 * 管理端设定的**展示值**（`worker_stats.display_*`，负责人 2026-10-16）。
 *
 * `null` 一律表示「跟随真实」（没设过 / 已被清空），**不是 0**：
 * 「0 单」是一个管理端可以主动设的展示值，用 0 当哨兵会让"恢复真实值"无法表达。
 * `satisfiedRate` 与对外口径同为**百分数字符串**（`"98.2"` = 98.2%），不是 0–1 比率。
 */
export interface WorkerDisplayStats {
  completedOrders: number | null;
  satisfiedRate: string | null;
}

/**
 * 真实值 / 展示值 / 生效值 三联（`GET /admin/workers/:id/stats` 的响应体）
 *
 * 与公开接口**共用同一份聚合**（[ReviewService.loadStats]）：管理端看到的三段与老板端看到的
 * 最终数字出自同一次读取、同一个文案函数 —— 结构上不可能出现"管理端显示 A、老板端显示 B"。
 */
export interface WorkerStatsTriple {
  /** 真实值：`worker_stats.completed_orders` + `order_review` 实时聚合（永远不受展示值影响） */
  real: PublicWorkerStats;
  /** 管理端设定的展示值（null = 跟随真实） */
  display: WorkerDisplayStats;
  /** 最终生效值：有展示值用展示值，否则真实值（公开接口下发的就是它） */
  effective: PublicWorkerStats;
}

/** 设置展示值的返回值（含 `operation_log` 需要的变更前后摘要） */
export interface WorkerDisplayStatsResult extends WorkerStatsTriple {
  workerId: string;
  /** `operation_log.request_body` 直接用它：只记关键字段与**变更前后值**，不记任何个人隐私 */
  audit: {
    workerId: string;
    before: { completedOrders: number | null; satisfiedRate: string | null };
    after: { completedOrders: number | null; satisfiedRate: string | null };
    real: { completedOrders: number; reviewCount: number; satisfiedRate: string | null };
  };
}


/** 管理端隐藏/恢复的返回值（含写 `operation_log` 所需的前后摘要） */
export interface ReviewModerateResult {
  ok: true;
  reviewId: string;
  orderId: string;
  workerId: string | null;
  /** 变更后的 hidden（1 已隐藏 / 0 恢复正常） */
  hidden: number;
  /** 脱敏审计摘要：**只记关键字段与变更前后值**，不记评价原文（`operation_log.request_body` 直接用它） */
  audit: Record<string, unknown>;
}

/**
 * 评价人昵称脱敏 —— **公开接口唯一允许出现的用户标识形态**（docs/09）
 *
 * 口径：**首字 + 两个星号**（如「李**」）。
 * - 昵称是用户自填的自由文本，**可能直接就是手机号/微信号**，所以一律**不留尾部、不留长度**；
 * - 昵称为空（未填）时回「匿名用户」，**绝不用 `uid` 兜底** —— `uid` 是唯一的对外 ID，
 *   能拿去搜索/关联到本人，属于可识别信息，公开接口一个字段都不下发
 *   （手机号 / `uid` / 真实用户名 / `user.id` 全部不出现在 `/public/workers*` 的响应里）。
 */
export function maskNickname(nickname?: string | null): string {
  const name = String(nickname ?? '').trim();
  if (!name) return '匿名用户';
  // 用 Array.from 按**码点**切，避免把 emoji/扩展汉字切坏
  const chars = Array.from(name);
  return `${chars[0]}**`;
}

/**
 * 评价服务（负责人 2026-10-15：「做评价与评分体系」+「选打手页面点开打手头像可以看打手信息」）
 *
 * 三块能力，一个服务：
 * - **老板侧**：`POST /user/orders/:id/review` 提交、`GET /user/orders/:id/review` 回显；
 * - **公开侧**：打手信息（接单次数 + 好评率 + 最近评价）与评价分页 —— **无需登录**、只给脱敏昵称；
 * - **管理端**：评价列表 + 隐藏/恢复（每个写接口都由控制器写 `operation_log`）。
 *
 * ## 「一单一评」的三层保证（照 CLAUDE.md 充值与提现那套姿势，缺一不可）
 *
 * | # | 手段 | 落点 |
 * |---|---|---|
 * | ① | **事务 + `SELECT … FOR UPDATE` 锁订单行** | `submit()`：锁住这一单 → 同单并发评价在此排队 → 事务内查重 → 已存在则中文 400 |
 * | ② | **表级唯一约束** | `UK_review_order (order_id)`：绕过 ① 的并发（多实例）第二个 INSERT 撞 `ER_DUP_ENTRY` → 翻译成同一句中文 400 |
 * | ③ | **条件 UPDATE 判 `affectedRows`** | `adminHide` / `adminShow`：`WHERE id=? AND hidden=<旧值>` —— **"能否隐藏/恢复"的唯一判定点**（刻意不写成"先读状态再 UPDATE"：那样把条件 UPDATE 变异成无条件也测不出来） |
 *
 * ## 为什么好评率的**真实值**仍然实时算（`worker_stats` 里加的只是"展示值"，不是真实值冗余列）
 *
 * 冗余列 = 第二条真相：评价可能被管理端**隐藏/恢复**（`hidden` 翻转），隐藏后计数必须立刻变；
 * 若再存一列真实的 `satisfied_rate`，就得在"评价写入 / 隐藏 / 恢复 / 删号"每个路径上同步维护它，
 * 任何一处漏掉就是永久偏差（CLAUDE.md：退款时战绩与钱包必须同步回退 = 同一类事故）。
 * 这里**真实值只算不存**：`COUNT/SUM ... WHERE worker_id IN (...) AND hidden=0 GROUP BY worker_id` 走
 * `IDX_review_worker (worker_id, hidden, created_at)`，单打手评价量级下是索引内的毫秒级聚合；
 * 找陪玩列表把整页 id 一次性带进 `IN`（[publicWorkerStats]），仍然只算不存、仍然只有这一处口径。
 *
 * 2026-10-16（负责人：「**数字可调、评价必须真实**」）新增的
 * `worker_stats.display_completed_orders` / `display_satisfied_rate` 两列是**展示值**，
 * 与上面那条"不加真实值冗余列"**不矛盾**：
 * - 展示值**不承担任何真相**，它存在的唯一意义就是"管理端要对外显示别的数字"；
 * - 它**不影响**真实聚合与评价列表（`reviewCount`、`reviews`、榜单、结算、退款冲正一律照旧）；
 * - 真实值仍然每次现算在 [loadStats] 的**同一条聚合 SQL** 里（只是把这两列一起 SELECT 出来，
 *   SQL 条数不变），所以"真实值 / 展示值 / 生效值"永远出自同一次读取，不存在两套口径。
 *
 * ⚠️ 因此 `/api/v1/public/workers*` **以及内嵌了打手数值的 `GET /public/home`** 在
 * `PublicCacheInterceptor` 里登记为 **`no-store`**
 * （不进进程内微缓存）：好评率随老板评价**实时变化**；`/public/players` 追加的这三个数值同源同变化率，
 * 而它**本来就在 `no-store` 档**（随授权状态变化），因此本批次**无需改缓存登记**。
 */
@Injectable()
export class ReviewService {
  private readonly logger = new Logger('Review');

  constructor(
    @InjectRepository(OrderReview) private readonly repo: Repository<OrderReview>,
    @InjectRepository(UserNotification) private readonly notifRepo: Repository<UserNotification>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly realtime: RealtimeGateway,
  ) {}

  // ---------------- 老板侧 ----------------

  /**
   * 提交评价（**一单一评**，三层保证见类注释）
   *
   * @returns `{ ok: true, needAfterSale }` —— 不满意时 `needAfterSale=true`，
   *   客户端据此引导老板走**既有的** `POST /user/orders/:id/appeal`（售后只有这一条入口）；
   *   服务端**不改订单状态、不落售后单**（避免第二条售后真相）。
   */
  async submit(
    userId: string,
    orderId: string,
    dto: { satisfied: boolean; remark?: string },
  ): Promise<{ ok: true; needAfterSale: boolean }> {
    const satisfied = dto.satisfied === true;
    const remark = String(dto.remark ?? '').trim();
    if (remark.length > REVIEW_REMARK_MAX) {
      throw new BadRequestException(`评价内容最多 ${REVIEW_REMARK_MAX} 字`);
    }

    const created = await this.dataSource
      .transaction(async (em) => {
        // ① 事务内校验：锁住订单行（归属 + 状态），同一订单的并发评价在这里排队
        //    查询条件含 user_id —— 伪造 orderId 直接 404，不区分"不存在"与"不是你的"（docs/04）
        const order = await em.findOne(Order, {
          where: { id: orderId, userId },
          lock: { mode: 'pessimistic_write' },
        });
        if (!order) throw new NotFoundException('订单不存在或不属于你');
        if (order.status !== 'completed') throw new BadRequestException(REVIEW_NOT_COMPLETED_MESSAGE);

        // ① 事务内查重（判定点；表级唯一键是第②层兜底，见下 catch）
        const exist = await em.findOne(OrderReview, { where: { orderId: order.id } });
        if (exist) throw new BadRequestException(REVIEW_DUPLICATE_MESSAGE);

        const review = await em.save(
          em.create(OrderReview, {
            orderId: order.id,
            userId,
            workerId: order.workerId,
            satisfied: satisfied ? 1 : 0,
            // 空串按未填处理（与客户端"没写"等价，避免库里出现 '' 与 NULL 两种"空"）
            remark: remark.length ? remark : null,
            hidden: 0,
            hiddenReason: null,
            // 显式写时间：同事务内即可回显给对方（且不必再读一次库）
            createdAt: new Date(),
          }),
        );
        return { orderId: String(order.id), orderNo: order.orderNo, workerId: order.workerId, reviewId: String(review.id) };
      })
      .catch((e: unknown) => {
        // ② 表级唯一约束兜底：并发下第二个 INSERT 撞 UK_review_order → 中文 400（不是 500）
        if (e instanceof QueryFailedError && (e as unknown as { code?: string }).code === 'ER_DUP_ENTRY') {
          throw new BadRequestException(REVIEW_DUPLICATE_MESSAGE);
        }
        throw e;
      });

    // 通知打手（复用既有 user_notification + notification:new；best-effort，失败不影响评价已落库）
    await this.notifyWorker(created.workerId, {
      satisfied,
      remark: remark.length ? remark : null,
      orderNo: created.orderNo,
      orderId: created.orderId,
    });

    this.logger.log(`评价提交 order=${created.orderNo} worker=${created.workerId ?? '-'} satisfied=${satisfied ? 1 : 0}`);
    return { ok: true, needAfterSale: !satisfied };
  }

  /** 该单的评价（用于客户端回显"已评价"）；未评价返回 `null`（不是 404） */
  async mine(userId: string, orderId: string) {
    const order = await this.dataSource.getRepository(Order).findOne({ where: { id: orderId, userId } });
    if (!order) throw new NotFoundException('订单不存在或不属于你');
    const review = await this.repo.findOne({ where: { orderId: order.id } });
    if (!review) return null;
    return {
      satisfied: review.satisfied === 1,
      remark: review.remark,
      createdAt: review.createdAt,
    };
  }

  // ---------------- 公开侧（无需登录） ----------------

  /**
   * 打手公开信息（`GET /public/workers/:id`）
   *
   * - `completedOrders`：`worker_stats.completed_orders`（**与榜单同源**，不另立口径）；
   * - `reviewCount` / `satisfiedRate`：**实时聚合** `order_review`（只算 `hidden=0`）；
   *   **无评价时 `satisfiedRate` 为 `null`**（前端显示「暂无评价」）—— 绝不编一个 100% 出来：
   *   "没人评过"和"全好评"是两件事，凑成一个数字是最容易被后人和老板同时误读的假数据；
   * - `reviews`：最近 20 条（`hidden=0`，只带**脱敏昵称**）。
   *
   * ⚠️ 四个数值里的前三个**不在这里算**：一律委托 [publicWorkerStats]（与 `/public/players` 同一段实现）。
   */
  async publicWorkerProfile(workerId: string) {
    const profile = await this.requirePublicWorker(workerId);
    const stats = await this.statsOf(profile.workerId);
    const reviews = await this.fetchReviews(profile.workerId, 0, PUBLIC_REVIEW_LIMIT);
    return {
      id: profile.workerId,
      nickname: profile.nickname,
      intro: profile.intro,
      avatarMediaId: profile.avatarMediaId,
    backgroundMediaId: profile.backgroundMediaId,
      completedOrders: stats.completedOrders,
      reviewCount: stats.reviewCount,
      satisfiedRate: stats.satisfiedRate,
      reviews,
    };
  }

  /** 评价分页（`GET /public/workers/:id/reviews`，供"查看更多"；`total` 与资料页 `reviewCount` 同源） */
  async publicWorkerReviews(workerId: string, page: number, pageSize: number) {
    const profile = await this.requirePublicWorker(workerId);
    const stats = await this.statsOf(profile.workerId);
    const list = await this.fetchReviews(profile.workerId, (page - 1) * pageSize, pageSize);
    return { list, total: stats.reviewCount, page, pageSize };
  }

  /**
   * 公开数值的**唯一实现**（`completedOrders` / `reviewCount` / `satisfiedRate` 的**生效值**）
   *
   * 三个公开消费方都只走这里，所以"列表显示 98.2、详情显示别的"在结构上不可能发生：
   * - `GET /public/workers/:id`（单人）→ 传入 1 个 id；
   * - `GET /public/players`（列表，负责人 2026-10-15 追加 3 字段）→ 传入本页全部 id，
   *   **`IN (...)` 批量聚合 + `GROUP BY`**，每张表页内只发 1 条 SQL，**不做逐行查**（N+1 被结构性排除）；
   * - `GET /public/home` 的 `players` 子块 → 复用同一个 `PlayersService`（进而走到本函数）。
   *
   * **生效值口径（负责人 2026-10-16）**：`worker_stats.display_*` 非空则用展示值，否则回落真实值；
   * `reviewCount` 永远是真实值（不提供覆盖）。
   *
   * SQL 条数与 `pageSize` **无关**（固定 2 条：`worker_stats` 一条 + `order_review` 一条），
   * 与单人路径用的是同一张表、同一列、同一个过滤条件（`hidden = 0`）与同一个文案函数
   * [satisfiedRateText] —— 两处**逐字一致**。
   *
   * 缺失的行按 0/0/null 兜底：`worker_stats` 无行（新打手）/ `order_review` 无行（没人评过）
   * 都不算错误，`satisfiedRate` 保持 `null`（**不编 100**）。
   */
  async publicWorkerStats(
    workerIds: Array<string | number | null | undefined>,
  ): Promise<Map<string, PublicWorkerStats>> {
    const triples = await this.loadStats(workerIds);
    const map = new Map<string, PublicWorkerStats>();
    for (const [id, t] of triples) map.set(id, t.effective);
    return map;
  }

  /**
   * 管理端三联（`GET /admin/workers/:id/stats`）：真实值 / 展示值 / 最终生效值
   *
   * 与公开路径**共用 [loadStats]**（同一份聚合、同一个文案函数、同一次读取），
   * 因此管理端看到的 `effective` 就是老板端将看到的那一个数字 —— 不存在"两套口径各算一遍"。
   *
   * 打手 id 非法或不存在 → 中文 404（**刻意不套用 `requirePublicWorker`**：
   * 那条还要求 `worker.status=1` + `user.status=1`，而管理端要看的是**包括已停用/已封禁在内**的档案）。
   */
  async workerStatsView(workerId: string): Promise<WorkerStatsTriple & { workerId: string }> {
    const id = await this.assertWorkerExists(workerId);
    const triples = await this.loadStats([id]);
    const triple = triples.get(id) ?? emptyTriple();
    return { workerId: id, real: triple.real, display: triple.display, effective: triple.effective };
  }

  /**
   * 设置展示值（`PUT /admin/workers/:id/display-stats`，权限点 `worker:adjust`，默认仅超管）
   *
   * 口径（负责人 2026-10-16，逐条照做）：
   * - **`null` / 省略 = 恢复「跟随真实」**：两列一律写 `null`，即请求体是**整体覆盖**而不是局部合并
   *   （只传 `completedOrders` 等于同时清空 `satisfiedRate` —— 这是接口契约，已在 Swagger 摘要里写明）；
   * - `completedOrders` 范围 **0–999999**、`satisfiedRate` 范围 **0.0–100.0**（百分数，最多 1 位小数）；
   * - **只写展示值两列**：`total_orders` / `completed_orders` / `total_amount` **一个字都不碰**
   *   （真实战绩是结算与退款冲正的地盘，任何管理端动作都不得改写）；
   * - 打手不存在 → 中文 404；越界 → 中文 400（DTO 已先校验一遍，这里再兜一层，
   *   因为本函数也可能被其它入口调用，校验不能只活在校验管道里）。
   *
   * **单条 SQL 写入（upsert）**：`worker_stats` 行可能还不存在（新打手从未结算过），
   * 用 `INSERT … ON DUPLICATE KEY UPDATE` 一次搞定，**不做"先查再写"**（那样有并发窗口）。
   * 刻意用「参数写两遍」而不是 MySQL 已弃用的 `VALUES()`：语义相同，少一个弃用告警。
   *
   * 返回值含 `before` / `after` 摘要，供控制器写 `operation_log`（`module=worker`、
   * `action=worker:adjust-stats`）；**不记任何个人隐私**（只有两个数字与打手 id）。
   */
  async setWorkerDisplayStats(
    workerId: string,
    dto: { completedOrders?: number | null; satisfiedRate?: number | null },
  ): Promise<WorkerDisplayStatsResult> {
    const id = await this.assertWorkerExists(workerId);

    const completedOrders = normalizeDisplayCompletedOrders(dto.completedOrders);
    const satisfiedRate = normalizeDisplaySatisfiedRate(dto.satisfiedRate);

    const before = (await this.loadStats([id])).get(id) ?? emptyTriple();

    await this.dataSource.query(
      `INSERT INTO worker_stats (worker_id, display_completed_orders, display_satisfied_rate)
       VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE display_completed_orders = ?, display_satisfied_rate = ?`,
      [id, completedOrders, satisfiedRate, completedOrders, satisfiedRate],
    );

    const after = (await this.loadStats([id])).get(id) ?? emptyTriple();
    this.logger.log(
      `展示值调整 worker=${id} completedOrders=${before.display.completedOrders ?? 'NULL'}→${after.display.completedOrders ?? 'NULL'} ` +
        `satisfiedRate=${before.display.satisfiedRate ?? 'NULL'}→${after.display.satisfiedRate ?? 'NULL'}`,
    );

    return {
      workerId: id,
      real: after.real,
      display: after.display,
      effective: after.effective,
      audit: {
        workerId: id,
        before: { ...before.display },
        after: { ...after.display },
        real: { ...after.real },
      },
    };
  }

  // ---------------- 管理端（治理；控制器负责写 operation_log） ----------------

  /**
   * 评价列表（含 `hidden` 状态）
   *
   * 筛选值**严格校验**（`satisfied` / `hidden` 只认 0/1）而不是静默忽略：
   * 治理页面上的筛选条件被忽略会让人以为"符合条件的一条都没有"，比报错更危险
   * （与提现列表 `status` 的既有口径一致）。
   */
  async adminList(q: {
    page: number;
    pageSize: number;
    satisfied?: string;
    hidden?: string;
    workerId?: string;
  }) {
    const satisfied = parseTinyFlag(q.satisfied, 'satisfied');
    const hidden = parseTinyFlag(q.hidden, 'hidden');
    const workerId = String(q.workerId ?? '').trim();
    if (workerId && !/^\d+$/.test(workerId)) throw new BadRequestException('打手参数不合法');

    const qb = this.dataSource
      .createQueryBuilder(OrderReview, 'r')
      .leftJoin(Order, 'o', 'o.id = r.order_id')
      .leftJoin(Worker, 'w', 'w.id = r.worker_id')
      .leftJoin(User, 'wu', 'wu.id = w.user_id')
      .leftJoin(User, 'u', 'u.id = r.user_id')
      .select([
        'r.id AS id',
        'r.order_id AS orderId',
        'o.order_no AS orderNo',
        // 昵称优先、退 `uid`、再退空串：管理端要看得出"是谁"，但**不引入第二套展示规则**
        `COALESCE(NULLIF(wu.nickname, ''), wu.uid, '') AS workerNickname`,
        `COALESCE(NULLIF(u.nickname, ''), u.uid, '') AS userName`,
        'r.satisfied AS satisfied',
        'r.remark AS remark',
        'r.hidden AS hidden',
        'r.hidden_reason AS hiddenReason',
        'r.created_at AS createdAt',
      ]);
    if (satisfied !== undefined) qb.andWhere('r.satisfied = :satisfied', { satisfied });
    if (hidden !== undefined) qb.andWhere('r.hidden = :hidden', { hidden });
    if (workerId) qb.andWhere('r.worker_id = :workerId', { workerId });

    const total = await qb.clone().select('COUNT(1)', 'cnt').getRawOne<{ cnt: string }>();
    const rows = await qb
      .orderBy('r.id', 'DESC')
      .offset((q.page - 1) * q.pageSize)
      .limit(q.pageSize)
      .getRawMany<Record<string, unknown>>();

    return {
      list: rows.map((r) => ({
        id: String(r.id),
        orderId: String(r.orderId ?? ''),
        orderNo: String(r.orderNo ?? ''),
        workerNickname: String(r.workerNickname ?? ''),
        userName: String(r.userName ?? ''),
        satisfied: Number(r.satisfied) === 1,
        remark: r.remark == null ? null : String(r.remark),
        hidden: Number(r.hidden) === 1,
        hiddenReason: r.hiddenReason == null ? null : String(r.hiddenReason),
        createdAt: r.createdAt,
      })),
      total: Number(total?.cnt ?? 0),
      page: q.page,
      pageSize: q.pageSize,
    };
  }

  /**
   * 隐藏评价（`POST /admin/reviews/:id/hide`）
   *
   * ③ 条件 UPDATE（`WHERE id=? AND hidden=0`）判 `affectedRows` —— **唯一判定点**：
   * 已隐藏的行 affected=0 → 中文 400「该评价已隐藏」，**不重复写 operation_log**。
   */
  async adminHide(id: string, reason: string): Promise<ReviewModerateResult> {
    const hiddenReason = String(reason ?? '').trim();
    if (!hiddenReason) throw new BadRequestException(REVIEW_HIDE_REASON_REQUIRED_MESSAGE);
    if (hiddenReason.length > REVIEW_REMARK_MAX) throw new BadRequestException(REVIEW_HIDE_REASON_TOO_LONG_MESSAGE);

    const review = await this.repo.findOne({ where: { id } });
    if (!review) throw new NotFoundException('评价不存在');

    const res = await this.repo
      .createQueryBuilder()
      .update(OrderReview)
      .set({ hidden: 1, hiddenReason })
      .where('id = :id AND hidden = 0', { id: review.id })
      .execute();
    if (!res.affected) throw new BadRequestException('该评价已隐藏');

    this.logger.log(`评价隐藏 review=${review.id} order=${review.orderId}`);
    return {
      ok: true,
      reviewId: String(review.id),
      orderId: String(review.orderId),
      workerId: review.workerId == null ? null : String(review.workerId),
      hidden: 1,
      audit: {
        reviewId: String(review.id),
        orderId: String(review.orderId),
        workerId: review.workerId == null ? null : String(review.workerId),
        hiddenBefore: 0,
        hiddenAfter: 1,
        reason: hiddenReason,
      },
    };
  }

  /**
   * 恢复评价（`POST /admin/reviews/:id/show`）
   *
   * 条件 UPDATE（`WHERE id=? AND hidden=1`）判 `affectedRows` —— 与隐藏同一把尺子。
   * 恢复时**清空 `hidden_reason`**：本列语义是"当前的隐藏原因"，评价已可见却仍带着原因，
   * 客户端/管理端都可能把它当成"当前状态"渲染；历史原因由 `operation_log` 留痕（不丢）。
   */
  async adminShow(id: string): Promise<ReviewModerateResult> {
    const review = await this.repo.findOne({ where: { id } });
    if (!review) throw new NotFoundException('评价不存在');

    const res = await this.repo
      .createQueryBuilder()
      .update(OrderReview)
      .set({ hidden: 0, hiddenReason: null })
      .where('id = :id AND hidden = 1', { id: review.id })
      .execute();
    if (!res.affected) throw new BadRequestException('该评价未被隐藏');

    this.logger.log(`评价恢复 review=${review.id} order=${review.orderId}`);
    return {
      ok: true,
      reviewId: String(review.id),
      orderId: String(review.orderId),
      workerId: review.workerId == null ? null : String(review.workerId),
      hidden: 0,
      audit: {
        reviewId: String(review.id),
        orderId: String(review.orderId),
        workerId: review.workerId == null ? null : String(review.workerId),
        hiddenBefore: 1,
        hiddenAfter: 0,
        // 变更前摘要（≤200 字，非敏感信息）；恢复后该列已被清空，所以必须在这里记下
        reasonBefore: review.hiddenReason,
      },
    };
  }

  // ---------------- 内部 ----------------

  /**
   * 公开页的打手判定：**不存在 / 档案停用 / 账号封禁 → 同一句 404**
   *
   * 三者在对外表现上必须一致（不泄漏"这个 id 存在但停用了"），且都**只认权威表**：
   * `worker.status = 1`（在职）+ `user.status = 1`（未封禁）。
   * 复用同一份 where → 资料页与评价分页的 404 口径恒等。
   *
   * 只做"这个人能不能公开出现"的判定与展示字段（昵称/介绍/头像）；
   * 接单次数与评价数值**不在这里查** —— 一律走 [publicWorkerStats]（口径唯一一处）。
   */
  private async requirePublicWorker(workerId: string): Promise<{
    workerId: string;
    nickname: string;
    intro: string;
    avatarMediaId: string | null;
    backgroundMediaId: string | null;
  }> {
    const id = String(workerId ?? '').trim();
    // 非数字 id 直接 404（公开接口不区分 400/404，避免枚举出"哪些 id 格式对但不存在"）
    if (!/^\d+$/.test(id)) throw new NotFoundException(WORKER_NOT_PUBLIC_MESSAGE);

    const rows = await this.dataSource.query<
      Array<{ workerId: string; nickname: string | null; intro: string | null; avatarMediaId: string | null; backgroundMediaId: string | null }>
    >(
      `SELECT w.id AS workerId, u.nickname AS nickname, u.intro AS intro,
              u.avatar_media_id AS avatarMediaId,
    u.background_media_id AS backgroundMediaId
         FROM worker w
         JOIN user u ON u.id = w.user_id
        WHERE w.id = ? AND w.status = 1 AND u.status = 1
        LIMIT 1`,
      [id],
    );
    const row = rows[0];
    if (!row) throw new NotFoundException(WORKER_NOT_PUBLIC_MESSAGE);

    return {
      workerId: String(row.workerId),
      nickname: String(row.nickname ?? ''),
      intro: String(row.intro ?? ''),
      avatarMediaId: row.avatarMediaId == null ? null : String(row.avatarMediaId),
    backgroundMediaId: row.backgroundMediaId == null ? null : String(row.backgroundMediaId),
    };
  }

  /**
   * 单个打手的三个数值（内部便利方法）
   *
   * **只是 `publicWorkerStats` 的单元素封装**：刻意不在这里写第二份聚合 SQL/文案逻辑，
   * 否则列表（批量）与详情（单个）就会像"两套实现"一样各自演化 —— 那正是本批次要消灭的隐患。
   */
  private async statsOf(workerId: string): Promise<PublicWorkerStats> {
    const stats = await this.publicWorkerStats([workerId]);
    return stats.get(String(workerId)) ?? { completedOrders: 0, reviewCount: 0, satisfiedRate: null };
  }

  /**
   * 真实值 / 展示值 / 生效值的**唯一聚合实现**（公开接口与管理端三联共用）
   *
   * 固定 **2 条 SQL**（与 id 个数、`pageSize` 无关）：
   * ① `worker_stats`：真实接单次数 + 两个展示值列（2026-10-16 起这一条多带两列，**条数不变**）；
   * ② `order_review`：真实评价条数与好评数（只算 `hidden = 0`）。
   *
   * 生效值在这里一次算好（`completedOrders` 与 `satisfiedRate` 各自"展示值优先、否则真实值"），
   * `reviewCount` **恒为真实值**（负责人口径：评价条数不提供覆盖）。
   * 文案（百分数字符串）一律走 [satisfiedRateText] / [satisfiedRatePercentText]，
   * 本函数内**没有第二处 toFixed** —— 这是"同一规则只有一份实现"的落点。
   */
  private async loadStats(workerIds: Array<string | number | null | undefined>): Promise<Map<string, WorkerStatsTriple>> {
    const map = new Map<string, WorkerStatsTriple>();
    const ids: string[] = [];
    for (const raw of workerIds) {
      const id = String(raw ?? '').trim();
      // 非数字 id 直接忽略（公开接口不因一个脏值整体 400/500，与 `requirePublicWorker` 的 404 口径一致）
      if (!/^\d+$/.test(id) || map.has(id)) continue;
      // 默认值即"无数据"态：satisfiedRate 天生是 null，展示值天生是 null（= 跟随真实）
      map.set(id, emptyTriple());
      ids.push(id);
    }
    if (!ids.length) return map;

    // 参数是纯数字校验过的 id 拼进 IN —— 仍是占位符绑定，不做字符串拼接取值
    const placeholders = ids.map(() => '?').join(',');

    // ① 接单次数（真实）+ 展示值两列：`worker_stats.completed_orders`（**与榜单同源**，不另算一套）
    const statRows = await this.dataSource.query<
      Array<{
        workerId: string | number;
        completedOrders: number | string | null;
        displayCompletedOrders: number | string | null;
        displaySatisfiedRate: number | string | null;
      }>
    >(
      `SELECT worker_id AS workerId,
              COALESCE(completed_orders, 0) AS completedOrders,
              display_completed_orders AS displayCompletedOrders,
              display_satisfied_rate AS displaySatisfiedRate
         FROM worker_stats
        WHERE worker_id IN (${placeholders})`,
      ids,
    );
    for (const r of statRows) {
      const triple = map.get(String(r.workerId));
      if (!triple) continue;
      triple.real.completedOrders = Number(r.completedOrders ?? 0);
      // 展示值：NULL 就是 NULL（**不回落成 0**）—— 0 与"没设过"是两件事
      triple.display.completedOrders =
        r.displayCompletedOrders == null ? null : Number(r.displayCompletedOrders);
      triple.display.satisfiedRate =
        r.displaySatisfiedRate == null ? null : satisfiedRatePercentText(Number(r.displaySatisfiedRate));
    }

    // ② 好评率（真实）：只算 `hidden = 0`（隐藏/恢复立即反映；真实值不在 `worker_stats` 存冗余列，见类注释）
    const reviewRows = await this.dataSource.query<
      Array<{ workerId: string | number; cnt: number | string; ok: number | string | null }>
    >(
      `SELECT worker_id AS workerId,
              COUNT(1) AS cnt,
              SUM(CASE WHEN satisfied = 1 THEN 1 ELSE 0 END) AS ok
         FROM order_review
        WHERE worker_id IN (${placeholders}) AND hidden = 0
        GROUP BY worker_id`,
      ids,
    );
    for (const r of reviewRows) {
      const triple = map.get(String(r.workerId));
      if (!triple) continue;
      const count = Number(r.cnt ?? 0);
      triple.real.reviewCount = count;
      // 真实值的唯一生成点：无评价 → null；有评价 → 百分数字符串保留 1 位小数
      triple.real.satisfiedRate = satisfiedRateText(count, Number(r.ok ?? 0));
    }

    // ③ 生效值 = 展示值优先、否则真实值（`reviewCount` 永远真实）—— 一次性在这里收口
    for (const triple of map.values()) {
      triple.effective.completedOrders =
        triple.display.completedOrders == null ? triple.real.completedOrders : triple.display.completedOrders;
      triple.effective.satisfiedRate =
        triple.display.satisfiedRate == null ? triple.real.satisfiedRate : triple.display.satisfiedRate;
      triple.effective.reviewCount = triple.real.reviewCount;
    }
    return map;
  }

  /**
   * 打手档案存在性判定（管理端展示值写入/查看用）
   *
   * 与 [requirePublicWorker] **刻意不同**：这里不看 `worker.status` / `user.status` ——
   * 管理端要能对**已停用/已封禁**的打手查看与调整展示值（停用了也要能看见它现在对外长什么样）。
   * 只要求"这一行存在"，否则中文 404（不泄漏"这个 id 格式对不对"之外的任何信息）。
   */
  private async assertWorkerExists(workerId: string): Promise<string> {
    const id = String(workerId ?? '').trim();
    if (!/^\d+$/.test(id)) throw new NotFoundException('打手不存在');
    const rows = await this.dataSource.query<Array<{ id: string }>>(
      'SELECT id FROM worker WHERE id = ? LIMIT 1',
      [id],
    );
    if (!rows[0]) throw new NotFoundException('打手不存在');
    return String(rows[0].id);
  }

  /** 评价列表（公开口径：只取 `hidden=0`，只给脱敏昵称） */
  private async fetchReviews(workerId: string, offset: number, limit: number): Promise<PublicReviewItem[]> {
    const rows = await this.dataSource.query<
      Array<{ satisfied: number; remark: string | null; createdAt: Date; nickname: string | null }>
    >(
      // id 与 created_at 同序（自增写入）→ 用主键倒序即可命中 IDX_review_worker 的后缀
      `SELECT r.satisfied AS satisfied, r.remark AS remark, r.created_at AS createdAt, u.nickname AS nickname
         FROM order_review r
         JOIN user u ON u.id = r.user_id
        WHERE r.worker_id = ? AND r.hidden = 0
        ORDER BY r.id DESC
        LIMIT ? OFFSET ?`,
      [workerId, limit, offset],
    );
    return rows.map((r) => ({
      satisfied: Number(r.satisfied) === 1,
      remark: r.remark == null ? null : String(r.remark),
      createdAt: r.createdAt,
      nicknameMasked: maskNickname(r.nickname),
    }));
  }

  /**
   * 给被打手发站内通知（复用既有 `user_notification` + `notification:new`，不新造通道）
   *
   * **best-effort**：通知失败只告警 —— 评价已经落库，通知只是"提醒打手去看"，
   * 绝不能因为通知写失败就把已经成功的评价回滚掉（类比下单后的推送）。
   * 文案（负责人 2026-10-15 定案）：「收到一条好评」/「收到一条差评，平台客服会跟进」。
   */
  private async notifyWorker(
    workerId: string | null,
    payload: { satisfied: boolean; remark: string | null; orderNo: string; orderId: string },
  ): Promise<void> {
    if (!workerId) return;
    try {
      const rows = await this.dataSource.query<Array<{ user_id: string }>>(
        'SELECT user_id FROM worker WHERE id = ? LIMIT 1',
        [workerId],
      );
      const workerUserId = rows[0]?.user_id;
      if (!workerUserId) return;
      const good = payload.satisfied;
      await this.notifRepo.save(
        this.notifRepo.create({
          userId: String(workerUserId),
          type: 'order_review',
          title: good ? '收到一条好评' : '收到一条差评',
          content: good
            ? `订单 ${payload.orderNo} 收到一条好评${payload.remark ? `：${payload.remark}` : ''}`
            : `订单 ${payload.orderNo}：收到一条差评，平台客服会跟进`,
          refId: payload.orderId,
        }),
      );
      this.realtime.emitToUser(String(workerUserId), 'notification:new', { type: 'order_review' });
    } catch (e) {
      this.logger.warn(`评价通知发送失败（不影响评价已落库）worker=${workerId}: ${(e as Error).message}`);
    }
  }
}

/**
 * 好评率文案（**真实值入口**）：**无评价返回 `null`**（前端显示「暂无评价」），有评价保留 1 位小数（如 `"98.2"`）。
 *
 * 刻意**不给"没人评过"编一个 100%**：那会让新打手看起来"满分"，属于对老板的误导；
 * 也刻意不返回 `"0.0"`（那读起来像"全都是差评"）。
 *
 * ⚠️ 口径红线（踩过的坑，不许再踩第二次）：对外一律是**百分数字符串**（`"98.2"` 表示 98.2%），
 * **不是 0–1 比率** —— 历史上曾把 `1.0` 渲染成 `100%`。
 * 因此本函数与展示值入口 [satisfiedRatePercentText] **共用同一个尾部**
 * （`toFixed(1)` 只有那一处），展示值不可能绕过这条口径自己格式化。
 */
export function satisfiedRateText(count: number, satisfied: number): string | null {
  if (!count) return null;
  return satisfiedRatePercentText((satisfied / count) * 100);
}

/**
 * 百分数 → 对外文案的**唯一生成点**（真实值与展示值共用出口）
 *
 * 入参是**百分数**（`98.2` = 98.2%，`100` = 100%），不是比率。保留 1 位小数，
 * 与 `worker_stats.display_satisfied_rate`（`decimal(5,1)`）的精度一致 ——
 * 管理端存什么、老板端就看到什么，不会出现"库里 98.2、界面 98.2000001"这类浮点噪声。
 */
export function satisfiedRatePercentText(percent: number): string {
  return Number(percent).toFixed(1);
}

/** 「无数据」三联（新打手 / 该 id 在两张表里都没有行） */
function emptyTriple(): WorkerStatsTriple {
  return {
    real: { completedOrders: 0, reviewCount: 0, satisfiedRate: null },
    display: { completedOrders: null, satisfiedRate: null },
    effective: { completedOrders: 0, reviewCount: 0, satisfiedRate: null },
  };
}

/**
 * 展示值校验：接单次数（0–999999 整数；`null`/`undefined` = 恢复跟随真实）
 *
 * 刻意**不悄悄取整**（`12.7` → 12 会让管理端以为设成功了）也不是静默忽略非法值：
 * 越界一律中文 400。DTO 已经校验过一遍，这里是服务层的第二道（本函数也可能被别的入口调用）。
 */
function normalizeDisplayCompletedOrders(raw: number | null | undefined): number | null {
  if (raw === null || raw === undefined) return null;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0 || n > 999999) {
    throw new BadRequestException('接单次数展示值需为 0-999999 的整数（null = 跟随真实）');
  }
  return n;
}

/**
 * 展示值校验：好评率（**百分数** 0.0–100.0，最多 1 位小数；`null`/`undefined` = 恢复跟随真实）
 *
 * ⚠️ 入参是百分数，不是 0–1 比率（见 [satisfiedRateText] 的口径红线）。
 */
function normalizeDisplaySatisfiedRate(raw: number | null | undefined): number | null {
  if (raw === null || raw === undefined) return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0 || n > 100) {
    throw new BadRequestException('好评率展示值需为 0-100 的百分数（如 98.2，null = 跟随真实）');
  }
  // 1 位小数：四舍五入后再比对（`98.24` 与 `98.2` 视为同一档，避免存进 decimal(5,1) 被 MySQL 静默改写）
  const rounded = Math.round(n * 10) / 10;
  if (Math.abs(rounded - n) > 1e-9) {
    throw new BadRequestException('好评率展示值最多保留 1 位小数（如 98.2）');
  }
  return rounded;
}

/** 筛选值解析：只认 0/1（以及 true/false 字符串）；非法值中文 400（**不静默忽略**） */
function parseTinyFlag(raw: string | undefined, field: string): number | undefined {
  const v = String(raw ?? '').trim().toLowerCase();
  if (!v) return undefined;
  if (v === '1' || v === 'true') return 1;
  if (v === '0' || v === 'false') return 0;
  throw new BadRequestException(`筛选值不合法（${field} 只能是 0 或 1）`);
}
