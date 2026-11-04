import { Body, Controller, ForbiddenException, Get, Param, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiProperty, ApiPropertyOptional, ApiTags } from '@nestjs/swagger';
import { InjectDataSource } from '@nestjs/typeorm';
import { IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import { Request } from 'express';
import { DataSource } from 'typeorm';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { WORKER_GRADE_MAX, WORKER_GRADE_MIN } from '../worker/worker-grade.constants';
import { WorkerGradeService } from './worker-grade.service';

/**
 * 设置打手等级请求体（`PUT /admin/workers/:id/grade`）
 *
 * 只接受 `grade` + `note` 两个字段（多带一个 → 全局白名单 400）。
 * `grade` 允许 **1–5 全档，含最高档** —— 「宗师只能人工设置」正是靠这条接口落地的。
 * 「操作人是谁」**只从 `@CurrentUser()` 取**，请求体里的 `adminId` / `workerId` 一律不认。
 */
export class SetWorkerGradeDto {
  @ApiProperty({
    description: `等级 ${WORKER_GRADE_MIN}-${WORKER_GRADE_MAX} 的整数（LV1 初出 / LV2 立足 / LV3 扬名 / LV4 称雄 / LV5 宗师）`,
    minimum: WORKER_GRADE_MIN,
    maximum: WORKER_GRADE_MAX,
  })
  @IsInt({ message: `等级必须是 ${WORKER_GRADE_MIN}-${WORKER_GRADE_MAX} 的整数` })
  @Min(WORKER_GRADE_MIN, { message: `等级必须是 ${WORKER_GRADE_MIN}-${WORKER_GRADE_MAX} 的整数` })
  @Max(WORKER_GRADE_MAX, { message: `等级必须是 ${WORKER_GRADE_MIN}-${WORKER_GRADE_MAX} 的整数` })
  grade!: number;

  @ApiPropertyOptional({ description: '备注（≤100 字；落 worker_grade.note 并进 operation_log）' })
  @IsOptional()
  @IsString({ message: '备注格式不正确' })
  @MaxLength(100, { message: '备注最多 100 字' })
  note?: string;
}

/**
 * 管理端：人工设置打手等级（负责人已审批 2026-10-17）
 *
 * ## 权限：**仅超管**（`super_admin` 角色 或 `admin.is_owner = 1`）
 *
 * 刻意**不挂 `@RequirePermission(...)`**，只做 `assertSuperAdmin()` 一道闸门。理由：
 * - 权限系统里 `is_owner=1` 的账号只有在权限点进了 `SUPER_ONLY_PERMISSIONS` 时才被放行
 *   （`PermissionsGuard` 的既有语义）；若这里挂一个普通权限点，**所有者反而会被 403**，
 *   与"仅超管"要求的"超管或所有者"相矛盾。
 * - "谁是超管"的判定与 `recharge-admin.controller.ts` 的私有实现**同一段 SQL**
 *   （`admin_role.code = 'super_admin'` ∪ `admin.is_owner = 1`）；
 *   之所以没有抽成公共函数：那份实现是 recharge 模块的 private 方法（本轮改动范围不含该模块），
 *   这里按同一口径落地并在本注释里标注，**没有第三种定义**。
 *
 * ## 为什么 LV5 也走这里
 *
 * 自动判定封顶 `AUTO_MAX_GRADE = 4`（`WORKER_GRADE_RULES` 里 LV5 标了 `manualOnly`），
 * 因此「宗师」这一档**只有**本接口能给 —— 这就是审批表那句「必须人工审核，不自动升」的落点。
 *
 * ## 审计
 *
 * 由 `WorkerGradeService.setManualGrade()` 在**同一事务**里写 `operation_log`
 * （`module='worker_grade'`、`action='worker_grade:manual-set'`、`admin_id`=操作人、
 * `request_body` 记前后等级 + 指标快照 + 备注），并同时更新 `worker_grade.upgraded_by`。
 */
@ApiTags('admin/workers')
@Controller('admin/workers')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('admin')
@ApiBearerAuth()
export class RatingAdminController {
  constructor(
    private readonly grade: WorkerGradeService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  @Put(':id/grade')
  @ApiOperation({
    summary: '仅超管：人工设置打手等级（1-5 全档，含 LV5 宗师）；写 worker_grade + operation_log',
  })
  setGrade(
    @Param('id') id: string,
    @Body() dto: SetWorkerGradeDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    return this.assertSuperAdmin(user.userId).then(() =>
      this.grade.setManualGrade(
        id,
        { grade: dto.grade, note: dto.note },
        {
          adminUserId: user.userId,
          ip: clientIpOf(req),
          requestId: req.requestId,
          path: req.path,
          method: req.method,
        },
      ),
    );
  }

  /**
   * 查看某打手的等级 + 五维 + 进度（**同一道闸门**：仅超管）
   *
   * 管理端"设置等级"对话框需要"当前等级 + 当前指标"才能填，而既有的
   * `GET /admin/workers/:id/stats` 只给接单次数/好评率三联、不含五维与等级。
   * 只读、无副作用；返回形状与公开详情一致，便于前端复用同一套渲染。
   */
  @Get(':id/grade')
  @ApiOperation({ summary: '仅超管：查看打手等级 + 五维均分与样本数 + 距下一级还差多少' })
  async detail(@Param('id') id: string, @CurrentUser() user: { userId: string }) {
    await this.assertSuperAdmin(user.userId);
    return this.grade.detail(id);
  }

  /**
   * 「仅超管」闸门（`super_admin` 角色 或 `admin.is_owner = 1`）
   *
   * 与 `recharge-admin.controller.ts#assertSuperAdmin` **同一段 SQL、同一口径**；
   * 刻意不依赖 `system_setting.is_high_security`（那是配置**行**的属性，这里没有配置行可依托）。
   */
  private async assertSuperAdmin(userId: string): Promise<void> {
    const rows: Array<{ code: string; isOwner: number }> = await this.dataSource.query(
      `SELECT ar.code AS code, a.is_owner AS isOwner
         FROM admin a LEFT JOIN admin_role ar ON ar.id = a.role_id
        WHERE a.user_id = ? LIMIT 1`,
      [String(userId)],
    );
    const row = rows[0];
    if (row && (row.code === 'super_admin' || Number(row.isOwner) === 1)) return;
    throw new ForbiddenException('打手等级仅超级管理员可设置');
  }
}
