import { Body, Controller, Get, HttpCode, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { clientIpOf } from '../../common/client-ip';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { CreateRechargeRequestDto } from './dto/recharge.dto';
import { RechargeService } from './recharge.service';

/**
 * 老板端「充值」——**用户侧**（primary 会话，`role=user`）。
 *
 * 合规口径（CLAUDE.md 结构规则 12）：这里**没有**"充值下单/支付/回调"接口，
 * 只有"提交一张带截图的申请"和"查我自己的申请"。余额**只能由管理员手工发放**，
 * 用户永远不能自行加分（docs/06 铁律不变）。
 *
 * 会话口径：
 * - companion（打手态）**不在白名单里** → 打手态无法提交充值申请（默认拒绝，无需额外代码）；
 * - recharge（受限管理态）**不在白名单里** → 管理员态不能自己给自己提充值申请。
 *
 * 主体 id 只从 JWT `sub` 取，请求体里**没有任何用户标识字段**。
 */
@ApiTags('user/recharge')
@Controller('user/recharge')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('user')
@ApiBearerAuth()
export class RechargeUserController {
  constructor(private readonly service: RechargeService) {}

  /**
   * 提交充值申请（**201**）。
   *
   * 校验（全部中文 400）：金额在档位内或自定义区间内 → `points = round(金额 × 到账比例, 2)` 且 >0
   * → 凭证必须是**本人上传**的图片 → 收款码（可选）存在且启用 → 待审核数 < 每人上限。
   */
  @Post('requests')
  @ApiOperation({
    summary: '提交充值申请（线下付款截图 + 人工审核；金额校验/凭证归属校验/待审上限均在此拦截）',
  })
  create(@CurrentUser() user: { userId: string }, @Body() dto: CreateRechargeRequestDto) {
    return this.service.createRequest(user.userId, {
      amountYuan: Number(dto.amountYuan),
      qrId: dto.qrId,
      note: dto.note,
      proofMediaId: dto.proofMediaId,
    });
  }

  /** 我的申请（含状态/驳回原因/发放时间；附带待审数与上限，客户端据此禁用提交按钮） */
  @Get('requests')
  @ApiOperation({ summary: '我的充值申请列表（含状态、驳回原因、发放时间、待审数与上限）' })
  mine(
    @CurrentUser() user: { userId: string },
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.myRequests(user.userId, parsePage(page), parsePageSize(pageSize));
  }
}

/**
 * 老板端「身份」——绑定 **管理员身份**（受限会话）。
 *
 * 与打手态 `/user/identity/bind` 完全同构（同模块、同会话机制、同限流、同防枚举文案），
 * 差别只在"校验对象是 `recharge_admin` 白名单里的 admin 账号"。
 *
 * 为什么放在 `@Controller('user/identity')` 而不是 `user/recharge`：
 * 它是**身份切换**能力（老板在身份页把另一个账号的身份挂上来），不是充值业务能力；
 * 路径与 `docs/03` / `docs/04` 的身份族保持一处，客户端切换身份的代码只需要改一个端点常量。
 */
@ApiTags('user/identity')
@Controller('user/identity')
export class RechargeIdentityController {
  constructor(private readonly service: RechargeService) {}

  /**
   * 绑定管理员身份 → 签发 `kind='recharge'` 受限会话。
   *
   * - 调用方必须是**已登录的 primary 会话**（老板或管理员都可：身份页是老板侧能力，
   *   管理员也常在自己的 App 里直接切）；
   * - 被签发的对象**永远是"被验证账密的那个管理员账号"**，不是调用方 —— 主体只来自服务端查库；
   * - **不顶 primary**：该管理员在管理端的登录照常可用（`AuthService.issueTokens` 按 kind 分族吊销）；
   * - TTL 12h（与 companion 一致），到点必须重新输账密。
   */
  @Post('bind-recharge-admin')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user', 'admin')
  @ApiBearerAuth()
  @ApiOperation({
    summary: '绑定管理员身份（校验管理员账密 + recharge_admin 白名单 + 封禁）并签发受限会话（不顶 primary）',
  })
  bind(
    @CurrentUser() user: { userId: string },
    @Body() dto: { username?: string; password?: string },
    @Req() req: Request,
  ) {
    return this.service.bindRechargeAdmin(user.userId, dto, clientIpOf(req), req.header('user-agent') ?? '');
  }

  /**
   * 受限管理会话续期（**公开**：只吃 recharge 的 refreshToken）。
   *
   * 与 `/user/identity/refresh` 同一条闸门：非 recharge 令牌（含 primary / companion）
   * 在**任何写操作之前** 401 中文，绝不把别的会话轮换/吊销掉。
   */
  @Post('refresh-recharge-admin')
  @HttpCode(200)
  @ApiOperation({ summary: '受限管理会话续期（只接受 recharge refreshToken；移出白名单则 401 中文）' })
  refresh(@Body() dto: { refreshToken?: string }, @Req() req: Request) {
    return this.service.refreshRechargeAdmin(String(dto?.refreshToken ?? ''), clientIpOf(req));
  }
}
