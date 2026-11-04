import { CanActivate, ExecutionContext, ForbiddenException, Injectable, UnauthorizedException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { Admin } from '../../modules/admin/admin.entity';
import { AdminRole } from '../../modules/rbac/entities/admin-role.entity';
import { PERMISSION_KEY } from '../decorators/require-permission.decorator';
import { OWNER_KEY } from '../decorators/owner-only.decorator';
import { SUPER_ONLY_PERMISSIONS } from '../../modules/rbac/permissions.const';

/**
 * 管理员权限点守卫（docs/04 RBAC）：
 * - 主体必须是 admin 角色且档案正常
 * - super_admin 内置放行（但 @OwnerOnly 标记的接口不放行）
 * - 「仅超管 + 所有者」权限点（退款审批 / 打赏配置）：is_owner=1 的账号额外放行
 * - 其余按 admin_role_permission 实时查库校验（不缓存、不信任前端）
 */
@Injectable()
export class PermissionsGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const code = this.reflector.getAllAndOverride<string>(PERMISSION_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    const ownerOnly = this.reflector.getAllAndOverride<boolean>(OWNER_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!code && !ownerOnly) {
      return true;
    }
    const request = context.switchToHttp().getRequest();
    if (!request.user || request.user.role !== 'admin') {
      throw request.user ? new ForbiddenException('无权限') : new UnauthorizedException('未登录');
    }

    const admin = await this.dataSource.getRepository(Admin).findOne({
      where: { userId: request.user.userId, status: 1 },
    });
    if (!admin) {
      throw new ForbiddenException('无权限');
    }
    // 所有者独占：super_admin 也不放行，只有 is_owner=1 的账号可执行
    if (ownerOnly && admin.isOwner !== 1) {
      throw new ForbiddenException('该操作仅限所有者账号');
    }
    const role = await this.dataSource.getRepository(AdminRole).findOne({ where: { id: admin.roleId } });
    if (!role) {
      throw new ForbiddenException('无权限');
    }
    // 所有者与超管同权：独占权限点（退款审批 / 打赏配置）对 is_owner=1 直接放行
    if (code && admin.isOwner === 1 && SUPER_ONLY_PERMISSIONS.includes(code)) {
      return true;
    }
    if (!code || role.code === 'super_admin') {
      return true;
    }

    const rows: unknown[] = await this.dataSource.query(
      `SELECT 1 FROM admin_role_permission arp
       JOIN permission p ON p.id = arp.permission_id
       WHERE arp.role_id = ? AND p.code = ? LIMIT 1`,
      [admin.roleId, code],
    );
    if (rows.length === 0) {
      throw new ForbiddenException('无权限');
    }
    return true;
  }
}
