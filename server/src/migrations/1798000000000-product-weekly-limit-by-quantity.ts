import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 商品「每周限购按件数」开关列（负责人 2026-10-05 任务③）
 *
 * 需求原文：
 * > 限购支持「按件数」（后台可配，默认保持现行为）：
 * > `product` 表加列 `weekly_limit_by_quantity tinyint NOT NULL DEFAULT 0`
 * > （0=按**订单条数**（现状）、1=按**件数** SUM(quantity)）；
 * > 结算/下单判定处按该开关切换聚合方式；并发安全保持不变。
 *
 * ---------------------------------------------------------------------------
 * `product.weekly_limit_by_quantity` tinyint NOT NULL DEFAULT 0
 *   - **0 = 按订单条数**（`COUNT(1)`）：现状口径，也是本列的默认值 ——
 *     加列不加行为：迁移跑完，全库所有商品（含已配限购的商品 137）判定方式**与迁移前逐字一致**。
 *   - **1 = 按件数**（`COALESCE(SUM(quantity),0)`）：一次买 2 件 = 占 2 个名额。
 *   - 只有 `weekly_limit > 0`（配了限购）时该开关才有意义；不限购商品配了也不影响。
 *   - 用 NOT NULL + DEFAULT 0 而不是 NULL：这是一个**二值口径**而不是"未配置"三态，
 *     NOT NULL 让 `weekly_limit_by_quantity = 1` 能直接走索引判断，也让实体/代码里不必到处 `?? 0`
 *     （实测踩过的坑：`tinyint NULL` 在同一张表里读出来是 `null`，很容易被 `!== 1` 误判成"按件数"）。
 *
 * 口径的**唯一来源**仍是 `order.service.ts` 里的限购 SQL 构造函数：下单强制校验与
 * `/user/orders/weekly-quota` 配额查询共用它，不会出现"提示按件、判定按单"的漂移。
 *
 * **幂等**：先查 information_schema，存在则跳过（重复跑不会报 1060 Duplicate column）。
 * **回滚**：删列。删列前不改任何数据 —— 该列不承载业务数据，只是口径开关，
 *   回滚后所有商品回到"按订单条数"，与现状一致。
 */
export class ProductWeeklyLimitByQuantity1798000000000 implements MigrationInterface {
  name = 'ProductWeeklyLimitByQuantity1798000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const [col] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = 'weekly_limit_by_quantity'`,
    );
    if (Number(col.c) > 0) return;
    await queryRunner.query(
      `ALTER TABLE \`product\`
         ADD COLUMN \`weekly_limit_by_quantity\` tinyint NOT NULL DEFAULT 0
         COMMENT '限购口径：0=按订单条数（默认）/ 1=按件数 SUM(quantity)；仅 weekly_limit>0 时有意义'
         AFTER \`weekly_limit\``,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const [col] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = 'weekly_limit_by_quantity'`,
    );
    if (Number(col.c) > 0) {
      await queryRunner.query('ALTER TABLE `product` DROP COLUMN `weekly_limit_by_quantity`');
    }
  }
}
