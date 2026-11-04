import { MigrationInterface, QueryRunner } from 'typeorm';

/** 官网内容（负责人 2026-09-25）：单行 JSON，官网所有展示内容由管理端高度自定义 */
export class SiteContent1789970000000 implements MigrationInterface {
  name = 'SiteContent1789970000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`site_content\` (
        \`id\` int NOT NULL AUTO_INCREMENT,
        \`content\` json NOT NULL,
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    // 默认内容（管理端可全量修改）
    await queryRunner.query(`
      INSERT IGNORE INTO \`site_content\` (\`id\`, \`content\`) VALUES (1, JSON_OBJECT(
        'siteTitle', '祁连山电竞俱乐部',
        'logoText', '祁连山电竞',
        'heroTitle', '祁连山电竞俱乐部',
        'heroSubtitle', 'CODM 专业陪玩 · 代练 · 玩家社区 —— 让每一局都有高手护航',
        'heroBgUrl', '',
        'clubTitle', '关于俱乐部',
        'clubParagraphs', JSON_ARRAY('祁连山电竞俱乐部专注于 CODM（使命召唤手游），汇聚一批高分段职业陪玩与代练选手，为玩家提供开黑陪玩、上分代练、专属客服等一站式服务。', '我们相信：每一局都值得认真对待。俱乐部以严格筛选的打手团队与透明规范的订单流程，为每一位老板带来稳定、安全、省心的游戏体验。'),
        'clubImageUrl', '',
        'videoTitle', '俱乐部宣传片',
        'videoUrl', '/site/assets/promo-bgm.mp4',
        'galleryTitle', '精彩瞬间',
        'galleryItems', JSON_ARRAY(),
        'downloadTitle', '下载客户端',
        'downloadNote', '扫描二维码或在手机上打开本页，即可下载老板端 / 工作端客户端。客户端主要用于下单与接单，俱乐部内容以本页为准。',
        'footerText', '© 2026 祁连山电竞俱乐部 · 让每一局都有高手护航',
        'contactText', '加入我们：联系管理员获取俱乐部最新活动'
      ))
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`site_content\``);
  }
}
