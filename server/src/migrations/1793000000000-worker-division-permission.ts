import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 打手 × 分部 接单权限（负责人 2026-10-04：接单要分「和平 / 三角洲手游 / 三角洲端游」）。
 *
 * 背景：此前 `worker.can_take_order` 是**全局**开关 —— 授了权的打手可以抢任何分部的单，
 * 老板指定护航员时也能看到别的分部的人。本次把接单权限**下沉到分部维度**。
 *
 * - 新表 `worker_division_permission(worker_id, division_id, can_take_order, created_at, updated_at)`，
 *   唯一键 `(worker_id, division_id)`；`can_take_order=0` 的行保留（撤销留痕/后续可再授予），
 *   查询一律带 `can_take_order = 1`。
 * - 索引 `IDX_wdp_division_take(division_id, can_take_order)`：大厅/指定护航员/公开找陪玩
 *   都按「某分部有哪些有权限的打手」查（EXISTS 子查询命中该索引）。
 * - **兼容回填**（不让存量打手突然接不到单）：`worker.can_take_order = 1` 的打手，
 *   回填为**当前全部启用分部（division.status = 1）均可接单**；`can_take_order = 0` 的不回填。
 *   `worker.can_take_order` 保留为「是否有任一接单权限」的派生/汇总，写入时同步维护。
 * - 幂等：`CREATE TABLE IF NOT EXISTS` + `INSERT IGNORE`（唯一键去重），可重复执行不报错、不覆盖已授权。
 * - 回滚：仅删表（worker.can_take_order 汇总列保持原样，回滚后回到旧的全局语义）。
 */
export class WorkerDivisionPermission1793000000000 implements MigrationInterface {
  name = 'WorkerDivisionPermission1793000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`worker_division_permission\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`worker_id\` bigint unsigned NOT NULL COMMENT '打手档案 id（worker.id）',
        \`division_id\` bigint unsigned NOT NULL COMMENT '分部 id（division.id）',
        \`can_take_order\` tinyint NOT NULL DEFAULT 1 COMMENT '该分部的接单权限 1 有 / 0 无（撤销留痕，查询恒带 =1）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_wdp_worker_division\` (\`worker_id\`, \`division_id\`),
        KEY \`IDX_wdp_division_take\` (\`division_id\`, \`can_take_order\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='打手 × 分部接单权限'
    `);

    // 回填：既有全局接单权限 → 当前全部启用分部（INSERT IGNORE 幂等，重复执行不会覆盖已改动的授权）
    await queryRunner.query(`
      INSERT IGNORE INTO \`worker_division_permission\` (\`worker_id\`, \`division_id\`, \`can_take_order\`)
      SELECT w.\`id\`, d.\`id\`, 1
      FROM \`worker\` w
      CROSS JOIN \`division\` d
      WHERE w.\`can_take_order\` = 1 AND d.\`status\` = 1
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS \`worker_division_permission\``);
  }
}
