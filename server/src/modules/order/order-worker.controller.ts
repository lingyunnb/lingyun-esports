import { Controller, Get, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OrderService } from './order.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 工作端订单接口（docs/04/05）：接单权限每次请求实时查库；订单归属以 worker 档案为准 */
@ApiTags('worker/orders')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class OrderWorkerController {
  constructor(private readonly service: OrderService) {}

  @Get('order-hall')
  @ApiOperation({ summary: '接单大厅（需接单权限实时校验，仅待接单；可按分部筛选）' })
  hall(
    @CurrentUser() user: { userId: string },
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
    @Query('divisionId') divisionId?: string,
  ) {
    return this.service.workerHall(user.userId, parsePage(page), parsePageSize(pageSize), divisionId);
  }

  @Get('orders')
  @ApiOperation({ summary: '我的订单（可按状态过滤）' })
  list(
    @CurrentUser() user: { userId: string },
    @Query('status') status?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.workerOrders(user.userId, status, parsePage(page), parsePageSize(pageSize));
  }

  @Post('orders/:id/grab')
  @ApiOperation({ summary: '抢单（条件更新防并发，一个订单只被一人抢到）' })
  grab(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Req() req: Request) {
    return this.service.grab(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Post('orders/:id/start')
  @ApiOperation({ summary: '开始服务（已接单→进行中）' })
  start(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Req() req: Request) {
    return this.service.start(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Post('orders/:id/submit')
  @ApiOperation({ summary: '提交完成（进行中→待用户确认）' })
  submit(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Req() req: Request) {
    return this.service.submit(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Post('orders/:id/accept')
  @ApiOperation({ summary: '确认派单（待确认派单→已接单，仅被派对象+有效期内，docs/05）' })
  accept(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Req() req: Request) {
    return this.service.workerAccept(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
  }

  @Post('orders/:id/reject')
  @ApiOperation({ summary: '拒绝派单（回大厅）' })
  reject(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Req() req: Request) {
    return this.service.workerReject(user.userId, id, { ip: req.ip ?? '', requestId: req.requestId });
  }
}
