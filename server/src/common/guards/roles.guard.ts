import { CanActivate, ExecutionContext, ForbiddenException, Injectable, UnauthorizedException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { ROLES_KEY } from '../decorators/roles.decorator';

/** 角色守卫（docs/04）：与 @Roles 配合，JwtAuthGuard 之后执行 */
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const roles = this.reflector.getAllAndOverride<string[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!roles || roles.length === 0) {
      return true;
    }
    const request = context.switchToHttp().getRequest();
    if (!request.user) {
      throw new UnauthorizedException('未登录');
    }
    if (!roles.includes(request.user.role)) {
      throw new ForbiddenException('无权限访问');
    }
    return true;
  }
}
