import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 已读位点 + 系统消息（负责人 2026-10-04）
 *
 * 1) 已读回执精确化：`chat_conversation` 增加三方已读位点列
 *    - `user_read_seq`   属主（老板）读到第几条
 *    - `peer_read_seq`   对端（好友 / 打手直聊里的打手）读到第几条
 *    - `worker_read_seq` CS 会话里被指派客服读到第几条
 *    markRead 时把读者位点推给会话内另一方（WS `msg:read`）；
 *    发送方用 `对方位点 >= 我方消息 seq` 判定双勾，否则单勾（已送达）。
 *
 * 2) 系统消息：**不新增表/列** —— 复用既有 `chat_message`：
 *    `sender_type='system'` + `sender_id=0` + `msg_type='system'` + `content` 为文案
 *    （sender_id 无外键约束，0 表示"非真人"；客户端按 msg_type!='text/image' 走居中灰 chip 渲染）
 *
 * 3) 回填（避免老会话永远是单勾）：未读为 0 = 该侧已读完 → 位点取「非本人发送（且非系统）的最大 seq」；
 *    仍有未读则位点保持 0（保守：宁可单勾，不可错标已读）。
 */
export class ChatReadSeqAndSystemMsg1789985000000 implements MigrationInterface {
  name = 'ChatReadSeqAndSystemMsg1789985000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `ALTER TABLE \`chat_conversation\`
         ADD COLUMN \`user_read_seq\` bigint unsigned NOT NULL DEFAULT 0 AFTER \`unread_peer\`,
         ADD COLUMN \`peer_read_seq\` bigint unsigned NOT NULL DEFAULT 0 AFTER \`user_read_seq\`,
         ADD COLUMN \`worker_read_seq\` bigint unsigned NOT NULL DEFAULT 0 AFTER \`peer_read_seq\``,
    );

    // 属主位点回填：unread_user = 0 → 已读完对端消息
    await queryRunner.query(`
      UPDATE chat_conversation c
      SET c.user_read_seq = COALESCE((
        SELECT MAX(m.seq) FROM chat_message m
        WHERE m.conversation_id = c.id AND m.sender_type <> 'system' AND m.sender_id <> c.user_id
      ), 0)
      WHERE c.unread_user = 0
    `);
    // 对端位点回填：unread_peer = 0 → 对端已读完属主消息（仅 friend / worker 双人会话有 peer）
    await queryRunner.query(`
      UPDATE chat_conversation c
      SET c.peer_read_seq = COALESCE((
        SELECT MAX(m.seq) FROM chat_message m
        WHERE m.conversation_id = c.id AND m.sender_type <> 'system' AND m.sender_id <> c.peer_user_id
      ), 0)
      WHERE c.unread_peer = 0 AND c.peer_user_id IS NOT NULL
    `);
    // 客服位点回填：unread_worker = 0 且存在 active 指派 → 被指派客服已读完老板消息
    await queryRunner.query(`
      UPDATE chat_conversation c
      JOIN chat_conversation_assign a ON a.conversation_id = c.id AND a.status = 'active'
      SET c.worker_read_seq = COALESCE((
        SELECT MAX(m.seq) FROM chat_message m
        WHERE m.conversation_id = c.id AND m.sender_type <> 'system' AND m.sender_id <> a.worker_user_id
      ), 0)
      WHERE c.unread_worker = 0 AND c.type = 'cs'
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `ALTER TABLE \`chat_conversation\`
         DROP COLUMN \`worker_read_seq\`,
         DROP COLUMN \`peer_read_seq\`,
         DROP COLUMN \`user_read_seq\``,
    );
  }
}
