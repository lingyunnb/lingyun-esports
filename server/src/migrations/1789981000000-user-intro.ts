import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 陪玩介绍字段（负责人 2026-10-03 硬规则）
 *
 * 「找陪玩」列表**只显示 名字 + 介绍**，其余字段一律不要。
 * 介绍由**管理端**填写维护，因此落在 user 表（工作端账号同一份资料）：
 * - `intro`：介绍正文（客户端只读展示）
 * - `intro_updated_by`：最后修改的管理员 id（可审计）
 */
export class UserIntro1789981000000 implements MigrationInterface {
  name = 'UserIntro1789981000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const [exists] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = 'intro'`,
    );
    if (Number(exists.c) === 0) {
      await queryRunner.query(`ALTER TABLE \`user\` ADD COLUMN \`intro\` varchar(200) NOT NULL DEFAULT '' AFTER \`nickname\``);
    }
    const [existsBy] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = 'intro_updated_by'`,
    );
    if (Number(existsBy.c) === 0) {
      await queryRunner.query(
        `ALTER TABLE \`user\` ADD COLUMN \`intro_updated_by\` bigint unsigned NULL AFTER \`intro\``,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`user\` DROP COLUMN \`intro_updated_by\``);
    await queryRunner.query(`ALTER TABLE \`user\` DROP COLUMN \`intro\``);
  }
}
