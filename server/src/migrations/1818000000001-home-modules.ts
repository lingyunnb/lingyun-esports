import { MigrationInterface, QueryRunner } from 'typeorm';

import {
  HOME_MODULES_DEFAULT,
  HOME_MODULES_DESCRIPTION,
  HOME_MODULES_KEY,
} from '../modules/home/home-modules';

/**
 * 首页三模块配置 1/1：`system_setting.home_modules`（负责人 2026-10-18）
 *
 * ## 需求原文
 *
 * > 「热门游戏 精选服务 人气打手 可以在管理端更改」
 *
 * ## 为什么是"一行配置"而不是新表、不是客户端常量
 *
 * - 三块各自只有 **启用开关 + 条数 + 排序口径** 三个字段（见 `home-modules.ts` 的取舍说明）：
 *   没有业务实体、没有分页、没有唯一约束要维护 —— 建表只为存 3 × 3 个标量属于过度设计；
 * - 与 `platform_commission_rate` / `purchase_points_hint` / `recharge_config` / `withdraw_config`
 *   **完全同一套**：一行 `system_setting` + 管理端可视化编辑 + 读侧实时读库无缓存 + 客户端零硬编码；
 * - 写入口唯一（`SystemSettingService.update()` → `validate` 按 key 校验），
 *   所以"通用入口 `PUT /admin/settings/:key`"与"专用入口 `PUT /admin/settings/home_modules`"
 *   用的是**同一份** `assertHomeModules`，不会有两套规则。
 *
 * ## 为什么 `is_high_security = 0`（普通管理员可改）
 *
 * 这一项**只决定首页展示哪几块、几块、按什么顺序排**：不动钱、不动权限、不动数据可见性
 * （对比 `withdraw_config` / `recharge_config` 那些 `is_high_security = 1` 的资金口径）。
 * 运营需要随时调整版面（本周主推哪个游戏），走超管闸门只会让日常运营卡住。
 *
 * ## 默认值 = 改动前客户端硬编码的那一套（行为零变化）
 *
 * `{"value": {"hotGames": {"enabled": true, "limit": 3, "order": "onlineCount"},
 *             "products": {"enabled": true, "limit": 8, "order": "sales"},
 *             "players":  {"enabled": true, "limit": 4, "order": "completedOrders"}}}`
 *
 * 与 `HOME_MODULES_DEFAULT` 逐字一致（唯一出处是那份常量，本迁移只负责把它写进库）。
 * 读侧对"整行缺失 / 被手工改坏"另有逐字段回退（`parseHomeModules` 永不抛），
 * 所以即便本迁移没跑，首页也照常出内容 —— 迁移的意义是让管理端**看得见并改得动**这份默认值。
 *
 * ## 幂等与回滚
 *
 * `INSERT ... ON DUPLICATE KEY UPDATE setting_key = setting_key` → 重复执行不报错，
 * 且**不会冲掉运营已经调过的开关/条数/口径**。
 * `down` 只删本行，不触碰任何既有配置与业务数据。
 */
export class HomeModules1818000000001 implements MigrationInterface {
  name = 'HomeModules1818000000001';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, ?, ?, 0)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [HOME_MODULES_KEY, JSON.stringify({ value: HOME_MODULES_DEFAULT }), HOME_MODULES_DESCRIPTION],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [HOME_MODULES_KEY]);
  }
}
