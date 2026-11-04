import { Column, CreateDateColumn, Entity, PrimaryGeneratedColumn } from 'typeorm';

/** 权限点全量清单（docs/04 种子数据），code 如 admin:wallet:grant */
@Entity('permission')
export class Permission {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 64, unique: true })
  code: string;

  @Column({ length: 32 })
  name: string;

  @Column({ name: 'group_name', length: 32, default: '' })
  groupName: string;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;
}
