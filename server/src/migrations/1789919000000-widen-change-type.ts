import { MigrationInterface, QueryRunner } from 'typeorm';

/** 流水 change_type 加长到 32：支持 settlement_reversal / platform_commission_reversal 等新类型 */
export class WidenChangeType1789919000000 implements MigrationInterface {
  name = 'WidenChangeType1789919000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`wallet_transaction\` MODIFY \`change_type\` varchar(32) NOT NULL`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`wallet_transaction\` MODIFY \`change_type\` varchar(24) NOT NULL`);
  }
}
