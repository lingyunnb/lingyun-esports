import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import {
  RATING_COMMENT_MAX,
  RATING_SCORE_MAX,
  RATING_SCORE_MIN,
} from '../worker/worker-grade.constants';
import { RatingService } from './rating.service';

/**
 * 五维评分请求体（`POST /user/orders/:id/rating`）
 *
 * ⚠️ **刻意不继承 `LenientUpdateDto`**：那种"整行回传静静忽略"的宽松语义是给管理端用的。
 * 老板侧评分只接受这 6 个字段，多带一个（尤其是 `workerId` / `orderId` / `userId`）一律被全局管道
 * `forbidNonWhitelisted` **400 掉** —— 「给谁打分」在协议层面就不可指定（docs/04 归属铁律）。
 *
 * 五个维度各 **1–10 的整数**（`enableImplicitConversion` 会把 `"8"` 转成 8，`8.5` / `0` / `11` 一律 400）。
 * 字段名与 `worker_rating` 列名一一对应（去掉 `r_` 前缀）：`skill / emotion / stress / voice / shop`。
 *
 * 类必须声明在 Controller **之前**（Nest 用 `design:paramtypes` 反射注入 DTO，
 * 声明在后面时 `tsc` 照样过，但运行时会 `Cannot access 'CreateWorkerRatingDto' before initialization`）。
 */
export class CreateWorkerRatingDto {
  @ApiProperty({ description: `五维第 1 维（1-${RATING_SCORE_MAX} 整数）`, minimum: RATING_SCORE_MIN, maximum: RATING_SCORE_MAX })
  @IsInt({ message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Min(RATING_SCORE_MIN, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Max(RATING_SCORE_MAX, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  skill!: number;

  @ApiProperty({ description: `五维第 2 维（1-${RATING_SCORE_MAX} 整数）`, minimum: RATING_SCORE_MIN, maximum: RATING_SCORE_MAX })
  @IsInt({ message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Min(RATING_SCORE_MIN, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Max(RATING_SCORE_MAX, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  emotion!: number;

  @ApiProperty({ description: `五维第 3 维（1-${RATING_SCORE_MAX} 整数）`, minimum: RATING_SCORE_MIN, maximum: RATING_SCORE_MAX })
  @IsInt({ message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Min(RATING_SCORE_MIN, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Max(RATING_SCORE_MAX, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  stress!: number;

  @ApiProperty({ description: `五维第 4 维（1-${RATING_SCORE_MAX} 整数）`, minimum: RATING_SCORE_MIN, maximum: RATING_SCORE_MAX })
  @IsInt({ message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Min(RATING_SCORE_MIN, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Max(RATING_SCORE_MAX, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  voice!: number;

  @ApiProperty({ description: `五维第 5 维（1-${RATING_SCORE_MAX} 整数）`, minimum: RATING_SCORE_MIN, maximum: RATING_SCORE_MAX })
  @IsInt({ message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Min(RATING_SCORE_MIN, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  @Max(RATING_SCORE_MAX, { message: `五维评分必须是 ${RATING_SCORE_MIN}-${RATING_SCORE_MAX} 的整数` })
  shop!: number;

  @ApiPropertyOptional({ description: `评价正文（可选，最多 ${RATING_COMMENT_MAX} 字；空串按未填处理）` })
  @IsOptional()
  @IsString({ message: '评价格式不正确' })
  @MaxLength(RATING_COMMENT_MAX, { message: `评价最多 ${RATING_COMMENT_MAX} 字` })
  comment?: string;
}

/**
 * 老板侧五维评分（负责人已审批 2026-10-17）
 *
 * 为什么路由落在 `/user/orders/:id/rating`（与既有 `/user/orders/:id/review` 同一前缀）：
 * 评价的对象是**订单**，`order_id` 是唯一键 —— 路由形状直接表达"一单一评"。
 * Express 按完整路径匹配，`:id` 详情（两段）与本控制器（三段）互不遮蔽。
 *
 * 会话语义：`@Roles('user')` → 只有老板 primary 能评；
 * - **打手不能自评**：打手态是 companion（`role=worker`），`RolesGuard` 直接 403；
 *   即使拿到老板令牌，服务层的 `order.user_id = sub` 校验也会拦住（替别人/替自己打手账号评都不行）。
 * - 管理端（role=admin）403；受限会话（`kind=recharge`）403。
 */
@ApiTags('user/orders')
@Controller('user/orders')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class RatingUserController {
  constructor(private readonly service: RatingService) {}

  @Post(':id/rating')
  @ApiOperation({
    summary:
      '提交五维评分（仅自己已完成订单；一单一评；五维各 1-10 整数；同事务重算均分并跑升级检查）',
  })
  submit(
    @CurrentUser() user: { userId: string },
    @Param('id') id: string,
    @Body() dto: CreateWorkerRatingDto,
  ) {
    // 只把五个维度 + 正文往下传：即使将来 DTO 加了字段，也不会把身份类字段带进写库路径
    return this.service.submit(user.userId, id, {
      skill: dto.skill,
      emotion: dto.emotion,
      stress: dto.stress,
      voice: dto.voice,
      shop: dto.shop,
      comment: dto.comment,
    });
  }

  @Get(':id/rating')
  @ApiOperation({ summary: '查询该订单的五维评分（未评价返回 null，供「已评价」回显）' })
  mine(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.service.mine(user.userId, id);
  }
}
