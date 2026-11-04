import { Body, Controller, Get, Param, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsNumber, IsOptional, Max, Min } from 'class-validator';
import { Request } from 'express';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { ReviewService } from '../review/review.service';
import {
  DIM_LABELS,
  RatingDim6,
  WorkerRatingManualService,
} from '../worker/worker-rating-manual.service';

/**
 * 六维手填值请求体（`PUT /admin/workers/:id/rating-manual`）
 *
 * ## 语义：**逐字段局部更新**（与 `WorkerStatsDto` 的"整体覆盖"刻意不同，见服务类注释）
 *
 * | 形态 | 含义 |
 * |---|---|
 * | 字段**不出现**（省略） | 保持原值不动 |
 * | 数字 `0`–`10`（两位小数） | 设为该值 |
 * | `null` | **清除该项**（回到自动聚合） |
 *
 * 六个字段**全部可选**：运营经常只想改一维，强制全量回传会让"漏传一个"静默清空数据。
 *
 * ## 为什么 `0` 是合法值
 *
 * `0` = "这项 0 分"（管理端主动设的），与 `null`（= 没设 / 已清除）是两件事。
 * 列上 `NULL` 才是"未手动设"的哨兵，`0.00` 是一个真实取值 —— 所以 `@Min(0)` 而不是 `@Min(1)`。
 *
 * ## 宽松处理
 *
 * JSON 数字与数字字符串都收（`9.5` / `"9.5"` 等价）；空串按 **清除**（`null`）处理 ——
 * 管理端清空输入框后常见的提交形态是 `""`，把它当 400 只会让运营反复试错
 * （与 `WorkerDisplayStatsDto` 的既有姿势一致）。
 */
export class WorkerRatingManualDto {
  @ApiPropertyOptional({
    description: '「评分」轴手填值（0-10，两位小数）；null / 空串 = 清除该项（回到自动）；省略 = 不改',
    nullable: true,
    minimum: 0,
    maximum: 10,
    example: 9.6,
  })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 2 }, { message: `「${DIM_LABELS.score}」最多保留两位小数` })
  @Min(0, { message: `「${DIM_LABELS.score}」不能小于 0` })
  @Max(10, { message: `「${DIM_LABELS.score}」不能大于 10` })
  score?: number | null;

  @ApiPropertyOptional({ description: `「${DIM_LABELS.skill}」手填值（0-10，两位小数）；null = 清除；省略 = 不改`, nullable: true })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 2 }, { message: `「${DIM_LABELS.skill}」最多保留两位小数` })
  @Min(0, { message: `「${DIM_LABELS.skill}」不能小于 0` })
  @Max(10, { message: `「${DIM_LABELS.skill}」不能大于 10` })
  skill?: number | null;

  @ApiPropertyOptional({ description: `「${DIM_LABELS.emotion}」手填值（0-10，两位小数）；null = 清除；省略 = 不改`, nullable: true })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 2 }, { message: `「${DIM_LABELS.emotion}」最多保留两位小数` })
  @Min(0, { message: `「${DIM_LABELS.emotion}」不能小于 0` })
  @Max(10, { message: `「${DIM_LABELS.emotion}」不能大于 10` })
  emotion?: number | null;

  @ApiPropertyOptional({ description: `「${DIM_LABELS.stress}」手填值（0-10，两位小数）；null = 清除；省略 = 不改`, nullable: true })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 2 }, { message: `「${DIM_LABELS.stress}」最多保留两位小数` })
  @Min(0, { message: `「${DIM_LABELS.stress}」不能小于 0` })
  @Max(10, { message: `「${DIM_LABELS.stress}」不能大于 10` })
  stress?: number | null;

  @ApiPropertyOptional({ description: `「${DIM_LABELS.voice}」手填值（0-10，两位小数）；null = 清除；省略 = 不改`, nullable: true })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 2 }, { message: `「${DIM_LABELS.voice}」最多保留两位小数` })
  @Min(0, { message: `「${DIM_LABELS.voice}」不能小于 0` })
  @Max(10, { message: `「${DIM_LABELS.voice}」不能大于 10` })
  voice?: number | null;

  @ApiPropertyOptional({ description: `「${DIM_LABELS.shop}」手填值（0-10，两位小数）；null = 清除；省略 = 不改`, nullable: true })
  @IsOptional()
  @Transform(toNumberOrNull)
  @IsNumber({ maxDecimalPlaces: 2 }, { message: `「${DIM_LABELS.shop}」最多保留两位小数` })
  @Min(0, { message: `「${DIM_LABELS.shop}」不能小于 0` })
  @Max(10, { message: `「${DIM_LABELS.shop}」不能大于 10` })
  shop?: number | null;
}

/**
 * 取值归一（`@Transform`，`transform: true` 下生效）
 *
 * `null` / `undefined` / 空串 / 纯空白 → `null`（= 清除该项）；数字字符串 → 数字；
 * 其它原样交给 class-validator 去拒绝（**不在这里静默兜底**：非法值必须 400，
 * 否则"设了但没生效"会变成最难查的一类报障）。
 */
function toNumberOrNull({ value }: { value: unknown }): unknown {
  if (value === null || value === undefined) return null;
  if (typeof value === 'string') {
    const t = value.trim();
    if (!t) return null;
    const n = Number(t);
    return Number.isFinite(n) ? n : value;
  }
  return value;
}

/**
 * 管理端：手填打手六维评分（含雷达图数据，负责人 2026-10-18）
 *
 * ## 权限：`admin:worker:write`（**与既有打手管理同一个权限点，不新增**）
 *
 * 刻意**不加新权限点**：本能力是"编辑打手资料"的一部分（与 `PUT /admin/workers/:id/players-profile`
 * 同族），它只影响展示、不涉及钱、不涉及等级 —— 新增权限点只会产出"能改介绍却不能改展示分"的碎片授权。
 *
 * ## 两个接口
 *
 * | 方法 | 路径 | 说明 |
 * |---|---|---|
 * | GET | `/admin/workers/:id/rating-manual` | `{ manual, effective, sources, samples, updatedBy, updatedAt }` |
 * | PUT | `/admin/workers/:id/rating-manual` | body 六项均可选（0-10 两位小数；显式 null = 清除该项） |
 *
 * `:id` 是 **`worker.id`**（不是 `user.id`）—— 与本控制器的兄弟路由
 * （`PUT /admin/workers/:id/players-profile`、`POST /admin/workers/:id/permission`）同源。
 *
 * ## 审计（每次 PUT 必写 `operation_log`）
 *
 * `module='worker_rating_manual'`、`action='worker_rating_manual:save'`、
 * `request_body` 记 `before` / `after` **六维摘要** + 改动维度列表 ——
 * 只有打手 id 与六个数字，**不含任何隐私**（没有手机号/真实姓名/评价原文）。
 *
 * ## 红线（写在接口层，避免后人从这条路"顺手"改等级）
 *
 * **管理端手填值只影响展示，不影响等级判定，否则改分即可刷等级** ——
 * 本接口只写 `worker_rating_manual`，**不碰** `worker_rating_agg` / `worker_grade` /
 * `worker_stats` 任何一列；判级路径（`WorkerGradeService.metricsOf`）也不读本表。
 *
 * ## 读侧实时查库、无缓存
 *
 * PUT 成功后老板端下一次 `GET /public/workers/:id` 即生效（该接口已登记 `no-store`）。
 */
@ApiTags('admin/workers')
@Controller('admin/workers')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class WorkerRatingManualController {
  constructor(
    private readonly service: WorkerRatingManualService,
    private readonly opLog: OperationLogService,
    /** 好评率（「评分」轴自动值的来源）唯一口径出口 —— 与 `/public/workers/:id` 同一段实现 */
    private readonly review: ReviewService,
  ) {}

  @Get(':id/rating-manual')
  @RequirePermission('admin:worker:write')
  @ApiOperation({
    summary:
      '权限点 admin:worker:write：读打手六维手填值（manual 六列含 null / effective 生效值 / sources 逐维来源 / 老板评价条数）',
  })
  async detail(@Param('id') id: string) {
    /**
     * `effective` / `sources` 必须与老板端**逐字一致**，所以「评分」轴的自动值
     * （好评率 ÷ 10）也在这里传一次 —— 好评率来自 `ReviewService.publicWorkerStats`
     * （**唯一口径出口**，与 `/public/workers/:id` 同源），本控制器不重算。
     *
     * 少传这一步的后果很具体：管理端看到 `sources.score = 'none'`（"没数据"），
     * 而老板端其实显示着 9.86 —— 那种"同一维度两个页面两种结论"正是要消灭的。
     */
    const stats = await this.review.publicWorkerStats([id]);
    const rate = stats.get(String(id))?.satisfiedRate ?? null;
    return this.service.detailForAdmin(id, scoreFromRate(rate));
  }

  @Put(':id/rating-manual')
  @RequirePermission('admin:worker:write')
  @ApiOperation({
    summary:
      '权限点 admin:worker:write：保存六维手填值（六项均可选，0-10 两位小数；显式 null = 清除该项回自动）；只影响展示，不影响等级',
  })
  async save(
    @Param('id') id: string,
    @Body() dto: WorkerRatingManualDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    // 只取六个**声明过的**字段（`undefined` = 未出现 = 保持原值；`null` = 清除）
    const input: Partial<Record<RatingDim6, number | null>> = {};
    for (const dim of WorkerRatingManualService.DIMS) {
      if (!(dim in dto)) continue;
      input[dim] = dto[dim] ?? null;
    }

    const result = await this.service.saveForAdmin(id, input, user.userId ?? null);

    /**
     * 留痕（docs/03：管理端写接口必须写 operation_log）。
     * `requestBody` 只放关键字段与**变更前后六维摘要** —— 无隐私、无 token、无超长原文。
     */
    const changed = WorkerRatingManualService.DIMS.filter(
      (d) => (result.audit.before[d] ?? null) !== (result.audit.after[d] ?? null),
    );
    this.opLog.log({
      adminUserId: user.userId ?? null,
      adminName: '',
      module: WorkerRatingManualService.LOG_MODULE,
      action: 'worker_rating_manual:save',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        workerId: result.audit.workerId,
        before: result.audit.before,
        after: result.audit.after,
        changed,
        beforeUpdatedBy: result.audit.beforeUpdatedBy,
        beforeUpdatedAt: result.audit.beforeUpdatedAt,
      }),
      ip: req.ip,
      requestId: req.requestId,
    });

    return {
      workerId: result.workerId,
      manual: result.manual,
      effective: result.effective,
      sources: result.sources,
      samples: result.samples,
      updatedBy: result.updatedBy,
      updatedAt: result.updatedAt,
    };
  }
}

/**
 * 好评率百分数字符串 → 「评分」轴（0–10，两位小数）
 *
 * 与 `public-workers.controller.ts#scoreFromRate` **同一口径**（`98.6%` → `9.86`、`null` → `null`）：
 * 管理端读到的 `effective.score` 必须与老板端逐字相同，否则"同一维度两个页面两种结论"。
 *
 * 为什么不抽成公共函数：它是**三行纯换算**，且两个控制器的入参来源不同
 * （公开侧用 `profile.satisfiedRate`，管理端用 `publicWorkerStats().satisfiedRate`）——
 * 抽出去会多一个"公共 utils"落点，而这里真正的口径红线（好评率怎么算）已经收在
 * `ReviewService.satisfiedRateText` 一处。若将来这份换算要改（例如换量程），
 * 两处必须一起改，因此两处注释都写明了对方的位置。
 */
function scoreFromRate(rate: string | null | undefined): number | null {
  if (rate === null || rate === undefined) return null;
  const percent = Number(String(rate).replace('%', '').trim());
  if (!Number.isFinite(percent)) return null;
  return Math.min(10, Math.max(0, Math.round((percent / 10 + Number.EPSILON) * 100) / 100));
}
