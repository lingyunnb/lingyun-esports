import { MigrationInterface, QueryRunner } from 'typeorm';

/** 用户等级系统（负责人需求 #7）：user 表累计实际消费 total_spent + 等级 level；user_level_log 管理端手动调整审计 */
export class UserLevels1789922000000 implements MigrationInterface {
  name = 'UserLevels1789922000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `ALTER TABLE \`user\`
       ADD COLUMN \`level\` tinyint NOT NULL DEFAULT 1 COMMENT '等级 1-5（累计实际消费升级，客户端不可改）',
       ADD COLUMN \`total_spent\` bigint NOT NULL DEFAULT 0 COMMENT '累计实际消费积分（下单累加/退款回退）'`,
    );
    await queryRunner.query(`
      CREATE TABLE \`user_level_log\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`admin_user_id\` bigint unsigned NULL COMMENT '操作管理员（手动调整时）',
        \`from_level\` tinyint NOT NULL,
        \`to_level\` tinyint NOT NULL,
        \`reason\` varchar(255) NOT NULL DEFAULT '',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_ull_user\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`user\` DROP COLUMN \`total_spent\`, DROP COLUMN \`level\``);
    await queryRunner.query(`DROP TABLE \`user_level_log\``);
  }
}
