import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 好友关系（负责人需求 #16）：申请/同意/拒绝/删除全走服务端；唯一约束防重复申请 */
@Entity('user_friend')
@Index('IDX_friend_addressee', ['addresseeId', 'status'])
export class UserFriend {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'requester_id', type: 'bigint', unsigned: true })
  requesterId: string;

  @Column({ name: 'addressee_id', type: 'bigint', unsigned: true })
  addresseeId: string;

  /** pending 待处理 / accepted 已同意 / rejected 已拒绝 / removed 已删除 */
  @Column({ type: 'varchar', length: 16, default: 'pending' })
  status: string;

  @Column({ type: 'varchar', length: 255, default: '' })
  message: string;

  @Column({ name: 'acted_at', type: 'datetime', precision: 3, nullable: true })
  actedAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
