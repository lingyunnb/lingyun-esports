import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { InjectDataSource } from '@nestjs/typeorm';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';

@Injectable()
export class HealthService {
  private readonly logger = new Logger('Health');

  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly config: ConfigService,
  ) {}

  /** 数据库与 Redis 连通性检查；任一失败返回 degraded（docs/17 故障排查第一步） */
  async check() {
    const services: Record<string, string> = {};

    try {
      await this.dataSource.query('SELECT 1');
      services.database = 'up';
    } catch (e) {
      services.database = 'down';
      this.logger.error(`数据库不可用: ${e instanceof Error ? e.message : String(e)}`);
    }

    const redis = new Redis({
      host: this.config.get<string>('REDIS_HOST'),
      port: this.config.get<number>('REDIS_PORT'),
      password: this.config.get<string>('REDIS_PASSWORD') || undefined,
      lazyConnect: true,
      connectTimeout: 2000,
    });
    try {
      await redis.ping();
      await redis.quit();
      services.redis = 'up';
    } catch (e) {
      services.redis = 'down';
      redis.disconnect();
      this.logger.error(`Redis 不可用: ${e instanceof Error ? e.message : String(e)}`);
    }

    const allUp = Object.values(services).every((s) => s === 'up');
    return {
      status: allUp ? 'ok' : 'degraded',
      services,
      uptime: Math.round(process.uptime()),
      version: '0.1.0',
      nodeEnv: this.config.get<string>('NODE_ENV'),
    };
  }
}
