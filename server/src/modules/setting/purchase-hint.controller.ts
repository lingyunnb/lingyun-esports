import { BadRequestException, Body, Controller, Get, Put, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { InjectDataSource } from '@nestjs/typeorm';
import { Request } from 'express';
import { DataSource } from 'typeorm';

import { clientIpOf } from '../../common/client-ip';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import {
  PURCHASE_POINTS_HINT_DEFAULT,
  PURCHASE_POINTS_HINT_DESCRIPTION,
  PURCHASE_POINTS_HINT_KEY,
} from './purchase-hint';
import { SystemSettingService } from './system-setting.service';

/** 公开读取路径（写路径失效钩子与 `PublicCacheInterceptor` 登记的前缀必须一致） */
export const PURCHASE_HINT_PUBLIC_PATH = '/api/v1/public/purchase-hint';

/**
 * 购买提示 **公开**接口（负责人 2026-10-05）
 *
 * `GET /public/purchase-hint` → `{ text }`（老板端「选择服务」页底部那行小字）
 *
 * ## 为什么单开一个极轻接口，而不是挂在列表页已有的接口上
 *
 * 选择服务页（`apps/boss-app/lib/pages/product_list_page.dart`）实际只调三个接口，
 * 逐个评估过（结论都不可用）：
 * 1. `GET /divisions` —— 返回**裸数组**（`DivisionPublicController.list()` 直接 return 实体数组），
 *    要塞平台级文案只能改成 `{ list, purchaseHint }` 信封 —— 那是**破坏性改形状**，
 *    客户端（服务页/商品列表/工作端大厅）与官网都要跟着改，为一个字段不值。
 *    「每个分部都带一份同样的文案」更是把 1 句话重复 N 遍（5 个分部 = 5 份）。
 * 2. `GET /public/categories` —— 同样是裸数组，同样的问题。
 * 3. `GET /public/products` —— **明确排除**：该接口 1792000000000 做过列裁剪性能专项，
 *    40/50 条商品每条再挂一遍平台文案等于把刚压下去的体积加回去。
 *
 * 故按既有口径新增本接口：**1 行配置、1 次主键读、约 2ms**，并登记进
 * `PublicCacheInterceptor`（进程内 30s 微缓存 + `Cache-Control` 60s 档；
 * 文案随运营变化，故与公告/宣传图同档，而不是字典档 600s）；
 * 管理端写入时调用 `PublicCacheInterceptor.invalidate(...)` → **下一次请求即生效**。
 *
 * ## 空值语义（与客户端约定，客户端的测试锁死了这条）
 *
 * `text` 为空串 = **整行不渲染**。这不是"降级"，是**运营主动关闭这行提示**的合法状态
 * （充值活动暂停 / 暂不需要引导联系客服时），管理端把输入框清空保存即可，
 * 不需要发版、也不需要理解 JSON。因此这里**不做代码常量兜底**：
 * 兜底会让"运营清空了却还在显示"，属于最难查的一类问题。
 */
@ApiTags('public')
@Controller('public')
export class PurchaseHintPublicController {
  constructor(private readonly settings: SystemSettingService) {}

  @Get('purchase-hint')
  @ApiOperation({ summary: '公开：购买提示文案（老板端选择服务页小字；text 为空 = 客户端整行不渲染）' })
  async read() {
    return { text: await this.settings.text(PURCHASE_POINTS_HINT_KEY, '') };
  }
}

/**
 * 购买提示 **管理端**接口（负责人 2026-10-05）
 *
 * - `GET /admin/purchase-hint`：**读**（权限点 `admin:setting:read`，普通管理员也可读）
 * - `PUT /admin/purchase-hint`：**写**（权限点 `admin:setting:write` + **仅超级管理员**）
 *
 * 「仅超管可写」不是靠这里手写 if，而是走项目既有的**最高安全配置**机制
 * （docs/04）：迁移把该行写成 `is_high_security = 1`，
 * `SystemSettingService.update()` 会用调用者角色码校验 —— 与 `PUT /admin/settings/:key`
 * 完全同一条路径，不存在"两个入口两套规则"。
 *
 * 注意这里必须像 `SystemSettingController.update()` 一样**查真实角色码**传入
 * （不能像 `OrderNoticeAdminController` 那样写死 `'admin'` —— 那会让高安全校验永远
 * 把超管也挡在外面，属于把开关装反）。
 */
@ApiTags('admin/settings')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class PurchaseHintAdminController {
  constructor(
    private readonly settings: SystemSettingService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  @Get('purchase-hint')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：购买提示文案（含默认文案，供「恢复默认」按钮用）' })
  async read() {
    return {
      // 忠实返回库里的值（**空串就返回空串**）：管理端清空保存后，输入框必须也是空的，
      // 否则运营会以为"清空没保存上"，一保存又把文案写回去。
      text: await this.settings.text(PURCHASE_POINTS_HINT_KEY, ''),
      // 代码里的初始默认值（只用于管理端「恢复默认」按钮，不做任何隐式兜底）
      defaultText: PURCHASE_POINTS_HINT_DEFAULT,
      /** 是否仅超管可改（管理端据此显示标签；权威判定在服务端） */
      superAdminOnly: true,
    };
  }

  /**
   * 保存购买提示。
   *
   * 落库形状 `cfg_value = {"value":{"text":"..."}}` —— 与 `order_notice_default`
   * 逐字同形状（`SystemSettingService.text()` 只认 `cfg_value.value.text`），
   * 管理端「全部配置项」表格与通用 `PUT /admin/settings/:key` 都能直接读懂它。
   *
   * 兼容两种入参：`{ text }`（管理端表单）与 `{ cfgValue: { value: { text } } }`
   * （直接照通用设置的形状提交也不会 400）。
   *
   * **允许空**（与 `order_notice_default` 刻意不同）：那里留空会让所有商品失去须知，
   * 属于事故；这里留空 = 关闭这行提示，是**运营的合法动作**（客户端整行不渲染），
   * 故只做长度上限校验（200 字，防误粘贴整段公告）。
   */
  @Put('purchase-hint')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write + 仅超管：保存购买提示文案（可留空 = 客户端不显示）' })
  async save(
    @Body() body: { text?: unknown; cfgValue?: { value?: { text?: unknown } } },
    @Req() req: Request & { user: { userId: string } },
  ) {
    const raw = body?.text ?? body?.cfgValue?.value?.text;
    const text = typeof raw === 'string' ? raw.trim() : '';
    if (text.length > 200) {
      throw new BadRequestException('购买提示最多 200 字');
    }

    // 调用者角色码（仅超管可写；与 SystemSettingController 同一口径）
    const rows: Array<{ code: string }> = await this.dataSource.query(
      `SELECT ar.code FROM admin a JOIN admin_role ar ON ar.id = a.role_id WHERE a.user_id = ?`,
      [req.user.userId],
    );
    // 第 5 参 = 审计身份（「谁改的」），与 RechargeAdminController.saveConfig 同一姿势；不改权限与业务行为
    await this.settings.update(
      PURCHASE_POINTS_HINT_KEY,
      { value: { text } },
      PURCHASE_POINTS_HINT_DESCRIPTION,
      rows[0]?.code ?? null,
      {
        userId: req.user.userId,
        ip: clientIpOf(req),
        requestId: req.requestId ?? null,
        method: req.method,
        path: req.path,
      },
    );

    /**
     * **必须失效公开接口微缓存**（与 `OrderNoticeAdminController` / 分部写入同一口径）。
     *
     * 不失效的话运营改完联系人，客户端最长 30s 还是旧文案 ——
     * "改完像没生效"是这类问题的典型现场（官方须知那次实测踩过）。
     */
    PublicCacheInterceptor.invalidate(PURCHASE_HINT_PUBLIC_PATH);
    return { ok: true, text };
  }
}
