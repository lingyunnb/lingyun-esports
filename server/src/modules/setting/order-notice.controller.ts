import { BadRequestException, Body, Controller, Get, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';

import { Request } from 'express';
import { clientIpOf } from '../../common/client-ip';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { Roles } from '../../common/decorators/roles.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { ORDER_NOTICE_DEFAULT_KEY, ORDER_NOTICE_DEFAULT_TEXT } from './order-notice';
import { SystemSettingService } from './system-setting.service';

/** 下单须知：商品级覆盖 + 平台默认两层（负责人 2026-10-05 商品详情页 v2 方案 B） */
@ApiTags('admin/settings')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class OrderNoticeAdminController {
  constructor(private readonly settings: SystemSettingService) {}

  @Get('order-notice')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：平台默认下单须知（商品未覆盖时下发此文案）' })
  async read() {
    return { text: await this.settings.text(ORDER_NOTICE_DEFAULT_KEY, ORDER_NOTICE_DEFAULT_TEXT) };
  }

  /**
   * 保存平台默认下单须知。
   *
   * 落库形状 `cfg_value = {"value":{"text":"..."}}`（与 `order_pending_take_timeout_hours`
   * 的 `{"value":24}` 同一套约定，见 `SystemSettingService.text()`）。
   *
   * 兼容两种入参：`{ text }`（管理端表单）与 `{ cfgValue: { value: { text } } }`
   * （直接照 `PUT /admin/settings/:key` 的通用形状提交时也不会 400）。
   * 校验只拦"全空白"——那等于把默认须知清空，详情页会退化成代码兜底常量，
   * 运营却以为"改生效了"，属于最难查的一类问题。
   */
  @Put('order-notice')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write：保存平台默认下单须知' })
  async save(
    @Body() body: { text?: unknown; cfgValue?: { value?: { text?: unknown } } },
    @Req() req: Request & { user: { userId: string } },
  ) {
    const raw = body?.text ?? body?.cfgValue?.value?.text;
    const text = typeof raw === 'string' ? raw.trim() : '';
    if (!text) {
      throw new BadRequestException('默认下单须知不能为空（留空会让所有未单独配置的商品失去须知）');
    }
    // 第 5 参 = 审计身份（「谁改的」）：本接口只管文案、无高安全门槛，角色码沿用既有的 'admin'
    await this.settings.update(
      ORDER_NOTICE_DEFAULT_KEY,
      { value: { text } },
      '平台默认下单须知（商品未单独配置「下单须知」时下发此文案；\\n 分条）',
      'admin',
      {
        userId: req.user.userId,
        ip: clientIpOf(req),
        requestId: req.requestId ?? null,
        method: req.method,
        path: req.path,
      },
    );
    /**
     * **必须失效公开接口微缓存**（与 `ProductService.invalidatePublicProductCache` 同一口径）。
     *
     * 平台默认须知是 `GET /public/products/:id` 响应的一部分，而该路由挂在
     * `PublicCacheInterceptor` 的 30s 进程内微缓存下 —— 不失效的话运营改完默认须知，
     * 详情页最多 30s 还是旧文案。实测踩过：脚本改完立刻回读，拿到的还是旧值，
     * 看起来就像"保存没生效"。
     */
    PublicCacheInterceptor.invalidate('/api/v1/public/products');
    return { ok: true, text };
  }
}
