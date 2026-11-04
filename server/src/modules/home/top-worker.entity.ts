import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 首页优秀打手展示：仅展示适合公开的信息（不暴露工作端内部数据） */
@Entity('top_worker')
@Index('IDX_top_worker_visible_sort', ['visible', 'sortOrder'])
export class TopWorker {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 关联 worker 档案（仅取展示字段） */
  @Column({ name: 'worker_id', type: 'bigint', unsigned: true, unique: true })
  workerId: string;

  /** 展示昵称（快照，可单独修饰） */
  @Column({ name: 'display_name', length: 32 })
  displayName: string;

  /** 头像 URL（历史兼容字段；media 优先，阶段 13 起管理端改传图） */
  @Column({ name: 'avatar_url', type: 'varchar', length: 500, nullable: true })
  avatarUrl: string | null;

  /** 头像媒体 id（阶段 13 media 模块，优先于 avatar_url） */
  @Column({ name: 'avatar_media_id', type: 'bigint', unsigned: true, nullable: true })
  avatarMediaId: string | null;

  /** 擅长游戏/项目（展示文案） */
  @Column({ length: 100, default: '' })
  skills: string;

  /** 服务评价（如 4.9） */
  @Column({ type: 'decimal', precision: 2, scale: 1, default: 5.0 })
  rating: string;

  /** 完成单量（展示值，由管理端维护） */
  @Column({ name: 'completed_orders', type: 'int', default: 0 })
  completedOrders: number;

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
