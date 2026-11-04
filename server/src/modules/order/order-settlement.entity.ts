import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn } from 'typeorm';

/**
 * 订单结算记录（负责人新增需求）：
 * - order_id 唯一约束 = 一个订单最多一次正式结算（数据库级幂等兜底）
 * - 分成比例由服务器按订单快照金额计算，客户端不可传；比例本身读 `system_setting.platform_commission_rate`
 *   （默认平台 25% / 打手 75%），**按结算当时生效值落库**，历史单据因此可回溯
 */
@Entity('order_settlement')
export class OrderSettlement {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'settlement_no', length: 32, unique: true })
  settlementNo: string;

  @Column({ name: 'order_id', type: 'bigint', unsigned: true, unique: true })
  orderId: string;

  /** 订单结算总余额 = 订单创建时快照金额 */
  @Column({ name: 'order_amount', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  orderAmount: number;

  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 打手入账金额 */
  @Column({ name: 'worker_amount', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  workerAmount: number;

  /** 打手分成比例（百分数整数；默认 75 = 平台抽 25%） */
  @Column({ name: 'worker_percentage', type: 'int', default: 75 })
  workerPercentage: number;

  /** 平台入账金额 */
  @Column({ name: 'platform_amount', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  platformAmount: number;

  /** 平台抽成比例（百分数整数，默认 25） */
  @Column({ name: 'platform_percentage', type: 'int', default: 25 })
  platformPercentage: number;

  @Column({ name: 'request_id', type: 'varchar', length: 64, nullable: true })
  requestId: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
