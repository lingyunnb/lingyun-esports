import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 意见反馈（设置页入口）：用户提交 → 管理端查看/处理留痕 */
@Entity('user_feedback')
@Index('IDX_feedback_status', ['status', 'id'])
export class UserFeedback {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  @Column({ type: 'varchar', length: 1000 })
  content: string;

  @Column({ type: 'varchar', length: 100, default: '' })
  contact: string;

  /** 1 待处理 / 2 已处理 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  @Column({ name: 'handler_id', type: 'bigint', unsigned: true, nullable: true })
  handlerId: string | null;

  @Column({ name: 'handler_remark', type: 'varchar', length: 500, default: '' })
  handlerRemark: string;

  @Column({ name: 'handled_at', type: 'datetime', precision: 3, nullable: true })
  handledAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
