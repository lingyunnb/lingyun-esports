import { Body, Controller, Get, HttpCode, Param, Post, Put, Query, Req, Res, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { InjectDataSource } from '@nestjs/typeorm';
import { Request, Response } from 'express';
import { DataSource } from 'typeorm';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { MediaService } from '../media/media.service';
import { WithdrawService } from './withdraw.service';

/**
 * 提现**管理端** `/admin/withdraw/*`（admin-web 用）。
 *
 * ## 会话口径（与充值**双层口径**逐条同构，负责人 2026-10-06 定案延续到提现）
 *
 * - **PC 管理端（本文件）**：正常 `role='admin'` 的 **primary** 登录 + **窄权限点**
 *   `withdraw:review`（看列表/详情/收款码与打款凭证）/ `withdraw:pay`（打款·驳回）。
 *   **不套受限会话** —— 管理端本来就是管理员终端。
 * - **App 内「管理员身份」**：受限会话（`kind='recharge'`）→ `/withdraw/*`
 *   （见 `withdraw-review.controller.ts`）。两条入口**共用同一个服务层**
 *   （`WithdrawService.reviewList/detail/pay/reject/proofMedia`）：
 *   幂等、审计、状态机完全一致，差的只是"用哪种会话进来"。
 *
 * ## 权限点映射
 *
 * | 接口 | 权限点 |
 * |---|---|
 * | `GET /admin/withdraw/requests` / `requests/:id` / `proof/:id` | `withdraw:review` |
 * | `POST /admin/withdraw/requests/:id/pay` / `reject` | `withdraw:pay` |
 * | `GET /admin/withdraw/config` | `admin:setting:read` |
 * | `PUT /admin/withdraw/config` | `admin:setting:write` + **仅超管**（`is_high_security=1`） |
 *
 * `PUT` 的"仅超管"**不靠本文件手写 if**：配置行 `is_high_security=1`，
 * `SystemSettingService.update()` 会用调用者角色码校验（与 `PUT /admin/settings/:key`、
 * `PUT /admin/recharge/config` 完全同一条路径）—— 改配置这道闸门全项目只有一处实现。
 */
@ApiTags('admin/withdraw')
@Controller('admin/withdraw')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class WithdrawAdminController {
  constructor(
    private readonly service: WithdrawService,
    private readonly media: MediaService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  // ---------------------------------------------------------------- 申请审核

  @Get('requests')
  @RequirePermission('withdraw:review')
  @ApiOperation({
    summary:
      '权限点 withdraw:review：提现申请列表（status/keyword/startTime/endTime/page/pageSize；收款信息给**完整** account + 兼容保留 accountMasked）',
  })
  list(
    @Query('status') status?: string,
    @Query('keyword') keyword?: string,
    @Query('startTime') startTime?: string,
    @Query('endTime') endTime?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.reviewList({ status, keyword, startTime, endTime }, parsePage(page), parsePageSize(pageSize));
  }

  @Get('requests/:id')
  @RequirePermission('withdraw:review')
  @ApiOperation({ summary: '权限点 withdraw:review：提现申请详情（**完整**姓名/电话/微信号 + 收款码链接 + 打款记录）' })
  detail(@Param('id') id: string) {
    return this.service.detail(id);
  }

  /**
   * 受保护取图通道（收款码 / 打款凭证）—— 权限面收窄到"这条申请的那两张图"。
   *
   * PC 管理端本来也能走 `/media/protected/:id`，但这里统一走同一条更窄的通道：
   * 两条入口（PC 与 App 管理员态）取图行为一致，也免去"管理端要去记两个 mediaId"。
   */
  @Get('proof/:id')
  @RequirePermission('withdraw:review')
  @ApiOperation({ summary: '权限点 withdraw:review：读取该申请的收款码(kind=qr)/打款凭证(kind=payout)' })
  async proof(@Param('id') id: string, @Query('kind') kind: string, @Res() res: Response) {
    const media = await this.service.proofMedia(id, kind);
    res.setHeader('Content-Type', media.mimeType);
    // 个人信息 + 资金凭证：不进任何共享缓存（与 /media/protected 同口径）
    res.setHeader('Cache-Control', 'no-store');
    res.sendFile(this.media.absPath(media));
  }

  /** 打款（幂等：重复调用 → 中文 400「该申请已打款」且不重复生效） */
  @Post('requests/:id/pay')
  @HttpCode(200)
  @RequirePermission('withdraw:pay')
  @ApiOperation({ summary: '权限点 withdraw:pay：打款（条件 UPDATE 判 affectedRows；重复调用中文 400 且不重复生效）' })
  pay(
    @Param('id') id: string,
    @Body() body: { proofMediaId?: string; note?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    return this.service.pay(id, user.userId, body ?? {}, {
      ip: clientIpOf(req),
      requestId: req.requestId ?? '',
      source: 'admin-web',
    });
  }

  /** 驳回（必填原因 → **退回余额 + 反向流水**；重复调用同样中文 400） */
  @Post('requests/:id/reject')
  @HttpCode(200)
  @RequirePermission('withdraw:pay')
  @ApiOperation({ summary: '权限点 withdraw:pay：驳回（必填原因；退回余额 + 反向流水 withdraw_reject；幂等）' })
  reject(
    @Param('id') id: string,
    @Body() body: { reason?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    return this.service.reject(id, user.userId, String(body?.reason ?? ''), {
      ip: clientIpOf(req),
      requestId: req.requestId ?? '',
      source: 'admin-web',
    });
  }

  // ---------------------------------------------------------------- 配置

  /** `GET /admin/withdraw/config`：平铺返回配置本体（+ 默认值，供「恢复默认」） */
  @Get('config')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：提现配置（平铺；含 defaultConfig / pendingLimit）' })
  readConfig() {
    return this.service.configView();
  }

  /**
   * `PUT /admin/withdraw/config`：门槛/次数/费率/说明文案（**仅超管**，`is_high_security=1`）。
   *
   * 未提交的字段沿用当前库值（局部提交不该把其余项悄悄打回默认）。
   * 读侧**无缓存** → 保存即生效，无需失效钩子。
   */
  @Put('config')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write + 仅超管：保存提现配置（非法值中文 400；保存即生效）' })
  async saveConfig(
    @Body() body: Record<string, unknown>,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const roleCode = await this.roleCodeOf(user.userId);
    return this.service.saveConfig(
      body ?? {},
      {
        userId: user.userId,
        ip: clientIpOf(req),
        requestId: req.requestId ?? null,
        method: req.method,
        path: req.path,
      },
      roleCode,
    );
  }

  /** 调用者的管理员角色码（查不到 → null；与 `SystemSettingController` 同一段 SQL） */
  private async roleCodeOf(userId: string): Promise<string | null> {
    const rows: Array<{ code: string }> = await this.dataSource.query(
      `SELECT ar.code FROM admin a JOIN admin_role ar ON ar.id = a.role_id WHERE a.user_id = ?`,
      [String(userId)],
    );
    return rows[0]?.code ?? null;
  }
}
