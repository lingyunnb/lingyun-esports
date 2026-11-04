import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 金额字段支持小数（负责人决策 2026-09-23：钻皮·刀 5.5 积分/局等小数价目）
 * 全链路改为 decimal：商品价 → 订单快照 → 钱包余额/流水 → 70/30 结算 → 等级累计消费 → 榜单统计。
 * int/bigint → decimal 为无损转换（整数数据原样保留）。
 */
export class DecimalMoney1789933000000 implements MigrationInterface {
  async up(queryRunner: QueryRunner): Promise<void> {
    const q = async (sql: string) => queryRunner.query(sql);
    await q(`ALTER TABLE \`product\` MODIFY \`price\` decimal(10,2) NOT NULL COMMENT '积分价格（支持小数）'`);
    await q(`ALTER TABLE \`order\` MODIFY \`unit_price\` decimal(12,2) NOT NULL, MODIFY \`total_amount\` decimal(12,2) NOT NULL`);
    await q(`ALTER TABLE \`order_price_snapshot\` MODIFY \`unit_price\` decimal(12,2) NOT NULL, MODIFY \`total_amount\` decimal(12,2) NOT NULL`);
    await q(`ALTER TABLE \`order_settlement\` MODIFY \`order_amount\` decimal(12,2) NOT NULL, MODIFY \`worker_amount\` decimal(12,2) NOT NULL, MODIFY \`platform_amount\` decimal(12,2) NOT NULL`);
    await q(`ALTER TABLE \`wallet\` MODIFY \`balance\` decimal(14,2) NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`wallet_transaction\` MODIFY \`amount\` decimal(14,2) NOT NULL, MODIFY \`balance_before\` decimal(14,2) NOT NULL, MODIFY \`balance_after\` decimal(14,2) NOT NULL`);
    await q(`ALTER TABLE \`user\` MODIFY \`total_spent\` decimal(14,2) NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`worker_stats\` MODIFY \`total_amount\` decimal(14,2) NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`leaderboard_entry\` MODIFY \`total_amount\` decimal(14,2) NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`leaderboard_adjustment\` MODIFY \`amount_delta\` decimal(14,2) NOT NULL DEFAULT 0`);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    const q = async (sql: string) => queryRunner.query(sql);
    await q(`ALTER TABLE \`product\` MODIFY \`price\` int NOT NULL`);
    await q(`ALTER TABLE \`order\` MODIFY \`unit_price\` int NOT NULL, MODIFY \`total_amount\` int NOT NULL`);
    await q(`ALTER TABLE \`order_price_snapshot\` MODIFY \`unit_price\` int NOT NULL, MODIFY \`total_amount\` int NOT NULL`);
    await q(`ALTER TABLE \`order_settlement\` MODIFY \`order_amount\` int NOT NULL, MODIFY \`worker_amount\` int NOT NULL, MODIFY \`platform_amount\` int NOT NULL`);
    await q(`ALTER TABLE \`wallet\` MODIFY \`balance\` int NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`wallet_transaction\` MODIFY \`amount\` int NOT NULL, MODIFY \`balance_before\` int NOT NULL, MODIFY \`balance_after\` int NOT NULL`);
    await q(`ALTER TABLE \`user\` MODIFY \`total_spent\` bigint NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`worker_stats\` MODIFY \`total_amount\` int NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`leaderboard_entry\` MODIFY \`total_amount\` int NOT NULL DEFAULT 0`);
    await q(`ALTER TABLE \`leaderboard_adjustment\` MODIFY \`amount_delta\` int NOT NULL DEFAULT 0`);
  }
}
