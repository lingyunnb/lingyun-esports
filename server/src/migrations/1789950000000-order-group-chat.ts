import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 订单群组（负责人需求 2026-09-24）：
 * 1. chat_conversation 增加 order_id（一单一群，唯一约束防并发重复创建）与 name（群名"订单群-订单号"）
 * 2. 新表 chat_conversation_member：群成员（老板/打手/lingyunya），每成员独立未读数
 * 复用现有 chat_message 消息结构（msg_id 唯一 + seq 顺序 + client_msg_id 幂等），不另造消息系统
 */
export class OrderGroupChat1789950000000 implements MigrationInterface {
  name = 'OrderGroupChat1789950000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` ADD COLUMN \`order_id\` bigint unsigned NULL COMMENT '订单群关联订单（一单一群）' AFTER \`peer_user_id\``);
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` ADD COLUMN \`name\` varchar(64) NULL COMMENT '群组名称' AFTER \`order_id\``);
    await queryRunner.query(`CREATE UNIQUE INDEX \`UQ_conv_order\` ON \`chat_conversation\` (\`order_id\`)`);
    await queryRunner.query(`
      CREATE TABLE \`chat_conversation_member\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`conversation_id\` bigint unsigned NOT NULL,
        \`user_id\` bigint unsigned NOT NULL,
        \`role\` varchar(16) NOT NULL DEFAULT 'boss' COMMENT 'boss 下单老板 / worker 打手 / admin 管理员(lingyunya)',
        \`unread\` int NOT NULL DEFAULT 0 COMMENT '该成员未读数',
        \`joined_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_conv_member\` (\`conversation_id\`, \`user_id\`),
        KEY \`IDX_member_user\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`chat_conversation_member\``);
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` DROP INDEX \`UQ_conv_order\``);
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` DROP COLUMN \`name\``);
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` DROP COLUMN \`order_id\``);
  }
}
