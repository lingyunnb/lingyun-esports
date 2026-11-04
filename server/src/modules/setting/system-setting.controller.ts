import { BadRequestException, Body, Controller, Get, Param, Put, Req, UseGuards } from '@nestjs/common';
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
import { SystemSettingService } from './system-setting.service';

/** 系统设置（docs/04：最高安全配置仅超管可改，服务端强制校验） */
@ApiTags('admin/settings')
@Controller('admin/settings')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class SystemSettingController {
  constructor(
    private readonly service: SystemSettingService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  @Get()
  @RequirePermission('admin:setting:read')
  @ApiOperation({ summary: '权限点 admin:setting:read：配置列表' })
  list() {
    return this.service.all();
  }

  @Put(':key')
  @RequirePermission('admin:setting:write')
  @ApiOperation({ summary: '权限点 admin:setting:write：修改配置（高安全项仅超管）' })
  async update(
    @Param('key') key: string,
    @Body() body: { cfgValue?: unknown; description?: string } | undefined,
    @Req() req: Request & { user: { userId: string } },
  ) {
    /**
     * **入口校验（全项目唯一一处，刻意不散进 `SystemSettingService.update`）**
     *
     * 2026-10-17 真事故：管理端传了 `{ value: [...] }`（少了外层 `cfgValue`）、
     * 以及直接传一个裸数组 —— 两种都会让 `body.cfgValue === undefined`，
     * 而 `SystemSettingService.update()` 拿到 `undefined` 后**什么都不写却照样 200**，
     * 前端以为改了、库里一个字没动（"看起来成功其实没写"是最难查的一类问题）。
     *
     * 现在改成**先挡住、再落库**：
     * - 缺 `cfgValue` / 为 `null` → 400；
     * - `cfgValue` 不是普通对象（`typeof !== 'object'` 或数组）→ 400。
     *
     * 校验**只加在这里**：`SystemSettingService.update()` 的签名与语义一个字不动
     * （它仍是配置写入的唯一实现：白名单 / `is_high_security` 超管校验 / 审计留痕）。
     */
    if (!body || body.cfgValue === undefined || body.cfgValue === null) {
      throw new BadRequestException('缺少 cfgValue：系统设置必须以 { cfgValue, description? } 提交');
    }
    if (typeof body.cfgValue !== 'object' || Array.isArray(body.cfgValue)) {
      throw new BadRequestException('cfgValue 必须是对象');
    }
    const cfgValue = body.cfgValue as Record<string, unknown>;
    const description = typeof body.description === 'string' ? body.description : undefined;

    // 管理员角色码（super_admin 检查）
    const rows: Array<{ code: string }> = await this.dataSource.query(
      `SELECT ar.code FROM admin a JOIN admin_role ar ON ar.id = a.role_id WHERE a.user_id = ?`,
      [req.user.userId],
    );
    /**
     * 第 5 个参数是**审计身份**（`module='setting'` 那行的「谁 / 在哪个请求里」）。
     * 2026-10-06 补：留痕实现加在 `SystemSettingService.update()`（唯一写入口），
     * 但**调用方不传 actor 就只会记下「改了什么」、记不下「谁改的」** ——
     * 本接口是管理端通用配置入口，必须把身份与来源请求一并带下去（与
     * `RechargeAdminController.saveConfig` 同一姿势）。不改任何权限与业务行为。
     */
    return this.service.update(key, cfgValue, description, rows[0]?.code ?? null, {
      userId: req.user.userId,
      ip: clientIpOf(req),
      requestId: req.requestId ?? null,
      method: req.method,
      path: req.path,
    });
  }
}
