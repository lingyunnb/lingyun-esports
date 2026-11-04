import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * AI 咨询「会话轮换」（session rotation）—— 负责人 2026-10-04：
 * 「用户退出祁小山之后应自动初始化，用户再次进入不要显示之前的对话」
 *
 * **不删历史**：管理端质检要按会话回看全部问答（`GET /admin/ai/conversations|messages` 只读），
 * 所以旧数据一行都不动，只在「每用户一条长期会话」上轮换 `current_session`：
 * 用户侧读写只看 `current_session` → 重进即空会话；喂模型的多轮历史也按 session 截断 → 上下文天然隔离。
 *
 * 1) `ai_conversation.current_session` varchar(36) NOT NULL：当前 session（UUID）。
 *    老行回填：`UPDATE ... SET current_session = UUID()`（MySQL 逐行求值 → 每行一个不同 uuid）。
 *    列默认值用表达式 `(UUID())`（MySQL 8.0.13+ 支持）作为兜底；应用层始终显式写入。
 * 2) `ai_message.session_id` varchar(36) NOT NULL：本行归属的 session。
 *    老行回填其会话当时的 `current_session`（会话行缺失的孤儿行用 `UUID()` 兜底，保证 NOT NULL）。
 * 3) 新索引 `IDX_ai_msg_conv_session_seq (conversation_id, session_id, seq)`：
 *    用户侧「当前 session 倒序补拉」与「喂模型最近 3 轮」两条查询都走它。
 *    既有 `IDX_ai_msg_conv_seq (conversation_id, seq)` 保留（管理端跨 session 按 seq 排序仍用它）。
 *
 * 幂等：每一步先查 `information_schema`，条件不满足才执行 —— 重复执行不报错，可分步续跑。
 * 回滚：只删本次新增的列与索引，不动任何既有列与数据。
 */
export class AiSession1790002000000 implements MigrationInterface {
  name = 'AiSession1790002000000';

  private static readonly CONV_COMMENT = '当前 session（UUID；用户离开会话页即轮换，旧数据保留）';
  private static readonly MSG_COMMENT = '归属 session（UUID，与 ai_conversation.current_session 对应）';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- ① ai_conversation.current_session ----------
    if (!(await this.hasColumn(queryRunner, 'ai_conversation', 'current_session'))) {
      await queryRunner.query(
        `ALTER TABLE \`ai_conversation\`
           ADD COLUMN \`current_session\` varchar(36) NULL COMMENT '${AiSession1790002000000.CONV_COMMENT}'
           AFTER \`user_id\``,
      );
    }
    // 老行回填（每行一个不同 uuid）；重复执行时已被下方收紧为 NOT NULL，这里自然 0 行
    await queryRunner.query(
      `UPDATE \`ai_conversation\` SET \`current_session\` = UUID()
       WHERE \`current_session\` IS NULL OR \`current_session\` = ''`,
    );
    const convCol = await this.columnMeta(queryRunner, 'ai_conversation', 'current_session');
    if (convCol?.IS_NULLABLE === 'YES' || !convCol?.COLUMN_DEFAULT) {
      await queryRunner.query(
        `ALTER TABLE \`ai_conversation\`
           MODIFY COLUMN \`current_session\` varchar(36) NOT NULL DEFAULT (UUID())
           COMMENT '${AiSession1790002000000.CONV_COMMENT}'`,
      );
    }

    // ---------- ② ai_message.session_id ----------
    if (!(await this.hasColumn(queryRunner, 'ai_message', 'session_id'))) {
      await queryRunner.query(
        `ALTER TABLE \`ai_message\`
           ADD COLUMN \`session_id\` varchar(36) NULL COMMENT '${AiSession1790002000000.MSG_COMMENT}'
           AFTER \`conversation_id\``,
      );
    }
    // 老行回填：跟随其会话当前的 session（孤儿行用 UUID() 兜底，保证 NOT NULL 可加）
    await queryRunner.query(
      `UPDATE \`ai_message\` m
         LEFT JOIN \`ai_conversation\` c ON c.id = m.conversation_id
         SET m.\`session_id\` = COALESCE(NULLIF(c.\`current_session\`, ''), UUID())
       WHERE m.\`session_id\` IS NULL OR m.\`session_id\` = ''`,
    );
    const msgCol = await this.columnMeta(queryRunner, 'ai_message', 'session_id');
    if (msgCol?.IS_NULLABLE === 'YES') {
      await queryRunner.query(
        `ALTER TABLE \`ai_message\`
           MODIFY COLUMN \`session_id\` varchar(36) NOT NULL COMMENT '${AiSession1790002000000.MSG_COMMENT}'`,
      );
    }

    // ---------- ③ 索引 (conversation_id, session_id, seq) ----------
    if (!(await this.hasIndex(queryRunner, 'ai_message', 'IDX_ai_msg_conv_session_seq'))) {
      await queryRunner.query(
        `ALTER TABLE \`ai_message\` ADD KEY \`IDX_ai_msg_conv_session_seq\` (\`conversation_id\`, \`session_id\`, \`seq\`)`,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    if (await this.hasIndex(queryRunner, 'ai_message', 'IDX_ai_msg_conv_session_seq')) {
      await queryRunner.query(`ALTER TABLE \`ai_message\` DROP KEY \`IDX_ai_msg_conv_session_seq\``);
    }
    if (await this.hasColumn(queryRunner, 'ai_message', 'session_id')) {
      await queryRunner.query(`ALTER TABLE \`ai_message\` DROP COLUMN \`session_id\``);
    }
    if (await this.hasColumn(queryRunner, 'ai_conversation', 'current_session')) {
      await queryRunner.query(`ALTER TABLE \`ai_conversation\` DROP COLUMN \`current_session\``);
    }
  }

  private async hasColumn(queryRunner: QueryRunner, table: string, column: string): Promise<boolean> {
    const rows: Array<{ cnt: number | string }> = await queryRunner.query(
      `SELECT COUNT(*) AS cnt FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?`,
      [table, column],
    );
    return Number(rows?.[0]?.cnt ?? 0) > 0;
  }

  private async columnMeta(
    queryRunner: QueryRunner,
    table: string,
    column: string,
  ): Promise<{ IS_NULLABLE: string; COLUMN_DEFAULT: string | null } | undefined> {
    const rows: Array<{ IS_NULLABLE: string; COLUMN_DEFAULT: string | null }> = await queryRunner.query(
      `SELECT IS_NULLABLE, COLUMN_DEFAULT FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?`,
      [table, column],
    );
    return rows?.[0];
  }

  private async hasIndex(queryRunner: QueryRunner, table: string, index: string): Promise<boolean> {
    const rows: Array<{ cnt: number | string }> = await queryRunner.query(
      `SELECT COUNT(*) AS cnt FROM information_schema.statistics
       WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?`,
      [table, index],
    );
    return Number(rows?.[0]?.cnt ?? 0) > 0;
  }
}
