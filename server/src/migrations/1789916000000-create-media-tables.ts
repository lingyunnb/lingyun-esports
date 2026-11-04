import { MigrationInterface, QueryRunner } from 'typeorm';

/** 阶段13 媒体系统：media 表 + product_media 关联表 + 各业务表 media_id 引用列（docs/08） */
export class CreateMediaTables1789916000000 implements MigrationInterface {
  name = 'CreateMediaTables1789916000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`media\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`file_key\` varchar(255) NOT NULL,
        \`media_type\` varchar(32) NOT NULL,
        \`original_name\` varchar(255) NOT NULL DEFAULT '',
        \`mime_type\` varchar(64) NOT NULL,
        \`extension\` varchar(16) NOT NULL,
        \`size_bytes\` bigint unsigned NOT NULL,
        \`width\` int unsigned NULL,
        \`height\` int unsigned NULL,
        \`sha256\` char(64) NOT NULL,
        \`uploader_id\` bigint unsigned NULL,
        \`is_protected\` tinyint NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_media_sha256_type\` (\`sha256\`, \`media_type\`),
        KEY \`IDX_media_type\` (\`media_type\`),
        KEY \`IDX_media_uploader\` (\`uploader_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    // product_media 表阶段 11/12 已建（media_type/is_cover 结构），此处只补媒体唯一约束（防重复挂载）
    await queryRunner.query(`ALTER TABLE \`product_media\` ADD UNIQUE KEY \`UQ_product_media\` (\`product_id\`, \`media_id\`)`);
    // 商品主图复用既有 cover_media_id（阶段 11/12 预留未启用）；新增视频/视频封面（可空）
    await queryRunner.query(`ALTER TABLE \`product\` ADD \`video_media_id\` bigint unsigned NULL, ADD \`video_cover_media_id\` bigint unsigned NULL`);
    // Banner 图片（可空；image_url 保留为历史兼容，media 优先）
    await queryRunner.query(`ALTER TABLE \`home_banner\` ADD \`image_media_id\` bigint unsigned NULL`);
    // 优秀打手头像（可空；avatar_url 保留为历史兼容）
    await queryRunner.query(`ALTER TABLE \`top_worker\` ADD \`avatar_media_id\` bigint unsigned NULL`);
    // 注：user.avatar_media_id/background_media_id 阶段8 建表时已存在，不重复添加
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`top_worker\` DROP COLUMN \`avatar_media_id\``);
    await queryRunner.query(`ALTER TABLE \`home_banner\` DROP COLUMN \`image_media_id\``);
    await queryRunner.query(`ALTER TABLE \`product\` DROP COLUMN \`video_cover_media_id\`, DROP COLUMN \`video_media_id\``);
    await queryRunner.query(`ALTER TABLE \`product_media\` DROP INDEX \`UQ_product_media\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`media\``);
  }
}
