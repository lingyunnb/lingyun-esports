import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/**
 * 打赏记录（负责人 2026-10-04：顶部导航「打赏」，用余额打赏）
 *
 * 业务：老板对**自己的订单**打赏，余额从老板钱包 100% 划到打手钱包（平台不抽成）。
 * 铁律（docs/06）：
 * - 钱包余额/金额一律服务端权威，客户端只传 orderId + amount + idempotencyKey
 * - `idempotency_key` 唯一约束：同键重复提交（网络重试/连点）只扣一次
 * - 打赏与两条流水在同一事务内，任一步失败整体回滚（不产生半笔打赏）
 * - 仅允许打赏「进行中 / 待确认 / 已完成」且已有接单打手的订单
 */
@Entity('order_tip')
@Index('UQ_order_tip_idem', ['idempotencyKey'], { unique: true })
@Index('IDX_order_tip_order', ['orderId'])
@Index('IDX_order_tip_from', ['fromUserId', 'id'])
@Index('IDX_order_tip_to_user', ['toUserId', 'id'])
export class OrderTip {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true })
  orderId: string;

  /** 打赏老板（钱包扣减方，取自 JWT） */
  @Column({ name: 'from_user_id', type: 'bigint', unsigned: true })
  fromUserId: string;

  /** 打手登录账号（钱包入账方，服务端按订单 worker_id 反查，客户端不可指定） */
  @Column({ name: 'to_user_id', type: 'bigint', unsigned: true })
  toUserId: string;

  /** 打手档案 worker.id */
  @Column({ name: 'to_worker_id', type: 'bigint', unsigned: true })
  toWorkerId: string;

  /** 打赏金额（元，最多 2 位小数） */
  @Column({ type: 'int' })
  amount: number;

  /** success / failed（失败不留痕；字段保留供对账扩展） */
  @Column({ type: 'varchar', length: 16, default: 'success' })
  status: string;

  @Column({ type: 'varchar', length: 200, default: '' })
  remark: string;

  @Column({ name: 'idempotency_key', type: 'varchar', length: 64 })
  idempotencyKey: string;

  @Column({ name: 'request_id', type: 'varchar', length: 64, nullable: true })
  requestId: string | null;

  @Column({ type: 'varchar', length: 64, nullable: true })
  ip: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
