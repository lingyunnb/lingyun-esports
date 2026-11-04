import 'dotenv/config';
import { DataSource } from 'typeorm';

/**
 * TypeORM CLI 专用 DataSource（migration 生成/执行，docs/10）
 * 运行方式：npm run migration:run / migration:generate
 */
export default new DataSource({
  type: 'mysql',
  host: process.env.DB_HOST ?? '127.0.0.1',
  port: Number(process.env.DB_PORT ?? 3306),
  username: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  entities: ['src/modules/**/*.entity.ts'],
  migrations: ['src/migrations/*.ts'],
  charset: 'utf8mb4',
  timezone: 'Z',
  synchronize: false,
});
