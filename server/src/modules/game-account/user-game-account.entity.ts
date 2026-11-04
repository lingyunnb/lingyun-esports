import { Column, Entity, Index, PrimaryGeneratedColumn, UpdateDateColumn } from 'typeorm';

/**
 * 老板保存过的游戏账号（migration `1813000000000`，负责人 2026-10-15「记住我的游戏 ID 这个也做」）
 *
 * **一行 = 一个游戏**（`UK_uga_user_game (user_id, game_id)`）：同一游戏换号/换区是**更新同一行**，
 * 客户端永远只面对"这个游戏记的是哪个号"这一个答案。
 *
 * 写入有且只有两条路径，且**共用同一个 `upsert()`**：
 * 1. 下单成功 → 服务端自动写入（`OrderService.rememberGameAccountBestEffort`，best-effort）；
 * 2. `POST /user/game-accounts` → 用户手工保存。
 *
 * 因此客户端**不需要**在"下单前先保存一次"——只调 `GET /user/game-accounts` 做回填即可。
 */
@Entity('user_game_account')
@Index('UK_uga_user_game', ['userId', 'gameId'], { unique: true })
export class UserGameAccount {
  @PrimaryGeneratedColumn({ type: 'bigint', unsigned: true })
  id: string;

  /** 老板账号（`user.id`，role=user）—— 只来自 JWT sub */
  @Column({ name: 'user_id', type: 'bigint', unsigned: true })
  userId: string;

  /** 游戏（`game.id`） */
  @Column({ name: 'game_id', type: 'bigint', unsigned: true })
  gameId: string;

  /** 游戏 ID（与 `order.game_player_id` 同长度同校验正则） */
  @Column({ name: 'game_player_id', type: 'varchar', length: 64 })
  gamePlayerId: string;

  /** 游戏分区（QQ 区/微信区…；空串按未填处理 = NULL） */
  @Column({ name: 'game_zone', type: 'varchar', length: 32, nullable: true })
  gameZone: string | null;

  /** 最近一次使用/保存时间（下单自动 upsert 与手工保存都会前进） */
  @UpdateDateColumn({ name: 'updated_at', type: 'datetime', precision: 3 })
  updatedAt: Date;
}
