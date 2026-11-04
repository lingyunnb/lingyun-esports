import { HttpException, HttpStatus, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/** 腾讯开放平台 Graph API 默认基址（`QQ_GRAPH_BASE_URL` 可覆盖：仅用于本地打桩/联调测试） */
const DEFAULT_GRAPH_BASE = 'https://graph.qq.com';
/** 单次网络调用硬超时（负责人要求 ≤10s：绝不允许一个卡住的第三方调用把请求线程拖死） */
const QQ_TIMEOUT_MS = 10_000;

/** 复核失败原因（服务层据此选中文文案与 HTTP 状态，**文案只有一份**：见 qqErrorToException） */
export type QqErrorReason =
  | 'unconfigured'
  | 'invalid_token'
  | 'appid_mismatch'
  | 'bad_response'
  | 'timeout'
  | 'network';

export interface QqMe {
  /** 服务端复核得到的权威 openid（**唯一可信来源**） */
  openid: string;
  unionid: string | null;
  /** 腾讯返回的 client_id（= 应用 APP ID；必须与本服务端配置一致） */
  clientId: string | null;
}

export interface QqUserInfo {
  nickname: string | null;
  /** QQ 头像直链（**不落库**：本站头像是 media 体系，没有"外链头像"列；仅回给调用方备将来用） */
  figureUrl: string | null;
}

export type QqResult<T> = { ok: true; data: T } | { ok: false; reason: QqErrorReason; detail?: string };

/**
 * 失败原因 → 中文 HTTP 异常（**唯一映射处**：服务层各处直接调用，不各写一套文案/状态码）。
 *
 * 状态码口径：
 * - `unconfigured` **503**「QQ 登录未配置」——服务端缺配置，属"暂时不可用"，不是客户端错；
 * - `timeout` / `network` **503**「QQ 登录服务暂时不可用，请稍后重试」——上游抖动，可重试；
 * - `invalid_token` / `appid_mismatch` / `bad_response` **400**「QQ 授权已失效，请重新授权后登录」——
 *   凭证本身不成立（过期的 access_token、别家应用的 token、伪造 token），要让用户重新授权。
 */
export function qqErrorToException(reason: QqErrorReason): HttpException {
  if (reason === 'unconfigured') {
    return new HttpException('QQ 登录未配置', HttpStatus.SERVICE_UNAVAILABLE);
  }
  if (reason === 'timeout' || reason === 'network') {
    return new HttpException('QQ 登录服务暂时不可用，请稍后重试', HttpStatus.SERVICE_UNAVAILABLE);
  }
  return new HttpException('QQ 授权已失效，请重新授权后登录', HttpStatus.BAD_REQUEST);
}

/**
 * QQ 互联 Graph API 客户端（2026-10-10）。
 *
 * 只做两件事，且**只用 Node 内置 fetch**（不引入腾讯 SDK、不加任何 npm 依赖）：
 * 1. `oauth2.0/me`：用 `access_token` 换 **权威 openid/unionid**，并校验返回的 `client_id`
 *    等于本服务端配置的 `QQ_APP_ID`（拿别家应用的 token 来登录 → 直接挡掉）；
 * 2. `user/get_user_info`：取昵称（**失败只降级为无昵称**，绝不让 QQ 侧的小毛病挡住登录）。
 *
 * 硬约束（负责人指定）：
 * - **绝不相信客户端传的 openid**：openid 一律以本客户端的复核结果为准，入参 openid 只用于比对；
 * - 超时 ≤10s，失败**永不抛到异常链之外**（返回 `{ok:false}`，由服务层选中文文案与状态码）；
 * - `access_token` / `QQ_APP_KEY` **绝不进日志**。
 */
@Injectable()
export class QqOauthClient {
  private readonly logger = new Logger('QqOauth');

  constructor(private readonly config: ConfigService) {}

  /** APP ID（未配置 = 空串） */
  get appId(): string {
    return String(this.config.get<string>('QQ_APP_ID') ?? '').trim();
  }

  /** APP Key（未配置 = 空串；**只用于判定"配置是否齐全"，当前流程不参与签名**） */
  get appKey(): string {
    return String(this.config.get<string>('QQ_APP_KEY') ?? '').trim();
  }

  /** 是否已配置（两项都非空才可用；未配置时接口一律中文 503，不做任何网络调用） */
  get configured(): boolean {
    return this.appId.length > 0 && this.appKey.length > 0;
  }

  /** Graph API 基址（默认 https://graph.qq.com；`QQ_GRAPH_BASE_URL` 仅供本地打桩/联调测试） */
  private baseUrl(): string {
    const raw = String(this.config.get<string>('QQ_GRAPH_BASE_URL') ?? '').trim() || DEFAULT_GRAPH_BASE;
    return raw.replace(/\/+$/, '');
  }

  /** 复核 access_token → 权威 openid/unionid */
  async resolveOpenId(accessToken: string): Promise<QqResult<QqMe>> {
    if (!this.configured) return { ok: false, reason: 'unconfigured' };
    const url =
      `${this.baseUrl()}/oauth2.0/me?access_token=${encodeURIComponent(accessToken)}` +
      `&fmt=json&unionid=1`;
    const res = await this.getJson(url);
    if (!res.ok) return res;

    const payload = res.data;
    // 腾讯错误体：{"error":100016,"error_description":"access token check failed"}
    if (payload.error !== undefined) {
      return {
        ok: false,
        reason: 'invalid_token',
        detail: `error=${String(payload.error)} ${String(payload.error_description ?? '').slice(0, 120)}`.trim(),
      };
    }
    const openid = String(payload.openid ?? '').trim();
    const clientId = String(payload.client_id ?? '').trim() || null;
    if (!openid) return { ok: false, reason: 'bad_response', detail: 'missing openid' };
    // APP ID 校验：token 必须属于本应用（否则等于"拿别家应用的登录态换本平台账号"）
    if (clientId && clientId !== this.appId) {
      return { ok: false, reason: 'appid_mismatch', detail: `client_id=${clientId}` };
    }
    return {
      ok: true,
      data: { openid, unionid: String(payload.unionid ?? '').trim() || null, clientId },
    };
  }

  /**
   * 取昵称（可选能力）：任何失败都只是"没有昵称"，**不影响登录**。
   * 头像直链刻意**不落库**（本站头像走 media 体系，`user` 表没有外链头像列），只随返回值带出。
   */
  async fetchUserInfo(accessToken: string, openid: string): Promise<QqUserInfo> {
    if (!this.configured) return { nickname: null, figureUrl: null };
    const url =
      `${this.baseUrl()}/user/get_user_info?access_token=${encodeURIComponent(accessToken)}` +
      `&oauth_consumer_key=${encodeURIComponent(this.appId)}&openid=${encodeURIComponent(openid)}`;
    const res = await this.getJson(url);
    if (!res.ok) {
      this.logger.warn(`取 QQ 昵称失败（降级为无昵称）：${res.reason} ${res.detail ?? ''}`);
      return { nickname: null, figureUrl: null };
    }
    // ret !== 0 表示腾讯侧拒绝（如 token 无 user_info 权限）；同样只降级
    if (Number(res.data.ret ?? 0) !== 0) {
      this.logger.warn(`取 QQ 昵称被拒（降级为无昵称）：ret=${String(res.data.ret)}`);
      return { nickname: null, figureUrl: null };
    }
    const nickname = String(res.data.nickname ?? '').trim();
    const figureUrl = String(
      res.data.figureurl_qq_2 ?? res.data.figureurl_qq_1 ?? res.data.figureurl ?? '',
    ).trim();
    return { nickname: nickname || null, figureUrl: figureUrl || null };
  }

  /**
   * GET + JSON 解析（超时 10s、永不抛异常）。
   *
   * `oauth2.0/me` 在不带 `fmt=json` 时返回 `callback( {...} );`，这里两种形态都接
   * （腾讯文档里两种都存在；只认一种会在某些 token 下直接解析失败）。
   */
  private async getJson(url: string): Promise<QqResult<Record<string, unknown>>> {
    let text: string;
    try {
      const res = await fetch(url, {
        method: 'GET',
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(QQ_TIMEOUT_MS),
      });
      text = await res.text();
      if (!res.ok) {
        return { ok: false, reason: res.status >= 500 ? 'network' : 'invalid_token', detail: `http_${res.status}` };
      }
    } catch (e) {
      const err = e as { name?: string; message?: string };
      // AbortSignal.timeout 触发时 name = 'TimeoutError'（旧运行时为 AbortError）
      const timedOut = err?.name === 'TimeoutError' || err?.name === 'AbortError';
      // 只记原因，不记 URL（URL 里带 access_token）
      this.logger.warn(`QQ Graph 调用失败：${timedOut ? 'timeout' : 'network'} ${String(err?.message ?? '').slice(0, 120)}`);
      return { ok: false, reason: timedOut ? 'timeout' : 'network' };
    }
    const parsed = parseQqJson(text);
    if (!parsed) return { ok: false, reason: 'bad_response', detail: text.slice(0, 120) };
    return { ok: true, data: parsed };
  }
}

/**
 * 解析腾讯返回值：JSON 本体 或 `callback( {...} );` 包裹形态。
 * 解析不出来返回 null（调用方按 bad_response 处理），**绝不把原文抛给客户端**。
 */
export function parseQqJson(text: string): Record<string, unknown> | null {
  const raw = String(text ?? '').trim();
  if (!raw) return null;
  const candidates = [raw];
  // callback( {...} ); / callback({...});
  const m = raw.match(/^[A-Za-z_$][\w$]*\s*\(\s*([\s\S]*?)\s*\)\s*;?$/);
  if (m) candidates.push(m[1]);
  for (const c of candidates) {
    try {
      const v = JSON.parse(c);
      if (v && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>;
    } catch {
      // 试下一种形态
    }
  }
  return null;
}
