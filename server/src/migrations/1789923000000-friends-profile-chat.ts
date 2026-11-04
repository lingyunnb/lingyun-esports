import { MigrationInterface, QueryRunner } from 'typeorm';

/** 好友系统 + 系统通知 + 会话支持好友聊天（负责人需求 #12-19/#22-24） */
export class FriendsProfileChat1789923000000 implements MigrationInterface {
  name = 'FriendsProfileChat1789923000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`user_friend\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`requester_id\` bigint unsigned NOT NULL,
        \`addressee_id\` bigint unsigned NOT NULL,
        \`status\` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending/accepted/rejected/removed',
        \`message\` varchar(255) NOT NULL DEFAULT '',
        \`acted_at\` datetime(3) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_friend_pair\` (\`requester_id\`, \`addressee_id\`),
        KEY \`IDX_friend_addressee\` (\`addressee_id\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`user_notification\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`type\` varchar(32) NOT NULL,
        \`title\` varchar(100) NOT NULL DEFAULT '',
        \`content\` varchar(500) NOT NULL DEFAULT '',
        \`ref_id\` varchar(64) NULL,
        \`is_read\` tinyint NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_notif_user\` (\`user_id\`, \`is_read\`, \`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    // 会话支持好友聊天：type/peer 双成员；生成列保证 (owner, peer, type) 唯一（CS 行 peer=NULL 视为 0）
    await queryRunner.query(`
      ALTER TABLE \`chat_conversation\`
        DROP INDEX \`UQ_conv_user\`,
        ADD COLUMN \`type\` varchar(8) NOT NULL DEFAULT 'cs' COMMENT 'cs 客服会话 / friend 好友会话',
        ADD COLUMN \`peer_user_id\` bigint unsigned NULL COMMENT '好友会话对方（CS 为 NULL）',
        ADD COLUMN \`unread_peer\` int NOT NULL DEFAULT 0 COMMENT '好友会话对方侧未读',
        ADD COLUMN \`peer_key\` bigint unsigned GENERATED ALWAYS AS (COALESCE(\`peer_user_id\`, 0)) STORED,
        ADD UNIQUE KEY \`UQ_conv_members\` (\`user_id\`, \`peer_key\`, \`type\`),
        ADD KEY \`IDX_conv_peer\` (\`peer_user_id\`)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE \`user_friend\``);
    await queryRunner.query(`DROP TABLE \`user_notification\``);
    await queryRunner.query(`
      ALTER TABLE \`chat_conversation\`
        DROP INDEX \`UQ_conv_members\`,
        DROP INDEX \`IDX_conv_peer\`,
        DROP COLUMN \`peer_key\`,
        DROP COLUMN \`unread_peer\`,
        DROP COLUMN \`peer_user_id\`,
        DROP COLUMN \`type\`,
        ADD UNIQUE KEY \`UQ_conv_user\` (\`user_id\`)
    `);
  }
}
