import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 评价体系地基 3/3：**一个窄权限点** `review:moderate`（负责人 2026-10-15 定案）。
 *
 * ## 为什么是窄权限点，而不是复用 `admin:*` 大权限
 *
 * 负责人原文：**只授予 super_admin，与 `recharge:review` / `withdraw:review` 同口径；
 * 不复用任何 `admin:*` 大权限。** 理由与充值/提现那两处完全一致：
 * `admin:order:read` / `admin:complaint:handle` 这类大权限一旦授予，就同时给出
 * 订单页/投诉页/用户页一族能力 —— 而"评价治理"只需要**看评价列表 + 隐藏/恢复**这两件事。
 * 一个窄点让该职责**可被独立授予、独立收回**。
 *
 * 本点同时覆盖**读与写**（列表 `GET /admin/reviews` 与隐藏/恢复 `POST /admin/reviews/:id/{hide,show}`）：
 * 评价原文是**用户生成内容**，隐藏/恢复是"改内容可见性"的治理动作，
 * 两者是同一个人在同一张列表上完成的连贯动作；把"看"再拆出一个点，只会让
 * "能看到评价但点不动隐藏"变成一个需要额外授权的空壳形态。
 *
 * ## 授予范围（刻意保守）
 *
 * - `super_admin`：**授予**（超管本就拥有全部权限，这里幂等保证不因"清库重来"而缺失）；
 * - 其它既有角色（运营管理员等）：**一律不授予**（与 `recharge:*` / `withdraw:*` 同口径）。
 *   需要时由超管在「角色权限」页显式勾选。
 *
 * 权限点全量清单同时登记在 `modules/rbac/permissions.const.ts` —— 启动种子
 * （`SeedService.onApplicationBootstrap`）会把 `PERMISSIONS` 幂等补种，并把新点授予 `super_admin`；
 * 本迁移保证**不重启也生效**。两条路径都是 INSERT 幂等，不冲突、不会重复授权。
 *
 * ## 幂等与回滚
 *
 * `INSERT ... ON DUPLICATE KEY UPDATE` + `INSERT IGNORE` → 重复执行不报错、不重复授权。
 * 回滚只删这个权限点及其授权行（**不动**任何角色定义、不动其它权限点的授予关系）。
 */
export class ReviewModeratePermission1814000000000 implements MigrationInterface {
  name = 'ReviewModeratePermission1814000000000';

  /** 唯一的窄权限点（group_name 统一为「评价」，管理端角色页按组展示） */
  private readonly code = 'review:moderate';
  private readonly permName = '评价治理（查看/隐藏/恢复）';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `INSERT INTO \`permission\` (\`code\`, \`name\`, \`group_name\`, \`created_at\`)
       VALUES (?, ?, '评价', NOW(3))
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
