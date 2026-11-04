import { moneyTransformer } from '../../common/money.transformer';
import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

export type UserRole = 'user' | 'worker' | 'admin';

/** 统一账号表（docs/02）：老板/工作端/管理员三端账号，role 区分登录分流与守卫 */
@Entity('user')
@Index('IDX_user_role_status', ['role', 'status'])
// 邮箱唯一（仅非空唯一：MySQL 唯一索引对 NULL 不去重，未绑邮箱的老用户不受影响）
@Index('UQ_user_email', ['email'], { unique: true })
export class User {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 32, unique: true })
  username: string;

  /** 对外展示 ID（唯一，默认不可改，见 docs/待确认事项） */
  @Column({ length: 20, unique: true })
  uid: string;

  @Column({ name: 'password_hash', length: 100, select: false })
  passwordHash: string;

  @Column({ length: 32, default: '' })
  nickname: string;

  /**
   * 邮箱（负责人 2026-10-05：邮箱验证替代短信验证）：**可选**，NULL=未绑定。
   * 唯一索引 `UQ_user_email` —— MySQL 唯一索引对 NULL 不去重，故未绑定邮箱的老用户可无限多行。
   */
  @Column({ type: 'varchar', length: 120, nullable: true })
  email: string | null;

  /** 邮箱验证通过时间（NULL=未验证）；注册带邮箱验码通过 / 找回密码验码通过时写入 */
  @Column({ name: 'email_verified_at', type: 'datetime', precision: 3, nullable: true })
  emailVerifiedAt: Date | null;

  /**
   * 陪玩介绍（负责人 2026-10-03 建立；**2026-10-17 改定：由打手自己写**，管理端保留兜底改写）
   *
   * - 打手自写：`PUT /worker/profile`（2–120 字、屏蔽手机号/微信号/QQ 号，
   *   规则唯一实现 `modules/worker/worker-intro.rules.ts`）
   * - 管理端兜底：`PUT /admin/workers/:id/players-profile`（0–200 字，语义未变）
   *
   * 列长 `varchar(200)` 是为管理端兜底留的余量（打手侧上限 120 直接落在校验里，不改列宽）；
   * 「找陪玩」列表只展示 名字 + 介绍。
   */
  @Column({ length: 200, default: '' })
  intro: string;

  /**
   * 介绍最后修改人（**管理员 id，可审计**）：`NULL` = 不是管理端写的（打手自写时置 NULL）。
   * 管理端「陪玩资料」页据此区分"打手自己写"与"管理员兜底改过"。
   */
  @Column({ name: 'intro_updated_by', type: 'bigint', unsigned: true, nullable: true })
  introUpdatedBy: string | null;

  @Column({ name: 'avatar_media_id', type: 'bigint', unsigned: true, nullable: true })
  avatarMediaId: string | null;

  @Column({ name: 'background_media_id', type: 'bigint', unsigned: true, nullable: true })
  backgroundMediaId: string | null;

  @Column({ length: 16 })
  role: UserRole;

  /** 1 正常 / 2 封禁（禁登录） */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  /** 封禁截止时间（NULL=永久封禁；到期后登录/请求时自动解封） */
  @Column({ name: 'banned_until', type: 'datetime', precision: 3, nullable: true })
  bannedUntil: Date | null;

  /**
   * 封禁原因（2026-10-16 新增，migration `1816000000000`）：**只有在 `status=2` 时才有值**，
   * 解封（含到期自动解封）一律清空 —— 否则残留旧原因会误导客户端那句
   * 「账号已被封禁：<原因>（解封时间：…）」（唯一构造实现：`modules/auth/account-ban.check.ts`）。
   */
  @Column({ name: 'ban_reason', type: 'varchar', length: 200, nullable: true })
  banReason: string | null;

  /** 等级 1-5：累计实际消费自动升级（只升不降），仅服务端可写（docs/06 补充） */
  @Column({ type: 'tinyint', default: 1 })
  level: number;

  /** 累计实际消费金额（元）：下单成功累加、退款回退（等级升级唯一依据，非余额） */
  @Column({ name: 'total_spent', type: 'decimal', precision: 14, scale: 2, default: 0, transformer: moneyTransformer })
  totalSpent: string;

  @Column({ name: 'last_login_at', type: 'datetime', precision: 3, nullable: true })
  lastLoginAt: Date | null;

  @Column({ name: 'last_login_ip', type: 'varchar', length: 64, nullable: true })
  lastLoginIp: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
