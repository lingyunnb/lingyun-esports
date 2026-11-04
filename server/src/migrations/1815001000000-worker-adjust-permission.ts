import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 展示值调整 · **一个窄权限点** `worker:adjust`（负责人 2026-10-16 定案）。
 *
 * ## 覆盖哪些接口
 *
 * - `PUT /admin/workers/:id/display-stats`（设置接单次数/好评率的**展示值**，`null` = 恢复跟随真实）
 * - `GET  /admin/workers/:id/stats`（同时看真实值 / 展示值 / 最终生效值）
 *
 * 读写**共用这一个点**，与 `review:moderate` 完全同口径：「看当前是什么」与「改它」是同一个人
 * 在同一张卡片上的连贯动作；再拆一个只读点，只会产出"能看到但与真实值不符却点不动修复"的空壳授权。
 *
 * ## 为什么是窄权限点，不复用 `admin:*` 大权限
 *
 * 负责人原文：**只授予 super_admin，与 `review:moderate` / `withdraw:pay` 同口径，
 * 不复用任何 `admin:*` 大权限。** 理由与充值/提现/评价那三处一致：
 * `admin:worker:write` 会连带给出"建工作端账号 / 改真实姓名电话 / 改陪玩资料"一族能力，
 * 而"调展示值"只需要改两个**对外展示**的数字。一个窄点让该职责**可被独立授予、独立收回**。
 *
 * ⚠️ 语义提醒（写给后来人）：本点是"调展示值"，**不是**"改真实战绩"。
 * 真实值（`worker_stats.completed_orders` / `order_review`）在任何路径下都不可被本点改写，
 * 评价原文的可见性治理仍只走 `review:moderate`。
 *
 * ## 授予范围（刻意保守）
 *
 * - `super_admin`：**授予**（幂等保证不因"清库重来"而缺失）；
 * - 其它既有角色（运营管理员等）：**一律不授予**（与 `recharge:*` / `withdraw:*` / `review:moderate` 同口径）。
 *   需要时由超管在「角色权限」页显式勾选。
 *
 * 权限点全量清单同时登记在 `modules/rbac/permissions.const.ts` —— 启动种子
 * （`SeedService.onApplicationBootstrap`）会把 `PERMISSIONS` 幂等补种并授予 `super_admin`；
 * 本迁移保证**不重启也生效**。两条路径都是幂等 INSERT，不冲突、不会重复授权。
 *
 * ## 幂等与回滚
 *
 * `INSERT … ON DUPLICATE KEY UPDATE` + `INSERT IGNORE` → 重复执行不报错、不重复授权。
 * 回滚只删这个权限点及其授权行（**不动**任何角色定义、不动其它权限点的授予关系）。
 */
export class WorkerAdjustPermission1815001000000 implements MigrationInterface {
  name = 'WorkerAdjustPermission1815001000000';

  /** 唯一的窄权限点（group_name 统一为「工作端」，管理端角色页按组展示） */
  private readonly code = 'worker:adjust';
  private readonly permName = '展示值调整（接单次数/好评率）';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `INSERT INTO \`permission\` (\`code\`, \`name\`, \`group_name\`, \`created_at\`)
       VALUES (?, ?, '工作端', NOW(3))
       ON DUPLICATE KEY UPDATE \`name\` = VALUES(\`name\`), \`group_name\` = VALUES(\`group_name\`)`,
      [this.code, this.permName],
    );

    // 只给 super_admin（幂等；其它角色一个都不给 —— 见文件头"授予范围"）
    await queryRunner.query(
      `INSERT IGNORE INTO \`admin_role_permission\` (\`role_id\`, \`permission_id\`, \`created_at\`)
       SELECT r.id, p.id, NOW(3)
       FROM \`admin_role\` r CROSS JOIN \`permission\` p
       WHERE r.code = 'super_admin' AND p.code = ?`,
      [this.code],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `DELETE FROM \`admin_role_permission\` WHERE \`permission_id\` IN
         (SELECT id FROM \`permission\` WHERE code = ?)`,
      [this.code],
    );
    await queryRunner.query('DELETE FROM `permission` WHERE code = ?', [this.code]);
  }
}
