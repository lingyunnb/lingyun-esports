import { MigrationInterface, QueryRunner } from 'typeorm';

/** 阶段11/12：游戏/游戏配置/分类/商品/商品媒体 5 张表（docs/02、docs/13） */
export class CreateCatalogTables1789913000000 implements MigrationInterface {
  name = 'CreateCatalogTables1789913000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`game\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`code\` varchar(32) NOT NULL,
        \`name\` varchar(32) NOT NULL,
        \`icon_media_id\` bigint unsigned NULL,
        \`banner_media_id\` bigint unsigned NULL,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`status\` tinyint NOT NULL DEFAULT 1,
        \`config_json\` json NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_game_code\` (\`code\`),
        KEY \`IDX_game_status_sort\` (\`status\`, \`sort_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`game_config\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`game_id\` bigint unsigned NOT NULL,
        \`cfg_key\` varchar(32) NOT NULL,
        \`cfg_value\` json NOT NULL,
        \`remark\` varchar(100) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_game_config_game_key\` (\`game_id\`, \`cfg_key\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`category\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`game_id\` bigint unsigned NOT NULL,
        \`parent_id\` bigint unsigned NULL,
        \`name\` varchar(32) NOT NULL,
        \`icon_media_id\` bigint unsigned NULL,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`status\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_category_game_status\` (\`game_id\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`product\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`name\` varchar(64) NOT NULL,
        \`subtitle\` varchar(64) NOT NULL DEFAULT '',
        \`game_id\` bigint unsigned NOT NULL,
        \`category_id\` bigint unsigned NOT NULL,
        \`price\` int NOT NULL,
        \`price_unit\` varchar(16) NOT NULL DEFAULT '局',
        \`estimate_duration_min\` int NOT NULL DEFAULT 30,
        \`service_status\` tinyint NOT NULL DEFAULT 2,
        \`sales_count\` int NOT NULL DEFAULT 0,
        \`cover_media_id\` bigint unsigned NULL,
        \`description\` text NULL,
        \`detail\` text NULL,
        \`service_flow\` text NULL,
        \`service_rules\` text NULL,
        \`attention\` text NULL,
        \`extra_json\` json NULL,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`status\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_product_game_category_status\` (\`game_id\`, \`category_id\`, \`status\`),
        KEY \`IDX_product_status_sort\` (\`status\`, \`sort_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`product_media\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`product_id\` bigint unsigned NOT NULL,
        \`media_id\` bigint unsigned NOT NULL,
        \`media_type\` varchar(16) NOT NULL DEFAULT 'image',
        \`is_cover\` tinyint NOT NULL DEFAULT 0,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_product_media_product\` (\`product_id\`, \`sort_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `product_media`');
    await queryRunner.query('DROP TABLE IF EXISTS `product`');
    await queryRunner.query('DROP TABLE IF EXISTS `category`');
    await queryRunner.query('DROP TABLE IF EXISTS `game_config`');
    await queryRunner.query('DROP TABLE IF EXISTS `game`');
  }
}
