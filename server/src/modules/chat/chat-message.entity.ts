import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 聊天消息（docs/07）：msg_id 全局唯一；seq 会话内递增（服务端事务分配）；client_msg_id 幂等去重；撤回为软状态 */
@Entity('chat_message')
@Index('IDX_msg_conv_seq', ['conversationId', 'seq'])
export class ChatMessage {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 服务端生成的全局唯一消息 id */
  @Column({ name: 'msg_id', length: 40, unique: true })
  msgId: string;

  @Column({ name: 'conversation_id', type: 'bigint', unsigned: true })
  conversationId: string;

  @Column({ type: 'bigint', unsigned: true })
  seq: string;

  /** user / worker（客服） */
  @Column({ name: 'sender_type', type: 'varchar', length: 16 })
  senderType: string;

  @Column({ name: 'sender_id', type: 'bigint', unsigned: true })
  senderId: string;

  /** text / image（image 的 content = mediaId） */
  @Column({ name: 'msg_type', type: 'varchar', length: 16, default: 'text' })
  msgType: string;

  @Column({ type: 'text' })
  content: string;

  /** 客户端生成的消息幂等 id（同会话唯一；重试幂等重发原 ACK） */
  @Column({ name: 'client_msg_id', type: 'varchar', length: 64, nullable: true })
  clientMsgId: string | null;

  @Column({ type: 'tinyint', default: 0 })
  recalled: number;

  @Column({ name: 'recalled_at', type: 'datetime', precision: 3, nullable: true })
  recalledAt: Date | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
