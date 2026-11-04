import { BadRequestException, Body, Controller, Get, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { InjectRepository } from '@nestjs/typeorm';
import { Request } from 'express';
import { Repository } from 'typeorm';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { Roles } from '../../common/decorators/roles.decorator';
import { RolesGuard } from '../../common/guards/roles.guard';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { OperationLogService } from '../log/operation-log.service';
import { SiteContent } from './site-content.entity';

/** 公开接口路径（写路径失效钩子必须与 `PublicCacheInterceptor` 登记的前缀逐字一致） */
const SITE_PUBLIC_PATH = '/api/v1/public/site';

/** 官网内容（负责人 2026-09-25）：公开读取（/public/site）+ 管理端编辑（/admin/site） */
@Controller()
export class SiteController {
  constructor(
    @InjectRepository(SiteContent) private readonly repo: Repository<SiteContent>,
    private readonly opLog: OperationLogService,
  ) {}

  @Get('public/site')
  @ApiTags('public')
  @ApiOperation({ summary: '官网内容（官网页面渲染的唯一数据源）' })
  async publicSite() {
    const row = await this.repo.findOne({ where: { id: 1 } });
    return row?.content ?? {};
  }

  @Get('admin/site')
  @ApiTags('admin/site')
  @UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
  @Roles('admin')
  @RequirePermission('admin:site:edit')
  @ApiBearerAuth()
  @ApiOperation({ summary: '管理端读取官网内容' })
  adminGet() {
    return this.publicSite();
  }

  @Put('admin/site')
  @ApiTags('admin/site')
  @UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
  @Roles('admin')
  @RequirePermission('admin:site:edit')
  @ApiBearerAuth()
  @ApiOperation({ summary: '管理端保存官网内容（全量覆盖）' })
  async adminPut(@Body() dto: { content: Record<string, unknown> }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const content = dto?.content ?? {};
    // 防呆：内容必须是对象且大小受限（防止误传巨大 JSON）
    const size = JSON.stringify(content).length;
    if (size > 500_000) throw new BadRequestException('内容过大（超过 500KB）');
    const row = await this.repo.findOne({ where: { id: 1 } });
    if (row) {
      row.content = content;
      await this.repo.save(row);
    } else {
      await this.repo.save(this.repo.create({ id: 1, content }));
    }
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'site',
      action: 'site:content:update',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(content).slice(0, 2000),
      ip: req.ip,
      requestId: req.requestId,
    });
    /**
     * **官网内容写入后立刻失效公开接口的进程内微缓存**（2026-10-08 缺口修复）
     *
     * `GET /public/site` 挂在 `PublicCacheInterceptor` 的 30s 微缓存下，而本模块此前
     * 没有写入侧失效钩子 → 管理端保存官网内容后，官网/App 设置页最长 30s 仍是旧内容。
     * 口径与 `division` / `product` / `banner` 既有实现一致：
     * **内容随管理端配置变化的数据，写入时必须配失效钩子**（唯一失效入口就是这里这个调用）。
     * ⚠️ **本模块新增任何写路径都必须一起失效**。
     */
    PublicCacheInterceptor.invalidate(SITE_PUBLIC_PATH);
    return { ok: true };
  }
}
