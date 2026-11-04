import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 订单状态码（docs/05 权威状态机） */
export type OrderStatus =
  | 'pending_take' // 待接单
  | 'pending_dispatch' // 待确认派单
  | 'taken' // 已接单
  | 'in_progress' // 进行中
  | 'pending_confirm' // 待用户确认
  | 'completed' // 已完成
  | 'canceled' // 已取消
  | 'abnormal' // 异常
  | 'after_sale'; // 售后/申诉

/** 订单主表（docs/02）：价格快照、状态机服务端控制、结算与取消留痕 */
@Entity('order')
@Index('UQ_order_idempotency', ['idempotencyKey'], { unique: true })
@Index('IDX_order_user_status', ['userId', 'status'])
@Index('IDX_order_worker_status', ['workerId', 'status'])
@Index('IDX_order_status_created', ['status', 'createdAt'])
export class Order {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'order_no', length: 32, unique: true })
  orderNo: string;

  @Column({ name: 'idempotency_key', type: 'varchar', length: 64 })
  idempotencyKey: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  @Column({ name: 'product_id', type: 'bigint', unsigned: true })
  productId: string;

  @Column({ name: 'game_id', type: 'bigint', unsigned: true })
  gameId: string;

  /** 分部（游戏 + 平台）：下单时由服务端按商品所属分部写入，客户端不可指定 */
  @Column({ name: 'division_id', type: 'bigint', unsigned: true, nullable: true })
  divisionId: string | null;

  @Column({ name: 'category_id', type: 'bigint', unsigned: true })
  categoryId: string;

  @Column({ type: 'int', default: 1 })
  quantity: number;

  /** 下单时单价快照（服务端查库定价，docs/06） */
  @Column({ name: 'unit_price', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  unitPrice: number;

  /** 下单时总价快照 = 结算总余额（改价不影响历史订单与结算） */
  @Column({ name: 'total_amount', type: 'decimal', precision: 12, scale: 2, transformer: moneyTransformer })
  totalAmount: number;

  @Column({ type: 'varchar', length: 20, default: 'pending_take' })
  status: OrderStatus;

  @Column({ name: 'worker_id', type: 'bigint', unsigned: true, nullable: true })
  workerId: string | null;

  /** 派单时间（阶段16补） */
  @Column({ name: 'dispatched_at', type: 'datetime', precision: 3, nullable: true })
  dispatchedAt: Date | null;

  /** 派单确认截止时间（超时自动回大厅） */
  @Column({ name: 'dispatch_expire_at', type: 'datetime', precision: 3, nullable: true })
  dispatchExpireAt: Date | null;

  @Column({ name: 'user_remark', type: 'varchar', length: 500, nullable: true })
  userRemark: string | null;

  /** 联系方式（选填；下单页可配置是否显示） */
  @Column({ name: 'contact_phone', length: 20, default: '' })
  contactPhone: string;

  /** 护航员选择方式：random 随机安排 / designated 指定护航员 */
  @Column({ name: 'worker_mode', length: 16, default: 'random' })
  workerMode: string;

  /** 指定护航员（worker.id，仅 worker_mode=designated 时有效） */
  @Column({ name: 'designated_worker_id', type: 'bigint', unsigned: true, nullable: true })
  designatedWorkerId: string | null;


  /** 老板游戏分区（QQ区/微信区；下单必填，打手抢单后才可见） */
  @Column({ name: 'game_zone', type: 'varchar', length: 16, nullable: true })
  gameZone: string | null;

  /** 老板游戏 ID（下单必填；打手抢单后才可见） */
  @Column({ name: 'game_player_id', type: 'varchar', length: 64, nullable: true })
  gamePlayerId: string | null;

  @Column({ name: 'cancel_reason', type: 'varchar', length: 200, nullable: true })
  cancelReason: string | null;

  @Column({ name: 'cancel_by', type: 'varchar', length: 16, nullable: true })
  cancelBy: string | null;

  @Column({ type: 'varchar', length: 64, nullable: true })
  ip: string | null;

  @Column({ name: 'request_id', type: 'varchar', length: 64, nullable: true })
  requestId: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
