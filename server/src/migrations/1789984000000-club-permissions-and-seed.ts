import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 官方馆权限 + 初始数据（负责人 2026-10-04）
 *
 * 1) 注册管理端权限 admin:club:read|write|delete 并授予既有管理角色
 * 2) 把首页原先客户端写死的两张「祁连山电竞 · XX分部」卡片落库为可维护数据
 *    （评分/单量取管理端可改的真实初始值；封面图留空 → 客户端用渐变色块兜底，管理端上传后即替换）
 */
export class ClubPermissionsAndSeed1789984000000 implements MigrationInterface {
  name = 'ClubPermissionsAndSeed1789984000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const perms: [string, string][] = [
      ['admin:club:read', '官方馆查看'],
      ['admin:club:write', '官方馆管理'],
      ['admin:club:delete', '官方馆删除'],
    ];
    for (const [code, name] of perms) {
      await queryRunner.query(
        `INSERT INTO permission (code, name, group_name, created_at) VALUES (?, ?, '官方馆管理', NOW(3))
         ON DUPLICATE KEY UPDATE name = VALUES(name), group_name = VALUES(group_name)`,
        [code, name],
      );
    }
    await queryRunner.query(`
      INSERT IGNORE INTO admin_role_permission (role_id, permission_id, created_at)
      SELECT r.id, p.id, NOW(3) FROM admin_role r CROSS JOIN permission p
      WHERE p.code LIKE 'admin:club:%'
    `);

    // 初始两张卡片（幂等：按 name 判重）
    const seeds: [string, string, string, string, number, number][] = [
      ['祁连山电竞 · 和平精英分部', '和平精英分部', '和平精英与三角洲行动全段位上分与护航，客服 9:00-次日 2:00 在线', '4.9', 2847, 10],
      ['祁连山电竞 · 三角洲行动分部', '三角洲行动分部', '烽火地带手游/端游双端护航，大红物资稳定，夜间也有人接单', '4.8', 1306, 20],
    ];
    for (const [name, subTitle, description, rating, orderCount, sortOrder] of seeds) {
      const rows = await queryRunner.query(`SELECT id FROM club WHERE name = ? LIMIT 1`, [name]);
      if (rows.length) continue;
      await queryRunner.query(
        `INSERT INTO club (name, sub_title, description, badge, rating, order_count, sort_order, status, created_at, updated_at)
         VALUES (?, ?, ?, '官方', ?, ?, ?, 1, NOW(3), NOW(3))`,
        [name, subTitle, description, rating, orderCount, sortOrder],
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM admin_role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code LIKE 'admin:club:%')`);
    await queryRunner.query(`DELETE FROM permission WHERE code LIKE 'admin:club:%'`);
  }
}
