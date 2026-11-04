import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 官方自营馆（负责人 2026-10-04）：首页「祁连山官方」卡片的数据源。
 *
 * 之前是客户端写死的假数据（评分 4.9 / 2,847 单），现在改为管理端维护：
 * 名称、副标题、简介、**封面图**、角标、评分、单量、排序、上下架全部可在后台改。
 */
@Entity('club')
@Index('IDX_club_status_sort', ['status', 'sortOrder'])
export class Club {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 40 })
  name: string;

  /** 副标题（如「和平精英分部」） */
  @Column({ name: 'sub_title', length: 64, default: '' })
  subTitle: string;

  /** 简介（1-2 行） */
  @Column({ length: 255, default: '' })
  description: string;

  /** 封面图媒体 id（管理端上传；空则客户端用渐变色块 + 图标兜底） */
  @Column({ name: 'cover_media_id', type: 'bigint', unsigned: true, nullable: true })
  coverMediaId: string | null;

  /** 角标文案（默认「官方」） */
  @Column({ length: 16, default: '官方' })
  badge: string;

  /** 评分（展示用，管理端维护） */
  @Column({ type: 'decimal', precision: 3, scale: 1, default: 5.0 })
  rating: string;

  /** 累计单量（展示用，管理端维护） */
  @Column({ name: 'order_count', type: 'int', default: 0 })
  orderCount: number;

  /** 关联分部（可空；用于「进入该分部」跳转） */
  @Column({ name: 'division_id', type: 'bigint', unsigned: true, nullable: true })
  divisionId: string | null;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 上架 / 2 下架 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
