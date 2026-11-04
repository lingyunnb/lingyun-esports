import { Request } from 'express';

/**
 * 客户端真实 IP —— **限流键与登录日志的唯一来源**（docs/09）。
 *
 * 隧道回源（Cloudflare Tunnel）时所有请求都来自本机回环：此时用 `CF-Connecting-IP` 还原真实客户端 IP；
 * 直连（局域网/真机）时**不信任**该头，防伪造绕过限流。
 *
 * 2026-10-06 从 `AuthController` 的私有方法抽成公共函数（表达式逐字未改）：身份绑定接口
 * （`/user/identity/*`）与 `/auth/login` 必须用**完全同一套** IP 判定，否则限流键会不一致。
 */
export function clientIpOf(req: Request): string {
  const raw = (req.ip ?? '').replace(/^::ffff:/, '');
  const cfIp = req.header('cf-connecting-ip');
  return (raw === '127.0.0.1' || raw === '::1') && cfIp ? cfIp : raw;
}
