import { MigrationInterface, QueryRunner } from 'typeorm';

import { ORDER_NOTICE_DEFAULT_KEY, ORDER_NOTICE_DEFAULT_TEXT } from '../modules/setting/order-notice';

/**
 * 「下单须知」两层配置（负责人 2026-10-05 商品详情页 v2 方案 B，方案甲）
 *
 * 需求原文：
 * > 「下单须知」默认折叠（点开看全）：文案来自**接口下发**
 * > `order_notice` 商品级优先 → 否则平台默认；**若这两个字段还不存在**，按设计稿方案甲加：
 * > migration 时间戳 1799000000000-*，`product.order_notice TEXT NULL` +
 * > `system_setting.order_notice_default`，**默认值直接写现有那段须知**，
 * > 让上线当天每个商品就有须知，无空窗
 *
 * ---------------------------------------------------------------------------
 * 1) `product.order_notice` TEXT NULL
 *    - **商品级覆盖**（管理端「下单须知 → 覆盖」）。NULL / 空 = 继承平台默认。
 *    - 用 TEXT（不是 varchar）：须知是**多条长句**，现有那份默认文案 4 条已 ~90 字，
 *      将来加"保证金/未成年/发票"等条款必然继续增长；varchar 到 500/1000 再改表
 *      等于给运营埋一个"改文案改到一半被 400 拒绝"的坑。
 *    - 长度上限不靠 DDL 而靠 DTO（`@Length(0, 3000)`）：DDL 只管存储，DTO 才是给运营看的
 *      中文 400 文案（"下单须知最多 3000 字"），两者分工与 `attention`/`detail` 一致。
 *
 * 2) `system_setting.order_notice_default`
 *    - **平台默认须知**（所有未覆盖的商品共用），管理端「下单须知 → 默认」可改。
 *    - 存储形状 `{"value":{"text":"..."}}`：与既有 `order_pending_take_timeout_hours`
 *      （`{"value":24}`）同一套 `cfg_value` 约定 —— 都是 `JSON_OBJECT('value', ...)`，
 *      `SystemSettingService.text()` 只认 `cfg_value.value.text`。
 *    - **默认值 = 现有那段须知，逐字写在迁移里**（从 `modules/setting/order-notice.ts` import，
 *      保证"库里一份、代码一份"不会分叉）：上线当天每个商品就有须知，**无空窗**。
 *
 * ⚠️ **列表接口不加这两个字段**：`GET /public/products` 已做列裁剪（迁移 1792000000000 的
 *    性能专项），把 TEXT 捞回列表会把刚压下去的响应体体积加回去。须知只走**详情**接口
 *    （`GET /public/products/:id` 的 `effectiveOrderNotice`）。
 *
 * **幂等**：列先查 information_schema（存在则跳过）；配置行走 `INSERT ... ON DUPLICATE KEY UPDATE`
 *   只在**没有该行**时写入默认文案（管理端改过的默认**不会被迁移覆盖**）。
 * **回滚**：删列 + 删除该配置行（管理端改过的默认文案一并丢弃 —— 回滚语义就是"这一版没做过"）。
 */
export class OrderNotice1799000000000 implements MigrationInterface {
  name = 'OrderNotice1799000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const [col] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = 'order_notice'`,
    );
    if (Number(col.c) === 0) {
      await queryRunner.query(
        `ALTER TABLE \`product\`
           ADD COLUMN \`order_notice\` text NULL
           COMMENT '商品级下单须知（NULL/空=继承平台默认 order_notice_default）' AFTER \`attention\``,
      );
    }

    // 平台默认须知：只在**行不存在**时写入默认文案（管理端已改过则一个字节都不动）
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, JSON_OBJECT('value', JSON_OBJECT('text', ?)), ?, 0)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [
        ORDER_NOTICE_DEFAULT_KEY,
        ORDER_NOTICE_DEFAULT_TEXT,
        '平台默认下单须知（商品未单独配置「下单须知」时下发此文案；\\n 分条）',
      ],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [ORDER_NOTICE_DEFAULT_KEY]);
    const [col] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'product' AND COLUMN_NAME = 'order_notice'`,
    );
    if (Number(col.c) > 0) await queryRunner.query('ALTER TABLE `product` DROP COLUMN `order_notice`');
  }
}
