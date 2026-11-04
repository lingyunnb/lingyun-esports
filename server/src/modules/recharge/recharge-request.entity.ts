import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 申请状态：pending 待审核 / granted 已发放 / rejected 已驳回 */
export type RechargeRequestStatus = 'pending' | 'granted' | 'rejected';

/**
 * 充值申请（migration 1804000000000）—— **线下付款 + 人工审核**的唯一凭据。
 *
 * 字段语义与合规边界（CLAUDE.md 结构规则 12）：
 * - `amount_yuan` 是**老板自己填写/选择的金额**（DECIMAL(10,2)），不是任何通道回调的结果；
 * - `proof_media_id` 是老板上传的**转账截图**（受保护媒体：只有本人与管理员可读）；
 * - `status='granted'` 只能由管理员**人工核对后**手工触发，**没有任何自动到账路径**；
 * - `wallet_transaction_id` 指向真正加余额的那条流水（**唯一约束**：一笔流水只能对应一张申请），
 *   与 `recharge.service.grant()` 里的条件 UPDATE（`WHERE status='pending'` 判 affectedRows）
 *   一起构成"一张申请只能发放一次"的双保险；审计三件套 = `reviewed_by` + `reviewed_at` + `wallet_transaction_id`。
 * - 表里**没有**提现字段、没有退款字段、没有支付单号字段 —— 不做的能力不留在模型里。
 */
@Entity('recharge_request')
@Index('IDX_rqr_user_status', ['userId', 'status', 'id'])
@Index('IDX_rqr_status', ['status', 'id'])
export class RechargeRequest {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 申请人（user.id，role=user）—— 永远是 JWT sub，绝不来自请求体 */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 申请金额（元）。DECIMAL(10,2)：与项目既有金额字段口径一致（禁 FLOAT 精度漂移） */
  @Column({ name: 'amount_yuan', type: 'decimal', precision: 10, scale: 2 })
  amountYuan: string;

  /** 按当时 `points_per_yuan` 换算出的余额（**落库快照**：事后改比例不影响历史单据） */
  @Column({ type: 'int' })
  points: number;

  /** 老板扫的那张收款码（可为空：管理员换过码/码被删时历史申请仍要能看） */
  @Column({ name: 'qr_id', type: 'bigint', unsigned: true, nullable: true })
  qrId: string | null;

  /** 转账截图 media.id（受保护媒体，protected 通道） */
  @Column({ name: 'proof_media_id', type: 'bigint', unsigned: true })
  proofMediaId: string;

  /** 老板留言（如「微信昵称：XX」），便于人工核对 */
  @Column({ type: 'varchar', length: 200, default: '' })
  note: string;

  @Column({ type: 'varchar', length: 16, default: 'pending' })
  status: RechargeRequestStatus;

  /** 驳回原因（仅 status=rejected 时有值；会随通知发给老板） */
  @Column({ name: 'reject_reason', type: 'varchar', length: 200, nullable: true })
  rejectReason: string | null;

  /** 审核人（user.id，role=admin）—— 审计：谁发的 */
  @Column({ name: 'reviewed_by', type: 'bigint', unsigned: true, nullable: true })
  reviewedBy: string | null;

  /** 审核时间 —— 审计：什么时候发的 */
  @Column({ name: 'reviewed_at', type: 'datetime', precision: 3, nullable: true })
  reviewedAt: Date | null;

  /** 发放对应的钱包流水（审计：发的是哪一笔）；**唯一约束**兜住"一笔流水只能对应一张申请" */
  @Column({ name: 'wallet_transaction_id', type: 'bigint', unsigned: true, nullable: true })
  walletTransactionId: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
