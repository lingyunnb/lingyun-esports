import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 退款申请（负责人 2026-10-04：顶部导航「退款」）
 *
 * 业务：老板对**未结束的订单**（未开始/进行中/待确认）提交退款申请 → 管理端审批。
 * - 通过：原路退回老板余额（未结算订单退还订单金额；已结算订单先按该单结算记录冲正打手与平台，再全额退还）
 *   —— 与既有 `cancelByUser` / `cancelByAdmin` / 申诉退款**同一套流水与幂等键**（docs/06）
 * - 驳回：必须填理由，订单状态不变，结果通知申请人
 * 防重复：`idempotency_key` 唯一约束（提交）+ `status` 条件更新（审批）+ 订单退款流水唯一幂等键（退款）
 */
@Entity('refund_request')
@Index('UQ_refund_request_no', ['requestNo'], { unique: true })
@Index('UQ_refund_request_idem', ['idempotencyKey'], { unique: true })
@Index('IDX_refund_request_status', ['status', 'id'])
@Index('IDX_refund_request_user', ['userId', 'id'])
export class RefundRequest {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'request_no', length: 32 })
  requestNo: string;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true })
  orderId: string;

  /** 申请人（订单老板，取自 JWT） */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 申请退款金额（= 订单金额快照，服务端算，客户端不可传） */
  @Column({ type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  amount: number;

  /** 申请时订单状态（留痕；审批通过后订单进入 canceled） */
  @Column({ name: 'prev_status', type: 'varchar', length: 20 })
  prevStatus: string;

  @Column({ type: 'varchar', length: 200, default: '' })
  reason: string;

  @Column({ type: 'varchar', length: 500, default: '' })
  remark: string;

  /** pending 待处理 / approved 已通过（已退款）/ rejected 已驳回 */
  @Column({ type: 'varchar', length: 16, default: 'pending' })
  status: string;

  @Column({ name: 'handler_id', type: 'bigint', unsigned: true, nullable: true })
  handlerId: string | null;

  @Column({ name: 'handler_remark', type: 'varchar', length: 500, default: '' })
  handlerRemark: string;

  @Column({ name: 'handled_at', type: 'datetime', precision: 3, nullable: true })
  handledAt: Date | null;

  @Column({ name: 'idempotency_key', type: 'varchar', length: 64 })
  idempotencyKey: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
