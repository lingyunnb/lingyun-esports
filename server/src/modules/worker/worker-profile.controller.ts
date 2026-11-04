import { Body, Controller, Get, Put, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiProperty, ApiTags } from '@nestjs/swagger';
import { IsNotEmpty, IsOptional, IsString } from 'class-validator';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { WorkerProfileService } from './worker-profile.service';

/**
 * 请求体。**刻意不继承 `LenientUpdateDto`**：
 * 那种宽松语义是给管理端"回传整行"用的；本接口对多带字段一律 400（白名单铁律），
 * 这样 `{intro, workerId: 别人的id}` 这类尝试会被网关层直接拒绝，连 service 都进不来。
 *
 * 这里只做"是不是字符串"这一步；**业务语义（长度/换行/联系方式）全部在
 * `worker-intro.rules.ts` 的纯函数里**（唯一实现，可单测）。
 *
 * ⚠️ **必须声明在 Controller 之前**：Nest 用 `design:paramtypes` 反射注入 DTO，
 * 类声明在后面时 `tsc --noEmit` 照样通过，但运行时会
 * `ReferenceError: Cannot access 'UpdateWorkerIntroDto' before initialization`
 * （manager 与本文件的注入顺序共用一个 emit 作用域）。管理端 `worker-admin.controller.ts`
 * 的 `PlayersProfileDto` 也是同一个写法。
 */
export class UpdateWorkerIntroDto {
  @ApiProperty({
    description: '陪玩介绍（2–120 字；最多 1 个换行；禁止首尾空白；不得含手机号/微信号/QQ 号）',
    example: '和平精英双排老手，稳定上分不墨迹。工作日 20:00-次日 1:00 在线。',
    required: false,
  })
  @IsOptional()
  @IsString({ message: '简介格式不正确' })
  @IsNotEmpty({ message: '简介不能为空' })
  intro?: string;

  // ── 头像 / 主页背景（负责人 2026-10-18：打手可自定义）──────────────────
  //
  // 两者都是**可选**：不传 = 不改（与 intro 的三态语义一致：
  // 传了才动，没传保持原值 —— 绝不因为少传一个字段就把它清空）。
  // `null` 显式传入 = 清除（回到默认字标 / 默认场）。

  @ApiProperty({ description: '头像 mediaId（null = 清除回默认）', required: false, nullable: true })
  @IsOptional()
  @IsString({ message: '头像参数格式不正确' })
  avatarMediaId?: string | null;

  @ApiProperty({ description: '主页背景 mediaId（null = 清除回默认）', required: false, nullable: true })
  @IsOptional()
  @IsString({ message: '背景参数格式不正确' })
  backgroundMediaId?: string | null;
}

/**
 * 打手简介（陪玩介绍）自写接口 —— 负责人 2026-10-17 改定
 *
 * 结构规则 6 原定「介绍由管理端填写」；本轮改为**打手自己写**，管理端保留兜底修改能力
 * （`PUT /admin/workers/:id/players-profile`，一行未改）。
 *
 * ============================ 为什么落在 `/worker/` 前缀下 ============================
 * 边界靠**既有白名单**兜住，不新增一条规则：
 * `JwtAuthGuard.isCompanionAllowedRoute()` 里 `p === '/worker' || p.startsWith('/worker/')` → true，
 * 即**老板端打手态（companion 会话）天然可调**；若放在 `/user/...` 前缀下就必须显式加白名单
 * （companion 是**允许清单**：不加即整族 403），那是一处需要长期维护的额外规则。
 *
 * ============================ 会话类型矩阵（三种都真实存在）============================
 * | 调用者                        | 结果 | 由谁拦 |
 * |------------------------------|------|--------|
 * | companion（老板端打手态）      | 200  | 白名单放行 `/worker/*` + `@Roles('worker')`（companion 的 role 就是 worker） |
 * | worker primary（旧工作端/脚本）| 200  | `@Roles('worker')`；到期收口 `worker-app-sunset` 独立生效，本文不改它 |
 * | **老板 primary（role=user）**  | **403** | `RolesGuard`：role='user' 不在 `@Roles('worker')` 里 → 「无权限访问」 |
 * | 管理端 primary（role=admin）   | 403  | 同上（管理端改简介走自己的 `/admin/workers/:id/players-profile`） |
 * | 受限会话 `kind='recharge'`     | 403  | 充值管理员白名单不含 `/worker/*` |
 *
 * 主体 id **只从 `@CurrentUser()` 取**（= 守卫从 `auth_token` 反查出的 `sub`），
 * 请求体里**没有** workerId/userId 字段 —— 带了会被全局管道 400 掉（`forbidNonWhitelisted`）。
 */
@ApiTags('worker')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class WorkerProfileController {
  constructor(private readonly service: WorkerProfileService) {}

  @Get('profile')
  @ApiOperation({ summary: '我的陪玩介绍（打手态「我的」页回填；只读自己的）' })
  mine(@CurrentUser() user: { userId: string }) {
    return this.service.getIntro(user.userId);
  }

  @Put('profile')
  @ApiOperation({
    summary: '修改我的陪玩资料（简介 / 头像 / 主页背景；主体只从令牌取，不接受 workerId）',
  })
  async update(@CurrentUser() user: { userId: string }, @Body() dto: UpdateWorkerIntroDto) {
    // 字段**逐个显式下传**（不是 `...dto`）：即使将来 DTO 加了字段，也绝不会把身份类字段
    // 带进写库路径。三者互不影响：简介只在传了 intro 时校验/写库，头像与背景同理。
    let intro: string | undefined;
    if (dto.intro !== undefined) {
      const r = await this.service.setIntro(user.userId, dto.intro);
      intro = r.intro;
    }
    const media =
      dto.avatarMediaId !== undefined || dto.backgroundMediaId !== undefined
        ? await this.service.setMedia(user.userId, {
            avatarMediaId: dto.avatarMediaId,
            backgroundMediaId: dto.backgroundMediaId,
          })
        : null;

    return {
      ok: true,
      ...(intro !== undefined ? { intro } : {}),
      ...(media ?? {}),
    };
  }
}
