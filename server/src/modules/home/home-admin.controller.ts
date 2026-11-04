import { Body, Controller, Delete, Get, Param, Post, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { Request } from 'express';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { UpsertAnnouncementDto, UpsertBannerDto, UpsertModuleDto, UpsertTopWorkerDto } from './dto/home.dto';
import { HomeService } from './home.service';

/** 首页管理（权限点 admin:home:write，docs/04） */
@ApiTags('admin/home')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class HomeAdminController {
  constructor(
    private readonly service: HomeService,
    private readonly opLog: OperationLogService,
  ) {}

  /**
   * 审计留痕（负责人铁律：管理端任何会改变库内容的接口，成功后必须写 `operation_log`）。
   *
   * 本控制器有 9 个写接口（模块 / 宣传图 / 公告 / 优秀打手），逐个手写必然漂移 → 收口一处。
   * 口径与 `division.controller.ts` / `game-admin.controller.ts` 一致：
   * `adminUserId` 只从 JWT 的 `CurrentUser` 取，**绝不从请求体取**。
   *
   * 废弃接口（`home/top-workers*`）**同样留痕**：它们仍是可被调用的写路由，
   * "无人调用"不等于"改了不用记"（遗留脚本一样能改库）。
   */
  private audit(
    user: { userId: string },
    req: Request,
    action: string,
    requestBody: Record<string, unknown>,
  ): void {
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'home',
      action,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(requestBody),
      ip: req.ip ?? null,
      requestId: (req as Request & { requestId?: string }).requestId ?? null,
      result: 'success',
    });
  }

  // 通用模块（介绍/活动/按钮）
  @Get('home/modules')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '权限点 admin:home:write：模块配置列表' })
  modules() {
    return this.service.adminModules();
  }

  @Put('home/modules/:key')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '权限点 admin:home:write：更新模块配置（标题/内容/扩展JSON/排序/显隐；操作日志留痕）' })
  async updateModule(
    @Param('key') key: string,
    @Body() dto: UpsertModuleDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateModule(key, dto);
    this.audit(user, req, 'home:module:update', { key, ...(dto as Record<string, unknown>) });
    return result;
  }

  // ---------------------------------------------------------------
  // 宣传图（首页顶部通栏轮播）—— 2026-10-05 任务②（方案 C）**重新启用**
  // ---------------------------------------------------------------
  //
  // 本段原标「已废弃，2026-10-05」，本次按负责人审批的方案 C **全部去掉 @deprecated**：
  // 管理端新增「宣传图管理」页（`admin-web/src/views/BannersView.vue`）、
  // App 首页新增 `GET /public/banners` 消费方 → 四个接口重新有真实调用方，不再是"无人调用的空转接口"。
  //
  // 数据表 `home_banner` **原样复用、没有新建表**；本次只补 3 个可空列
  // （`subtitle` / `start_at` / `end_at`）与 `image_url` 的 `DEFAULT ''`，见 migration `1798000000000`。
  //
  // 权限点沿用 `admin:home:write`（与公告管理同一把钥匙：都是"首页内容"这一类配置，
  // 单开 `admin:home:banner` 只会让超管多维护一个角色位，没有实际隔离收益）。
  //
  // 【优秀打手 `home/top-workers*` 仍然废弃】：它没有新的消费方（首页不再有"优秀打手"位，
  // 「找陪玩」页走 `/public/players`），因此下面那段 @deprecated 保留不动、表 `top_worker` 不删。
  // ---------------------------------------------------------------

  @Get('home/banners')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '宣传图列表（含隐藏与已过期；按 sortOrder 升序 + id 降序）' })
  banners() {
    return this.service.adminBanners();
  }

  @Post('home/banners')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '新建宣传图（只传 imageMediaId 也能成功：image_url 已补 DEFAULT \'\'；操作日志留痕）' })
  async createBanner(
    @Body() dto: UpsertBannerDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const saved = await this.service.createBanner(dto);
    this.audit(user, req, 'home:banner:create', {
      id: String((saved as { id?: unknown })?.id ?? ''),
      title: dto.title,
      imageMediaId: dto.imageMediaId,
      visible: dto.visible,
    });
    return saved;
  }

  @Put('home/banners/:id')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '更新宣传图（含上下架 visible 1/2、投放时间区间 startAt/endAt；操作日志留痕）' })
  async updateBanner(
    @Param('id') id: string,
    @Body() dto: UpsertBannerDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateBanner(id, dto);
    this.audit(user, req, 'home:banner:update', { id: String(id), ...(dto as Record<string, unknown>) });
    return result;
  }

  @Delete('home/banners/:id')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '删除宣传图（操作日志留痕）' })
  async deleteBanner(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteBanner(id);
    this.audit(user, req, 'home:banner:delete', { id: String(id) });
    return result;
  }

  // 公告
  @Get('announcements')
  @RequirePermission('admin:home:write')
  announcements() {
    return this.service.adminAnnouncements();
  }

  @Post('announcements')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '新建公告（操作日志留痕）' })
  async createAnnouncement(
    @Body() dto: UpsertAnnouncementDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const saved = await this.service.createAnnouncement(dto);
    this.audit(user, req, 'home:announcement:create', {
      id: String((saved as { id?: unknown })?.id ?? ''),
      title: dto.title,
      pinned: dto.pinned,
    });
    return saved;
  }

  @Put('announcements/:id')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '更新公告（操作日志留痕）' })
  async updateAnnouncement(
    @Param('id') id: string,
    @Body() dto: UpsertAnnouncementDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateAnnouncement(id, dto);
    this.audit(user, req, 'home:announcement:update', { id: String(id), ...(dto as Record<string, unknown>) });
    return result;
  }

  @Delete('announcements/:id')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '删除公告（操作日志留痕）' })
  async deleteAnnouncement(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteAnnouncement(id);
    this.audit(user, req, 'home:announcement:delete', { id: String(id) });
    return result;
  }

  // 优秀打手 —— 【仍为废弃，2026-10-05】理由：没有新的消费方（首页不再有"优秀打手"展示位，
  // 「找陪玩」页走 `/public/players`）。保留路由以免遗留调用 404；表 `top_worker` 不删。

  /** @deprecated 2026-10-05 起无调用方（管理端入口已下架）。保留路由以免遗留调用 404；表不删。 */
  @Get('home/top-workers')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '【已废弃】优秀打手列表（无调用方，保留兼容）', deprecated: true })
  topWorkers() {
    return this.service.adminTopWorkers();
  }

  /** @deprecated 2026-10-05 起无调用方（管理端入口已下架）。保留路由以免遗留调用 404；表不删。 */
  @Post('home/top-workers')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '【已废弃】新增优秀打手（无调用方，保留兼容；仍写操作日志）', deprecated: true })
  async createTopWorker(
    @Body() dto: UpsertTopWorkerDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const saved = await this.service.createTopWorker(dto);
    this.audit(user, req, 'home:top-worker:create', {
      id: String((saved as { id?: unknown })?.id ?? ''),
      workerId: dto.workerId,
    });
    return saved;
  }

  /** @deprecated 2026-10-05 起无调用方（管理端入口已下架）。保留路由以免遗留调用 404；表不删。 */
  @Put('home/top-workers/:id')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '【已废弃】更新优秀打手（无调用方，保留兼容；仍写操作日志）', deprecated: true })
  async updateTopWorker(
    @Param('id') id: string,
    @Body() dto: UpsertTopWorkerDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateTopWorker(id, dto);
    this.audit(user, req, 'home:top-worker:update', { id: String(id), ...(dto as Record<string, unknown>) });
    return result;
  }

  /** @deprecated 2026-10-05 起无调用方（管理端入口已下架）。保留路由以免遗留调用 404；表不删。 */
  @Delete('home/top-workers/:id')
  @RequirePermission('admin:home:write')
  @ApiOperation({ summary: '【已废弃】删除优秀打手（无调用方，保留兼容；仍写操作日志）', deprecated: true })
  async deleteTopWorker(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteTopWorker(id);
    this.audit(user, req, 'home:top-worker:delete', { id: String(id) });
    return result;
  }
}
