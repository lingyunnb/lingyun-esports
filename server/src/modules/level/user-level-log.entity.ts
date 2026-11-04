import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn } from 'typeorm';

/** 等级变更日志（docs/06 补充）：管理端手动调整必须留痕（操作人/时间/原等级/新等级/原因） */
@Entity('user_level_log')
@Index('IDX_ull_user', ['userId'])
export class UserLevelLog {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 操作管理员（手动调整时；自动升级为 null） */
  @Column({ name: 'admin_user_id', type: 'bigint', unsigned: true, nullable: true })
  adminUserId: string | null;

  @Column({ name: 'from_level', type: 'tinyint' })
  fromLevel: number;

  @Column({ name: 'to_level', type: 'tinyint' })
  toLevel: number;

  @Column({ length: 255, default: '' })
  reason: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
