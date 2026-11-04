import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsBoolean, IsOptional, IsString, MaxLength } from 'class-validator';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { REVIEW_REMARK_MAX, ReviewService } from './review.service';

/**
 * 提交评价请求体
 *
 * ⚠️ `satisfied` 的 TS 类型刻意写成 `boolean | string`（而不是 `boolean`）：
 * 全局管道开了 `enableImplicitConversion`，若声明类型是 `boolean`，class-transformer 会用
 * `Boolean(value)` 隐式转换 —— **字符串 `"false"` 会变成 `true`**（`Boolean("false") === true`），
 * 于是一条差评会被静默记成好评（好评率虚高 + 售后提示不出现）。
 * 声明成联合类型后 `design:type` 是 `Object`，**不做隐式转换**，下面 `@Transform` 拿到原始值按白名单归一，
 * 再由 `@IsBoolean()` 收口：`true/false` 与 `"true"/"false"/"1"/"0"` 都收，其余一律 400。
 */
export class CreateReviewDto {
  @ApiProperty({ type: Boolean, description: '是否满意：true 好评 / false 差评（差评会回 needAfterSale=true）' })
  @Transform(({ value }) => {
    if (value === true || value === 'true' || value === 1 || value === '1') return true;
    if (value === false || value === 'false' || value === 0 || value === '0') return false;
    return value;
  })
  @IsBoolean({ message: '请选择满意或不满意' })
  satisfied!: boolean | string;

  @ApiPropertyOptional({ description: `评价内容（可选，最多 ${REVIEW_REMARK_MAX} 字）` })
  @IsOptional()
  @IsString()
  @MaxLength(REVIEW_REMARK_MAX, { message: `评价内容最多 ${REVIEW_REMARK_MAX} 字` })
  remark?: string;
}

/**
 * 老板端评价接口（负责人 2026-10-15 定案）
 *
 * 路由落在 `/user/orders/*` 下，与 `OrderUserController` 同前缀：
 * Express 按**完整路径**匹配，`:id` 详情（两段）与本控制器的 `:id/review`（三段）互不遮蔽，
 * 且两者都只做「取出 JWT 主体 → 交给服务层」这一件事（业务全在 `ReviewService`）。
 *
 * 归属铁律（docs/04）：`user_id` **只从 JWT sub 取**；订单是否属于本人由服务层查库判定。
 * 打手态（companion 受限会话）**默认被守卫挡掉**（`/user/*` 不在允许清单里）—— 评价是老板侧动作。
 */
@ApiTags('user/orders')
@Controller('user/orders')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class ReviewUserController {
  constructor(private readonly service: ReviewService) {}

  @Post(':id/review')
  @ApiOperation({ summary: '提交评价（仅已完成订单；一单一评；不满意回 needAfterSale=true）' })
  submit(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Body() dto: CreateReviewDto) {
    return this.service.submit(user.userId, id, {
      satisfied: dto.satisfied === true,
      remark: dto.remark,
    });
  }

  @Get(':id/review')
  @ApiOperation({ summary: '查询该订单的评价（未评价返回 null，供「已评价」回显）' })
  mine(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.service.mine(user.userId, id);
  }
}
