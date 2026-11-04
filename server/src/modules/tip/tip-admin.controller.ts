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
import { parsePage, parsePageSize } from '../../common/pagination';
import { TipService } from './tip.service';

/** 管理端打赏（权限点 admin:tip:read 查看 / admin:tip:config 改金额配置） */
@ApiTags('admin/tips')
@Controller('admin/tips')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class TipAdminController {
  constructor(
    private readonly service: TipService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:tip:read')
  @ApiOperation({ summary: '权限点 admin:tip:read：打赏记录列表（含总额/今日额统计）' })
  list(
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
    @Query('keyword') keyword?: string,
    @Query('orderId') orderId?: string,
  ) {
    return this.service.adminList({
      page: parsePage(page),
      pageSize: parsePageSize(pageSize),
      keyword: keyword?.trim() || undefined,
      orderId: orderId?.trim() || undefined,
    });
  }

  @Get('config')
  @RequirePermission('admin:tip:read')
  @ApiOperation({ summary: '权限点 admin:tip:read：打赏金额配置' })
  config() {
    return this.service.config();
  }

  @Post('config')
  @RequirePermission('admin:tip:config')
  @ApiOperation({ summary: '权限点 admin:tip:config：修改预设金额/单次上限/单订单累计上限（操作留痕）' })
  async updateConfig(
    @Body() dto: { presets?: number[]; maxPerTip?: number; maxPerOrder?: number },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateConfig(dto);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'tip',
      action: 'tip:config',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(dto),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
