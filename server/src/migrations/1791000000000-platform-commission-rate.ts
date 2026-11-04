import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 平台抽成比例后台可配（负责人 2026-10-04：抽成 30% → 25%，且管理端可自行修改）。
 *
 * - 新增 `system_setting` 配置项 `platform_commission_rate`，`cfg_value = {"value": 25}`，
 *   语义 = **百分数整数**（25 = 平台抽 25%、打手拿 75%），取值 0–50 由后端校验。
 * - 默认 25 = 本次需求值（打手 75%）；此后改比例一律走管理端「系统设置」，
 *   结算 / AI 提示词 / 管理端展示全部读这一条配置（禁止再散落硬编码）。
 * - `is_high_security = 0`：沿用既有 `admin:setting:write` 权限点（不额外收窄到超管）；
 *   若要收窄，把该列改成 1 即可（SystemSettingService.update 已按超管校验）。
 * - `INSERT IGNORE` 幂等：已经存在（人工先建）时不覆盖已有取值，避免上线把运营改好的比例冲掉。
 *
 * 另：`order_settlement` 两个比例列的**列默认值**从建表时的 70/30 跟到 75/25
 * （`ALTER COLUMN ... SET DEFAULT` 是 INSTANT 元数据变更，不重建表、不动索引）。
 * 结算代码一律显式写入比例，列默认值只是「万一有遗漏写入」的兜底，避免新单悄悄落 70/30。
 */
export class PlatformCommissionRate1791000000000 implements MigrationInterface {
  name = 'PlatformCommissionRate1791000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      INSERT IGNORE INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`) VALUES
      ('platform_commission_rate', JSON_OBJECT('value', 25),
       '平台抽成比例（百分数整数 0-50；打手拿 100-该值%，默认 25 = 打手 75%）', 0)
    `);
    await queryRunner.query(`ALTER TABLE \`order_settlement\` ALTER COLUMN \`worker_percentage\` SET DEFAULT 75`);
    await queryRunner.query(`ALTER TABLE \`order_settlement\` ALTER COLUMN \`platform_percentage\` SET DEFAULT 25`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`order_settlement\` ALTER COLUMN \`worker_percentage\` SET DEFAULT 70`);
    await queryRunner.query(`ALTER TABLE \`order_settlement\` ALTER COLUMN \`platform_percentage\` SET DEFAULT 30`);
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = 'platform_commission_rate'`);
  }
}
