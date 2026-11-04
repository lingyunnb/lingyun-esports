import { MigrationInterface, QueryRunner } from 'typeorm';

/** 阶段8：账号与权限 8 张表（docs/02 权威设计，含 down 回滚） */
export class CreateAuthTables1789910000000 implements MigrationInterface {
  name = 'CreateAuthTables1789910000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE \`user\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`username\` varchar(32) NOT NULL,
        \`uid\` varchar(20) NOT NULL,
        \`password_hash\` varchar(100) NOT NULL,
        \`nickname\` varchar(32) NOT NULL DEFAULT '',
        \`avatar_media_id\` bigint unsigned NULL,
        \`background_media_id\` bigint unsigned NULL,
        \`role\` varchar(16) NOT NULL,
        \`status\` tinyint NOT NULL DEFAULT 1,
        \`last_login_at\` datetime(3) NULL,
        \`last_login_ip\` varchar(64) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_user_username\` (\`username\`),
        UNIQUE KEY \`UQ_user_uid\` (\`uid\`),
        KEY \`IDX_user_role_status\` (\`role\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`worker\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`worker_no\` varchar(20) NOT NULL,
        \`real_name\` varchar(32) NULL,
        \`phone\` varchar(20) NULL,
        \`can_take_order\` tinyint NOT NULL DEFAULT 0,
        \`can_serve_customer\` tinyint NOT NULL DEFAULT 0,
        \`status\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_worker_user_id\` (\`user_id\`),
        UNIQUE KEY \`UQ_worker_worker_no\` (\`worker_no\`),
        KEY \`IDX_worker_can_take_order_status\` (\`can_take_order\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`admin_role\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`code\` varchar(32) NOT NULL,
        \`name\` varchar(32) NOT NULL,
        \`is_builtin\` tinyint NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_admin_role_code\` (\`code\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`permission\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`code\` varchar(64) NOT NULL,
        \`name\` varchar(32) NOT NULL,
        \`group_name\` varchar(32) NOT NULL DEFAULT '',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_permission_code\` (\`code\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`admin_role_permission\` (
        \`role_id\` bigint unsigned NOT NULL,
        \`permission_id\` bigint unsigned NOT NULL,
        \`granted_by\` bigint unsigned NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`role_id\`, \`permission_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`admin\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL,
        \`role_id\` bigint unsigned NOT NULL,
        \`status\` tinyint NOT NULL DEFAULT 1,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_admin_user_id\` (\`user_id\`),
        KEY \`IDX_admin_role_id\` (\`role_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`auth_token\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`jti\` varchar(64) NOT NULL,
        \`user_id\` bigint unsigned NOT NULL,
        \`role\` varchar(16) NOT NULL,
        \`expire_at\` datetime(3) NOT NULL,
        \`revoked\` tinyint NOT NULL DEFAULT 0,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_auth_token_jti\` (\`jti\`),
        KEY \`IDX_auth_token_user_id\` (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    await queryRunner.query(`
      CREATE TABLE \`login_log\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_type\` varchar(16) NOT NULL,
        \`user_id\` bigint unsigned NULL,
        \`username\` varchar(32) NOT NULL,
        \`ip\` varchar(64) NULL,
        \`user_agent\` varchar(255) NULL,
        \`result\` varchar(16) NOT NULL,
        \`fail_reason\` varchar(100) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_login_log_user_id\` (\`user_id\`),
        KEY \`IDX_login_log_ip_created\` (\`ip\`, \`created_at\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query('DROP TABLE IF EXISTS `login_log`');
    await queryRunner.query('DROP TABLE IF EXISTS `auth_token`');
    await queryRunner.query('DROP TABLE IF EXISTS `admin`');
    await queryRunner.query('DROP TABLE IF EXISTS `admin_role_permission`');
    await queryRunner.query('DROP TABLE IF EXISTS `permission`');
    await queryRunner.query('DROP TABLE IF EXISTS `admin_role`');
    await queryRunner.query('DROP TABLE IF EXISTS `worker`');
    await queryRunner.query('DROP TABLE IF EXISTS `user`');
  }
}
