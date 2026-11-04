import { MigrationInterface, QueryRunner } from 'typeorm';

/** 客服会话"本次咨询已完成"机制（负责人需求 #7）：同一用户可多次开新会话 + 结束时间/结束方记录 */
export class CsConversationClose1789925000000 implements MigrationInterface {
  name = 'CsConversationClose1789925000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // 旧唯一约束（生成列方案）禁止同一用户存在第二条 CS 会话 → 改为 (user_id, peer_user_id, type)：
    // CS 行 peer_user_id 为 NULL，MySQL 唯一索引中 NULL 互不相等 → 允许用户多次开新会话；好友会话对仍受保护
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` DROP INDEX \`UQ_conv_members\``);
    await queryRunner.query(`
      ALTER TABLE \`chat_conversation\`
        DROP COLUMN \`peer_key\`,
        ADD COLUMN \`closed_at\` datetime(3) NULL COMMENT '会话结束时间',
        ADD COLUMN \`closed_by\` varchar(16) NULL COMMENT '结束方 user/worker/admin',
        ADD UNIQUE KEY \`UQ_conv_pair\` (\`user_id\`, \`peer_user_id\`, \`type\`)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` DROP INDEX \`UQ_conv_pair\``);
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` DROP COLUMN \`closed_by\`, DROP COLUMN \`closed_at\``);
    await queryRunner.query(`
      ALTER TABLE \`chat_conversation\`
        ADD COLUMN \`peer_key\` bigint unsigned GENERATED ALWAYS AS (COALESCE(\`peer_user_id\`, 0)) STORED,
        ADD UNIQUE KEY \`UQ_conv_members\` (\`user_id\`, \`peer_key\`, \`type\`)
    `);
  }
}
