import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * 投诉 / 打赏 / 退款（负责人 2026-10-04 顶部导航三入口）
 *
 * 1) `order_tip` 打赏记录：老板钱包 → 打手钱包 100% 过手（平台不抽成），
 *    idempotency_key 唯一约束防重复打赏；订单维度可累计（上限走 system_setting）
 * 2) `refund_request` 退款申请：老板提交 → 管理端审批（通过=原路退回积分，驳回=填理由），
 *    idempotency_key 唯一约束 + status 条件更新防重复审批/重复退款
 * 3) `complaint` 投诉工单：对象（订单/打手/客服）+ 类型 + 描述 + 截图（媒体 id）+
 *    处理状态/处理人/处理意见
 * 4) 管理端权限点 6 个（查看/处理），授予既有管理角色
 * 5) 打赏金额配置（预设/单次上限/单订单累计上限）落 system_setting，管理端可改
 */
export class TipRefundComplaint1789986000000 implements MigrationInterface {
  name = 'TipRefundComplaint1789986000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- 打赏 ----------
    await queryRunner.query(`
      CREATE TABLE \`order_tip\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`order_id\` bigint unsigned NOT NULL,
        \`from_user_id\` bigint unsigned NOT NULL COMMENT '打赏老板（钱包扣减方）',
        \`to_user_id\` bigint unsigned NOT NULL COMMENT '打手登录账号（钱包入账方，服务端权威）',
        \`to_worker_id\` bigint unsigned NOT NULL COMMENT '打手档案 worker.id',
        \`amount\` int NOT NULL COMMENT '打赏积分（正整数，服务端校验）',
        \`status\` varchar(16) NOT NULL DEFAULT 'success' COMMENT 'success / failed',
        \`remark\` varchar(200) NOT NULL DEFAULT '',
        \`idempotency_key\` varchar(64) NOT NULL COMMENT '客户端生成，唯一约束防重复打赏',
        \`request_id\` varchar(64) NULL,
        \`ip\` varchar(64) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_order_tip_idem\` (\`idempotency_key\`),
        KEY \`IDX_order_tip_order\` (\`order_id\`),
        KEY \`IDX_order_tip_from\` (\`from_user_id\`, \`id\`),
        KEY \`IDX_order_tip_to_user\` (\`to_user_id\`, \`id\`),
        KEY \`IDX_order_tip_created\` (\`created_at\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // ---------- 退款申请 ----------
    await queryRunner.query(`
      CREATE TABLE \`refund_request\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`request_no\` varchar(32) NOT NULL,
        \`order_id\` bigint unsigned NOT NULL,
        \`user_id\` bigint unsigned NOT NULL COMMENT '申请人（订单老板，取自 JWT）',
        \`amount\` decimal(12,2) NOT NULL COMMENT '申请退款金额（= 订单金额快照，服务端算）',
        \`prev_status\` varchar(20) NOT NULL COMMENT '申请时订单状态，审批通过后作废该订单',
        \`reason\` varchar(200) NOT NULL DEFAULT '',
        \`remark\` varchar(500) NOT NULL DEFAULT '',
        \`status\` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending / approved / rejected',
        \`handler_id\` bigint unsigned NULL,
        \`handler_remark\` varchar(500) NOT NULL DEFAULT '',
        \`handled_at\` datetime(3) NULL,
        \`idempotency_key\` varchar(64) NOT NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_refund_request_no\` (\`request_no\`),
        UNIQUE KEY \`UQ_refund_request_idem\` (\`idempotency_key\`),
        KEY \`IDX_refund_request_order\` (\`order_id\`),
        KEY \`IDX_refund_request_status\` (\`status\`, \`id\`),
        KEY \`IDX_refund_request_user\` (\`user_id\`, \`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // ---------- 投诉工单 ----------
    await queryRunner.query(`
      CREATE TABLE \`complaint\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`complaint_no\` varchar(32) NOT NULL,
        \`user_id\` bigint unsigned NOT NULL COMMENT '投诉人（取自 JWT）',
        \`target_type\` varchar(16) NOT NULL COMMENT 'order / worker / service',
        \`target_id\` varchar(64) NOT NULL DEFAULT '' COMMENT '订单 id / 打手 worker.id / 客服标识',
        \`target_name\` varchar(64) NOT NULL DEFAULT '' COMMENT '目标展示名快照（服务端写入）',
        \`type\` varchar(24) NOT NULL COMMENT 'attitude 服务态度 / not_agreed 未按约定 / delay 恶意拖延 / other 其它',
        \`content\` varchar(1000) NOT NULL,
        \`media_ids\` varchar(500) NOT NULL DEFAULT '' COMMENT '截图媒体 id，逗号分隔（最多 6 张）',
        \`status\` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending / processing / handled / rejected',
        \`handle_remark\` varchar(500) NOT NULL DEFAULT '',
        \`handled_by\` bigint unsigned NULL,
        \`handled_at\` datetime(3) NULL,
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UQ_complaint_no\` (\`complaint_no\`),
        KEY \`IDX_complaint_status\` (\`status\`, \`id\`),
        KEY \`IDX_complaint_user\` (\`user_id\`, \`id\`),
        KEY \`IDX_complaint_target\` (\`target_type\`, \`target_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    `);

    // ---------- 权限点（查看 / 处理）与角色授予 ----------
    const perms: [string, string, string][] = [
      ['admin:tip:read', '打赏记录查看', '打赏'],
      ['admin:tip:config', '打赏金额配置', '打赏'],
      ['admin:refund:read', '退款申请查看', '退款'],
      ['admin:refund:handle', '退款申请审批', '退款'],
      ['admin:complaint:read', '投诉工单查看', '投诉'],
      ['admin:complaint:handle', '投诉工单处理', '投诉'],
    ];
    for (const [code, name, group] of perms) {
      await queryRunner.query(
        `INSERT INTO permission (code, name, group_name, created_at) VALUES (?, ?, ?, NOW(3))
         ON DUPLICATE KEY UPDATE name = VALUES(name), group_name = VALUES(group_name)`,
        [code, name, group],
      );
    }
    // 与既有 club 权限同策略：既有管理角色（含 super_admin）全部授予，之后可在角色页按需收回
    await queryRunner.query(`
      INSERT IGNORE INTO admin_role_permission (role_id, permission_id, created_at)
      SELECT r.id, p.id, NOW(3) FROM admin_role r CROSS JOIN permission p
      WHERE p.code LIKE 'admin:tip:%' OR p.code LIKE 'admin:refund:%' OR p.code LIKE 'admin:complaint:%'
    `);

    // ---------- 打赏金额配置（管理端「系统设置」可直接改） ----------
    await queryRunner.query(`
      INSERT IGNORE INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`) VALUES
      ('tip_presets', JSON_OBJECT('value', JSON_ARRAY(6, 18, 38, 88)), '打赏预设金额（积分，管理端可改）', 0),
      ('tip_max_per_tip', JSON_OBJECT('value', 500), '单次打赏上限（积分）', 0),
      ('tip_max_per_order', JSON_OBJECT('value', 1000), '同一订单累计打赏上限（积分）', 0),
      ('refund_apply_statuses', JSON_OBJECT('value', JSON_ARRAY('pending_take','pending_dispatch','taken','in_progress','pending_confirm')), '可申请退款的订单状态（已完成走申诉，docs/05）', 0)
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM admin_role_permission WHERE permission_id IN (SELECT id FROM permission WHERE code LIKE 'admin:tip:%' OR code LIKE 'admin:refund:%' OR code LIKE 'admin:complaint:%')`);
    await queryRunner.query(`DELETE FROM permission WHERE code LIKE 'admin:tip:%' OR code LIKE 'admin:refund:%' OR code LIKE 'admin:complaint:%'`);
    await queryRunner.query(`DELETE FROM system_setting WHERE setting_key IN ('tip_presets','tip_max_per_tip','tip_max_per_order','refund_apply_statuses')`);
    await queryRunner.query('DROP TABLE IF EXISTS `complaint`');
    await queryRunner.query('DROP TABLE IF EXISTS `refund_request`');
    await queryRunner.query('DROP TABLE IF EXISTS `order_tip`');
  }
}
