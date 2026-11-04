import { Column, CreateDateColumn, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/** 游戏级扩展配置（docs/02、docs/13）：如 CODM 段位/区服/模式列表，客户端按 key 拉取渲染 */
@Entity('game_config')
@Index('UQ_game_config_game_key', ['gameId', 'cfgKey'], { unique: true })
export class GameConfig {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  @Column({ name: 'game_id', type: 'bigint', unsigned: true })
  gameId: string;

  @Column({ name: 'cfg_key', length: 32 })
  cfgKey: string;

  @Column({ name: 'cfg_value', type: 'json' })
  cfgValue: unknown;

  @Column({ type: 'varchar', length: 100, nullable: true })
  remark: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'datetime', precision: 3 })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
