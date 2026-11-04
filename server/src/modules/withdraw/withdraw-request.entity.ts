import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 提现状态：pending 处理中 / paid 已打款 / rejected 已驳回（金额已退回） */
export type WithdrawRequestStatus = 'pending' | 'paid' | 'rejected';

/**
 * 提现申请（migration `1810000000000`）—— **申请即扣款**的资金单据。
 *
 * ## 资金语义（负责人拍板，别再问）
 *
 * 1. **提交申请 = 同一事务内立即从打手钱包扣减并写流水**（`change_type='withdraw'`）；
 *    申请期间这笔钱**不可能被再花、不可能重复提现**（余额已经不在钱包里了）；
 * 2. **驳回 = 退回余额 + 反向流水**（`change_type='withdraw_reject'`）；
 * 3. **打款 = 管理员线下微信转账后回填凭证**，本表只记结论（`paid_by` / `paid_at` /
 *    `payout_proof_media_id`）—— 平台**没有**任何代付通道/回调。
 *
 * ## 幂等与并发（资金安全三件套 + 数据库级兜底）
 *
 * | 层 | 落点 |
 * |---|---|
 * | ① 事务 + 行锁 | 申请：`SELECT id FROM wallet WHERE user_id=? FOR UPDATE`；打款/驳回：`SELECT ... FROM withdraw_request WHERE id=? FOR UPDATE` |
 * | ② 条件 UPDATE 判 affectedRows | `UPDATE withdraw_request SET ... WHERE id=? AND status='pending'` |
 * | ③ 幂等键唯一约束 | `wallet_transaction.idempotency_key`：扣款 = `withdraw:<requestId>`，退回 = `withdraw_reject:<requestId>`（`UQ_wallet_txn_idem` 唯一） |
 *
 * 另有两条**表结构级**兜底（"多算无害、少算有害"的不对称逻辑）：
 * - `UK_wr_pending_worker (pending_worker_id 生成列)`：同一打手**不可能同时存在两笔 pending**
 *   —— 并发两笔时后一笔直接撞唯一键（服务层翻译成中文 409，不是 500）；
 * - `UK_wr_wallet_txn (wallet_transaction_id)`：一笔流水只能对应一张申请。
 *
 * ## 审计
 *
 * `applied_at`（什么时候申请的）+ `wallet_transaction_id`（扣的是哪一笔，顺流水可拿前后余额快照）
 * + `paid_by/paid_at/payout_proof_media_id` 或 `rejected_by/rejected_at/reject_reason`。
 * 退款那条反向流水靠确定的幂等键 `withdraw_reject:<id>` 反查（无需再加一列）。
 */
@Entity('withdraw_request')
@Index('IDX_wr_worker_status', ['workerId', 'status'])
@Index('IDX_wr_status_applied', ['status', 'appliedAt'])
export class WithdrawRequest {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 打手档案 id（`worker.id`） */
  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 打手账号 user.id（**钱包主体**：扣款/退款都作用在它的 wallet 上）；只来自 JWT sub */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 申请金额（元）。DECIMAL(12,2)：与项目既有金额字段同口径（禁 FLOAT 精度漂移） */
  @Column({ type: 'decimal', precision: 12, scale: 2 })
  amount: string;

  @Column({ type: 'varchar', length: 16, default: 'pending' })
  status: WithdrawRequestStatus;

  /** 申请时间（= 扣款时间；DB 时钟写入，避免客户端/宿主时钟差） */
  @Column({ name: 'applied_at', type: 'datetime', precision: 3, nullable: true })
  appliedAt: Date | null;

  /** 打款时间 */
  @Column({ name: 'paid_at', type: 'datetime', precision: 3, nullable: true })
  paidAt: Date | null;

  /** 打款人（user.id，role=admin）—— 审计：谁打的款 */
  @Column({ name: 'paid_by', type: 'bigint', unsigned: true, nullable: true })
  paidBy: string | null;

  /** 打款凭证 media.id（用途 `withdraw_proof`，protected：资金凭证绝不公开直连） */
  @Column({ name: 'payout_proof_media_id', type: 'bigint', unsigned: true, nullable: true })
  payoutProofMediaId: string | null;

  /** 打款备注（如微信转账单号/尾号；管理员填写） */
  @Column({ name: 'payout_note', type: 'varchar', length: 200, nullable: true })
  payoutNote: string | null;

  @Column({ name: 'rejected_at', type: 'datetime', precision: 3, nullable: true })
  rejectedAt: Date | null;

  /** 驳回人（user.id，role=admin） */
  @Column({ name: 'rejected_by', type: 'bigint', unsigned: true, nullable: true })
  rejectedBy: string | null;

  /** 驳回原因（必填；会随通知发给打手） */
  @Column({ name: 'reject_reason', type: 'varchar', length: 200, nullable: true })
  rejectReason: string | null;

  /** 申请时的**扣款**流水（审计：扣的是哪一笔）；**唯一约束**兜住"一笔流水只能对应一张申请" */
  @Column({ name: 'wallet_transaction_id', type: 'bigint', unsigned: true, nullable: true })
  walletTransactionId: string | null;

  /**
   * 幂等键（varchar 64，UNIQUE，可空）。
   *
   * 客户端重试/网络重发时带上同一个键 → 服务端识别为同一笔申请，不重复扣款。
   * 与钱包流水的幂等键（`withdraw:<id>`）**不同层**：这一列管"申请单据"的重复提交，
   * 那一列管"钱包流水"的重复入账。
   */
  @Column({ name: 'idempotency_key', type: 'varchar', length: 64, nullable: true })
  idempotencyKey: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
