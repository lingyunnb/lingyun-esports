import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 合并双端 · 身份切换（方案甲）地基 2/2：`auth_token` 增加 `kind` 与 `binding_id`。
 *
 * 背景（设计稿 §2 冲突点 ①，最高风险）：`/auth/login` 成功后 `issueTokens(replaceOthers=true)` 会把该账号
 * **所有** `revoked=0` 的会话置为 `revoked=2`（单设备登录铁律）。合并端若直接用打手账密登录，
 * 真正的打手会被立刻顶下线。方案甲的解法：给会话**分类**，而不是豁免单设备规则。
 *
 * - `kind`：`primary`（默认，普通登录：老板端/工作端/管理端）| `companion`（伴随登录：老板端内"切换身份"）。
 *   **存量行一律 primary**（`NOT NULL DEFAULT 'primary'`）→ 既有单设备语义逐字节不变。
 * - `binding_id`：companion 会话所属的 `worker_identity_binding.id`（primary 为 NULL）。
 *   守卫据此**每次请求实时查库**校验绑定仍 active（解绑/停用立即 401），不信任令牌载荷。
 * - 索引 `IDX_auth_token_kind (user_id, kind, revoked)`：companion 签发时"只顶掉该账号其它 companion"
 *   的 UPDATE、以及 refresh 轮换的会话查询都命中它。
 * - 索引 `IDX_auth_token_binding (binding_id)`：解绑时按绑定批量吊销（`WHERE binding_id=? AND revoked=0`）。
 *
 * 幂等：加列/加索引前先查 `information_schema`（MySQL 8 不支持 `ADD COLUMN IF NOT EXISTS`），
 * 重复执行不报错、不覆盖既有数据。
 * 回滚：删两个索引与两列（kind 删除后回到"所有会话等价"的旧语义）。
 */
export class AuthTokenKind1802000000000 implements MigrationInterface {
  name = 'AuthTokenKind1802000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    if (!(await this.columnExists(queryRunner, 'kind'))) {
      await queryRunner.query(
        `ALTER TABLE \`auth_token\`
         ADD COLUMN \`kind\` varchar(16) NOT NULL DEFAULT 'primary'
         COMMENT 'primary 普通登录（单设备互斥）/ companion 伴随会话（绑定关系签发，不顶 primary）' AFTER \`role\``,
      );
    }
    if (!(await this.columnExists(queryRunner, 'binding_id'))) {
      await queryRunner.query(
        `ALTER TABLE \`auth_token\`
         ADD COLUMN \`binding_id\` bigint unsigned NULL
         COMMENT 'companion 会话所属绑定 id（worker_identity_binding.id；primary 为 NULL）' AFTER \`kind\``,
      );
    }
    if (!(await this.indexExists(queryRunner, 'IDX_auth_token_kind'))) {
      await queryRunner.query(
        `ALTER TABLE \`auth_token\` ADD KEY \`IDX_auth_token_kind\` (\`user_id\`, \`kind\`, \`revoked\`)`,
      );
    }
    if (!(await this.indexExists(queryRunner, 'IDX_auth_token_binding'))) {
      await queryRunner.query(`ALTER TABLE \`auth_token\` ADD KEY \`IDX_auth_token_binding\` (\`binding_id\`)`);
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    if (await this.indexExists(queryRunner, 'IDX_auth_token_binding')) {
      await queryRunner.query(`ALTER TABLE \`auth_token\` DROP KEY \`IDX_auth_token_binding\``);
    }
    if (await this.indexExists(queryRunner, 'IDX_auth_token_kind')) {
      await queryRunner.query(`ALTER TABLE \`auth_token\` DROP KEY \`IDX_auth_token_kind\``);
    }
    if (await this.columnExists(queryRunner, 'binding_id')) {
      await queryRunner.query(`ALTER TABLE \`auth_token\` DROP COLUMN \`binding_id\``);
    }
    if (await this.columnExists(queryRunner, 'kind')) {
      await queryRunner.query(`ALTER TABLE \`auth_token\` DROP COLUMN \`kind\``);
    }
  }

  private async columnExists(queryRunner: QueryRunner, column: string): Promise<boolean> {
    const rows = (await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'auth_token' AND COLUMN_NAME = ?`,
      [column],
    )) as Array<{ c: number | string }>;
    return Number(rows[0]?.c ?? 0) > 0;
  }

  private async indexExists(queryRunner: QueryRunner, index: string): Promise<boolean> {
    const rows = (await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'auth_token' AND INDEX_NAME = ?`,
      [index],
    )) as Array<{ c: number | string }>;
    return Number(rows[0]?.c ?? 0) > 0;
  }
}
