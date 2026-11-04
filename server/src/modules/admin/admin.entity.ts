import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 管理员档案（docs/02）：关联 user.id 与 admin_role.id */
@Entity('admin')
export class Admin {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'user_id', type: 'bigint', unsigned: true, unique: true })
  userId: string;

  @Column({ name: 'role_id', type: 'bigint', unsigned: true })
  roleId: string;

  /** 1 正常 / 2 禁用 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  /** 1=所有者：独占「封禁/注销管理员账号」操作（负责人指定，仅 kslingyun） */
  @Column({ name: 'is_owner', type: 'tinyint', default: 0 })
  isOwner: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
