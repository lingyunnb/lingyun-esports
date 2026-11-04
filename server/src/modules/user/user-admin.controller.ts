import { Body, Controller, Delete, Get, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { UserPageQueryDto } from './dto/user-admin.dto';
import { UserAdminService } from './user-admin.service';

/** 管理端用户管理（负责人需求）：老板/工作端账号列表、封号（自定义时长）、解封、删除 */
@ApiTags('admin/users')
@Controller('admin/users')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class UserAdminController {
  constructor(
    private readonly service: UserAdminService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:user:read')
  @ApiOperation({ summary: '权限点 admin:user:read：用户列表（老板/工作端，分页+搜索+角色过滤）' })
  list(@Query() q: UserPageQueryDto) {
    return this.service.list({ page: q.page ?? 1, pageSize: q.pageSize ?? 20, keyword: q.keyword ?? '', role: q.role });
  }

  @Post(':id/ban')
  @RequirePermission('admin:user:ban')
  @ApiOperation({ summary: '权限点 admin:user:ban（默认仅超管）：封号（days 为空=永久，否则封禁至 now+days 天）' })
  async ban(
    @Param('id') id: string,
    @Body() dto: { days?: number | null; reason?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    // 释放绑定的触发者 + 请求证据（审计 F4：谁、哪个 bindingId、来源、IP、UA）
    const result = await this.service.ban(id, dto, {
      adminUserId: user.userId,
      ip: req.ip,
      userAgent: req.header('user-agent') ?? '',
    });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'user',
      action: 'user:ban',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ userId: id, days: dto.days ?? null, permanent: result.permanent, reason: dto.reason ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Post(':id/unban')
  @RequirePermission('admin:user:ban')
  @ApiOperation({ summary: '权限点 admin:user:ban：解封' })
  async unban(
    @Param('id') id: string,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.unban(id);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'user',
      action: 'user:unban',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ userId: id }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Delete(':id')
  @RequirePermission('admin:user:delete')
  @ApiOperation({ summary: '权限点 admin:user:delete（默认仅超管）：删除账号（清理个人数据，保留订单/结算/日志）' })
  async delete(
    @Param('id') id: string,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.deleteUser(id, {
      adminUserId: user.userId,
      ip: req.ip,
      userAgent: req.header('user-agent') ?? '',
    });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'user',
      action: 'user:delete',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ userId: id }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }
}
