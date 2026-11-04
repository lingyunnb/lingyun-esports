import { Body, Controller, Get, HttpCode, Post, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { BindWorkerIdentityDto, RefreshCompanionDto, UnbindWorkerIdentityDto } from './dto/worker-identity.dto';
import { WorkerIdentityService } from './worker-identity.service';

/**
 * 老板端「切换身份」—— 绑定打手账号 / 解绑 / 查询绑定状态 / 伴随会话续期
 * （合并双端·身份切换，方案甲；负责人 2026-10-06 拍板）。
 *
 * 会话语义（**本模块的核心安全设计**，详见 `JwtAuthGuard` 的 companion 分支）：
 * - `bind/unbind/status` 是**老板侧（primary）**能力：`@Roles('user')` + companion 白名单双重拦截
 *   —— 伴随会话（companion）**不能**管理绑定关系（否则打手态可自行解绑/换绑，等于越权）。
 * - `refresh` 是**公开**的（只吃 companion 的 refreshToken）：伴随会话 12h 窗口内续期，
 *   续期时同样校验绑定仍 active；不需要（也不应该）持有老板 token。
 * - 主体 id 只从 JWT `sub` 取：请求体里只有"绑谁"的定位标识与打手账密，绝不接受 boss id。
 */
@ApiTags('user/identity')
@Controller('user/identity')
export class WorkerIdentityController {
  constructor(private readonly service: WorkerIdentityService) {}

  /**
   * 绑定打手账号 → 建绑定 + 签发伴随会话（companion）。
   * 老板自己的 token **不变**（`bossTokenUnchanged: true`），companion 只在打手态使用。
   */
  @Post('bind')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user')
  @ApiBearerAuth()
  @ApiOperation({
    summary: '绑定打手账号（校验打手账密 + 角色/封禁/占用/上限）并签发伴随会话（不顶打手原有登录）',
  })
  bind(@CurrentUser() user: { userId: string }, @Body() dto: BindWorkerIdentityDto, @Req() req: Request) {
    return this.service.bind(user.userId, dto, clientIpOf(req), req.header('user-agent') ?? '');
  }

  /** 解绑（保留历史行 + 立即吊销该绑定的 companion 会话 + 断开其 WS + 写 identity 审计） */
  @Post('unbind')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user')
  @ApiBearerAuth()
  @ApiOperation({ summary: '解绑打手账号（保留历史绑定行；立即吊销伴随会话 → 打手态下一次请求 401 中文）' })
  unbind(@CurrentUser() user: { userId: string }, @Body() dto: UnbindWorkerIdentityDto, @Req() req: Request) {
    // IP/UA 进解绑审计（审计 F4：解绑必须可追溯到"谁、从哪、用什么设备"）
    return this.service.unbind(user.userId, dto?.bindingId, {
      ip: clientIpOf(req),
      userAgent: req.header('user-agent') ?? '',
    });
  }

  /** 当前绑定状态（含打手档案摘要：工号/昵称/接单与客服权限/分部权限；不含任何敏感字段） */
  @Get()
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user')
  @ApiBearerAuth()
  @ApiOperation({ summary: '当前绑定状态（未绑定返回 bound:false；含打手档案摘要与绑定上限）' })
  status(@CurrentUser() user: { userId: string }) {
    return this.service.status(user.userId);
  }

  /** 伴随会话续期（公开：只接受 companion 的 refreshToken；续期后仍是 companion，TTL 仍 12h） */
  @Post('refresh')
  @HttpCode(200)
  @ApiOperation({ summary: '伴随会话续期（只接受 companion refreshToken；绑定失效则 401 中文）' })
  refresh(@Body() dto: RefreshCompanionDto, @Req() req: Request) {
    return this.service.refreshCompanion(dto.refreshToken, clientIpOf(req));
  }
}
