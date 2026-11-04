import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 登录日志（docs/02）：成功/失败全记录，供安全审计与暴力破解分析 */
@Entity('login_log')
@Index('IDX_login_log_user_id', ['userId'])
@Index('IDX_login_log_ip_created', ['ip', 'createdAt'])
export class LoginLog {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_type', length: 16 })
  userType: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true, nullable: true })
  userId: string | null;

  @Column({ length: 32 })
  username: string;

  @Column({ type: 'varchar', length: 64, nullable: true })
  ip: string | null;

  @Column({ name: 'user_agent', type: 'varchar', length: 255, nullable: true })
  userAgent: string | null;

  /** success / fail */
  @Column({ length: 16 })
  result: string;

  @Column({ name: 'fail_reason', type: 'varchar', length: 100, nullable: true })
  failReason: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
