import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn } from 'typeorm';

/** 下单时商品全量快照（docs/02）：历史订单展示永不漂移，结算按快照金额 */
@Entity('order_price_snapshot')
export class OrderPriceSnapshot {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true, unique: true })
  orderId: string;

  @Column({ name: 'product_id', type: 'bigint', unsigned: true })
  productId: string;

  @Column({ name: 'product_name', type: 'varchar', length: 64 })
  productName: string;

  @Column({ name: 'game_name', type: 'varchar', length: 32 })
  gameName: string;

  @Column({ name: 'category_name', type: 'varchar', length: 32 })
  categoryName: string;

  @Column({ name: 'unit_price', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  unitPrice: number;

  @Column({ type: 'int' })
  quantity: number;

  @Column({ name: 'total_amount', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  totalAmount: number;

  @Column({ name: 'price_unit', type: 'varchar', length: 16 })
  priceUnit: string;

  @Column({ name: 'estimate_duration_min', type: 'int' })
  estimateDurationMin: number;

  @Column({ name: 'game_zone', type: 'varchar', length: 16, nullable: true })
  gameZone: string | null;

  @Column({ name: 'game_player_id', type: 'varchar', length: 64, nullable: true })
  gamePlayerId: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
