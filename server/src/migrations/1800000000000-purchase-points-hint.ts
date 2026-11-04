import { MigrationInterface, QueryRunner } from 'typeorm';

import {
  PURCHASE_POINTS_HINT_DEFAULT,
  PURCHASE_POINTS_HINT_DESCRIPTION,
  PURCHASE_POINTS_HINT_KEY,
} from '../modules/setting/purchase-hint';

/**
 * 购买提示（负责人 2026-10-05）：老板端「选择服务」页底部常驻一行小字
 *
 * 需求原文：
 * > 「在选择服务那里加一行小字：下单均使用积分非人民币 10 积分等于 1 人民币，
 * >   如需下单请联系小云进行积分充值」
 *
 * ---------------------------------------------------------------------------
 * 1) 为什么落在 `system_setting`（而不是客户端常量 / 新表）
 *    - 联系人（小云）与比例（10 积分 = 1 人民币）都是**运营口径**，会变；
 *      写死在 App 里改一次要发一次版，还得等全量用户升级。
 *    - 与 `order_notice_default`（1799000000000）、`platform_commission_rate`（1791000000000）
 *      完全同一套：一行 `system_setting` + 管理端可视化编辑 + 客户端零硬编码。
 *
 * 2) 存储形状 `{"value":{"text":"..."}}`
 *    - 与 `order_notice_default` 逐字同形状（`SystemSettingService.text()` 只认
 *      `cfg_value.value.text`），管理端「全部配置项」表格与通用
 *      `PUT /admin/settings/:key` 都能直接读懂它，不引入第二套约定。
 *
 * 3) `is_high_security = 1` —— **仅超级管理员可改**
 *    - 这行字直接出现在下单路径上，改错等于向所有用户发错充值联系人；
 *      与抽成比例（同样是钱相关口径）同级，故走 `docs/04` 的最高安全档：
 *      普通管理员可读（`admin:setting:read`）、写被 `SystemSettingService.update` 拒绝。
 *    - `description` 里写明「留空会让整行消失」，避免运营以为清空是"暂时隐藏"。
 *
 * ⚠️ **不加进 `/public/products`**：该接口已做列裁剪（迁移 1792000000000 性能专项），
 *    把平台级文案挂到**每一个商品**上是纯浪费（50 条商品 = 同一句话重复 50 次）。
 *    下发走**独立极轻接口** `GET /public/purchase-hint`（1 行配置、2ms），
 *    已登记进 `PublicCacheInterceptor`（前缀 + 60s 档缓存头），写路径带失效钩子。
 *
 * **幂等**：`INSERT ... ON DUPLICATE KEY UPDATE setting_key = setting_key`
 *   —— 只在**没有该行**时写入默认文案；管理端已经改过的文案**一个字节都不动**
 *   （重复执行迁移、或先手工建行再跑迁移，都不会把运营改的值冲掉）。
 * **回滚**：删该配置行（管理端改过的值一并丢弃 —— 回滚语义就是"这一版没做过"，
 *   客户端会因为拿不到 `text` 而**整行不渲染**，不会露出任何兜底文案）。
 */
export class PurchasePointsHint1800000000000 implements MigrationInterface {
  name = 'PurchasePointsHint1800000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, JSON_OBJECT('value', JSON_OBJECT('text', ?)), ?, 1)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [PURCHASE_POINTS_HINT_KEY, PURCHASE_POINTS_HINT_DEFAULT, PURCHASE_POINTS_HINT_DESCRIPTION],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [PURCHASE_POINTS_HINT_KEY]);
  }
}
