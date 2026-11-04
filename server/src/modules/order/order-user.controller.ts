import { Body, Controller, Get, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { CancelOrderDto, CreateOrderDto } from './dto/order.dto';
import { OrderService } from './order.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 老板端订单接口（docs/05）：归属一律以 JWT 主体为准 */
@ApiTags('user/orders')
@Controller('user/orders')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class OrderUserController {
  constructor(private readonly service: OrderService) {}

  @Post()
  @ApiOperation({ summary: '下单（服务端查库定价+事务扣款+价格快照+幂等；指定护航员按分部校验）' })
  create(@Body() dto: CreateOrderDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.createOrder(
      user.userId,
      {
        productId: dto.productId,
        quantity: dto.quantity ?? 1,
        remark: dto.remark,
        idempotencyKey: dto.idempotencyKey,
        gameZone: dto.gameZone,
        gamePlayerId: dto.gamePlayerId,
        contactPhone: dto.contactPhone,
        // 指定护航员（负责人 2026-10-04）：DTO 早就声明并校验了这两个字段，但控制器此前**没有往下传**——
        // 老板端选了「指定护航员」服务端也当随机安排处理（选了等于没选）。
        // 现在原样转发，并在 createOrder 内做「该分部有接单权限」的服务端校验。
        workerMode: dto.workerMode,
        designatedWorkerId: dto.designatedWorkerId,
      },
      { ip: req.ip ?? '', requestId: req.requestId },
    );
  }

  @Get()
  @ApiOperation({ summary: '我的订单（分页，可按状态过滤）' })
  list(
    @CurrentUser() user: { userId: string },
    @Query('status') status?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.userOrders(user.userId, status, parsePage(page), parsePageSize(pageSize));
  }

  /**
   * 每周限购配额（负责人 2026-10-05）
   *
   * 路由必须声明在 `@Get(':id')` **之前**：Nest 按声明顺序匹配，放在后面会被 `:id` 抢走
   * （`weekly-quota` 会被当成订单号去查详情 → 404/400）。
   *
   * 只回「服务端权威结果 + 中文提示」：客户端拿到的限购数/已下单数/剩余数/文案全部来自这里，
   * 客户端不硬编码任何限购规则（docs/04）。
   */
  @Get('weekly-quota')
  @ApiOperation({ summary: '每周限购配额（限购数/本周已下单/剩余/中文提示文案，客户端只展示）' })
  weeklyQuota(@CurrentUser() user: { userId: string }, @Query('productId') productId: string) {
    return this.service.weeklyQuota(user.userId, productId);
  }

  @Get(':id')
  @ApiOperation({ summary: '订单详情（含价格快照与结算信息）' })
  detail(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.service.userOrderDetail(user.userId, id);
  }

  /** 老板点击"已完成"：触发正式结算（幂等+事务；比例读 system_setting.platform_commission_rate，默认抽成 25%） */
  @Post(':id/confirm')
  @ApiOperation({ summary: '确认完成并正式结算（按后台配置的抽成比例分账，服务器计算，一个订单仅一次）' })
  confirm(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Req() req: Request) {
    return this.service.confirmAndSettle(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Post(':id/cancel')
  @ApiOperation({ summary: '取消订单（仅待接单状态，全额退款）' })
  cancel(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Body() dto: CancelOrderDto, @Req() req: Request) {
    return this.service.cancelByUser(user.userId, id, dto.reason ?? '', { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Post(':id/appeal')
  @ApiOperation({ summary: '申请售后（仅已完成/异常订单，一单一申诉，docs/05）' })
  appeal(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Body() dto: CancelOrderDto, @Req() req: Request) {
    return this.service.userAppeal(user.userId, id, dto.reason ?? '', { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Get(':id/appeal')
  @ApiOperation({ summary: '查询申诉状态' })
  appealStatus(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.service.userAppealStatus(user.userId, id);
  }
}
