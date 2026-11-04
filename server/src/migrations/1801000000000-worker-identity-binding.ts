import { MigrationInterface, QueryRunner } from 'typeorm';

import {
  WORKER_BINDING_MAX_PER_BOSS_DEFAULT,
  WORKER_BINDING_MAX_PER_BOSS_DESCRIPTION,
  WORKER_BINDING_MAX_PER_BOSS_KEY,
} from '../modules/auth/worker-binding-limit';

/**
 * 合并双端 · 身份切换（方案甲）地基 1/2：`worker_identity_binding` 绑定表 + 绑定上限配置。
 *
 * 负责人 2026-10-06 拍板四条（本迁移只落数据模型，客户端由另一任务做）：
 * ① 停用工作端 App；② 一个老板账号默认绑 1 个打手账号（上限可配、**可解绑**）；
 * ③ 必须做"伴随会话"（绑定打手账密不顶掉打手原有登录）；④ 打手态消息只留【老板】【客服】两段。
 *
 * ---------------------------------------------------------------------------
 * 1) 唯一约束：为什么是「生成的 active 列 + 槽位」而不是普通唯一键
 *
 * 需求是「同一 boss 在 active 时只能有一条（默认上限 1）**且上限可配**」，两者用同一个固定唯一键
 * 无法同时满足（上限改成 2 就会被唯一键一票否决）。MySQL 没有条件唯一索引（无 partial index），
 * 因此用**生成列**替代：
 *
 *   `active_boss_user_id`   = CASE WHEN status='active' THEN boss_user_id   ELSE NULL END  (STORED)
 *   `active_worker_user_id` = CASE WHEN status='active' THEN worker_user_id ELSE NULL END  (STORED)
 *
 * MySQL 的唯一索引**忽略含 NULL 的键**（多行 NULL 互不冲突），于是：
 * - `UK_wib_active_worker (active_worker_user_id)`：**一个打手账号同时只能被一个老板绑定**
 *   —— 与上限无关的语义硬约束（否则一个打手会被多人来回切换，语义混乱）；解绑后 NULL 释放。
 * - `UK_wib_active_boss_slot (active_boss_user_id, slot)`：老板侧最多 `上限` 条 active
 *   （第 i 条占槽位 i，服务层取最小空闲槽）。上限=1 时等价于"一个老板只能有一条 active"；
 *   上限=2/3 时也成立；**并发**抢同一槽位由唯一键兜底（服务层计数 + 唯一键双保险）。
 * - 解绑 = `status='unbound'` + `unbound_at`（**保留历史行，不删除**，可审计可追溯）；
 *   解绑行两个 active 列自动变 NULL → 立刻释放两个唯一键名额。
 *
 * 2) 上限配置：`system_setting.worker_binding_max_per_boss`
 * - `{"value": 1}` 形状，与 `platform_commission_rate` / `purchase_points_hint` 同一套约定；
 * - `is_high_security = 1` → **仅超级管理员可改**（复用既有机制，普通管理员可读不可写）；
 * - 读侧 `SystemSettingService.value(key, 1)` 每次实时读库（无缓存）→ 管理端改完下一次绑定即生效。
 *
 * 3) 幂等：`CREATE TABLE IF NOT EXISTS` + `INSERT ... ON DUPLICATE KEY UPDATE setting_key = setting_key`
 *    —— 重复执行不报错，且**不会冲掉运营已经改过的上限值**。
 * 4) 回滚：仅删表 + 删该配置行（不触碰 user/worker/auth_token 任何既有数据）。
 */
export class WorkerIdentityBinding1801000000000 implements MigrationInterface {
  name = 'WorkerIdentityBinding1801000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`worker_identity_binding\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`boss_user_id\` bigint unsigned NOT NULL COMMENT '老板账号 id（user.id，role=user）',
        \`worker_user_id\` bigint unsigned NOT NULL COMMENT '打手账号 id（user.id，role=worker）',
        \`status\` varchar(16) NOT NULL DEFAULT 'active' COMMENT 'active 生效 / unbound 已解绑（解绑保留历史行，不删除）',
        \`slot\` tinyint unsigned NOT NULL DEFAULT 1 COMMENT '老板侧配额槽位（1..上限），配合唯一键实现"上限可配"的并发安全',
        \`bound_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '本次绑定时间',
        \`unbound_at\` datetime(3) NULL COMMENT '解绑时间（未解绑为 NULL）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        \`active_boss_user_id\` bigint unsigned GENERATED ALWAYS AS (CASE WHEN \`status\` = 'active' THEN \`boss_user_id\` ELSE NULL END) STORED COMMENT '仅 active 行有值：唯一键只约束 active 行',
        \`active_worker_user_id\` bigint unsigned GENERATED ALWAYS AS (CASE WHEN \`status\` = 'active' THEN \`worker_user_id\` ELSE NULL END) STORED COMMENT '仅 active 行有值：唯一键只约束 active 行',
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_wib_active_boss_slot\` (\`active_boss_user_id\`, \`slot\`),
        UNIQUE KEY \`UK_wib_active_worker\` (\`active_worker_user_id\`),
        KEY \`IDX_wib_boss_status\` (\`boss_user_id\`, \`status\`),
        KEY \`IDX_wib_worker_status\` (\`worker_user_id\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='老板账号 ↔ 打手账号 绑定（合并双端·身份切换，方案甲）'
    `);

    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, JSON_OBJECT('value', ?), ?, 1)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [
        WORKER_BINDING_MAX_PER_BOSS_KEY,
        WORKER_BINDING_MAX_PER_BOSS_DEFAULT,
        WORKER_BINDING_MAX_PER_BOSS_DESCRIPTION,
      ],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`worker_identity_binding\``);
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [
      WORKER_BINDING_MAX_PER_BOSS_KEY,
    ]);
  }
}
