import { Controller, Get, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { WorkerDivisionPermissionService } from './worker-division-permission.service';

/**
 * 工作端：我的接单权限（按分部，负责人 2026-10-04）。
 *
 * 用途：工作端「我的」页展示自己有哪些分部的接单权限；接单大厅只在**有权限的分部**里出筛选胶囊。
 * 与所有接单接口一致：**每次请求实时查库**，管理端刚改的授权下一次请求就生效（无缓存）。
 */
@ApiTags('worker')
@Controller('worker')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class WorkerPermissionController {
  constructor(private readonly service: WorkerDivisionPermissionService) {}

  @Get('division-permissions')
  @ApiOperation({ summary: '我的接单权限（全部启用分部 + 是否已授权，实时查库）' })
  mine(@CurrentUser() user: { userId: string }) {
    return this.service.listForUser(user.userId);
  }
}
