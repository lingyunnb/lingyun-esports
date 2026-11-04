import { MigrationInterface, QueryRunner } from 'typeorm';

import {
  CS_HALL_RELEASE_DEFAULT,
  CS_HALL_RELEASE_DESCRIPTION,
  CS_HALL_RELEASE_KEY,
} from '../modules/chat/cs-hall';

/**
 * 客服大厅（有客服权限的打手主动接咨询）1/1：**数据库层的"同时只能一个客服接入"硬约束** +
 * 「退回池子」开关配置行。负责人 2026-10-08 定案（抢占式 + 管理端改派兜底）。
 *
 * ---------------------------------------------------------------------------
 * 1) 为什么在 `chat_conversation_assign` 上加「生成列 + 唯一键」而不是只靠服务层判断
 *
 * 需求是「同一会话**同时只能被一个客服接入**」。`chat_conversation_assign` 原本只有两个**普通**索引
 * （`IDX_assign_worker_status` / `IDX_assign_conv`），也就是说"同一会话 + active"在库里**没有唯一性**：
 * 两个请求只要都过了服务层的"查一下有没有 active"检查，就能各插一行 → 一个会话两个客服同时在线。
 *
 * 服务层的 `SELECT ... FOR UPDATE`（会话行锁）+ 复核能挡住"两个 claim 并发"，
 * 但挡不住**任何没走那把锁的写入路径**（管理端改派、将来的新接口、运维手工 SQL）。
 * 本项目的既有姿势（`worker_identity_binding`，CLAUDE.md 第 11 条）是：
 * **能用数据库约束表达的不变量，就不只写在服务层**。所以这里用同一套写法：
 *
 *   `active_conversation_id` = CASE WHEN status='active' THEN conversation_id ELSE NULL END  (STORED)
 *   UNIQUE KEY `UK_cca_active` (`active_conversation_id`)
 *
 * MySQL 唯一索引**忽略含 NULL 的键** → 只有 active 行参与唯一性：
 * - 一个会话最多一行 active（第二个客服的插入被数据库直接拒绝 `ER_DUP_ENTRY`）；
 * - `inactive`（管理端改派留下的历史行）/ `released`（客服退回池子）自动变 NULL → 历史行**无限保留**、可审计；
 * - 生成列**不在实体里映射**（与 `worker_identity_binding` 逐字同口径）→ 任何 `save()` 都不会碰到它。
 *
 * 幂等与预检：迁移前先查一遍"已经存在重复 active 行"的历史脏数据。真有的话 `ADD UNIQUE KEY` 会直接失败，
 * 而报错只有一句英文 → 这里先给出**中文可执行提示**（先清理再跑），而不是让人对着 `ER_DUP_ENTRY` 猜。
 * 结构变更全部按 `information_schema` 判存在，**可重复执行**。
 *
 * 2) 「退回池子」开关：`system_setting.cs_hall_release_enabled`
 * - 形状 `{"value": 1}`（与 `worker_binding_max_per_boss` / `chat_recall_seconds` 同一套 `cfg_value` 约定）；
 * - **默认 1 = 开放**（负责人尚未定案该功能，先实现 + 开关交付）；
 * - `is_high_security = 0` → 运营/管理员都能在管理端「系统设置」自助开关（这不是安全档配置）；
 * - 读侧 `SystemSettingService.value(key, 1)` **每次实时读库、无缓存** → 关掉下一次请求即 403 中文。
 *
 * 3) 回滚：删唯一键 + 生成列 + 该配置行；**不触碰任何既有指派数据**（`status` 一个字节不改）。
 */
export class CsHallClaim1807000000000 implements MigrationInterface {
  name = 'CsHallClaim1807000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---- 预检：历史脏数据（同一会话多行 active）会让唯一键建不上，先给中文可执行提示 ----
    const dup: Array<{ conversation_id: string; n: number | string }> = await queryRunner.query(
      `SELECT conversation_id, COUNT(*) AS n
         FROM chat_conversation_assign
        WHERE status = 'active'
        GROUP BY conversation_id
       HAVING n > 1`,
    );
    if (Array.isArray(dup) && dup.length) {
      const detail = dup.map((d) => `${d.conversation_id}(${d.n} 行)`).join('、');
      throw new Error(
        `客服指派表存在重复 active 行，无法建立唯一键 UK_cca_active：会话 ${detail}。` +
          `请先人工确认保留哪个客服（把其余行 UPDATE 成 'inactive'）后重跑 npm run migration:run`,
      );
    }

    // ---- ① 生成列（仅 active 行有值；不在实体里映射）----
    const col: unknown = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chat_conversation_assign'
          AND COLUMN_NAME = 'active_conversation_id'`,
    );
    if (Number(this.scalar(col)) === 0) {
      await queryRunner.query(
        `ALTER TABLE \`chat_conversation_assign\`
           ADD COLUMN \`active_conversation_id\` bigint unsigned
             GENERATED ALWAYS AS (CASE WHEN \`status\` = 'active' THEN \`conversation_id\` ELSE NULL END) STORED
             COMMENT '仅 active 行有值：唯一键只约束 active 行（同一会话同时只能一个客服接入）'`,
      );
    }

    // ---- ② 唯一键（一个会话最多一行 active）----
    const idx: unknown = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chat_conversation_assign'
          AND INDEX_NAME = 'UK_cca_active'`,
    );
    if (Number(this.scalar(idx)) === 0) {
      await queryRunner.query(
        `ALTER TABLE \`chat_conversation_assign\` ADD UNIQUE KEY \`UK_cca_active\` (\`active_conversation_id\`)`,
      );
    }

    // ---- ③ 「退回池子」开关（幂等：重复执行不冲掉运营已经改过的值）----
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, JSON_OBJECT('value', ?), ?, 0)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [CS_HALL_RELEASE_KEY, CS_HALL_RELEASE_DEFAULT, CS_HALL_RELEASE_DESCRIPTION],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const idx: unknown = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chat_conversation_assign'
          AND INDEX_NAME = 'UK_cca_active'`,
    );
    if (Number(this.scalar(idx)) > 0) {
      await queryRunner.query(`ALTER TABLE \`chat_conversation_assign\` DROP INDEX \`UK_cca_active\``);
    }
    const col: unknown = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chat_conversation_assign'
          AND COLUMN_NAME = 'active_conversation_id'`,
    );
    if (Number(this.scalar(col)) > 0) {
      await queryRunner.query(
        `ALTER TABLE \`chat_conversation_assign\` DROP COLUMN \`active_conversation_id\``,
      );
    }
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [
      CS_HALL_RELEASE_KEY,
    ]);
  }

  /**
   * 取 `SELECT COUNT(*) AS n` 的标量值。
   *
   * `queryRunner.query()` 的返回形状在 mysql2 驱动下是 `[rows, fields]`（TypeORM 不解包），
   * 直接 `rows[0].n` 会拿到 `undefined` → "判存在"恒为 false → 迁移静默不生效。
   * 这里做一次防御性解包（与 `RealtimeGateway.assertSessionActive` 里的解包同一种写法）。
   */
  private scalar(raw: unknown): number | string {
    const rows = (Array.isArray(raw) && Array.isArray(raw[0]) ? raw[0] : raw) as Array<{ n: number | string }>;
    return rows?.[0]?.n ?? 0;
  }
}
