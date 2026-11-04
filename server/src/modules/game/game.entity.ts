import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 游戏目录（docs/02、docs/13）：**平台只做「和平精英 / 三角洲行动」，手游与端游各一条游戏行**，新增游戏走后台配置，客户端零硬编码 */
@Entity('game')
@Index('IDX_game_status_sort', ['status', 'sortOrder'])
export class Game {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ length: 32, unique: true })
  code: string;

  @Column({ length: 32 })
  name: string;

  @Column({ name: 'icon_media_id', type: 'bigint', unsigned: true, nullable: true })
  iconMediaId: string | null;

  @Column({ name: 'banner_media_id', type: 'bigint', unsigned: true, nullable: true })
  bannerMediaId: string | null;

  @Column({ name: 'sort_order', type: 'int', default: 0 })
  sortOrder: number;

  /** 1 上架 / 2 下架（下架后 public 接口不可见） */
  @Column({ type: 'tinyint', default: 1 })
  status: number;

  @Column({ name: 'config_json', type: 'json', nullable: true })
  configJson: Record<string, unknown> | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
