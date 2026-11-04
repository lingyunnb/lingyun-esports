import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 分部「建设中」态 + 招人文案 + 两个新分部（负责人 2026-10-05）
 *
 * 需求原文：
 * > 增加**瓦端（无畏契约端游）**和**瓦手（无畏契约手游）**，但是用户点开先显示
 * > **该分部正在建设中，敬请期待**；本分部大力招人，有意联系本人 **q：3989032755**
 *
 * 本迁移做三件事：
 *
 * 1) `division` 加两列（**幂等**：先查 information_schema 再 ALTER）
 *    - `under_construction` tinyint NOT NULL DEFAULT 0：1 = 建设中（客户端分部卡显示细描边「建设中」小片、
 *      点击进「建设中」页而不是商品列表）；0 = 正常分部。**默认 0** → 既有 3 个分部行为零变化。
 *    - `notice_text` varchar(255) NULL：建设中页展示的提示文案（**服务端下发，客户端零硬编码**；
 *      可含换行与 QQ 号）。
 *
 *    为什么加独立列、不复用通用 JSON 字段：
 *    - `division` 表**没有** `config_json`（只有 `game` 有），要复用就必须先新增一个 json 列 —— 同样是 DDL，
 *      换来的是「热门公开接口每次请求都要解包 JSON、无法建索引、管理端表单要自己序列化多行文本」；
 *    - `under_construction` 是**布尔判定**（客户端据此决定进哪个页面），独立 tinyint 语义自解释、
 *      将来要参与筛选/排序也能直接建索引；
 *    - `notice_text` 是用户可见文案（含换行），独立 varchar 让管理端表单直接绑定纯文本，最不易被误转义。
 *
 * 2) 新建 2 个游戏 + 2 个分部（按 code 幂等：**已存在则跳过**，绝不覆盖管理员后来的改动）
 *    - 游戏 `无畏契约（端游）` → 分部 `valorant_pc`（platform=pc），under_construction=1
 *    - 游戏 `无畏契约（手游）` → 分部 `valorant_mobile`（platform=mobile），under_construction=1
 *    - 展示名取舍：负责人内部叫「瓦端 / 瓦手」，但**用户可见处一律用完整名**（`无畏契约 · 端游` /
 *      `无畏契约 · 手游`），分部卡主标题用「无畏契约」+ 平台标签「端游 / 手游」，与既有分部
 *      （三角洲行动 · 手游 / · 端游）同一套命名结构；管理端可随时改名（含改成「瓦端/瓦手」）。
 *    - **不建分类、不建商品**（分部暂时是空的，等上架商品后再把 under_construction 改成 0 即恢复常态）。
 *    - 排序 40 / 50：排在既有 3 个分部之后，**不动既有分部的任何数据**。
 *
 * 3) 文案写入 `notice_text`（两个分部同一份原文，保留 QQ 号）：
 *    `本分部正在建设中，敬请期待。\n本分部大力招人，有意者请联系本人 QQ：3989032755`
 *
 * 回滚：删两个分部（仅当无商品/订单挂载）+ 删两个游戏（仅当无引用）+ 删两列。
 */
export class DivisionUnderConstruction1794000000000 implements MigrationInterface {
  name = 'DivisionUnderConstruction1794000000000';

  /** 建设中页文案（保留换行；两个分部同一份） */
  private static readonly NOTICE = [
    '本分部正在建设中，敬请期待。',
    '本分部大力招人，有意者请联系本人 QQ：3989032755',
  ].join('\n');

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- 1. 两列（幂等） ----------
    const hasColumn = async (table: string, column: string): Promise<boolean> => {
      const [row] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?`,
        [table, column],
      );
      return Number(row.c) > 0;
    };

    if (!(await hasColumn('division', 'under_construction'))) {
      await queryRunner.query(
        `ALTER TABLE \`division\`
           ADD COLUMN \`under_construction\` tinyint NOT NULL DEFAULT 0
           COMMENT '1 建设中（客户端显示建设中标识并进建设中页）/ 0 正常' AFTER \`status\``,
      );
    }
    if (!(await hasColumn('division', 'notice_text'))) {
      await queryRunner.query(
        `ALTER TABLE \`division\`
           ADD COLUMN \`notice_text\` varchar(255) NULL
           COMMENT '建设中页提示文案（服务端下发，可含换行/QQ 号）' AFTER \`under_construction\``,
      );
    }

    // ---------- 2. 游戏（按 code 幂等） ----------
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

    const valorantPcGameId = await ensureGame('valorant_pc', '无畏契约（端游）', 40);
    const valorantMobileGameId = await ensureGame('valorant_mobile', '无畏契约（手游）', 50);

    // ---------- 3. 分部（按 code 幂等：已存在则**整条跳过**，不覆盖管理端改动） ----------
    const ensureDivision = async (row: {
      gameId: string;
      platform: string;
      code: string;
      name: string;
      shortName: string;
      platformLabel: string;
      onlineDesc: string;
      themeColor: string;
      sortOrder: number;
    }): Promise<void> => {
      const exists = await queryRunner.query(`SELECT id FROM division WHERE code = ? LIMIT 1`, [row.code]);
      if (exists.length) return; // 幂等：已存在则跳过（可能已被管理端改名/改文案/上架商品）
      await queryRunner.query(
        `INSERT INTO division
           (game_id, platform, code, name, short_name, platform_label, online_desc, price_note,
            theme_color, sub_title, sort_order, status, under_construction, notice_text, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, '', ?, 1, 1, ?, NOW(3), NOW(3))`,
        [
          row.gameId,
          row.platform,
          row.code,
          row.name,
          row.shortName,
          row.platformLabel,
          row.onlineDesc,
          row.themeColor,
          row.sortOrder,
          DivisionUnderConstruction1794000000000.NOTICE,
        ],
      );
    };

    // 瓦端（无畏契约端游）：实色红，与既有 绿/蓝/紫 三个分部可区分
    await ensureDivision({
      gameId: valorantPcGameId,
      platform: 'pc',
      code: 'valorant_pc',
      name: '无畏契约 · 端游',
      shortName: '无畏契约',
      platformLabel: '端游',
      onlineDesc: '招募中',
      themeColor: '#DC2626',
      sortOrder: 40,
    });
    // 瓦手（无畏契约手游）：实色深青
    await ensureDivision({
      gameId: valorantMobileGameId,
      platform: 'mobile',
      code: 'valorant_mobile',
      name: '无畏契约 · 手游',
      shortName: '无畏契约',
      platformLabel: '手游',
      onlineDesc: '招募中',
      themeColor: '#0D9488',
      sortOrder: 50,
    });
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const codes = ['valorant_pc', 'valorant_mobile'];
    for (const code of codes) {
      const rows = await queryRunner.query(`SELECT id FROM division WHERE code = ? LIMIT 1`, [code]);
      if (!rows.length) continue;
      const id = String(rows[0].id);
      // 有商品/订单挂载就不删（与「删除分部」接口同一保护口径），避免留下悬空引用
      const [productUsed] = await queryRunner.query(`SELECT COUNT(*) AS c FROM product WHERE division_id = ?`, [id]);
      const [orderUsed] = await queryRunner.query(`SELECT COUNT(*) AS c FROM \`order\` WHERE division_id = ?`, [id]);
      if (Number(productUsed.c) > 0 || Number(orderUsed.c) > 0) continue;
      await queryRunner.query(`DELETE FROM division WHERE id = ?`, [id]);
    }
    for (const code of ['valorant_pc', 'valorant_mobile']) {
      const rows = await queryRunner.query(`SELECT id FROM game WHERE code = ? LIMIT 1`, [code]);
      if (!rows.length) continue;
      const id = String(rows[0].id);
      const [gameUsed] = await queryRunner.query(`SELECT COUNT(*) AS c FROM division WHERE game_id = ?`, [id]);
      const [productUsed] = await queryRunner.query(`SELECT COUNT(*) AS c FROM product WHERE game_id = ?`, [id]);
      if (Number(gameUsed.c) > 0 || Number(productUsed.c) > 0) continue;
      await queryRunner.query(`DELETE FROM game WHERE id = ?`, [id]);
    }
    for (const column of ['notice_text', 'under_construction']) {
      const [exists] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'division' AND COLUMN_NAME = ?`,
        [column],
      );
      if (Number(exists.c) > 0) await queryRunner.query(`ALTER TABLE \`division\` DROP COLUMN \`${column}\``);
    }
  }
}
