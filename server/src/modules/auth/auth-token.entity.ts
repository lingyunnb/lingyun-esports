import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/**
 * 会话种类（migration 1802000000000 建列；`recharge` 由 2026-10-06 充值功能复用同一列，无需改结构）：
 * - `primary` 普通登录（单设备互斥）
 * - `companion` 伴随会话（老板绑定打手账号签发，不顶 primary）
 * - `recharge` **受限充值管理员会话**（白名单 admin 账号 + 账密校验签发，不顶 primary）
 *
 * `recharge` 为什么复用同一列而不加新列：受限会话语义与 companion 完全同构
 * （非 primary → 只顶同族、TTL 12h、每请求实时校验、白名单默认拒绝），差别只在"绑的是什么"。
 * `varchar(16)` 容量足够（'recharge' 8 字符），故**不需要 migration 改结构** ——
 * 存量行 `DEFAULT 'primary'` 语义逐字节不变。
 */
export type AuthTokenKind = 'primary' | 'companion' | 'recharge';

/** JWT 会话登记（docs/02）：支撑登出/踢下线/refresh 轮换吊销 */
@Entity('auth_token')
@Index('IDX_auth_token_user_id', ['userId'])
@Index('IDX_auth_token_kind', ['userId', 'kind', 'revoked'])
export class AuthToken {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 64, unique: true })
  jti: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  @Column({ length: 16 })
  role: string;

  /**
   * 会话种类（migration 1802000000000）：存量行一律 `primary` → 单设备语义逐字节不变。
   *
   * **三类会话互不干扰**（实际实现在 `AuthService.issueTokens`，按 kind 分别吊销）：
   * - `primary` 登录/续期 = **只**顶掉该账号的其它 `primary`（`WHERE user_id=? AND kind='primary'`：
   *   登录 → revoked=2「账号已在其他设备登录」，续期 → revoked=1），**不触碰 companion/recharge**；
   *   **primary ↔ primary 仍互斥 = 单设备铁律不变**（只有 primary 行时，该过滤条件恒真、语句与历史等价）。
   * - `companion` 登录/续期 = **只**顶掉该账号的其它 `companion`，绝不触碰 primary（负责人定案③）。
   * - `recharge` 登录/续期 = **只**顶掉该账号的其它 `recharge`，绝不触碰 primary
   *   （负责人定案：管理员态"绝不顶掉 primary"——管理员在管理端的登录不受影响）。
   */
  @Column({ type: 'varchar', length: 16, default: 'primary' })
  kind: AuthTokenKind;

  /** companion 会话所属绑定 id（worker_identity_binding.id）；primary/recharge 为 NULL。守卫据此每请求实时校验绑定有效性 */
  @Column({ name: 'binding_id', type: 'bigint', unsigned: true, nullable: true })
  bindingId: string | null;

  @Column({ name: 'expire_at', type: 'datetime', precision: 3 })
  expireAt: Date;

  /** 1 已吊销（登出/轮换/踢下线） */
  @Column({ type: 'tinyint', default: 0 })
  revoked: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
