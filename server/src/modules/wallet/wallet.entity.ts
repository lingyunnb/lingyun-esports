import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 余额钱包（docs/02、docs/06）：一人一钱包；余额只能由服务端事务变更 */
@Entity('wallet')
export class Wallet {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true, unique: true })
  userId: string;

  @Column({ type: 'decimal', precision: 14, scale: 2, default: 0, transformer: moneyTransformer })
  balance: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
