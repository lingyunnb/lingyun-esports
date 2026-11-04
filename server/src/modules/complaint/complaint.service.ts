import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { randomInt, randomUUID } from 'crypto';
import { DataSource, Repository } from 'typeorm';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { Media } from '../media/media.entity';
import { UserNotification } from '../friend/user-notification.entity';
import {
  COMPLAINTABLE_ORDER_STATUSES,
  ORDER_NOT_COMPLAINTABLE_MESSAGE,
  isComplaintableOrderStatus,
} from '../order/order-complaintable';
import { Order } from '../order/order.entity';
import { User } from '../user/user.entity';
import { Worker } from '../worker/worker.entity';
import { Complaint, ComplaintStatus, ComplaintTargetType, ComplaintType } from './complaint.entity';

export const COMPLAINT_TARGETS: ComplaintTargetType[] = ['order', 'worker', 'service'];
export const COMPLAINT_TYPES: ComplaintType[] = ['attitude', 'not_agreed', 'delay', 'other'];
const MAX_MEDIA = 6;

/** 打手候选（投诉页「选择打手」下拉的数据形状） */
export interface ComplaintWorkerTarget {
  /** `worker.id` —— 与 `order.worker_id`、`POST /user/complaints` 的 targetId 同一口径 */
  workerId: string;
  nickname: string;
  workerNo: string;
  /** 该打手最近一次为我服务的订单号（下拉里做区分，同名打手不混淆） */
  lastOrderNo: string;
  /** 该打手为我服务过的订单数（去重后的关联强度，非全部订单计数） */
  orderCount: number;
}

/**
 * 投诉工单服务（负责人 2026-10-04：顶部导航「投诉」）
 *
 * - 老板：选对象（订单/打手/客服）+ 类型 + 描述 + 可选截图 → 提交；「我的投诉」看状态与处理结果
 * - 管理端：工单列表 + 详情 + 处理（处理中/已处理/驳回 + 处理意见）→ 结果通知投诉人
 * - 服务端权威：投诉人取自 JWT；订单/打手归属服务端校验；截图校验必须是本人上传的媒体；
 *   目标名落快照；处理走条件更新（已终结的工单不可重复处理）
 *
 * 【2026-10-05 负责人任务②③：两道此前**缺失**的服务端校验（不是"前端过滤一下"就算）】
 * 1. **可投诉订单状态**：此前只校验"订单是不是你的"，状态一个字都没看 →
 *    已取消的单照样能被投诉。现在按 `order-complaintable.ts` 的唯一口径校验，
 *    非法状态中文 400。客户端列表用同一份状态清单做查询参数（前后端同源）。
 * 2. **打手必须真有服务关系**：此前只校验"这个打手存在"→ 可投诉任意一个没接过我单的打手。
 *    现在必须存在"我 → 该打手"的可投诉订单（订单级投诉还要求就是他接的那一单），
 *    否则中文 400。候选列表接口 `workerTargets()` 用同一套 where 条件产出，
 *    所以"列表里能选"与"接口能收"恒等。
 */
@Injectable()
export class ComplaintService {
  private readonly logger = new Logger('Complaint');

  constructor(
    @InjectRepository(Complaint) private readonly repo: Repository<Complaint>,
    @InjectRepository(UserNotification) private readonly notifRepo: Repository<UserNotification>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly realtime: RealtimeGateway,
  ) {}

  // ---------------- 老板端 ----------------

  /** 提交投诉（带截图媒体：必须是本人上传的 media id，服务端逐个校验） */
  async create(
    userId: string,
    dto: { targetType: string; targetId?: string; type: string; content: string; mediaIds?: string[] },
  ) {
    const targetType = String(dto.targetType ?? '') as ComplaintTargetType;
    if (!COMPLAINT_TARGETS.includes(targetType)) throw new BadRequestException('投诉对象类型非法');
    const type = String(dto.type ?? '') as ComplaintType;
    if (!COMPLAINT_TYPES.includes(type)) throw new BadRequestException('投诉类型非法');
    const content = (dto.content ?? '').trim();
    if (content.length < 5) throw new BadRequestException('请描述清楚问题（至少 5 个字）');
    if (content.length > 1000) throw new BadRequestException('描述过长（最多 1000 字）');

    const targetId = String(dto.targetId ?? '').trim();
    // 目标校验 + 名称快照（服务端权威；订单必须属于本人**且处于可投诉状态**，打手必须**真接过我单**）
    let targetName = '';
    if (targetType === 'order') {
      if (!targetId) throw new BadRequestException('请选择要投诉的订单');
      const order = await this.dataSource.getRepository(Order).findOne({ where: { id: targetId, userId } });
      if (!order) throw new NotFoundException('订单不存在或不属于你');
      // 【任务②】状态校验：口径见 order-complaintable.ts（排除 canceled / 未接单 / abnormal）
      if (!isComplaintableOrderStatus(order.status)) {
        throw new BadRequestException(ORDER_NOT_COMPLAINTABLE_MESSAGE);
      }
      // 快照：订单号 + 接单打手昵称（打手可能为空 = 尚未有人接单，但状态已保证可投诉）
      const workerName = order.workerId ? await this.workerNickname(order.workerId) : '';
      targetName = workerName ? `${order.orderNo} · ${workerName}` : order.orderNo;
    } else if (targetType === 'worker') {
      if (!targetId) throw new BadRequestException('请选择要投诉的打手');
      const worker = await this.dataSource.getRepository(Worker).findOne({ where: { id: targetId } });
      if (!worker) throw new NotFoundException('打手不存在');
      // 【任务③】服务关系校验：必须存在"我 → 该打手"的可投诉订单，否则拒绝。
      // 这是权威判定：客户端下拉只列关联打手，但即便被篡改成任意 workerId，这里也会拦下。
      const relation = await this.serviceRelationExists(userId, targetId);
      if (!relation) {
        throw new BadRequestException('该打手没有接过你的订单，无法投诉');
      }
      const wu = await this.dataSource.getRepository(User).findOne({ where: { id: worker.userId } });
      targetName = wu?.nickname || wu?.uid || `打手${worker.workerNo}`;
    } else {
      // 客服：目标可为空（由客服侧认领）或客服账号标识
      targetName = targetId ? targetId.slice(0, 64) : '在线客服';
    }

    // 截图：只接受本人上传的媒体，最多 6 张（防越权挂他人媒体 / 防 IDOR）
    const rawIds = (dto.mediaIds ?? []).map((v) => String(v).trim()).filter((v) => v.length > 0);
    if (rawIds.length > MAX_MEDIA) throw new BadRequestException(`最多上传 ${MAX_MEDIA} 张截图`);
    if (rawIds.length) {
      const owned = await this.dataSource
        .getRepository(Media)
        .createQueryBuilder('m')
        .where('m.id IN (:...ids)', { ids: rawIds })
        .andWhere('m.uploader_id = :userId', { userId })
        .getMany();
      if (owned.length !== rawIds.length) throw new BadRequestException('截图只能选择本人上传的图片');
    }

    const saved = await this.repo.save(
      this.repo.create({
        complaintNo: this.generateNo(),
        userId,
        targetType,
        targetId,
        targetName,
        type,
        content,
        mediaIds: rawIds.join(','),
        status: 'pending',
      }),
    );
    // 管理端实时提醒（新工单）
    this.realtime.emitToAdmins('complaint:new', {
      complaintId: String(saved.id),
      targetType,
      type,
      complaintNo: saved.complaintNo,
    });
    this.logger.log(`投诉提交 ${saved.complaintNo} target=${targetType}:${targetId} type=${type}`);
    return { id: String(saved.id), complaintNo: saved.complaintNo, status: saved.status, mediaCount: rawIds.length };
  }

  /** 我的投诉（含处理结果） */
  async myList(userId: string, page: number, pageSize: number) {
    const [list, total] = await this.repo.findAndCount({
      where: { userId },
      order: { id: 'DESC' },
      skip: (page - 1) * pageSize,
      take: pageSize,
    });
    return {
      list: list.map((c) => ({
        id: String(c.id),
        complaintNo: c.complaintNo,
        targetType: c.targetType,
        targetId: c.targetId,
        targetName: c.targetName,
        type: c.type,
        content: c.content,
        mediaIds: c.mediaIds ? c.mediaIds.split(',') : [],
        status: c.status,
        handleRemark: c.handleRemark,
        handledAt: c.handledAt,
        createdAt: c.createdAt,
      })),
      total,
      page,
      pageSize,
    };
  }

  /**
   * 可投诉打手候选（【任务③】服务端权威列表）
   *
   * 语义（与 `create()` 的校验**同一套 where 条件**，所以"列表能选"⇔"接口能收"）：
   * - **带 orderId（针对某一订单投诉）**：只返回**该订单的接单打手**（最严格）——
   *   订单不属于本人 / 未接单 / 状态不可投诉 → 返回空列表（不是报错，页面显示"该订单暂无关联打手"）。
   * - **不带 orderId（通用投诉）**：返回**曾接过我订单的打手**，按 `worker.id` 去重
   *   （`order.user_id = 我 AND order.worker_id IS NOT NULL AND order.status IN 可投诉状态`）。
   *
   * 只认"真实服务过"的订单：`pending_take`/`pending_dispatch`（还没人接）与
   * `canceled`（负责人要求已取消的单不算服务）、`abnormal`（平台裁决中）都不构成服务关系。
   */
  async workerTargets(userId: string, orderId?: string): Promise<ComplaintWorkerTarget[]> {
    const qb = this.dataSource
      .createQueryBuilder(Order, 'o')
      .innerJoin(Worker, 'w', 'w.id = o.worker_id')
      .innerJoin(User, 'u', 'u.id = w.user_id')
      .select([
        'w.id AS workerId',
        'w.worker_no AS workerNo',
        'u.nickname AS nickname',
        'COUNT(1) AS orderCount',
        'MAX(o.id) AS lastOrderId',
      ])
      .where('o.user_id = :userId', { userId })
      .andWhere('o.worker_id IS NOT NULL')
      .andWhere('o.status IN (:...statuses)', { statuses: COMPLAINTABLE_ORDER_STATUSES });
    const target = String(orderId ?? '').trim();
    if (target) qb.andWhere('o.id = :orderId', { orderId: target });
    const rows = await qb.groupBy('w.id').addGroupBy('w.worker_no').addGroupBy('u.nickname').orderBy('MAX(o.id)', 'DESC').getRawMany<
      Record<string, unknown>
    >();
    if (!rows.length) return [];

    // 「最近一单的订单号」批量补一次（避免每行一次查询；组数=关联打手数，通常个位数）
    const lastIds = rows.map((r) => String(r.lastOrderId));
    const lastOrders = await this.dataSource
      .createQueryBuilder(Order, 'o')
      .select(['o.id AS id', 'o.order_no AS orderNo'])
      .where('o.id IN (:...ids)', { ids: lastIds })
      .getRawMany<{ id: string; orderNo: string }>();
    const noMap = new Map(lastOrders.map((o) => [String(o.id), o.orderNo]));

    return rows.map((r) => ({
      workerId: String(r.workerId),
      workerNo: String(r.workerNo ?? ''),
      nickname: String(r.nickname ?? ''),
      lastOrderNo: noMap.get(String(r.lastOrderId)) ?? '',
      orderCount: Number(r.orderCount ?? 0),
    }));
  }

  // ---------------- 管理端 ----------------

  async adminList(q: { status?: string; targetType?: string; page: number; pageSize: number }) {
    const qb = this.dataSource
      .createQueryBuilder(Complaint, 'c')
      .leftJoin(User, 'u', 'u.id = c.user_id')
      .select([
        'c.id AS id',
        'c.complaint_no AS complaintNo',
        'c.user_id AS userId',
        'u.nickname AS nickname',
        'u.uid AS uid',
        'c.target_type AS targetType',
        'c.target_id AS targetId',
        'c.target_name AS targetName',
        'c.type AS type',
        'c.content AS content',
        'c.media_ids AS mediaIds',
        'c.status AS status',
        'c.handle_remark AS handleRemark',
        'c.handled_at AS handledAt',
        'c.created_at AS createdAt',
      ]);
    if (q.status) qb.andWhere('c.status = :status', { status: q.status });
    if (q.targetType) qb.andWhere('c.target_type = :targetType', { targetType: q.targetType });
    const total = await qb.clone().select('COUNT(1)', 'cnt').getRawOne();
    const list = await qb.orderBy('c.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    const counts: Array<{ status: string; c: string }> = await this.dataSource.query(
      `SELECT status, COUNT(1) AS c FROM complaint GROUP BY status`,
    );
    const stat: Record<string, number> = { pending: 0, processing: 0, handled: 0, rejected: 0 };
    for (const r of counts) stat[r.status] = Number(r.c);
    return {
      list: list.map((r) => ({
        ...r,
        id: String(r.id),
        mediaIds: r.mediaIds ? String(r.mediaIds).split(',') : [],
      })),
      total: Number(total?.cnt ?? 0),
      page: q.page,
      pageSize: q.pageSize,
      stat,
    };
  }

  async adminDetail(id: string) {
    const c = await this.repo.findOne({ where: { id } });
    if (!c) throw new NotFoundException('投诉不存在');
    const user = await this.dataSource.getRepository(User).findOne({ where: { id: c.userId } });
    const mediaIds = c.mediaIds ? c.mediaIds.split(',') : [];
    const medias = mediaIds.length
      ? await this.dataSource.getRepository(Media).find({ where: mediaIds.map((mid) => ({ id: mid })) })
      : [];
    return {
      id: String(c.id),
      complaintNo: c.complaintNo,
      userId: String(c.userId),
      nickname: user?.nickname ?? '',
      uid: user?.uid ?? '',
      targetType: c.targetType,
      targetId: c.targetId,
      targetName: c.targetName,
      type: c.type,
      content: c.content,
      mediaIds,
      medias: medias.map((m) => ({ id: String(m.id), mimeType: m.mimeType, mediaType: m.mediaType })),
      status: c.status,
      handleRemark: c.handleRemark,
      handledBy: c.handledBy,
      handledAt: c.handledAt,
      createdAt: c.createdAt,
    };
  }

  /**
   * 处理工单：processing 处理中 / handled 已处理 / rejected 驳回（终态必须给处理意见）。
   * 条件更新防重复处理：已是 handled/rejected 的工单不可再次流转。
   */
  async adminHandle(adminUserId: string, id: string, dto: { status: string; remark?: string }) {
    const status = String(dto.status ?? '') as ComplaintStatus;
    if (!['processing', 'handled', 'rejected'].includes(status)) {
      throw new BadRequestException('处理状态非法（只能是：处理中、已处理、已驳回）');
    }
    const remark = (dto.remark ?? '').trim();
    if ((status === 'handled' || status === 'rejected') && !remark) {
      throw new BadRequestException('请填写处理意见');
    }
    const c = await this.repo.findOne({ where: { id } });
    if (!c) throw new NotFoundException('投诉不存在');
    if (c.status === 'handled' || c.status === 'rejected') {
      throw new BadRequestException('该投诉已处理完毕，不能重复处理');
    }
    const updated = await this.repo
      .createQueryBuilder()
      .update(Complaint)
      .set({
        status,
        handleRemark: remark.slice(0, 500),
        handledBy: adminUserId,
        // 处理中只是认领，不写结案时间；结案（handled/rejected）才落时间
        handledAt: status === 'processing' ? null : new Date(),
      })
      .where('id = :id AND status IN (:...open)', { id: c.id, open: ['pending', 'processing'] })
      .execute();
    if (!updated.affected) throw new BadRequestException('该投诉已被其他管理员处理，请刷新');

    // 处理结果通知投诉人（站内通知 + 实时）
    const titleMap: Record<string, string> = {
      processing: '投诉处理中',
      handled: '投诉已处理',
      rejected: '投诉未通过',
    };
    await this.notifRepo.save(
      this.notifRepo.create({
        userId: c.userId,
        type: 'complaint_handled',
        title: titleMap[status],
        content: `工单 ${c.complaintNo}：${titleMap[status]}${remark ? `｜处理意见：${remark}` : ''}`,
        refId: String(c.id),
      }),
    );
    this.realtime.emitToUser(c.userId, 'complaint:handled', {
      complaintId: String(c.id),
      complaintNo: c.complaintNo,
      status,
      remark,
    });
    this.realtime.emitToUser(c.userId, 'notification:new', { type: 'complaint_handled' });
    this.logger.log(`投诉处理 ${c.complaintNo} → ${status} by admin=${adminUserId}`);
    return { ok: true, status };
  }

  private generateNo(): string {
    return `C${Date.now().toString(36).toUpperCase()}${randomInt(1000, 10000)}${randomUUID().slice(0, 4).toUpperCase()}`;
  }

  /**
   * 【任务③权威判定】「我 → 该打手」是否存在真实服务关系
   *
   * 判定条件与 `workerTargets()` 完全一致（同一份状态口径 + 同一张 order 表）：
   * `order.user_id = 我 AND order.worker_id = 该打手 AND order.status ∈ 可投诉状态`。
   * 命中任意一单即视为"接过我的单"（通用投诉按人去重，不要求指定订单）。
   */
  private async serviceRelationExists(userId: string, workerId: string): Promise<boolean> {
    const row = await this.dataSource
      .createQueryBuilder(Order, 'o')
      .select('o.id', 'id')
      .where('o.user_id = :userId', { userId })
      .andWhere('o.worker_id = :workerId', { workerId })
      .andWhere('o.status IN (:...statuses)', { statuses: COMPLAINTABLE_ORDER_STATUSES })
      .limit(1)
      .getRawOne<{ id: string }>();
    return !!row;
  }

  /** 接单打手昵称（订单投诉的名称快照用；查不到返回空串，不抛错） */
  private async workerNickname(workerId: string): Promise<string> {
    const row = await this.dataSource
      .createQueryBuilder(Worker, 'w')
      .innerJoin(User, 'u', 'u.id = w.user_id')
      .select(['u.nickname AS nickname', 'u.uid AS uid'])
      .where('w.id = :workerId', { workerId })
      .getRawOne<{ nickname: string | null; uid: string | null }>();
    return row?.nickname || row?.uid || '';
  }
}
