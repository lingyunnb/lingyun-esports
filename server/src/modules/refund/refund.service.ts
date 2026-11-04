import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { randomInt, randomUUID } from 'crypto';
import { DataSource, QueryFailedError, Repository } from 'typeorm';
import { mapMoney } from '../../common/money.transformer';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { UserNotification } from '../friend/user-notification.entity';
import { Order } from '../order/order.entity';
import { OrderPriceSnapshot } from '../order/order-price-snapshot.entity';
import { OrderService } from '../order/order.service';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { RefundRequest } from './refund-request.entity';

/** 可申请退款的订单状态（默认；管理端 system_setting `refund_apply_statuses` 可改） */
const DEFAULT_APPLY_STATUSES = ['pending_take', 'pending_dispatch', 'taken', 'in_progress', 'pending_confirm'];

/**
 * 退款服务（负责人 2026-10-04：顶部导航「退款」）
 *
 * - 老板：列出可申请退款的订单（未开始/进行中/待确认；**已完成走既有申诉**）→ 提交申请
 * - 管理端：待处理/已通过/已驳回 → 通过=原路退回余额（未结算退订单金额；已结算走既有冲正），
 *   驳回=必填理由；全程状态流转 + 双方通知
 * - 铁律：退款复用 [OrderService.adminRefundOrderTx]（同一套 `order_refund` 流水与 `refund:{orderId}` 幂等键），
 *   三层防重复：申请幂等键唯一约束 / 审批 status 条件更新 / 订单退款流水幂等键唯一
 */
@Injectable()
export class RefundService {
  private readonly logger = new Logger('Refund');

  constructor(
    @InjectRepository(RefundRequest) private readonly repo: Repository<RefundRequest>,
    @InjectRepository(UserNotification) private readonly notifRepo: Repository<UserNotification>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly orders: OrderService,
    private readonly settings: SystemSettingService,
    private readonly realtime: RealtimeGateway,
  ) {}

  /** 可申请退款的状态（管理端可配；非法配置回落默认值，绝不放行 completed） */
  async applyStatuses(): Promise<string[]> {
    const row = await this.settings.get('refund_apply_statuses');
    const v = row?.cfgValue?.['value'];
    if (!Array.isArray(v)) return DEFAULT_APPLY_STATUSES;
    const list = v.map((s) => String(s)).filter((s) => DEFAULT_APPLY_STATUSES.includes(s));
    return list.length ? list : DEFAULT_APPLY_STATUSES;
  }

  // ---------------- 老板端 ----------------

  /** 可申请退款的订单（本人 + 状态允许 + 没有待处理申请） */
  async creatableOrders(userId: string, page: number, pageSize: number) {
    const statuses = await this.applyStatuses();
    const qb = this.dataSource
      .createQueryBuilder(Order, 'o')
      .where('o.user_id = :userId', { userId })
      .andWhere('o.status IN (:...statuses)', { statuses })
      .andWhere(
        `NOT EXISTS (SELECT 1 FROM refund_request r WHERE r.order_id = o.id AND r.status = 'pending')`,
      )
      .orderBy('o.id', 'DESC');
    const total = await qb.clone().select('COUNT(1)', 'cnt').getRawOne();
    const list = await qb.offset((page - 1) * pageSize).limit(pageSize).getMany();
    if (!list.length) return { list: [], total: Number(total?.cnt ?? 0), page, pageSize };
    const snaps = await this.dataSource
      .getRepository(OrderPriceSnapshot)
      .createQueryBuilder('s')
      .where('s.order_id IN (:...ids)', { ids: list.map((o) => o.id) })
      .getMany();
    const snapMap = new Map(snaps.map((s) => [String(s.orderId), s]));
    return {
      list: list.map((o) => ({
        orderId: String(o.id),
        orderNo: o.orderNo,
        status: o.status,
        totalAmount: o.totalAmount,
        productName: snapMap.get(String(o.id))?.productName ?? '',
        createdAt: o.createdAt,
      })),
      total: Number(total?.cnt ?? 0),
      page,
      pageSize,
    };
  }

  /** 我的退款申请 */
  async myRequests(userId: string, page: number, pageSize: number) {
    const [list, total] = await this.repo.findAndCount({
      where: { userId },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    return { list: await this.decorate(list), total, page, pageSize };
  }

  /** 提交退款申请（幂等键唯一约束；同一订单同时只允许一条待处理申请） */
  async create(
    userId: string,
    dto: { orderId: string; reason: string; remark?: string; idempotencyKey: string },
    meta: { ip: string; requestId: string },
  ) {
    const reason = (dto.reason ?? '').trim();
    if (!reason) throw new BadRequestException('请填写退款原因');
    if (reason.length > 100) throw new BadRequestException('退款原因过长（最多 100 字）');
    const key = String(dto.idempotencyKey ?? '').trim();
    if (!key || key.length > 64) throw new BadRequestException('幂等键非法（1-64 字符）');

    const existed = await this.repo.findOne({ where: { idempotencyKey: key } });
    if (existed) return this.requestView(existed, true);

    const order = await this.dataSource.getRepository(Order).findOne({ where: { id: dto.orderId, userId } });
    if (!order) throw new NotFoundException('订单不存在或不属于你');
    const statuses = await this.applyStatuses();
    if (!statuses.includes(order.status)) {
      throw new BadRequestException(
        order.status === 'completed' ? '已完成订单请在订单详情里申请售后' : '该订单当前状态不可申请退款',
      );
    }

    try {
      const saved = await this.dataSource.transaction(async (em) => {
        // 订单行锁：同一订单并发提交只有一条能过（另一条被下面的待处理校验拦住）
        const locked = await em.findOne(Order, { where: { id: order.id, userId }, lock: { mode: 'pessimistic_write' } });
        if (!locked) throw new NotFoundException('订单不存在或不属于你');
        const pending = await em.findOne(RefundRequest, { where: { orderId: order.id, status: 'pending' } });
        if (pending) throw new BadRequestException('该订单已有退款申请在处理中');
        return em.save(
          em.create(RefundRequest, {
            requestNo: this.generateRequestNo(),
            orderId: order.id,
            userId,
            amount: order.totalAmount,
            prevStatus: locked.status,
            reason,
            remark: (dto.remark ?? '').slice(0, 500),
            status: 'pending',
            idempotencyKey: key,
          }),
        );
      });
      this.realtime.emitToAdmins('refund:new', {
        requestId: String(saved.id),
        orderId: String(order.id),
        orderNo: order.orderNo,
        amount: order.totalAmount,
      });
      this.logger.log(`退款申请 submitted orderNo=${order.orderNo} requestNo=${saved.requestNo}`);
      return this.requestView(saved, false);
    } catch (e) {
      if (e instanceof QueryFailedError && (e as unknown as { code?: string }).code === 'ER_DUP_ENTRY') {
        const first = await this.repo.findOne({ where: { idempotencyKey: key } });
        if (first) return this.requestView(first, true);
      }
      throw e;
    }
  }

  // ---------------- 管理端 ----------------

  async adminList(q: { status?: string; page: number; pageSize: number }) {
    const qb = this.dataSource
      .createQueryBuilder(RefundRequest, 'r')
      .leftJoin(Order, 'o', 'o.id = r.order_id')
      .leftJoin(User, 'u', 'u.id = r.user_id')
      .select([
        'r.id AS id',
        'r.request_no AS requestNo',
        'r.order_id AS orderId',
        'o.order_no AS orderNo',
        'o.status AS orderStatus',
        'r.user_id AS userId',
        'u.nickname AS nickname',
        'u.uid AS uid',
        'r.amount AS amount',
        'r.prev_status AS prevStatus',
        'r.reason AS reason',
        'r.remark AS remark',
        'r.status AS status',
        'r.handler_remark AS handlerRemark',
        'r.handled_at AS handledAt',
        'r.created_at AS createdAt',
      ]);
    if (q.status) qb.andWhere('r.status = :status', { status: q.status });
    const total = await qb.clone().select('COUNT(1)', 'cnt').getRawOne();
    const list = await qb.orderBy('r.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    const counts: Array<{ status: string; c: string }> = await this.dataSource.query(
      `SELECT status, COUNT(1) AS c FROM refund_request GROUP BY status`,
    );
    const stat = { pending: 0, approved: 0, rejected: 0 };
    for (const c of counts) {
      if (c.status in stat) stat[c.status as keyof typeof stat] = Number(c.c);
    }
    return { list: list.map((r) => mapMoney(r, ['amount'])), total: Number(total?.cnt ?? 0), page: q.page, pageSize: q.pageSize, stat };
  }

  /**
   * 审批：approve = 原路退回余额（同一事务：订单行锁 → 退款流水 → 申请置已通过）；
   * reject = 必填理由，订单状态不变。
   * 重复审批：`UPDATE ... WHERE status='pending'` 判 affectedRows，第二次必然 0 → 明确报错，绝不二次退款。
   */
  async adminHandle(
    adminUserId: string,
    id: string,
    dto: { action: 'approve' | 'reject'; remark?: string },
    meta: { ip: string; requestId: string },
  ) {
    if (dto.action !== 'approve' && dto.action !== 'reject') {
      throw new BadRequestException('审批动作非法（只能是：通过、驳回）');
    }
    const remark = (dto.remark ?? '').trim();
    if (dto.action === 'reject' && !remark) {
      throw new BadRequestException('驳回必须填写理由');
    }

    let appliedOrderId = '';
    const outcome = await this.dataSource.transaction(async (em) => {
      const req = await em.findOne(RefundRequest, { where: { id }, lock: { mode: 'pessimistic_write' } });
      if (!req) throw new NotFoundException('退款申请不存在');
      if (req.status !== 'pending') throw new BadRequestException('该退款申请已处理，不能重复审批');
      appliedOrderId = String(req.orderId);
      const order = await em.findOne(Order, { where: { id: req.orderId }, lock: { mode: 'pessimistic_write' } });
      if (!order) throw new NotFoundException('订单不存在');

      let direct = null;
      if (dto.action === 'approve') {
        // 该状态已终态/售后中：不允许再退（防绕过状态机重复退款）
        if (['canceled', 'completed', 'after_sale'].includes(order.status)) {
          throw new BadRequestException('订单当前状态不允许退款（已取消/已完成/售后中）');
        }
        // 双重保险：同一订单已存在 order_refund 流水 → 拒绝（历史上被其它路径退过）
        const dup: Array<{ id: string }> = await em.query(
          `SELECT id FROM wallet_transaction WHERE order_id = ? AND change_type = 'order_refund' LIMIT 1`,
          [order.id],
        );
        if (dup.length) throw new BadRequestException('该订单已退款，不能重复退款');
        direct = await this.orders.adminRefundOrderTx(
          em,
          order,
          order.status,
          adminUserId,
          { reason: `退款审批通过：${req.reason}`, logRemark: `退款审批通过：${remark || req.reason}` },
          meta,
        );
      }

      // 审批落结果（条件更新：并发/重复点击只有一个成功）
      const updated = await em
        .createQueryBuilder()
        .update(RefundRequest)
        .set({
          status: dto.action === 'approve' ? 'approved' : 'rejected',
          handlerId: adminUserId,
          handlerRemark: remark.slice(0, 500),
          handledAt: new Date(),
        })
        .where('id = :id AND status = :pending')
        .setParameters({ id: req.id, pending: 'pending' })
        .execute();
      if (!updated.affected) throw new BadRequestException('该退款申请已处理，不能重复审批');

      // 站内通知申请人（与审批同事务）
      await em.save(
        em.create(UserNotification, {
          userId: req.userId,
          type: 'refund_handled',
          title: dto.action === 'approve' ? '退款已通过' : '退款被驳回',
          content:
            dto.action === 'approve'
              ? `订单 ${order.orderNo} 退款申请已通过，${order.totalAmount} 元已原路退回`
              : `订单 ${order.orderNo} 退款申请被驳回：${remark}`,
          refId: String(req.id),
        }),
      );
      return { direct, userId: String(req.userId), orderNo: order.orderNo, amount: Number(order.totalAmount) };
    });

    // 事务提交后推实时事件 + 会话收尾事件（复用订单服务的会话事件规则）
    this.realtime.emitToUser(outcome.userId, 'refund:handled', {
      orderId: appliedOrderId,
      action: dto.action,
      remark,
    });
    this.realtime.emitToUser(outcome.userId, 'notification:new', { type: 'refund_handled' });
    this.orders.emitDirectChatEvent(outcome.direct, appliedOrderId, dto.action === 'approve' ? 'refund_approved_canceled' : 'refund_rejected');
    this.logger.log(`退款审批 ${dto.action} requestId=${id} orderNo=${outcome.orderNo} amount=${outcome.amount}`);
    return { ok: true, action: dto.action };
  }

  // ---------------- 内部 ----------------

  /** 列表补订单号与申请人（只读展示） */
  private async decorate(list: RefundRequest[]) {
    if (!list.length) return [];
    const rows: Array<{ id: string; order_no: string }> = await this.dataSource.query(
      `SELECT id, order_no FROM \`order\` WHERE id IN (?)`,
      [[...new Set(list.map((r) => String(r.orderId)))]],
    );
    const noMap = new Map(rows.map((r) => [String(r.id), r.order_no]));
    return list.map((r) => ({
      id: String(r.id),
      requestNo: r.requestNo,
      orderId: String(r.orderId),
      orderNo: noMap.get(String(r.orderId)) ?? '',
      amount: r.amount,
      prevStatus: r.prevStatus,
      reason: r.reason,
      remark: r.remark,
      status: r.status,
      handlerRemark: r.handlerRemark,
      handledAt: r.handledAt,
      createdAt: r.createdAt,
    }));
  }

  private requestView(req: RefundRequest, duplicated: boolean) {
    return {
      id: String(req.id),
      requestNo: req.requestNo,
      orderId: String(req.orderId),
      amount: req.amount,
      status: req.status,
      duplicated,
      createdAt: req.createdAt,
    };
  }

  private generateRequestNo(): string {
    return `R${Date.now().toString(36).toUpperCase()}${randomInt(1000, 10000)}${randomUUID().slice(0, 4).toUpperCase()}`;
  }
}
