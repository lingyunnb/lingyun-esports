import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 媒体去重唯一键：`sha256` 单列 → `(sha256, media_type)` 组合
 *
 * ## 为什么要改（2026-10-18 真机 bug）
 * `MediaService.upload()` 的去重查询是 `findOne({ where: { sha256, mediaType } })`
 * —— 它按「内容 + 用途」判重，注释也写明「类型不同则各自建记录，保证保护级别/生命周期独立」。
 * 但表上的唯一约束是**只有 `sha256`** 单列。
 *
 * 两者不一致的后果：**同一张图换个用途上传就 500**
 * （查重按组合查不到 → 尝试插入 → `sha256` 唯一键冲突）。
 * 真机表现：先设头像成功，再用同一张图设主页背景 → 「上传失败，请重试」。
 *
 * ## 改动
 * 删掉 `sha256` 单列唯一索引，建 `(sha256, media_type)` 组合唯一索引。
 * - 同一内容 + 同一用途 → 仍然复用（去重语义不变）
 * - 同一内容 + 不同用途 → 允许各自一行（这正是代码本来的意图）
 *
 * ## 幂等
 * 先查 `information_schema.STATISTICS`：组合索引已存在则整段跳过；
 * `sha256` 单列唯一索引不存在时也不报错（`DROP ... IF EXISTS` 语义靠先查再做）。
 */
export class MediaSha256TypeUnique1819000000000 implements MigrationInterface {
  name = 'MediaSha256TypeUnique1819000000000';

  private readonly COMBO = 'UK_media_sha256_type';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const db: Array<{ db: string }> = await queryRunner.query('SELECT DATABASE() AS db');
    const schema = db[0]?.db;
    if (!schema) return;

    // 幂等：组合索引已存在 → 跳过
    const hasCombo: Array<{ n: number }> = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = 'media' AND INDEX_NAME = ?`,
      [schema, this.COMBO],
    );
    if (Number(hasCombo[0]?.n ?? 0) > 0) return;

    // 找出 sha256 单列的唯一索引（名字由 TypeORM 生成，不硬编码）
    const single: Array<{ INDEX_NAME: string; cols: string }> = await queryRunner.query(
      `SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols
         FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = 'media' AND NON_UNIQUE = 0
        GROUP BY INDEX_NAME`,
      [schema],
    );
    for (const idx of single) {
      // 只删「恰好只有 sha256 一列」的唯一索引；组合索引与主键都不动
      if (String(idx.cols) === 'sha256') {
        await queryRunner.query(`ALTER TABLE media DROP INDEX \`${idx.INDEX_NAME}\``);
      }
    }

    await queryRunner.query(
      `ALTER TABLE media ADD UNIQUE KEY \`${this.COMBO}\` (sha256, media_type)`,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const db: Array<{ db: string }> = await queryRunner.query('SELECT DATABASE() AS db');
    const schema = db[0]?.db;
    if (!schema) return;

    const hasCombo: Array<{ n: number }> = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = 'media' AND INDEX_NAME = ?`,
      [schema, this.COMBO],
    );
    if (Number(hasCombo[0]?.n ?? 0) === 0) return;

    await queryRunner.query(`ALTER TABLE media DROP INDEX \`${this.COMBO}\``);

    // 回滚时可能已有「同内容不同用途」的多行 → 无法重建 sha256 单列唯一。
    // 这种情况下只删组合索引、不重建（保持数据完整优先），并把原因写在日志里。
    const dup: Array<{ n: number }> = await queryRunner.query(
      `SELECT COUNT(*) AS n FROM (
         SELECT sha256 FROM media GROUP BY sha256 HAVING COUNT(*) > 1
       ) t`,
    );
    if (Number(dup[0]?.n ?? 0) > 0) {
      // eslint-disable-next-line no-console
      console.warn(
        '[down] 存在同一 sha256 的多行（不同用途），跳过重建 sha256 单列唯一索引以免失败',
      );
      return;
    }
    await queryRunner.query('ALTER TABLE media ADD UNIQUE KEY `UK_media_sha256` (sha256)');
  }
}
