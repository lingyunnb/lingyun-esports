import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 周期榜单快照（M7）：recalc 时按有效金额（真实金额+人工调整）排名写入 */
@Entity('leaderboard_entry')
@Index('IDX_board_period_rank', ['period', 'rank'])
export class LeaderboardEntry {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** '2026-W38' / '2026-09' */
  @Column({ type: 'varchar', length: 16 })
  period: string;

  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 分部（游戏 + 平台；负责人 2026-10-03）：榜单按分部独立排名，可空=全站榜 */
  @Column({ name: 'division_id', type: 'bigint', unsigned: true, nullable: true })
  divisionId: string | null;

  @Column({ name: 'completed_orders', type: 'int', default: 0 })
  completedOrders: number;

  @Column({ name: 'total_amount', type: 'decimal', precision: 14, scale: 2, default: 0, transformer: moneyTransformer })
  totalAmount: number;

  @Column({ type: 'int', default: 0 })
  rank: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
