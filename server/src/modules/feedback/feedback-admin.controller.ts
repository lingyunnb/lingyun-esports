import { Body, Controller, Get, Post, Param, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { FeedbackService } from './feedback.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 管理端意见反馈（admin:feedback:read：查看/处理留痕） */
@ApiTags('admin/feedback')
@Controller('admin/feedback')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class FeedbackAdminController {
  constructor(
    private readonly service: FeedbackService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:feedback:read')
  @ApiOperation({ summary: '权限点 admin:feedback:read：反馈列表（分页/状态）' })
  list(@Query('page') page?: string, @Query('pageSize') pageSize?: string, @Query('status') status?: string) {
    const st = status === undefined || status === '' ? undefined : Number(status);
    return this.service.adminList(parsePage(page), parsePageSize(pageSize), st);
  }

  @Post(':id/handle')
  @RequirePermission('admin:feedback:read')
  @ApiOperation({ summary: '权限点 admin:feedback:read：处理反馈（标记已处理+备注，操作留痕）' })
  async handle(@Param('id') id: string, @Body() dto: { remark?: string }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.handle(user.userId, id, dto.remark ?? '');
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'feedback',
      action: 'feedback:handle',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ feedbackId: id, remark: dto.remark ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
