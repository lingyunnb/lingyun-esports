import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 订单增加老板游戏信息（负责人需求 2026-09-24）：
 * - 老板下单必须填写游戏分区（QQ区/微信区）与游戏 ID
 * - 打手抢上单之后才能看到这两个字段（大厅不展示）
 * - 快照表同步记录，历史订单展示永不漂移
 */
export class OrderGameZone1789940000000 implements MigrationInterface {
  name = 'OrderGameZone1789940000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`order\` ADD COLUMN \`game_zone\` varchar(16) NULL COMMENT '游戏分区(QQ区/微信区)' AFTER \`user_remark\``);
    await queryRunner.query(`ALTER TABLE \`order\` ADD COLUMN \`game_player_id\` varchar(64) NULL COMMENT '老板游戏ID' AFTER \`game_zone\``);
    await queryRunner.query(`ALTER TABLE \`order_price_snapshot\` ADD COLUMN \`game_zone\` varchar(16) NULL COMMENT '游戏分区快照' AFTER \`estimate_duration_min\``);
    await queryRunner.query(`ALTER TABLE \`order_price_snapshot\` ADD COLUMN \`game_player_id\` varchar(64) NULL COMMENT '游戏ID快照' AFTER \`game_zone\``);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`order_price_snapshot\` DROP COLUMN \`game_player_id\``);
    await queryRunner.query(`ALTER TABLE \`order_price_snapshot\` DROP COLUMN \`game_zone\``);
    await queryRunner.query(`ALTER TABLE \`order\` DROP COLUMN \`game_player_id\``);
    await queryRunner.query(`ALTER TABLE \`order\` DROP COLUMN \`game_zone\``);
  }
}
