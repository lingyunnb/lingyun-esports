import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 第三方登录绑定表 `user_oauth`（QQ 登录，负责人 2026-10-10）。
 *
 * ## 为什么需要这张表
 * QQ 登录的账号定位键是**第三方平台的 openid**（服务端用 access_token 复核得到），
 * 它既不是 username 也不是 uid，塞进 `user` 表会污染账号体系（且一个平台账号将来要绑多个 provider）。
 * 单独一张表 + 唯一键，才能把"一个 QQ 只能对一个平台账号"变成**数据库级**约束。
 *
 * ## 结构语义
 * - `provider varchar(16)`：`qq`（当前），预留 `wechat`（表结构不写死 provider）；
 * - `openid varchar(64)`：第三方平台用户唯一标识（QQ 为 32 位十六进制）；
 * - `unionid varchar(64) NULL`：同开发者的跨应用统一 id（`oauth2.0/me?unionid=1` 才有），
 *   当前只**存下来备将来合并**，不参与登录判定；
 * - `user_id bigint unsigned`：平台账号（`user.id`）；
 * - `UK_user_oauth_provider_openid(provider, openid)`：**一个第三方账号只能绑一个平台账号**
 *   （并发下服务层的"先查后插"必被绕过，唯一索引才是兜底；服务层撞键时回中文 409 而不是 500）；
 * - `IDX_user_oauth_user_id(user_id)`：按平台账号反查已绑定的第三方账号（`GET /auth/qq/*` 类展示、
 *   以及将来"解绑"要按 user_id 定位）。
 *
 * ## 幂等与回滚
 * - `CREATE TABLE IF NOT EXISTS`：重复执行不报错（typeorm 迁移表已记录时本就不会再跑）；
 * - 建表前先按 `information_schema` 判定，索引缺失也单独补（防止"表已存在但索引被手工删过"）；
 * - `down` 只删本迁移建的表，不触碰任何既有表与数据。
 */
export class UserOauth1809000000000 implements MigrationInterface {
  name = 'UserOauth1809000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`user_oauth\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`provider\` varchar(16) NOT NULL COMMENT '第三方平台：qq（当前）/ wechat（预留）',
        \`openid\` varchar(64) NOT NULL COMMENT '第三方平台用户唯一标识（**只信服务端复核结果**，绝不信客户端入参）',
        \`unionid\` varchar(64) NULL COMMENT '同开发者跨应用统一 id（可选；仅存备合并，不参与登录判定）',
        \`user_id\` bigint unsigned NOT NULL COMMENT '平台账号 id（user.id）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_user_oauth_provider_openid\` (\`provider\`, \`openid\`),
        KEY \`IDX_user_oauth_user_id\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='第三方登录绑定（QQ/微信；一个第三方账号只能绑一个平台账号）'
    `);

    // 表可能是手工建过（缺唯一键）→ 单独补齐，保证"一个 QQ 一个账号"的数据库级约束确实在
    const [uk] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user_oauth' AND INDEX_NAME = 'UK_user_oauth_provider_openid'`,
    );
    if (Number(uk.c) === 0) {
      await queryRunner.query(
        `ALTER TABLE \`user_oauth\` ADD UNIQUE INDEX \`UK_user_oauth_provider_openid\` (\`provider\`, \`openid\`)`,
      );
    }
    const [idx] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user_oauth' AND INDEX_NAME = 'IDX_user_oauth_user_id'`,
    );
    if (Number(idx.c) === 0) {
      await queryRunner.query(`ALTER TABLE \`user_oauth\` ADD INDEX \`IDX_user_oauth_user_id\` (\`user_id\`)`);
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `user_oauth`');
  }
}
