import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 管理员「所有者」标记（负责人需求 2026-09-23）：
 * 封禁/注销其他管理端账号属最高敏感操作，super_admin 会跳过权限点校验，
 * 因此改用账号级独占标记 is_owner —— 只有被标记的账号（kslingyun）能执行。
 */
export class AdminOwnerFlag1789932000000 implements MigrationInterface {
  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `ALTER TABLE \`admin\` ADD COLUMN \`is_owner\` tinyint NOT NULL DEFAULT 0 COMMENT '1=所有者（独占封禁/注销管理员权限）' AFTER \`status\``,
    );
    // 授予 kslingyun（负责人指定）
    await queryRunner.query(
      `UPDATE \`admin\` a JOIN \`user\` u ON u.id = a.user_id SET a.is_owner = 1 WHERE u.username = 'kslingyun'`,
    );
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`admin\` DROP COLUMN \`is_owner\``);
  }
}
