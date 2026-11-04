import { Column, CreateDateColumn, Entity, PrimaryColumn } from 'typeorm';

/**
 * 受限充值管理员白名单（migration 1804000000000）。
 *
 * 语义（CLAUDE.md 结构规则 12）：
 * - 一条 = 一个**被授权进入"管理员态"的 admin 账号**（`user_id` 必须是 `role='admin'`）；
 * - `user_id` 就是主键 → **天然唯一约束**：同一个账号不可能被加两次；
 *   并发加两个不同账号时"总数 ≤ admin_limit"由服务层的**配置行行锁**串行化（见 recharge.service.ts）；
 * - 这张表白名单**只是"能不能进入受限会话"的名单**，权限点仍是 `recharge:review` / `recharge:grant`
 *   两个**专用窄权限**（不复用 `admin:*` 大权限）—— 名单 + 窄权限 = 双重收窄；
 * - 移出白名单 = 删除本行 + **立即吊销该账号全部 `kind='recharge'` 会话**（下一次请求 401 中文），
 *   但**绝不动它的 primary 会话**（管理员仍能在管理端正常工作）。
 */
@Entity('recharge_admin')
export class RechargeAdmin {
  /** admin 账号的 user.id（主键 = 唯一键：一个账号最多一条） */
  @PrimaryColumn({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 谁加进来的（超管 user.id）；审计用 */
  @Column({ name: 'granted_by', type: 'bigint', unsigned: true })
  grantedBy: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
