import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 用户封禁（负责人需求）：user 表增加 banned_until（封禁截止时间，NULL=永久封禁）
 * 语义：status=2 且 banned_until 为 NULL → 永久封禁；banned_until 有值 → 封禁至该时刻（到期登录时自动解封）
 */
export class UserBanDelete1789930000000 implements MigrationInterface {
  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `ALTER TABLE \`user\` ADD COLUMN \`banned_until\` datetime(3) NULL COMMENT '封禁截止时间（NULL=永久）' AFTER \`status\``,
    );
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`user\` DROP COLUMN \`banned_until\``);
  }
}
