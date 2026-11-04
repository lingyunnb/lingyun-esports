import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 商品分类（docs/02）：按游戏隔离，parent_id 预留层级 */
@Entity('category')
@Index('IDX_category_game_status', ['gameId', 'status'])
export class Category {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'game_id', type: 'bigint', unsigned: true })
  gameId: string;

  @Column({ name: 'parent_id', type: 'bigint', unsigned: true, nullable: true })
  parentId: string | null;

  @Column({ length: 32 })
  name: string;

  @Column({ name: 'icon_media_id', type: 'bigint', unsigned: true, nullable: true })
  iconMediaId: string | null;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 启用 / 2 停用 */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
