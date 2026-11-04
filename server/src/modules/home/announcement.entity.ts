import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 公告/通知：发布、置顶、排序、显隐，管理端配置 */
@Entity('announcement')
@Index('IDX_announcement_pinned_sort', ['visible', 'pinned', 'sortOrder'])
export class Announcement {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 100 })
  title: string;

  @Column({ type: 'varchar', length: 500, default: '' })
  summary: string;

  @Column({ type: 'text' })
  content: string;

  /** 1 置顶 / 0 普通 */
  @Column({ type: 'tinyint', default: 0 })
  pinned: number;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 显示 / 2 隐藏 */
  @Column({ type: 'tinyint', default: 1 })
  visible: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
