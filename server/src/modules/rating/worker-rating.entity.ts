import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/**
 * 打手五维评分（migration `1817000000000`，负责人已审批 2026-10-17）
 *
 * ## 语义
 *
 * - **一单一评**：`UK_wrating_order (order_id)` 表级兜底；服务层另有事务内查重 + 中文 400（两层都在）。
 * - **评价自愿**：系统不强制、不催；**只有评了才计入**聚合（没有"默认满分"这种填充）。
 * - **五维各 1–10 的整数**，列名 `r_` 前缀是审批表定的（避免与业务字段混淆）。
 *   中文名未在审批表中给出，接口只回英文字段名（`skill/emotion/stress/voice/shop`）。
 * - `worker_id` 是**落库时的快照**（来自 `order.worker_id`），不是从请求体读的 ——
 *   老板端**没有**任何手段指定"给谁打分"。
 *
 * ## 谁写
 *
 * 只有一条写入路径：`POST /user/orders/:id/rating` → `RatingService.submit()`。
 * 同一事务内依次：校验订单归属/状态 → 插本行 → 重算 `worker_rating_agg` → `WorkerGradeService.evaluate()`。
 * 因此「评分落库了但均分没更新」在结构上不可能出现。
 */
@Entity('worker_rating')
@Index('UK_wrating_order', ['orderId'], { unique: true })
@Index('IDX_wrating_worker_created', ['workerId', 'createdAt'])
export class WorkerRating {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 被评价订单（`order.id`）—— 唯一键保证一单一评 */
  @Column({ name: 'order_id', type: 'bigint', unsigned: true })
  orderId: string;

  /** 被评价打手档案（`worker.id`）；快照自 `order.worker_id` */
  @Column({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 五维第 1 维（1–10 整数） */
  @Column({ name: 'r_skill', type: 'tinyint' })
  rSkill: number;

  /** 五维第 2 维（1–10 整数） */
  @Column({ name: 'r_emotion', type: 'tinyint' })
  rEmotion: number;

  /** 五维第 3 维（1–10 整数） */
  @Column({ name: 'r_stress', type: 'tinyint' })
  rStress: number;

  /** 五维第 4 维（1–10 整数） */
  @Column({ name: 'r_voice', type: 'tinyint' })
  rVoice: number;

  /** 五维第 5 维（1–10 整数） */
  @Column({ name: 'r_shop', type: 'tinyint' })
  rShop: number;

  /** 评价正文（可选；空串按未填处理 = NULL，避免库里 '' 与 NULL 两种"空"） */
  @Column({ name: 'r_comment', type: 'varchar', length: 200, nullable: true })
  rComment: string | null;

  /** 评价时间（服务层显式写入，同事务内即可回显） */
  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
