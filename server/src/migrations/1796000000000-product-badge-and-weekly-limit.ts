import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 商品「徽标文案」+「每周限购」两列 + 和平精英体验单置顶/徽标/限购数据（负责人 2026-10-05）
 *
 * 需求原文：
 * > 把**体验单放到最上面**并标注「**董事长推荐**」，这个单要**突出明显**，
 * > 并且**一个账号一周只能下 2 单**
 *
 * 目标商品：`9.9新人体验单保200w不卡保底`（和平精英 / division 1 / category 78 / 99 积分 / product id 137）
 *
 * ---------------------------------------------------------------------------
 * 1) `product.badge_text` varchar(32) NULL
 *    - 商品卡/详情页的**小徽标文案**（如「董事长推荐」「店长推荐」）。
 *    - **通用能力，不是给这一个商品写死的**：任何商品都能配，留空（NULL）= 不显示徽标，
 *      客户端只有一个判断「非空才渲染」，不需要为每个活动改代码。
 *    - 32 字上限：徽标是**左上角小片**（10px 字、6px 内边距），超过 32 字在 390pt 宽的手机上
 *      必然换行/溢出，用 DDL 长度把这个约束钉死（管理端表单同一上限，服务端 DTO 也校验）。
 *
 * 2) `product.weekly_limit` int NULL
 *    - **每个账号每周可下该商品的单数上限**（NULL / 0 = 不限）。
 *    - 判定在服务端下单事务内（`order.service.ts` 的 `assertWeeklyLimit`，位于扣款之前），
 *      客户端只展示服务端下发的提示与拦截文案（docs/04：客户端数据一律不可信）。
 *    - 用 int（而不是 tinyint）：将来若要放开到「每周 200 单」不必再改表结构；
 *      NULL 与 0 都表示不限（NULL = 从未配置，0 = 管理端显式填 0），语义在代码里统一按 `> 0` 判定。
 *
 * 3) 数据（**幂等 + 不覆盖管理员的后续修改**：只在当前值为 NULL 时写入）
 *    - 商品 137 → `badge_text = '董事长推荐'`、`weekly_limit = 2`
 *    - 置顶：商品 137 的 `sort_order = 0`，同一分部**其余商品**按它们当时的生效顺序
 *      （`sort_order ASC, id DESC`，与公开接口的 ORDER BY 完全一致）重排为 10 / 20 / 30 …
 *      ⚠️ 为什么不是把 137 设成负数：`UpdateProductDto`/`CreateProductDto` 的 sortOrder 是
 *      `@Min(0)`，负值会让「管理端点开该商品直接保存」被 400 拒绝（保存按钮永远失败）。
 *      因此改成「137 保持唯一的 0（最小且不与他人冲突）+ 其余商品上移到 10 起」——
 *      置顶效果相同，且每个商品都能在管理端正常编辑；其余商品的**相对顺序一个都没变**。
 *      只重排「同一分部内 sort_order <= 0 且非 137」的商品，原本已排过序的商品不会被挤动。
 *
 * **幂等**：两列都先查 information_schema，存在则跳过；数据只在 NULL 时写、排序只在需要时改。
 * **回滚**：删两列（列上数据一并丢弃）+ 把该分部 sort_order 归 0（迁移前的原值），
 *   不改动任何其它列、不删任何行。
 */
export class ProductBadgeAndWeeklyLimit1796000000000 implements MigrationInterface {
  name = 'ProductBadgeAndWeeklyLimit1796000000000';

  /** 置顶商品（和平精英体验单） */
  private static readonly FEATURED_PRODUCT_ID = '137';

  /** 置顶商品徽标文案 */
  private static readonly FEATURED_BADGE = '董事长推荐';

  /** 置顶商品每周限购（单/账号/周） */
  private static readonly FEATURED_WEEKLY_LIMIT = 2;

  /** 其余商品重排后的起始值（步长 10，留出人工插队的空间） */
  private static readonly SORT_BASE = 10;

  private static readonly SORT_STEP = 10;

  public async up(queryRunner: QueryRunner): Promise<void> {
    const hasColumn = async (column: string): Promise<boolean> => {
      const [row] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = ?`,
        [column],
      );
      return Number(row.c) > 0;
    };

    // ---------- 1. badge_text ----------
    if (!(await hasColumn('badge_text'))) {
      await queryRunner.query(
        `ALTER TABLE \`product\`
           ADD COLUMN \`badge_text\` varchar(32) NULL
           COMMENT '商品徽标文案（如 董事长推荐；NULL/空=不显示），管理端可配' AFTER \`subtitle\``,
      );
    }

    // ---------- 2. weekly_limit ----------
    if (!(await hasColumn('weekly_limit'))) {
      await queryRunner.query(
        `ALTER TABLE \`product\`
           ADD COLUMN \`weekly_limit\` int NULL
           COMMENT '每个账号每周可下单数（NULL/0=不限；服务端下单事务内强制）' AFTER \`badge_text\``,
      );
    }

    // ---------- 3. 目标商品数据（不存在则整段跳过，绝不凭空造商品） ----------
    const rows = await queryRunner.query(
      `SELECT id, division_id, badge_text, weekly_limit FROM product WHERE id = ? LIMIT 1`,
      [ProductBadgeAndWeeklyLimit1796000000000.FEATURED_PRODUCT_ID],
    );
    if (!rows.length) return;

    const product = rows[0] as { id: string; division_id: string | null; badge_text: string | null; weekly_limit: number | null };

    // 3.1 徽标 + 限购：只在「从未配置过」时写，管理端改过的值不会被迁移覆盖
    if (product.badge_text == null) {
      await queryRunner.query(`UPDATE product SET badge_text = ? WHERE id = ?`, [
        ProductBadgeAndWeeklyLimit1796000000000.FEATURED_BADGE,
        ProductBadgeAndWeeklyLimit1796000000000.FEATURED_PRODUCT_ID,
      ]);
    }
    if (product.weekly_limit == null) {
      await queryRunner.query(`UPDATE product SET weekly_limit = ? WHERE id = ?`, [
        ProductBadgeAndWeeklyLimit1796000000000.FEATURED_WEEKLY_LIMIT,
        ProductBadgeAndWeeklyLimit1796000000000.FEATURED_PRODUCT_ID,
      ]);
    }

    // 3.2 置顶：商品没挂分部时无法确定「同一分部」，只把它自己置 0（此时它不参与任何分部排序）
    const divisionId = product.division_id == null ? null : String(product.division_id);

    // 先取出「该分部其余商品」的当前生效顺序（与公开接口 ORDER BY sort_order ASC, id DESC 一致）
    const others: Array<{ id: string; sort_order: number }> = divisionId
      ? await queryRunner.query(
          `SELECT id, sort_order FROM product
            WHERE division_id = ? AND id <> ? AND sort_order <= 0
            ORDER BY sort_order ASC, id DESC`,
          [divisionId, ProductBadgeAndWeeklyLimit1796000000000.FEATURED_PRODUCT_ID],
        )
      : [];

    await queryRunner.query(`UPDATE product SET sort_order = 0 WHERE id = ?`, [
      ProductBadgeAndWeeklyLimit1796000000000.FEATURED_PRODUCT_ID,
    ]);

    for (let i = 0; i < others.length; i += 1) {
      const next = ProductBadgeAndWeeklyLimit1796000000000.SORT_BASE + i * ProductBadgeAndWeeklyLimit1796000000000.SORT_STEP;
      await queryRunner.query(`UPDATE product SET sort_order = ? WHERE id = ?`, [next, others[i].id]);
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // 排序是**业务数据**：回滚只把目标商品所在分部的 sort_order 还原为迁移前的 0（迁移前该分部全部为 0），
    // 不删任何商品、不动其它分部。
    const rows = await queryRunner.query(`SELECT division_id FROM product WHERE id = ? LIMIT 1`, [
      ProductBadgeAndWeeklyLimit1796000000000.FEATURED_PRODUCT_ID,
    ]);
    const divisionId = rows.length && rows[0].division_id != null ? String(rows[0].division_id) : null;
    if (divisionId) {
      await queryRunner.query(`UPDATE product SET sort_order = 0 WHERE division_id = ?`, [divisionId]);
    }

    for (const column of ['weekly_limit', 'badge_text']) {
      const [exists] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = ?`,
        [column],
      );
      if (Number(exists.c) > 0) await queryRunner.query(`ALTER TABLE \`product\` DROP COLUMN \`${column}\``);
    }
  }
}
