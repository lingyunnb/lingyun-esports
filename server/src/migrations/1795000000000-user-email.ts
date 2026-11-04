import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 邮箱验证基础字段（负责人 2026-10-05：用邮箱验证替代短信验证，0 成本）
 *
 * 需求原文：
 * > 「忘记密码」要真能用 —— 用邮箱验证替代短信验证（0 成本）
 *
 * 本迁移只做「加列 + 加唯一索引」，**不改动任何既有列/表结构、不删任何数据**：
 *
 * 1) `user`.`email` varchar(120) NULL
 *    - 邮箱是**可选**属性（老客户端不传 email，注册行为必须完全不变）→ 必须 NULL 可空；
 *    - 长度 120：RFC 5321 规定邮件地址最长 254 字节，但本项目邮箱仅作验证通道、
 *      120 足够容纳真实地址，且能在 utf8mb4 下保持唯一索引不超长（见下）。
 *
 * 2) `user`.`email_verified_at` datetime(3) NULL
 *    - **需要**：3 个接口（注册 / 找回密码 / 后续可能的换绑邮箱）都要回答「这个邮箱是不是他本人的」。
 *      没有这一列就只能靠「当前会话里刚验过码」这种易失状态推断，进程重启/多实例即失效，
 *      管理端也无法排查「某账号邮箱是否已验证」；
 *    - 写入时机：注册带 email 且码正确 → 与 email 同事务写入；找回密码验码成功 → 也刷新该时间
 *      （验码成功即证明邮箱可达且持码人可控该邮箱）；
 *    - 该列**只增不删**（换绑邮箱需要旧邮箱确认，届时另有接口），当前不影响任何既有逻辑。
 *
 * 3) 唯一索引 `UQ_user_email`（**仅非空唯一**）
 *    - MySQL 唯一索引对 NULL **不去重**（多行 NULL 合法），因此「大量未填邮箱的老用户」不会冲突；
 *    - 只对已填（非空）邮箱去重 —— 这是「一个邮箱只能绑一个账号」的权威约束，
 *      代码层的重复校验会被并发绕过，唯一索引才是兜底；
 *    - 换绑/清空邮箱：把 email 置 NULL 即退出唯一约束。
 *
 * **幂等**：全部步骤先查 information_schema，存在则跳过（可重复执行不报错）。
 * **回滚**：先删索引再删两列（列上有数据时会被丢弃，与 drizzle/typeorm 常规回滚口径一致）。
 */
export class UserEmail1795000000000 implements MigrationInterface {
  name = 'UserEmail1795000000000';

  /** 唯一索引名（查重与建索引共用） */
  private static readonly UNIQUE_INDEX = 'UQ_user_email';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const hasColumn = async (column: string): Promise<boolean> => {
      const [row] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = ?`,
        [column],
      );
      return Number(row.c) > 0;
    };
    const hasIndex = async (indexName: string): Promise<boolean> => {
      const [row] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.STATISTICS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND INDEX_NAME = ?`,
        [indexName],
      );
      return Number(row.c) > 0;
    };

    // ---------- 1. email 列 ----------
    if (!(await hasColumn('email'))) {
      await queryRunner.query(
        `ALTER TABLE \`user\`
           ADD COLUMN \`email\` varchar(120) NULL
           COMMENT '邮箱（可选，唯一；用于注册/找回密码的邮箱验证）' AFTER \`nickname\``,
      );
    }

    // ---------- 2. email_verified_at 列 ----------
    if (!(await hasColumn('email_verified_at'))) {
      await queryRunner.query(
        `ALTER TABLE \`user\`
           ADD COLUMN \`email_verified_at\` datetime(3) NULL
           COMMENT '邮箱验证通过时间（NULL=未验证）' AFTER \`email\``,
      );
    }

    // ---------- 3. 唯一索引（NULL 允许多行，仅非空唯一） ----------
    if (!(await hasIndex(UserEmail1795000000000.UNIQUE_INDEX))) {
      // 建索引前先自检历史重复值：如有重复（理论上不该有，加列前全为 NULL）则如实报错而不是静默丢数据
      const dup: { email: string; c: number }[] = await queryRunner.query(
        `SELECT email, COUNT(*) AS c FROM \`user\` WHERE email IS NOT NULL GROUP BY email HAVING c > 1 LIMIT 5`,
      );
      if (dup.length > 0) {
        throw new Error(
          `user.email 存在重复值，无法建唯一索引：${dup.map((d) => `${d.email}×${d.c}`).join(', ')}`,
        );
      }
      await queryRunner.query(
        `ALTER TABLE \`user\` ADD UNIQUE INDEX \`${UserEmail1795000000000.UNIQUE_INDEX}\` (\`email\`)`,
      );
    }
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    const [idx] = await queryRunner.query(
      `SELECT COUNT(*) AS c FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND INDEX_NAME = ?`,
      [UserEmail1795000000000.UNIQUE_INDEX],
    );
    if (Number(idx.c) > 0) {
      await queryRunner.query(`ALTER TABLE \`user\` DROP INDEX \`${UserEmail1795000000000.UNIQUE_INDEX}\``);
    }
    for (const column of ['email_verified_at', 'email']) {
      const [exists] = await queryRunner.query(
        `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'user' AND COLUMN_NAME = ?`,
        [column],
      );
      if (Number(exists.c) > 0) await queryRunner.query(`ALTER TABLE \`user\` DROP COLUMN \`${column}\``);
    }
  }
}
