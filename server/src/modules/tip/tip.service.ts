import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { randomInt, randomUUID } from 'crypto';
import { DataSource, EntityManager, In, QueryFailedError, Repository } from 'typeorm';
import { mapMoney } from '../../common/money.transformer';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { UserNotification } from '../friend/user-notification.entity';
import { Order, OrderStatus } from '../order/order.entity';
import { OrderPriceSnapshot } from '../order/order-price-snapshot.entity';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { Wallet } from '../wallet/wallet.entity';
import { WalletTransaction } from '../wallet/wallet-transaction.entity';
import { Worker } from '../worker/worker.entity';
import { OrderTip } from './order-tip.entity';

/** 可打赏的订单状态（已有接单打手才会出现，见 [tipableOrders]） */
export const TIPABLE_STATUSES: OrderStatus[] = ['in_progress', 'pending_confirm', 'completed'];

const DEFAULT_PRESETS = [0.6, 1.8, 3.8, 8.8];
const DEFAULT_MAX_PER_TIP = 50;
const DEFAULT_MAX_PER_ORDER = 100;

/** 打赏配置（管理端 system_setting 可改，客户端只读不可指定） */
export interface TipConfig {
  presets: number[];
  maxPerTip: number;
  maxPerOrder: number;
}

/**
 * 打赏服务（负责人 2026-10-04：顶部导航「打赏」，用余额打赏）
 *
 * 铁律（docs/06，全部服务端权威）：
 * - 金额/上限/归属一律服务端判定；客户端只传 orderId + amount + idempotencyKey
 * - 事务内：订单行锁 → 老板钱包行锁 → **条件扣款（balance >= amount，affectedRows 判余额）**
 *   → 老板出账流水 → 打手钱包行锁 → 打手入账流水 → order_tip 落库；任一步失败整体回滚
 * - 幂等：order_tip.idempotency_key 唯一约束 + 两条流水各自的幂等键（:out / :in）
 * - 100% 给打手，平台不抽成（与订单结算的分成比例配置 platform_commission_rate 无关）
 * - 2026-10-09 计价单位改「余额（元）」后，amount 允许 2 位小数（见 createTip 的金额校验）
 */
@Injectable()
export class TipService {
  private readonly logger = new Logger('Tip');

  constructor(
    @InjectRepository(OrderTip) private readonly tipRepo: Repository<OrderTip>,
    @InjectRepository(UserNotification) private readonly notifRepo: Repository<UserNotification>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly settings: SystemSettingService,
    private readonly realtime: RealtimeGateway,
  ) {}

  // ---------------- 配置 ----------------

  async config(): Promise<TipConfig> {
    const rows = await this.settings.all();
    const byKey = new Map(rows.map((r) => [r.settingKey, r.cfgValue?.['value']]));
    const presetsRaw = byKey.get('tip_presets');
    const presets = Array.isArray(presetsRaw)
      ? presetsRaw.map((v) => Number(v)).filter((v) => Number.isFinite(v) && v > 0)
      : DEFAULT_PRESETS;
    const num = (key: string, fallback: number) => {
      const v = Number(byKey.get(key));
      return Number.isFinite(v) && v > 0 ? Math.trunc(v) : fallback;
    };
    return {
      presets: presets.length ? presets : DEFAULT_PRESETS,
      maxPerTip: num('tip_max_per_tip', DEFAULT_MAX_PER_TIP),
      maxPerOrder: num('tip_max_per_order', DEFAULT_MAX_PER_ORDER),
    };
  }

  /** 管理端改配置（权限点 admin:tip:config；仅这三项，不动其它系统设置） */
  async updateConfig(dto: { presets?: number[]; maxPerTip?: number; maxPerOrder?: number }) {
    if (dto.presets !== undefined) {
      const presets = (dto.presets ?? []).map((v) => Number(v));
      if (!presets.length || presets.length > 8 || presets.some((v) => !Number.isInteger(v) || v <= 0 || v > 100000)) {
        throw new BadRequestException('预设金额非法（1-8 个正整数）');
      }
      await this.settings.update('tip_presets', { value: presets }, undefined, null);
    }
    if (dto.maxPerTip !== undefined) {
      const v = Number(dto.maxPerTip);
      if (!Number.isInteger(v) || v <= 0 || v > 1000000) throw new BadRequestException('单次上限非法');
      await this.settings.update('tip_max_per_tip', { value: v }, undefined, null);
    }
    if (dto.maxPerOrder !== undefined) {
      const v = Number(dto.maxPerOrder);
      if (!Number.isInteger(v) || v <= 0 || v > 1000000) throw new BadRequestException('单订单累计上限非法');
      await this.settings.update('tip_max_per_order', { value: v }, undefined, null);
    }
    return this.config();
  }

  // ---------------- 老板端 ----------------

  /**
   * 我可打赏的订单：本人订单 + 状态可打赏 + 已有接单打手。
   * 带出该订单已打赏累计（同一订单**允许重复打赏**，受 tip_max_per_order 累计上限约束）。
   */
  async tipableOrders(userId: string, page: number, pageSize: number) {
    const cfg = await this.config();
    const qb = this.dataSource
      .createQueryBuilder(Order, 'o')
      .where('o.user_id = :userId', { userId })
      .andWhere('o.status IN (:...statuses)', { statuses: TIPABLE_STATUSES })
      .andWhere('o.worker_id IS NOT NULL')
      .orderBy('o.id', 'DESC');
    const total = await qb.clone().select('COUNT(1)', 'cnt').getRawOne();
    const list = await qb.offset((page - 1) * pageSize).limit(pageSize).getMany();
    if (!list.length) {
      return { list: [], total: Number(total?.cnt ?? 0), page, pageSize, config: cfg };
    }
    const ids = list.map((o) => o.id);
    const snaps = await this.dataSource
      .getRepository(OrderPriceSnapshot)
      .createQueryBuilder('s')
      .where('s.order_id IN (:...ids)', { ids })
      .getMany();
    const snapMap = new Map(snaps.map((s) => [String(s.orderId), s]));
    const tippedMap = await this.tippedAmountMap(ids);
    const nickMap = await this.workerNicknameMap(list.map((o) => o.workerId).filter((v): v is string => !!v));
    return {
      list: list.map((o) => {
        const tipped = tippedMap.get(String(o.id)) ?? 0;
        return {
          orderId: String(o.id),
          orderNo: o.orderNo,
          status: o.status,
          totalAmount: o.totalAmount,
          productName: snapMap.get(String(o.id))?.productName ?? '',
          workerNickname: o.workerId ? (nickMap.get(String(o.workerId)) ?? '') : '',
          tippedAmount: tipped,
          remainingAmount: Math.max(0, cfg.maxPerOrder - tipped),
          createdAt: o.createdAt,
        };
      }),
      total: Number(total?.cnt ?? 0),
      page,
      pageSize,
      config: cfg,
    };
  }

  /** 我发出的打赏（老板端查看记录） */
  async myTips(userId: string, page: number, pageSize: number) {
    const [list, total] = await this.tipRepo.findAndCount({
      where: { fromUserId: userId, status: 'success' },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    return { list: await this.decorate(list), total, page, pageSize };
  }

  /**
   * 打赏（核心）：老板 → 打手，100% 过手。
   * 校验顺序固定：金额 → 上限 → 订单归属/状态/打手 → 累计上限 → 幂等 → 事务扣款/入账。
   */
  async createTip(
    userId: string,
    dto: { orderId: string; amount: number; idempotencyKey: string; remark?: string },
    meta: { ip: string; requestId: string },
  ) {
    const cfg = await this.config();
    const rawAmount = Number(dto.amount);
    // 客户端金额一律不可信：必须是 >0 且最多 2 位小数。
    // 2026-10-09 计价单位改「余额（元）」后 order_tip.amount 已由 int 改为 decimal(12,2)，
    // 因此这里放开小数（打赏预设档位本身就有 0.6 / 1.8 / 3.8 / 8.8 元）；
    // 仍然拒绝超过 2 位小数，避免"填 0.666 存成 0.67"的静默改写，
    // 也保证 wallet.balance / wallet_transaction.amount 的 decimal(14,2) 前后一致。
    if (!Number.isFinite(rawAmount) || rawAmount <= 0) {
      throw new BadRequestException('打赏金额必须大于 0');
    }
    const amount = Math.round(rawAmount * 100) / 100;
    if (Math.abs(amount - rawAmount) > 1e-9) {
      throw new BadRequestException('打赏金额最多保留 2 位小数');
    }
    if (amount > cfg.maxPerTip) {
      throw new BadRequestException(`单次打赏不能超过 ${cfg.maxPerTip} 元`);
    }
    const key = String(dto.idempotencyKey ?? '').trim();
    if (!key || key.length > 48) {
      throw new BadRequestException('幂等键非法（1-48 字符）');
    }

    // 幂等先行：同键已存在直接返回首次结果（网络重试/连点不会重复扣款）
    const existed = await this.tipRepo.findOne({ where: { idempotencyKey: key } });
    if (existed) return this.tipView(existed, true);

    const order = await this.dataSource.getRepository(Order).findOne({ where: { id: dto.orderId, userId } });
    if (!order) throw new NotFoundException('订单不存在或不属于你');
    if (!TIPABLE_STATUSES.includes(order.status)) {
      throw new BadRequestException('该订单当前状态不可打赏（仅进行中/待确认/已完成）');
    }
    if (!order.workerId) throw new BadRequestException('该订单还没有接单打手，无法打赏');
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { id: order.workerId } });
    if (!worker) throw new BadRequestException('打手档案不存在，无法打赏');

    const tipped = (await this.tippedAmountMap([String(order.id)])).get(String(order.id)) ?? 0;
    if (tipped + amount > cfg.maxPerOrder) {
      throw new BadRequestException(
        `该订单累计打赏上限 ${cfg.maxPerOrder} 元（已打赏 ${tipped}，还可打赏 ${Math.max(0, cfg.maxPerOrder - tipped)}）`,
      );
    }

    try {
      const tip = await this.dataSource.transaction(async (em) => {
        // 订单行锁：串行化同一订单的并发打赏（累计上限判定才有意义）
        const locked = await em.findOne(Order, { where: { id: order.id, userId }, lock: { mode: 'pessimistic_write' } });
        if (!locked || !TIPABLE_STATUSES.includes(locked.status)) {
          throw new BadRequestException('该订单当前状态不可打赏');
        }
        const sumRow: Array<{ s: string | null }> = await em.query(
          `SELECT COALESCE(SUM(amount), 0) AS s FROM order_tip WHERE order_id = ? AND status = 'success'`,
          [order.id],
        );
        const currentTipped = Number(sumRow[0]?.s ?? 0);
        if (currentTipped + amount > cfg.maxPerOrder) {
          throw new BadRequestException(`该订单累计打赏上限 ${cfg.maxPerOrder} 元`);
        }

        // 1) 老板钱包：行锁读快照 → 条件扣款（balance >= amount 才扣，防负余额）
        const bossWallet = await em.findOne(Wallet, { where: { userId }, lock: { mode: 'pessimistic_write' } });
        if (!bossWallet) throw new NotFoundException('钱包不存在');
        const bossBefore = bossWallet.balance;
        if (bossBefore < amount) throw new BadRequestException('余额不足，无法打赏');
        const deducted = await em
          .createQueryBuilder()
          .update(Wallet)
          .set({ balance: () => 'balance - :amt' })
          .where('id = :id AND balance >= :amt')
          .setParameters({ id: bossWallet.id, amt: amount })
          .execute();
        if (!deducted.affected) throw new BadRequestException('余额不足，无法打赏');
        const bossAfter = bossBefore - amount;
        await this.insertTxn(em, {
          userId,
          changeType: 'order_tip_out',
          amount: -amount,
          balanceBefore: bossBefore,
          balanceAfter: bossAfter,
          operatorType: 'user',
          operatorId: userId,
          source: 'client',
          reason: `打赏订单 ${order.orderNo}`,
          orderId: order.id,
          idempotencyKey: `${key}:out`,
          meta,
        });

        // 2) 打手钱包：入账 100%（平台不抽成）
        const workerWallet = await em.findOne(Wallet, { where: { userId: worker.userId }, lock: { mode: 'pessimistic_write' } });
        if (!workerWallet) throw new NotFoundException('打手钱包不存在');
        const workerBefore = workerWallet.balance;
        const workerAfter = workerBefore + amount;
        await em.update(Wallet, workerWallet.id, { balance: workerAfter });
        await this.insertTxn(em, {
          userId: worker.userId,
          changeType: 'order_tip_income',
          amount,
          balanceBefore: workerBefore,
          balanceAfter: workerAfter,
          operatorType: 'user',
          operatorId: userId,
          source: 'client',
          reason: `收到老板打赏（订单 ${order.orderNo}）`,
          orderId: order.id,
          idempotencyKey: `${key}:in`,
          meta,
        });

        // 3) 打赏记录（幂等键唯一约束兜底）
        const saved = await em.save(
          em.create(OrderTip, {
            orderId: order.id,
            fromUserId: userId,
            toUserId: worker.userId,
            toWorkerId: worker.id,
            amount,
            status: 'success',
            remark: (dto.remark ?? '').slice(0, 200),
            idempotencyKey: key,
            requestId: meta.requestId?.slice(0, 64) ?? null,
            ip: meta.ip?.slice(0, 64) ?? null,
          }),
        );

        // 4) 站内通知（与打赏同事务，打手一定能在通知里看到对应记录）
        await em.save(
          em.create(UserNotification, {
            userId: worker.userId,
            type: 'tip_received',
            title: '收到打赏',
            content: `老板打赏你 ${amount.toFixed(2)} 元（订单 ${order.orderNo}）`,
            refId: String(saved.id),
          }),
        );
        return saved;
      });

      const workerUserId = worker.userId;
      // 事务提交后再推实时事件（docs/07）
      this.realtime.emitToUser(workerUserId, 'tip:received', {
        tipId: String(tip.id),
        orderId: String(order.id),
        orderNo: order.orderNo,
        amount,
      });
      this.realtime.emitToUser(workerUserId, 'notification:new', { type: 'tip_received' });
      this.realtime.emitToUser(userId, 'tip:created', { tipId: String(tip.id), orderId: String(order.id), amount });
      this.logger.log(`打赏成功 orderNo=${order.orderNo} amount=${amount} worker=${workerUserId}`);
      return this.tipView(tip, false);
    } catch (e) {
      // 并发同键：唯一约束兜底 → 返回首次结果（只扣一次）
      if (e instanceof QueryFailedError && (e as unknown as { code?: string }).code === 'ER_DUP_ENTRY') {
        const first = await this.tipRepo.findOne({ where: { idempotencyKey: key } });
        if (first) return this.tipView(first, true);
      }
      throw e;
    }
  }

  // ---------------- 工作端 ----------------

  /** 打手收到的打赏明细（工作端「我的收益」） */
  async receivedTips(userId: string, page: number, pageSize: number) {
    const [list, total] = await this.tipRepo.findAndCount({
      where: { toUserId: userId, status: 'success' },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    return { list: await this.decorate(list, true), total, page, pageSize };
  }

  /** 打赏收益聚合（工作端 my-wallet 用）：笔数 + 总额 */
  async receivedSummary(userId: string): Promise<{ tipCount: number; tipIncome: number }> {
    const rows: Array<{ c: string; s: string | null }> = await this.dataSource.query(
      `SELECT COUNT(1) AS c, COALESCE(SUM(amount), 0) AS s FROM order_tip WHERE to_user_id = ? AND status = 'success'`,
      [userId],
    );
    return { tipCount: Number(rows[0]?.c ?? 0), tipIncome: Number(rows[0]?.s ?? 0) };
  }

  // ---------------- 管理端 ----------------

  async adminList(q: { page: number; pageSize: number; keyword?: string; orderId?: string }) {
    const qb = this.dataSource
      .createQueryBuilder(OrderTip, 't')
      .leftJoin(Order, 'o', 'o.id = t.order_id')
      .leftJoin(User, 'fu', 'fu.id = t.from_user_id')
      .leftJoin(User, 'tu', 'tu.id = t.to_user_id')
      .select([
        't.id AS id',
        't.order_id AS orderId',
        'o.order_no AS orderNo',
        't.from_user_id AS fromUserId',
        'fu.nickname AS fromNickname',
        'fu.uid AS fromUid',
        't.to_user_id AS toUserId',
        'tu.nickname AS toNickname',
        'tu.uid AS toUid',
        't.to_worker_id AS toWorkerId',
        't.amount AS amount',
        't.status AS status',
        't.remark AS remark',
        't.created_at AS createdAt',
      ]);
    if (q.orderId) qb.andWhere('t.order_id = :orderId', { orderId: q.orderId });
    if (q.keyword) {
      qb.andWhere('(o.order_no LIKE :kw OR fu.nickname LIKE :kw OR tu.nickname LIKE :kw)', { kw: `%${q.keyword}%` });
    }
    const total = await qb.clone().select('COUNT(1)', 'cnt').getRawOne();
    const list = await qb.orderBy('t.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    // 风控视角：总打赏金额 + 当日打赏金额（都是服务端实时统计，不写死）
    const stat: Array<{ total: string | null; today: string | null }> = await this.dataSource.query(
      `SELECT COALESCE(SUM(amount), 0) AS total,
              COALESCE(SUM(CASE WHEN created_at >= CURDATE() THEN amount ELSE 0 END), 0) AS today
       FROM order_tip WHERE status = 'success'`,
    );
    return {
      list: list.map((r) => mapMoney(r, ['amount'])),
      total: Number(total?.cnt ?? 0),
      page: q.page,
      pageSize: q.pageSize,
      stat: { totalAmount: Number(stat[0]?.total ?? 0), todayAmount: Number(stat[0]?.today ?? 0) },
    };
  }

  // ---------------- 内部 ----------------

  private async tippedAmountMap(orderIds: string[]): Promise<Map<string, number>> {
    const map = new Map<string, number>();
    if (!orderIds.length) return map;
    const rows: Array<{ order_id: string; s: string | null }> = await this.dataSource.query(
      `SELECT order_id, COALESCE(SUM(amount), 0) AS s FROM order_tip
       WHERE order_id IN (?) AND status = 'success' GROUP BY order_id`,
      [orderIds],
    );
    for (const r of rows) map.set(String(r.order_id), Number(r.s ?? 0));
    return map;
  }

  private async workerNicknameMap(workerIds: string[]): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    if (!workerIds.length) return map;
    const rows: Array<{ id: string; nickname: string }> = await this.dataSource.query(
      `SELECT w.id, u.nickname FROM worker w JOIN user u ON u.id = w.user_id WHERE w.id IN (?)`,
      [workerIds],
    );
    for (const r of rows) map.set(String(r.id), r.nickname ?? '');
    return map;
  }

  /** 列表补订单号/昵称（列表页只读展示） */
  private async decorate(list: OrderTip[], forWorker = false) {
    if (!list.length) return [];
    const orderIds = [...new Set(list.map((t) => String(t.orderId)))];
    const orders = await this.dataSource.getRepository(Order).find({ where: { id: In(orderIds) } });
    const orderMap = new Map(orders.map((o) => [String(o.id), o]));
    const otherIds = [...new Set(list.map((t) => String(forWorker ? t.fromUserId : t.toUserId)))];
    const users = otherIds.length ? await this.dataSource.getRepository(User).find({ where: { id: In(otherIds) } }) : [];
    const nickMap = new Map(users.map((u) => [String(u.id), u.nickname || u.uid || '']));
    return list.map((t) => ({
      id: String(t.id),
      orderId: String(t.orderId),
      orderNo: orderMap.get(String(t.orderId))?.orderNo ?? '',
      amount: t.amount,
      remark: t.remark,
      createdAt: t.createdAt,
      ...(forWorker
        ? { fromNickname: nickMap.get(String(t.fromUserId)) ?? '' }
        : { toNickname: nickMap.get(String(t.toUserId)) ?? '' }),
    }));
  }

  private tipView(tip: OrderTip, duplicated: boolean) {
    return {
      tipId: String(tip.id),
      orderId: String(tip.orderId),
      amount: tip.amount,
      status: tip.status,
      duplicated,
      createdAt: tip.createdAt,
    };
  }

  private async insertTxn(
    em: EntityManager,
    input: {
      userId: string;
      changeType: string;
      amount: number;
      balanceBefore: number;
      balanceAfter: number;
      operatorType: string;
      operatorId: string | null;
      source: string;
      reason: string;
      orderId: string | null;
      idempotencyKey: string;
      meta: { ip: string; requestId: string };
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
}
