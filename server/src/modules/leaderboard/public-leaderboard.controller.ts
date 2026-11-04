import { Controller, Get, Query } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';

import { LeaderboardService } from './leaderboard.service';

/**
 * 排行榜（公开，老板端顶部导航「排行榜」使用）
 *
 * 展示内容遵循负责人硬规则：
 * - **每行只有 名次 + 头像(昵称首字) + 名字 + 数值**，不写分部、不带"明星/单考/空闲"等标签
 * - 分部由上方胶囊决定（?divisionId=），不传为全站榜
 * - 仅返回公开字段（昵称/工号/单数/金额/名次），不含手机号等隐私
 *
 * ⚠️ 2026-10-16（任务②）：字段裁剪与周期解析搬到了 `LeaderboardService.publicBoard()`
 * （**服务层唯一实现**），只为让 `GET /public/home` 的 `leaderboard` 子块复用同一段实现，
 * 而不是复制一份"首页版榜单字段"。响应形状**逐字节未变**。
 */
@ApiTags('public')
@Controller('public')
export class PublicLeaderboardController {
  constructor(private readonly service: LeaderboardService) {}

  @Get('leaderboard')
  @ApiOperation({ summary: '公开：排行榜（kind=week|month；divisionId 取分部榜，不传为全站榜）' })
  board(@Query('kind') kind?: string, @Query('divisionId') divisionId?: string, @Query('period') period?: string) {
    return this.service.publicBoard({
      kind,
      divisionId: divisionId?.trim() || undefined,
      period,
    });
  }
}
