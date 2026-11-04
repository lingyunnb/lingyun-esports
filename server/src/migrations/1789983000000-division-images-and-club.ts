import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 负责人 2026-10-04：首页/下单页要能在管理端高度自定义
 * - division 加 图标图 / 封面图 / 副标题（首页圈出的图可换）
 * - 新建 club 官方馆表（封面图、评分、单量由管理端维护，替代客户端写死）
 * - orders 加 联系方式 / 护航员选择（随机或指定）
 */
export class DivisionImagesAndClub1789983000000 implements MigrationInterface {
  name = 'DivisionImagesAndClub1789983000000';

  public async up(q: QueryRunner): Promise<void> {
    await q.query(`ALTER TABLE \`division\`
      ADD COLUMN icon_media_id BIGINT UNSIGNED NULL COMMENT '专区圆形图媒体 id',
      ADD COLUMN cover_media_id BIGINT UNSIGNED NULL COMMENT '分部卡封面图媒体 id',
      ADD COLUMN sub_title VARCHAR(64) NOT NULL DEFAULT '' COMMENT '副标题'`);

    await q.query(`CREATE TABLE IF NOT EXISTS \`club\` (
      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      name VARCHAR(40) NOT NULL,
      sub_title VARCHAR(64) NOT NULL DEFAULT '',
      description VARCHAR(255) NOT NULL DEFAULT '',
      cover_media_id BIGINT UNSIGNED NULL,
      badge VARCHAR(16) NOT NULL DEFAULT '官方',
      rating DECIMAL(3,1) NOT NULL DEFAULT 5.0,
      order_count INT NOT NULL DEFAULT 0,
      division_id BIGINT UNSIGNED NULL,
      sort_order INT NOT NULL DEFAULT 0,
      status TINYINT NOT NULL DEFAULT 1,
      created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
      updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      PRIMARY KEY (id),
      KEY IDX_club_status_sort (status, sort_order)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='官方自营馆（管理端可维护）'`);

    await q.query(`ALTER TABLE \`order\`
      ADD COLUMN contact_phone VARCHAR(20) NOT NULL DEFAULT '' COMMENT '联系方式（选填）',
      ADD COLUMN worker_mode VARCHAR(16) NOT NULL DEFAULT 'random' COMMENT 'random 随机安排 / designated 指定护航员',
      ADD COLUMN designated_worker_id BIGINT UNSIGNED NULL COMMENT '指定护航员（worker.id）'`);
  }

  public async down(q: QueryRunner): Promise<void> {
    await q.query('ALTER TABLE `order` DROP COLUMN contact_phone, DROP COLUMN worker_mode, DROP COLUMN designated_worker_id');
    await q.query('DROP TABLE IF EXISTS `club`');
    await q.query('ALTER TABLE `division` DROP COLUMN icon_media_id, DROP COLUMN cover_media_id, DROP COLUMN sub_title');
  }
}
