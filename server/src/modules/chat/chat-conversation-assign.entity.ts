import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 客服会话授权（docs/07）：把会话指派/接入给持客服权限的工作端；改派后原客服被强制下线。
 *
 * 三条来源（同一张表、同一 `status` 语义，**不新增表**）：
 * - 管理端改派：`admin/chat` 的 assign（`assigned_by` = 管理员 id）；
 * - **客服大厅主动接入（2026-10-08）**：`POST /worker/cs/hall/:id/claim`，抢占式，
 *   `assigned_by` = **接入者自己的 user id**（= 自主接入；与管理员改派靠"是否等于 worker_user_id"区分）；
 * - 客服退回池子：`status='released'`（负责人尚未定案，见 `cs-hall-release.ts`）。
 *
 * **并发硬约束在数据库层**（migration `1807000000000`）：生成列 `active_conversation_id`
 * （仅 `status='active'` 时非 NULL）+ 唯一键 `UK_cca_active` → 同一会话**同时只能有一行 active**。
 * 该生成列**刻意不在实体里映射**（写入永不涉及），与本项目 `worker_identity_binding` 逐字同口径。
 */
@Entity('chat_conversation_assign')
@Index('IDX_assign_worker_status', ['workerUserId', 'status'])
@Index('IDX_assign_conv', ['conversationId'])
export class ChatConversationAssign {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'conversation_id', type: 'bigint', unsigned: true })
  conversationId: string;

  /** 客服 = 持 can_serve_customer 权限的工作端（user 表 id，实时查库校验） */
  @Column({ name: 'worker_user_id', type: 'bigint', unsigned: true })
  workerUserId: string;

  /** active 生效 / inactive 已解除（管理员改派）/ released 已退回池子（客服主动，2026-10-08） */
  @Column({ type: 'varchar', length: 16, default: 'active' })
  status: string;

  /**
   * 谁做的这次指派：管理员改派 = 管理员 user id；客服大厅自主接入 = 接入客服自己的 user id。
   * 历史行（inactive / released）一并保留 → 一个会话的接入史可完整回看。
   */
  @Column({ name: 'assigned_by', type: 'bigint', unsigned: true, nullable: true })
  assignedBy: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
