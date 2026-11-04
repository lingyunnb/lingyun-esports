import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 充值（线下收款 + 人工审核）地基 2/2：**两个专用窄权限点**。
 *
 * ## 为什么是 `recharge:review` / `recharge:grant`，而不是复用 `admin:*` 大权限
 *
 * 负责人定案原文：**不要**给受限充值管理员任何其它 admin 权限，**只加这两个权限点**。
 * 这是"最小权限"落到数据层：`admin:wallet:grant` 之类的大权限一旦授予，就同时给了
 * 管理端积分页/用户页/订单页等一族能力 —— 而受限会话只需要"看充值申请"和"发放/驳回充值申请"。
 * 两个窄点让"充值审核员"成为一个**可被独立授予、独立收回**的角色。
 *
 * 权限点全量清单同时登记在 `modules/rbac/permissions.const.ts`（启动种子 `SeedService` 幂等补种，
 * 与 `admin:club:*` / AI 权限同策略）——本迁移保证**不重启也生效**，两者不冲突（都是 INSERT 幂等）。
 *
 * ## 授予范围（刻意保守）
 *
 * - `super_admin`：**授予**（超管本就拥有全部权限，这里幂等保证不因"清库重来"而缺失）；
 * - 其它既有角色（运营管理员等）：**一律不授予**。这与 `admin:club:*`（全角色授予）相反，
 *   是刻意的 —— 充值审核涉及"手工发积分"，属于资金相邻操作，默认不给任何既有运营角色，
 *   需要时由超管在「角色权限」页显式勾选。
 * - 「受限充值管理员」的日常形态并不是这套 RBAC 角色，而是 `recharge_admin` 白名单 + `kind='recharge'`
 *   受限会话（白名单默认拒绝，只放行 `/recharge/*`）。
 *
 * ## 幂等与回滚
 *
 * `INSERT ... ON DUPLICATE KEY UPDATE` + `INSERT IGNORE` → 重复执行不报错、不重复授权。
 * 回滚只删这两个权限点及其授权行（**不动**任何角色定义、不动 `recharge_admin` 白名单）。
 */
export class RechargePermissions1805000000000 implements MigrationInterface {
  name = 'RechargePermissions1805000000000';

  /** 两个窄权限点（group_name 统一为「充值」，管理端角色页按组展示） */
  private readonly perms: Array<[string, string]> = [
    ['recharge:review', '充值申请查看'],
    ['recharge:grant', '充值申请发放/驳回'],
  ];

  public async up(queryRunner: QueryRunner): Promise<void> {
    for (const [code, name] of this.perms) {
      await queryRunner.query(
        `INSERT INTO \`permission\` (\`code\`, \`name\`, \`group_name\`, \`created_at\`)
         VALUES (?, ?, '充值', NOW(3))
         ON DUPLICATE KEY UPDATE \`name\` = VALUES(\`name\`), \`group_name\` = VALUES(\`group_name\`)`,
        [code, name],
      );
    }

    // 只给 super_admin（幂等；其它角色一个都不给 —— 见文件头"授予范围"）
    await queryRunner.query(
      `INSERT IGNORE INTO \`admin_role_permission\` (\`role_id\`, \`permission_id\`, \`created_at\`)
       SELECT r.id, p.id, NOW(3)
       FROM \`admin_role\` r CROSS JOIN \`permission\` p
       WHERE r.code = 'super_admin' AND p.code IN (?, ?)`,
      [this.perms[0][0], this.perms[1][0]],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `DELETE FROM \`admin_role_permission\` WHERE \`permission_id\` IN
         (SELECT id FROM \`permission\` WHERE code IN (?, ?))`,
      [this.perms[0][0], this.perms[1][0]],
    );
    await queryRunner.query(`DELETE FROM \`permission\` WHERE code IN (?, ?)`, [
      this.perms[0][0],
      this.perms[1][0],
    ]);
  }
}
