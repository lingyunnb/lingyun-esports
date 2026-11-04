import { ConfigService } from '@nestjs/config';
import Redis from 'ioredis';

export const REDIS_CLIENT = 'REDIS_CLIENT';

/** 共享 Redis 客户端（限流/计数等，配置来自 env；docs/07 发送限流 20 条/分） */
export const redisProvider = {
  provide: REDIS_CLIENT,
  useFactory: (config: ConfigService) =>
    new Redis({
      host: config.get<string>('REDIS_HOST', '127.0.0.1'),
      port: config.get<number>('REDIS_PORT', 6380),
      password: config.get<string>('REDIS_PASSWORD', '') || undefined,
      lazyConnect: false,
      maxRetriesPerRequest: 2,
    }),
  inject: [ConfigService],
};
