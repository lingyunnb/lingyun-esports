import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/**
 * 订单评价（migration `1812000000000`，负责人 2026-10-15「做评价与评分体系」）
 *
 * 语义（照竞品的信息架构、不用它的文案）：
 * - **二值评价**：`satisfied` 1 好评 / 0 差评 —— 老板的决策成本只有一个问题
 *   （"这次满意吗"），比 5 星评分更适合陪玩；**差评转售后**（接口回 `needAfterSale=true`，
 *   客户端引导走既有的 `POST /user/orders/:id/appeal`，本表**不落售后单**）；
 * - **一单一评**：`UK_review_order (order_id)` 表级兜底（三层保证见 `review.service.ts`）；
 * - **好评率不落冗余列**：由公开接口实时聚合本表（`worker_stats` 一列都不加）。
 *
 * 归属铁律（docs/04）：`user_id` **只从 JWT sub 取**；`order_id` 必须属于该老板且状态为
 * `completed`（服务层事务内校验）；`worker_id` 是落库时的快照（来自 `order.worker_id`）。
 */
@Entity('order_review')
@Index('UK_review_order', ['orderId'], { unique: true })
@Index('IDX_review_worker', ['workerId', 'hidden', 'createdAt'])
export class OrderReview {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 被评价的订单（`order.id`）—— 唯一键保证一单一评 */
  @Column({ name: 'order_id', type: 'bigint', unsigned: true })
  orderId: string;

  /** 评价人 = 下单老板（`user.id`，role=user） */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 被评价打手档案（`worker.id`）；快照自 `order.worker_id`，历史脏数据可为 NULL */
  @Column({ name: 'worker_id', type: 'bigint', unsigned: true, nullable: true })
  workerId: string | null;

  /**
   * 1 好评 / 0 差评。
   *
   * ⚠️ 刻意**不用** `type: 'boolean'`：与全项目既有写法一致（tinyint 存 0/1），
   * 且在**接口层**统一转成 JSON boolean（`satisfied: review.satisfied === 1`）——
   * 只有一处做这个转换，客户端拿到的永远是 `true/false`。
   */
  @Column({ type: 'tinyint', default: 0 })
  satisfied: number;

  /** 评价内容（可选；strip 前后空格，空串按未填处理 = NULL） */
  @Column({ type: 'varchar', length: 200, nullable: true })
  remark: string | null;

  /** 0 正常 / 1 已隐藏（`hidden=1` 的行公开接口一律不下发） */
  @Column({ type: 'tinyint', default: 0 })
  hidden: number;

  /** 隐藏原因（隐藏时必填；恢复可见时**清空** —— 本列语义是"当前的隐藏原因"） */
  @Column({ name: 'hidden_reason', type: 'varchar', length: 200, nullable: true })
  hiddenReason: string | null;

  /** 评价时间（服务层显式写入，便于同事务内直接回显 `createdAt`） */
  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
