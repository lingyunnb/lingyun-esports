import { Body, Controller, Get, Post, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { IsArray, IsIn, IsOptional, IsString, Length } from 'class-validator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { ComplaintService } from './complaint.service';

export class CreateComplaintDto {
  /** 投诉对象：order 订单 / worker 打手 / service 客服 */
  @IsIn(['order', 'worker', 'service'])
  targetType!: string;

  @IsOptional()
  @IsString()
  @Length(0, 64)
  targetId?: string;

  /** 投诉类型：attitude 服务态度 / not_agreed 未按约定 / delay 恶意拖延 / other 其它 */
  @IsIn(['attitude', 'not_agreed', 'delay', 'other'])
  type!: string;

  @IsString()
  @Length(5, 1000)
  content!: string;

  /** 截图媒体 id（最多 6 张，必须是本人上传） */
  @IsOptional()
  @IsArray()
  mediaIds?: string[];
}

/** 老板端投诉（投诉人一律取自 JWT；订单/打手归属与截图归属服务端校验） */
@ApiTags('user/complaints')
@Controller('user/complaints')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class ComplaintUserController {
  constructor(private readonly service: ComplaintService) {}

  @Post()
  @ApiOperation({ summary: '提交投诉（对象/类型/描述/可选截图）' })
  create(@CurrentUser() user: { userId: string }, @Body() dto: CreateComplaintDto) {
    return this.service.create(user.userId, {
      targetType: dto.targetType,
      targetId: dto.targetId,
      type: dto.type,
      content: dto.content,
      mediaIds: dto.mediaIds,
    });
  }

  /**
   * 可投诉打手候选（负责人 2026-10-05 任务③）
   *
   * 路由必须声明在其它 GET 之前（Nest 按声明顺序匹配，与 `order-user.controller` 的
   * `weekly-quota` 同一处理）：本接口是 `targets/workers` 两段路径，本身不会被 `@Get()` 抢，
   * 但保持"具体路径在前"的写法以免后续加入 `@Get(':id')` 时踩坑。
   *
   * - `?orderId=xxx`：只返回该订单的接单打手（最严格）
   * - 不带参数：曾接过我订单的打手（按打手去重）
   * 数据源与 `ComplaintService.create` 的校验同一套 where 条件 → 列表能选的，接口一定收。
   */
  @Get('targets/workers')
  @ApiOperation({ summary: '可投诉打手候选（仅"接过我单"的打手；带 orderId 时只含该单接单人）' })
  workerTargets(@CurrentUser() user: { userId: string }, @Query('orderId') orderId?: string) {
    return this.service.workerTargets(user.userId, orderId);
  }

  @Get()
  @ApiOperation({ summary: '我的投诉（待处理/处理中/已处理/驳回 + 处理结果）' })
  mine(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.service.myList(user.userId, parsePage(page), parsePageSize(pageSize));
  }
}
