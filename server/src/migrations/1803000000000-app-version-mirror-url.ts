import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 云更新提速 ②/2：`app_version.mirror_url` —— 可空的多下载源（CDN / 镜像）。
 *
 * ## 为什么加这一列
 * 2026-10-06 实测：客户端经 ngrok 隧道下载 26MB 安装包时，**瓶颈在隧道**（单连接限速，
 * 多连接可把吞吐放大数倍），服务器本机直连是 390MB/s 量级。因此"换一个更快的下载源"
 * 是最直接的第二条提速路径——但它必须是**运维可配**的，不能写死在客户端。
 *
 * 本列语义：
 * - `NULL`（默认）= 没有镜像，客户端用 `/api/v1/public/app-versions/download/:id`
 *   （相对路径，服务端下发的 downloadUrl）
 * - 有值 = **绝对地址**（`https://cdn.example.com/fish-boss-1.11.19.apk`），
 *   `latest` 接口把它作为 `downloadUrl` 下发；客户端 `AppConfig.resolveMediaUrl`
 *   对绝对 http(s) URL **原样透传**，因此无需任何客户端改动即可切换下载源。
 *
 * ⚠️ 镜像必须与主包**逐字节一致**（sha256 校验会对不上就拒绝安装，不会装坏包），
 * 且必须支持 `Range`（否则客户端自动退回单连接整包，功能不受影响、只是慢）。
 *
 * ## 为什么用绝对地址而不是"镜像前缀"
 * 前缀拼接要求镜像目录结构与服务器磁盘一致，运维容易配错；绝对地址一目了然、
 * 也允许镜像用完全不同的文件名（CDN 常见）。校验仍以 sha256 为准，配错只会失败不会装坏。
 *
 * ## 幂等 / 回滚
 * - 幂等：`ADD COLUMN` 前先查 `information_schema`，列已存在则跳过（可重复执行）。
 * - 回滚：仅删该列（不触碰任何既有数据列）。
 */
export class AppVersionMirrorUrl1803000000000 implements MigrationInterface {
  name = 'AppVersionMirrorUrl1803000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const has = await this.hasColumn(queryRunner);
    if (has) return; // 幂等：重复执行不报错
    await queryRunner.query(
      'ALTER TABLE `app_version` ADD COLUMN `mirror_url` VARCHAR(512) NULL COMMENT \'可选镜像/CDN 绝对下载地址（NULL=用服务端默认下载接口）\'',
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    if (!(await this.hasColumn(queryRunner))) return;
    await queryRunner.query('ALTER TABLE `app_version` DROP COLUMN `mirror_url`');
  }

  private async hasColumn(queryRunner: QueryRunner): Promise<boolean> {
    const rows: Array<{ c: number }> = await queryRunner.query(
      "SELECT COUNT(*) AS c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'app_version' AND COLUMN_NAME = 'mirror_url'",
    );
    return Number(rows?.[0]?.c ?? 0) > 0;
  }
}
