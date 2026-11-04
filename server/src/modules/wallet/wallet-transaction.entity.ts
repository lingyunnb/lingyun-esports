import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 余额流水（docs/02、docs/06）：只增不改的权威账本，前后余额快照不可变 */
@Entity('wallet_transaction')
@Index('IDX_wallet_txn_user_id', ['userId'])
@Index('IDX_wallet_txn_order_id', ['orderId'])
@Index('IDX_wallet_txn_created_at', ['createdAt'])
export class WalletTransaction {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'transaction_no', length: 32, unique: true })
  transactionNo: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** grant 发放 / recover 回收 / order_pay 下单扣款 / order_refund 退款（docs/06） */
  @Column({ name: 'change_type', length: 20 })
  changeType: string;

  @Column({ type: 'decimal', precision: 14, scale: 2, transformer: moneyTransformer })
  amount: number;

  @Column({ name: 'balance_before', type: 'decimal', precision: 14, scale: 2, transformer: moneyTransformer })
  balanceBefore: number;

  @Column({ name: 'balance_after', type: 'decimal', precision: 14, scale: 2, transformer: moneyTransformer })
  balanceAfter: number;

  @Column({ name: 'operator_type', length: 16 })
  operatorType: string;

  @Column({ name: 'operator_id', type: 'bigint', unsigned: true, nullable: true })
  operatorId: string | null;

  @Column({ length: 16 })
  source: string;

  @Column({ type: 'varchar', length: 100, nullable: true })
  reason: string | null;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true, nullable: true })
  orderId: string | null;

  /** 幂等键（唯一约束兜底防重复，docs/06） */
  @Column({ name: 'idempotency_key', type: 'varchar', length: 64, nullable: true, unique: true })
  idempotencyKey: string | null;

  @Column({ type: 'varchar', length: 64, nullable: true })
  ip: string | null;

  @Column({ name: 'request_id', type: 'varchar', length: 64, nullable: true })
  requestId: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
