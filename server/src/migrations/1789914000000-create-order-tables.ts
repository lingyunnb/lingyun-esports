import { MigrationInterface, QueryRunner } from 'typeorm';

/** 订单+结算（负责人新增需求）：4 张表 + 平台账户 + 工作端钱包回填 */
export class CreateOrderTables1789914000000 implements MigrationInterface {
  name = 'CreateOrderTables1789914000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`order\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`order_no\` varchar(32) NOT NULL,
        \`idempotency_key\` varchar(64) NOT NULL,
        \`user_id\` bigint unsigned NOT NULL,
        \`product_id\` bigint unsigned NOT NULL,
        \`game_id\` bigint unsigned NOT NULL,
        \`category_id\` bigint unsigned NOT NULL,
        \`quantity\` int NOT NULL DEFAULT 1,
        \`unit_price\` int NOT NULL,
        \`total_amount\` int NOT NULL,
        \`status\` varchar(20) NOT NULL DEFAULT 'pending_take',
        \`worker_id\` bigint unsigned NULL,
        \`user_remark\` varchar(500) NULL,
        \`cancel_reason\` varchar(200) NULL,
        \`cancel_by\` varchar(16) NULL,
        \`ip\` varchar(64) NULL,
        \`request_id\` varchar(64) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_order_no\` (\`order_no\`),
        UNIQUE KEY \`UQ_order_idempotency\` (\`idempotency_key\`),
        KEY \`IDX_order_user_status\` (\`user_id\`, \`status\`),
        KEY \`IDX_order_worker_status\` (\`worker_id\`, \`status\`),
        KEY \`IDX_order_status_created\` (\`status\`, \`created_at\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`order_price_snapshot\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`order_id\` bigint unsigned NOT NULL,
        \`product_id\` bigint unsigned NOT NULL,
        \`product_name\` varchar(64) NOT NULL,
        \`game_name\` varchar(32) NOT NULL,
        \`category_name\` varchar(32) NOT NULL,
        \`unit_price\` int NOT NULL,
        \`quantity\` int NOT NULL,
        \`total_amount\` int NOT NULL,
        \`price_unit\` varchar(16) NOT NULL,
        \`estimate_duration_min\` int NOT NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_snapshot_order\` (\`order_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`order_status_log\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`order_id\` bigint unsigned NOT NULL,
        \`from_status\` varchar(20) NOT NULL,
        \`to_status\` varchar(20) NOT NULL,
        \`operator_type\` varchar(16) NOT NULL,
        \`operator_id\` bigint unsigned NULL,
        \`source\` varchar(16) NOT NULL,
        \`request_id\` varchar(64) NULL,
        \`remark\` varchar(255) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_order_status_log_order\` (\`order_id\`, \`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`order_settlement\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`settlement_no\` varchar(32) NOT NULL,
        \`order_id\` bigint unsigned NOT NULL,
        \`order_amount\` int NOT NULL,
        \`worker_id\` bigint unsigned NOT NULL,
        \`worker_amount\` int NOT NULL,
        \`worker_percentage\` int NOT NULL DEFAULT 70,
        \`platform_amount\` int NOT NULL,
        \`platform_percentage\` int NOT NULL DEFAULT 30,
        \`request_id\` varchar(64) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_settlement_no\` (\`settlement_no\`),
        UNIQUE KEY \`UQ_settlement_order\` (\`order_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // 平台账户（30% 抽成入账）：role=platform 无法登录（登录仅接受 user/worker/admin），密码为随机不可用哈希
    await queryRunner.query(`
      INSERT IGNORE INTO \`user\` (\`username\`, \`uid\`, \`password_hash\`, \`nickname\`, \`role\`, \`status\`)
      VALUES ('platform_account', 'PLATFORM1', '$2a$10$platform.invalid.hash.no.login.allowed', '平台账户', 'platform', 1)
    `);
    await queryRunner.query(`
      INSERT INTO \`wallet\` (\`user_id\`, \`balance\`)
      SELECT u.id, 0 FROM \`user\` u
      WHERE u.uid = 'PLATFORM1' AND NOT EXISTS (SELECT 1 FROM \`wallet\` w WHERE w.user_id = u.id)
    `);
    // 工作端钱包回填（打手收益 70% 入账账户）
    await queryRunner.query(`
      INSERT INTO \`wallet\` (\`user_id\`, \`balance\`)
      SELECT u.id, 0 FROM \`user\` u
      WHERE u.role = 'worker' AND NOT EXISTS (SELECT 1 FROM \`wallet\` w WHERE w.user_id = u.id)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `order_settlement`');
    await queryRunner.query('DROP TABLE IF EXISTS `order_status_log`');
    await queryRunner.query('DROP TABLE IF EXISTS `order_price_snapshot`');
    await queryRunner.query('DROP TABLE IF EXISTS `order`');
  }
}
