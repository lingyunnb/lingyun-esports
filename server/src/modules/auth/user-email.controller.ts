import { Body, Controller, Get, HttpCode, Post, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { BindEmailDto } from './dto/auth.dto';
import { EmailBindingService } from './email-binding.service';

/**
 * 邮箱绑定 / 换绑 + 邮箱状态（负责人 2026-10-10）。
 *
 * 路由挂在 `/user/*`（与 `/user/profile`、`/user/identity` 同族）：它是**账号设置页**的能力，
 * 主体 id 只取 JWT `sub`（守卫注入），请求体里没有也不需要 userId。
 *
 * ## 角色范围（**这是需要负责人确认的一处取舍，见报告**）
 * `@Roles('user', 'worker')` —— 老板与打手**都能用**：
 * - 老板（role=user）是主要使用者（设置页绑定邮箱、用邮箱码登录）；
 * - 打手（role=worker）：打手账号也是平台账号，将来同样需要邮箱找回/登录能力，
 *   而"打手态"（companion）**不是** primary 会话，**不在此列**（见下条），因此现在放行 worker primary
 *   不会让任何人凭空获得额外能力（到期收口后 worker primary 本身就会被 401 挡掉）；
 * - **管理员（role=admin）刻意不放行**：管理端账号由后台创建、走 PC 后台登录，
 *   给它开一个"外部邮箱通道"等于给最高权限面多开一条登录路径（同样的登录路径口子在
 *   `POST /auth/login` 已存在，但前提是账号**先有已验邮箱** —— 本接口是唯一能写入该邮箱的入口，
 *   所以把这里收窄，admin 就永远拿不到"邮箱码登录"这条路）。
 *
 * ## 为什么 companion（打手态）不能用（**刻意保持默认拒绝**）
 * `jwt-auth.guard.ts` 的 `isCompanionAllowedRoute` 是**允许清单**，`/user/email/*` 不在其中 → 403 中文。
 * 这一条**必须保持**：companion 是老板手上 12h 的受限会话，若它能改打手账号的邮箱，
 * 老板就能"绑自己的邮箱 → 用找回密码改掉打手密码 → 永久占有打手账号"（越权面）。
 * 因此本控制器**不得**被加进 companion 白名单（测试用例 ⑧ 附近有相应断言）。
 */
@ApiTags('user/email')
@Controller('user')
export class UserEmailController {
  constructor(private readonly service: EmailBindingService) {}

  /**
   * 绑定 / 换绑邮箱：**当前密码 + 新邮箱验证码**（负责人拍板 2，不是旧邮箱码）。
   *
   * 中文错误码：`密码错误`(400) / `验证码错误`・`验证码已过期，请重新获取`・
   * `验证码错误次数过多，请重新获取`(400) / `该邮箱已被其他账号绑定`(409) / 未登录(401) / 角色不符(403)。
   */
  @Post('email/bind')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user', 'worker')
  @ApiBearerAuth()
  @ApiOperation({ summary: '绑定/换绑邮箱（当前密码 + 新邮箱验证码；换绑 = 覆盖；一个邮箱只能绑一个账号）' })
  bind(@CurrentUser() user: { userId: string }, @Body() dto: BindEmailDto, @Req() req: Request) {
    return this.service.bind(user.userId, dto, clientIpOf(req), req.header('user-agent') ?? '');
  }

  /** 当前账号的邮箱状态：**脱敏**邮箱 + 是否已验证（设置页展示用；完整邮箱不下发） */
  @Get('email')
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user', 'worker')
  @ApiBearerAuth()
  @ApiOperation({ summary: '我的邮箱状态（脱敏邮箱 + verified；完整邮箱不下发）' })
  status(@CurrentUser() user: { userId: string }) {
    return this.service.status(user.userId);
  }
}
