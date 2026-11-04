import { createParamDecorator, ExecutionContext } from '@nestjs/common';

/** JWT 解析后的当前主体（由 JwtAuthGuard 注入）：{ userId, role, jti }。主体 id 只从这里取（docs/04） */
export const CurrentUser = createParamDecorator((_data: unknown, ctx: ExecutionContext) => {
  return ctx.switchToHttp().getRequest().user;
});
