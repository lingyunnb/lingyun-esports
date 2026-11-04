import { MigrationInterface, QueryRunner } from 'typeorm';

/** chat_conversation.type 加宽至 16（订单群类型 'order_group' 长 11 字符，原 varchar(8) 装不下） */
export class WidenConvType1789951000000 implements MigrationInterface {
  name = 'WidenConvType1789951000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` MODIFY COLUMN \`type\` varchar(16) NOT NULL DEFAULT 'cs'`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE \`chat_conversation\` MODIFY COLUMN \`type\` varchar(8) NOT NULL DEFAULT 'cs'`);
  }
}
