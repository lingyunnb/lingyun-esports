import { MigrationInterface, QueryRunner } from 'typeorm';

/** 阶段10：积分钱包与流水（docs/02、docs/06）+ 存量用户钱包回填 */
export class CreateWalletTables1789912000000 implements MigrationInterface {
  name = 'CreateWalletTables1789912000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`wallet\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`balance\` int NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_wallet_user_id\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`wallet_transaction\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`transaction_no\` varchar(32) NOT NULL,
        \`user_id\` bigint unsigned NOT NULL,
        \`change_type\` varchar(20) NOT NULL,
        \`amount\` int NOT NULL,
        \`balance_before\` int NOT NULL,
        \`balance_after\` int NOT NULL,
        \`operator_type\` varchar(16) NOT NULL,
        \`operator_id\` bigint unsigned NULL,
        \`source\` varchar(16) NOT NULL,
        \`reason\` varchar(100) NULL,
        \`order_id\` bigint unsigned NULL,
        \`idempotency_key\` varchar(64) NULL,
        \`ip\` varchar(64) NULL,
        \`request_id\` varchar(64) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_wallet_txn_no\` (\`transaction_no\`),
        UNIQUE KEY \`UQ_wallet_txn_idem\` (\`idempotency_key\`),
        KEY \`IDX_wallet_txn_user_id\` (\`user_id\`),
        KEY \`IDX_wallet_txn_order_id\` (\`order_id\`),
        KEY \`IDX_wallet_txn_created_at\` (\`created_at\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // 存量用户钱包回填（幂等；此后注册流程事务内创建钱包）
    await queryRunner.query(`
      INSERT INTO \`wallet\` (\`user_id\`, \`balance\`)
      SELECT u.id, 0 FROM \`user\` u
      WHERE u.role = 'user' AND NOT EXISTS (SELECT 1 FROM \`wallet\` w WHERE w.user_id = u.id)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `wallet_transaction`');
    await queryRunner.query('DROP TABLE IF EXISTS `wallet`');
  }
}
