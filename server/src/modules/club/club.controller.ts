import { Body, Controller, Delete, Get, Param, Post, Put, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { IsInt, IsNumberString, IsOptional, IsString, MaxLength } from 'class-validator';
import type { Request } from 'express';

import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { LenientUpdateDto } from '../../common/pipes/lenient-validation.pipe';
import { OperationLogService } from '../log/operation-log.service';
import { ClubService } from './club.service';

/**
 * 官方馆编辑 DTO。
 *
 * 继承 LenientUpdateDto：允许管理端回传整对象（含 `id` 等回显字段），
 * 多余字段静静忽略而不是 400（官方馆「改简介/副标题」报障修复）。
 */
class ClubDto extends LenientUpdateDto {
  @IsOptional() @IsString() @MaxLength(40) name?: string;
  @IsOptional() @IsString() @MaxLength(64) subTitle?: string;
  @IsOptional() @IsString() @MaxLength(255) description?: string;
  @IsOptional() @IsString() coverMediaId?: string | null;
  @IsOptional() @IsString() @MaxLength(16) badge?: string;
  @IsOptional() @IsNumberString() rating?: string;
  @IsOptional() @IsInt() orderCount?: number;
  @IsOptional() @IsString() divisionId?: string | null;
  @IsOptional() @IsInt() sortOrder?: number;
  @IsOptional() @IsInt() status?: number;
}

/** 公开：官方自营馆（首页「祁连山官方」卡片；管理端维护内容与封面图） */
@ApiTags('public')
@Controller('public')
export class ClubPublicController {
  constructor(private readonly service: ClubService) {}

  @Get('clubs')
  @ApiOperation({ summary: '公开：官方馆列表（首页渲染：名称/副标题/简介/封面图/角标/评分/单量）' })
  list(@Query('divisionId') divisionId?: string) {
    return this.service.listActive().then((all) => (divisionId ? all.filter((c) => String(c.divisionId ?? '') === String(divisionId)) : all));
  }
}

/** 管理端官方馆 CRUD（RBAC：admin:club:*） */
@ApiTags('admin/clubs')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class ClubAdminController {
  constructor(
    private readonly service: ClubService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get('clubs')
  @RequirePermission('admin:club:read')
  @ApiOperation({ summary: '权限点 admin:club:read：官方馆列表（含下架）' })
  list() {
    return this.service.listAll();
  }

  @Post('clubs')
  @RequirePermission('admin:club:write')
  @ApiOperation({ summary: '权限点 admin:club:write：新建官方馆（操作日志留痕）' })
  async create(
    @Body() dto: ClubDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const saved = await this.service.create(dto);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'club',
      action: 'club:create',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        id: String(saved.id),
        name: dto.name,
        subTitle: dto.subTitle,
        divisionId: dto.divisionId ?? null,
        badge: dto.badge,
        status: dto.status ?? 1,
      }),
      ip: req.ip ?? null,
      requestId: (req as Request & { requestId?: string }).requestId ?? null,
      result: 'success',
    });
    return saved;
  }

  @Put('clubs/:id')
  @RequirePermission('admin:club:write')
  @ApiOperation({ summary: '权限点 admin:club:write：编辑官方馆（含简介/副标题/封面图/评分/单量；未知字段忽略不报错）' })
  async update(
    @Param('id') id: string,
    @Body() dto: ClubDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.update(id, dto);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'club',
      action: 'club:update',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        id: String(id),
        // 只记**本次实际提交的字段**（未提交的不写 null，避免把"没改"记成"改成空"）
        ...(dto.name !== undefined ? { name: dto.name } : {}),
        ...(dto.subTitle !== undefined ? { subTitle: dto.subTitle } : {}),
        ...(dto.description !== undefined ? { description: dto.description } : {}),
        ...(dto.coverMediaId !== undefined ? { coverMediaId: dto.coverMediaId } : {}),
        ...(dto.badge !== undefined ? { badge: dto.badge } : {}),
        ...(dto.rating !== undefined ? { rating: dto.rating } : {}),
        ...(dto.orderCount !== undefined ? { orderCount: dto.orderCount } : {}),
        ...(dto.divisionId !== undefined ? { divisionId: dto.divisionId } : {}),
        ...(dto.sortOrder !== undefined ? { sortOrder: dto.sortOrder } : {}),
        ...(dto.status !== undefined ? { status: dto.status } : {}),
        ok: result.ok,
      }),
      ip: req.ip ?? null,
      requestId: (req as Request & { requestId?: string }).requestId ?? null,
      result: result.ok ? 'success' : 'fail',
      errorMsg: result.ok ? null : (result.message ?? null),
    });
    return result;
  }

  @Delete('clubs/:id')
  @RequirePermission('admin:club:delete')
  @ApiOperation({ summary: '权限点 admin:club:delete：删除官方馆（操作日志留痕）' })
  async remove(
    @Param('id') id: string,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.remove(id);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'club',
      action: 'club:delete',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ id: String(id) }),
      ip: req.ip ?? null,
      requestId: (req as Request & { requestId?: string }).requestId ?? null,
      result: 'success',
    });
    return result;
  }
}
