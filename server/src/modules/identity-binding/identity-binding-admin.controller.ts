import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';

import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { IdentityBindingQueryDto } from './dto/identity-binding-query.dto';
import { IdentityBindingAdminService } from './identity-binding-admin.service';

/**
 * 老板 ↔ 打手 身份绑定（管理端**只读**；负责人 2026-10-06 身份合并方案甲）。
 *
 * 权限沿用用户族既有权限点 `admin:user:read`（与 `/admin/users` 同一把钥匙）：
 * 绑定关系本质是"账号之间的关系"，能看用户账号的运营就能看绑定，不新造权限点
 * （新权限点会牵出 role_permission 种子与迁移，属于本轮不该做的事）。
 *
 * ⚠️ 本控制器**只有 GET**：绑定/解绑是老板端能力（`POST /user/identity/bind|unbind`，
 * 主体 id 只从 JWT sub 取）。管理端不提供写接口 —— 避免"运营替用户建立/解除绑定"
 * 这类没有审计与授权语义的越权面。
 */
@ApiTags('admin/identity-bindings')
@Controller('admin/identity-bindings')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class IdentityBindingAdminController {
  constructor(private readonly service: IdentityBindingAdminService) {}

  @Get()
  @RequirePermission('admin:user:read')
  @ApiOperation({
    summary:
      '权限点 admin:user:read：身份绑定列表（老板↔打手；状态/关键词/时间范围筛选 + 分页；含已解绑历史行与上限占用）',
  })
  list(@Query() q: IdentityBindingQueryDto) {
    return this.service.list(q);
  }
}
