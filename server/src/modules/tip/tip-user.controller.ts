import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { IsInt, IsOptional, IsString, Length, Max, Min } from 'class-validator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { TipService } from './tip.service';

export class CreateTipDto {
  @IsString()
  @Length(1, 32)
  orderId!: string;

  /** 打赏金额（元，最多 2 位小数；上限由管理端 system_setting 决定，服务端二次校验） */
  @IsInt()
  @Min(1)
  @Max(1000000)
  amount!: number;

  /** 客户端生成的幂等键（重试复用同一键，服务端唯一约束防重复扣款） */
  @IsString()
  @Length(8, 48)
  idempotencyKey!: string;

  @IsOptional()
  @IsString()
  @Length(0, 200)
  remark?: string;
}

/** 老板端打赏（docs/06：主体 id 一律取自 JWT，客户端不可指定收款方） */
@ApiTags('user/tips')
@Controller('user/tips')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class TipUserController {
  constructor(private readonly service: TipService) {}

  @Get('config')
  @ApiOperation({ summary: '打赏配置（预设金额/单次上限/单订单累计上限，只读）' })
  config() {
    return this.service.config();
  }

  @Get('orders')
  @ApiOperation({ summary: '我可打赏的订单（进行中/待确认/已完成且有接单打手）' })
  orders(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.tipableOrders(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  @Get()
  @ApiOperation({ summary: '我发出的打赏记录' })
  mine(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.myTips(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  @Post()
  @ApiOperation({ summary: '打赏（余额 100% 给打手；事务+条件扣款+幂等键唯一约束+双份流水）' })
  create(@CurrentUser() user: { userId: string }, @Body() dto: CreateTipDto, @Req() req: Request) {
    return this.service.createTip(
      user.userId,
      { orderId: dto.orderId, amount: dto.amount, idempotencyKey: dto.idempotencyKey, remark: dto.remark },
      { ip: req.ip ?? '', requestId: req.requestId },
    );
  }
}
