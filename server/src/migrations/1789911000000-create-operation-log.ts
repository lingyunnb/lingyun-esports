import { MigrationInterface, QueryRunner } from 'typeorm';

/** 阶段9：管理端操作日志表（docs/02） */
export class CreateOperationLog1789911000000 implements MigrationInterface {
  name = 'CreateOperationLog1789911000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`operation_log\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`admin_id\` bigint unsigned NULL,
        \`admin_name\` varchar(32) NULL,
        \`module\` varchar(32) NOT NULL,
        \`action\` varchar(64) NOT NULL,
        \`method\` varchar(16) NOT NULL,
        \`path\` varchar(255) NOT NULL,
        \`request_body\` text NULL,
        \`ip\` varchar(64) NULL,
        \`request_id\` varchar(64) NULL,
        \`result\` varchar(16) NOT NULL DEFAULT 'success',
        \`error_msg\` varchar(255) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_operation_log_admin_id\` (\`admin_id\`),
        KEY \`IDX_operation_log_action_created\` (\`action\`, \`created_at\`),
        KEY \`IDX_operation_log_request_id\` (\`request_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `operation_log`');
  }
}
