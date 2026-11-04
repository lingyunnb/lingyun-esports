import { Injectable, NestMiddleware } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { NextFunction, Request, Response } from 'express';

/**
 * 请求 ID：优先复用上游 x-request-id，否则生成 UUID。
 * 贯穿统一响应、异常日志、余额流水、状态日志、审计（docs/03）。
 */
@Injectable()
export class RequestIdMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction) {
    // 幂等：重复注册/多次执行时保持同一 requestId，保证 header 与响应体一致
    if (!req.requestId) {
      const incoming = req.header('x-request-id');
      req.requestId = incoming && incoming.length <= 64 ? incoming : randomUUID();
    }
    res.setHeader('x-request-id', req.requestId);
    next();
  }
}
