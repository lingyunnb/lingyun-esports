import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * AI 咨询「祁小山」建表（负责人 2026-10-04）
 *
 * 1) `ai_conversation`：每用户一条长期会话（`user_id` 唯一），`last_seq` 为会话内 seq 水位
 * 2) `ai_message`：AI 咨询消息（user / assistant / system），
 *    `role`+`seq`+`content` 为契约必需列；`msg_id`/`reply_msg_id`/`idempotency_key` 为工程补充：
 *    - `msg_id`：对外消息 id（UUID），WS `ai:chunk|done|error` 的 messageId 即 assistant 行的 msg_id
 *    - `reply_msg_id`：用户行记录"本次提问对应的回复 id"，幂等重放时据此回放同一答案
 *    - `idempotency_key`：客户端重试幂等（同用户唯一，NULL 不参与唯一约束）
 *    `provider`/`model`：本行由哪个供应商/模型生成（规则兜底=rule/none）
 *    `cached`：1 = 命中 30 秒同问缓存（未调用模型）
 * 3) 注册管理端只读权限点 `admin:ai:read`（会话/消息查看），授予既有全部管理角色（与 admin:club:* 同规）
 * 4) `system_setting` 写入 AI 咨询可配置项（管理端可改，客户端 `GET /user/ai/config` 下发）：
 *    - `ai_enabled`（总开关）/ `ai_greeting`（开场白）/ `ai_max_input_length`（输入上限）
 *      / `ai_presets`（快捷问题 chips）
 *
 * 说明：不改任何既有表结构（除 system_setting 种子数据），与既有 chat 体系完全解耦。
 */
export class CreateAiTables1790000000000 implements MigrationInterface {
  name = 'CreateAiTables1790000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`ai_conversation\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL COMMENT '老板端用户（长期会话，一人一条）',
        \`last_seq\` bigint unsigned NOT NULL DEFAULT 0 COMMENT '会话内消息 seq 水位',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_ai_conv_user\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='AI 咨询会话（祁小山，每用户一条长期会话）'
    `);

    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`ai_message\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`msg_id\` varchar(40) NOT NULL COMMENT '对外消息 id（UUID）',
        \`conversation_id\` bigint unsigned NOT NULL,
        \`user_id\` bigint unsigned NOT NULL COMMENT '归属用户（服务端从 JWT sub 写入）',
        \`role\` varchar(16) NOT NULL COMMENT 'user | assistant | system',
        \`content\` mediumtext NOT NULL,
        \`seq\` bigint unsigned NOT NULL COMMENT '会话内递增序号',
        \`provider\` varchar(32) DEFAULT NULL COMMENT 'glm | rule（降级）',
        \`model\` varchar(64) DEFAULT NULL COMMENT 'glm-4-flash 等；降级为 none',
        \`cached\` tinyint NOT NULL DEFAULT 0 COMMENT '1 = 命中 30 秒同问缓存，未调用模型',
        \`idempotency_key\` varchar(64) DEFAULT NULL COMMENT '客户端重试幂等键（同用户唯一）',
        \`reply_msg_id\` varchar(40) DEFAULT NULL COMMENT '用户行：本次提问对应的回复 msg_id',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_ai_msg_msg_id\` (\`msg_id\`),
        UNIQUE KEY \`UQ_ai_msg_user_idem\` (\`user_id\`, \`idempotency_key\`),
        KEY \`IDX_ai_msg_conv_seq\` (\`conversation_id\`, \`seq\`),
        KEY \`IDX_ai_msg_user\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='AI 咨询消息'
    `);

    // 权限点 + 授予既有管理角色（super_admin 等；与 admin:club:* 同规）
    await queryRunner.query(
      `INSERT INTO permission (code, name, group_name, created_at) VALUES (?, ?, 'AI 咨询', NOW(3))
       ON DUPLICATE KEY UPDATE name = VALUES(name), group_name = VALUES(group_name)`,
      ['admin:ai:read', 'AI 咨询查看'],
    );
    await queryRunner.query(`
      INSERT IGNORE INTO admin_role_permission (role_id, permission_id, created_at)
      SELECT r.id, p.id, NOW(3) FROM admin_role r CROSS JOIN permission p
      WHERE p.code = 'admin:ai:read'
    `);

    // 可配置项种子（幂等：已存在则不动，避免覆盖负责人已改的值）
    const settings: Array<[string, string, string]> = [
      ['ai_enabled', JSON.stringify({ value: true }), 'AI 咨询（祁小山）总开关'],
      [
        'ai_greeting',
        JSON.stringify({ value: '我是祁小山，祁连山电竞的客服。订单、积分、售后的事直接说，我帮你看。' }),
        'AI 咨询开场白',
      ],
      ['ai_max_input_length', JSON.stringify({ value: 500 }), 'AI 咨询单条输入长度上限'],
      [
        'ai_presets',
        JSON.stringify({
          value: [
            { label: '怎么下单', text: '怎么下单？' },
            { label: '积分怎么用', text: '积分怎么用？' },
            { label: '退款规则', text: '退款规则是什么？' },
            { label: '转人工', text: '我要转人工客服' },
          ],
        }),
        'AI 咨询快捷问题（chips）',
      ],
    ];
    for (const [key, value, description] of settings) {
      await queryRunner.query(
        `INSERT INTO system_setting (setting_key, cfg_value, description, is_high_security, created_at, updated_at)
         VALUES (?, CAST(? AS JSON), ?, 0, NOW(3), NOW(3))
         ON DUPLICATE KEY UPDATE setting_key = setting_key`,
        [key, value, description],
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM system_setting WHERE setting_key IN ('ai_enabled','ai_greeting','ai_max_input_length','ai_presets')`);
    await queryRunner.query(`DELETE FROM admin_role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code = 'admin:ai:read')`);
    await queryRunner.query(`DELETE FROM permission WHERE code = 'admin:ai:read'`);
    await queryRunner.query(`DROP TABLE IF EXISTS \`ai_message\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`ai_conversation\``);
  }
}
