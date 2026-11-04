import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';

import { Game } from '../game/game.entity';
import { UserGameAccount } from './user-game-account.entity';

/**
 * 游戏 ID 的校验口径（**全项目唯一一处**）：与 `CreateOrderDto.gamePlayerId` 逐字一致 ——
 * 下单页能填的字符集，就是"记住游戏 ID"能存的字符集；两处各写一份必然漂移。
 */
export const GAME_PLAYER_ID_PATTERN = /^[A-Za-z0-9一-龥_-]+$/;
export const GAME_PLAYER_ID_MESSAGE = '游戏ID仅支持字母/数字/中文/下划线/短横线';

/** 我保存过的游戏账号（`GET /user/game-accounts` 的一行） */
export interface GameAccountItem {
  gameId: string;
  gameName: string;
  gamePlayerId: string;
  gameZone: string | null;
  updatedAt: Date;
}

/**
 * 「记住我的游戏 ID」（负责人 2026-10-15）
 *
 * 设计要点（**客户端不需要调 POST 来保存**）：
 * - 下单成功时服务端自动 upsert（`OrderService.rememberGameAccountBestEffort`）；
 * - 本服务提供 `GET`（回填）与 `POST`（手动保存），两者与自动写入**共用同一个 `upsert()`**。
 *
 * ## 为什么用 `INSERT … ON DUPLICATE KEY UPDATE`（而不是"先查再插/再更"）
 *
 * 唯一键是 `UK_uga_user_game (user_id, game_id)`：一个 upsert 语句同时覆盖"首次"与"换号"两种情况，
 * **并发安全**（同一用户同一游戏同时两次写入：一次插入、一次更新，不会出现两行，也不会报错），
 * 且与既有 `worker_stats` 的累计写法（`ON DUPLICATE KEY UPDATE`）同一种姿势。
 *
 * ## 写失败的处理
 *
 * 手工保存失败 → 中文 400（用户看得到，能重试）；
 * 下单触发的自动保存失败 → **只告警、绝不影响下单**（见 `OrderService`，best-effort）。
 * 两条路径共用本方法，所以"什么算合法值"永远一致，差的只是"失败后怎么办"。
 */
@Injectable()
export class GameAccountService {
  private readonly logger = new Logger('GameAccount');

  constructor(
    @InjectRepository(UserGameAccount) private readonly repo: Repository<UserGameAccount>,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /**
   * 我保存过的游戏账号（按最近使用排序，**只回本人的行**）
   *
   * `gameName` 走 LEFT JOIN：游戏被删除时名字退化为空串（不因此丢掉用户填过的 ID ——
   * 那可是他下次下单要用的东西，宁可名字空着也不能消失）。
   */
  async list(userId: string): Promise<GameAccountItem[]> {
    const rows = await this.dataSource.query<
      Array<{ gameId: string; gameName: string | null; gamePlayerId: string; gameZone: string | null; updatedAt: Date }>
    >(
      `SELECT a.game_id AS gameId, g.name AS gameName, a.game_player_id AS gamePlayerId,
              a.game_zone AS gameZone, a.updated_at AS updatedAt
         FROM user_game_account a
         LEFT JOIN game g ON g.id = a.game_id
        WHERE a.user_id = ?
        ORDER BY a.updated_at DESC, a.id DESC`,
      [userId],
    );
    return rows.map((r) => ({
      gameId: String(r.gameId),
      gameName: String(r.gameName ?? ''),
      gamePlayerId: String(r.gamePlayerId ?? ''),
      gameZone: r.gameZone == null ? null : String(r.gameZone),
      updatedAt: r.updatedAt,
    }));
  }

  /**
   * upsert 一条游戏账号（`UNIQUE(user_id, game_id)` 幂等）
   *
   * @param opts.skipGameCheck 下单路径传 `true`：`gameId` 来自**刚刚落库的订单**（服务端自己写的），
   *   没必要再查一次 `game` 表（那是纯粹多一次往返）；手工保存走默认 `false`（必须校验游戏存在）。
   */
  async upsert(
    userId: string,
    dto: { gameId: string; gamePlayerId: string; gameZone?: string | null },
    opts: { skipGameCheck?: boolean } = {},
  ): Promise<GameAccountItem> {
    const gameId = String(dto.gameId ?? '').trim();
    if (!/^\d+$/.test(gameId)) throw new BadRequestException('游戏参数不合法');

    const gamePlayerId = String(dto.gamePlayerId ?? '').trim();
    if (!gamePlayerId) throw new BadRequestException('请填写游戏 ID');
    if (gamePlayerId.length > 64) throw new BadRequestException('游戏 ID 最多 64 个字符');
    if (!GAME_PLAYER_ID_PATTERN.test(gamePlayerId)) throw new BadRequestException(GAME_PLAYER_ID_MESSAGE);

    const gameZone = String(dto.gameZone ?? '').trim() || null;
    if (gameZone && gameZone.length > 32) throw new BadRequestException('游戏分区最多 32 个字符');

    let gameName = '';
    if (!opts.skipGameCheck) {
      const game = await this.dataSource
        .getRepository(Game)
        .findOne({ where: { id: gameId }, select: { id: true, name: true } });
      if (!game) throw new BadRequestException('游戏不存在');
      gameName = game.name;
    }

    // 用同一个 JS 时间写入与回显：返回的 `updatedAt` 与库里存的**逐毫秒一致**（不必再读一次库）
    const now = new Date();
    await this.dataSource.query(
      `INSERT INTO \`user_game_account\` (\`user_id\`, \`game_id\`, \`game_player_id\`, \`game_zone\`, \`updated_at\`)
       VALUES (?, ?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
         \`game_player_id\` = ?,
         \`game_zone\` = ?,
         \`updated_at\` = ?`,
      [userId, gameId, gamePlayerId, gameZone, now, gamePlayerId, gameZone, now],
    );

    return { gameId, gameName, gamePlayerId, gameZone, updatedAt: now };
  }

  /** 只读：取某用户某游戏的账号（下单页回填单个游戏时用；不存在返回 null） */
  async find(userId: string, gameId: string): Promise<UserGameAccount | null> {
    return this.repo.findOne({ where: { userId, gameId: String(gameId) } });
  }

  /**
   * 下单成功后的自动写入（**失败只告警，绝不影响下单**）
   *
   * 由 `OrderService.createOrder` 在**事务提交之后**调用 —— 位置刻意放在事务外：
   * 任何失败（约束、连接、锁等待）都不可能回滚一笔**已经提交**的订单。
   * 调用侧仍再包一层 try/catch 兜底（本方法自身也吞异常），确保"记住游戏 ID"这件事
   * 在任何情况下都不会变成"下单失败"。
   */
  async rememberBestEffort(
    userId: string,
    input: { gameId: string; gamePlayerId: string | null; gameZone: string | null },
  ): Promise<void> {
    const gamePlayerId = String(input.gamePlayerId ?? '').trim();
    if (!gamePlayerId) return; // 订单没带游戏 ID（历史数据）→ 不写空值，避免下次回填到一片空白
    try {
      await this.upsert(
        userId,
        { gameId: input.gameId, gamePlayerId, gameZone: input.gameZone },
        { skipGameCheck: true },
      );
    } catch (e) {
      this.logger.warn(
        `记住游戏 ID 失败（不影响下单成功）user=${userId} game=${input.gameId}: ${(e as Error).message}`,
      );
    }
  }
}
