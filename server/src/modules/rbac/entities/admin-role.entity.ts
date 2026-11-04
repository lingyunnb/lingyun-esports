import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 管理员角色（docs/02）：super_admin 为内置角色，不可删改 */
@Entity('admin_role')
export class AdminRole {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 32, unique: true })
  code: string;

  @Column({ length: 32 })
  name: string;

  /** 1 内置（super_admin）/ 0 自定义 */
  @Column({ name: 'is_builtin', type: 'tinyint', default: 0 })
  isBuiltin: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
