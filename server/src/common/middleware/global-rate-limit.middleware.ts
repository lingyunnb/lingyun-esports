import { Injectable, NestMiddleware } from '@nestjs/common';
import { NextFunction, Request, Response } from 'express';
import { RateLimitService } from '../rate-limit.service';

/**
 * 全局 API 限流（docs/09）：按 IP 计数，常规接口 300 次/分，媒体下载 1000 次/分（下载豁免过严限制）。
 * Redis 固定窗口；限流服务故障时放行（防护层不阻断主流程）；429 响应与统一响应结构一致。
 */
@Injectable()
export class GlobalRateLimitMiddleware implements NestMiddleware {
  constructor(private readonly rateLimit: RateLimitService) {}

  async use(req: Request, res: Response, next: NextFunction): Promise<void> {
    const rawIp = (req.ip || req.socket?.remoteAddress || 'unknown').replace(/^::ffff:/, '');
    // Cloudflare Tunnel 回源时所有请求都来自本机回环：用 CF-Connecting-IP 还原真实客户端 IP 参与限流
    // （仅信任回环来源携带的头，防直连时伪造头绕过限流，docs/09）
    const cfIp = req.headers['cf-connecting-ip'];
    const ip = (rawIp === '127.0.0.1' || rawIp === '::1') && typeof cfIp === 'string' && cfIp ? cfIp : rawIp;
    const isMedia = req.path.startsWith('/media/');
    const allowed = await this.rateLimit.allow(`global:${ip}:${isMedia ? 'media' : 'api'}`, isMedia ? 1000 : 300, 60);
    if (!allowed) {
      res.status(429).json({
        code: 429,
        message: '请求过于频繁，请稍后再试',
        data: null,
        requestId: (req as Request & { requestId?: string }).requestId ?? '',
        timestamp: Date.now(),
      });
      return;
    }
    next();
  }
}
