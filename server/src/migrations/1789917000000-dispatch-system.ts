import { MigrationInterface, QueryRunner } from 'typeorm';

/** 派单系统（阶段16补）：订单派单时间字段 + system_setting 系统配置表（含派单超时/并发上限种子） */
export class DispatchSystem1789917000000 implements MigrationInterface {
  name = 'DispatchSystem1789917000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE \`order\`
        ADD \`dispatched_at\` datetime(3) NULL,
        ADD \`dispatch_expire_at\` datetime(3) NULL
    `);
    await queryRunner.query(`
      CREATE TABLE \`system_setting\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`setting_key\` varchar(64) NOT NULL,
        \`cfg_value\` json NOT NULL,
        \`description\` varchar(255) NOT NULL DEFAULT '',
        \`is_high_security\` tinyint NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_system_setting_key\` (\`setting_key\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    // 种子配置（docs/待确认事项 默认值：派单确认 5 分钟 / 同时进行上限 3 单 / 撤回窗口 120 秒）
    await queryRunner.query(`
      INSERT IGNORE INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`) VALUES
      ('dispatch_confirm_timeout_min', JSON_OBJECT('value', 5), '派单确认超时（分钟），超时自动回大厅', 0),
      ('worker_max_concurrent_orders', JSON_OBJECT('value', 3), '单工作端同时进行订单上限', 0),
      ('chat_recall_seconds', JSON_OBJECT('value', 120), '聊天消息撤回窗口（秒）', 0)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`system_setting\``);
    await queryRunner.query(`ALTER TABLE \`order\` DROP COLUMN \`dispatch_expire_at\`, DROP COLUMN \`dispatched_at\``);
  }
}
