import * as Joi from 'joi';

/**
 * 环境变量校验（docs/09：敏感信息一律环境变量，启动即校验防配置错误）
 */
const schema = Joi.object({
  NODE_ENV: Joi.string().valid('development', 'test', 'production').default('development'),
  PORT: Joi.number().default(3000),
  CORS_ORIGINS: Joi.string().allow('').default(''),

  DB_HOST: Joi.string().default('127.0.0.1'),
  DB_PORT: Joi.number().default(3306),
  DB_USER: Joi.string().required(),
  DB_PASSWORD: Joi.string().required(),
  DB_NAME: Joi.string().required(),

  REDIS_HOST: Joi.string().default('127.0.0.1'),
  REDIS_PORT: Joi.number().default(6379),
  REDIS_PASSWORD: Joi.string().allow('').default(''),

  JWT_ACCESS_SECRET: Joi.string().min(32).required(),
  JWT_REFRESH_SECRET: Joi.string().min(32).required(),

  // 超级管理员种子账号（docs/04，仅首次启动创建，幂等）
  ADMIN_USERNAME: Joi.string().min(3).max(32).required(),
  ADMIN_PASSWORD: Joi.string().min(8).max(64).required(),

  // 邮箱验证通道（负责人 2026-10-05）：授权码只存服务端；未配置时邮件通道整体不可用
  MAIL_ENABLED: Joi.string().valid('true', 'false').default('false'),
  MAIL_HOST: Joi.string().allow('').default('smtp.qq.com'),
  MAIL_PORT: Joi.number().default(465),
  MAIL_SECURE: Joi.string().valid('true', 'false').default('true'),
  MAIL_USER: Joi.string().allow('').default(''),
  MAIL_PASS: Joi.string().allow('').default(''),
  MAIL_FROM_NAME: Joi.string().allow('').default(''),
  MAIL_FROM: Joi.string().allow('').default(''),
  MAIL_CODE_TTL_SECONDS: Joi.number().default(600),
  MAIL_CODE_RESEND_SECONDS: Joi.number().default(60),
  // 发信驱动：smtp=真发信（生产唯一允许值）；console=不发真信（仅开发/自动化测试，生产禁用）
  MAIL_DRIVER: Joi.string().valid('smtp', 'console').default('smtp'),
  // 测试用第二把钥匙（默认关闭）：允许在 NODE_ENV=production 下启用 console 驱动
  MAIL_ALLOW_CONSOLE: Joi.string().valid('true', 'false').default('false'),
  // 测试用第二把钥匙（默认关闭）：开启 /auth/email/_test/* 测试端点（生产必须保持 false）
  MAIL_ALLOW_TEST_ENDPOINTS: Joi.string().valid('true', 'false').default('false'),
  // 同 IP 每小时取码上限（默认 10；仅供测试用小额度验证限流，避免真发 10 封邮件）
  MAIL_IP_HOURLY_LIMIT: Joi.number().default(10),

  // QQ 登录（负责人 2026-10-10）：APP ID / APP Key 只存服务端，绝不入代码与客户端。
  // 两项任一为空 = 未配置 → `POST /auth/qq/login|bind` 一律中文 503「QQ 登录未配置」（不做任何网络调用）。
  QQ_APP_ID: Joi.string().allow('').default(''),
  QQ_APP_KEY: Joi.string().allow('').default(''),
  // Graph API 基址：默认腾讯线上地址；**仅用于本地打桩/联调测试**（生产不要改）
  QQ_GRAPH_BASE_URL: Joi.string().allow('').default(''),
});

export function validateEnv(config: Record<string, unknown>) {
  const { error, value } = schema.validate(config, { allowUnknown: true });
  if (error) {
    throw new Error(`环境变量配置错误: ${error.message}`);
  }
  return value;
}
