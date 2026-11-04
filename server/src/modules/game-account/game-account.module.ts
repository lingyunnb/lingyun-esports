import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { Game } from '../game/game.entity';
import { GameAccountController } from './game-account.controller';
import { GameAccountService } from './game-account.service';
import { UserGameAccount } from './user-game-account.entity';

/**
 * 游戏账号簿（负责人 2026-10-15「记住我的游戏 ID」）
 *
 * 对外暴露三处：
 * - `GET/POST /user/game-accounts`（本模块控制器，老板侧）；
 * - **`OrderService` 下单成功后自动 upsert**（`OrderModule` imports 本模块，拿 `GameAccountService`）。
 *
 * `Game` 实体在本模块注册：手工保存要校验"游戏存在"，且 `GET` 要带回 `gameName`。
 */
@Module({
  imports: [TypeOrmModule.forFeature([UserGameAccount, Game])],
  controllers: [GameAccountController],
  providers: [GameAccountService],
  exports: [GameAccountService],
})
export class GameAccountModule {}
