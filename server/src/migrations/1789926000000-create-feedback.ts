import { MigrationInterface, QueryRunner } from 'typeorm';

/** 意见反馈（负责人设置需求）：用户提交 → 管理端查看/处理留痕 */
export class CreateFeedback1789926000000 implements MigrationInterface {
  name = 'CreateFeedback1789926000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`user_feedback\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`content\` varchar(1000) NOT NULL,
        \`contact\` varchar(100) NOT NULL DEFAULT '',
        \`status\` tinyint NOT NULL DEFAULT 1 COMMENT '1 待处理 / 2 已处理',
        \`handler_id\` bigint unsigned NULL,
        \`handler_remark\` varchar(500) NOT NULL DEFAULT '',
        \`handled_at\` datetime(3) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_feedback_status\` (\`status\`, \`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE \`user_feedback\``);
  }
}
