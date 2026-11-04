import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { LeaderboardService, currentPeriod } from './leaderboard.service';

/** 工作端榜单（M7）：周榜/月榜 + 我的排名 */
@ApiTags('worker/leaderboard')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class LeaderboardWorkerController {
  constructor(private readonly service: LeaderboardService) {}

  @Get('leaderboard')
  @ApiOperation({ summary: '榜单（week 周榜 / month 月榜，默认本周；divisionId 取分部榜，不传为全站榜）+ 我的排名' })
  async board(
    @CurrentUser() user: { userId: string },
    @Query('period') period?: string,
    @Query('kind') kind?: string,
    @Query('divisionId') divisionId?: string,
  ) {
    const p = period || currentPeriod(kind === 'month' ? 'month' : 'week');
    const list = await this.service.list(p, divisionId);
    const workerId = await this.service.workerIdByUserId(user.userId);
    const my = workerId ? await this.service.myEntry(workerId, p) : null;
    return { period: p, divisionId: divisionId ?? null, list, me: my };
  }

  @Get('my-stats')
  @ApiOperation({ summary: '我的实时统计（完成单数/总金额）' })
  async myStats(@CurrentUser() user: { userId: string }) {
    const workerId = await this.service.workerIdByUserId(user.userId);
    if (!workerId) return null;
    return this.service.workerStats(workerId);
  }
}

/** 管理端榜单（M7）：查看/重算/人工调整（调整留痕 + 操作日志） */
@ApiTags('admin/leaderboard')
@Controller('admin/leaderboard')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class LeaderboardAdminController {
  constructor(
    private readonly service: LeaderboardService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:leaderboard:read')
  @ApiOperation({ summary: '权限点 admin:leaderboard:read：榜单列表' })
  list(@Query('period') period: string) {
    return this.service.list(period);
  }

  @Get('adjustments')
  @RequirePermission('admin:leaderboard:read')
  @ApiOperation({ summary: '权限点 admin:leaderboard:read：调整记录' })
  adjustments(@Query('period') period: string) {
    return this.service.adjustments(period);
  }

  @Post('recalc')
  @RequirePermission('admin:leaderboard:read')
  @ApiOperation({ summary: '权限点 admin:leaderboard:read：重算榜单快照' })
  recalc(@Body() dto: { period: string }) {
    return this.service.recalc(dto.period);
  }

  @Post('adjust')
  @RequirePermission('admin:leaderboard:adjust')
  @ApiOperation({ summary: '权限点 admin:leaderboard:adjust（默认仅超管）：人工调整（留痕）' })
  async adjust(@Body() dto: { period: string; workerId: string; amountDelta: number; reason?: string }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.adjust(dto.period, dto.workerId, dto.amountDelta, dto.reason ?? '', user.userId);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'leaderboard',
      action: 'leaderboard:adjust',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(dto),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
