import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

export type AiRole = 'user' | 'assistant' | 'system';

/**
 * AI 咨询消息：seq 会话内递增；msg_id 为对外消息 id（WS ai:chunk/done/error 的 messageId）。
 *
 * `session_id` 为**会话轮换**的归属列（migration `1790002000000-ai-session`）：
 * 落库时写"本次提问发生时"的 `ai_conversation.current_session`（生成中途 reset 也不会写进新 session）。
 */
@Entity('ai_message')
@Index('IDX_ai_msg_conv_seq', ['conversationId', 'seq'])
@Index('IDX_ai_msg_conv_session_seq', ['conversationId', 'sessionId', 'seq'])
export class AiMessage {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 对外消息 id（UUID） */
  @Column({ name: 'msg_id', length: 40, unique: true })
  msgId: string;

  @Column({ name: 'conversation_id', type: 'bigint', unsigned: true })
  conversationId: string;

  /** 归属 session（UUID）；与提问/生成开始时刻的 `ai_conversation.current_session` 一致 */
  @Column({ name: 'session_id', length: 36 })
  sessionId: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** user | assistant | system */
  @Column({ type: 'varchar', length: 16 })
  role: AiRole;

  @Column({ type: 'mediumtext' })
  content: string;

  @Column({ type: 'bigint', unsigned: true })
  seq: string;

  /** 生成该行的供应商：glm / rule（规则兜底） */
  @Column({ type: 'varchar', length: 32, nullable: true })
  provider: string | null;

  @Column({ type: 'varchar', length: 64, nullable: true })
  model: string | null;

  /** 1 = 命中 30 秒同问缓存（未调用模型） */
  @Column({ type: 'tinyint', default: 0 })
  cached: number;

  /** 客户端重试幂等键（同用户唯一） */
  @Column({ name: 'idempotency_key', type: 'varchar', length: 64, nullable: true })
  idempotencyKey: string | null;

  /** 用户行：本次提问对应的回复 msg_id（幂等重放用） */
  @Column({ name: 'reply_msg_id', type: 'varchar', length: 40, nullable: true })
  replyMsgId: string | null;

  /**
   * 找陪玩推荐（`POST /user/ai/recommend`）挑中的打手快照（JSON 数组）；普通问答为 null。
   *
   * 只存**已展示给用户**的四个字段（workerId/name/intro/divisionName/reason），
   * 不含手机号、真实姓名、工号等任何敏感字段 —— 与提示词白名单一致。
   * 列由 migration `1790001000000-ai-message-picks` 添加（synchronize 关闭，必须走 migration）。
   */
  @Column({ name: 'picks_json', type: 'json', nullable: true })
  picksJson: Array<Record<string, unknown>> | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
