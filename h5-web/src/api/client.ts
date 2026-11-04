/**
 * API 客户端（H5）
 * ============================================================================
 * 与 App / 管理端共用**同一个后端**（`/api/v1`），同源部署（`/h5/` 下），
 * 所以这里一律用**相对路径** —— 没有 CORS、没有跨域预检、没有第二套地址配置。
 *
 * 响应结构统一为 `{code, message, data, requestId, timestamp}`（`code===0` 为成功）。
 *
 * ## 令牌
 * 后端是**单设备登录**（`docs/04`）：同账号在别处登录会把这里顶掉 →
 * 任意接口回到 401 时，**清令牌并回登录页**，避免用户对着一个"点哪都没反应"的页面发呆。
 */

export interface ApiResponse<T = unknown> {
  code: number;
  message: string;
  data: T;
  requestId: string;
  timestamp: number;
}

/** 业务异常（服务端明确回了 `code !== 0`） */
export class ApiError extends Error {
  constructor(
    public readonly code: number,
    message: string,
    public readonly requestId = '',
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

const TOKEN_KEY = 'h5_token';

export function getToken(): string {
  try {
    return localStorage.getItem(TOKEN_KEY) || '';
  } catch {
    return '';
  }
}

export function setToken(t: string | null) {
  try {
    if (t) localStorage.setItem(TOKEN_KEY, t);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* 隐私模式下 localStorage 可能不可写：静默降级为「本次会话不持久」 */
  }
}

/** 401 时的统一回调（由 App 注入路由跳转，避免这里 import router 造成循环依赖） */
let onUnauthorized: (() => void) | null = null;
export function setUnauthorizedHandler(fn: () => void) {
  onUnauthorized = fn;
}

/** 请求 ID：非安全上下文（`http://<IP>`）下 `crypto.randomUUID` 不可用，必须显式判能力 */
function uuid(): string {
  const c = globalThis.crypto as Crypto | undefined;
  if (c && typeof c.randomUUID === 'function') return c.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (ch) => {
    const r = (Math.random() * 16) | 0;
    const v = ch === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

interface ReqOpts {
  /** 查询参数（自动跳过 undefined / 空串） */
  query?: Record<string, unknown>;
  /** multipart 上传时传 FormData（此时不设 Content-Type，交给浏览器带 boundary） */
  form?: FormData;
  /** 该接口不需要令牌（公开接口） */
  anonymous?: boolean;
}

function buildUrl(path: string, query?: Record<string, unknown>): string {
  const base = `/api/v1${path}`;
  if (!query) return base;
  const qs = Object.entries(query)
    .filter(([, v]) => v !== undefined && v !== null && v !== '')
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join('&');
  return qs ? `${base}?${qs}` : base;
}

export async function request<T = unknown>(
  method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE',
  path: string,
  body?: unknown,
  opts: ReqOpts = {},
): Promise<T> {
  const headers: Record<string, string> = { 'x-request-id': uuid() };
  const token = getToken();
  if (token && !opts.anonymous) headers.Authorization = `Bearer ${token}`;

  let payload: BodyInit | undefined;
  if (opts.form) {
    payload = opts.form; // 不设 Content-Type：让浏览器补 multipart boundary
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }

  let resp: Response;
  try {
    resp = await fetch(buildUrl(path, opts.query), { method, headers, body: payload });
  } catch (e) {
    // 网络层失败（断网/DNS/被拦）—— 与服务端明确拒绝区分开，便于用户理解
    throw new ApiError(-1, '网络连接失败，请检查网络后重试');
  }

  let json: ApiResponse<T>;
  try {
    json = (await resp.json()) as ApiResponse<T>;
  } catch {
    throw new ApiError(resp.status, `服务异常（HTTP ${resp.status}），请稍后重试`);
  }

  if (json.code !== 0) {
    // 单设备登录：非「登录接口自身」的 401 = 被顶掉/过期 → 清令牌回登录页
    if (json.code === 401 && !path.startsWith('/auth/login')) {
      setToken(null);
      onUnauthorized?.();
    }
    throw new ApiError(json.code, json.message || '请求失败', json.requestId);
  }
  return json.data;
}

export const http = {
  get: <T = unknown>(p: string, opts?: ReqOpts) => request<T>('GET', p, undefined, opts),
  post: <T = unknown>(p: string, body?: unknown, opts?: ReqOpts) => request<T>('POST', p, body, opts),
  put: <T = unknown>(p: string, body?: unknown, opts?: ReqOpts) => request<T>('PUT', p, body, opts),
  del: <T = unknown>(p: string, opts?: ReqOpts) => request<T>('DELETE', p, undefined, opts),
};
