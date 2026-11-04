import { MigrationInterface, QueryRunner } from 'typeorm';

/** 等级规则后台可配（负责人 2026-09-25）：升级阈值写入 system_setting，前端只读 /public/levels */
export class LevelRulesSetting1789960000000 implements MigrationInterface {
  name = 'LevelRulesSetting1789960000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      INSERT IGNORE INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`) VALUES
      ('level_rules', JSON_OBJECT('rules', JSON_ARRAY(
        JSON_OBJECT('level', 1, 'name', '新星会员', 'minSpent', 0),
        JSON_OBJECT('level', 2, 'name', '进阶会员', 'minSpent', 500),
        JSON_OBJECT('level', 3, 'name', '精英会员', 'minSpent', 2000),
        JSON_OBJECT('level', 4, 'name', '尊享会员', 'minSpent', 10000),
        JSON_OBJECT('level', 5, 'name', '王者会员', 'minSpent', 50000)
      )), '会员等级规则（升级所需累计消费积分，前端只读）', 0)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = 'level_rules'`);
  }
}
