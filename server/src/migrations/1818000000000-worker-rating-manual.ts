import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 打手六维「管理端手填值」表（负责人 2026-10-18 指令）
 *
 * ## 为什么需要它（问题原样复述）
 *
 * 老板评价是**自愿**的：没有评价 → `worker_rating_agg` 无行（或全 0 + `sample_count = 0`）
 * → `GET /public/workers/:id` 的 `rating` 五维全 0、样本 0 → 陪玩主页六轴全显示 `--`。
 * 运营需要一个**只影响展示**的手填通道，让新打手/冷门打手的主页也有六轴数据。
 *
 * ## 三个刻意的设计取舍（改之前先读）
 *
 * ### ① 六列**全部可空**，`NULL` = 「该维未手动设」
 *
 * 与 `worker_stats.display_*` 同口径：`0` 是一个**可以主动设的值**（"这项 0 分"），
 * 用 `0` 当哨兵会让"清除该项（回到自动）"无法表达。因此：**NULL = 回自动**，
 * `0.00` = 管理端真的把它设成了 0 分。读侧据此逐维判定 `manual / auto / none`
 * （唯一实现：`modules/worker/worker-rating-manual.service.ts#resolveRating`）。
 *
 * ### ② 列宽一律 `decimal(4,2)`（上界 10.00），不是 `decimal(3,2)`
 *
 * 与 `worker_rating_agg` 同一理由（见 migration `1817000000000` 注释 ②）：
 * `decimal(3,2)` 上界 9.99，而本表的上界是 **10.00** —— 严格模式下写 10.00 会
 * ER_DATA_OUT_OF_RANGE（1264）并让整个 PUT 事务回滚。
 *
 * ### ③ `worker_id` / `updated_by` 用 `bigint unsigned`
 *
 * 与全部兄弟表一致（`worker_rating_agg.worker_id`、`worker_rating.worker_id`、
 * `operation_log.admin_id`、`user.id` 都是 `bigint unsigned`）—— 避免"有符号 vs 无符号"
 * 在比较/关联时被 MySQL 隐式转换（虽然 id 恒为正、实际不会出错，但没必要留这个坑）。
 *
 * ## 与等级判定的边界（**红线，不可改**）
 *
 * 本表的数据**只影响展示**：`worker_grade` 的判定与升级进度**一律只读
 * `worker_rating_agg` / `worker_stats` / `order_review`**，绝不读本表 ——
 * 否则「改分即可刷等级」，制度当场失效。落点见
 * `worker-rating-manual.service.ts` 类注释与 `worker-grade.service.ts#metricsOf`。
 *
 * ## 幂等与回滚
 *
 * 先查 `information_schema.TABLES`，存在则**整段跳过**（`CREATE TABLE IF NOT EXISTS` 再兜一层）；
 * 重复执行不报错、不覆盖既有数据。`down()` 只删本 migration 建的那一张表，
 * 不触碰 `worker_rating` / `worker_rating_agg` / `worker_grade` 与任何既有数据。
 */
export class WorkerRatingManual1818000000000 implements MigrationInterface {
  name = 'WorkerRatingManual1818000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    if (await this.tableExists(queryRunner, 'worker_rating_manual')) return;

    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`worker_rating_manual\` (
        \`worker_id\` bigint unsigned NOT NULL COMMENT '打手档案（worker.id；与 worker_rating_agg.worker_id 同源）',
        \`score\` decimal(4,2) NULL COMMENT '「评分」那一轴的手填值（0.00-10.00；NULL = 未手动设）',
        \`skill\` decimal(4,2) NULL COMMENT '第 1 维（技术）手填值；NULL = 未手动设（回自动聚合）',
        \`emotion\` decimal(4,2) NULL COMMENT '第 2 维（情绪价值）手填值；NULL = 未手动设',
        \`stress\` decimal(4,2) NULL COMMENT '第 3 维（抗压）手填值；NULL = 未手动设',
        \`voice\` decimal(4,2) NULL COMMENT '第 4 维（声音）手填值；NULL = 未手动设',
        \`shop\` decimal(4,2) NULL COMMENT '第 5 维（综合表现）手填值；NULL = 未手动设',
        \`updated_by\` bigint unsigned NULL COMMENT '最后修改人（user.id，role=admin）；NULL = 从未经人手写',
        \`updated_at\` datetime(3) NULL COMMENT '最后修改时间（服务层显式写入；NULL = 从未手写）',
        PRIMARY KEY (\`worker_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='打手六维手填值（只影响展示，绝不参与等级判定）'
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `worker_rating_manual`');
  }

  private async tableExists(queryRunner: QueryRunner, table: string): Promise<boolean> {
    const rows = (await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.TABLES
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?`,
      [table],
    )) as Array<{ c: number | string }>;
    return Number(rows[0]?.c ?? 0) > 0;
  }
}
