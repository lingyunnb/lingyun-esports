import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, Unique } from 'typeorm';

/** 群组成员（订单群，负责人需求 2026-09-24）：老板/打手/管理员；每成员独立未读 */
@Entity('chat_conversation_member')
@Unique('UQ_conv_member', ['conversationId', 'userId'])
@Index('IDX_member_user', ['userId'])
export class ChatConversationMember {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'conversation_id', type: 'bigint', unsigned: true })
  conversationId: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** boss 下单老板 / worker 打手 / admin 管理员（lingyunya） */
  @Column({ type: 'varchar', length: 16, default: 'boss' })
  role: string;

  @Column({ type: 'int', default: 0 })
  unread: number;

  @CreateDateColumn({ name: 'joined_at', type: 'datetime', precision: 3 })
  joinedAt: Date;
}
