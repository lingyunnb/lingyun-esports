import { MigrationInterface, QueryRunner } from 'typeorm';

import {
  RECHARGE_CONFIG_DEFAULT,
  RECHARGE_CONFIG_DESCRIPTION,
  RECHARGE_CONFIG_KEY,
} from '../modules/recharge/recharge-config';

/**
 * 充值（线下收款 + 人工审核）地基 1/2：三张表 + 充值配置行。
 *
 * ## 合规红线（负责人定案，逐条落到模型里）
 *
 * - **不接任何支付通道**：本迁移不建任何"支付/通道/回调"表，三张表里也没有
 *   支付单号、商户号、appid、密钥字段 —— 不做的能力不留在模型里。
 * - **收款码是图片**：`recharge_qr_code.media_id` → `media` 表（App 只展示）。
 * - **平台不经手资金**：`recharge_request` 只记"老板自己填的金额 + 上传的截图 + 人工审核结论"，
 *   `status='granted'` 只能由管理员手工触发（没有任何自动到账路径）。
 * - **不做提现**：没有提现表、没有提现字段。
 *
 * ## 1) `recharge_qr_code`（收款码，可多张）
 *
 * `enabled + sort` 建联合索引：老板端只查"启用的、按 sort 升序"那几行（覆盖索引，单次范围扫描）。
 * 停用**不删行**：历史申请要能回溯"当时扫的是哪张码"。
 *
 * ## 2) `recharge_request`（充值申请）—— 幂等与审计的落地
 *
 * - `UK_rqr_wallet_txn (wallet_transaction_id)`：**一笔流水只能对应一张申请**。
 *   这是"一张申请只能发放一次"的**数据库级**兜底（服务层另有事务内 `SELECT ... FOR UPDATE`
 *   + `WHERE status='pending'` 条件 UPDATE 判 affectedRows，两道都在）。
 *   MySQL 唯一索引忽略 NULL → 未发放的申请（NULL）互不冲突，天然支持"多张待审"。
 * - `IDX_rqr_user_status (user_id, status, id)`：老板端"我的申请"列表 + **待审核数上限**统计
 *   （`WHERE user_id=? AND status='pending'`）都命中它，高频路径不扫全表。
 * - `IDX_rqr_status (status, id)`：管理端/受限会话的待审列表分页（`status='pending' ORDER BY id`）。
 * - `amount_yuan DECIMAL(10,2)`：与项目既有 16 个金额字段同口径（docs/02 铁律：金额一律 DECIMAL）。
 * - `points INT`：**落库快照**，事后改 `points_per_yuan` 不影响历史单据（可对账）。
 * - 审计三件套 `reviewed_by` / `reviewed_at` / `wallet_transaction_id` 全在表里，均可空（未审核）。
 *
 * ## 3) `recharge_admin`（受限管理员白名单，≤ 5）
 *
 * `user_id` 做主键 = 唯一约束（同一账号不可能重复加入）。总数 ≤ `admin_limit`（硬上限 5）
 * 由服务层的**配置行行锁**串行化 + 该唯一键兜底，见 `recharge.service.ts` 的注释。
 *
 * ## 4) 配置行 `system_setting.recharge_config`
 *
 * 为什么配置落 `system_setting` 而不是单开 `recharge_config` 表 —— 见
 * `modules/recharge/recharge-config.ts` 顶部说明（核心：只有这样才能**真正复用 `is_high_security` 机制**，
 * 不把"仅超管可写"这条规则再实现一遍）。
 * `is_high_security = 1` → 普通管理员可读、**写在 `SystemSettingService.update()` 被 403 拦下**。
 * 读侧每次实时读库（无缓存）；公开接口走 `PublicCacheInterceptor`，写路径带失效钩子。
 *
 * ## 幂等与回滚
 *
 * `CREATE TABLE IF NOT EXISTS` + `INSERT ... ON DUPLICATE KEY UPDATE setting_key = setting_key`
 * → 重复执行不报错，且**不会冲掉运营已经改过的档位/比例**。
 * 回滚只删本迁移建的三张表与该配置行，不触碰任何既有数据（user/media/wallet 一行不动）。
 */
export class Recharge1804000000000 implements MigrationInterface {
  name = 'Recharge1804000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- 1) 收款码 ----------
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`recharge_qr_code\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`media_id\` bigint unsigned NOT NULL COMMENT '收款码图片（media.id；public 通道，App 只展示，不接任何支付通道）',
        \`channel\` varchar(16) NOT NULL DEFAULT 'other' COMMENT 'wechat 微信 / alipay 支付宝 / other 其它',
        \`label\` varchar(64) NOT NULL DEFAULT '' COMMENT '展示名（老板端列表里那一行字）',
        \`sort\` int NOT NULL DEFAULT 0 COMMENT '排序（升序展示）',
        \`enabled\` tinyint NOT NULL DEFAULT 1 COMMENT '1 启用展示 / 0 停用（不删行，历史申请仍可回溯）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        KEY \`IDX_rqc_enabled_sort\` (\`enabled\`, \`sort\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充值收款码（图片展示；平台不经手资金，无任何支付通道字段）'
    `);

    // ---------- 2) 充值申请 ----------
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`recharge_request\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`user_id\` bigint unsigned NOT NULL COMMENT '申请人（user.id，role=user；主体只来自 JWT sub）',
        \`amount_yuan\` decimal(10,2) NOT NULL COMMENT '申请金额（元，老板自填/选择的档位；非任何通道回调）',
        \`points\` int NOT NULL COMMENT '按当时 points_per_yuan 换算的积分（落库快照，事后改比例不影响历史）',
        \`qr_id\` bigint unsigned NULL COMMENT '老板扫的收款码（recharge_qr_code.id，可空）',
        \`proof_media_id\` bigint unsigned NOT NULL COMMENT '转账截图（media.id，受保护媒体：本人与管理员可读）',
        \`note\` varchar(200) NOT NULL DEFAULT '' COMMENT '老板留言（便于人工核对）',
        \`status\` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending 待审核 / granted 已发放 / rejected 已驳回',
        \`reject_reason\` varchar(200) NULL COMMENT '驳回原因（随通知发给老板）',
        \`reviewed_by\` bigint unsigned NULL COMMENT '审核人（user.id，role=admin）——审计：谁发的',
        \`reviewed_at\` datetime(3) NULL COMMENT '审核时间——审计：什么时候发的',
        \`wallet_transaction_id\` bigint unsigned NULL COMMENT '发放对应的钱包流水（审计：发的是哪一笔）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_rqr_wallet_txn\` (\`wallet_transaction_id\`),
        KEY \`IDX_rqr_user_status\` (\`user_id\`, \`status\`, \`id\`),
        KEY \`IDX_rqr_status\` (\`status\`, \`id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充值申请（线下付款 + 上传截图 + 人工核对后手工发积分；无自动到账、无提现）'
    `);

    // ---------- 3) 受限充值管理员白名单 ----------
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`recharge_admin\` (
        \`user_id\` bigint unsigned NOT NULL COMMENT 'admin 账号的 user.id（主键=唯一键：一个账号最多一条）',
        \`granted_by\` bigint unsigned NOT NULL COMMENT '谁加进来的（超管 user.id）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        PRIMARY KEY (\`user_id\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='受限充值管理员白名单（最多 5 个账号；权限仅限 recharge:review / recharge:grant）'
    `);

    // ---------- 4) 配置行（is_high_security=1 → 仅超管可写）----------
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, ?, ?, 1)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [
        RECHARGE_CONFIG_KEY,
        // 形状与既有配置完全一致：cfg_value = {"value": <配置本体>}
        JSON.stringify({ value: RECHARGE_CONFIG_DEFAULT }),
        RECHARGE_CONFIG_DESCRIPTION,
      ],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DELETE FROM \`system_setting\` WHERE \`setting_key\` = ?`, [RECHARGE_CONFIG_KEY]);
    await queryRunner.query(`DROP TABLE IF EXISTS \`recharge_admin\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`recharge_request\``);
    await queryRunner.query(`DROP TABLE IF EXISTS \`recharge_qr_code\``);
  }
}
