import { Body, Controller, Get, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
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
import { RefundService } from './refund.service';

/** 管理端退款审批（权限点 admin:refund:read 查看 / admin:refund:handle 审批） */
@ApiTags('admin/refunds')
@Controller('admin/refunds')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class RefundAdminController {
  constructor(
    private readonly service: RefundService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:refund:read')
  @ApiOperation({ summary: '权限点 admin:refund:read：退款申请列表（待处理/已通过/已驳回 + 数量统计）' })
  list(@Query('status') status?: string, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.adminList({
      status: status?.trim() || undefined,
      page: parsePage(page),
      pageSize: parsePageSize(pageSize),
    });
  }

  @Post(':id/handle')
  @RequirePermission('admin:refund:handle')
  @ApiOperation({ summary: '权限点 admin:refund:handle：审批（approve 原路退回余额 / reject 必填理由）' })
  async handle(
    @Param('id') id: string,
    @Body() dto: { action: 'approve' | 'reject'; remark?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.adminHandle(
      user.userId,
      id,
      { action: dto.action, remark: dto.remark },
      { ip: req.ip ?? '', requestId: req.requestId },
    );
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'refund',
      action: `refund:${dto.action}`,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ refundId: id, action: dto.action, remark: dto.remark ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
