import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 第三方登录绑定（QQ 登录，2026-10-10；migration 1809000000000）。
 *
 * 设计要点：
 * - **唯一键 `UK_user_oauth_provider_openid(provider, openid)`** 是"一个第三方账号只能绑一个平台账号"的
 *   权威约束（并发下服务层的"先查后插"必然被绕过，唯一索引才是兜底）；
 * - `openid` 长度 64：QQ 的 openid 是 32 位十六进制字符串；留足余量给将来（如微信 28 位、以及
 *   某些场景下的更长 openid），同时 utf8mb4 下不会撑爆唯一索引；
 * - `unionid` 可空：同一开发者在 QQ 互联 + 微信开放平台打通时才有值（`oauth2.0/me?unionid=1`），
 *   当前只**存下来备将来跨应用合并**，不参与登录判定（判定只认 `(provider, openid)`）；
 * - `provider` 预留 `wechat`（表结构与服务层都按"多 provider"写，不写死 qq）。
 */
@Entity('user_oauth')
@Index('UK_user_oauth_provider_openid', ['provider', 'openid'], { unique: true })
@Index('IDX_user_oauth_user_id', ['userId'])
export class UserOAuth {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 第三方平台标识：`qq`（当前）/ `wechat`（预留） */
  @Column({ length: 16 })
  provider: string;

  /** 第三方平台的用户唯一标识（**只信服务端复核结果**，绝不信客户端入参） */
  @Column({ length: 64 })
  openid: string;

  /** 同开发者的跨应用统一 id（可选；`oauth2.0/me?unionid=1` 才有） */
  @Column({ type: 'varchar', length: 64, nullable: true })
  unionid: string | null;

  /** 平台账号 id（user.id；主体 id 只来自 JWT sub） */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
