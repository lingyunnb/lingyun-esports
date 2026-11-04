import { Body, Controller, Get, HttpCode, NotFoundException, Post, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { ConfigService } from '@nestjs/config';
import { Request } from 'express';
import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { AuthService } from './auth.service';
import { EmailCodeService, isEmailScene } from './email-code.service';
import {
  LoginDto,
  LogoutDto,
  QqBindDto,
  QqLoginDto,
  RefreshDto,
  RegisterDto,
  ResetPasswordDto,
  SendEmailCodeDto,
} from './dto/auth.dto';

@ApiTags('auth')
@Controller('auth')
export class AuthController {
  constructor(
    private readonly authService: AuthService,
    /** RealtimeModule 是 @Global（与 RechargeService / BindingReleaseService 同一注入方式）：登出后主动断开 WS */
    private readonly realtime: RealtimeGateway,
  ) {}

  /** 公开：老板端注册（工作端/管理员账号由后台创建，docs/04） */
  @Post('register')
  @ApiOperation({ summary: '公开：老板端注册（可选邮箱+邮箱验证码；不传 email 时行为与旧版一致）' })
  register(@Body() dto: RegisterDto) {
    return this.authService.register(dto);
  }

  /**
   * 公开：获取邮箱验证码（负责人 2026-10-05：邮箱验证替代短信验证）
   * 限流：同邮箱 60s / 同邮箱 5次·小时 / 同 IP 10次·小时；响应**不回显验证码**
   *
   * 2026-10-10 扩展 `scene`：`bind`（绑定/换绑邮箱）、`login`（邮箱验证码登录）。
   * 防枚举口径：**`login`（邮箱未绑定账号）与 `reset`（邮箱未注册）两个场景下，响应与真发逐字相同、
   * 限流与额度消耗也与存在侧逐字相同**（两者**不发信，但照扣额度** —— 否则"连发第二次 429/200 的差异"
   * 就是账号枚举 oracle；`login` 于 2026-10-10 第一批修复、`reset` 于同批第二批修复）；
   * `bind` 场景按限流正常发信（唯一性冲突在 `POST /user/email/bind` 处以中文 409 给出），
   * `register` 场景按设计对已注册邮箱显式 400。
   */
  @Post('email/code')
  @HttpCode(200)
  @ApiOperation({ summary: '公开：获取邮箱验证码（scene: register/reset/bind/login；防枚举；响应不回显验证码）' })
  sendEmailCode(@Body() dto: SendEmailCodeDto, @Req() req: Request) {
    return this.authService.sendEmailCode(dto, this.clientIp(req), req.header('user-agent') ?? '');
  }

  /** 公开：邮箱验证码找回密码（不依赖旧密码；成功后吊销该账号全部会话，需重新登录） */
  @Post('password/reset')
  @HttpCode(200)
  @ApiOperation({ summary: '公开：邮箱验证码重置密码（成功后吊销该用户全部 access/refresh 会话）' })
  resetPassword(@Body() dto: ResetPasswordDto, @Req() req: Request) {
    return this.authService.resetPasswordByEmail(dto, this.clientIp(req), req.header('user-agent') ?? '');
  }

  /**
   * 公开：三端统一登录入口，按 role 分流校验（docs/04）
   *
   * 2026-10-10：同一入口支持**邮箱验证码登录**（传 `email` + `emailCode` 即走该路径，忽略 `username/password`）。
   * 失败统一中文 400「邮箱或验证码错误」（不区分"邮箱没绑账号"与"码不对"，防枚举）；
   * 成功仍是一条 **primary** 会话 → 单设备顶号语义与密码登录完全一致。
   */
  @Post('login')
  @HttpCode(200)
  @ApiOperation({ summary: '公开：登录（role: user/worker/admin；可选邮箱验证码登录；限流 5次/分/IP+账号）' })
  login(@Body() dto: LoginDto, @Req() req: Request) {
    return this.authService.login(dto, this.clientIp(req), req.header('user-agent') ?? '');
  }

  /**
   * 公开：QQ 登录（2026-10-10）。
   *
   * 服务端**自己**用 `access_token` 调腾讯 `oauth2.0/me` 取权威 openid（客户端传的只用于比对），
   * 已绑定 → 登录该账号；未绑定 → 建新老板账号并写 `user_oauth`。
   * 未配置 `QQ_APP_ID`/`QQ_APP_KEY` → **中文 503「QQ 登录未配置」**（不做任何网络调用）。
   */
  @Post('qq/login')
  @HttpCode(200)
  @ApiOperation({ summary: '公开：QQ 登录（服务端复核 openid；未配置 → 中文 503；未绑定则建号）' })
  loginByQq(@Body() dto: QqLoginDto, @Req() req: Request) {
    return this.authService.loginByQq(dto, this.clientIp(req), req.header('user-agent') ?? '');
  }

  /** 已登录：把 QQ 绑到当前账号（主体只取 JWT；一个 QQ 只能绑一个账号，重复绑自己幂等成功） */
  @Post('qq/bind')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard, RolesGuard)
  @Roles('user')
  @ApiBearerAuth()
  @ApiOperation({ summary: '绑定 QQ 到当前账号（服务端复核 openid；已绑别的账号 → 中文 409）' })
  bindQq(@CurrentUser() user: { userId: string }, @Body() dto: QqBindDto, @Req() req: Request) {
    return this.authService.bindQq(user.userId, dto, this.clientIp(req), req.header('user-agent') ?? '');
  }

  /** 公开：refresh 轮换（docs/04） */
  @Post('refresh')
  @HttpCode(200)
  @ApiOperation({ summary: '公开：刷新令牌（轮换制，旧 refresh 即吊销）' })
  refresh(@Body() dto: RefreshDto, @Req() req: Request) {
    return this.authService.refresh(dto.refreshToken, this.clientIp(req));
  }

  /** 隧道回源（回环）时以 CF-Connecting-IP 还原真实客户端 IP；直连时不信任该头（防伪造绕过限流）
   *  —— 2026-10-06 抽到 `common/client-ip.ts`（身份绑定接口用同一套判定，限流键必须一致） */
  private clientIp(req: Request): string {
    return clientIpOf(req);
  }

  /**
   * 登出（docs/04）：**把这次登录的全部令牌（access + refresh）一次吊销**。
   *
   * - `userId` 由守卫从**库中会话登记行**取出（`request.user.userId`），用它把该账号该族的活行收干净；
   *   客户端**不传** `refreshToken` 也保证退干净（旧实现漏的正是这一条：实测残留 `revoked=0` 的 refresh 行）；
   * - `kind` 同样以库中登记为准 ⇒ companion / recharge 登出**绝不触碰 primary**；
   * - `revokedJtis` 交给 `RealtimeGateway.disconnectByJti()` 主动断开这些会话已建立的 WS
   *   （新增行为，默认事件与 companion/recharge 释放路径一致）。
   */
  @Post('logout')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: '登出（吊销本次登录的全部会话行：access + refresh；三类会话同一规则）' })
  async logout(@Body() dto: LogoutDto, @CurrentUser() user: { userId: string; role: string; jti: string }) {
    const r = await this.authService.logout(user.jti, dto.refreshToken, user.userId);
    // 登出即吊销 → 已建立的 WS 必须主动断开（F1 同类根因：只改库不踢线 = 旧连接继续收消息）
    this.realtime.disconnectByJti(r.revokedJtis, 'auth:expired');
    return { ok: r.ok };
  }

  @Post('password')
  @HttpCode(200)
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: '修改密码（校验旧密码；改密后全部会话吊销需重新登录）' })
  changePassword(@Body() dto: { oldPassword: string; newPassword: string }, @CurrentUser() user: { userId: string }) {
    return this.authService.changePassword(user.userId, dto);
  }

  @Get('me')
  @UseGuards(JwtAuthGuard)
  @ApiBearerAuth()
  @ApiOperation({ summary: '当前登录主体信息（worker 附权限位、admin 附角色与权限点）' })
  me(@CurrentUser() user: { userId: string; role: string }) {
    return this.authService.me(user);
  }
}

/**
 * **仅自动化测试用**的邮箱验证码检查端点（父任务要求「补一条测试用注入点」）。
 *
 * 安全设计（为什么不能把 verify 做成公开接口）：
 * - 「校验正确码 → 一次性作废」意味着**任何会消费验证码的公开接口都是攻击面**：
 *   若 `POST /auth/email/verify` 公开，攻击者只要猜到/试到码就能在真正注册前把码烧掉；
 *   更糟的是它与 register/reset 争抢同一份一次性凭据，会产生难以推理的竞态。
 * - 因此生产接口只保留 **email/code（发码）+ register / password/reset（内部验码）**，
 *   校验逻辑作为**内部能力**放在 EmailCodeService，由业务方法调用。
 * - 本控制器仅用于测试断言「生成/校验/过期/一次性/错满 5 次」这些**内部规则**：
 *   每条路由先调 `ensureTestMode()`，**任何非 `MAIL_DRIVER=console` 的部署一律 404**（生产不可达）。
 */
@ApiTags('auth-test')
@Controller('auth/email/_test')
export class AuthEmailTestController {
  constructor(
    private readonly emailCode: EmailCodeService,
    private readonly config: ConfigService,
  ) {}

  /**
   * 生产守卫（**唯一一把钥匙**）：必须显式 `MAIL_ALLOW_TEST_ENDPOINTS=true`，否则一律 404。
   *
   * 为什么不再要求 MAIL_DRIVER=console：真实通道端到端测试需要在 **smtp 驱动（真发信）** 下读取
   * Redis 里的验证码来做断言（生产接口绝不回显验证码），若同时要求 console 驱动就无法两全。
   * 生产只需保证这一项为 false（默认即 false；.env.example 里也写明生产必须 false）。
   */
  private ensureTestMode(): void {
    if (String(this.config.get<string>('MAIL_ALLOW_TEST_ENDPOINTS', 'false')).toLowerCase() !== 'true') {
      throw new NotFoundException();
    }
  }

  /** 读取 Redis 里当前有效码（仅测试；生产 404） */
  @Get('peek')
  @ApiOperation({ summary: '【测试专用】查看当前有效验证码（非 console 驱动返回 404）' })
  async peek(@Req() req: Request) {
    this.ensureTestMode();
    const email = String(req.query.email ?? '').trim().toLowerCase();
    const scene = String(req.query.scene ?? '');
    if (!email || !isEmailScene(scene)) {
      throw new NotFoundException();
    }
    const { code, expired } = await this.emailCode.describeCodeForTest(email, scene);
    return { email, scene, code, expired };
  }

  /** 校验验证码（仅测试；生产 404）。返回判定结果，不抛业务异常，便于断言各分支 */
  @Post('verify')
  @HttpCode(200)
  @ApiOperation({ summary: '【测试专用】校验验证码（非 console 驱动返回 404）' })
  async verify(@Body() body: { email?: string; scene?: string; code?: string }) {
    this.ensureTestMode();
    const email = String(body?.email ?? '').trim().toLowerCase();
    const scene = String(body?.scene ?? '');
    if (!email || !isEmailScene(scene)) {
      throw new NotFoundException();
    }
    const outcome = await this.emailCode.verifyCode(email, scene, String(body?.code ?? ''));
    return outcome.ok ? { ok: true } : { ok: false, reason: outcome.reason };
  }

  /** 开关「把发信结果打桩为失败」（仅测试；生产 404） */
  @Post('fail-mode')
  @HttpCode(200)
  @ApiOperation({ summary: '【测试专用】打桩发信失败（非 console 驱动返回 404）' })
  async failMode(@Body() body: { on?: boolean; scope?: string }) {
    this.ensureTestMode();
    const on = body?.on === true;
    const scope = String(body?.scope ?? 'smtp');
    await this.emailCode.setForceFail(on);
    return { ok: true, forceFail: on, scope };
  }
}
