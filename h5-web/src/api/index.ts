/**
 * 接口封装（H5）—— 覆盖老板端核心交易流
 * ============================================================================
 * 端点全部来自后端真实路由（`server/src/modules/**`），**不新增、不改动服务端**：
 *
 * 公开（无需登录）：
 *   GET  /public/home              首页聚合
 *   GET  /public/banners           宣传图
 *   GET  /public/announcements     公告列表 / 详情
 *   GET  /public/games             游戏
 *   GET  /public/categories        分类
 *   GET  /public/products          商品列表（支持 divisionId / categoryId / keyword / page）
 *   GET  /public/products/:id      商品详情
 *   GET  /public/players           找陪玩
 *   GET  /public/leaderboard       排行榜
 *   GET  /public/order-form        下单页「填写信息」配置（字段/必填/顺序全由此下发）
 *   GET  /divisions/grouped        分部（按游戏分组）
 *
 * 登录后：
 *   POST /auth/login               登录
 *   GET  /auth/me                  我是谁
 *   PUT  /user/profile             改资料
 *   GET  /user/profile/:uid        公开资料
 *   GET  /user/orders              我的订单
 *   GET  /user/orders/:id          订单详情
 *   POST /user/orders              下单
 *   POST /user/orders/:id/confirm  确认完成
 *   POST /user/orders/:id/cancel   取消
 *   GET  /user/wallet/transactions 余额流水
 *   POST /user/recharge/requests   充值申请（上传截图）
 *   GET  /user/recharge/requests   我的充值申请
 *
 * ⚠️ 字段名一律**以服务端实际返回为准** —— 页面里若发现形状不符，先读接口返回再改，
 *    不许在前端臆造字段（App 端的 `OrderBrief`/`Wallet` 模型可作形状参考）。
 */
import { http } from './client';

// 令牌与异常类型从 client 统一再导出：页面/store 只 import '@/api' 一处，避免深路径散落
export { getToken, setToken, ApiError, type ApiResponse } from './client';

/* ---------------- 类型（宽松定义；以服务端返回为准） ---------------- */

export interface Page<T> {
  list: T[];
  total?: number;
  page?: number;
  pageSize?: number;
  hasMore?: boolean;
}

export interface Profile {
  id: string;
  username?: string;
  nickname?: string;
  avatarUrl?: string;
  phone?: string;
  level?: number;
  levelName?: string;
  [k: string]: unknown;
}

export interface OrderBrief {
  id: string;
  orderNo: string;
  status: string;
  statusName: string;
  productName: string;
  divisionName?: string;
  totalAmount: string | number;
  quantityText?: string;
  priceUnit?: string;
  createdAt: string;
  workerNickname?: string;
  [k: string]: unknown;
}

export interface OrderFormConfig {
  fields: Array<{
    key: string;
    label: string;
    placeholder?: string;
    type?: string;
    required?: boolean;
    enabled?: boolean;
    maxLength?: number;
  }>;
  /** 区服选项 —— 线上实际形状是 `{label,value}`（如 `{label:"微信",value:"wechat"}`），映射到 DTO 的 `gameZone` */
  zoneOptions?: Array<{ label: string; value: string }>;
  workerLabel?: string;
  feeTitle?: string;
  submitText?: string;
  notice?: string;
  [k: string]: unknown;
}

/* ---------------- 认证 ---------------- */

export interface LoginResult {
  accessToken: string;
  refreshToken?: string;
  user?: Profile;
  [k: string]: unknown;
}

export const authApi = {
  login: (username: string, password: string) =>
    http.post<LoginResult>('/auth/login', { username, password, role: 'user' }, { anonymous: true }),
  me: () => http.get<Profile>('/auth/me'),
  logout: () => http.post('/auth/logout'),
};

/* ---------------- 公开目录 ---------------- */

export const publicApi = {
  home: () => http.get<Record<string, unknown>>('/public/home', { anonymous: true }),
  banners: () => http.get<unknown[]>('/public/banners', { anonymous: true }),
  announcements: (page = 1, pageSize = 20) =>
    http.get<Page<Record<string, unknown>>>('/public/announcements', { query: { page, pageSize }, anonymous: true }),
  announcement: (id: string) => http.get<Record<string, unknown>>(`/public/announcements/${id}`, { anonymous: true }),
  about: () => http.get<Record<string, unknown>>('/public/about', { anonymous: true }),
  privacy: () => http.get<Record<string, unknown>>('/public/privacy', { anonymous: true }),

  games: () => http.get<unknown[]>('/public/games', { anonymous: true }),
  categories: (query?: Record<string, unknown>) =>
    http.get<unknown[]>('/public/categories', { query, anonymous: true }),
  products: (query?: Record<string, unknown>) =>
    http.get<Page<Record<string, unknown>>>('/public/products', { query, anonymous: true }),
  product: (id: string) => http.get<Record<string, unknown>>(`/public/products/${id}`, { anonymous: true }),

  players: (query?: Record<string, unknown>) =>
    http.get<Page<Record<string, unknown>>>('/public/players', { query, anonymous: true }),
  leaderboard: (query?: Record<string, unknown>) =>
    http.get<Record<string, unknown>>('/public/leaderboard', { query, anonymous: true }),

  /** 下单页「填写信息」配置：**字段/必填/顺序全部由此下发，前端不得写死** */
  orderForm: () => http.get<OrderFormConfig>('/public/order-form', { anonymous: true }),
};

export const divisionApi = {
  grouped: () => http.get<Record<string, unknown>>('/divisions/grouped', { anonymous: true }),
};

/* ---------------- 订单 ---------------- */

/**
 * 下单请求体 —— **扁平结构**（2026-10-15 真机实测后修正）
 *
 * ⚠️ 别再写成嵌套 `fields: {...}`：全局 `whitelist + forbidNonWhitelisted` 会直接回
 *    「**不支持字段 fields**」400。真实 DTO 把动态字段放在**顶层**，
 *    而"有哪些动态字段"由 `GET /public/order-form` 的 `fields[].key` 决定
 *    —— **key 本身就是 DTO 的顶层属性名**，所以提交时按 `payload[f.key] = 值` 回填即可。
 *
 * ⚠️ `divisionId` **不要发**：服务端按商品归属自行派生（`order.service.ts: divisionId: product.divisionId`）。
 * ✅ `idempotencyKey` **必填且至少 8 字符**（同键重放返回同一张订单，不重复扣款）。
 */
export interface CreateOrderPayload {
  productId: string;
  quantity: number;
  /** 区服（由 `zoneOptions[].value` 映射而来，如 `wechat` / `qq`）—— **必填** */
  gameZone: string;
  /** 幂等键（≥8 字符）—— **必填**，防止重复下单 */
  idempotencyKey: string;
  /** 动态字段（如 `gamePlayerId` / `remark` / `contactPhone`），键名取自 `/public/order-form` */
  [k: string]: unknown;
}

export const orderApi = {
  create: (payload: CreateOrderPayload) => http.post<{ id: string; orderNo?: string }>('/user/orders', payload),
  list: (query?: Record<string, unknown>) => http.get<Page<OrderBrief>>('/user/orders', { query }),
  detail: (id: string) => http.get<Record<string, unknown>>(`/user/orders/${id}`),
  confirm: (id: string) => http.post(`/user/orders/${id}/confirm`),
  cancel: (id: string, reason?: string) => http.post(`/user/orders/${id}/cancel`, reason ? { reason } : undefined),
  weeklyQuota: () => http.get<Record<string, unknown>>('/user/orders/weekly-quota'),
};

/* ---------------- 用户 / 钱包 / 充值 ---------------- */

export const userApi = {
  profile: (uid: string) => http.get<Profile>(`/user/profile/${uid}`, { anonymous: true }),
  updateProfile: (patch: Record<string, unknown>) => http.put<Profile>('/user/profile', patch),
};

export const walletApi = {
  transactions: (query?: Record<string, unknown>) =>
    http.get<Page<Record<string, unknown>>>('/user/wallet/transactions', { query }),
};

export const rechargeApi = {
  submit: (form: FormData) => http.post('/user/recharge/requests', undefined, { form }),
  list: (query?: Record<string, unknown>) => http.get<Page<Record<string, unknown>>>('/user/recharge/requests', { query }),
};
