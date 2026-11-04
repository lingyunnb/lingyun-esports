import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 老板端版本更新（负责人云端更新需求，2026-09-22）：
 * app_version 表记录每次上传的 APK（文件名/版本号/大小/哈希/路径/状态/上传人），
 * 仅 boss 端启用更新机制（app_type 预留 worker）。
 */
export class CreateAppVersion1789931000000 implements MigrationInterface {
  async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`app_version\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`app_type\` varchar(16) NOT NULL DEFAULT 'boss' COMMENT 'boss/worker（本期仅 boss）',
        \`version_code\` int NOT NULL COMMENT '数字版本号（版本比较依据）',
        \`version_name\` varchar(32) NOT NULL COMMENT '展示版本名',
        \`update_desc\` text NOT NULL COMMENT '更新说明',
        \`force_update\` tinyint NOT NULL DEFAULT 0 COMMENT '1 强制更新',
        \`min_supported_version\` int NOT NULL DEFAULT 1 COMMENT '最低支持版本（预留）',
        \`file_name\` varchar(255) NOT NULL COMMENT '原始文件名',
        \`file_size\` bigint NOT NULL COMMENT '字节数',
        \`file_hash\` varchar(64) NOT NULL COMMENT 'sha256',
        \`file_path\` varchar(512) NOT NULL COMMENT '服务器磁盘路径',
        \`status\` tinyint NOT NULL DEFAULT 1 COMMENT '1 启用 2 停用',
        \`uploaded_by\` bigint unsigned NULL COMMENT '上传管理员 user id',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_app_version_type_status\` (\`app_type\`, \`status\`),
        KEY \`IDX_app_version_type_code\` (\`app_type\`, \`version_code\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `app_version`');
  }
}
