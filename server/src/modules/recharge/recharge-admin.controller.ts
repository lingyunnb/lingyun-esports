import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  HttpCode,
  Param,
  Post,
  Put,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { InjectDataSource } from '@nestjs/typeorm';
import { Request } from 'express';
import { DataSource } from 'typeorm';

import { clientIpOf } from '../../common/client-ip';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { OperationLogService } from '../log/operation-log.service';
import { RECHARGE_CONFIG_DESCRIPTION, RECHARGE_CONFIG_KEY, assertRechargeConfig } from './recharge-config';
import { RechargeService } from './recharge.service';
import { SystemSettingService } from '../setting/system-setting.service';

/**
 * 充值**管理端** `/admin/recharge/*`（admin-web 用）。
 *
 * ## 会话口径（负责人 2026-10-06 定案：**双层**）
 *
 * - **PC 管理端（本文件）**：正常 `role='admin'` 的 **primary** 登录 + **窄权限点**
 *   `recharge:review`（看列表）/ `recharge:grant`（发放·驳回）。
 *   **不套受限会话** —— 管理端本来就是管理员终端，再包一层只剩登录流程变复杂，无额外安全收益。
 * - **App 内「管理员身份」**：受限会话（`kind='recharge'`、12h、白名单 ≤5、默认拒绝其它接口）→ `/recharge/*`。
 *
 * 两条入口**共用同一个服务层**（`RechargeService.reviewList/grant/reject`）：
 * 幂等、审计、状态机完全一致，只是"用哪种会话进来"不同。
 *
 * ## 权限点映射
 *
 * | 接口 | 权限点 |
 * |---|---|
 * | `GET /admin/recharge/qr-codes` / `GET /admin/recharge/config` | `admin:setting:read` |
 * | `POST/PUT/DELETE /admin/recharge/qr-codes` | `admin:setting:write` |
 * | `PUT /admin/recharge/config` | `admin:setting:write` + **仅超管**（`is_high_security=1`） |
 * | `GET /admin/recharge/requests` | `recharge:review` |
 * | `POST /admin/recharge/requests/:id/grant` / `reject` | `recharge:grant` |
 * | `GET/POST/DELETE /admin/recharge/admins` | `admin:admin:write` + **仅超管**（见 [assertSuperAdmin]） |
 *
 * `PUT /admin/recharge/config` 的"仅超管"**不靠本文件手写 if**：配置行 `is_high_security=1`，
 * `SystemSettingService.update()` 会用调用者角色码校验（与 `PUT /admin/settings/:key` 完全同一条路径）。
 * 白名单增删的"仅超管"没有配置行可依托，故显式校验角色码 —— 但用的是**同一段查角色码的 SQL**
 * （`assertSuperAdmin`），保证"超管"的定义全项目只有一处。
 */
@ApiTags('admin/recharge')
@Controller('admin/recharge')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class RechargeAdminController {
  constructor(
    private readonly service: RechargeService,
    private readonly settings: SystemSettingService,
    private readonly opLog: OperationLogService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /**
   * 写接口留痕（负责人 2026-10-06 铁律：**管理员动作必须留痕**）。
   *
   * 为什么本文件原先一条都没有：这个控制器是 2026-10-06 新写的，作者只在服务层做了
   * 业务审计（`recharge_request.reviewed_by` 等），**忘了 `operation_log`** ——
   * 结果"改老板端可见的充值文案"这件事在操作日志里查不到（本次修文案时实测踩到）。
   *
   * 只记**关键字段摘要**，不落整包敏感内容（docs/09）：
   * 收款码只记 id/channel/label/enabled/sort（图片 mediaId 记了也无害，但没必要）；
   * 白名单只记目标 user id；配置只记改动的顶层字段名 + 与旧值的差异摘要
   * （配置本体动辄几 KB，整包塞进审计表既噪音又不利于查）。
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
      module: 'recharge',
      action: action.slice(0, 64),
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(requestBody).slice(0, 4000),
      ip: clientIpOf(req),
      requestId: req.requestId ?? null,
      result: 'success',
    });
  }

  // ---------------------------------------------------------------- 收款码

  @Get('qr-codes')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：收款码列表（含停用；enabled=1|0 可筛）' })
  listQrCodes(@Query('enabled') enabled?: string) {
    return this.service.listQrCodes(enabled);
  }

  @Post('qr-codes')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write：新增收款码（图片走既有媒体上传；字段兼容 imageMediaId/mediaId）' })
  async createQrCode(
    @Body()
    body: {
      mediaId?: string;
      imageMediaId?: string;
      channel?: string;
      label?: string;
      sort?: number;
      enabled?: boolean;
    },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.createQrCode(body);
    this.audit(user, req, 'recharge:qrcode:create', {
      id: (result as { id?: string })?.id ?? null,
      channel: body?.channel ?? null,
      label: body?.label ?? null,
      sort: body?.sort ?? null,
      enabled: body?.enabled ?? null,
    });
    return result;
  }

  @Put('qr-codes/:id')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write：编辑收款码（换图/渠道/名称/排序/启停，部分提交）' })
  async updateQrCode(
    @Param('id') id: string,
    @Body()
    body: {
      mediaId?: string;
      imageMediaId?: string;
      channel?: string;
      label?: string;
      sort?: number;
      enabled?: boolean;
    },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateQrCode(id, body);
    this.audit(user, req, 'recharge:qrcode:update', {
      id,
      // 只记"改了哪些字段"，不记图片地址等长值
      changed: Object.keys(body ?? {}).filter((k) => (body as Record<string, unknown>)[k] !== undefined),
      channel: body?.channel ?? null,
      label: body?.label ?? null,
      sort: body?.sort ?? null,
      enabled: body?.enabled ?? null,
    });
    return result;
  }

  @Delete('qr-codes/:id')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write：删除收款码（停用请用 PUT enabled=false）' })
  async deleteQrCode(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteQrCode(id);
    this.audit(user, req, 'recharge:qrcode:delete', { id });
    return result;
  }

  // ---------------------------------------------------------------- 配置

  /**
   * `GET /admin/recharge/config`：**平铺返回配置本体**（不是 `{config:{...}}` 信封）。
   *
   * 为什么平铺：管理端 `api/recharge.ts` 的 `getConfig()` 直接对响应 `data` 做归一，
   * 前端已按平铺实现 —— 包一层会让它整页回落到默认值，且这种"少一层"的错很难从页面看出来。
   */
  @Get('config')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：充值配置（平铺；含 defaultConfig 供「恢复默认」）' })
  async readConfig() {
    const cfg = await this.service.config();
    return {
      ...cfg,
      /** 是否仅超管可改（管理端据此显示标签；权威判定在服务端 `is_high_security`） */
      superAdminOnly: true,
      /** 当前硬上限（受限管理员最多 5 个账号） */
      adminLimitMax: 5,
    };
  }

  /**
   * `PUT /admin/recharge/config`：档位/比例/上下限/待审上限/管理员上限/说明文案（**仅超管**）。
   *
   * 写路径两步都在：
   * 1. 本方法先 `assertRechargeConfig` 做中文 400 校验（给管理端即时反馈）；
   * 2. `SystemSettingService.update()` 的 `is_high_security=1` 闸门做**权威**的仅超管判定，
   *    且 `validate()` 按 key 再复核一次取值（两道都在，不靠调用方自觉）。
   * 保存成功后**必须失效公开接口微缓存**，否则老板端最长 30s 还是旧档位（"改完像没生效"）。
   */
  @Put('config')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write + 仅超管：保存充值配置（非法值中文 400；保存即失效公开缓存）' })
  async saveConfig(
    @Body() body: Record<string, unknown>,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    // 未提交的字段沿用当前库值（管理端若做局部提交，不该把其余项悄悄打回默认）
    const cur = await this.service.config();
    const cfg = assertRechargeConfig({
      amountOptions: body['amountOptions'] ?? cur.amountOptions,
      customEnabled: body['customEnabled'] ?? cur.customEnabled,
      minYuan: body['minYuan'] ?? cur.minYuan,
      maxYuan: body['maxYuan'] ?? cur.maxYuan,
      pointsPerYuan: body['pointsPerYuan'] ?? cur.pointsPerYuan,
      pendingLimitPerUser: body['pendingLimitPerUser'] ?? cur.pendingLimitPerUser,
      adminLimit: body['adminLimit'] ?? cur.adminLimit,
      noticeText: body['noticeText'] ?? cur.noticeText,
    });

    // 调用者角色码（仅超管可写；与 SystemSettingController / PurchaseHintAdminController 同一口径）
    const roleCode = await this.roleCodeOf(user.userId);
    await this.settings.update(RECHARGE_CONFIG_KEY, { value: cfg }, RECHARGE_CONFIG_DESCRIPTION, roleCode, {
      userId: user.userId, ip: clientIpOf(req), requestId: req.requestId ?? null, method: req.method, path: req.path,
    });

    this.service.invalidatePublicConfigCache();
    /**
     * 业务级留痕（`module='recharge'`）：只记**顶层字段的改动**，不落整包配置
     * —— 说明文案动辄两三百字、档位是数组，整包进审计表只会把「谁在什么时候把哪一项改成了什么」淹掉。
     * 注意：`settings.update()` 自己还会写一条 `module='setting'` 的行（before/after 摘要），
     * 两条**不是重复**：一条回答"充值配置这个业务动作被谁执行了"，
     * 一条回答"`system_setting.recharge_config` 这一行的值从什么变成了什么"。
     */
    const diffKeys = (['amountOptions', 'customEnabled', 'minYuan', 'maxYuan', 'pointsPerYuan', 'pendingLimitPerUser', 'adminLimit', 'noticeText'] as const)
      .filter((k) => JSON.stringify((cur as unknown as Record<string, unknown>)[k]) !== JSON.stringify((cfg as unknown as Record<string, unknown>)[k]));
    this.audit(user, req, 'recharge:config:update', {
      changedKeys: diffKeys,
      ...(diffKeys.includes('noticeText')
        ? { noticeTextBefore: String(cur.noticeText ?? '').slice(0, 200), noticeTextAfter: String(cfg.noticeText ?? '').slice(0, 200) }
        : {}),
    });
    return { ok: true, ...cfg };
  }

  // ---------------------------------------------------------------- 申请审核

  @Get('requests')
  @RequirePermission('recharge:review')
  @ApiOperation({
    summary: '权限点 recharge:review：充值申请列表（status/keyword/startTime/endTime/page/pageSize；与 App 端同一服务层逻辑）',
  })
  listRequests(
    @Query('status') status?: string,
    @Query('keyword') keyword?: string,
    @Query('startTime') startTime?: string,
    @Query('endTime') endTime?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.service.reviewList({ status, keyword, startTime, endTime }, parsePage(page), parsePageSize(pageSize));
  }

  @Post('requests/:id/grant')
  @HttpCode(200)
  @RequirePermission('recharge:grant')
  @ApiOperation({ summary: '权限点 recharge:grant：发放（与 App 端同一服务层；幂等，重复调用中文 400 且不重复加分）' })
  grant(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    return this.service.grant(id, user.userId, { ip: clientIpOf(req), requestId: req.requestId ?? '' });
  }

  @Post('requests/:id/reject')
  @HttpCode(200)
  @RequirePermission('recharge:grant')
  @ApiOperation({ summary: '权限点 recharge:grant：驳回（必填原因；通知申请人）' })
  reject(@Param('id') id: string, @Body() body: { reason?: string }, @CurrentUser() user: { userId: string }) {
    return this.service.reject(id, user.userId, String(body?.reason ?? ''));
  }

  // ---------------------------------------------------------------- 管理员白名单

  @Get('admins')
  @RequirePermission('admin:admin:read')
  @ApiOperation({ summary: '权限点 admin:admin:read：充值审核管理员白名单（≤ adminLimit，硬上限 5）' })
  listAdmins() {
    return this.service.listAdmins();
  }

  /** 加入白名单（**仅超管**）。入参兼容 `adminUserId` / `targetUserId` / `userId`。 */
  @Post('admins')
  @RequirePermission('admin:admin:write')
  @ApiOperation({ summary: '权限点 admin:admin:write + 仅超管：加入白名单（只允许 role=admin 账号；并发安全 ≤5）' })
  async addAdmin(
    @Body() body: { adminUserId?: string; targetUserId?: string; userId?: string },
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    await this.assertSuperAdmin(user.userId);
    const target = String(body?.adminUserId ?? body?.targetUserId ?? body?.userId ?? '').trim();
    const result = await this.service.addAdmin(user.userId, target);
    this.audit(user, req, 'recharge:admin:add', { targetUserId: target });
    return result;
  }

  /** 移出白名单（**仅超管**）；`:id` 就是该管理员账号的 user id（前端删条目用的也是它）。 */
  @Delete('admins/:id')
  @RequirePermission('admin:admin:write')
  @ApiOperation({ summary: '权限点 admin:admin:write + 仅超管：移出白名单（立即吊销其受限会话 → 下一次请求 401）' })
  async removeAdmin(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    await this.assertSuperAdmin(user.userId);
    const result = await this.service.removeAdmin(user.userId, id);
    this.audit(user, req, 'recharge:admin:remove', { targetUserId: id });
    return result;
  }

  // ---------------------------------------------------------------- 内部

  /** 调用者的管理员角色码（查不到 → null；与既有各处同一段 SQL） */
  private async roleCodeOf(userId: string): Promise<string | null> {
    const rows: Array<{ code: string }> = await this.dataSource.query(
      `SELECT ar.code FROM admin a JOIN admin_role ar ON ar.id = a.role_id WHERE a.user_id = ?`,
      [String(userId)],
    );
    return rows[0]?.code ?? null;
  }

  /**
   * 「仅超管」闸门（白名单增删用）。
   *
   * 为什么不用 `is_high_security`：那是 `system_setting` **行**的属性，白名单增删没有配置行可依托。
   * 但"谁是超管"的判定复用**同一段查角色码的 SQL**（`roleCodeOf`），
   * 并额外放行 `admin.is_owner=1`（与 `PermissionsGuard` 对 `SUPER_ONLY_PERMISSIONS` 的所有者放行同口径，
   * 避免"所有者能改退款审批、却改不了充值白名单"这种自相矛盾的权限面）。
   */
  private async assertSuperAdmin(userId: string): Promise<void> {
    const code = await this.roleCodeOf(userId);
    if (code === 'super_admin') return;
    const rows: Array<{ isOwner: number }> = await this.dataSource.query(
      `SELECT is_owner AS isOwner FROM admin WHERE user_id = ? LIMIT 1`,
      [String(userId)],
    );
    if (Number(rows[0]?.isOwner ?? 0) === 1) return;
    throw new ForbiddenException('充值审核管理员白名单仅超级管理员可维护');
  }
}
