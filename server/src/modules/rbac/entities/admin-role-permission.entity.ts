import { Column, CreateDateColumn, Entity, PrimaryColumn } from 'typeorm';

/** 角色-权限点关联（docs/02），联合主键 */
@Entity('admin_role_permission')
export class AdminRolePermission {
  @PrimaryColumn({ name: 'role_id', type: 'bigint', unsigned: true })
  roleId: string;

  @PrimaryColumn({ name: 'permission_id', type: 'bigint', unsigned: true })
  permissionId: string;

  @Column({ name: 'granted_by', type: 'bigint', unsigned: true, nullable: true })
  grantedBy: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
