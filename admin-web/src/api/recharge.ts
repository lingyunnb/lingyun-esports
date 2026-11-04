/**
 * 充值（负责人：老板端「充值」= 线下扫码 + 截图申请 + 管理员核对后手工加余额）
 *
 * ## 合规口径（不接任何支付通道）
 * - **没有支付 SDK / 回调 / 支付单号**：收款码就是一张**图片**，老板线下扫码付款后自己上传截图；
 * - 平台**不经手资金**，全站**不出现「支付成功」**字样，只有「**已发放**」（= 余额已由管理员手工发放）；
 * - 余额**仅可用于平台内消费，不可提现、不可转让**；
 * - 因此本模块只有三种东西：收款码图（配置）、充值申请（人工核对）、充值设置（档位/到账比例/限额）。
 *
 * ## 计价口径（负责人 2026-10-09）
 * 单位从「积分（1 元 = 10 积分）」改为「余额（1 元 = 1 元）」，存量由服务端按 10:1 折算；
 * **API 字段名一律不变**（`amount` / `points` / `pointsPerYuan` 照旧），页面显示一律 ¥ + 两位小数。
 *
 * ## 接口（与后端 `admin/recharge/*` 契约对应）
 * - `GET/POST/PUT/DELETE /admin/recharge/qr-codes`  收款码增删改查（图片走既有媒体上传）
 * - `GET/PUT /admin/recharge/config`                充值设置（**仅超管可写**，`is_high_security`）
 * - `GET /admin/recharge/requests`                  申请列表（状态 / 关键词 / 时间筛选）
 * - `POST /admin/recharge/requests/:id/grant`       发放（"发放"= 手工加余额，不是"支付"）
 * - `POST /admin/recharge/requests/:id/reject`      驳回（**必填原因**）
 * - `GET/POST/DELETE /admin/recharge/admins`        管理员白名单（≤ adminLimit，只允许 role=admin 账号）
 *
 * ## 关于字段别名
 * 后端为并行实现，列表接口的行字段名可能与本文档契约定稿略有差异。本文件用 `pick()`
 * 做**读侧别名归一**（只认契约里承诺的语义，不凭空造字段），写侧一律用契约字段名。
 * 真机实测后若发现差异，只改本文件的 `pick()` 候选表即可，页面不用动。
 */
import { request } from '@/api/client';

/** 从后端行里按候选键取第一个非空值（读侧容错；写侧不受影响） */
function pick<T = unknown>(row: Record<string, unknown>, keys: string[]): T | undefined {
  for (const k of keys) {
    const v = row[k];
    if (v !== undefined && v !== null && v !== '') return v as T;
  }
  return undefined;
}

function asNum(v: unknown, fallback = 0): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function asBool(v: unknown, fallback = false): boolean {
  if (typeof v === 'boolean') return v;
  if (v === 1 || v === '1' || v === 'true') return true;
  if (v === 0 || v === '0' || v === 'false') return false;
  return fallback;
}

/** 列表响应：后端可能给 `{list,total}`，也可能直接给数组（两种都收） */
function unwrapList<T>(data: unknown): { list: T[]; total: number } {
  if (Array.isArray(data)) return { list: data as T[], total: data.length };
  const obj = (data ?? {}) as { list?: T[]; rows?: T[]; total?: number };
  const list = obj.list ?? obj.rows ?? [];
  return { list, total: asNum(obj.total, list.length) };
}

// ---------------------------------------------------------------- 收款码

export type RechargeChannel = 'wechat' | 'alipay' | 'other';

/** 收款码（管理端配置；老板端只读展示，不参与支付流程） */
export interface RechargeQrCode {
  id: string;
  channel: RechargeChannel;
  /** 标签：同一渠道可以有多张（如「微信 · 客服小祁」），用于老板端区分 */
  label: string;
  sort: number;
  enabled: boolean;
  imageMediaId: string | null;
}

export const CHANNEL_OPTIONS: { label: string; value: RechargeChannel }[] = [
  { label: '微信', value: 'wechat' },
  { label: '支付宝', value: 'alipay' },
  { label: '其他', value: 'other' },
];

export function channelLabel(c: string): string {
  return CHANNEL_OPTIONS.find((o) => o.value === c)?.label ?? '其他';
}

function normalizeQrCode(raw: unknown): RechargeQrCode {
  const r = (raw ?? {}) as Record<string, unknown>;
  const channel = String(pick(r, ['channel']) ?? 'other');
  return {
    id: String(pick(r, ['id']) ?? ''),
    channel: (['wechat', 'alipay', 'other'].includes(channel) ? channel : 'other') as RechargeChannel,
    label: String(pick(r, ['label', 'name', 'title']) ?? ''),
    sort: asNum(pick(r, ['sort', 'sortOrder', 'order']), 0),
    // enabled 也接受 status=1/2 这类既有约定（本项目管理端列表普遍用 status）
    enabled: r['enabled'] !== undefined ? asBool(r['enabled'], true) : asNum(pick(r, ['status']), 1) === 1,
    imageMediaId: pick<string>(r, ['imageMediaId', 'mediaId', 'imageId', 'qrMediaId']) ?? null,
  };
}

export async function listQrCodes(): Promise<RechargeQrCode[]> {
  const data = await request<unknown>('GET', '/admin/recharge/qr-codes');
  return unwrapList<unknown>(data).list.map(normalizeQrCode);
}

/** 提交体：契约字段名 `channel/label/sort/enabled/imageMediaId` */
export interface QrCodePayload {
  channel: RechargeChannel;
  label: string;
  sort: number;
  enabled: boolean;
  imageMediaId: string | null;
}

export function createQrCode(body: QrCodePayload) {
  return request('POST', '/admin/recharge/qr-codes', body);
}

export function updateQrCode(id: string, body: Partial<QrCodePayload>) {
  return request('PUT', `/admin/recharge/qr-codes/${id}`, body);
}

export function deleteQrCode(id: string) {
  return request('DELETE', `/admin/recharge/qr-codes/${id}`);
}

// ---------------------------------------------------------------- 充值设置

/** 充值设置（`is_high_security` → 仅超管可写；普通管理员 GET 可读、PUT 403） */
export interface RechargeConfig {
  /** 金额档位（元）：老板端点选，默认 6,10,20,38,68,98,128,198,328,648 */
  amountOptions: number[];
  /** 是否允许老板自己填金额 */
  customEnabled: boolean;
  /** 自定义金额下限（元） */
  minYuan: number;
  /** 自定义金额上限（元） */
  maxYuan: number;
  /** 1 元到账多少余额（**全站口径**，改它等于改所有档位的应得余额；新口径下为 1，即 1 元 = 1 元余额） */
  pointsPerYuan: number;
  /** 每人同时待审核的申请上限 */
  pendingLimitPerUser: number;
  /** 管理员白名单上限 */
  adminLimit: number;
  /** 给老板看的说明文案（多行） */
  noticeText: string;
  /** 服务端下发：是否仅超管可改（权威判定在服务端 is_high_security） */
  superAdminOnly?: boolean;
  /** 服务端下发：白名单硬上限（负责人定案：最多 5 个账号；adminLimit 只能在它以内收紧） */
  adminLimitMax?: number;
}

export const DEFAULT_AMOUNT_OPTIONS = [6, 10, 20, 38, 68, 98, 128, 198, 328, 648];
export const DEFAULT_POINTS_PER_YUAN = 10;
export const DEFAULT_PENDING_LIMIT = 3;
export const DEFAULT_ADMIN_LIMIT = 5;

export const DEFAULT_CONFIG: RechargeConfig = {
  amountOptions: [...DEFAULT_AMOUNT_OPTIONS],
  customEnabled: true,
  minYuan: 1,
  maxYuan: 9999,
  pointsPerYuan: DEFAULT_POINTS_PER_YUAN,
  pendingLimitPerUser: DEFAULT_PENDING_LIMIT,
  adminLimit: DEFAULT_ADMIN_LIMIT,
  noticeText: '',
};

/** 归一：缺项用默认值（后端若尚未落库该行，页面不该整片空白） */
export function normalizeConfig(raw: unknown): RechargeConfig {
  const r = (raw ?? {}) as Record<string, unknown>;
  const opts = pick<unknown[]>(r, ['amountOptions', 'amount_options', 'options']);
  const amountOptions = Array.isArray(opts)
    ? opts.map((v) => asNum(v, 0)).filter((n) => n > 0)
    : [...DEFAULT_AMOUNT_OPTIONS];
  return {
    amountOptions: amountOptions.length ? amountOptions : [...DEFAULT_AMOUNT_OPTIONS],
    customEnabled: asBool(pick(r, ['customEnabled', 'custom_enabled']), DEFAULT_CONFIG.customEnabled),
    minYuan: asNum(pick(r, ['minYuan', 'min_yuan']), DEFAULT_CONFIG.minYuan),
    maxYuan: asNum(pick(r, ['maxYuan', 'max_yuan']), DEFAULT_CONFIG.maxYuan),
    pointsPerYuan: asNum(pick(r, ['pointsPerYuan', 'points_per_yuan']), DEFAULT_CONFIG.pointsPerYuan),
    pendingLimitPerUser: asNum(
      pick(r, ['pendingLimitPerUser', 'pending_limit_per_user']),
      DEFAULT_CONFIG.pendingLimitPerUser,
    ),
    adminLimit: asNum(pick(r, ['adminLimit', 'admin_limit']), DEFAULT_CONFIG.adminLimit),
    noticeText: String(pick(r, ['noticeText', 'notice_text', 'notice']) ?? ''),
    // 服务端下发的两个只读附加项（GET /admin/recharge/config 平铺返回）
    superAdminOnly: asBool(pick(r, ['superAdminOnly', 'super_admin_only']), true),
    adminLimitMax: asNum(pick(r, ['adminLimitMax', 'admin_limit_max']), DEFAULT_ADMIN_LIMIT),
  };
}

export async function getConfig(): Promise<RechargeConfig> {
  return normalizeConfig(await request<unknown>('GET', '/admin/recharge/config'));
}

export function updateConfig(body: RechargeConfig) {
  return request('PUT', '/admin/recharge/config', body);
}

// ---------------------------------------------------------------- 充值申请

/** 申请状态：待核对 / 已发放 / 已驳回（**没有"支付成功"这一档**） */
export type RechargeRequestStatus = 'pending' | 'granted' | 'rejected';

export const REQUEST_STATUS_OPTIONS: { label: string; value: RechargeRequestStatus }[] = [
  { label: '待核对', value: 'pending' },
  { label: '已发放', value: 'granted' },
  { label: '已驳回', value: 'rejected' },
];

export function statusLabel(s: string): string {
  return REQUEST_STATUS_OPTIONS.find((o) => o.value === s)?.label ?? s;
}

export interface RechargeRequestRow {
  id: string;
  userId: string;
  nickname: string;
  /** 中文 ID（老板端展示与搜索都用它） */
  uid: string;
  /** 申请付款金额（元，老板自己填的真金白银；服务端**不折算**这一列） */
  amount: number;
  /** 应得到账余额（元 = 付款金额 × 1 元到账比例；以后端下发为准，两位小数，显示走 formatYuan） */
  points: number;
  /** 付款截图（媒体 id；公开通道读不到时会自动改走受保护通道） */
  voucherMediaId: string | null;
  status: string;
  /** 审核人昵称/账号 */
  reviewerName: string;
  reviewedAt: string | null;
  rejectReason: string;
  createdAt: string | null;
}

function normalizeRequest(raw: unknown): RechargeRequestRow {
  const r = (raw ?? {}) as Record<string, unknown>;
  return {
    id: String(pick(r, ['id']) ?? ''),
    userId: String(pick(r, ['userId', 'user_id']) ?? ''),
    nickname: String(pick(r, ['nickname', 'userNickname', 'user_nickname']) ?? ''),
    uid: String(pick(r, ['uid', 'userUid', 'user_uid', 'chineseId']) ?? ''),
    amount: asNum(pick(r, ['amount', 'amountYuan', 'amount_yuan']), 0),
    points: asNum(pick(r, ['points', 'grantPoints', 'grant_points', 'pointsAwarded']), 0),
    voucherMediaId:
      pick<string>(r, ['voucherMediaId', 'voucher_media_id', 'proofMediaId', 'proof_media_id', 'mediaId']) ?? null,
    status: String(pick(r, ['status']) ?? 'pending'),
    reviewerName: String(pick(r, ['reviewerName', 'reviewer_name', 'auditorName', 'adminName', 'handlerName']) ?? ''),
    reviewedAt: pick<string>(r, ['reviewedAt', 'reviewed_at', 'auditedAt', 'grantedAt', 'handledAt']) ?? null,
    rejectReason: String(pick(r, ['rejectReason', 'reject_reason', 'reason']) ?? ''),
    createdAt: pick<string>(r, ['createdAt', 'created_at', 'submittedAt']) ?? null,
  };
}

export interface RechargeRequestQuery {
  status?: string;
  keyword?: string;
  /** 毫秒时间戳（n-date-picker）→ 转 ISO 下发 */
  startAt?: number | null;
  endAt?: number | null;
  page?: number;
  pageSize?: number;
}

export async function listRequests(
  q: RechargeRequestQuery,
): Promise<{ list: RechargeRequestRow[]; total: number }> {
  const sp = new URLSearchParams({ page: String(q.page ?? 1), pageSize: String(q.pageSize ?? 20) });
  if (q.status) sp.set('status', q.status);
  if (q.keyword) sp.set('keyword', q.keyword);
  if (q.startAt) sp.set('startTime', new Date(q.startAt).toISOString());
  if (q.endAt) sp.set('endTime', new Date(q.endAt).toISOString());
  const data = await request<unknown>('GET', `/admin/recharge/requests?${sp.toString()}`);
  const { list, total } = unwrapList<unknown>(data);
  return { list: list.map(normalizeRequest), total };
}

/** 发放（= 手工加余额，写余额流水 + 审计；重复发放由服务端中文 400 拒绝） */
export function grantRequest(id: string) {
  return request('POST', `/admin/recharge/requests/${id}/grant`);
}

/** 驳回（必填原因；结果通知申请人） */
export function rejectRequest(id: string, reason: string) {
  return request('POST', `/admin/recharge/requests/${id}/reject`, { reason });
}

// ---------------------------------------------------------------- 管理员白名单

/** 白名单条目（≤ adminLimit 条；只允许 role=admin 账号） */
export interface RechargeAdminEntry {
  /** 删除时用的主键（优先取条目自身 id，其次管理员账号 id） */
  id: string;
  adminUserId: string;
  username: string;
  nickname: string;
  roleCode: string;
  createdAt: string | null;
}

function normalizeAdminEntry(raw: unknown): RechargeAdminEntry {
  const r = (raw ?? {}) as Record<string, unknown>;
  const adminUserId = String(pick(r, ['adminUserId', 'admin_user_id', 'userId', 'user_id', 'adminId']) ?? '');
  return {
    id: String(pick(r, ['id', 'entryId']) ?? adminUserId),
    adminUserId,
    username: String(pick(r, ['username', 'account', 'adminUsername']) ?? ''),
    nickname: String(pick(r, ['nickname', 'adminNickname', 'name']) ?? ''),
    roleCode: String(pick(r, ['roleCode', 'role_code', 'role']) ?? ''),
    createdAt: pick<string>(r, ['createdAt', 'created_at']) ?? null,
  };
}

export async function listWhitelist(): Promise<RechargeAdminEntry[]> {
  const data = await request<unknown>('GET', '/admin/recharge/admins');
  return unwrapList<unknown>(data).list.map(normalizeAdminEntry);
}

/**
 * 加入白名单。
 * 提交体用契约字段 `adminUserId`（= 「管理员与角色」页里该管理员的账号 id）。
 * 若后端最终采用别的键名，只改这一处（列表读侧已做别名归一）。
 */
export function addWhitelist(adminUserId: string) {
  return request('POST', '/admin/recharge/admins', { adminUserId });
}

export function removeWhitelist(entryId: string) {
  return request('DELETE', `/admin/recharge/admins/${entryId}`);
}

// ---------------------------------------------------------------- 上传用途

/**
 * 收款码图片的上传用途（`POST /admin/media/upload` 的 type）。
 *
 * 后端已在 `media/service.ts` 的 TYPE_RULES 登记 `recharge_qr`（**公开可读**，10MB，image）：
 * 收款码必须公开可读（老板端直接拉图显示），受保护用途（recharge_proof / complaint_image）读不到。
 * 本次对接：已从临时借用的 `banner` 切到专用用途 `recharge_qr`（2026-10-07 后端登记后切换）。
 */
export const QR_UPLOAD_MEDIA_TYPE = 'recharge_qr';
