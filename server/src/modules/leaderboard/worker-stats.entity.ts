import { moneyTransformer } from '../../common/money.transformer';
import { Column, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 打手实时统计（M7）：结算事务内累计（docs/待确认事项：完成数+总金额自动统计） */
@Entity('worker_stats')
export class WorkerStats {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'worker_id', type: 'bigint', unsigned: true, unique: true })
  workerId: string;

  @Column({ name: 'total_orders', type: 'int', default: 0 })
  totalOrders: number;

  @Column({ name: 'completed_orders', type: 'int', default: 0 })
  completedOrders: number;

  @Column({ name: 'total_amount', type: 'decimal', precision: 14, scale: 2, default: 0, transformer: moneyTransformer })
  totalAmount: number;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
