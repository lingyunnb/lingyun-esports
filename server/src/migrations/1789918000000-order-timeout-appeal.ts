import { MigrationInterface, QueryRunner } from 'typeorm';

/** 订单超时规则 + 售后申诉（docs/05）：order_appeal 表 + 待接单超时配置种子 */
export class OrderTimeoutAppeal1789918000000 implements MigrationInterface {
  name = 'OrderTimeoutAppeal1789918000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`order_appeal\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`order_id\` bigint unsigned NOT NULL,
        \`user_id\` bigint unsigned NOT NULL,
        \`prev_status\` varchar(20) NOT NULL,
        \`reason\` varchar(500) NOT NULL DEFAULT '',
        \`status\` varchar(16) NOT NULL DEFAULT 'open',
        \`result\` varchar(16) NULL,
        \`handler_id\` bigint unsigned NULL,
        \`handler_remark\` varchar(500) NULL,
        \`handled_at\` datetime(3) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_appeal_order\` (\`order_id\`),
        KEY \`IDX_appeal_status\` (\`status\`),
        KEY \`IDX_appeal_user\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      INSERT IGNORE INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`) VALUES
      ('order_pending_take_timeout_hours', JSON_OBJECT('value', 24), '待接单订单超时小时数（超时自动取消并全额退款）', 0)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`order_appeal\``);
  }
}
