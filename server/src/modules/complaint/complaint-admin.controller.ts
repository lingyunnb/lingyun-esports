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
import { ComplaintService } from './complaint.service';

/** 管理端投诉工单（权限点 admin:complaint:read 查看 / admin:complaint:handle 处理） */
@ApiTags('admin/complaints')
@Controller('admin/complaints')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class ComplaintAdminController {
  constructor(
    private readonly service: ComplaintService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:complaint:read')
  @ApiOperation({ summary: '权限点 admin:complaint:read：投诉工单列表（状态/对象筛选 + 数量统计）' })
  list(
    @Query('status') status?: string,
    @Query('targetType') targetType?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.adminList({
      status: status?.trim() || undefined,
      targetType: targetType?.trim() || undefined,
      page: parsePage(page),
      pageSize: parsePageSize(pageSize),
    });
  }

  @Get(':id')
  @RequirePermission('admin:complaint:read')
  @ApiOperation({ summary: '权限点 admin:complaint:read：工单详情（含截图媒体）' })
  detail(@Param('id') id: string) {
    return this.service.adminDetail(id);
  }

  @Post(':id/handle')
  @RequirePermission('admin:complaint:handle')
  @ApiOperation({ summary: '权限点 admin:complaint:handle：处理（processing 处理中 / handled 已处理 / rejected 驳回）' })
  async handle(
    @Param('id') id: string,
    @Body() dto: { status: string; remark?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.adminHandle(user.userId, id, { status: dto.status, remark: dto.remark });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'complaint',
      action: `complaint:${dto.status}`,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ complaintId: id, status: dto.status, remark: dto.remark ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
