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
import { AdminCancelOrderDto, DispatchOrderDto, OrderPageQueryDto, SettlementQueryDto } from './dto/order.dto';
import { OrderService } from './order.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 管理端：订单管理 + 抽成中心（负责人结算需求） */
@ApiTags('admin/orders')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class OrderAdminController {
  constructor(
    private readonly service: OrderService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get('orders')
  @RequirePermission('admin:order:read')
  @ApiOperation({ summary: '权限点 admin:order:read：订单列表（分页/状态/搜索）' })
  list(@Query() q: OrderPageQueryDto) {
    return this.service.adminList({ status: q.status, keyword: q.keyword, page: q.page ?? 1, pageSize: q.pageSize ?? 20 });
  }

  @Get('orders/:id')
  @RequirePermission('admin:order:read')
  @ApiOperation({ summary: '权限点 admin:order:read：订单详情（快照+状态日志+结算信息）' })
  detail(@Param('id') id: string) {
    return this.service.adminDetail(id);
  }

  @Post('orders/:id/cancel')
  @RequirePermission('admin:order:cancel')
  @ApiOperation({ summary: '权限点 admin:order:cancel：管理员取消订单（全额退款，未结算订单）' })
  async cancel(@Param('id') id: string, @Body() dto: AdminCancelOrderDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.cancelByAdmin(user.userId, id, dto.reason ?? '', { ip: req.ip ?? '', requestId: req.requestId });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'order',
      action: 'order:admin-cancel',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ orderId: id, reason: dto.reason ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  // ---------------- 强制完成（负责人 2026-10-04：老板确认之外的第二条 completed 路径） ----------------

  @Post('orders/:id/complete')
  @RequirePermission('admin:order:write')
  @ApiOperation({
    summary: '权限点 admin:order:write：管理端强制完成订单（待确认/异常/售后 → 已完成；未结算则按后台配置抽成比例结算，已结算只补状态）',
  })
  async forceComplete(
    @Param('id') id: string,
    @Body() dto: { remark?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.adminForceComplete(user.userId, id, dto?.remark ?? '', {
      ip: req.ip ?? '',
      requestId: req.requestId,
    });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'order',
      action: 'order:force-complete',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ orderId: id, remark: dto?.remark ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  // ---------------- 派单（阶段16补，docs/05） ----------------

  @Post('orders/:id/dispatch')
  @RequirePermission('admin:order:dispatch')
  @ApiOperation({ summary: '权限点 admin:order:dispatch：派单给指定打手（待接单→待确认派单，WS 通知）' })
  async dispatch(@Param('id') id: string, @Body() dto: DispatchOrderDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.adminDispatch(user.userId, id, dto.workerId, { ip: req.ip ?? '', requestId: req.requestId });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'order',
      action: 'order:dispatch',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ orderId: id, workerId: dto.workerId }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Post('orders/:id/revoke-dispatch')
  @RequirePermission('admin:order:dispatch')
  @ApiOperation({ summary: '权限点 admin:order:dispatch：撤销派单（回大厅）' })
  async revoke(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.adminRevokeDispatch(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'order',
      action: 'order:revoke-dispatch',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ orderId: id }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  // ---------------- 售后申诉（docs/05） ----------------

  @Get('appeals')
  @RequirePermission('admin:appeal:handle')
  @ApiOperation({ summary: '权限点 admin:appeal:handle：申诉列表' })
  appeals(@Query('status') status?: string, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.adminAppeals({ status, page: parsePage(page), pageSize: parsePageSize(pageSize) });
  }

  @Post('appeals/:id/handle')
  @RequirePermission('admin:appeal:handle')
  @ApiOperation({ summary: '权限点 admin:appeal:handle：裁决（refund 退款含结算冲正 / dismiss 驳回）' })
  async handleAppeal(@Param('id') id: string, @Body() dto: { action: 'refund' | 'dismiss'; remark?: string }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.adminHandleAppeal(user.userId, id, dto, { ip: req.ip ?? '', requestId: req.requestId });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'order',
      action: `appeal:${dto.action}`,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ appealId: id, ...dto }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  // ---------------- 抽成中心 ----------------

  @Get('settlements')
  @RequirePermission('admin:order:read')
  @ApiOperation({ summary: '权限点 admin:order:read：结算流水（订单号/打手过滤）' })
  settlements(@Query() q: SettlementQueryDto) {
    return this.service.settlements({ orderNo: q.orderNo, workerId: q.workerId, page: q.page ?? 1, pageSize: q.pageSize ?? 20 });
  }

  @Get('commission/stats')
  @RequirePermission('admin:order:read')
  @ApiOperation({ summary: '权限点 admin:order:read：抽成概览（累计/今日/本月，SQL 实时统计）' })
  stats() {
    return this.service.commissionStats();
  }
}
