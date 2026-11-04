import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 打手展示值（接单次数 / 好评率）—— 负责人 2026-10-16 指令：
 * 「上去的打手**只能管理端调接单次数和好评率**，评价只能用真实数据」。
 *
 * ## 口径（数字可调、评价必须真实）
 *
 * | 对外字段 | 来源 | 能否被管理端覆盖 |
 * |---|---|---|
 * | `completedOrders`（接单次数） | `worker_stats.completed_orders` | **能**（本迁移新增 `display_completed_orders`） |
 * | `satisfiedRate`（好评率） | `order_review` 实时聚合（`hidden=0`） | **能**（本迁移新增 `display_satisfied_rate`） |
 * | `reviewCount`（评价条数） | `order_review` 实时聚合 | **不能**（没有覆盖列 —— 评价条数与评价列表必须一致） |
 * | 评价列表（`order_review`） | 真实数据 | **不能**（隐藏/恢复只走既有 `review:moderate` 治理） |
 *
 * **`NULL` = 跟随真实**（未设展示值时一律回落真实值）：两列都可空，语义严格定义为
 * 「没设过 / 已清空」，而不是 0。「0 单」与「没设过」在管理端是两件事，
 * 用 0 当哨兵会让「恢复真实值」变成一个无法表达的状态。
 *
 * ⚠️ **`satisfiedRate` 对外是百分数字符串**（如 `"98.2"`）、**不是 0–1 比率** ——
 * 这是本项目踩过的坑（曾把 `1.0` 渲染成 `100%`）。因此：
 * - 本列存的是**百分数**（`98.2` 就是 98.2%），`decimal(5,1)` 与对外文案同为 1 位小数；
 * - 生成对外字符串的**唯一出口**是 `review.service.ts` 的 `satisfiedRateText()` /
 *   `satisfiedRatePercentText()`（展示值与真实值走同一个函数，见该文件注释）。
 *
 * ## 为什么放在 `worker_stats`（而不是新开一张 `worker_display_stats` 表）
 *
 * 1. **同一行并排**：真实值就在 `worker_stats.completed_orders`，展示值放同一行 →
 *    「真实值 + 展示值 + 生效值」由**同一条 SQL** 读出（`ReviewService` 的公开口径本来就查这张表，
 *    本批次只在该 SQL 里多加两个列，**SQL 条数不变**）。若另开表，公开路径每次都要多一次 JOIN/查询。
 * 2. **写入路径不受影响（已逐条核实）**：本表的三条既有写入都是
 *    `INSERT … ON DUPLICATE KEY UPDATE total_orders/completed_orders/total_amount = …`
 *    （`order.service.ts` 结算、`leaderboard.service.ts#bumpWorkerStats`、退款冲正 `UPDATE … SET completed_orders = completed_orders - 1`），
 *    **只更新列出的列**，绝不会把新列抹成 NULL —— 即"结算若干次后展示值仍在"。
 * 3. **随打手账号一起消失**：`user-admin.service.ts` 删除用户时会 `DELETE FROM worker_stats`，
 *    展示值不可能成为无主的孤儿行（另开表就得自己补这条级联）。
 * 4. 列可空 + 无默认值 → 对既有行零改写、对既有写入零影响（strict 模式下 INSERT 不含这两列即落 NULL）。
 *
 * ## 幂等与回滚
 *
 * 每列先查 `information_schema.COLUMNS`，存在则跳过（与 `1798000000000-home-banner-carousel-fields` 同一姿势）。
 * 回滚只删这两列（**不动任何行数据、不动 `worker_stats` 其它列**）；删列即等于"全部回落真实值"。
 */
export class WorkerDisplayStats1815000000000 implements MigrationInterface {
  name = 'WorkerDisplayStats1815000000000';

  private readonly table = 'worker_stats';

  public async up(queryRunner: QueryRunner): Promise<void> {
    if (!(await this.hasColumn(queryRunner, 'display_completed_orders'))) {
      await queryRunner.query(
        `ALTER TABLE \`${this.table}\`
           ADD COLUMN \`display_completed_orders\` int NULL
           COMMENT '接单次数展示值（管理端覆盖；NULL=跟随真实 worker_stats.completed_orders）'
           AFTER \`completed_orders\``,
      );
    }
    if (!(await this.hasColumn(queryRunner, 'display_satisfied_rate'))) {
      await queryRunner.query(
        `ALTER TABLE \`${this.table}\`
           ADD COLUMN \`display_satisfied_rate\` decimal(5,1) NULL
           COMMENT '好评率展示值（百分数 0.0-100.0，对外文案同为 1 位小数；NULL=跟随真实评价聚合）'
           AFTER \`display_completed_orders\``,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    for (const col of ['display_satisfied_rate', 'display_completed_orders']) {
      if (await this.hasColumn(queryRunner, col)) {
        await queryRunner.query(`ALTER TABLE \`${this.table}\` DROP COLUMN \`${col}\``);
      }
    }
  }

  private async hasColumn(queryRunner: QueryRunner, column: string): Promise<boolean> {
    const [row] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?`,
      [this.table, column],
    );
    return Number(row.c) > 0;
  }
}
