import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 商品「列表短名」列 + 两条超长名商品的数据（负责人 2026-10-05 任务②）
 *
 * 需求原文：
 * > 管理端加「列表短名」（数据驱动，通用能力）：`product` 表加列 `list_name varchar(64) NULL`；
 * > 管理端商品编辑可填；老板端**列表页**优先显示 `listName`（空则回退完整 `name`）；
 * > **详情页 / 确认订单页 / 订单页仍显示完整名**（不要到处替换）；
 * > `/public/products` 与详情都返回该字段。
 *
 * ---------------------------------------------------------------------------
 * 1) `product.list_name` varchar(64) NULL
 *    - 只服务**窄卡列表**这一次渲染：管理端给超长商品名配一个短名，列表卡不再换行 4 行以上；
 *      留空（NULL）＝列表直接用完整 `name`（**默认行为，绝大多数商品都不需要配**）。
 *    - 长度 64 与 `product.name` 完全一致：短名的语义是"名字的另一种写法"，
 *      允许它跟完整名一样长（管理端配得比完整名长没有意义但也不该 400），DDL 只钉住上限。
 *    - **不是**给这两个商品写死的字段：任何商品都能配，客户端只有一个判断「非空则用短名」。
 *    - 为什么不改 `name`：`name` 会进 `order_price_snapshot.product_name` 与订单列表/
 *      详情/消息文案，改它等于改历史展示口径；列表短名是**纯展示层**字段，零业务影响。
 *
 * 2) 数据（**幂等 + 不覆盖管理员的后续修改**：只在当前值为 NULL 时写入）
 *    - 商品 144 `36.6博弈宝冠单（出返现小金人+金aug）不出保888w[老板必须全程录屏不录开出不算]`（45 字）
 *      → `36.6博弈宝冠单（不出保888w）`
 *    - 商品 145 `44.6博弈鹰雕单（出反现小金人+金aug+雪隼）不出保1200w[老板必须全程录屏不录开出不算]`（49 字）
 *      → `44.6博弈鹰雕单（不出保1200w）`
 *    - **只给这两条配，其余商品保持 NULL**（负责人明确要求"其余保持空"）。
 *    - 短名保留「价格前缀 + 单名 + 不出保额度」三段——这是老板在列表里筛选时真正要看的信息；
 *      「出什么小金人 / 必须录屏」等长说明留在详情页完整名里展开。
 *    - 写入前先按 id 实查 `name` 长度并要求 `>= 40`：万一这两条名字被别人改短了，
 *      迁移不会把短名硬塞给一条已经正常的商品（宁可不写，也不制造"列表名与完整名不一致"的困惑）。
 *
 * **幂等**：列先查 information_schema，存在则跳过；数据只在 NULL 且名字确实超长时写。
 * **回滚**：删列（列上数据一并丢弃），不改动任何其它列、不删任何行。
 */
export class ProductListName1797000000000 implements MigrationInterface {
  name = 'ProductListName1797000000000';

  /** 超长名的两条商品 → 短名（负责人给的示例口径） */
  private static readonly SHORT_NAMES: Array<{ id: string; listName: string }> = [
    { id: '144', listName: '36.6博弈宝冠单（不出保888w）' },
    { id: '145', listName: '44.6博弈鹰雕单（不出保1200w）' },
  ];

  /** 只有"确实超长"（≥40 字）才配短名；小于这个长度说明数据已被人改过，迁移不越权 */
  private static readonly MIN_LONG_NAME_CHARS = 40;

  public async up(queryRunner: QueryRunner): Promise<void> {
    const [col] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = 'list_name'`,
    );
    if (Number(col.c) === 0) {
      await queryRunner.query(
        `ALTER TABLE \`product\`
           ADD COLUMN \`list_name\` varchar(64) NULL
           COMMENT '列表短名（客户端商品列表卡显示用；NULL/空=用完整 name）'
           AFTER \`subtitle\``,
      );
    }

    for (const item of ProductListName1797000000000.SHORT_NAMES) {
      const rows = await queryRunner.query(
        `SELECT id, name, list_name FROM product WHERE id = ? LIMIT 1`,
        [item.id],
      );
      if (!rows.length) continue; // 商品不存在（被删或换了环境）→ 跳过，绝不凭空造商品
      const row = rows[0] as { name: string | null; list_name: string | null };
      if (row.list_name != null && String(row.list_name).trim() !== '') continue; // 管理员已配过 → 不覆盖
      const nameLength = [...String(row.name ?? '')].length;
      if (nameLength < ProductListName1797000000000.MIN_LONG_NAME_CHARS) continue;
      await queryRunner.query(`UPDATE product SET list_name = ? WHERE id = ?`, [item.listName, item.id]);
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const [col] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = 'list_name'`,
    );
    if (Number(col.c) > 0) {
      await queryRunner.query('ALTER TABLE `product` DROP COLUMN `list_name`');
    }
  }
}
