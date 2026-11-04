import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 系统通知（好友申请/通过等，docs/07 补充）：服务端写入，客户端只读/已读 */
@Entity('user_notification')
@Index('IDX_notif_user', ['userId', 'isRead', 'id'])
export class UserNotification {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  @Column({ type: 'varchar', length: 32 })
  type: string;

  @Column({ type: 'varchar', length: 100, default: '' })
  title: string;

  @Column({ type: 'varchar', length: 500, default: '' })
  content: string;

  @Column({ name: 'ref_id', type: 'varchar', length: 64, nullable: true })
  refId: string | null;

  @Column({ name: 'is_read', type: 'tinyint', default: 0 })
  isRead: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
