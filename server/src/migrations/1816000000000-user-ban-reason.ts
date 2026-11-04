import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 封禁秒踢 1/1：`user` 表增加 `ban_reason`（负责人 2026-10-16 需求）。
 *
 * ## 为什么必须有这一列
 *
 * 负责人原话：「**显示踢下线原因是被封**」。而在本次之前，`ban(id, { reason })` 的
 * **原因只落 `operation_log`** —— `user` 表只有 `status` + `banned_until`。
 * 于是"因为什么被封"在**用户可见的链路**上**没有任何数据源**：管理员填了原因，
 * 用户被封时看不到（能看到的只有管理员自己在操作日志里）。
 *
 * ## 语义（与既有两列严格配套，不新增状态）
 *
 * - `status = 2` 时才有值；`status = 1` 时必须为 NULL（解封即清空，见下）；
 * - `NULL` = 管理员未填原因 → 文案**省略**原因段（`账号已被封禁（永久）`），
 *   而不是显示"原因：无"这种噪音；
 * - 与 `banned_until` 一起构成封禁的**全部**状态：`status=2 + banned_until=NULL + ban_reason` = 永久封禁。
 *
 * ## 谁写、谁清（唯一实现）
 *
 * - 写：`UserAdminService.ban()` → `userRepo.update(id, { status: 2, bannedUntil, banReason })`；
 *   清洗（trim + 按字符截断 200 + 空串归 NULL）只有一份：`normalizeBanReason()`。
 * - 清：`UserAdminService.unban()`（管理员提前解封）与 `checkAccountBan()` 的"到期自动解封"
 *   （守卫 / `AuthService.assertNotBanned` 共用）。**解封不残留旧原因**是本列的硬约束 ——
 *   残留会让下一次"永久封禁但没填原因"错误地显示上一次的原因，属于误导性文案。
 * - 读：守卫（每请求 401 `errorCode=ACCOUNT_BANNED` + 文案）与 WS 踢线载荷，
 *   都走 `modules/auth/account-ban.check.ts` 的 `buildBanMessage()`。
 *
 * ## 幂等与回滚
 *
 * 加列前先查 `information_schema`（MySQL 8 不支持 `ADD COLUMN IF NOT EXISTS`），
 * 重复执行不报错、不覆盖既有数据（**存量被封账号的 ban_reason 保持 NULL** ——
 * 它们本就只留了结束时间，不臆造原因）。
 * `down` 只删本列，不触碰 `status` / `banned_until` 与任何业务数据。
 */
export class UserBanReason1816000000000 implements MigrationInterface {
  name = 'UserBanReason1816000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    if (!(await this.columnExists(queryRunner, 'ban_reason'))) {
      await queryRunner.query(
        `ALTER TABLE \`user\`
         ADD COLUMN \`ban_reason\` varchar(200) NULL
         COMMENT '封禁原因（仅 status=2 时有值；解封即清空）' AFTER \`banned_until\``,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    if (await this.columnExists(queryRunner, 'ban_reason')) {
      await queryRunner.query(`ALTER TABLE \`user\` DROP COLUMN \`ban_reason\``);
    }
  }

  private async columnExists(queryRunner: QueryRunner, column: string): Promise<boolean> {
    const rows = (await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = ?`,
      [column],
    )) as Array<{ c: number | string }>;
    return Number(rows[0]?.c ?? 0) > 0;
  }
}
