import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 售后申诉（docs/05）：用户申诉 → 管理员裁决（退款/驳回），一单一次 */
@Entity('order_appeal')
@Index('IDX_appeal_status', ['status'])
@Index('IDX_appeal_user', ['userId'])
export class OrderAppeal {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true, unique: true })
  orderId: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 申诉前订单状态（裁决驳回时还原） */
  @Column({ name: 'prev_status', length: 20 })
  prevStatus: string;

  @Column({ length: 500, default: '' })
  reason: string;

  /** open 待处理 / handled 已处理 */
  @Column({ length: 16, default: 'open' })
  status: string;

  /** refund 退款 / dismiss 驳回（处理完成时写入） */
  @Column({ type: 'varchar', length: 16, nullable: true })
  result: string | null;

  @Column({ name: 'handler_id', type: 'bigint', unsigned: true, nullable: true })
  handlerId: string | null;

  @Column({ name: 'handler_remark', type: 'varchar', length: 500, nullable: true })
  handlerRemark: string | null;

  @Column({ name: 'handled_at', type: 'datetime', precision: 3, nullable: true })
  handledAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
