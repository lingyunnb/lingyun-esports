import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { IsOptional, IsString, Length } from 'class-validator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { RefundService } from './refund.service';

export class CreateRefundDto {
  @IsString()
  @Length(1, 32)
  orderId!: string;

  /** 退款原因（必填；金额不可传，服务端按订单金额快照退回） */
  @IsString()
  @Length(1, 100)
  reason!: string;

  @IsOptional()
  @IsString()
  @Length(0, 500)
  remark?: string;

  @IsString()
  @Length(8, 64)
  idempotencyKey!: string;
}

/** 老板端退款申请（docs/05/06：主体 id 一律取自 JWT；已完成订单走既有申诉） */
@ApiTags('user/refunds')
@Controller('user/refunds')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class RefundUserController {
  constructor(private readonly service: RefundService) {}

  @Get('orders')
  @ApiOperation({ summary: '可申请退款的订单（未开始/进行中/待确认，且无待处理申请）' })
  orders(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.creatableOrders(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  @Get()
  @ApiOperation({ summary: '我的退款申请（待处理/已通过/已驳回）' })
  mine(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.myRequests(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  @Post()
  @ApiOperation({ summary: '提交退款申请（幂等键唯一约束；同一订单同时只有一条待处理）' })
  create(@CurrentUser() user: { userId: string }, @Body() dto: CreateRefundDto, @Req() req: Request) {
    return this.service.create(
      user.userId,
      { orderId: dto.orderId, reason: dto.reason, remark: dto.remark, idempotencyKey: dto.idempotencyKey },
      { ip: req.ip ?? '', requestId: req.requestId },
    );
  }
}
