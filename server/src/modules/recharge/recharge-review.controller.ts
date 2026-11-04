import { Body, Controller, Get, HttpCode, Param, Post, Query, Req, Res, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request, Response } from 'express';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { clientIpOf } from '../../common/client-ip';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { MediaService } from '../media/media.service';
import { RechargeSessionGuard } from './recharge-session.guard';
import { RechargeService } from './recharge.service';

/**
 * 充值审核族 `/recharge/*` —— **App 内「管理员身份」（受限会话）专用**。
 *
 * ## 三层闸门（缺一不可，顺序即执行顺序）
 *
 * 1. `JwtAuthGuard`：校验令牌与会话登记；对 `kind='recharge'` 的会话**每请求实时查库**
 *    校验"仍在 `recharge_admin` 白名单 + 未封禁 + 仍是 admin"，并执行**接口族白名单**
 *    （只放行 `/recharge/*` + `GET /auth/me` + `POST /auth/logout` + `POST /auth/refresh`，
 *    其余一律 403 中文 —— 含 `/admin/*`、`/user/*`、`/media/*`、`/auth/password`）。
 *    被移出白名单 → 这里直接 401 中文。
 * 2. `RechargeSessionGuard`：只接受 `kind='recharge'`（**primary 管理员不能走这条路径**，
 *    他走 `/admin/recharge/*`）。“受限会话"因此是这一族接口的唯一通道，语义不分叉。
 * 3. `PermissionsGuard` + `@RequirePermission`：`recharge:review` / `recharge:grant`
 *    两个**专用窄权限点**（不复用任何 `admin:*` 大权限），按 `admin_role_permission` 实时查库。
 *
 * ## 与 PC 管理端的关系（负责人 2026-10-06 定案：双层口径）
 *
 * PC 管理端用 **primary 会话 + 同样这两个窄权限点**，走 `/admin/recharge/*`。
 * 两条入口**共用同一个服务层**（`RechargeService`），因此幂等、审计、状态机完全一致 ——
 * 差别只在"用哪种会话进来"。
 */
@ApiTags('recharge')
@Controller('recharge')
@UseGuards(JwtAuthGuard, RechargeSessionGuard, PermissionsGuard)
@ApiBearerAuth()
export class RechargeReviewController {
  constructor(
    private readonly service: RechargeService,
    private readonly media: MediaService,
  ) {}

  /** 待审/全部申请列表（含用户昵称/中文 ID、金额、余额、凭证 id 与 url、提交时间） */
  @Get('requests')
  @RequirePermission('recharge:review')
  @ApiOperation({ summary: '权限点 recharge:review：充值申请列表（status=pending|granted|rejected|all；仅限受限管理会话）' })
  list(
    @Query('status') status?: string,
    @Query('keyword') keyword?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.reviewList({ status, keyword }, parsePage(page), parsePageSize(pageSize));
  }

  /**
   * **幂等发放**：事务 + 行锁 + 条件 UPDATE 判 affectedRows + 幂等键唯一约束（三层，见服务层注释）。
   * 重复调用 → 中文 400「该申请已发放」，**余额只加一次**。
   */
  @Post('requests/:id/grant')
  @HttpCode(200)
  @RequirePermission('recharge:grant')
  @ApiOperation({ summary: '权限点 recharge:grant：发放（复用既有发余额能力；幂等，重复调用中文 400 且不重复加分）' })
  grant(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.grant(id, user.userId, { ip: clientIpOf(req), requestId: req.requestId ?? '' });
  }

  /** 驳回（必填原因；通知申请人；重复处理 → 中文 400） */
  @Post('requests/:id/reject')
  @HttpCode(200)
  @RequirePermission('recharge:grant')
  @ApiOperation({ summary: '权限点 recharge:grant：驳回（必填原因，通知申请人；幂等）' })
  reject(@Param('id') id: string, @Body() body: { reason?: string }, @CurrentUser() user: { userId: string }) {
    return this.service.reject(id, user.userId, String(body?.reason ?? ''));
  }

  /** 当前受限管理员身份 + 待审核数 */
  @Get('me')
  @ApiOperation({ summary: '当前「管理员身份」信息 + 待审核数（无需权限点：identity 信息）' })
  me(@CurrentUser() user: { userId: string }) {
    return this.service.adminMe(user.userId);
  }

  /**
   * 转账截图（**按申请取图**，权限面最小）。
   *
   * 为什么不复用 `/media/protected/:id`：那个接口对 `role='admin'` 放行**任意**受保护媒体
   * （聊天图片也在内），而受限会话的白名单里刻意没有 `/media/*`。
   * 这里只放行"这条充值申请对应的这一张凭证"，且需要 `recharge:review`。
   * （PC 管理端用 primary 会话，直接走既有的 `/media/protected/:id`，无需这条。）
   */
  @Get('proof/:id')
  @RequirePermission('recharge:review')
  @ApiOperation({ summary: '权限点 recharge:review：读取某条充值申请的转账截图（受限会话专用窄通道）' })
  async proof(@Param('id') id: string, @Res() res: Response) {
    const media = await this.service.proofMedia(id);
    res.setHeader('Content-Type', media.mimeType);
    // 资金凭证：不进任何共享缓存（与 /media/protected 同口径）
    res.setHeader('Cache-Control', 'no-store');
    res.sendFile(this.media.absPath(media));
  }
}
