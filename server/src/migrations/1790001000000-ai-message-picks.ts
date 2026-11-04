import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 找陪玩推荐落库（负责人 2026-10-04：AI 参与「找陪玩」）
 *
 * `POST /user/ai/recommend` 的问答复用既有 `ai_message`（user + assistant 两行，语义与客服问答完全一致），
 * 只加**一列**存"这次挑了谁"：
 *
 * - `picks_json` JSON NULL：数组，元素为 `{workerId,name,intro,divisionName,reason}`，
 *   即当时**已展示给用户**的快照（不含手机号/真实姓名/工号）；
 * - 普通 AI 问答该列为 NULL（不写、不影响既有读写路径）；
 * - 只加列、不改任何既有列与索引，对既有客服问答零影响（`synchronize` 关闭 → 必须走本 migration）。
 *
 * 幂等：先查 `information_schema.columns`，已存在则跳过（重复执行不报错）。
 */
export class AiMessagePicks1790001000000 implements MigrationInterface {
  name = 'AiMessagePicks1790001000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const rows: Array<{ cnt: number | string }> = await queryRunner.query(
      `SELECT COUNT(*) AS cnt FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = 'ai_message' AND column_name = 'picks_json'`,
    );
    if (Number(rows?.[0]?.cnt ?? 0) > 0) return;

    await queryRunner.query(`
      ALTER TABLE \`ai_message\`
        ADD COLUMN \`picks_json\` json DEFAULT NULL
        COMMENT '找陪玩推荐挑中的打手快照（JSON 数组；普通问答为 NULL）'
        AFTER \`reply_msg_id\`
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const rows: Array<{ cnt: number | string }> = await queryRunner.query(
      `SELECT COUNT(*) AS cnt FROM information_schema.columns
       WHERE table_schema = DATABASE() AND table_name = 'ai_message' AND column_name = 'picks_json'`,
    );
    if (Number(rows?.[0]?.cnt ?? 0) === 0) return;
    await queryRunner.query(`ALTER TABLE \`ai_message\` DROP COLUMN \`picks_json\``);
  }
}
