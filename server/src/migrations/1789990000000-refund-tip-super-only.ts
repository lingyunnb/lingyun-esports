import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 权限收口（负责人 2026-10-04）：退款审批 / 打赏配置 改为「超级管理员 + 所有者」独占
 *
 * 背景：1789986000000-tip-refund-complaint 按「与既有 club 权限同策略」把
 *   `admin:tip:*` / `admin:refund:*` / `admin:complaint:*` 六个权限点授予了**所有既有管理角色**
 *   （含「运营管理员」operator）。负责人要求把两个**写操作**收回：
 *     - 收回：`admin:refund:handle`（退款审批）、`admin:tip:config`（打赏金额配置）
 *     - 保留：`admin:refund:read` / `admin:tip:read`（普通运营「能看不能批」）
 *     - 不动：`admin:complaint:*`（本次不在要求范围内，投诉处理维持原策略）
 *
 * 为什么是 migration，而不是只改权限种子：
 *   启动种子（`modules/auth/seed.service.ts`）只做两件事 —— ① 把 PERMISSIONS 常量
 *   INSERT IGNORE 进 `permission` 表；② 把**全部**权限点 INSERT IGNORE 给 `super_admin` 角色。
 *   它**从不下发、也从不回收**其它角色的授权，所以「改种子」在已经跑过 1789986000000 的库上
 *   收不回任何已发出的授权 —— 必须落一条 migration 直接清理 `admin_role_permission`。
 *   本 migration 同时幂等保证 `super_admin` 持有这两点（与启动种子同策略）；重启不会把授权加回去。
 *   两条路都说明：种子负责「权限点清单 + 超管全量」，migration 负责「角色授权收口」。
 *
 * 所有者（`admin.is_owner = 1`）：守卫 `common/guards/permissions.guard.ts` 对这两个权限点
 *   额外放行（所有者与超管同权），与 docs/04「所有者独占」的既有做法一致。
 */
export class RefundTipSuperOnly1789990000000 implements MigrationInterface {
  name = 'RefundTipSuperOnly1789990000000';

  /** 收口为「超管 + 所有者」独占的权限点（与 permissions.const.ts 的 SUPER_ONLY_PERMISSIONS 一致） */
  private readonly locked: string[] = ['admin:refund:handle', 'admin:tip:config'];

  public async up(queryRunner: QueryRunner): Promise<void> {
    // 1) 从全部「非 super_admin」角色收回这两个权限点的授权（运营管理员/工作端管理员等）
    for (const code of this.locked) {
      await queryRunner.query(
        `DELETE arp FROM admin_role_permission arp
           JOIN permission p ON p.id = arp.permission_id
           JOIN admin_role r ON r.id = arp.role_id
          WHERE p.code = ? AND r.code <> 'super_admin'`,
        [code],
      );
    }
    // 2) 幂等确保 super_admin 角色持有（与启动种子同策略；已存在则不动）
    await queryRunner.query(
      `INSERT IGNORE INTO admin_role_permission (role_id, permission_id, created_at)
       SELECT r.id, p.id, NOW(3) FROM admin_role r CROSS JOIN permission p
        WHERE r.code = 'super_admin' AND p.code IN (?, ?)`,
      this.locked,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // 回到 1789986000000 的初始策略：既有管理角色全部授予（仅回滚授权，不动权限点本身）
    await queryRunner.query(
      `INSERT IGNORE INTO admin_role_permission (role_id, permission_id, created_at)
       SELECT r.id, p.id, NOW(3) FROM admin_role r CROSS JOIN permission p
        WHERE p.code IN (?, ?)`,
      this.locked,
    );
  }
}
