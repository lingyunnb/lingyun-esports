import { BadRequestException, ForbiddenException, Injectable, Logger, NotFoundException, OnApplicationBootstrap } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { randomInt, randomUUID } from 'crypto';
import { DataSource, EntityManager, In, IsNull, QueryFailedError, Repository } from 'typeorm';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { splitAmount, workerPercentageOf } from '../setting/commission-rate';
import { SystemSettingService } from '../setting/system-setting.service';
import { LevelService } from '../level/level.service';
import { ChatService } from '../chat/chat.service';
import { DivisionService } from '../division/division.service';
import { GameAccountService } from '../game-account/game-account.service';
import { Game } from '../game/game.entity';
import { Category } from '../game/category.entity';
import { Product } from '../product/product.entity';
import { User } from '../user/user.entity';
import { Wallet } from '../wallet/wallet.entity';
import { WalletTransaction } from '../wallet/wallet-transaction.entity';
import { Worker } from '../worker/worker.entity';
import { WorkerDivisionPermissionService } from '../worker/worker-division-permission.service';
import { OrderAppeal } from './order-appeal.entity';
import { OrderPriceSnapshot } from './order-price-snapshot.entity';
import { OrderSettlement } from './order-settlement.entity';
import { OrderStatusLog } from './order-status-log.entity';
import { Order, OrderStatus } from './order.entity';
import { mapMoney } from '../../common/money.transformer';

/**
 * 结算分成：**比例不再硬编码**（负责人 2026-10-04：抽成 25% 可配）。
 * 生效值 = `system_setting.platform_commission_rate`（百分数整数，默认 25 → 打手 75%），
 * 由 [SystemSettingService.platformCommissionRate] 每次结算读库，[splitAmount] 负责分账与金额守恒。
 * 金额一律按订单快照计算，客户端不可传（docs/06）。

/** 「老板↔打手」直聊收尾结果（settleWorkerDirectTx 返回值 + 两端 user_id，供提交后推 WS） */
export type DirectOutcome = {
  conversationId: string;
  /** 会话被物理删除（最后一单结束）→ 事务提交后推 conv:removed */
  removed: boolean;
  /** 会话被结束（旧语义字段，方案①后恒与 removed 同值；保留字段避免调用方读取 undefined） */
  closed: boolean;
  /** 方案①：该对仍有未完成订单 → 会话保持 open、未做任何改动（不推任何事件） */
  kept: boolean;
  bossUserId: string;
  workerUserId: string;
} | null;

/** 订单完成收口（completeOrderTx）返回值 */
type OrderCompletion = {
  orderNo: string;
  settlementNo: string;
  orderAmount: number;
  workerAmount: number;
  workerPercentage: number;
  platformAmount: number;
  platformPercentage: number;
  settledAt: Date;
  direct: DirectOutcome;
};

/**
 * 每周限购（负责人 2026-10-05）：**规则与文案集中在这里**，创建订单的强制校验与
 * 客户端配额查询共用同一份口径，避免「拦截文案」和「提示文案」两处各写一份而漂移。
 *
 * - 窗口：**滚动 7×24 小时**（`created_at >= NOW(3) - INTERVAL 7 DAY`），不是自然周。
 *   理由：自然周会让「周日 23:59 下 2 单、周一 00:01 再下 2 单」在 2 分钟内拿到 4 单；
 *   滚动窗口对任何时刻都只看「自己前 7 天」，没有跨周突变。
 * - 口径：**两种，由商品列 `product.weekly_limit_by_quantity` 决定**（负责人 2026-10-05 任务③）：
 *   - `0`（默认，= 加列前的现状）：按**订单条数** `COUNT(1)` —— 与「一个账号一周只能下 2 单」一致；
 *   - `1`：按**件数** `COALESCE(SUM(quantity),0)` —— 一次买 2 件就占 2 个名额。
 *   两种口径共用同一条 SQL 模板（只有聚合表达式不同），校验与配额查询**永远不会各算各的**。
 * - 排除：只有 `status = 'canceled'`（已取消）不计入 —— 用户取消 / 管理端取消 / 待接单超时自动取消
 *   三条路径都会全额退款且状态统一落 `canceled`；`abnormal`（异常）、`after_sale`（售后中）
 *   **仍然计入**（单已下、余额已扣，异常/售后要走人工流程，不能靠"报异常"重置名额）。
 */
const WEEKLY_LIMIT_WINDOW_DAYS = 7;

/**
 * 每周限购计数 SQL（口径唯一来源；`FOR UPDATE` 由调用方按需追加）
 *
 * @param byQuantity `true` = 按件数（SUM(quantity)）、`false` = 按订单条数（COUNT(1)）。
 *   两个分支都返回同一个列名 `c`，调用方（以及锁定读 FOR UPDATE）无需区分。
 */
function weeklyLimitCountSql(byQuantity: boolean): string {
  const aggregate = byQuantity ? 'COALESCE(SUM(quantity), 0)' : 'COUNT(1)';
  return `SELECT ${aggregate} AS c FROM \`order\`
   WHERE user_id = ? AND product_id = ? AND status <> 'canceled'
     AND created_at >= DATE_SUB(NOW(3), INTERVAL ${WEEKLY_LIMIT_WINDOW_DAYS} DAY)`;
}

/** 限购口径的展示单位（文案用；口径是唯一来源，别在别处再写一份"单/件"） */
function weeklyLimitUnit(byQuantity: boolean): { unit: string; verb: string } {
  return byQuantity ? { unit: '件', verb: '已购' } : { unit: '单', verb: '已下单' };
}

/** docs/05 合法迁移表 */
const TRANSITIONS: Record<OrderStatus, OrderStatus[]> = {
  pending_take: ['taken', 'pending_dispatch', 'canceled'],
  pending_dispatch: ['taken', 'pending_take', 'canceled'],
  taken: ['in_progress', 'canceled'],
  in_progress: ['pending_confirm', 'abnormal', 'canceled'],
  pending_confirm: ['completed', 'abnormal'],
  completed: ['after_sale'],
  abnormal: ['canceled', 'completed', 'after_sale'],
  after_sale: ['completed', 'canceled'],
  canceled: [],
};

/**
 * 订单服务（docs/05 + 负责人结算需求）：
 * - 下单：服务端查库定价 → 事务内扣款+建单+价格快照+流水；幂等键唯一兜底
 * - 结算：老板确认完成 = 事务内【校验归属/状态/打手 → 打手+分成% → 平台+抽成% → 结算记录 → 状态流转 → 日志】
 *   （分成比例读 `system_setting.platform_commission_rate`，默认 25% 抽成 = 打手 75%）
 * - 一个订单最多结算一次：order_settlement.order_id 唯一约束 + 订单行锁 + 状态检查 三重保证
 */
@Injectable()
export class OrderService implements OnApplicationBootstrap {
  private readonly logger = new Logger('Order');
  private sweepTimer: NodeJS.Timeout | null = null;

  constructor(
    @InjectRepository(Order) private readonly orderRepo: Repository<Order>,
    @InjectRepository(OrderSettlement) private readonly settlementRepo: Repository<OrderSettlement>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly settings: SystemSettingService,
    private readonly realtime: RealtimeGateway,
    private readonly level: LevelService,
    private readonly chat: ChatService,
    /** 分部接单权限（负责人 2026-10-04）：大厅/抢单/接单/派单/指定护航员全部走它，**每次实时查库** */
    private readonly divisionPerm: WorkerDivisionPermissionService,
    /**
     * 分部（负责人 2026-10-05）：**防误单**用 —— 建设中分部（瓦端/瓦手）的文案是「敬请期待」，
     * 若管理端误挂了商品，这里必须中文拒绝，而不是让老板付了余额才发现没人接单。
     */
    private readonly divisions: DivisionService,
    /**
     * 记住游戏 ID（负责人 2026-10-15「记住我的游戏 ID 这个也做」）：
     * 下单成功后**自动 upsert** 一条 `user_game_account`（客户端不需要额外调用来"保存"，只调 GET 回填）。
     * 写入是 **best-effort**：见 [rememberGameAccountBestEffort]。
     */
    private readonly gameAccounts: GameAccountService,
  ) {}

  /** 超时扫描（派单确认 + 待接单超时）：启动立即扫一次（覆盖停机窗口）+ 每 30s 周期（docs/05：条件 UPDATE 幂等，禁 Redis 锁双源） */
  onApplicationBootstrap(): void {
    const tick = () => {
      this.sweepExpiredDispatches().catch((e) => this.logger.warn(`派单超时扫描失败: ${(e as Error).message}`));
      this.sweepPendingTakeTimeout().catch((e) => this.logger.warn(`待接单超时扫描失败: ${(e as Error).message}`));
    };
    tick();
    this.sweepTimer = setInterval(tick, 30_000);
    // 进程退出时清理（非关键路径，Node 退出自然回收）
    this.sweepTimer.unref?.();
  }

  // ---------------- 下单 ----------------

  async createOrder(
    userId: string,
    dto: {
      productId: string;
      quantity: number;
      remark?: string;
      idempotencyKey: string;
      gameZone: string;
      gamePlayerId: string;
      contactPhone?: string;
      workerMode?: string;
      designatedWorkerId?: string;
    },
    meta: { ip: string; requestId: string },
  ) {
    // 幂等先行：同键已有订单直接返回（docs/06）
    const existing = await this.orderRepo.findOne({ where: { idempotencyKey: dto.idempotencyKey } });
    if (existing) {
      return this.orderView(existing, true);
    }
    const quantity = dto.quantity ?? 1;
    if (quantity < 1 || quantity > 99) {
      throw new BadRequestException('数量非法');
    }
    /**
     * 记住游戏 ID（负责人 2026-10-15）—— 「结果盒子」：事务回调里**只记值**，提交后再写库。
     *
     * 为什么要用盒子把值带出来、而不是在事务里直接写 `user_game_account`：
     * **写入发生在事务之外 → 任何失败都不可能回滚一笔已经提交的订单**。这正是
     * 「失败不得影响下单成功」这句话的**结构性**保证（不是靠多写几个 try/catch 去赌）。
     * 代价只是一次额外往返，而下单本来就是低频重事务，这点开销换"下单永远不会因为
     * 一个附加记账动作而失败"完全值得。
     */
    const rememberRef: {
      value?: { gameId: string; gamePlayerId: string | null; gameZone: string | null };
    } = {};
    try {
      const created = await this.dataSource.transaction(async (em) => {
        // 服务端查库真实价格（客户端 price 不可信）
        const product = await em.findOne(Product, { where: { id: dto.productId } });
        if (!product || product.status !== 1 || product.serviceStatus !== 1) {
          throw new BadRequestException('商品不存在或不可售');
        }
        // 建设中分部防误单（负责人 2026-10-05）：瓦端/瓦手 暂无商品且页面是「敬请期待」，
        // 万一管理端把商品误挂到建设中分部，必须在下单时空口拦住（中文拒绝），
        // 而不是先扣了余额再让老板发现没人接单。
        // 说明：下单接口**不接受客户端传 divisionId**（分部由商品归属决定，见下面 order.divisionId），
        // 所以这里校验的是「商品所属分部」，客户端无法绕过、也无法伪造。
        if (await this.divisions.isUnderConstruction(product.divisionId)) {
          throw new BadRequestException('该分部正在建设中，敬请期待');
        }
        // 指定护航员的分部隔离（负责人 2026-10-04，服务端权威，客户端不可信）：
        // 老板端选择器已按分部过滤，这里再兜一层 —— 直接调接口也**不可能**指定到别的分部的打手。
        if (dto.workerMode === 'designated' && dto.designatedWorkerId) {
          const designated = await em.findOne(Worker, { where: { id: String(dto.designatedWorkerId) } });
          if (!designated || designated.status !== 1 || designated.canTakeOrder !== 1) {
            throw new BadRequestException('指定的护航员不存在、已停用或暂无接单权限');
          }
          if (!(await this.divisionPerm.hasTakeOrder(designated.id, product.divisionId, em))) {
            const name = (await this.divisionPerm.divisionName(product.divisionId)) || '该';
            throw new BadRequestException(`指定的护航员暂无「${name}」分部的接单权限，请重新选择`);
          }
        }
        const total = product.price * quantity;
        // 扣款：行锁 + 余额校验（禁负余额）
        const wallet = await em.findOne(Wallet, { where: { userId }, lock: { mode: 'pessimistic_write' } });
        if (!wallet) {
          throw new NotFoundException('钱包不存在');
        }
        /**
         * 每周限购（负责人 2026-10-05，**服务端强制**）：
         * 位置刻意放在「钱包行锁之后、余额校验与扣款之前」——
         * 1) **拦在扣款前**：不满足限购时一分余额都不动，也不写流水/等级/快照/状态日志；
         * 2) **并发安全**：钱包行是同一用户的天然串行点（每个下单事务都要 `FOR UPDATE` 这一行），
         *    后到的事务会阻塞到前一个提交后才开始计数；计数本身再用锁定读（`FOR UPDATE`）强制
         *    读**最新已提交**数据（MySQL 默认 REPEATABLE READ 下，本次事务在拿到钱包锁之前已经
         *    读过 product 表，普通 SELECT 会走那时的旧快照，看不到并发事务刚插入的订单）。
         *    两层合起来 = 同一用户并发提交也绕不过去（实测见 2026-10-05 验收：并发 2 单只成功 1 单）。
         *    不用 Redis 锁：判定与扣款必须同一事务、同一数据源（docs/06 铁律）。
         */
        const weeklyLimit = Number(product.weeklyLimit ?? 0);
        /**
         * 口径开关（负责人 2026-10-05 任务③）：`weekly_limit_by_quantity`
         * 0 = 按订单条数（默认，行为与加列前逐字一致）/ 1 = 按件数 SUM(quantity)。
         * 只认 1，其余（NULL / 0 / 脏值）一律按"按条数"—— 与列 NOT NULL DEFAULT 0 同口径，
         * 且不会被"脏值恰好等于 1 的字符串"之类的情况骗到。
         */
        const weeklyByQuantity = Number(product.weeklyLimitByQuantity ?? 0) === 1;
        if (Number.isFinite(weeklyLimit) && weeklyLimit > 0) {
          const usedThisWeek = await this.countWeeklyOrders(em, userId, String(product.id), {
            forUpdate: true,
            byQuantity: weeklyByQuantity,
          });
          if (usedThisWeek >= weeklyLimit) {
            throw new BadRequestException(this.weeklyLimitMessage(weeklyLimit, usedThisWeek, weeklyByQuantity));
          }
        }
        if (wallet.balance < total) {
          throw new BadRequestException('余额不足');
        }
        await em.update(Wallet, wallet.id, { balance: wallet.balance - total });
        await this.insertTxn(em, {
          userId, changeType: 'order_pay', amount: -total,
          balanceBefore: wallet.balance, balanceAfter: wallet.balance - total,
          operatorType: 'user', operatorId: userId, source: 'client',
          reason: `下单扣款`, orderId: null, idempotencyKey: null, meta,
        });
        // 等级：累计实际消费 + 自动升级（只升不降，事务内行锁，docs/06 补充）
        await this.level.applySpendInTx(em, userId, total);

        const game = await em.findOne(Game, { where: { id: product.gameId } });
        const category = await em.findOne(Category, { where: { id: product.categoryId } });
        const order = await em.save(
          em.create(Order, {
            orderNo: this.generateOrderNo(),
            idempotencyKey: dto.idempotencyKey,
            userId,
            productId: product.id,
            gameId: product.gameId,
            categoryId: product.categoryId,
            // 分部（负责人 2026-10-03）：由商品归属决定，服务端权威，客户端不可指定
            divisionId: product.divisionId ?? null,
            quantity,
            unitPrice: product.price,
            totalAmount: total,
            status: 'pending_take',
            userRemark: dto.remark ?? null,
            // 负责人需求（2026-09-24）：下单必填游戏分区/游戏ID；打手抢单后才可见
            gameZone: dto.gameZone,
        contactPhone: dto.contactPhone ?? '',
        workerMode: dto.workerMode === 'designated' ? 'designated' : 'random',
        designatedWorkerId: dto.workerMode === 'designated' && dto.designatedWorkerId ? String(dto.designatedWorkerId) : null,
            gamePlayerId: dto.gamePlayerId.trim(),
            ip: meta.ip?.slice(0, 64) ?? null,
            requestId: meta.requestId?.slice(0, 64) ?? null,
          }),
        );
        await em.save(
          em.create(OrderPriceSnapshot, {
            orderId: order.id,
            productId: product.id,
            productName: product.name,
            gameName: game?.name ?? '',
            categoryName: category?.name ?? '',
            unitPrice: product.price,
            quantity,
            totalAmount: total,
            priceUnit: product.priceUnit,
            estimateDurationMin: product.estimateDurationMin,
            gameZone: dto.gameZone,
        contactPhone: dto.contactPhone ?? '',
        workerMode: dto.workerMode === 'designated' ? 'designated' : 'random',
        designatedWorkerId: dto.workerMode === 'designated' && dto.designatedWorkerId ? String(dto.designatedWorkerId) : null,
            gamePlayerId: dto.gamePlayerId.trim(),
          }),
        );
        await this.logStatus(em, order.id, '', 'pending_take', 'user', userId, 'client', meta, '创建订单');
        // 记住游戏 ID：订单本身就是"这个老板在这个游戏用什么号"的权威来源（值已校验并落库），
        // 这里只**记下值**，真正的 upsert 在事务提交之后执行（见下方 rememberGameAccountBestEffort）
        rememberRef.value = {
          gameId: String(product.gameId),
          gamePlayerId: order.gamePlayerId,
          gameZone: order.gameZone,
        };
    // 实时推送：广播"有新单"，工作端接单大厅立即刷新（负责人 2026-10-04 反馈：此前要大退才看得到）
    this.realtime.emitToAll('order:new', { orderId: order.id });
        // 创建响应仅发给下单老板本人 → 可含游戏分区/ID（大厅/他人通道不返回这两个字段）
        return { ...this.orderView(order), gameZone: order.gameZone, gamePlayerId: order.gamePlayerId };
      });
      // 记住游戏 ID（best-effort）：**事务已提交**，这里写失败只留一行 warn，绝不影响下单结果
      await this.rememberGameAccountBestEffort(userId, rememberRef.value);
      return created;
    } catch (e) {
      if (e instanceof QueryFailedError && (e as unknown as { code?: string }).code === 'ER_DUP_ENTRY') {
        const existing = await this.orderRepo.findOne({ where: { idempotencyKey: dto.idempotencyKey } });
        if (existing) {
          return { ...this.orderView(existing, true), gameZone: existing.gameZone, gamePlayerId: existing.gamePlayerId };
        }
      }
      throw e;
    }
  }

  // ---------------- 记住游戏 ID（负责人 2026-10-15） ----------------

  /**
   * 下单成功后自动 upsert 一条 `user_game_account`（**best-effort，失败不得影响下单**）
   *
   * 调用点在 [createOrder] **事务提交之后**（不是事务内）—— 这是"失败隔离"的关键：
   * 事务内的任何语句失败都可能连带 COMMIT 一起挂掉（连接级错误、锁等待超时等），
   * 而事务外的写入**在结构上**不可能影响一笔已经提交的订单。
   *
   * 三层失败隔离，缺一不可：
   * ① **位置**：事务外（上面那条）；
   * ② **异常**：`GameAccountService.rememberBestEffort` 内部自行 try/catch + 告警，
   *    这里再包一层（防御未来有人改坏内层）——**任何异常都不许冒泡出去**；
   * ③ **幂等**：`UK_uga_user_game (user_id, game_id)` + `ON DUPLICATE KEY UPDATE` ——
   *    即使重复执行（幂等重放、重试），也不会产生第二行。
   *
   * 代价：这次写入失败时"这次没记住"，下次在同一游戏下单会再写一次（幂等，自愈）。
   * 收益：下单主链路的成功率**一个字都没变** —— 附加记账永远不许拖垮交易。
   *
   * @param remembered 事务内生成的订单值（`undefined` = 事务未成功，直接跳过）
   */
  private async rememberGameAccountBestEffort(
    userId: string,
    remembered?: { gameId: string; gamePlayerId: string | null; gameZone: string | null },
  ): Promise<void> {
    if (!remembered) return;
    try {
      await this.gameAccounts.rememberBestEffort(userId, remembered);
    } catch (e) {
      this.logger.warn(`记住游戏 ID 失败（不影响下单成功）user=${userId} game=${remembered.gameId}: ${(e as Error).message}`);
    }
  }

  // ---------------- 每周限购（负责人 2026-10-05） ----------------

  /**
   * 统计「最近 7 天该用户对该商品」的**未取消订单数 / 件数**（口径见文件顶部 WEEKLY_LIMIT_* 注释）。
   *
   * @param runner 事务 EntityManager（下单路径）或 DataSource（只读查询）
   * @param opts.forUpdate 下单路径必须传 true —— 锁定读强制读**最新已提交**数据，
   *   否则并发事务在同一快照下都会数到旧值（详见 createOrder 内的调用点注释）。
   * @param opts.byQuantity true = 按件数 SUM(quantity)；缺省/ false = 按订单条数 COUNT(1)（默认口径）。
   *   两种口径共用同一条 SQL 模板，**并发安全与锁行为完全一致**（锁定读的粒度、时机都没变）。
   */
  private async countWeeklyOrders(
    runner: { query: (sql: string, parameters?: unknown[]) => Promise<unknown> },
    userId: string,
    productId: string,
    opts: { forUpdate?: boolean; byQuantity?: boolean } = {},
  ): Promise<number> {
    const rows = (await runner.query(
      `${weeklyLimitCountSql(opts.byQuantity === true)}${opts.forUpdate ? ' FOR UPDATE' : ''}`,
      [userId, productId],
    )) as Array<{ c: number | string }>;
    return Number(rows[0]?.c ?? 0);
  }

  /**
   * 触发限购时的中文 400 文案（**具体可验证**：规则、已下单数/已购件数、下一步动作都写清；
   * 客户端直接展示，不自己拼）。口径不同 → 量词与动词都不同（「已下单 2 单」/「已购 3 件」），
   * 老板一眼能看出这个商品是按单算还是按件算。
   */
  private weeklyLimitMessage(limit: number, used: number, byQuantity: boolean): string {
    const { unit, verb } = weeklyLimitUnit(byQuantity);
    return `该商品每位用户每周限购 ${limit} ${unit}，你本周${verb} ${used} ${unit}，请下周再来`;
  }

  /**
   * 每周限购配额查询（老板端下单页/商品详情页的提示来源）
   *
   * 客户端**不硬编码任何规则**：限购数、已下单数、剩余数、提示文案全部由服务端给出，
   * 客户端只负责把 `limitText` / `quotaText` 原样显示。
   * 不限购（weeklyLimit 为 NULL/0）时返回空文案，客户端据此不显示这一行。
   *
   * 口径（任务③）：读商品 `weekly_limit_by_quantity`，`orderedCount` / `remaining` /
   * `limitText` / `quotaText` **四者一起切换**，不会出现"数字按件、文案按单"。额外回带
   * `byQuantity` 供管理端排查/客户端将来扩展，客户端不用它做判定。
   */
  async weeklyQuota(userId: string, productId: string) {
    if (!/^\d+$/.test(String(productId ?? ''))) {
      throw new BadRequestException('商品参数不合法');
    }
    const product = await this.dataSource
      .getRepository(Product)
      .findOne({ where: { id: String(productId) }, select: { id: true, weeklyLimit: true, weeklyLimitByQuantity: true } });
    if (!product) {
      throw new NotFoundException('商品不存在');
    }
    const limit = Number(product.weeklyLimit ?? 0);
    const byQuantity = Number(product.weeklyLimitByQuantity ?? 0) === 1;
    if (!Number.isFinite(limit) || limit <= 0) {
      return {
        productId: String(product.id),
        weeklyLimit: 0,
        orderedCount: 0,
        remaining: null as number | null,
        byQuantity: byQuantity ? 1 : 0,
        limitText: '',
        quotaText: '',
      };
    }
    const orderedCount = await this.countWeeklyOrders(this.dataSource, userId, String(product.id), { byQuantity });
    const remaining = Math.max(0, limit - orderedCount);
    const { unit, verb } = weeklyLimitUnit(byQuantity);
    return {
      productId: String(product.id),
      weeklyLimit: limit,
      orderedCount,
      remaining,
      byQuantity: byQuantity ? 1 : 0,
      limitText: `每周限购 ${limit} ${unit}`,
      quotaText: remaining > 0 ? `本周还可${byQuantity ? '购' : '下'} ${remaining} ${unit}` : '本周额度已用完，下周再来',
      // `verb` 目前只用在拦截文案里；留一个显式字段避免将来有人用 orderedCount 拼文案时又硬编码"单/件"
      orderedText: `本周${verb} ${orderedCount} ${unit}`,
    };
  }

  // ---------------- 订单完成（所有 completed 路径的唯一收口） ----------------

  /**
   * 老板确认完成 + 正式结算（核心，幂等+原子；分成比例读 `system_setting.platform_commission_rate`，默认抽成 25%）。
   *
   * 负责人 2026-10-04 报障「单子完成了还显示进行中并且能联系打手」→ 会话收尾**不能只挂在这一条路径上**，
   * 因此把「订单置为 completed」的全部逻辑收口到 [completeOrderTx]（同事务），
   * 本方法与 [adminForceComplete]、[adminHandleAppeal]（售后驳回还原 completed）共用同一收口。
   */
  async confirmAndSettle(userId: string, orderId: string, meta: { ip: string; requestId: string }) {
    // 事务：结算 + 直聊会话收尾（确认完成 = 自动结束并删除和打手的对话）
    const outcome = await this.dataSource.transaction((em) =>
      this.completeOrderTx(
        em,
        // 归属+行锁：查询条件含 user_id，伪造 orderId 直接 404（docs/04）
        { id: orderId, userId },
        ['pending_confirm'],
        meta,
        { operatorType: 'user', operatorId: userId, source: 'client', remark: '老板确认完成，正式结算' },
      ),
    );

    // 事务提交后推事件：会话被删除 → conv:removed（两端会话列表立即移除）；
    // 共用会话保留（该对仍有未完成订单）→ 保持 open、不推任何会话事件
    this.emitDirectChatEvent(outcome.direct, orderId, 'order_completed');

    // 对外返回结算视图（不含内部会话字段）
    return this.settlementView(outcome);
  }

  /**
   * 管理端强制完成（负责人 2026-10-04 报障的「非老板确认」完成路径）。
   *
   * - 合法迁移：pending_confirm → completed（docs/05）、abnormal → completed、after_sale → completed
   * - 未结算 → 与老板确认完全一致的服务端结算（比例读配置，金额按订单快照，客户端不可传）
   * - 已结算（如 after_sale 还原或重复强制）→ 只补状态流转，**绝不二次结算 / 不重复累加销量与打手统计**
   * - 同一事务内做「老板↔打手」直聊收尾（方案①：还有未完成订单 → 保持 open；最后一单 → 删除），
   *   提交后仅在删除时推 conv:removed
   */
  async adminForceComplete(
    adminUserId: string,
    orderId: string,
    remark: string,
    meta: { ip: string; requestId: string },
  ) {
    const outcome = await this.dataSource.transaction((em) =>
      this.completeOrderTx(
        em,
        { id: orderId },
        ['pending_confirm', 'abnormal', 'after_sale'],
        meta,
        {
          operatorType: 'admin',
          operatorId: adminUserId,
          source: 'admin',
          remark: `管理员强制完成：${remark || '-'}`,
        },
        { allowAlreadySettled: true },
      ),
    );
    this.emitDirectChatEvent(outcome.direct, orderId, 'order_completed_by_admin');
    this.logger.log(`管理员强制完成 orderNo=${outcome.orderNo} admin=${adminUserId}`);
    return this.settlementView(outcome);
  }

  /**
   * 订单 → completed 的**唯一收口**（同一事务内完成，禁绕过）：
   * 行锁取单 → 合法迁移校验 → 按生效配置分账结算（未结算时；含唯一结算记录 + 销量 + 打手统计）
   * → 状态流转 + order_status_log + WS order:update → 「老板↔打手」直聊收尾
   * （方案①：该对还有其它未完成订单 → 会话保持 open 原样不动；最后一单结束 → 结束并删除）。
   *
   * 返回值中的 `direct` 交由调用方在**事务提交后**推 conv:removed
   * （不在事务内推，避免客户端回查时数据尚未提交）。
   */
  private async completeOrderTx(
    em: EntityManager,
    where: { id: string; userId?: string },
    allowedFrom: OrderStatus[],
    meta: { ip: string; requestId: string },
    actor: { operatorType: 'user' | 'admin' | 'system'; operatorId: string | null; source: 'client' | 'admin' | 'system'; remark: string },
    opts: { allowAlreadySettled?: boolean } = {},
  ): Promise<OrderCompletion> {
    const order = await em.findOne(Order, { where, lock: { mode: 'pessimistic_write' } });
    if (!order) {
      throw new NotFoundException('订单不存在');
    }
    this.assertStatus(order, allowedFrom, '当前状态不允许完成订单');
    if (!order.workerId) {
      throw new BadRequestException('订单无接单打手，无法结算');
    }
    // order.workerId 是 worker 档案 id，需映射 user_id（钱包/会话/WS 通道都用 user_id）
    const workerProfile = await em.findOne(Worker, { where: { id: order.workerId } });
    if (!workerProfile || workerProfile.status !== 1) {
      throw new BadRequestException('打手档案不存在或已停用');
    }

    // 三重防重复结算：状态检查（上）+ 结算记录唯一约束 + 行锁串行化
    const existing = await em.findOne(OrderSettlement, { where: { orderId: order.id } });
    if (existing && !opts.allowAlreadySettled) {
      throw new BadRequestException('订单已结算，请勿重复操作');
    }

    const total = order.totalAmount;
    let settlement = existing;
    // 生效抽成比例：读 system_setting（唯一真相，管理端可改，改完下一单立即生效；不缓存见 service 注释）
    const commissionRate = await this.settings.platformCommissionRate();
    const split = splitAmount(total, commissionRate);
    if (!existing) {
      // 服务器分账（按订单快照金额，绝不用商品当前价格；金额支持小数 → 四舍五入到 0.01）
      const { workerAmount, platformAmount, workerPercentage, platformPercentage } = split;

      // 打手 +workerPercentage%（工作端自己的钱包）
      const workerWallet = await em.findOne(Wallet, { where: { userId: workerProfile.userId }, lock: { mode: 'pessimistic_write' } });
      if (!workerWallet) {
        throw new BadRequestException('打手钱包不存在');
      }
      await em.update(Wallet, workerWallet.id, { balance: workerWallet.balance + workerAmount });
      await this.insertTxn(em, {
        userId: workerProfile.userId, changeType: 'order_settlement', amount: workerAmount,
        balanceBefore: workerWallet.balance, balanceAfter: workerWallet.balance + workerAmount,
        operatorType: actor.operatorType, operatorId: actor.operatorId, source: 'order_settlement',
        reason: `订单完成结算 ${workerPercentage}%`, orderId: order.id, idempotencyKey: `settle:${order.id}`, meta,
      });

      // 平台 +platformPercentage%（平台账户钱包）
      const platformUser = await em.findOne(User, { where: { uid: 'PLATFORM1' } });
      if (!platformUser) {
        throw new BadRequestException('平台账户不存在');
      }
      const platformWallet = await em.findOne(Wallet, { where: { userId: platformUser.id }, lock: { mode: 'pessimistic_write' } });
      if (!platformWallet) {
        throw new BadRequestException('平台钱包不存在');
      }
      await em.update(Wallet, platformWallet.id, { balance: platformWallet.balance + platformAmount });
      await this.insertTxn(em, {
        userId: platformUser.id, changeType: 'platform_commission', amount: platformAmount,
        balanceBefore: platformWallet.balance, balanceAfter: platformWallet.balance + platformAmount,
        operatorType: 'system', operatorId: null, source: 'order_settlement',
        reason: `订单平台抽成 ${platformPercentage}%`, orderId: order.id, idempotencyKey: `platform:${order.id}`, meta,
      });

      // 唯一结算记录（数据库级幂等兜底）：比例按当时生效配置落库留痕（历史单据可回溯）
      settlement = await em.save(
        em.create(OrderSettlement, {
          settlementNo: this.generateSettlementNo(),
          orderId: order.id,
          orderAmount: total,
          workerId: order.workerId,
          workerAmount,
          workerPercentage,
          platformAmount,
          platformPercentage,
          requestId: meta.requestId?.slice(0, 64) ?? null,
        }),
      );

      // 销量累加 + 打手统计（M7，事务内同一数据源；已结算单不重复累加）
      await em.query('UPDATE product SET sales_count = sales_count + ? WHERE id = ?', [order.quantity, order.productId]);
      await em.query(
        `INSERT INTO worker_stats (worker_id, total_orders, completed_orders, total_amount)
         VALUES (?, 1, 1, ?)
         ON DUPLICATE KEY UPDATE total_orders = total_orders + 1, completed_orders = completed_orders + 1, total_amount = total_amount + ?`,
        [order.workerId, total, total],
      );
      this.logger.log(
        `订单结算成功 orderNo=${order.orderNo} settlement=${settlement.settlementNo} 抽成=${platformPercentage}% worker=${workerAmount} platform=${platformAmount}`,
      );
    } else {
      this.logger.log(`订单已完成结算，仅补状态流转 orderNo=${order.orderNo} settlement=${settlement?.settlementNo}`);
    }

    // 状态流转 + 状态日志 + 两端实时（both 老板端与工作端订单列表立即变「已完成」）
    await em.update(Order, order.id, { status: 'completed' });
    await this.logStatus(em, order.id, order.status, 'completed', actor.operatorType, actor.operatorId, actor.source, meta, actor.remark);
    this.realtime.emitToUser(order.userId, 'order:update', { orderId: order.id, status: 'completed' });
    this.realtime.emitToUser(workerProfile.userId, 'order:update', { orderId: order.id, status: 'completed' });

    // 「老板↔打手」直聊收尾（同事务）：最后一单结束 → 删除；该对仍有其它未完成订单 → 会话保持 open 不动
    const direct = await this.settleDirectChatTx(em, order, workerProfile.userId);

    return {
      orderNo: order.orderNo,
      settlementNo: settlement?.settlementNo ?? '',
      orderAmount: settlement ? Number(settlement.orderAmount) : total,
      workerAmount: settlement ? Number(settlement.workerAmount) : 0,
      // 已结算单回读落库比例（历史单据按当时的配置），未结算路径用本次生效配置
      workerPercentage: settlement ? Number(settlement.workerPercentage) : split.workerPercentage,
      platformAmount: settlement ? Number(settlement.platformAmount) : 0,
      platformPercentage: settlement ? Number(settlement.platformPercentage) : split.platformPercentage,
      settledAt: settlement?.createdAt ?? new Date(),
      direct,
    };
  }

  /**
   * 直聊会话收尾（同事务，**完成**路径）：该对还有其它未完成订单 → 会话保持 `open` 原样不动（方案①）；
   * 最后一单结束 → 结束并删除。会话保留时补一条系统消息留痕（订单节点）；会话已删除则不再写（写了也会随会话一起删）。
   */
  private async settleDirectChatTx(em: EntityManager, order: Order, workerUserId: string): Promise<DirectOutcome> {
    const direct = await this.chat.settleWorkerDirectTx(em, order.userId, workerUserId, order.id);
    if (direct && !direct.removed) {
      await this.chat.appendSystemMessageTx(
        em,
        direct.conversationId,
        `订单已完成结算 · 单号 ${this.shortOrderNo(order.orderNo)}`,
      );
    }
    if (!direct) return null;
    return { ...direct, bossUserId: String(order.userId), workerUserId: String(workerUserId) };
  }

  /**
   * **取消**订单（终态 canceled）后的直聊会话收尾（同一事务内，负责人 2026-10-04 方案①：
   * 「凡把订单置 canceled 的路径，都按同一规则处理直聊会话」）。
   *
   * 规则与完成路径**完全一致**（同一 `settleWorkerDirectTx`）：
   * - 该 (老板, 打手) 对还有其它未完成订单 → 共用会话**保持 open 原样不动**（不 closed、不删除、不推事件）
   * - 没有其它未完成订单（最后一单也结束）→ 物理删除会话，调用方事务提交后推 conv:removed
   *
   * **不动会话的取消路径**：订单没有接单打手（`worker_id IS NULL`）时不存在 (老板, 打手) 对
   * → 直接返回 null，不查不删（老板取消待接单、待接单超时自动取消退款都属于这一类）。
   */
  private async settleCanceledDirectChatTx(em: EntityManager, order: Order): Promise<DirectOutcome> {
    if (!order.workerId) return null;
    const workerProfile = await em.findOne(Worker, { where: { id: order.workerId } });
    if (!workerProfile) return null;
    const direct = await this.chat.settleWorkerDirectTx(em, order.userId, workerProfile.userId, order.id);
    if (!direct) return null;
    return { ...direct, bossUserId: String(order.userId), workerUserId: String(workerProfile.userId) };
  }

  /**
   * 只清理**孤儿**直聊会话（用于「申诉驳回还原 completed / abnormal」这类**非新的订单结束事件**的置回路径）：
   * 复用 [settleWorkerDirectTx] 的方案①语义 —— 同一对老板/打手若还有其它未完成订单正在使用该会话，
   * 会话**保持 open 原样不动**（那单还在服务，误置 closed 会让两端输入栏置灰）；只有孤儿会话才结束并删除。
   * 与完成/取消路径的唯一差别：**不补系统消息**（驳回不是一次新的完成结算事件）。
   */
  private async settleOrphanDirectChatTx(em: EntityManager, order: Order, workerUserId: string): Promise<DirectOutcome> {
    const direct = await this.chat.settleWorkerDirectTx(em, order.userId, workerUserId, order.id);
    if (!direct) return null;
    return { ...direct, bossUserId: String(order.userId), workerUserId: String(workerUserId) };
  }

  /**
   * 事务提交后推会话事件（方案①）：
   * - 会话被删除（最后一单结束）→ 两端推 `conv:removed`（列表立即移除该会话）
   * - 共用会话被保留（该对仍有未完成订单）→ **不推任何会话事件**（会话仍是 open，客户端无需变更；
   *   旧语义的 `chat:closed` 会让客户端把输入栏置灰，正是本次修复的 bug）
   *
   * 公开给退款审批复用（负责人 2026-10-04）：退款审批通过 = 订单置 canceled 的另一条路径，
   * 会话收尾规则必须与其它取消路径完全一致。
   */
  emitDirectChatEvent(direct: DirectOutcome, orderId: string, reason: string) {
    if (!direct) return;
    if (!direct.removed) {
      this.logger.log(
        `订单收尾(${reason}) → 直聊会话保留（该对仍有未完成订单，保持 open，不推会话事件） conv=${direct.conversationId} orderId=${orderId}`,
      );
      return;
    }
    const payload = { conversationId: direct.conversationId, orderId: String(orderId), reason };
    this.realtime.emitToUser(direct.bossUserId, 'conv:removed', payload);
    this.realtime.emitToUser(direct.workerUserId, 'conv:removed', payload);
    this.logger.log(
      `订单收尾(${reason}) → 直聊会话已结束并删除 conv=${direct.conversationId} orderId=${orderId}`,
    );
  }

  /** 对外结算视图（不含内部会话字段） */
  private settlementView(outcome: OrderCompletion) {
    return {
      settlementNo: outcome.settlementNo,
      orderAmount: outcome.orderAmount,
      workerAmount: outcome.workerAmount,
      workerPercentage: outcome.workerPercentage,
      platformAmount: outcome.platformAmount,
      platformPercentage: outcome.platformPercentage,
      settledAt: outcome.settledAt,
    };
  }

  // ---------------- 取消（全额退款） ----------------

  /**
   * 老板取消（仅待接单状态）：全额退款 + 关闭订单；
   * 同一事务内按方案①收尾直聊会话（待接单订单无接单打手 → 该对不存在，实际不动任何会话）。
   */
  async cancelByUser(userId: string, orderId: string, reason: string, meta: { ip: string; requestId: string }) {
    let direct: DirectOutcome = null;
    const result = await this.dataSource.transaction(async (em) => {
      const order = await em.findOne(Order, { where: { id: orderId, userId }, lock: { mode: 'pessimistic_write' } });
      if (!order) {
        throw new NotFoundException('订单不存在');
      }
      if (order.status !== 'pending_take') {
        throw new BadRequestException('仅待接单状态可取消');
      }
      await this.refundAndClose(em, order, 'user', reason, meta);
      direct = await this.settleCanceledDirectChatTx(em, order);
      return { ok: true };
    });
    this.emitDirectChatEvent(direct, orderId, 'order_canceled_by_user');
    return result;
  }

  /**
   * 管理端取消（待接单/待派单/已接单/进行中都可能，**可能已有接单打手**）：
   * 全额退款 + 关闭订单 + 同一事务内按方案①收尾直聊会话
   * （无其它未完成订单 → 删除并推 conv:removed；该对还有另一单在服务 → 会话保持 open 不动）。
   */
  async cancelByAdmin(adminUserId: string, orderId: string, reason: string, meta: { ip: string; requestId: string }) {
    let direct: DirectOutcome = null;
    const result = await this.dataSource.transaction(async (em) => {
      const order = await em.findOne(Order, { where: { id: orderId }, lock: { mode: 'pessimistic_write' } });
      if (!order) {
        throw new NotFoundException('订单不存在');
      }
      if (['completed', 'canceled', 'after_sale'].includes(order.status)) {
        throw new BadRequestException('该状态订单不可取消');
      }
      await this.refundAndClose(em, order, 'admin', reason, meta);
      direct = await this.settleCanceledDirectChatTx(em, order);
      return { ok: true };
    });
    this.emitDirectChatEvent(direct, orderId, 'order_canceled_by_admin');
    return result;
  }

  /** 退款（order_refund）+ 关闭订单（docs/06：退款与状态同一事务） */
  private async refundAndClose(em: EntityManager, order: Order, by: string, reason: string, meta: { ip: string; requestId: string }) {
    const wallet = await em.findOne(Wallet, { where: { userId: order.userId }, lock: { mode: 'pessimistic_write' } });
    if (wallet) {
      await em.update(Wallet, wallet.id, { balance: wallet.balance + order.totalAmount });
      await this.insertTxn(em, {
        userId: order.userId, changeType: 'order_refund', amount: order.totalAmount,
        balanceBefore: wallet.balance, balanceAfter: wallet.balance + order.totalAmount,
        operatorType: by, operatorId: by === 'user' ? order.userId : null, source: by === 'user' ? 'client' : 'admin',
        reason: `取消订单退款：${reason || '-'}`, orderId: order.id, idempotencyKey: `refund:${order.id}`, meta,
      });
    }
    await em.update(Order, order.id, { status: 'canceled', cancelReason: reason ?? null, cancelBy: by });
    // 退款回退累计消费（等级不自动降级，docs/06 补充）
    await this.level.refundSpentInTx(em, order.userId, order.totalAmount);
    await this.logStatus(em, order.id, order.status, 'canceled', by, by === 'user' ? order.userId : null, by === 'user' ? 'client' : 'admin', meta, `取消并全额退款`);
    this.realtime.emitToUser(order.userId, 'order:update', { orderId: order.id, status: 'canceled' });
    this.realtime.emitToAll('order:new', { orderId: order.id, status: 'canceled' });
  }

  // ---------------- 工作端：抢单/开始/提交 ----------------

  async grab(workerUserId: string, orderId: string, meta: { ip: string; requestId: string }) {
    // 接单权限实时查库（docs/04 铁律，前端隐藏无效）
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { userId: workerUserId } });
    if (!worker || worker.status !== 1 || worker.canTakeOrder !== 1) {
      throw new ForbiddenException('无接单权限');
    }
    // 分部隔离（负责人 2026-10-04）：抢单必须**该分部**有接单权限（服务端判定，不靠前端隐藏按钮）。
    // 订单的 division_id 一旦建单就不再变化（由商品归属决定），所以事务外先读、再进事务做条件更新是安全的。
    const target = await this.orderRepo.findOne({ where: { id: orderId }, select: ['id', 'divisionId'] });
    if (!target) {
      throw new NotFoundException('订单不存在');
    }
    await this.divisionPerm.assertTakeOrder(
      worker.id,
      target.divisionId,
      (name) => `你暂无「${name}」分部的接单权限，无法抢该分部的订单`,
    );
    return this.dataSource.transaction(async (em) => {
      // 条件更新防并发抢单（docs/05：判 affectedRows）——只有真正抢单成功的这次调用会走到建群
      const result = await em
        .createQueryBuilder()
        .update(Order)
        .set({ workerId: worker.id, status: 'taken' })
        .where('id = :orderId AND status = :status AND worker_id IS NULL', { orderId, status: 'pending_take' })
        .execute();
      if (!result.affected) {
        throw new BadRequestException('手慢了，订单已被抢走或不可接');
      }
      const order = await em.findOne(Order, { where: { id: orderId } });
      if (!order) throw new NotFoundException('订单不存在');
      await this.logStatus(em, orderId, 'pending_take', 'taken', 'worker', workerUserId, 'client', meta, '抢单成功');
      // 老板端订单列表立即变"已接单"；其它打手端大厅立即移除该单
      this.realtime.emitToUser(order.userId, 'order:update', { orderId, status: 'taken' });
      this.realtime.emitToUser(worker.userId, 'order:update', { orderId, status: 'taken' });
      this.realtime.emitToAll('order:new', { orderId, status: 'taken' });
      // 抢单成功 = 订单状态已变已接单 → 同一事务内建立「老板 ↔ 打手」一对一沟通会话（群组功能已下掉）
      // 并写入系统消息（负责人 2026-10-04：订单关键节点在直聊里出现「护航员已接单 · 单号 0087」）
      await this.chat.appendOrderSystemMessageTx(
        em,
        order.userId,
        worker.userId,
        `护航员已接单 · 单号 ${this.shortOrderNo(order.orderNo)}`,
      );
      return { ok: true, orderId };
    });
  }

  async start(workerUserId: string, orderId: string, meta: { ip: string; requestId: string }) {
    return this.transitByWorker(workerUserId, orderId, ['taken'], 'in_progress', '开始服务', meta);
  }

  async submit(workerUserId: string, orderId: string, meta: { ip: string; requestId: string }) {
    return this.transitByWorker(workerUserId, orderId, ['in_progress'], 'pending_confirm', '提交完成，等待老板确认', meta);
  }

  private async transitByWorker(
    workerUserId: string,
    orderId: string,
    from: OrderStatus[],
    to: OrderStatus,
    remark: string,
    meta: { ip: string; requestId: string },
  ) {
    return this.dataSource.transaction(async (em) => {
      const worker = await em.findOne(Worker, { where: { userId: workerUserId, status: 1 } });
      if (!worker) {
        throw new ForbiddenException('工作端不可用');
      }
      const order = await em.findOne(Order, { where: { id: orderId, workerId: worker.id }, lock: { mode: 'pessimistic_write' } });
      if (!order) {
        throw new NotFoundException('订单不存在或不属于你');
      }
      this.assertStatus(order, from, '当前状态不允许该操作');
      await em.update(Order, order.id, { status: to });
      await this.logStatus(em, order.id, order.status, to, 'worker', workerUserId, 'client', meta, remark);
    // 状态流转实时推送（开始服务 → 进行中 / 提交 → 待确认 等）
    this.realtime.emitToUser(order.userId, 'order:update', { orderId: order.id, status: to });
    this.realtime.emitToUser(order.userId, 'order:status', { orderId: order.id, status: to });
      // 系统消息（负责人 2026-10-04）：老板↔打手直聊里记录「已开始 / 已提交待确认」
      const sysText = to === 'in_progress'
        ? `护航员已开始服务 · 单号 ${this.shortOrderNo(order.orderNo)}`
        : to === 'pending_confirm'
          ? `护航员已提交完成，等待老板确认 · 单号 ${this.shortOrderNo(order.orderNo)}`
          : '';
      if (sysText) await this.chat.appendOrderSystemMessageTx(em, order.userId, worker.userId, sysText);
      return { ok: true };
    });
  }

  // ---------------- 派单（阶段16补：admin 派单 → worker 确认/拒绝 → 超时回大厅，docs/05） ----------------

  /**
   * 管理端派单：待接单 → pending_dispatch（条件 UPDATE 判 affectedRows 防并发重复派单）
   * 校验：worker 存在/启用/有接单权限/未超同时进行上限（system_setting 可配）
   */
  async adminDispatch(adminUserId: string, orderId: string, workerId: string, meta: { ip: string; requestId: string }) {
    const timeoutMin = await this.settings.value('dispatch_confirm_timeout_min', 5);
    const maxConcurrent = await this.settings.value('worker_max_concurrent_orders', 3);
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { id: workerId } });
    if (!worker || worker.status !== 1 || worker.canTakeOrder !== 1) {
      throw new BadRequestException('工作端不存在或未启用/无接单权限');
    }
    // 分部隔离（负责人 2026-10-04）：派单前校验目标打手**该分部**有接单权限，
    // 否则派过去他也接不了（确认接口会拒绝），白白占住订单 5 分钟。
    const target = await this.orderRepo.findOne({ where: { id: orderId }, select: ['id', 'divisionId'] });
    if (target && !(await this.divisionPerm.hasTakeOrder(worker.id, target.divisionId))) {
      const name = (await this.divisionPerm.divisionName(target.divisionId)) || '该';
      throw new BadRequestException(`该打手暂无「${name}」分部的接单权限，不可派此单`);
    }
    // 同时进行上限：pending_dispatch + taken + in_progress + pending_confirm
    const activeCount = await this.orderRepo
      .createQueryBuilder('o')
      .where('o.worker_id = :workerId AND o.status IN (:...statuses)', { workerId, statuses: ['pending_dispatch', 'taken', 'in_progress', 'pending_confirm'] })
      .getCount();
    if (activeCount >= maxConcurrent) {
      throw new BadRequestException(`该打手同时进行订单已达上限（${maxConcurrent} 单）`);
    }
    const result = await this.dataSource.transaction(async (em) => {
      // 过期时间用数据库时钟计算（NOW(3)），与超时判定同源，彻底规避应用/数据库时区差
      const res = await em
        .createQueryBuilder()
        .update(Order)
        .set({
          status: 'pending_dispatch',
          workerId,
          dispatchedAt: () => 'NOW(3)',
          dispatchExpireAt: () => `DATE_ADD(NOW(3), INTERVAL ${Number(timeoutMin)} MINUTE)`,
        })
        .where('id = :orderId AND status = :status AND worker_id IS NULL', { orderId, status: 'pending_take' })
        .execute();
      if (!res.affected) {
        throw new BadRequestException('派单失败：订单已被接走或状态不允许派单');
      }
      const order = await em.findOneOrFail(Order, { where: { id: orderId } });
      await this.logStatus(em, orderId, 'pending_take', 'pending_dispatch', 'admin', adminUserId, 'admin', meta, `派单给工作端#${worker.workerNo}`);
      return order;
    });
    const expireAt = result.dispatchExpireAt;
    // WS 通知目标打手（docs/07 dispatch:new）
    const expireAtIso = expireAt?.toISOString() ?? null;
    this.realtime.emitToUser(worker.userId, 'dispatch:new', {
      orderId: result.id,
      orderNo: result.orderNo,
      productId: result.productId,
      totalAmount: result.totalAmount,
      // 派单对象已归属 → 可携带老板游戏信息（大厅通道不携带）
      gameZone: result.gameZone,
      gamePlayerId: result.gamePlayerId,
      expireAt: expireAtIso,
    });
    this.logger.log(`派单成功 order=${result.orderNo} worker=${worker.workerNo} expire=${expireAtIso ?? '-'}`);
    return { ok: true, orderId: result.id, expireAt: expireAtIso };
  }

  /** 打手确认派单：pending_dispatch → taken（仅被派对象本人在有效期内） */
  async workerAccept(workerUserId: string, orderId: string, meta: { ip: string; requestId: string }) {
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { userId: workerUserId, status: 1 } });
    if (!worker) throw new ForbiddenException('工作端不可用');
    // 分部隔离（负责人 2026-10-04）：确认派单也要**该分部**有接单权限（与抢单同口径，实时查库）。
    // 订单不属于自己时这里查不到 → 交给下面的条件更新给出"派单已超时、已被撤销或不属于你"。
    const dispatched = await this.orderRepo.findOne({
      where: { id: orderId, workerId: worker.id },
      select: ['id', 'divisionId'],
    });
    if (dispatched) {
      await this.divisionPerm.assertTakeOrder(
        worker.id,
        dispatched.divisionId,
        (name) => `你暂无「${name}」分部的接单权限，无法确认该派单`,
      );
    }
    return this.dataSource.transaction(async (em) => {
      const res = await em
        .createQueryBuilder()
        .update(Order)
        .set({ status: 'taken', dispatchExpireAt: null })
        .where('id = :orderId AND status = :status AND worker_id = :workerId AND dispatch_expire_at > NOW(3)', {
          orderId, status: 'pending_dispatch', workerId: worker.id,
        })
        .execute();
      if (!res.affected) {
        throw new BadRequestException('确认失败：派单已超时、已被撤销或不属于你');
      }
      const order = await em.findOne(Order, { where: { id: orderId } });
      if (!order) throw new NotFoundException('订单不存在');
      await this.logStatus(em, orderId, 'pending_dispatch', 'taken', 'worker', workerUserId, 'client', meta, '确认派单');
      // 接派单成功 → 同一事务内创建「老板 ↔ 打手」直聊（与抢单同规则）+ 系统消息「已接单」
      await this.chat.appendOrderSystemMessageTx(
        em,
        order.userId,
        worker.userId,
        `护航员已接单 · 单号 ${this.shortOrderNo(order.orderNo)}`,
      );
      return { ok: true, orderId };
    });
  }

  /** 打手拒绝派单：pending_dispatch → pending_take 回大厅（worker_id 清空） */
  async workerReject(workerUserId: string, orderId: string, meta: { ip: string; requestId: string }) {
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { userId: workerUserId, status: 1 } });
    if (!worker) throw new ForbiddenException('工作端不可用');
    return this.dataSource.transaction(async (em) => {
      const res = await em
        .createQueryBuilder()
        .update(Order)
        .set({ status: 'pending_take', workerId: null, dispatchedAt: null, dispatchExpireAt: null })
        .where('id = :orderId AND status = :status AND worker_id = :workerId', { orderId, status: 'pending_dispatch', workerId: worker.id })
        .execute();
      if (!res.affected) {
        throw new BadRequestException('拒绝失败：派单已超时、已被撤销或不属于你');
      }
      await this.logStatus(em, orderId, 'pending_dispatch', 'pending_take', 'worker', workerUserId, 'client', meta, '拒绝派单，回大厅');
      this.realtime.emitToAdmins('dispatch:rejected', { orderId, workerId: worker.id });
      return { ok: true, orderId };
    });
  }

  /** 管理端撤销派单：pending_dispatch → pending_take */
  async adminRevokeDispatch(adminUserId: string, orderId: string, meta: { ip: string; requestId: string }) {
    return this.dataSource.transaction(async (em) => {
      const order = await em.findOne(Order, { where: { id: orderId }, lock: { mode: 'pessimistic_write' } });
      if (!order) throw new NotFoundException('订单不存在');
      this.assertStatus(order, ['pending_dispatch'], '当前状态不允许撤销派单');
      const prevWorkerId = order.workerId;
      await em.update(Order, order.id, { status: 'pending_take', workerId: null, dispatchedAt: null, dispatchExpireAt: null });
      await this.logStatus(em, order.id, 'pending_dispatch', 'pending_take', 'admin', adminUserId, 'admin', meta, '管理员撤销派单');
      if (prevWorkerId) {
        const w = await em.findOne(Worker, { where: { id: prevWorkerId } });
        if (w) this.realtime.emitToUser(w.userId, 'dispatch:canceled', { orderId: order.id });
      }
      return { ok: true };
    });
  }

  /**
   * 派单超时扫描：过期派单回大厅（条件 UPDATE 批处理；启动时先跑一次覆盖重启窗口；30s 周期）
   * 超时订单逐条写状态日志 + WS 通知打手 dispatch:expired
   */
  async sweepExpiredDispatches(): Promise<number> {
    const expired = await this.orderRepo
      .createQueryBuilder('o')
      .select(['o.id', 'o.workerId', 'o.orderNo'])
      .where('o.status = :status AND o.dispatch_expire_at < NOW(3)', { status: 'pending_dispatch' })
      .getMany();
    if (!expired.length) return 0;
    for (const order of expired) {
      const res = await this.dataSource
        .createQueryBuilder()
        .update(Order)
        .set({ status: 'pending_take', workerId: null, dispatchedAt: null, dispatchExpireAt: null })
        .where('id = :id AND status = :status AND dispatch_expire_at < NOW(3)', { id: order.id, status: 'pending_dispatch' })
        .execute();
      if (!res.affected) continue;
      await this.dataSource.transaction(async (em) => {
        await this.logStatus(em, order.id, 'pending_dispatch', 'pending_take', 'system', null, 'system', { ip: '', requestId: '' }, '派单确认超时，自动回大厅');
      });
      if (order.workerId) {
        const w = await this.dataSource.getRepository(Worker).findOne({ where: { id: order.workerId } });
        if (w) this.realtime.emitToUser(w.userId, 'dispatch:expired', { orderId: order.id });
      }
      this.logger.log(`派单超时回大厅 order=${order.orderNo}`);
    }
    return expired.length;
  }

  /** 待接单超时扫描：超过 system_setting 配置小时数无人接单 → 自动取消并全额退款（docs/05 超时规则默认 24h） */
  async sweepPendingTakeTimeout(): Promise<number> {
    const hours = await this.settings.value('order_pending_take_timeout_hours', 24);
    const expired = await this.orderRepo
      .createQueryBuilder('o')
      .select(['o.id', 'o.orderNo', 'o.userId', 'o.totalAmount'])
      .where("o.status = 'pending_take' AND o.created_at < DATE_SUB(NOW(3), INTERVAL :hours HOUR)", { hours })
      .getMany();
    if (!expired.length) return 0;
    for (const order of expired) {
      const res = await this.dataSource
        .createQueryBuilder()
        .update(Order)
        .set({ status: 'canceled', cancelReason: `待接单超时（${hours}h）自动取消`, cancelBy: 'system' })
        .where("id = :id AND status = 'pending_take'", { id: order.id })
        .execute();
      if (!res.affected) continue;
      let direct: DirectOutcome = null;
      // 退款（事务：行锁钱包 + 流水，docs/06）+ 同一事务内按方案①收尾直聊会话
      await this.dataSource.transaction(async (em) => {
        const wallet = await em.findOne(Wallet, { where: { userId: order.userId }, lock: { mode: 'pessimistic_write' } });
        if (wallet) {
          await em.update(Wallet, wallet.id, { balance: wallet.balance + order.totalAmount });
          await this.insertTxn(em, {
            userId: order.userId, changeType: 'order_refund', amount: order.totalAmount,
            balanceBefore: wallet.balance, balanceAfter: wallet.balance + order.totalAmount,
            operatorType: 'system', operatorId: null, source: 'system',
            reason: `待接单超时自动取消退款（${hours}h）`, orderId: order.id, idempotencyKey: `timeout-refund:${order.id}`, meta: { ip: '', requestId: '' },
          });
        }
        await this.logStatus(em, order.id, 'pending_take', 'canceled', 'system', null, 'system', { ip: '', requestId: '' }, `待接单超时（${hours}h）自动取消退款`);
        // 待接单订单必无接单打手（worker_id IS NULL）→ 该 (老板,打手) 对不存在，实际不动任何会话；
        // 仍按同一收尾规则调用，保证「凡置 canceled 的路径」语义一致（数据异常时也能自愈）
        direct = await this.settleCanceledDirectChatTx(em, order);
      });
      this.emitDirectChatEvent(direct, order.id, 'order_auto_canceled_timeout');
      this.realtime.emitToUser(order.userId, 'order:auto-canceled', { orderId: order.id, orderNo: order.orderNo });
      this.logger.log(`待接单超时自动取消 order=${order.orderNo}`);
    }
    return expired.length;
  }

  // ---------------- 售后申诉（docs/05：用户申诉 → 管理员裁决退款/驳回） ----------------

  /** 用户提交申诉：仅 completed / abnormal 订单；一单一申诉；订单进入 after_sale */
  async userAppeal(userId: string, orderId: string, reason: string, meta: { ip: string; requestId: string }) {
    return this.dataSource.transaction(async (em) => {
      const order = await em.findOne(Order, { where: { id: orderId, userId }, lock: { mode: 'pessimistic_write' } });
      if (!order) throw new NotFoundException('订单不存在或不属于你');
      if (!['completed', 'abnormal'].includes(order.status)) {
        throw new BadRequestException('仅已完成或异常订单可以申请售后');
      }
      const existing = await em.findOne(OrderAppeal, { where: { orderId: order.id } });
      if (existing) throw new BadRequestException('该订单已有售后申诉在处理中');
      const appeal = await em.save(em.create(OrderAppeal, {
        orderId: order.id, userId, prevStatus: order.status, reason: (reason || '').slice(0, 500), status: 'open',
      }));
      await em.update(Order, order.id, { status: 'after_sale' });
      await this.logStatus(em, order.id, order.status, 'after_sale', 'user', userId, 'client', meta, `申请售后：${reason || '-'}`);
      this.realtime.emitToAdmins('appeal:new', { appealId: appeal.id, orderId: order.id, orderNo: order.orderNo });
      return { appealId: appeal.id };
    });
  }

  async userAppealStatus(userId: string, orderId: string) {
    const appeal = await this.dataSource.getRepository(OrderAppeal).findOne({ where: { orderId, userId } });
    if (!appeal) return null;
    return {
      id: appeal.id, orderId: appeal.orderId, reason: appeal.reason, status: appeal.status,
      result: appeal.result, handlerRemark: appeal.handlerRemark, createdAt: appeal.createdAt, handledAt: appeal.handledAt,
    };
  }

  async adminAppeals(q: { status?: string; page: number; pageSize: number }) {
    const qb = this.dataSource
      .getRepository(OrderAppeal)
      .createQueryBuilder('a')
      .leftJoin(Order, 'o', 'o.id = a.order_id')
      .leftJoin(User, 'u', 'u.id = a.user_id')
      .select([
        'a.id AS id', 'a.order_id AS orderId', 'a.user_id AS userId', 'a.prev_status AS prevStatus',
        'a.reason AS reason', 'a.status AS status', 'a.result AS result', 'a.handler_remark AS handlerRemark',
        'a.handled_at AS handledAt', 'a.created_at AS createdAt',
        'o.order_no AS orderNo', 'o.total_amount AS totalAmount',
        'u.nickname AS nickname',
      ]);
    if (q.status) qb.andWhere('a.status = :status', { status: q.status });
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('a.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    return { list: list.map((r) => mapMoney(r, ['totalAmount'])), total: Number(total?.cnt ?? 0), page: q.page, pageSize: q.pageSize };
  }

  /**
   * 管理员裁决：refund（退款：未结算全额退款；已结算先按**原结算记录**冲正再全额退款）/ dismiss（驳回，还原 prev_status）
   * 全部在一个事务内：订单行锁 + 钱包行锁 + 流水 + 申诉落结果（docs/05/06）
   */
  async adminHandleAppeal(adminUserId: string, appealId: string, dto: { action: 'refund' | 'dismiss'; remark?: string }, meta: { ip: string; requestId: string }) {
    let direct: DirectOutcome = null;
    let closedOrderId = '';
    let chatReason = 'appeal_dismissed_restored';
    const result = await this.dataSource.transaction(async (em) => {
      const appeal = await em.findOne(OrderAppeal, { where: { id: appealId }, lock: { mode: 'pessimistic_write' } });
      if (!appeal) throw new NotFoundException('申诉不存在');
      if (appeal.status !== 'open') throw new BadRequestException('该申诉已处理');
      closedOrderId = String(appeal.orderId);
      const order = await em.findOne(Order, { where: { id: appeal.orderId }, lock: { mode: 'pessimistic_write' } });
      if (!order) throw new NotFoundException('订单不存在');
      if (order.status !== 'after_sale') throw new BadRequestException('订单当前状态不允许裁决');

      if (dto.action === 'dismiss') {
        // 驳回：还原到申诉前状态
        await em.update(Order, order.id, { status: appeal.prevStatus as OrderStatus });
        await this.logStatus(em, order.id, 'after_sale', appeal.prevStatus, 'admin', adminUserId, 'admin', meta, `售后驳回：${dto.remark || '-'}`);
        // 负责人 2026-10-04：申诉前状态多为 completed → 订单重新进入「已完成」= 又一条置 completed 的路径。
        // 但驳回**不是一次新的完成事件**（首次完成时已收尾过会话），所以只清理**孤儿会话**：
        // 该会话不被同一对老板/打手的其它进行中订单使用时才收尾；否则**保持 open 原样不动**
        // （方案①：不再置 closed —— 置 closed 会让另一单正在服务中的双方发不出消息）。
        if (appeal.prevStatus === 'completed') {
          const workerProfile = order.workerId ? await em.findOne(Worker, { where: { id: order.workerId } }) : null;
          if (workerProfile) direct = await this.settleOrphanDirectChatTx(em, order, workerProfile.userId);
        }
      } else {
        // 退款：订单进入终态 canceled → 与其它取消路径同一规则收尾直聊会话。
        // 负责人 2026-10-04：与「退款审批通过」共用同一收口（流水/幂等键完全一致）
        direct = await this.adminRefundOrderTx(
          em,
          order,
          'after_sale',
          adminUserId,
          { reason: `售后退款：${dto.remark || '-'}`, logRemark: `售后退款：${dto.remark || '-'}` },
          meta,
        );
        chatReason = 'appeal_refunded_canceled';
      }
      appeal.status = 'handled';
      appeal.result = dto.action;
      appeal.handlerId = adminUserId;
      appeal.handlerRemark = (dto.remark ?? '').slice(0, 500);
      appeal.handledAt = new Date();
      await em.save(appeal);
      this.realtime.emitToUser(order.userId, 'appeal:handled', { orderId: order.id, result: dto.action, remark: dto.remark ?? '' });
      return { ok: true };
    });
    // 事务提交后再推会话事件（驳回还原为 completed 时孤儿会话可能被删除；退款分支同理）
    this.emitDirectChatEvent(direct, closedOrderId, chatReason);
    return result;
  }

  /**
   * 管理端退款收口（**售后裁决 / 退款审批共用**，docs/06 同一套流水与幂等键）：
   * - 未结算订单：`refundAndClose`（条件增余额 + order_refund 流水，幂等键 `refund:{orderId}`）
   * - 已结算订单：先按**该单结算记录里的实际金额**冲正打手与平台（`settlement-reversal:{orderId}:worker|:platform`），再全额退还老板
   *   （**不回读当前配置**：历史单据按当时比例冲正，改配置不会让老单冲正金额错位）
   * - 订单进入终态 canceled + 状态日志 + 直聊会话收尾（与其它取消路径同一规则，方案①）
   *
   * 调用方必须在**自己的事务**里持有订单行锁后调用；本方法不提交事务。
   * 负责人 2026-10-04：退款审批与申诉退款走这里，禁止各写一套。
   */
  async adminRefundOrderTx(
    em: EntityManager,
    order: Order,
    fromStatus: OrderStatus | string,
    adminUserId: string,
    opts: { reason: string; logRemark: string },
    meta: { ip: string; requestId: string },
  ): Promise<DirectOutcome> {
    const settlement = await em.findOne(OrderSettlement, { where: { orderId: order.id } });
    if (settlement) {
      await this.reverseSettlementAndRefund(em, order, settlement, adminUserId, opts.reason, meta);
    } else {
      await this.refundAndClose(em, order, 'admin', opts.reason, meta);
    }
    await em.update(Order, order.id, { status: 'canceled' });
    await this.logStatus(em, order.id, fromStatus, 'canceled', 'admin', adminUserId, 'admin', meta, opts.logRemark);
    // 售后退款 = 把订单置 canceled 的路径之一：无其它未完成订单 → 删除会话；还有 → 保持 open 不动
    return this.settleCanceledDirectChatTx(em, order);
  }

  /** 已结算订单退款：按结算记录冲正打手与平台（金额取落库值，与当前配置无关），再全额退用户（打手余额不足则拒绝并提示人工处理） */
  private async reverseSettlementAndRefund(
    em: EntityManager,
    order: Order,
    settlement: OrderSettlement,
    adminUserId: string,
    reason: string,
    meta: { ip: string; requestId: string },
  ) {
    // 1. 打手退回该单结算金额（余额校验，防负余额）
    const worker = await em.findOne(Worker, { where: { id: settlement.workerId } });
    if (!worker) throw new BadRequestException('打手档案不存在，无法自动冲正（请人工处理）');
    const workerWallet = await em.findOne(Wallet, { where: { userId: worker.userId }, lock: { mode: 'pessimistic_write' } });
    if (!workerWallet || workerWallet.balance < settlement.workerAmount) {
      throw new BadRequestException('打手钱包余额不足，无法自动冲正退款（请人工处理）');
    }
    await em.update(Wallet, workerWallet.id, { balance: workerWallet.balance - settlement.workerAmount });
    await this.insertTxn(em, {
      userId: worker.userId, changeType: 'settlement_reversal', amount: -settlement.workerAmount,
      balanceBefore: workerWallet.balance, balanceAfter: workerWallet.balance - settlement.workerAmount,
      operatorType: 'admin', operatorId: adminUserId, source: 'admin',
      reason: `售后退款冲正结算（${settlement.settlementNo}）：${reason}`, orderId: order.id, idempotencyKey: `settlement-reversal:${order.id}:worker`, meta,
    });
    await this.rollbackWorkerStatsTx(em, settlement);
    // 2. 平台退回该单抽成金额
    const platformUser = await em.findOne(User, { where: { uid: 'PLATFORM1' } });
    if (platformUser) {
      const platformWallet = await em.findOne(Wallet, { where: { userId: platformUser.id }, lock: { mode: 'pessimistic_write' } });
      if (platformWallet) {
        await em.update(Wallet, platformWallet.id, { balance: platformWallet.balance - settlement.platformAmount });
        await this.insertTxn(em, {
          userId: platformUser.id, changeType: 'platform_commission_reversal', amount: -settlement.platformAmount,
          balanceBefore: platformWallet.balance, balanceAfter: platformWallet.balance - settlement.platformAmount,
          operatorType: 'admin', operatorId: adminUserId, source: 'admin',
          reason: `售后退款冲正平台抽成（${settlement.settlementNo}）`, orderId: order.id, idempotencyKey: `settlement-reversal:${order.id}:platform`, meta,
        });
      }
    }
    // 3. 用户全额退款
    const userWallet = await em.findOne(Wallet, { where: { userId: order.userId }, lock: { mode: 'pessimistic_write' } });
    if (!userWallet) throw new BadRequestException('用户钱包不存在');
    await em.update(Wallet, userWallet.id, { balance: userWallet.balance + order.totalAmount });
    await this.insertTxn(em, {
      userId: order.userId, changeType: 'order_refund', amount: order.totalAmount,
      balanceBefore: userWallet.balance, balanceAfter: userWallet.balance + order.totalAmount,
      operatorType: 'admin', operatorId: adminUserId, source: 'admin',
      reason: `售后退款：${reason}`, orderId: order.id, idempotencyKey: `refund:${order.id}`, meta,
    });
    // 退款回退累计消费（等级不自动降级）
    await this.level.refundSpentInTx(em, order.userId, order.totalAmount);
  }

  /**
   * 退款冲正时**同步回退打手战绩**（`worker_stats`，M7）—— 与钱包冲正**同一事务**，钱与战绩必须一致。
   *
   * ## 为什么必须有它（真 bug，2026-10-06 修）
   *
   * 结算路径（本文件 `settleTx`）在事务内做了
   * `INSERT INTO worker_stats … ON DUPLICATE KEY UPDATE +1/+1/+amount`，
   * 但**退款路径原先只写 wallet 冲正流水、从不回退 worker_stats** ——
   * 于是「走完全合法的售后退款链」之后，**钱包退干净了、战绩却永久虚高**：
   * `GET /worker/my-stats` 与打手态「我的」继续显示不该有的完成单数与金额。
   * 实证（修前）：打手 168 多算 1 单（order 785 已退款）、打手 170 多算 1 单（order 907）。
   *
   * ## 三条口径（与负责人 2026-10-06 定案一致）
   *
   * 1. **对称**：结算时加的就是 `settlement.orderAmount`（落库值），这里就减**同一个落库值**，
   *    **不重算**——与上面冲正金额「不回读当前配置」同一口径（改配置不会让老单冲正错位）。
   * 2. **不许负值**：用**条件 UPDATE**（三项都够减才动），而不是 `GREATEST(0, …)`。
   *    选条件 UPDATE 的理由：`GREATEST` 会把「行不存在 / 已被别的单减过 / 数据本来就错」
   *    **静默伪装成「减成功了」**，负值是被夹住了但异常被吞掉；条件 UPDATE 则如实返回
   *    `affectedRows = 0`，我们据此打告警，异常看得见。宁可少减一次并告警，也不假装成功。
   * 3. **幂等（同一单最多回退一次）**：本方法只在 `settlement-reversal:{orderId}:worker`
   *    这条流水**插入成功之后**才被调用，而该 `idempotency_key` 有**唯一约束**
   *    （`UQ_wallet_txn_idem`）→ 同一张单重复退款会在插流水那一步就抛冲突并整体回滚，
   *    本回退天然最多执行一次，无需再引入第二个幂等键。
   *
   * **失败不阻断退款**：回退失败只告警（钱必须退给老板，这是第一优先），
   * 与结算侧「战绩累加失败不阻断结算」的既有取舍对称。
   */
  private async rollbackWorkerStatsTx(em: EntityManager, settlement: OrderSettlement): Promise<void> {
    const res: { affectedRows?: number } = await em.query(
      `UPDATE worker_stats
          SET total_orders = total_orders - 1,
              completed_orders = completed_orders - 1,
              total_amount = total_amount - ?
        WHERE worker_id = ?
          AND total_orders >= 1
          AND completed_orders >= 1
          AND total_amount >= ?`,
      [settlement.orderAmount, settlement.workerId, settlement.orderAmount],
    );
    const affected = Number(res?.affectedRows ?? 0);
    if (affected === 1) {
      this.logger.log(
        `战绩同步回退 order=${settlement.orderId} worker=${settlement.workerId} −1单/−${settlement.orderAmount}（结算单 ${settlement.settlementNo}）`,
      );
    } else {
      // 理论上不该发生：能走到这里说明结算单存在。真发生了就是数据异常，必须留痕给人看
      this.logger.warn(
        `⚠️ 战绩回退未生效（affectedRows=${affected}）：worker=${settlement.workerId} order=${settlement.orderId} ` +
          `金额=${settlement.orderAmount} —— worker_stats 行缺失或计数不足，请人工核对（钱包已按单冲正，不受影响）`,
      );
    }
  }

  // ---------------- 查询 ----------------

  async userOrders(userId: string, status: string | undefined, page: number, pageSize: number) {
    const where: Record<string, unknown> = { userId };
    // 多状态过滤（2026-10-05 任务②）：投诉页要「只列可投诉的订单」，那是一组状态
    // （见 order-complaintable.ts），客户端以 `?status=a,b,c` 逗号分隔传入。
    // 单值语义与改动前完全一致（订单页各 tab 仍传单个状态）；空串/纯逗号 = 不过滤，
    // 不会拼出非法的 `IN ()`。
    const statuses = (status ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
    if (statuses.length === 1) where.status = statuses[0];
    else if (statuses.length > 1) where.status = In(statuses);
    const [list, total] = await this.orderRepo.findAndCount({
      where,
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    if (!list.length) return { list: [], total, page, pageSize };
    // 商品名/计价单位（价格快照）；打手昵称（已接单时展示服务人员，2026-09-25 UI 整改需求）
    const snapshots = await this.dataSource.getRepository(OrderPriceSnapshot)
      .createQueryBuilder('s')
      .where('s.order_id IN (:...ids)', { ids: list.map((o) => o.id) })
      .getMany();
    const snapMap = new Map(snapshots.map((s) => [s.orderId, s]));
    const workerIds = [...new Set(list.filter((o) => o.workerId).map((o) => Number(o.workerId)))];
    const nickMap = new Map<number, string>();
    if (workerIds.length) {
      const raw = await this.dataSource.query(
        `SELECT w.id, u.nickname FROM worker w JOIN user u ON u.id = w.user_id WHERE w.id IN (?)`,
        [workerIds],
      );
      for (const r of raw as Array<{ id: number; nickname: string }>) nickMap.set(Number(r.id), r.nickname);
    }
    return {
      list: list.map((o) => {
        const snap = snapMap.get(o.id);
        return {
          ...this.orderView(o),
          productName: snap?.productName ?? '',
          priceUnit: snap?.priceUnit ?? '',
          workerNickname: o.workerId ? (nickMap.get(Number(o.workerId)) ?? '') : '',
        };
      }),
      total, page, pageSize,
    };
  }

  async userOrderDetail(userId: string, orderId: string) {
    const order = await this.orderRepo.findOne({ where: { id: orderId, userId } });
    if (!order) {
      throw new NotFoundException('订单不存在');
    }
    const snapshot = await this.dataSource.getRepository(OrderPriceSnapshot).findOne({ where: { orderId: order.id } });
    const settlement = await this.settlementRepo.findOne({ where: { orderId: order.id } });
    // 状态流转记录（负责人 2026-10-14 批准）：老板端订单详情页要画**真实状态时间线**。
    //
    // 为什么必须补这个字段：此前只有管理端 `adminDetail()` 下发 `statusLogs`（见本文件 :1514），
    // 老板端详情拿不到流转记录 → 时间线只能"猜中间状态"或退化成两步。
    // 复用管理端那段**现成查询**（同一张表、同一排序），不新增接口、不改权限、不改表结构。
    //
    // 为什么按 id ASC：`order_status_log` 的自增 id 即真实发生顺序
    //（`created_at` 是 datetime(3)，同一毫秒内可能并列；id 不会）。
    const statusLogs = await this.dataSource
      .getRepository(OrderStatusLog)
      .find({ where: { orderId: order.id }, order: { id: 'ASC' } });
    // 打手信息（需求 #20：详情页展示服务信息与打手信息）
    let workerInfo: { workerNo: string; nickname: string } | null = null;
    if (order.workerId) {
      const raw: unknown = await this.dataSource.query(
        `SELECT w.worker_no, u.nickname FROM worker w JOIN user u ON u.id = w.user_id WHERE w.id = ? LIMIT 1`,
        [order.workerId],
      );
      const rows = (Array.isArray(raw) && raw.length >= 1 && Array.isArray(raw[0]) ? raw[0] : raw) as Array<{ worker_no: string; nickname: string }>;
      if (rows[0]) workerInfo = { workerNo: rows[0].worker_no, nickname: rows[0].nickname };
    }
    return {
      ...this.orderView(order),
      gameZone: order.gameZone,
      gamePlayerId: order.gamePlayerId,
      snapshot,
      settlement,
      workerInfo,
      statusLogs,
    };
  }

  /**
   * 接单大厅（负责人 2026-10-03 第 7 条：按分部筛选；2026-10-04：**按分部接单权限隔离**）
   *
   * - 只返回该打手**有接单权限的分部**的订单；不传 divisionId = 其全部可用分部（一次 IN 查询收口）。
   * - 传了没有权限的分部 → **返回空列表 + 明确中文提示**（`divisionDenied` / `message`），
   *   而不是 403：客户端的筛选胶囊本来就只列有权限的分部，正常路径点不到；
   *   这里兜底成"空列表 + 提示"，避免直接调接口时把整个大厅打成报错页。
   * - **一个分部权限都没有（2026-10-06 修）→ 同样返回空列表 + 中文提示**，不再 403。
   *   依据 CLAUDE.md 第 10 条「大厅无权限返回空列表 + 中文提示（不是报错页）」；
   *   合并双端后"刚绑定的新打手往往一个分部权限都没有"，这是**高频首屏路径**，
   *   报错页（红字 + 重试按钮）会被误读成"App 坏了"。修复方式：判定只看
   *   `worker_division_permission`（权威表），**不再用 `worker.can_take_order` 派生汇总做拦截**
   *   —— 该列本就只是"是否有任一授权"的派生值（CLAUDE.md 第 10 条：不作判定依据），
   *   用它拦截会让"汇总列与权限表暂时不一致"时出现错误的 403/漏单。
   * - 每次实时查库（管理端刚授/刚撤的权，下一次请求立刻生效，无缓存）。
   * @param divisionId 传分部 id 只看该分部订单；不传为该打手的全部可用分部
   */
  async workerHall(workerUserId: string, page: number, pageSize: number, divisionId?: string) {
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { userId: workerUserId } });
    // 只剩"没有打手档案 / 打手已停用"是 403（这不是"没有分部权限"，而是身份不可用）
    if (!worker || worker.status !== 1) {
      throw new ForbiddenException('工作端不可用或已停用');
    }
    // 分部接单权限（实时查库）：这是大厅可见范围的唯一依据
    const permitted = await this.divisionPerm.permittedDivisionIds(worker.id);
    const want = divisionId ? String(divisionId) : '';
    if (want && !permitted.includes(want)) {
      return {
        list: [], total: 0, page, pageSize,
        divisionDenied: true,
        message: '你暂无该分部的接单权限，请联系管理员',
      };
    }
    if (!want && !permitted.length) {
      return {
        list: [], total: 0, page, pageSize,
        divisionDenied: true,
        message: '你暂无任何分部的接单权限，请联系管理员',
      };
    }
    // 没有分部归属的历史/异常单不受分部限制 —— 否则这类单永远没人抢得动。
    // 只在「全部分部」视图里出现；指定了分部时严格只看该分部。
    const where = want
      ? { status: 'pending_take' as const, divisionId: want }
      : [
          { status: 'pending_take' as const, divisionId: In(permitted) },
          { status: 'pending_take' as const, divisionId: IsNull() },
        ];
    const [list, total] = await this.orderRepo.findAndCount({
      where,
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    // 大厅展示商品内容与数量（多老板同商品 = 各自一条订单，绝不合并）；
    // 注意：orderView 不含游戏分区/游戏ID —— 老板游戏信息只有抢上单后才可见（负责人需求）
    const snapshots = list.length
      ? await this.dataSource.getRepository(OrderPriceSnapshot)
          .createQueryBuilder('s')
          .where('s.order_id IN (:...ids)', { ids: list.map((o) => o.id) })
          .getMany()
      : [];
    const snapMap = new Map(snapshots.map((s) => [s.orderId, s]));
    return {
      list: list.map((o) => {
        const snap = snapMap.get(o.id);
        return { ...this.orderView(o), productName: snap?.productName ?? '', priceUnit: snap?.priceUnit ?? '' };
      }),
      total, page, pageSize,
    };
  }

  async workerOrders(workerUserId: string, status: string | undefined, page: number, pageSize: number) {
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { userId: workerUserId } });
    if (!worker) {
      throw new ForbiddenException('工作端不可用');
    }
    const where: Record<string, unknown> = { workerId: worker.id };
    if (status) where.status = status;
    const [list, total] = await this.orderRepo.findAndCount({
      where,
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    // 我的订单 = 已归属本打手 → 可展示老板游戏分区/游戏ID（抢单/接派单后才可见）
    const snapshots = list.length
      ? await this.dataSource.getRepository(OrderPriceSnapshot)
          .createQueryBuilder('s')
          .where('s.order_id IN (:...ids)', { ids: list.map((o) => o.id) })
          .getMany()
      : [];
    const snapMap = new Map(snapshots.map((s) => [s.orderId, s]));
    return {
      list: list.map((o) => {
        const snap = snapMap.get(o.id);
        return {
          ...this.orderView(o),
          productName: snap?.productName ?? '',
          priceUnit: snap?.priceUnit ?? '',
          gameZone: o.gameZone,
          gamePlayerId: o.gamePlayerId,
        };
      }),
      total, page, pageSize,
    };
  }

  async adminList(q: { status?: string; keyword?: string; page: number; pageSize: number }) {
    const qb = this.dataSource
      .createQueryBuilder(Order, 'o')
      // LEFT JOIN：账号被删除后历史订单仍须完整展示（业务记录保留）
      .leftJoin(User, 'u', 'u.id = o.user_id')
      .select([
        'o.id AS id', 'o.order_no AS orderNo', 'o.user_id AS userId', 'u.username AS username',
        'o.total_amount AS totalAmount', 'o.status AS status', 'o.worker_id AS workerId',
        'o.created_at AS createdAt', 'o.quantity AS quantity',
      ]);
    if (q.status) qb.andWhere('o.status = :status', { status: q.status });
    if (q.keyword) qb.andWhere('(o.order_no LIKE :kw OR u.username LIKE :kw)', { kw: `%${q.keyword}%` });
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('o.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    return { list: list.map((r) => mapMoney(r, ['totalAmount'])), total: Number(total?.cnt ?? 0), page: q.page, pageSize: q.pageSize };
  }

  async adminDetail(orderId: string) {
    const order = await this.orderRepo.findOne({ where: { id: orderId } });
    if (!order) {
      throw new NotFoundException('订单不存在');
    }
    const [snapshot, settlement, logs, user, workerUser] = await Promise.all([
      this.dataSource.getRepository(OrderPriceSnapshot).findOne({ where: { orderId: order.id } }),
      this.settlementRepo.findOne({ where: { orderId: order.id } }),
      this.dataSource.getRepository(OrderStatusLog).find({ where: { orderId: order.id }, order: { id: 'ASC' } }),
      this.dataSource.getRepository(User).findOne({ where: { id: order.userId } }),
      order.workerId
        ? this.dataSource.getRepository(Worker).findOne({ where: { id: order.workerId } }).then(async (w) => {
            if (!w) return null;
            const u = await this.dataSource.getRepository(User).findOne({ where: { id: w.userId } });
            return { workerNo: w.workerNo, nickname: u?.nickname ?? '', username: u?.username ?? '' };
          })
        : Promise.resolve(null),
    ]);
    return {
      ...this.orderView(order),
      username: user?.username ?? '',
      gameZone: order.gameZone,
      gamePlayerId: order.gamePlayerId,
      snapshot,
      settlement,
      workerInfo: workerUser,
      statusLogs: logs,
      // 需求 #9：后台订单详情可查看对应群组及成员
      chatDirect: await this.chat.directInfoByOrder(order.id),
    };
  }

  /** 抽成中心：结算流水（分页+过滤） */
  async settlements(q: { page: number; pageSize: number; orderNo?: string; workerId?: string }) {
    const qb = this.dataSource
      .createQueryBuilder(OrderSettlement, 's')
      .innerJoin(Order, 'o', 'o.id = s.order_id')
      .select([
        's.id AS id', 's.settlement_no AS settlementNo', 's.order_id AS orderId', 'o.order_no AS orderNo',
        's.order_amount AS orderAmount', 's.worker_id AS workerId', 's.worker_amount AS workerAmount',
        's.worker_percentage AS workerPercentage', 's.platform_amount AS platformAmount',
        's.platform_percentage AS platformPercentage', 's.created_at AS createdAt',
      ]);
    if (q.orderNo) qb.andWhere('o.order_no LIKE :orderNo', { orderNo: `%${q.orderNo}%` });
    if (q.workerId) qb.andWhere('s.worker_id = :workerId', { workerId: q.workerId });
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('s.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    return {
      list: list.map((r) => mapMoney(r, ['orderAmount', 'workerAmount', 'platformAmount'])),
      total: Number(total?.cnt ?? 0), page: q.page, pageSize: q.pageSize,
    };
  }

  /** 抽成中心概览（真实 SQL 统计，不写死） */
  async commissionStats() {
    // "今日/本月"按中国自然日（UTC+8）计算：数据库统一存 UTC，边界在 JS 侧算好传参（避免时区混淆）
    const chinaNow = new Date(Date.now() + 8 * 3600_000);
    const startOfChinaDay = new Date(Date.UTC(chinaNow.getUTCFullYear(), chinaNow.getUTCMonth(), chinaNow.getUTCDate()));
    const startOfChinaMonth = new Date(Date.UTC(chinaNow.getUTCFullYear(), chinaNow.getUTCMonth(), 1));
    const rows: {
      totalOrderAmount: string; totalWorker: string; totalPlatform: string;
      todayPlatform: string; monthPlatform: string; orderCount: string; settledCount: string;
    }[] = await this.dataSource.query(
      `
      SELECT
        COALESCE(SUM(o.total_amount), 0) AS totalOrderAmount,
        COALESCE((SELECT SUM(s.worker_amount) FROM order_settlement s), 0) AS totalWorker,
        COALESCE((SELECT SUM(s.platform_amount) FROM order_settlement s), 0) AS totalPlatform,
        COALESCE((SELECT SUM(s.platform_amount) FROM order_settlement s WHERE s.created_at >= ?), 0) AS todayPlatform,
        COALESCE((SELECT SUM(s.platform_amount) FROM order_settlement s WHERE s.created_at >= ?), 0) AS monthPlatform,
        COUNT(o.id) AS orderCount,
        (SELECT COUNT(*) FROM order_settlement) AS settledCount
      FROM \`order\` o
    `,
      [startOfChinaDay, startOfChinaMonth],
    );
    const r = rows[0];
    // 当前生效分成比例（读配置，管理端展示用；与结算用的是同一入口，不会出现"页面显示 25 实际按 30 结算"）
    const commissionRate = await this.settings.platformCommissionRate();
    return {
      totalOrderAmount: Number(r.totalOrderAmount),
      totalWorker: Number(r.totalWorker),
      totalPlatform: Number(r.totalPlatform),
      todayPlatform: Number(r.todayPlatform),
      monthPlatform: Number(r.monthPlatform),
      orderCount: Number(r.orderCount),
      settledCount: Number(r.settledCount),
      commissionRate,
      workerPercentage: workerPercentageOf(commissionRate),
    };
  }

  // ---------------- 内部工具 ----------------

  private assertStatus(order: Order, allowed: OrderStatus[], msg: string) {
    if (!allowed.includes(order.status)) {
      throw new BadRequestException(`${msg}（当前：${this.statusName(order.status)}）`);
    }
  }

  private statusName(s: OrderStatus): string {
    const map: Record<OrderStatus, string> = {
      pending_take: '待接单', pending_dispatch: '待确认派单', taken: '已接单', in_progress: '进行中',
      pending_confirm: '待用户确认', completed: '已完成', canceled: '已取消', abnormal: '异常', after_sale: '售后/申诉',
    };
    return map[s] ?? s;
  }

  private orderView(order: Order, duplicated = false) {
    return {
      id: order.id,
      orderNo: order.orderNo,
      productId: order.productId,
      quantity: order.quantity,
      unitPrice: order.unitPrice,
      totalAmount: order.totalAmount,
      status: order.status,
      statusName: this.statusName(order.status),
      workerId: order.workerId,
      userRemark: order.userRemark,
      createdAt: order.createdAt,
      // 分部/游戏（2026-10-04）：客户端订单卡要按分部显示官方游戏图标（division.iconMediaId），
      // 且端游要贴「端」角标 —— 此前不下发导致订单卡只能靠商品名猜、平台恒为空。
      // 公开只读字段，随订单自身返回（不涉及权限与结构变更）。
      divisionId: order.divisionId,
      gameId: order.gameId,
      duplicated,
    };
  }

  private async insertTxn(
    em: EntityManager,
    input: {
      userId: string; changeType: string; amount: number; balanceBefore: number; balanceAfter: number;
      operatorType: string; operatorId: string | null; source: string; reason: string;
      orderId: string | null; idempotencyKey: string | null; meta: { ip: string; requestId: string };
    },
  ) {
    await em.save(
      em.create(WalletTransaction, {
        transactionNo: `T${Date.now().toString(36).toUpperCase()}${randomInt(1000, 10000)}${randomUUID().slice(0, 4).toUpperCase()}`,
        userId: input.userId,
        changeType: input.changeType,
        amount: input.amount,
        balanceBefore: input.balanceBefore,
        balanceAfter: input.balanceAfter,
        operatorType: input.operatorType,
        operatorId: input.operatorId,
        source: input.source,
        reason: input.reason,
        orderId: input.orderId,
        idempotencyKey: input.idempotencyKey,
        ip: input.meta.ip?.slice(0, 64) ?? null,
        requestId: input.meta.requestId?.slice(0, 64) ?? null,
      }),
    );
  }

  private async logStatus(
    em: EntityManager,
    orderId: string,
    from: string,
    to: string,
    operatorType: string,
    operatorId: string | null,
    source: string,
    meta: { ip: string; requestId: string },
    remark: string,
  ) {
    await em.save(
      em.create(OrderStatusLog, {
        orderId,
        fromStatus: from,
        toStatus: to,
        operatorType,
        operatorId,
        source,
        requestId: meta.requestId?.slice(0, 64) ?? null,
        remark: remark?.slice(0, 255) ?? null,
      }),
    );
  }

  private generateOrderNo(): string {
    return `ORD${Date.now().toString(36).toUpperCase()}${randomInt(1000, 10000)}`;
  }

  /** 单号短号（订单号后 4 位；系统消息文案「单号 0087」用） */
  private shortOrderNo(orderNo: string): string {
    const s = (orderNo ?? '').slice(-4);
    return s.length === 4 ? s : (orderNo ?? '');
  }

  private generateSettlementNo(): string {
    return `STL${Date.now().toString(36).toUpperCase()}${randomInt(1000, 10000)}`;
  }
}
