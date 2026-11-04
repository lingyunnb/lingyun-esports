import { moneyTransformer } from '../../common/money.transformer';
import { Column, Entity, PrimaryColumn, UpdateDateColumn } from 'typeorm';

/**
 * 五维评分聚合（migration `1817000000000`，负责人已审批 2026-10-17）
 *
 * ## 为什么要有这张表（而不是每次判级现算 AVG）
 *
 * 判级发生在**每次评价**里，而判级要同时读"完成单/好评率/结算额"与"五维均分/样本数"。
 * 若每次都 `SELECT AVG(...) FROM worker_rating WHERE worker_id = ?`，
 * 就是把"聚合"扩散到每一个读判级指标的地方（详情页、我的、列表、判级）；
 * 落一行为**写入侧唯一聚合**后：写一次、读处处处一致，SQL 也只剩一条主键查询。
 *
 * ## 语义（与审批表一致）
 *
 * - 五列 = `worker_rating` 对应列在该打手全部评分上的 **AVG**（1–10 分，两位小数）；
 * - `sample_count` = 评分条数；**< 10 条不参与升级判定**（防刷，见 `MIN_RATING_SAMPLES_FOR_GRADE`）；
 * - `updated_at` = 最近一次重算时间（同事务内写入）。
 *
 * ⚠️ 列宽是 `decimal(4,2)` 而非审批表的 `decimal(3,2)`：`decimal(3,2)` 上界 9.99，
 * 而五维均值上界是 **10.00**（全给 10 分时），严格模式下写进去会 ER_DATA_OUT_OF_RANGE（1264）
 * 并让整条评价事务回滚。详见 migration `1817000000000` 注释 ②。
 *
 * **重算方式**（唯一实现 `RatingService.recomputeAggInTx()`）：
 * `INSERT … SELECT AVG/COUNT … GROUP BY worker_id … ON DUPLICATE KEY UPDATE` ——
 * 一条语句幂等完成，不用"先删后插"，也不会有"删了却没插进去"的空窗。
 */
@Entity('worker_rating_agg')
export class WorkerRatingAgg {
  /** 打手档案 id（`worker.id`） */
  @PrimaryColumn({ name: 'worker_id', type: 'bigint', unsigned: true })
  workerId: string;

  /** 第 1 维均分（0.00–10.00） */
  @Column({ type: 'decimal', precision: 4, scale: 2, default: 0, transformer: moneyTransformer })
  skill: number;

  /** 第 2 维均分 */
  @Column({ type: 'decimal', precision: 4, scale: 2, default: 0, transformer: moneyTransformer })
  emotion: number;

  /** 第 3 维均分 */
  @Column({ type: 'decimal', precision: 4, scale: 2, default: 0, transformer: moneyTransformer })
  stress: number;

  /** 第 4 维均分 */
  @Column({ type: 'decimal', precision: 4, scale: 2, default: 0, transformer: moneyTransformer })
  voice: number;

  /** 第 5 维均分 */
  @Column({ type: 'decimal', precision: 4, scale: 2, default: 0, transformer: moneyTransformer })
  shop: number;

  /** 样本数（`worker_rating` 条数） */
  @Column({ name: 'sample_count', type: 'int', default: 0 })
  sampleCount: number;

  /** 最近一次重算时间 */
  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
