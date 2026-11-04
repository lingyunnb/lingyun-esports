import { MigrationInterface, QueryRunner } from 'typeorm';

import { WITHDRAW_CONFIG_DEFAULT, WITHDRAW_CONFIG_DESCRIPTION, WITHDRAW_CONFIG_KEY } from '../modules/withdraw/withdraw-config';

/**
 * 打手提现（人工打款）地基 1/2：两张表 + 提现配置行。
 *
 * ## 资金模型（负责人拍板，逐条落到表结构里）
 *
 * **申请即扣款**：`withdraw_request` 一建出来，打手钱包里那笔钱就**已经**被扣走了
 * （同事务内 `WalletService.withdrawDeductInTx` + 流水 `change_type='withdraw'`），
 * `wallet_transaction_id` 就是那条扣款流水。驳回 → 退回 + 反向流水 `withdraw_reject`。
 * 因此本表**不需要**"冻结金额"之类的列：在途资金压根不在钱包里，不存在"锁了又被花掉"的窗口。
 *
 * ## 1) `worker_withdraw_account`（收款信息：收款码 + 微信号 + 姓名 + 电话）
 *
 * **同一打手只能有一行 active** —— 落地方式照抄 `worker_identity_binding`（结构规则 11）：
 *
 *   `active_worker_id` = CASE WHEN status='active' THEN worker_id ELSE NULL END  (STORED)
 *   `UNIQUE KEY UK_wwa_active_worker (active_worker_id)`
 *
 * MySQL 唯一索引**忽略含 NULL 的键** → 只有 active 行参与约束；解绑/留档行（`unbound`）为 NULL，
 * 互不冲突。**换绑 = UPDATE 同一行**（服务层写新旧值审计），不会留出"没有 active 行"的窗口
 * —— 打款侧任何时刻读到的收款信息都是唯一的、明确的（资金去向不能有歧义）。
 *
 * ## 2) `withdraw_request`（提现申请）—— 幂等、并发与审计的落地
 *
 * 三条**数据库级**兜底（服务层另有事务 + 行锁 + 条件 UPDATE，两道都在）：
 * - `UK_wr_pending_worker (pending_worker_id 生成列)`：同一打手**不可能同时存在两笔 pending**
 *   —— "未结清申请数上限 1"从业务规则升级为**表结构保证**。并发两笔时后一笔撞唯一键，
 *   服务层翻译成中文 409（不是 500）。已打款/已驳回的行生成列变 NULL，自动释放名额。
 * - `UK_wr_wallet_txn (wallet_transaction_id)`：**一笔流水只能对应一张申请**（照抄 `UK_rqr_wallet_txn`）；
 *   MySQL 唯一索引忽略 NULL → 未扣款的申请（NULL）天然支持多张。
 * - `UK_wr_idem (idempotency_key)`：客户端重试幂等（同一键返回首次结果，不重复扣款）。
 *
 * 索引：
 * - `IDX_wr_worker_status (worker_id, status)`：打手端"我的记录" + **未结清数**统计（`worker_id + status='pending'`）；
 * - `IDX_wr_status_applied (status, applied_at)`：管理端/受限会话的待处理列表（`status='pending' ORDER BY applied_at`）。
 *
 * ⚠️ `wallet_transaction_id` 与 `payout_proof_media_id` 里的"两条资金相关流水"是刻意分开的：
 * `wallet_transaction_id` 只记**扣款**那条（唯一约束要的语义）；**退回**那条靠确定的幂等键
 * `withdraw_reject:<id>` 反查（`wallet_transaction.idempotency_key` 唯一）——不额外加列，
 * 少一列就少一处可能与真实流水不一致的冗余。
 *
 * ## 3) media 用途（**无需 DDL**）
 *
 * `withdraw_qr`（**protected**：收款码绝不公开直连）与 `withdraw_proof`（**protected**：打款凭证）
 * 是应用层的用途白名单（`MediaService.TYPE_RULES`），`media.media_type` 是自由字符串，
 * 不需要改表；两者都进 `MediaService.referenceCount()` 引用计数（仍被引用的图禁止删除）。
 *
 * ## 4) 配置行 `system_setting.withdraw_config`
 *
 * `is_high_security = 1` → 普通管理员可读、**写在 `SystemSettingService.update()` 被 403 拦下**
 * （"仅超管可改"全项目只有一处实现）。读侧每次实时读库（无缓存）。
 *
 * ## 5) 两个专用窄权限点（`withdraw:review` / `withdraw:pay`）
 *
 * 负责人定案：**权限 = 仅超管**。与 `recharge:review` / `recharge:grant` **完全同口径**：
 * 不复用 `admin:wallet:*` 这类大权限（那会连带给出管理端钱包页/用户页一族能力），
 * 且**只授予 `super_admin`**，其余角色**一个都不给**（需要时由超管在「角色权限」页显式勾选）。
 * 拆成"看"与"打款"两点：`withdraw:review` 只读（含敏感个人信息与收款码），
 * `withdraw:pay` 是**不可逆的资金动作**（打款 = 平台真的把钱转出去了；驳回 = 退回）——
 * 于是"能看不能打"成为一个可独立授予的形态。
 * 权限点全量清单同时登记在 `modules/rbac/permissions.const.ts`（启动种子幂等补种）。
 *
 * ## 为什么"表 + 配置 + 权限点"写在**同一个** migration 文件里
 *
 * 充值当时拆成 `1804000000000`（表）+ `1805000000000`（权限）两个文件；
 * 本次负责人指定时间戳为 `1810000000000`（`1809000000000` 已被 user_oauth 占用），
 * 而 TypeORM 以**时间戳**标识一个 migration —— 两个文件同时间戳会让
 * "已执行迁移"的比对出现歧义。因此这里合并为一个文件、分节书写，
 * 时间戳唯一、语义仍然一目了然（与充值那两节逐条对应）。
 *
 * ## 幂等与回滚
 *
 * `CREATE TABLE IF NOT EXISTS` + `INSERT ... ON DUPLICATE KEY UPDATE setting_key = setting_key`
 * + `INSERT IGNORE`（授权）→ 重复执行不报错，且**不会冲掉运营已经改过的门槛/次数/文案**，
 * 也不会重复授权。回滚只删本迁移建的两张表、该配置行与两个权限点及其授权行，
 * 不触碰任何既有数据（user/worker/media/wallet/角色定义一行不动）。
 */
export class WorkerWithdraw1810000000000 implements MigrationInterface {
  name = 'WorkerWithdraw1810000000000';

  /** 两个窄权限点（group_name 统一为「提现」，管理端角色页按组展示） */
  private readonly perms: Array<[string, string]> = [
    ['withdraw:review', '提现申请查看'],
    ['withdraw:pay', '提现打款/驳回'],
  ];

  public async up(queryRunner: QueryRunner): Promise<void> {
    // ---------- 1) 打手收款信息（微信收款码 + 微信号 + 姓名 + 电话）----------
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`worker_withdraw_account\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`worker_id\` bigint unsigned NOT NULL COMMENT '打手档案（worker.id；不是 user.id）',
        \`real_name\` varchar(32) NOT NULL COMMENT '真实姓名（打款核对用；列表脱敏，详情给完整）',
        \`phone\` varchar(20) NOT NULL COMMENT '手机号（打款联系用；列表脱敏）',
        \`wechat_id\` varchar(64) NOT NULL COMMENT '微信号（只做微信，不做支付宝）',
        \`qr_media_id\` bigint unsigned NOT NULL COMMENT '微信收款码（media.id，用途 withdraw_qr，protected：绝不公开直连）',
        \`status\` varchar(16) NOT NULL DEFAULT 'active' COMMENT 'active 生效 / unbound 已解绑（历史行保留，不删除）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        \`active_worker_id\` bigint unsigned GENERATED ALWAYS AS (CASE WHEN \`status\` = 'active' THEN \`worker_id\` ELSE NULL END) STORED COMMENT '仅 active 行有值：唯一键只约束 active 行（同一打手只有一行 active）',
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_wwa_active_worker\` (\`active_worker_id\`),
        KEY \`IDX_wwa_worker_status\` (\`worker_id\`, \`status\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='打手提现收款信息（微信收款码 + 微信号 + 姓名 + 电话；换绑=更新同一行）'
    `);

    // ---------- 2) 提现申请（申请即扣款；驳回则退回）----------
    await queryRunner.query(`
      CREATE TABLE IF NOT EXISTS \`withdraw_request\` (
        \`id\` bigint unsigned NOT NULL AUTO_INCREMENT,
        \`worker_id\` bigint unsigned NOT NULL COMMENT '打手档案（worker.id）',
        \`user_id\` bigint unsigned NOT NULL COMMENT '打手账号（user.id，role=worker）——钱包主体；只来自 JWT sub',
        \`amount\` decimal(12,2) NOT NULL COMMENT '提现金额（元，两位小数；申请时已从余额扣除）',
        \`status\` varchar(16) NOT NULL DEFAULT 'pending' COMMENT 'pending 处理中 / paid 已打款 / rejected 已驳回（金额已退回）',
        \`applied_at\` datetime(3) NULL COMMENT '申请时间（= 扣款时间；DB 时钟写入）',
        \`paid_at\` datetime(3) NULL COMMENT '打款时间（管理员线下微信转账后回填）',
        \`paid_by\` bigint unsigned NULL COMMENT '打款人（user.id，role=admin）——审计：谁打的款',
        \`payout_proof_media_id\` bigint unsigned NULL COMMENT '打款凭证（media.id，用途 withdraw_proof，protected：资金凭证绝不公开直连）',
        \`payout_note\` varchar(200) NULL COMMENT '打款备注（如微信转账单号/尾号）',
        \`rejected_at\` datetime(3) NULL COMMENT '驳回时间',
        \`rejected_by\` bigint unsigned NULL COMMENT '驳回人（user.id，role=admin）',
        \`reject_reason\` varchar(200) NULL COMMENT '驳回原因（必填，随通知发给打手）',
        \`wallet_transaction_id\` bigint unsigned NULL COMMENT '申请时的扣款流水（change_type=withdraw）；退回流水按幂等键 withdraw_reject:<id> 反查',
        \`idempotency_key\` varchar(64) NULL COMMENT '客户端重试幂等键（同一键返回首次结果，不重复扣款）',
        \`created_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
        \`updated_at\` datetime(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
        \`pending_worker_id\` bigint unsigned GENERATED ALWAYS AS (CASE WHEN \`status\` = 'pending' THEN \`worker_id\` ELSE NULL END) STORED COMMENT '仅 pending 行有值：唯一键保证"未结清申请数上限 1"',
        PRIMARY KEY (\`id\`),
        UNIQUE KEY \`UK_wr_pending_worker\` (\`pending_worker_id\`),
        UNIQUE KEY \`UK_wr_wallet_txn\` (\`wallet_transaction_id\`),
        UNIQUE KEY \`UK_wr_idem\` (\`idempotency_key\`),
        KEY \`IDX_wr_worker_status\` (\`worker_id\`, \`status\`),
        KEY \`IDX_wr_status_applied\` (\`status\`, \`applied_at\`)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='提现申请（申请即扣款 + 人工打款；驳回退回余额并写反向流水）'
    `);

    // ---------- 3) 配置行（is_high_security=1 → 仅超管可写）----------
    await queryRunner.query(
      `INSERT INTO \`system_setting\` (\`setting_key\`, \`cfg_value\`, \`description\`, \`is_high_security\`)
       VALUES (?, ?, ?, 1)
       ON DUPLICATE KEY UPDATE \`setting_key\` = \`setting_key\``,
      [
        WITHDRAW_CONFIG_KEY,
        // 形状与既有配置完全一致：cfg_value = {"value": <配置本体>}
        JSON.stringify({ value: WITHDRAW_CONFIG_DEFAULT }),
        WITHDRAW_CONFIG_DESCRIPTION,
      ],
    );

    // ---------- 4) 两个窄权限点（只授予 super_admin）----------
    for (const [code, name] of this.perms) {
      await queryRunner.query(
        `INSERT INTO \`permission\` (\`code\`, \`name\`, \`group_name\`, \`created_at\`)
         VALUES (?, ?, '提现', NOW(3))
         ON DUPLICATE KEY UPDATE \`name\` = VALUES(\`name\`), \`group_name\` = VALUES(\`group_name\`)`,
        [code, name],
      );
    }
    await queryRunner.query(
      `INSERT IGNORE INTO \`admin_role_permission\` (\`role_id\`, \`permission_id\`, \`created_at\`)
       SELECT r.id, p.id, NOW(3)
       FROM \`admin_role\` r CROSS JOIN \`permission\` p
       WHERE r.code = 'super_admin' AND p.code IN (?, ?)`,
      [this.perms[0][0], this.perms[1][0]],
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(
      `DELETE FROM \`admin_role_permission\` WHERE \`permission_id\` IN
         (SELECT id FROM \`permission\` WHERE code IN (?, ?))`,
      [this.perms[0][0], this.perms[1][0]],
    );
    await queryRunner.query('DELETE FROM `permission` WHERE code IN (?, ?)', [
      this.perms[0][0],
      this.perms[1][0],
    ]);
    await queryRunner.query('DELETE FROM `system_setting` WHERE `setting_key` = ?', [WITHDRAW_CONFIG_KEY]);
    await queryRunner.query('DROP TABLE IF EXISTS `withdraw_request`');
    await queryRunner.query('DROP TABLE IF EXISTS `worker_withdraw_account`');
  }
}
