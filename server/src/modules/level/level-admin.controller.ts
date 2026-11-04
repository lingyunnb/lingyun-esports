import { Body, Controller, Get, Param, Post, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { LevelService } from './level.service';

/** 管理端用户等级（负责人需求 #7）：查看 + 手动调整（admin:user:level 默认仅超管，双重审计） */
@ApiTags('admin/users')
@Controller('admin/users')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class LevelAdminController {
  constructor(
    private readonly service: LevelService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get(':id')
  @RequirePermission('admin:user:read')
  @ApiOperation({ summary: '权限点 admin:user:read：用户等级详情（等级/等级名/累计消费）' })
  detail(@Param('id') id: string) {
    return this.service.adminUserDetail(id);
  }

  @Post(':id/level')
  @RequirePermission('admin:user:level')
  @ApiOperation({ summary: '权限点 admin:user:level（默认仅超管）：手动调整等级（user_level_log + 操作日志双重留痕）' })
  async setLevel(
    @Param('id') id: string,
    @Body() dto: { level: number; reason?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.adminSetLevel(user.userId, id, dto.level, dto.reason ?? '');
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'user-level',
      action: 'user:level:adjust',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        userId: id,
        fromLevel: (result as { fromLevel: number }).fromLevel,
        toLevel: (result as { toLevel: number }).toLevel,
        reason: dto.reason ?? '',
      }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
