import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 榜单唯一键纳入分部（负责人 2026-10-04 修复）
 *
 * 问题：`leaderboard_entry` 原唯一键为 (period, worker_id)，而分部榜需要同一 worker 在同一周期
 * 同时存在「全站行（division_id IS NULL）」与「分部行（division_id = 1/2/3）」，
 * 因此 recalc 写入时报 `Duplicate entry '2026-W40-47' for key 'UQ_board_period_worker'`（接口 500）。
 *
 * 修复：唯一键改为 (period, worker_id, division_id)。
 * MySQL 唯一索引中 NULL 互不相等，因此「同一周期同一 worker 的全站行」仍只允许一条，
 * 与各分部行互不冲突（recalc 本来就先按周期整表删除再写入，天然幂等）。
 */
export class LeaderboardDivisionKey1789982000000 implements MigrationInterface {
  name = 'LeaderboardDivisionKey1789982000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const idx: Array<{ INDEX_NAME: string }> = await queryRunner.query(
      `SELECT INDEX_NAME FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'leaderboard_entry'
         AND INDEX_NAME = 'UQ_board_period_worker'`,
    );
    // 若唯一键已含 division_id 则跳过（幂等）
    const cols: Array<{ COLUMN_NAME: string }> = await queryRunner.query(
      `SELECT COLUMN_NAME FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'leaderboard_entry'
         AND INDEX_NAME = 'UQ_board_period_worker' ORDER BY SEQ_IN_INDEX`,
    );
    const hasDivision = cols.some((c) => c.COLUMN_NAME === 'division_id');
    if (idx.length > 0 && !hasDivision) {
      await queryRunner.query(`ALTER TABLE \`leaderboard_entry\` DROP INDEX \`UQ_board_period_worker\``);
    }
    const exists: Array<{ INDEX_NAME: string }> = await queryRunner.query(
      `SELECT INDEX_NAME FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'leaderboard_entry'
         AND INDEX_NAME = 'UQ_board_period_worker_division'`,
    );
    if (exists.length === 0) {
      await queryRunner.query(
        `ALTER TABLE \`leaderboard_entry\`
         ADD UNIQUE KEY \`UQ_board_period_worker_division\` (\`period\`, \`worker_id\`, \`division_id\`)`,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`leaderboard_entry\` DROP INDEX \`UQ_board_period_worker_division\``);
    await queryRunner.query(
      `ALTER TABLE \`leaderboard_entry\` ADD UNIQUE KEY \`UQ_board_period_worker\` (\`period\`, \`worker_id\`)`,
    );
  }
}
