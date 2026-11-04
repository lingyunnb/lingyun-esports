import { Body, Controller, Get, Param, Put, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';

import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { Roles } from '../../common/decorators/roles.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { SystemSettingService } from './system-setting.service';

/** 下单表单默认配置（负责人 2026-10-04：下单页字段要能在管理端高度自定义） */
export const DEFAULT_ORDER_FORM = {
  /** 区服选择（必填）：label 展示、value 落库 */
  zoneLabel: '选择区服',
  zoneOptions: [
    { label: '微信', value: 'wechat' },
    { label: 'QQ', value: 'qq' },
  ],
  /** 表单字段（顺序即展示顺序；enabled=false 不显示；required 决定红星与校验） */
  fields: [
    {
      key: 'gamePlayerId',
      label: '游戏昵称或游戏ID',
      placeholder: '请输入游戏昵称或者游戏ID',
      type: 'text',
      required: true,
      enabled: true,
      maxLength: 64,
    },
    {
      key: 'remark',
      label: '订单备注(选填)',
      placeholder: '请输入订单备注(选填)',
      type: 'textarea',
      required: false,
      enabled: true,
      maxLength: 200,
    },
    {
      key: 'contactPhone',
      label: '联系方式（选填）',
      placeholder: '请输入联系手机号码（选填）',
      type: 'phone',
      required: false,
      enabled: true,
      maxLength: 20,
    },
  ],
  /** 护航员选择（打手称呼与两个选项文案均可改） */
  workerLabel: '选择护航员',
  workerRandomLabel: '随机安排',
  workerDesignatedLabel: '指定护航员',
  /** 费用区与提交按钮文案 */
  feeTitle: '商品费用',
  feeUnitLabel: '单价',
  totalLabel: '合计',
  submitText: '提交订单',
  /** 下单页顶部提示（可空） */
  notice: '',
};

/** 公开：下单表单配置（客户端下单页完全由它驱动，管理端可改） */
@ApiTags('public')
@Controller('public')
export class OrderFormPublicController {
  constructor(private readonly settings: SystemSettingService) {}

  @Get('order-form')
  @ApiOperation({ summary: '公开：下单页表单配置（区服选项/字段标签与必填/护航员文案/提交按钮文案）' })
  async config() {
    const row = await this.settings.get('order_form_config');
    const cfg = (row?.cfgValue as Record<string, unknown> | undefined) ?? {};
    // 浅合并：管理端只存覆盖项也不会丢默认
    return {
      ...DEFAULT_ORDER_FORM,
      ...cfg,
      zoneOptions: (cfg.zoneOptions as unknown[] | undefined) ?? DEFAULT_ORDER_FORM.zoneOptions,
      fields: (cfg.fields as unknown[] | undefined) ?? DEFAULT_ORDER_FORM.fields,
    };
  }
}

/** 管理端：下单表单配置（读写同一份 system_setting） */
@ApiTags('admin/settings')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class OrderFormAdminController {
  constructor(private readonly settings: SystemSettingService) {}

  @Get('order-form')
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：读取下单表单配置（含默认值）' })
  async read() {
    const row = await this.settings.get('order_form_config');
    return {
      ...DEFAULT_ORDER_FORM,
      ...((row?.cfgValue as Record<string, unknown> | undefined) ?? {}),
    };
  }

  @Put('order-form')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write：保存下单表单配置（字段标签/必填/开关/区服/文案）' })
  async save(@Body() dto: Record<string, unknown>) {
    await this.settings.update('order_form_config', dto, '下单页表单配置（管理端可自定义）', 'admin');
    return { ok: true };
  }
}
