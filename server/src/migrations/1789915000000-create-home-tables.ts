import { MigrationInterface, QueryRunner } from 'typeorm';

/** 首页内容系统：Banner/公告/优秀打手/通用模块 4 张表 */
export class CreateHomeTables1789915000000 implements MigrationInterface {
  name = 'CreateHomeTables1789915000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`home_banner\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`title\` varchar(64) NOT NULL,
        \`image_url\` varchar(500) NOT NULL,
        \`link_type\` varchar(16) NOT NULL DEFAULT 'none',
        \`link_value\` varchar(255) NULL,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`visible\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_home_banner_visible_sort\` (\`visible\`, \`sort_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`announcement\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`title\` varchar(100) NOT NULL,
        \`summary\` varchar(500) NOT NULL DEFAULT '',
        \`content\` text NOT NULL,
        \`pinned\` tinyint NOT NULL DEFAULT 0,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`visible\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_announcement_pinned_sort\` (\`visible\`, \`pinned\`, \`sort_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`top_worker\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`worker_id\` bigint unsigned NOT NULL,
        \`display_name\` varchar(32) NOT NULL,
        \`avatar_url\` varchar(500) NULL,
        \`skills\` varchar(100) NOT NULL DEFAULT '',
        \`rating\` decimal(2,1) NOT NULL DEFAULT 5.0,
        \`completed_orders\` int NOT NULL DEFAULT 0,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`visible\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_top_worker_worker\` (\`worker_id\`),
        KEY \`IDX_top_worker_visible_sort\` (\`visible\`, \`sort_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`home_module\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`module_key\` varchar(32) NOT NULL,
        \`title\` varchar(64) NOT NULL,
        \`content\` text NULL,
        \`extra_json\` json NULL,
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`visible\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_home_module_key\` (\`module_key\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // 默认模块配置（俱乐部介绍 / 活动 / 立即下单按钮；内容由管理端后续修改）
    await queryRunner.query(`
      INSERT IGNORE INTO \`home_module\` (\`module_key\`, \`title\`, \`content\`, \`extra_json\`, \`sort_order\`, \`visible\`) VALUES
      ('club_intro', '关于 祁连山电竞', '祁连山电竞俱乐部专注使命召唤手游陪练与上分服务，汇聚优秀打手，用专业与热情陪伴每一位玩家。', NULL, 10, 1),
      ('activity', '俱乐部活动', '', NULL, 40, 2),
      ('order_button', '立即下单', '立即下单', JSON_OBJECT('tab', 'order'), 90, 1)
    `);
    // 默认公告与优秀打手（示例数据，管理端可改）
    await queryRunner.query(`
      INSERT IGNORE INTO \`announcement\` (\`title\`, \`summary\`, \`content\`, \`pinned\`, \`sort_order\`, \`visible\`) VALUES
      ('欢迎来到 祁连山电竞', '祁连山电竞俱乐部正式上线，快来体验专业陪玩服务。', '祁连山电竞俱乐部正式上线！\n\n我们提供 CODM 段位上分、代打、娱乐陪玩等服务。\n\n新用户积分由管理员发放，如有疑问请联系客服。', 1, 1, 1)
    `);
    await queryRunner.query(`
      INSERT IGNORE INTO \`top_worker\` (\`worker_id\`, \`display_name\`, \`skills\`, \`rating\`, \`completed_orders\`, \`sort_order\`, \`visible\`)
      SELECT w.id, u.nickname, 'CODM 段位上分 · 娱乐陪玩', 4.9, 128, 1, 1
      FROM \`worker\` w JOIN \`user\` u ON u.id = w.user_id WHERE u.username = 'worker01' LIMIT 1
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `home_module`');
    await queryRunner.query('DROP TABLE IF EXISTS `top_worker`');
    await queryRunner.query('DROP TABLE IF EXISTS `announcement`');
    await queryRunner.query('DROP TABLE IF EXISTS `home_banner`');
  }
}
