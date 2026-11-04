import { MigrationInterface, QueryRunner } from 'typeorm';

/** 聊天系统（M6，docs/07）：会话 / 客服会话授权 / 消息（seq 会话内递增 + client_msg_id 幂等） */
export class CreateChatTables1789920000000 implements MigrationInterface {
  name = 'CreateChatTables1789920000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`chat_conversation\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`last_seq\` bigint unsigned NOT NULL DEFAULT 0,
        \`unread_user\` int NOT NULL DEFAULT 0,
        \`unread_worker\` int NOT NULL DEFAULT 0,
        \`status\` varchar(16) NOT NULL DEFAULT 'open',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_conv_user\` (\`user_id\`),
        KEY \`IDX_conv_status\` (\`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`chat_conversation_assign\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`conversation_id\` bigint unsigned NOT NULL,
        \`worker_user_id\` bigint unsigned NOT NULL,
        \`status\` varchar(16) NOT NULL DEFAULT 'active',
        \`assigned_by\` bigint unsigned NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_assign_worker_status\` (\`worker_user_id\`, \`status\`),
        KEY \`IDX_assign_conv\` (\`conversation_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`chat_message\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`msg_id\` varchar(40) NOT NULL,
        \`conversation_id\` bigint unsigned NOT NULL,
        \`seq\` bigint unsigned NOT NULL,
        \`sender_type\` varchar(16) NOT NULL,
        \`sender_id\` bigint unsigned NOT NULL,
        \`msg_type\` varchar(16) NOT NULL DEFAULT 'text',
        \`content\` text NOT NULL,
        \`client_msg_id\` varchar(64) NULL,
        \`recalled\` tinyint NOT NULL DEFAULT 0,
        \`recalled_at\` datetime(3) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_msg_id\` (\`msg_id\`),
        UNIQUE KEY \`UQ_msg_client\` (\`conversation_id\`, \`client_msg_id\`),
        KEY \`IDX_msg_conv_seq\` (\`conversation_id\`, \`seq\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`chat_message\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`chat_conversation_assign\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`chat_conversation\``);
  }
}
