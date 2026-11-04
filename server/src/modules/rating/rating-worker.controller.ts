import { Controller, Get, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { WorkerGradeService } from './worker-grade.service';

/**
 * 打手态：我的等级 + 升级进度（负责人已审批 2026-10-17）
 *
 * 会话类型（三种都真实存在，与 `worker-profile.controller.ts` 同一张矩阵）：
 *
 * | 调用者 | 结果 | 由谁拦 |
 * |---|---|---|
 * | companion（老板端打手态） | 200 | `/worker/*` 在 companion 允许清单内 + `@Roles('worker')` |
 * | worker primary（旧工作端/脚本） | 200 | `@Roles('worker')`（到期收口 `worker-app-sunset` 独立生效） |
 * | 老板 primary（role=user） | 403 | `RolesGuard` |
 * | 管理端 primary / 受限会话 | 403 | 同上 / 白名单不含 `/admin/*` |
 *
 * **主体只从 `@CurrentUser()` 取**（= 守卫从 `auth_token` 反查的 `sub`）：本接口没有路径参数、
 * 也没有请求体 —— 「看别人的等级」这条路径在协议层面不存在。
 * 五维均分与进度用的是与公开详情**同一个** `WorkerGradeService.detail()`，因此两处口径逐字一致。
 */
@ApiTags('worker')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class RatingWorkerController {
  constructor(private readonly grade: WorkerGradeService) {}

  @Get('grade')
  @ApiOperation({
    summary: '我的打手等级（grade/gradeLabel/gradeName + 五维均分与样本数 + 距下一级还差多少）',
  })
  mine(@CurrentUser() user: { userId: string }) {
    return this.grade.myDetail(user.userId);
  }
}
