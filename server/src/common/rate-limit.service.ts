import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import Redis from 'ioredis';

/**
 * Redis 固定窗口限流（docs/03、docs/09）。
 * 登录接口：5 次/分钟/IP+账号；后续 WS 与敏感接口复用。
 */
@Injectable()
export class RateLimitService {
  private readonly logger = new Logger('RateLimit');
  private readonly redis: Redis;

  constructor(config: ConfigService) {
    this.redis = new Redis({
      host: config.get<string>('REDIS_HOST'),
      port: config.get<number>('REDIS_PORT'),
      password: config.get<string>('REDIS_PASSWORD') || undefined,
      lazyConnect: true,
    });
  }

  /**
   * 窗口内是否允许通过。true=放行，false=超限（docs/03：429）
   */
  async allow(key: string, limit: number, windowSeconds: number): Promise<boolean> {
    const redisKey = `rl:${key}`;
    try {
      const count = await this.redis.incr(redisKey);
      if (count === 1) {
        await this.redis.expire(redisKey, windowSeconds);
      }
      return count <= limit;
    } catch (e) {
      // Redis 异常时放行（限流是防护层，不能因限流服务故障阻断主流程）
      this.logger.error(`限流检查失败 key=${redisKey}: ${e instanceof Error ? e.message : String(e)}`);
      return true;
    }
  }
}
