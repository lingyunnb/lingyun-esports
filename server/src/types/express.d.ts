declare namespace Express {
  interface Request {
    /** 请求 ID（由 RequestIdMiddleware 注入），贯穿日志/流水/审计 */
    requestId: string;
    /** JWT 解析后的当前主体（JwtAuthGuard 注入）：{ userId, role, jti } */
    user?: { userId: string; role: string; jti: string };
  }
}
