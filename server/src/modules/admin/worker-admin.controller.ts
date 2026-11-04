import { Body, Controller, Get, Param, Post, Put, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { IsInt, IsOptional, IsString, MaxLength } from 'class-validator';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { LenientUpdateDto } from '../../common/pipes/lenient-validation.pipe';
import { OperationLogService } from '../log/operation-log.service';
import { ReviewService } from '../review/review.service';
import {
  CreateWorkerDto,
  PageQueryDto,
  UpdateWorkerDto,
  UpdateWorkerPermissionDto,
  WorkerDisplayStatsDto,
} from './dto/worker-admin.dto';
import { WorkerAdminService } from './worker-admin.service';

/**
 * 陪玩资料（负责人 2026-10-03）：介绍由管理端填写，客户端「找陪玩」列表只展示 名字 + 介绍。
 *
 * 继承 LenientUpdateDto：允许回传整行（含 id/userId/canTakeOrder 等）——
 * 多余字段静静忽略而不是 400（管理端「改陪玩介绍」报障修复）。
 */
export class PlayersProfileDto extends LenientUpdateDto {
  @ApiPropertyOptional({ description: '陪玩介绍（客户端列表正文；≤200 字）' })
  @IsOptional()
  @IsString()
  @MaxLength(200)
  intro?: string;

  @ApiPropertyOptional({ description: '归属分部 id（游戏 + 平台）' })
  @IsOptional()
  @IsString()
  divisionId?: string;

  @ApiPropertyOptional({ description: '工作端状态：1 在职 / 2 停用' })
  @IsOptional()
  @IsInt()
  status?: number;
}

/** 工作端管理（docs/04）：全部接口 = JWT + admin 角色 + RBAC 权限点 */
@ApiTags('admin/workers')
@Controller('admin/workers')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class WorkerAdminController {
  constructor(
    private readonly service: WorkerAdminService,
    /**
     * 展示值（接单次数/好评率）的读写**刻意走 `ReviewService`**（负责人 2026-10-16）：
     * 那两个数字的**唯一口径**在那里 —— `publicWorkerStats()` 是老板端列表/详情/首页共用的
     * 同一个出口，`satisfiedRateText()` 是百分数字符串的唯一生成点。
     * 若在本模块再写一遍 `worker_stats` 查询与好评率格式化，就会立刻出现
     * "管理端显示 98.2、老板端显示 98.0"这类两套口径（安全审计 F1 的同一类根因）。
     */
    private readonly review: ReviewService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get()
  @RequirePermission('admin:worker:read')
  @ApiOperation({ summary: '权限点 admin:worker:read：工作端列表（分页+搜索）' })
  list(@Query() q: PageQueryDto) {
    return this.service.list(q.page ?? 1, q.pageSize ?? 20, q.keyword ?? '');
  }

  @Post()
  @RequirePermission('admin:worker:write')
  @ApiOperation({ summary: '权限点 admin:worker:write：创建工作端账号（默认无接单/客服权限）' })
  async create(
    @Body() dto: CreateWorkerDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.create(dto);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'worker',
      action: 'worker:create',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ username: dto.username, workerNo: dto.workerNo }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  @Put(':id')
  @RequirePermission('admin:worker:write')
  @ApiOperation({ summary: '权限点 admin:worker:write：编辑工作端档案（真实姓名/电话/状态）' })
  update(@Param('id') id: string, @Body() dto: UpdateWorkerDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    // 停用会释放老板↔打手绑定：带上触发者与请求证据（审计 F4）
    return this.service.update(id, dto, {
      adminUserId: user.userId,
      ip: req.ip,
      userAgent: req.header('user-agent') ?? '',
    });
  }

  @Post(':id/permission')
  @RequirePermission('admin:worker:permission')
  @ApiOperation({
    summary: '权限点 admin:worker:permission（默认仅超管）：授予/取消接单（可按分部）或客服权限，立即生效',
  })
  async updatePermission(
    @Param('id') id: string,
    @Body() dto: UpdateWorkerPermissionDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updatePermission(id, dto);
    // 权限变更必须留痕（docs/04）：全局开关 + **按分部的逐项前后值**都记进 operation_log
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'worker',
      action: `worker:permission:${dto.type}`,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        workerId: id,
        type: dto.type,
        // 请求里的目标（单分部 / 勾选集合 / 全局）
        requestDivisionId: dto.divisionId ?? null,
        requestDivisionIds: dto.divisionIds ?? null,
        before: result.before,
        after: result.after,
        // 变更留痕：授权前后分部集合 + 逐项前后值
        beforeDivisionIds: result.beforeDivisionIds,
        afterDivisionIds: result.divisionIds,
        divisionChanges: result.changes,
      }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  /**
   * 陪玩介绍（负责人 2026-10-03 硬规则）
   *
   * 「找陪玩」列表**只显示 名字 + 介绍**，介绍由管理端在此维护；
   * 写入 user.intro 并记录修改人，便于审计。
   */
  @Put(':id/players-profile')
  @RequirePermission('admin:worker:write')
  @ApiOperation({ summary: '权限点 admin:worker:write：设置陪玩资料（介绍 + 归属分部；介绍即「找陪玩」列表正文）' })
  async setPlayersProfile(
    @Param('id') id: string,
    @Body() dto: PlayersProfileDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const before = await this.service.getPlayersProfile(id);
    const result = await this.service.setPlayersProfile(id, dto, user.userId, {
      adminUserId: user.userId,
      ip: req.ip,
      userAgent: req.header('user-agent') ?? '',
    });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'worker',
      action: 'worker:players-profile',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ workerId: id, before, after: { intro: dto.intro, divisionId: dto.divisionId } }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  /**
   * 展示值三联（负责人 2026-10-16）：**真实值 / 展示值 / 最终生效值**
   *
   * 为什么要一条独立接口：管理端只显示"生效值"会让运营看不出"这个数字是人设的还是真的"，
   * 而只显示真实值又会对不上老板端屏幕上看到的数字。三段一起给，
   * 运营一眼能判断"要不要调、调的是哪一个"。
   *
   * 权限点 `worker:adjust`（migration 1815001000000 只授予 `super_admin`）：
   * **读写共用这一个点**（与 `review:moderate` 同口径）—— 只拆一个只读点，
   * 只会产出"能看到却点不动"的空壳授权。
   */
  @Get(':id/stats')
  @RequirePermission('worker:adjust')
  @ApiOperation({
    summary: '权限点 worker:adjust（默认仅超管）：真实值/展示值/生效值三联（真实值与老板端同源同实现）',
  })
  displayStats(@Param('id') id: string) {
    return this.review.workerStatsView(id);
  }

  /**
   * 设置展示值（`PUT /admin/workers/:id/display-stats`，权限点 `worker:adjust`）
   *
   * 口径（负责人 2026-10-16）：
   * - **`completedOrders` / `satisfiedRate` 可调**（展示值）；**省略或 `null` = 恢复跟随真实**；
   * - 范围：`completedOrders` 0–999999、`satisfiedRate` 百分数 0.0–100.0（最多 1 位小数）；
   * - `reviewCount` 与评价列表**不受影响**（本接口连字段都不接受）——
   *   「数字可调、评价必须真实」，评价可见性治理仍只走 `review:moderate`；
   * - 真实战绩（结算/退款冲正维护的 `worker_stats.completed_orders`）**一个字都不改**。
   *
   * 必须写 `operation_log`（docs/03）：`module='worker'`、`action='worker:adjust-stats'`，
   * `request_body` 记 `before` / `after` 变更前后值与真实值摘要 —— **不记任何个人隐私**（只有数字与打手 id）。
   *
   * 返回**更新后的完整三联**（同一个响应形状与 `GET .../stats` 一致）：管理端不必再取一次。
   */
  @Put(':id/display-stats')
  @RequirePermission('worker:adjust')
  @ApiOperation({
    summary: '权限点 worker:adjust（默认仅超管）：设置接单次数/好评率展示值（null/省略 = 跟随真实；返回更新后三联）',
  })
  async setDisplayStats(
    @Param('id') id: string,
    @Body() dto: WorkerDisplayStatsDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.review.setWorkerDisplayStats(id, dto);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'worker',
      action: 'worker:adjust-stats',
      method: req.method,
      path: req.path,
      // 只记关键字段与变更前后摘要：两个数字 + 打手 id（无手机号/无评价原文/token）
      requestBody: JSON.stringify(result.audit),
      ip: req.ip,
      requestId: req.requestId,
    });
    return { workerId: result.workerId, real: result.real, display: result.display, effective: result.effective };
  }
}
