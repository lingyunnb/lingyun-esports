import { MigrationInterface, QueryRunner } from 'typeorm';

/** 排行榜与统计（M7）：worker_stats 实时统计 + leaderboard_entry 周期榜单快照 + leaderboard_adjustment 人工调整留痕 */
export class CreateLeaderboardTables1789921000000 implements MigrationInterface {
  name = 'CreateLeaderboardTables1789921000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`worker_stats\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`worker_id\` bigint unsigned NOT NULL,
        \`total_orders\` int NOT NULL DEFAULT 0,
        \`completed_orders\` int NOT NULL DEFAULT 0,
        \`total_amount\` int NOT NULL DEFAULT 0,
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_stats_worker\` (\`worker_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`leaderboard_entry\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`period\` varchar(16) NOT NULL,
        \`worker_id\` bigint unsigned NOT NULL,
        \`completed_orders\` int NOT NULL DEFAULT 0,
        \`total_amount\` int NOT NULL DEFAULT 0,
        \`rank\` int NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_board_period_worker\` (\`period\`, \`worker_id\`),
        KEY \`IDX_board_period_rank\` (\`period\`, \`rank\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
    await queryRunner.query(`
      CREATE TABLE \`leaderboard_adjustment\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`period\` varchar(16) NOT NULL,
        \`worker_id\` bigint unsigned NOT NULL,
        \`amount_delta\` int NOT NULL,
        \`reason\` varchar(255) NOT NULL DEFAULT '',
        \`admin_user_id\` bigint unsigned NOT NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_adj_period_worker\` (\`period\`, \`worker_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`leaderboard_adjustment\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`leaderboard_entry\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`worker_stats\``);
  }
}
