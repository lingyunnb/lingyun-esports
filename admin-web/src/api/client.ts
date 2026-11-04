/** API 客户端（docs/03）：统一响应结构 + 401 处理 + 请求ID 透传 */
export interface ApiResponse<T = unknown> {
  code: number;
  message: string;
  data: T;
  requestId: string;
  timestamp: number;
}

export class ApiException extends Error {
  constructor(
    public readonly code: number,
    public readonly message: string,
    public readonly requestId: string,
  ) {
    super(message);
  }
}

const TOKEN_KEY = 'fish_admin_token';

/**
 * 生成请求 ID（`x-request-id` 透传用）。
 *
 * ⚠️ **为什么不用 `crypto.randomUUID()` 直调**（2026-10-15 真故障，代价很大）：
 * 它**只在「安全上下文」可用** —— 即 **HTTPS 或 `localhost` / `127.0.0.1` / `file://`**。
 * 而管理端有相当一部分访问方式是 **`http://<公网IP>:3100`**（例如负责人直接开
 * `http://YOUR_SERVER_HOST:3100`），这**不是安全上下文** → `crypto.randomUUID` 是 `undefined`
 * → 调用直接抛 `TypeError`。
 *
 * 症状极具误导性（当时排查了很久）：
 *   · 页面**照常渲染**（HTML/CSS/JS 都正常）
 *   · 但 `request()` 在**拼请求头之前**就抛异常 → 被 `LoginView` 里
 *     `e instanceof ApiException ? e.message : '登录失败，请稍后重试'` 的兜底吞掉
 *     → 界面只显示「**登录失败，请稍后重试**」
 *   · 这条文案看起来像"网络不通"，于是被误判成"账号密码错了/后端挂了"；
 *   · 而用 curl / node 测同一接口**全都通过**（它们不走这段前端代码），
 *     本地 `localhost:5173` 也**从不复现**（localhost 恰好是安全上下文）—— 双重掩盖。
 *
 * 所以这里显式判能力，缺失时退回 RFC4122 v4 的纯 JS 实现（任何上下文都能跑）。
 * 归因留痕：云端 `fish-server-out.log` 曾出现
 *   `method=POST path=/api/v1/auth/login status=400 raw=Expected property name or '}' in JSON…`
 * 与本条同批的登录异常；修掉本处后该现象消失。
 */
function uuid(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  // 兜底：RFC4122 v4（不依赖安全上下文）
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}
export function setToken(token: string | null) {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

export async function request<T = unknown>(
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  const token = getToken();
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const requestId = uuid();
  headers['x-request-id'] = requestId;

  let resp: Response;
  try {
    resp = await fetch(`/api/v1${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiException(-1, '网络连接失败，请检查网络', requestId);
  }

  let json: ApiResponse<T>;
  try {
    json = (await resp.json()) as ApiResponse<T>;
  } catch {
    throw new ApiException(resp.status, `请求失败（${resp.status}）`, requestId);
  }
  if (json.code !== 0) {
    // 单设备登录（docs/04）：任意接口 401（被顶掉/过期/登出）→ 清本地令牌并回登录页提示原因
    // 登录接口自身的 401（密码错误）不触发跳转，由登录页就地展示
    if (json.code === 401 && !path.startsWith('/auth/login')) {
      setToken(null);
      const reason = json.message === '账号已在其他设备登录' ? json.message : '登录已失效，请重新登录';
      if (window.location.pathname !== '/login') {
        window.location.href = `/login?reason=${encodeURIComponent(reason)}`;
      }
    }
    throw new ApiException(json.code, json.message, json.requestId);
  }
  return json.data;
}

/** 媒体上传返回（阶段13） */
export interface MediaUploadResult {
  id: string;
  path: string;
  mimeType: string;
  width: number | null;
  height: number | null;
  sizeBytes: number;
}

/** 上传媒体文件（multipart，管理端通道，权限点 admin:media:write 服务端校验） */
export async function uploadMedia(type: string, file: File): Promise<MediaUploadResult> {
  const fd = new FormData();
  fd.append('type', type);
  fd.append('file', file);
  const headers: Record<string, string> = { 'x-request-id': uuid() };
  const token = getToken();
  if (token) headers['Authorization'] = `Bearer ${token}`;
  let resp: Response;
  try {
    resp = await fetch('/api/v1/admin/media/upload', { method: 'POST', headers, body: fd });
  } catch {
    throw new ApiException(-1, '网络连接失败，请检查网络', '');
  }
  let json: ApiResponse<MediaUploadResult>;
  try {
    json = (await resp.json()) as ApiResponse<MediaUploadResult>;
  } catch {
    throw new ApiException(resp.status, `请求失败（${resp.status}）`, '');
  }
  if (json.code !== 0) {
    throw new ApiException(json.code, json.message, json.requestId);
  }
  return json.data;
}

/** 媒体 id → 预览路径（公开资源；vite 已代理 /media 到后端） */
export function mediaPreviewPath(id: string | null | undefined): string | null {
  return id ? `/media/public/${id}` : null;
}

/**
 * 受保护媒体（聊天图片 / 投诉截图）→ 临时预览地址（负责人 2026-10-04）
 *
 * 为什么要绕一层：`<img src>` 带不上 Authorization 头，受保护媒体只认 Bearer 令牌，
 * 直接把 `/media/protected/:id` 塞进 src 会 404（服务端按 docs/08 做归属校验，管理员可读）。
 * 这里用 fetch 带上令牌取二进制 → blob URL；调用方负责在关闭弹层时 revoke。
 */
export async function protectedMediaUrl(id: string): Promise<string> {
  const token = getToken();
  const resp = await fetch(`/api/v1/media/protected/${id}`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  if (!resp.ok) throw new ApiException(resp.status, `截图读取失败（${resp.status}）`, '');
  return URL.createObjectURL(await resp.blob());
}

/** /auth/me 返回的管理员资料 */
export interface AdminMe {
  id: string;
  username: string;
  uid: string;
  nickname: string;
  role: string;
  admin: { roleCode: string | null; permissions: string[]; isOwner?: boolean };
}
