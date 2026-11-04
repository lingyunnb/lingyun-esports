import { Body, Controller, Delete, Get, Param, Post, Put, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { InjectRepository } from '@nestjs/typeorm';
import { IsIn, IsInt, IsOptional, IsString, MaxLength, ValidateIf } from 'class-validator';
import { Request } from 'express';
import { Repository } from 'typeorm';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { LenientUpdateDto } from '../../common/pipes/lenient-validation.pipe';
import { OperationLogService } from '../log/operation-log.service';
import { Division } from './division.entity';
import { DivisionService } from './division.service';

/**
 * 分部管理 DTO（负责人 2026-10-03：分部 = 游戏 + 平台，管理端可增删改）
 *
 * 继承 LenientUpdateDto：编辑分部时允许前端回传整对象（含 gameName/onlineCount 等
 * 只读/计算字段），多余字段静静忽略而不是 400（管理端「改简介」报障修复）。
 */
export class DivisionDto extends LenientUpdateDto {
  @IsOptional()
  @IsString()
  gameId?: string;

  @IsOptional()
  @IsString()
  platform?: string;

  @IsOptional()
  @IsString()
  @MaxLength(48)
  code?: string;

  @IsOptional()
  @IsString()
  @MaxLength(40)
  name?: string;

  @IsOptional()
  @IsString()
  @MaxLength(24)
  shortName?: string;

  @IsOptional()
  @IsString()
  @MaxLength(8)
  platformLabel?: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  onlineDesc?: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  priceNote?: string;

  @IsOptional()
  @IsString()
  @MaxLength(16)
  themeColor?: string;

  /** 专区圆形图媒体 id（管理端上传；空则客户端回退渐变色块） */
  @IsOptional()
  @IsString()
  iconMediaId?: string | null;

  /** 分部卡封面图媒体 id（管理端上传） */
  @IsOptional()
  @IsString()
  coverMediaId?: string | null;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  subTitle?: string;

  /**
   * 是否建设中（负责人 2026-10-05：瓦端 / 瓦手 先上「建设中」页）
   *
   * **只允许 0 正常 / 1 建设中**（与 status 同一口径，拒绝 7 这类无意义值）；
   * 公开接口 `/divisions`、`/divisions/grouped` 会把它以 `underConstruction: true|false` 下发。
   */
  @IsOptional()
  @IsIn([0, 1], { message: 'underConstruction 只能是 0（正常）或 1（建设中）' })
  underConstruction?: number;

  /**
   * 建设中页提示文案（**服务端下发，客户端零硬编码**；可含换行与 QQ 号）
   *
   * 空字符串 = 清空（客户端显示兜底文案「该分部正在建设中，敬请期待」）。
   */
  @IsOptional()
  @IsString()
  @MaxLength(255, { message: '提示文案最多 255 字' })
  noticeText?: string;

  @IsOptional()
  @IsInt()
  sortOrder?: number;

  /**
   * 状态（负责人 2026-10-04 校验补口）：**只允许 0 下架 / 1 上架**
   *
   * 既有约定以代码为准：`DivisionService.listActive()` 过滤 `status = 1`（上架），
   * 管理端分部页下拉也只有 1 上架 / 0 下架；此前 DTO 只有 @IsInt()，
   * 可以写入 `status: 7` 这类无意义值（分部会静默「消失」在客户端列表里）。
   * 建表注释里的「2 下架」是初版历史遗留、代码从未使用，故不纳入合法值。
   * 新增分部时 status 仍为可选（服务端默认 1），必填项（gameId/code/name）行为不变。
   */
  @IsOptional()
  @IsIn([0, 1], { message: 'status 只能是 0（下架）或 1（上架）' })
  status?: number;
}

/**
 * 新增分部 DTO：在 DivisionDto 的基础上把三个必填项恢复为必填
 * （DivisionDto 因为要给「只改简介」这类局部更新用，全部字段可选）。
 *
 * 两点说明：
 * - 声明即赋值 `undefined as never`：只为让 TS 允许子类重声明父类属性（TS2612），运行时仍是 undefined；
 * - 属性级 `@ValidateIf`：子类重声明时父类校验装饰器会被保留（class-validator 追加而非替换），
 *   所以必须用属性级条件覆盖掉父类的 `@IsOptional`，否则三个必填项在新增时形同虚设。
 */
export class CreateDivisionDto extends DivisionDto {
  @ValidateIf((o: CreateDivisionDto) => isBlank(o.gameId))
  @IsString()
  gameId: string = undefined as never;

  @ValidateIf((o: CreateDivisionDto) => isBlank(o.code))
  @IsString()
  @MaxLength(48)
  code: string = undefined as never;

  @ValidateIf((o: CreateDivisionDto) => isBlank(o.name))
  @IsString()
  @MaxLength(40)
  name: string = undefined as never;
}

/** 空值判定（新增分部必填项用） */
function isBlank(v: unknown): boolean {
  return v === undefined || v === null || v === '';
}

/** 公开分部接口（客户端零硬编码：首页分部卡、筛选器全部由此驱动） */
@ApiTags('divisions')
@Controller('divisions')
export class DivisionPublicController {
  constructor(private readonly service: DivisionService) {}

  @Get()
  @ApiOperation({ summary: '上架分部列表（可按 gameId 过滤）' })
  async list(@Query('gameId') gameId?: string) {
    const all = await this.service.listActive();
    return gameId ? all.filter((d) => d.gameId === String(gameId)) : all;
  }

  @Get('grouped')
  @ApiOperation({ summary: '按游戏分组的分部（含 platformCount：=1 时客户端不显示平台筛选）' })
  grouped() {
    return this.service.listGrouped();
  }
}

/** 管理端分部 CRUD（RBAC：admin:division:*） */
@ApiTags('admin/divisions')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class DivisionAdminController {
  constructor(
    private readonly service: DivisionService,
    private readonly opLog: OperationLogService,
    @InjectRepository(Division) private readonly repo: Repository<Division>,
  ) {}

  @Get('divisions')
  @RequirePermission('admin:division:read')
  @ApiOperation({ summary: '权限点 admin:division:read：分部列表（含下架）' })
  list() {
    return this.service.listAll();
  }

  @Post('divisions')
  @RequirePermission('admin:division:write')
  @ApiOperation({ summary: '权限点 admin:division:write：新增分部（操作日志留痕）' })
  async create(
    @Body() dto: CreateDivisionDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const saved = await this.repo.save(
      this.repo.create({
        gameId: dto.gameId,
        platform: dto.platform ?? 'mobile',
        code: dto.code,
        name: dto.name,
        shortName: dto.shortName ?? dto.name,
        platformLabel: dto.platformLabel ?? (dto.platform === 'pc' ? '端游' : '手游'),
        onlineDesc: dto.onlineDesc ?? '',
        priceNote: dto.priceNote ?? '',
        themeColor: dto.themeColor ?? '',
        iconMediaId: dto.iconMediaId ? String(dto.iconMediaId) : null,
        coverMediaId: dto.coverMediaId ? String(dto.coverMediaId) : null,
        subTitle: dto.subTitle ?? '',
        sortOrder: dto.sortOrder ?? 0,
        status: dto.status ?? 1,
        underConstruction: dto.underConstruction ?? 0,
        noticeText: dto.noticeText ?? '',
      }),
    );
    // 审计（docs/09：管理端敏感操作全量留痕；沿用既有 opLog.log 做法）
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'division',
      action: 'division:create',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({
        id: String(saved.id),
        code: saved.code,
        name: saved.name,
        gameId: saved.gameId,
        platform: saved.platform,
        underConstruction: saved.underConstruction,
      }),
      ip: req.ip,
      requestId: req.requestId,
    });
    // 公开接口微缓存失效（`/divisions`、`/divisions/grouped`）：新增分部后立刻可见
    PublicCacheInterceptor.invalidate('/api/v1/divisions');
    return { id: String(saved.id) };
  }

  @Put('divisions/:id')
  @RequirePermission('admin:division:write')
  @ApiOperation({ summary: '权限点 admin:division:write：编辑分部（含建设中开关/提示文案；未知字段忽略不报错）' })
  async update(
    @Param('id') id: string,
    @Body() dto: DivisionDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const found = await this.repo.findOne({ where: { id } });
    if (!found) return { ok: false, message: '分部不存在' };
    // 变更前后值（只记这两项：本次需求的两个新字段，便于回溯「谁把哪个分部切成建设中/改了招人文案」）
    const before = { underConstruction: Number(found.underConstruction ?? 0), noticeText: found.noticeText ?? '' };
    Object.assign(found, {
      gameId: dto.gameId ?? found.gameId,
      platform: dto.platform ?? found.platform,
      code: dto.code ?? found.code,
      name: dto.name ?? found.name,
      shortName: dto.shortName ?? found.shortName,
      platformLabel: dto.platformLabel ?? found.platformLabel,
      onlineDesc: dto.onlineDesc ?? found.onlineDesc,
      priceNote: dto.priceNote ?? found.priceNote,
      themeColor: dto.themeColor ?? found.themeColor,
      iconMediaId: dto.iconMediaId !== undefined ? (dto.iconMediaId ? String(dto.iconMediaId) : null) : found.iconMediaId,
      coverMediaId: dto.coverMediaId !== undefined ? (dto.coverMediaId ? String(dto.coverMediaId) : null) : found.coverMediaId,
      subTitle: dto.subTitle ?? found.subTitle,
      sortOrder: dto.sortOrder ?? found.sortOrder,
      status: dto.status ?? found.status,
      // 0 是合法值 → 必须用 `??`（不能写 `||`，否则「切回正常」会被当成未传而失效）
      underConstruction: dto.underConstruction ?? found.underConstruction,
      noticeText: dto.noticeText !== undefined ? (dto.noticeText ?? '') : found.noticeText,
    });
    await this.repo.save(found);
    const after = { underConstruction: Number(found.underConstruction ?? 0), noticeText: found.noticeText ?? '' };
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'division',
      action: 'division:update',
      method: req.method,
      path: req.path,
      // 关键字段（哪个分部、开关从哪到哪、文案前后）排在前面：requestBody 超长会按 4000 字截断
      requestBody: JSON.stringify({
        id: String(id),
        code: found.code,
        name: found.name,
        underConstruction: `${before.underConstruction} → ${after.underConstruction}`,
        noticeTextBefore: before.noticeText,
        noticeTextAfter: after.noticeText,
      }),
      ip: req.ip,
      requestId: req.requestId,
    });
    /**
     * 公开接口微缓存失效（**本需求的关键一行**）：
     * `/divisions`、`/divisions/grouped` 走 `PublicCacheInterceptor` 的 30s 进程内微缓存，
     * 不失效的话「管理端把分部切成建设中 / 改招人文案」最长要 30s 才在客户端可见；
     * 失效后**下一次请求即生效**（与 CLAUDE.md「管理端改完下一次请求即生效」的口径一致）。
     */
    PublicCacheInterceptor.invalidate('/api/v1/divisions');
    return { ok: true };
  }

  @Delete('divisions/:id')
  @RequirePermission('admin:division:delete')
  @ApiOperation({ summary: '权限点 admin:division:delete：删除分部（有商品/订单挂载时拒绝，改用下架；操作日志留痕）' })
  async remove(
    @Param('id') id: string,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const [productUsed] = await this.repo.query('SELECT COUNT(*) AS c FROM product WHERE division_id = ?', [id]);
    const [orderUsed] = await this.repo.query('SELECT COUNT(*) AS c FROM `order` WHERE division_id = ?', [id]);
    if (Number(productUsed?.c) > 0 || Number(orderUsed?.c) > 0) {
      return { ok: false, message: '该分部下已有商品或订单，不能删除，请改为下架' };
    }
    const found = await this.repo.findOne({ where: { id } });
    await this.repo.delete({ id });
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'division',
      action: 'division:delete',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ id: String(id), code: found?.code ?? '', name: found?.name ?? '' }),
      ip: req.ip,
      requestId: req.requestId,
    });
    PublicCacheInterceptor.invalidate('/api/v1/divisions');
    return { ok: true };
  }
}
