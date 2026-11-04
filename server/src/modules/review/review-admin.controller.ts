import { Body, Controller, Get, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiProperty, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { IsDefined, IsString, Length } from 'class-validator';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { OperationLogService } from '../log/operation-log.service';
import { REVIEW_REMARK_MAX, ReviewService } from './review.service';

/** 隐藏评价请求体：**原因必填**（治理动作必须说清"为什么"，与提现驳回同口径） */
export class HideReviewDto {
  @ApiProperty({ description: `隐藏原因（1-${REVIEW_REMARK_MAX} 字，随 operation_log 留痕）` })
  @IsDefined({ message: '请填写隐藏原因' })
  @IsString({ message: '请填写隐藏原因' })
  @Length(1, REVIEW_REMARK_MAX, { message: `隐藏原因需为 1-${REVIEW_REMARK_MAX} 字` })
  reason!: string;
}

/**
 * 管理端评价治理（负责人 2026-10-15）
 *
 * - **窄权限点 `review:moderate`**（migration `1814000000000` 只授予 `super_admin`）：
 *   读列表与隐藏/恢复**共用这一个点** —— 刻意**不复用**任何 `admin:*` 大权限
 *   （`admin:order:read` 之类会连带给出订单页/用户页一族能力），与 `recharge:review` /
 *   `withdraw:review` 同口径。见 `modules/rbac/permissions.const.ts`。
 * - **每个写接口都写 `operation_log`**（docs/03 不可违反）：`module='review'`、
 *   `action='review:hide' / 'review:show'`，`request_body` 只记关键字段与**变更前后摘要**
 *   （评价 id / 订单 id / 打手 id / hidden 前→后 / 原因），**不记评价原文**、不记 token。
 *
 * 隐藏与恢复都走**条件 UPDATE 判 `affectedRows`**（见 `ReviewService.adminHide/adminShow`）：
 * 重复点击不会产生第二次状态变化，也不会重复留痕（第二次调用直接中文 400）。
 */
@ApiTags('admin/reviews')
@Controller('admin/reviews')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class ReviewAdminController {
  constructor(
    private readonly service: ReviewService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('review:moderate')
  @ApiOperation({ summary: '权限点 review:moderate：评价列表（含 hidden 状态；可按 满意/隐藏/打手 筛选）' })
  list(
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
    @Query('satisfied') satisfied?: string,
    @Query('hidden') hidden?: string,
    @Query('workerId') workerId?: string,
  ) {
    return this.service.adminList({
      page: parsePage(page),
      pageSize: parsePageSize(pageSize),
      satisfied: satisfied?.trim() || undefined,
      hidden: hidden?.trim() || undefined,
      workerId: workerId?.trim() || undefined,
    });
  }

  @Post(':id/hide')
  @RequirePermission('review:moderate')
  @ApiOperation({ summary: '权限点 review:moderate：隐藏评价（原因必填；条件 UPDATE 判 affectedRows）' })
  async hide(
    @Param('id') id: string,
    @Body() dto: HideReviewDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.adminHide(id, dto.reason);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'review',
      action: 'review:hide',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(result.audit),
      ip: req.ip,
      requestId: req.requestId,
    });
    return { ok: true, id: result.reviewId, hidden: result.hidden };
  }

  @Post(':id/show')
  @RequirePermission('review:moderate')
  @ApiOperation({ summary: '权限点 review:moderate：恢复评价可见（清空隐藏原因；条件 UPDATE 判 affectedRows）' })
  async show(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.adminShow(id);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'review',
      action: 'review:show',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(result.audit),
      ip: req.ip,
      requestId: req.requestId,
    });
    return { ok: true, id: result.reviewId, hidden: result.hidden };
  }
}
