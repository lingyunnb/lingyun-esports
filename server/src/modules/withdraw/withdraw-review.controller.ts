import {
  Body,
  Controller,
  Get,
  HttpCode,
  Param,
  Post,
  Query,
  Req,
  Res,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiBearerAuth, ApiConsumes, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request, Response } from 'express';
import { memoryStorage } from 'multer';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { MediaService } from '../media/media.service';
import { RechargeSessionGuard } from '../recharge/recharge-session.guard';
import { WithdrawService } from './withdraw.service';

/**
 * multipart 单文件上限（**宽于**用途限制，刻意如此）。
 *
 * 与 `MediaController` 同口径取 100MB：真正的"这个用途最多 10MB"由 `MediaService` 的
 * `TYPE_RULES.withdraw_proof` 判定（中文 400「文件超出大小限制（最大 10MB）」）；
 * 若这里卡 10MB，multer 会先抛英文的 `File too large`，中文错误码就断了。
 */
const MAX_UPLOAD = 100 * 1024 * 1024;

/**
 * 提现审核族 `/withdraw/*` —— **App 内「管理员身份」（受限会话）专用**。
 *
 * ## 三层闸门（缺一不可，顺序即执行顺序）
 *
 * 1. `JwtAuthGuard`：校验令牌与会话登记；对 `kind='recharge'` 的会话**每请求实时查库**
 *    校验"仍在 `recharge_admin` 白名单 + 未封禁 + 仍是 admin"，并执行**接口族白名单**。
 *    ⚠️ 本次为提现**显式放行** `/withdraw/*`（`isRechargeAdminAllowedRoute` 新增一条规则）
 *    —— 受限会话是**允许清单**，不加这一条则整族接口 403 中文。
 * 2. `RechargeSessionGuard`：只接受 `kind='recharge'`（**primary 管理员不能走这条路径**，
 *    他走 `/admin/withdraw/*`）。**直接复用充值那条守卫**，不新写第二份 —— 受限会话的语义只有一种。
 * 3. `PermissionsGuard` + `@RequirePermission`：`withdraw:review` / `withdraw:pay`
 *    两个**专用窄权限点**（migration `1810000000000` 只授予 `super_admin`），按
 *    `admin_role_permission` 实时查库。
 *
 * ## 打款凭证上传（2026-10-11 新增，取代"用备注代替凭证"的退化实现）
 *
 * `POST /withdraw/requests/:id/pay-proof`（multipart 字段 `file`）是本族**唯一的写媒体入口**：
 * 受限会话白名单里**没有** `/media/*`，所以把上传能力收窄到"这一张申请"，
 * 路径落在**已被放行的 `/withdraw/*` 前缀内**（白名单一条都不用加，更没有放宽 `/media/*`）。
 * 配套：`pay` 的凭证从"凭证或备注至少一条"收紧为**必须带 `proofMediaId`**（备注可选）。
 *
 * ## 与 PC 管理端的关系（**双层口径**，与充值逐条同构）
 *
 * 两条入口**共用同一个服务层**（`WithdrawService`）：幂等键、条件 UPDATE、
 * 审计留痕、状态机完全一致 —— 差的只是"用哪种会话进来"。
 * 因此不存在"App 里驳回没退钱、PC 里驳回退了钱"这类分叉。
 *
 * ## 这里**没有**配置接口
 *
 * 改门槛/次数是**治理动作**，只走管理端 primary 会话（`PUT /admin/withdraw/config`，
 * 仅超管）—— 与充值"改配置/收款码必须走管理端登录"同一口径。
 */
@ApiTags('withdraw')
@Controller('withdraw')
@UseGuards(JwtAuthGuard, RechargeSessionGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class WithdrawReviewController {
  constructor(
    private readonly service: WithdrawService,
    private readonly media: MediaService,
  ) {}

  /** 待处理/全部申请列表（含打手昵称/工号、金额、状态、申请时间、**完整**收款信息 `account` + 兼容 `accountMasked`） */
  @Get('requests')
  @RequirePermission('withdraw:review')
  @ApiOperation({ summary: '权限点 withdraw:review：提现申请列表（status=pending|paid|rejected|all；仅限受限管理会话）' })
  list(
    @Query('status') status?: string,
    @Query('keyword') keyword?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.reviewList({ status, keyword }, parsePage(page), parsePageSize(pageSize));
  }

  /** 详情：完整姓名/电话/微信号 + 收款码链接 + 打款记录（审核必需） */
  @Get('requests/:id')
  @RequirePermission('withdraw:review')
  @ApiOperation({ summary: '权限点 withdraw:review：提现申请详情（完整收款信息 + 打款记录 + 退款流水）' })
  detail(@Param('id') id: string) {
    return this.service.detail(id);
  }

  /**
   * 受保护取图通道（`kind=qr` 收款码 / `kind=payout` 打款凭证）。
   *
   * 为什么不复用 `/media/protected/:id`：那个接口对 `role='admin'` 放行**任意**受保护媒体
   * （聊天图片也在内），而受限会话的白名单里刻意没有 `/media/*`（`isRechargeAdminAllowedRoute`
   * 的默认拒绝段）。这里把权限面收窄到"这条提现申请对应的这两张图"，
   * 与 `/recharge/proof/:requestId` 是同一套取舍。
   */
  @Get('proof/:id')
  @RequirePermission('withdraw:review')
  @ApiOperation({ summary: '权限点 withdraw:review：读取该申请的收款码/打款凭证（受限会话专用窄通道）' })
  async proof(@Param('id') id: string, @Query('kind') kind: string, @Res() res: Response) {
    const media = await this.service.proofMedia(id, kind);
    res.setHeader('Content-Type', media.mimeType);
    res.setHeader('Cache-Control', 'no-store');
    res.sendFile(this.media.absPath(media));
  }

  /**
   * **打款凭证上传**（`POST /withdraw/requests/:id/pay-proof`，multipart 字段 `file`）——
   * 受限会话也能用的**窄上传通道**（2026-10-11 新增）。
   *
   * 为什么必须单开一条：本族白名单（`isRechargeAdminAllowedRoute`）**刻意不含 `/media/*`**
   * （`/media/protected/:id` 对 `role='admin'` 放行任意受保护媒体）。这条路径落在**已被放行的
   * `/withdraw/*` 前缀内** → **白名单一条都不用加**，也没有放宽 `/media/*`。
   *
   * 权限面（三层闸门照旧）：`RechargeSessionGuard`（复用**同一个** `checkRechargeSession`）
   * + `@Roles('admin')` + `withdraw:pay`（上传凭证是**打款动作的一部分**，与 pay/reject 同一个
   * 窄权限点；"能看不能打"的形态不变）。
   *
   * 服务层校验（见 `WithdrawService.uploadPayProof`）：申请必须存在（404 中文，不泄漏存在性）
   * 且仍在 `pending`（已打款 → 中文 400「该申请已打款」）；文件沿用 `MediaService` 既有校验，
   * 用途固定 `withdraw_proof`（protected），客户端不可指定 `type`。
   * 返回 `{ mediaId, url }`（`url` = 既有受保护取图约定，**不是**磁盘路径）。
   */
  @Post('requests/:id/pay-proof')
  @HttpCode(200)
  @RequirePermission('withdraw:pay')
  @ApiConsumes('multipart/form-data')
  @ApiOperation({
    summary: '权限点 withdraw:pay：上传打款凭证（multipart 字段 file；type 固定 withdraw_proof/protected）',
  })
  @UseInterceptors(FileInterceptor('file', { storage: memoryStorage(), limits: { fileSize: MAX_UPLOAD } }))
  uploadPayProof(
    @Param('id') id: string,
    @UploadedFile() file: Express.Multer.File | undefined,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    return this.service.uploadPayProof(id, user.userId, file, {
      ip: clientIpOf(req),
      requestId: req.requestId ?? '',
      source: 'app-admin',
    });
  }

  /**
   * 打款（幂等：重复调用 → 中文 400「该申请已打款」，不重复生效）。
   *
   * body `{ proofMediaId, note? }`：**`proofMediaId` 必填**（2026-10-11 收紧 —— App 已有专用
   * 上传通道 `POST /withdraw/requests/:id/pay-proof`，不再需要"用备注代替凭证"），备注可选。
   * 校验在唯一一处（`WithdrawService.pay`，与 PC 管理端共用）→ **以更严的为准**。
   */
  @Post('requests/:id/pay')
  @HttpCode(200)
  @RequirePermission('withdraw:pay')
  @ApiOperation({ summary: '权限点 withdraw:pay：打款（与 PC 管理端同一服务层；条件 UPDATE 判 affectedRows）' })
  pay(
    @Param('id') id: string,
    @Body() body: { proofMediaId?: string; note?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    return this.service.pay(id, user.userId, body ?? {}, {
      ip: clientIpOf(req),
      requestId: req.requestId ?? '',
      source: 'app-admin',
    });
  }

  /** 驳回（必填原因 → 退回余额 + 反向流水；与 PC 管理端同一服务层） */
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
      source: 'app-admin',
    });
  }
}
