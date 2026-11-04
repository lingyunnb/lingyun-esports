import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 系统设置（docs/02）：key-value JSON 配置；is_high_security=1 的最高安全配置仅超级管理员可改 */
@Entity('system_setting')
export class SystemSetting {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'setting_key', length: 64, unique: true })
  settingKey: string;

  @Column({ name: 'cfg_value', type: 'json' })
  cfgValue: Record<string, unknown>;

  @Column({ length: 255, default: '' })
  description: string;

  /** 1 = 最高安全配置（普通管理员不可修改，docs/04） */
  @Column({ name: 'is_high_security', type: 'tinyint', default: 0 })
  isHighSecurity: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
