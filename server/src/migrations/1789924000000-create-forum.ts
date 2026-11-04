import { MigrationInterface, QueryRunner } from 'typeorm';

/** 论坛/社区（负责人需求 #25-32）：动态帖 + 评论 + 点赞（媒体复用 media 表） */
export class CreateForum1789924000000 implements MigrationInterface {
  name = 'CreateForum1789924000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`forum_post\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`author_id\` bigint unsigned NOT NULL,
        \`content\` varchar(5000) NOT NULL DEFAULT '',
        \`media_ids\` varchar(1024) NOT NULL DEFAULT '' COMMENT '图片 media id JSON 数组（按序）',
        \`video_media_id\` bigint unsigned NULL,
        \`cover_media_id\` bigint unsigned NULL COMMENT '视频封面',
        \`like_count\` int NOT NULL DEFAULT 0,
        \`comment_count\` int NOT NULL DEFAULT 0,
        \`status\` tinyint NOT NULL DEFAULT 1 COMMENT '1 正常 / 2 作者删除 / 3 管理员下架',
        \`client_request_id\` varchar(64) NULL COMMENT '发布幂等键',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_post_req\` (\`client_request_id\`),
        KEY \`IDX_post_status\` (\`status\`, \`id\`),
        KEY \`IDX_post_author\` (\`author_id\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`forum_comment\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`post_id\` bigint unsigned NOT NULL,
        \`author_id\` bigint unsigned NOT NULL,
        \`content\` varchar(1000) NOT NULL,
        \`status\` tinyint NOT NULL DEFAULT 1 COMMENT '1 正常 / 2 作者删除 / 3 管理员删除',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_comment_post\` (\`post_id\`, \`status\`, \`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`forum_like\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`post_id\` bigint unsigned NOT NULL,
        \`user_id\` bigint unsigned NOT NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_like_post_user\` (\`post_id\`, \`user_id\`),
        KEY \`IDX_like_user\` (\`user_id\`, \`post_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE \`forum_like\``);
    await queryRunner.query(`DROP TABLE \`forum_comment\``);
    await queryRunner.query(`DROP TABLE \`forum_post\``);
  }
}
