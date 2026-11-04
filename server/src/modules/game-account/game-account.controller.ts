import { Body, Controller, Get, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { IsOptional, IsString, Length, Matches } from 'class-validator';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { GAME_PLAYER_ID_MESSAGE, GAME_PLAYER_ID_PATTERN, GameAccountService } from './game-account.service';

/** 保存（upsert）一条游戏账号请求体 */
export class SaveGameAccountDto {
  @ApiProperty({ description: '游戏 ID（game.id）' })
  @IsString()
  @Matches(/^\d+$/, { message: '游戏参数不合法' })
  gameId!: string;

  @ApiProperty({ description: '游戏 ID（角色名/编号，与下单页同一字符集与长度）' })
  @IsString()
  @Length(1, 64, { message: '游戏 ID 长度需为 1-64' })
  @Matches(GAME_PLAYER_ID_PATTERN, { message: GAME_PLAYER_ID_MESSAGE })
  gamePlayerId!: string;

  @ApiPropertyOptional({ description: '游戏分区（如 qq / wechat；选填）' })
  @IsOptional()
  @IsString()
  @Length(0, 32, { message: '游戏分区最多 32 个字符' })
  gameZone?: string;
}

/**
 * 「记住我的游戏 ID」（负责人 2026-10-15）
 *
 * **关键设计：客户端不需要调 POST 来保存。**
 * 下单成功时服务端已经自动 upsert（`OrderService` → `GameAccountService.rememberBestEffort`），
 * 客户端只需在进下单页时调一次 `GET` 做回填。`POST` 保留给"想提前把号存好"的场景
 * （例如还没下过单、或想改一下之前的游戏 ID）。
 *
 * 归属铁律：`user_id` **只从 JWT sub 取**，请求体里的任何用户标识一律不看（docs/04）。
 * 打手态（companion 受限会话）默认被守卫挡掉（`/user/*` 不在允许清单）—— 游戏账号是老板侧能力。
 */
@ApiTags('user/game-accounts')
@Controller('user/game-accounts')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class GameAccountController {
  constructor(private readonly service: GameAccountService) {}

  @Get()
  @ApiOperation({ summary: '我保存过的游戏账号（下单页回填用；按下单/保存时间倒序）' })
  list(@CurrentUser() user: { userId: string }) {
    return this.service.list(user.userId);
  }

  @Post()
  @ApiOperation({ summary: '保存（upsert）一条游戏账号：同一游戏只有一行，换号即更新' })
  save(@CurrentUser() user: { userId: string }, @Body() dto: SaveGameAccountDto) {
    return this.service.upsert(user.userId, {
      gameId: dto.gameId,
      gamePlayerId: dto.gamePlayerId,
      gameZone: dto.gameZone,
    });
  }
}
