import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 分部体系（负责人 2026-10-03 定案）
 *
 * 背景：俱乐部只有官方自营，按「游戏 + 平台」划分分部，共 3 个：
 *   和平精英 · 手游 / 三角洲行动 · 手游 / 三角洲行动 · 端游
 * 规则：**和平精英没有端游**，所以该游戏不出现平台筛选（platform_count=1 时客户端不显示筛选）。
 *
 * 本迁移做四件事：
 * 1) 建 `division` 表
 * 2) 给 product / `order` / worker / leaderboard_entry 加 `division_id`（可空，兼容存量数据）
 * 3) 幂等写入 3 个分部（按游戏 code 绑定，缺游戏则自动建）
 * 4) 注册管理端权限 `admin:division:*` 并授予非 owner 的管理角色
 */
export class CreateDivision1789980000000 implements MigrationInterface {
  name = 'CreateDivision1789980000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- 1. 分部表 ----------
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`division\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`game_id\` bigint unsigned NOT NULL,
        \`platform\` varchar(8) NOT NULL DEFAULT 'mobile' COMMENT 'mobile 手游 / pc 端游',
        \`code\` varchar(48) NOT NULL COMMENT '唯一标识，如 peace_mobile',
        \`name\` varchar(40) NOT NULL COMMENT '展示名，如 和平精英 · 手游',
        \`short_name\` varchar(24) NOT NULL DEFAULT '' COMMENT '分部卡主标题，如 和平精英',
        \`platform_label\` varchar(8) NOT NULL DEFAULT '' COMMENT '平台标签，如 手游/端游',
        \`online_desc\` varchar(64) NOT NULL DEFAULT '' COMMENT '首页在线说明，如 平均 3 分钟内接单',
        \`price_note\` varchar(64) NOT NULL DEFAULT '' COMMENT '价格说明（管理端可改）',
        \`theme_color\` varchar(16) NOT NULL DEFAULT '' COMMENT '主题色 #RRGGBB，空则按序取默认色',
        \`sort_order\` int NOT NULL DEFAULT 0,
        \`status\` tinyint NOT NULL DEFAULT 1 COMMENT '1 上架 / 2 下架',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_division_code\` (\`code\`),
        KEY \`IDX_division_status_sort\` (\`status\`, \`sort_order\`),
        KEY \`IDX_division_game_platform\` (\`game_id\`, \`platform\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // ---------- 2. 业务表挂分部 ----------
    const addColumn = async (table: string, after?: string) => {
      const [exists] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = 'division_id'`,
        [table],
      );
      if (Number(exists.c) > 0) return;
      await queryRunner.query(
        `ALTER TABLE \`${table}\` ADD COLUMN \`division_id\` bigint unsigned NULL${after ? ` AFTER \`${after}\`` : ''}`,
      );
      await queryRunner.query(`ALTER TABLE \`${table}\` ADD KEY \`IDX_${table}_division\` (\`division_id\`)`);
    };
    await addColumn('product', 'game_id');
    await addColumn('order', 'game_id');
    await addColumn('worker');
    await addColumn('leaderboard_entry');

    // ---------- 3. 种子分部（幂等：按 code 唯一） ----------
    // 3.1 确保两个游戏存在（和平精英原本没有；三角洲行动没有）
    const ensureGame = async (code: string, name: string, sortOrder: number): Promise<string> => {
      const rows = await queryRunner.query(`SELECT id FROM game WHERE code = ? LIMIT 1`, [code]);
      if (rows.length) return String(rows[0].id);
      await queryRunner.query(
        `INSERT INTO game (code, name, sort_order, status, created_at, updated_at)
         VALUES (?, ?, ?, 1, NOW(3), NOW(3))`,
        [code, name, sortOrder],
      );
      const [created] = await queryRunner.query(`SELECT id FROM game WHERE code = ? LIMIT 1`, [code]);
      return String(created.id);
    };
    const peaceGameId = await ensureGame('peace', '和平精英', 10);
    const deltaGameId = await ensureGame('delta', '三角洲行动', 20);

    // 3.2 三个分部（与设计稿一致：和平精英仅手游；三角洲 手游 + 端游）
    const divisions: [string, string, string, string, string, string, string, string, number][] = [
      [peaceGameId, 'mobile', 'peace_mobile', '和平精英 · 手游', '和平精英', '手游', '平均 3 分钟内接单', '#16A34A', 10],
      [deltaGameId, 'mobile', 'delta_mobile', '三角洲行动 · 手游', '三角洲行动', '手游', '平均 5 分钟内接单', '#2563EB', 20],
      [deltaGameId, 'pc', 'delta_pc', '三角洲行动 · 端游', '三角洲行动', '端游', '平均 6 分钟内接单', '#7C3AED', 30],
    ];
    for (const d of divisions) {
      await queryRunner.query(
        `INSERT INTO division
           (game_id, platform, code, name, short_name, platform_label, online_desc, theme_color, price_note, sort_order, status, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, '按局计费，下单后显示明细', ?, 1, NOW(3), NOW(3))
         ON DUPLICATE KEY UPDATE
           name = VALUES(name), short_name = VALUES(short_name), platform_label = VALUES(platform_label),
           online_desc = VALUES(online_desc), theme_color = VALUES(theme_color), sort_order = VALUES(sort_order)`,
        [...d.slice(0, 8), d[8]],
      );
    }

    // ---------- 4. 管理端权限（admin:division:*） ----------
    // 沿用既有命名规范：admin:<资源>:read|write|delete
    const perms: [string, string][] = [
      ['admin:division:read', '分部查看'],
      ['admin:division:write', '分部管理'],
      ['admin:division:delete', '分部删除'],
    ];
    for (const [code, name] of perms) {
      await queryRunner.query(
        `INSERT INTO permission (code, name, group_name, created_at) VALUES (?, ?, '分部管理', NOW(3))
         ON DUPLICATE KEY UPDATE name = VALUES(name), group_name = VALUES(group_name)`,
        [code, name],
      );
    }
    // 授予所有既有管理角色（超管在 admin.is_owner，天然不受角色限制）
    await queryRunner.query(`
      INSERT IGNORE INTO admin_role_permission (role_id, permission_id, created_at)
      SELECT r.id, p.id, NOW(3) FROM admin_role r CROSS JOIN permission p
      WHERE p.code LIKE 'admin:division:%'
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM admin_role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code LIKE 'admin:division:%')`);
    await queryRunner.query(`DELETE FROM permission WHERE code LIKE 'admin:division:%'`);
    for (const t of ['product', 'order', 'worker', 'leaderboard_entry']) {
      const [exists] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = 'division_id'`,
        [t],
      );
      if (Number(exists.c) > 0) await queryRunner.query(`ALTER TABLE \`${t}\` DROP COLUMN \`division_id\``);
    }
    await queryRunner.query(`DROP TABLE IF EXISTS \`division\``);
  }
}
