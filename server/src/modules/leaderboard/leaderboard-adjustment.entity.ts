import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 榜单人工调整（M7）：调整留痕可审计（docs/待确认事项：允许调整，留痕） */
@Entity('leaderboard_adjustment')
@Index('IDX_adj_period_worker', ['period', 'workerId'])
export class LeaderboardAdjustment {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ type: 'varchar', length: 16 })
  period: string;

  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 正数加榜 / 负数减榜 */
  @Column({ name: 'amount_delta', type: 'decimal', precision: 14, scale: 2, transformer: moneyTransformer })
  amountDelta: number;

  @Column({ type: 'varchar', length: 255, default: '' })
  reason: string;

  @Column({ name: 'admin_user_id', type: 'bigint', unsigned: true })
  adminUserId: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
