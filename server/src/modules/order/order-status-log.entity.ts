import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 订单状态流转日志（docs/05）：每次变化必写，非法迁移在写入前即被拒绝 */
@Entity('order_status_log')
@Index('IDX_order_status_log_order', ['orderId', 'id'])
export class OrderStatusLog {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true })
  orderId: string;

  @Column({ name: 'from_status', type: 'varchar', length: 20 })
  fromStatus: string;

  @Column({ name: 'to_status', type: 'varchar', length: 20 })
  toStatus: string;

  /** system / user / worker / admin */
  @Column({ name: 'operator_type', type: 'varchar', length: 16 })
  operatorType: string;

  @Column({ name: 'operator_id', type: 'bigint', unsigned: true, nullable: true })
  operatorId: string | null;

  @Column({ type: 'varchar', length: 16 })
  source: string;

  @Column({ name: 'request_id', type: 'varchar', length: 64, nullable: true })
  requestId: string | null;

  @Column({ type: 'varchar', length: 255, nullable: true })
  remark: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
