import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** AI 咨询会话（每用户一条长期会话；首次提问自动创建，docs 契约：conversationId 持久化） */
@Entity('ai_conversation')
export class AiConversation {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true, unique: true })
  userId: string;

  /**
   * 当前 session（UUID）——**会话轮换**用（migration `1790002000000-ai-session`）。
   *
   * 用户离开 AI 会话页时 `POST /user/ai/reset` 换一个新 uuid：
   * - 用户侧读写只看这个 session → 重进即空会话（旧数据仍留在库里，管理端质检可见）
   * - 喂模型的多轮历史也按 session 截断 → 新会话绝不引用上一次会话的内容
   */
  @Column({ name: 'current_session', length: 36 })
  currentSession: string;

  /** 会话内消息 seq 水位（事务内递增分配，与 chat 的 seq 语义一致） */
  @Column({ name: 'last_seq', type: 'bigint', unsigned: true, default: 0 })
  lastSeq: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
