/**
 * 提现审核（打手发起提现 → 管理员核对收款信息 → 线下打款后上传凭证标记已打款 / 驳回退回余额）
 * ============================================================================
 * ## 与充值的对称关系（口径不要混）
 *   充值：老板线下付款 → 上传截图 → 管理员**手工加余额**（`已发放`）。
 *   提现：打手申请提现 → 管理员**线下打款** → 上传支付记录截图 → 标记 `已打款`（`paid`）。
 *   两边都**不接支付通道**：没有支付 SDK / 回调 / 支付单号，平台不经手资金、不做自动到账；
 *   提现这一侧多一条硬语义：**驳回即把余额退回打手**（服务端在驳回事务里做，前端只负责把话说清楚）。
 *
 * ## 接口（与任务书契约逐条对应；服务端为并行实现，读侧做别名归一）
 *   `GET  /admin/withdraw/requests?status=&page=&pageSize=`  列表（打手昵称/工号 · 金额 · 状态 · 申请时间 · **收款信息完整**）
 *   `GET  /admin/withdraw/requests/:id`                     详情（**完整**姓名/电话/微信号 + 收款码取图 + 打款记录 / 驳回原因）
 *   `GET  /admin/withdraw/proof/:id?kind=qr|payout`         受保护图片（**必须带 Authorization**，看 `withdrawProofUrl`）
 *   `POST /admin/withdraw/requests/:id/pay`                 body `{ proofMediaId, note? }` → `paid`（`withdraw:pay`）
 *   `POST /admin/withdraw/requests/:id/reject`              body `{ reason }` → `rejected`（余额退回打手）
 *   `GET/PUT /admin/withdraw/config`                        提现设置（仅超管可写）
 *
 * ## 权限点（前端只做隐藏；服务端才是权威）
 *   `withdraw:review` → 列表 / 详情 / 取收款码图；`withdraw:pay` → 打款 / 驳回。
 *
 * ## 读侧别名归一（沿用 `api/recharge.ts` 的既有做法）
 * 服务端字段名以落盘代码为准，可能与契约定稿略有差异。本文件只做**读侧**容错
 * （`pick()` 候选表），写侧一律用契约字段名 —— 真机联调若发现差异，只改候选表，页面不用动。
 */
import { ApiException, getToken, request } from '@/api/client';

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

function asStr(v: unknown): string {
  return v === undefined || v === null ? '' : String(v);
}

/** 列表响应：`{list,total,pendingTotal}`（真契约）与裸数组都收 */
function unwrapList<T>(data: unknown): { list: T[]; total: number; pendingCount: number | null } {
  if (Array.isArray(data)) return { list: data as T[], total: data.length, pendingCount: null };
  const obj = (data ?? {}) as {
    list?: T[];
    rows?: T[];
    total?: number;
    /** 真契约字段名（`withdraw.service.ts` 的 `reviewList`）：全库待处理总数 */
    pendingTotal?: number;
    pendingCount?: number;
    pending?: number;
  };
  const list = obj.list ?? obj.rows ?? [];
  const pendingRaw = obj.pendingTotal ?? obj.pendingCount ?? obj.pending;
  return {
    list,
    total: asNum(obj.total, list.length),
    pendingCount: pendingRaw === undefined || pendingRaw === null ? null : asNum(pendingRaw, 0),
  };
}

// ---------------------------------------------------------------- 状态

/** 提现状态：待处理 / 已打款 / 已驳回（**没有"支付成功"这一档**） */
export type WithdrawStatus = 'pending' | 'paid' | 'rejected';

export const STATUS_FILTERS: { label: string; value: WithdrawStatus }[] = [
  { label: '待处理', value: 'pending' },
  { label: '已打款', value: 'paid' },
  { label: '已驳回', value: 'rejected' },
];

export function statusLabel(s: string): string {
  return STATUS_FILTERS.find((o) => o.value === s)?.label ?? s;
}

/** 状态标签色（页面统一读这里，避免各处自己写 if） */
export function statusTagType(s: string): 'warning' | 'success' | 'error' | 'default' {
  if (s === 'pending') return 'warning';
  if (s === 'paid') return 'success';
  if (s === 'rejected') return 'error';
  return 'default';
}

// ---------------------------------------------------------------- 列表

/** 收款信息三个字段（列表与详情同形：完整值 `account` / 脱敏值 `accountMasked`） */
export interface WithdrawAccount {
  realName: string;
  phone: string;
  wechatId: string;
}

/**
 * 列表行（**收款信息给完整值**）。
 *
 * 口径（负责人 2026-10-11 改定）：**能看列表 = 有 `withdraw:review`（当前只授超管）= 审核人本人**
 * → 向他自己脱敏没有意义，列表直接给完整姓名/电话/微信号，核对收款信息不必再点进详情。
 * 脱敏仍保留在**审计与站内通知**里（服务端负责，前端不参与）。
 * 服务端列表接口新增 `account: {realName, phone, wechatId}` 且**保留** `accountMasked`
 * → 展示串由 [`payeeTextOf`] 逐字段取值：`account` 取不到某字段时才回退 `accountMasked`（服务端未更新也不裂）。
 */
export interface WithdrawRequestRow {
  id: string;
  /** 打手昵称 */
  workerNickname: string;
  /** 打手工号（打手档案编号，不是账号 id） */
  workerNo: string;
  /** 提现金额（元；服务端 DECIMAL 常以字符串下发，显示一律走 formatYuan） */
  amount: number;
  status: string;
  /** **完整**收款信息（列表接口新增字段；服务端未更新 / 该行为空时为 null） */
  account: WithdrawAccount | null;
  /** 脱敏收款信息（保留字段：`account` 取不到时逐字段回退用它；也为 null 时退回 `payeeMasked`） */
  accountMasked: WithdrawAccount | null;
  /** 老形状兜底串（`accountMasked` 若是字符串或平铺 `*Masked` 字段，在这里拼好） */
  payeeMasked: string;
  /** 申请时间 */
  createdAt: string | null;
}

/**
 * **老形状兜底串**（`payeeMasked`）：`accountMasked` 若不是对象（例如服务端曾下发过一整串字符串）
 * 或只有平铺的 `*Masked` 字段时，在这里拼成一行，免得服务端小改一次前端就白屏。
 * 正常形状（对象）由 [`asAccount`] 归一，本函数只是最后一层兜底，**不是**列表的展示口径。
 */
function composeMasked(raw: unknown, row: Record<string, unknown>): string {
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    const a = raw as Record<string, unknown>;
    return [
      asStr(pick(a, ['realName', 'real_name', 'name'])),
      asStr(pick(a, ['phone', 'mobile'])),
      asStr(pick(a, ['wechatId', 'wechat_id', 'wechat', 'wx'])),
    ]
      .filter((x) => x)
      .join(' · ');
  }
  if (typeof raw === 'string') return raw;
  return [
    asStr(pick(row, ['realNameMasked', 'real_name_masked', 'payeeNameMasked'])),
    asStr(pick(row, ['phoneMasked', 'phone_masked', 'payeePhoneMasked'])),
    asStr(pick(row, ['wechatMasked', 'wechat_masked', 'payeeWechatMasked'])),
  ]
    .filter((x) => x)
    .join(' · ');
}

/** 把 `account` / `accountMasked` 归一成三字段对象（非对象形状 → null，交给 [`composeMasked`] 兜底） */
function asAccount(raw: unknown): WithdrawAccount | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const a = raw as Record<string, unknown>;
  const acc: WithdrawAccount = {
    realName: asStr(pick(a, ['realName', 'real_name', 'name'])),
    phone: asStr(pick(a, ['phone', 'mobile'])),
    wechatId: asStr(pick(a, ['wechatId', 'wechat_id', 'wechat', 'wx'])),
  };
  return acc.realName || acc.phone || acc.wechatId ? acc : null;
}

/**
 * 收款信息展示串（**完整值优先**，逐字段回退）。
 *
 * 取值顺序（每个字段各自判定，不是整段二选一）：
 *   ① `row.account.<字段>`（服务端列表接口新增的完整值）
 *   ② `row.accountMasked.<字段>`（服务端未更新 / 该字段缺失时回退，**不裂**）
 *   ③ `row.payeeMasked`（老形状兜底串）
 */
export function payeeTextOf(
  row: Pick<WithdrawRequestRow, 'account' | 'accountMasked' | 'payeeMasked'>,
): string {
  const a = row.account;
  const m = row.accountMasked;
  const parts = [
    a?.realName || m?.realName || '',
    a?.phone || m?.phone || '',
    a?.wechatId || m?.wechatId || '',
  ].filter((x) => x);
  if (parts.length) return parts.join(' · ');
  return row.payeeMasked || '';
}

function normalizeRow(raw: unknown): WithdrawRequestRow {
  const r = (raw ?? {}) as Record<string, unknown>;
  return {
    id: asStr(pick(r, ['id', 'requestId', 'request_id'])),
    workerNickname: asStr(pick(r, ['workerNickname', 'worker_nickname', 'nickname', 'userNickname', 'workerName'])),
    workerNo: asStr(
      pick(r, ['workerNo', 'worker_no', 'workerCode', 'worker_code', 'employeeNo', 'workerUid', 'worker_uid', 'uid']),
    ),
    amount: asNum(pick(r, ['amount', 'amountYuan', 'amount_yuan', 'applyAmount']), 0),
    status: asStr(pick(r, ['status'])) || 'pending',
    // 完整值：服务端列表接口新增 `account`（同时保留 `accountMasked`）
    account: asAccount(pick<unknown>(r, ['account', 'payeeAccount', 'payee_account', 'payee', 'receiver'])),
    accountMasked: asAccount(
      pick<unknown>(r, [
        'accountMasked', 'account_masked',
        'payeeMasked', 'payee_masked', 'payeeInfoMasked', 'payee_info_masked',
      ]),
    ),
    payeeMasked: composeMasked(
      pick<unknown>(r, [
        'accountMasked', 'account_masked',
        'payeeMasked', 'payee_masked', 'payeeInfoMasked', 'payee_info_masked',
        'account', 'payee', 'receiver',
      ]),
      r,
    ),
    // 真契约字段名是 `appliedAt`（申请时间）
    createdAt:
      pick<string>(r, ['appliedAt', 'applied_at', 'createdAt', 'created_at', 'requestedAt', 'submittedAt']) ?? null,
  };
}

export interface WithdrawListQuery {
  status?: string;
  page?: number;
  pageSize?: number;
}

export async function listRequests(
  q: WithdrawListQuery,
): Promise<{ list: WithdrawRequestRow[]; total: number; pendingCount: number | null }> {
  const sp = new URLSearchParams({ page: String(q.page ?? 1), pageSize: String(q.pageSize ?? 20) });
  // status 为空 = 全部（契约里 `status=` 留空即不过滤）
  if (q.status) sp.set('status', q.status);
  const data = await request<unknown>('GET', `/admin/withdraw/requests?${sp.toString()}`);
  const { list, total, pendingCount } = unwrapList<unknown>(data);
  return { list: list.map(normalizeRow), total, pendingCount };
}

// ---------------------------------------------------------------- 详情

/** 打款记录（打款人 / 时间 / 凭证 / 备注） */
export interface WithdrawPayout {
  payerName: string;
  paidAt: string | null;
  /** 支付记录截图 media id（读图仍走 `/admin/withdraw/proof/:id?kind=payout`，不直连 media） */
  proofMediaId: string | null;
  note: string;
}

/**
 * 详情：**完整**收款信息（与列表同口径）+ 打款记录 + 驳回原因。
 * 列表已给完整姓名/电话/微信号（2026-10-11 改定），详情的增量是：打款记录、驳回原因、收款码取图。
 */
export interface WithdrawRequestDetail extends WithdrawRequestRow {
  /** 完整姓名 */
  payeeName: string;
  /** 完整电话 */
  payeePhone: string;
  /** 完整微信号 */
  payeeWechat: string;
  /** 打款记录（`status='paid'` 时才有内容） */
  payout: WithdrawPayout | null;
  rejectReason: string;
  reviewedAt: string | null;
}

function normalizeDetail(raw: unknown): WithdrawRequestDetail {
  const r = (raw ?? {}) as Record<string, unknown>;
  const base = normalizeRow(raw);
  /**
   * 完整收款信息（真契约：`detail()` 额外挂的 `account` 对象）。
   * `account: { realName, phone, wechatId, qrMediaId, qrUrl, updatedAt } | null`
   * （打手还没绑收款信息时为 null → 页面显示「—」，不能编造）。
   */
  const acc = (r['account'] ?? r['payee'] ?? r['receiver']) as Record<string, unknown> | undefined;
  // 打款记录可能是嵌套对象，也可能是平铺字段（真契约是平铺：payerName/paidAt/payoutNote/payoutProofMediaId）
  const nested = (r['payout'] ?? r['payoutRecord'] ?? r['payout_record'] ?? r['payment']) as
    | Record<string, unknown>
    | undefined;
  const payerName = asStr(
    pick(nested ?? {}, ['payerName', 'payer_name', 'adminName', 'admin_name', 'paidBy', 'paid_by', 'operatorName']) ??
      pick(r, ['payerName', 'payer_name', 'paidBy', 'paid_by', 'reviewerName', 'reviewer_name']),
  );
  const paidAt =
    pick<string>(nested ?? {}, ['paidAt', 'paid_at', 'createdAt', 'time']) ??
    pick<string>(r, ['paidAt', 'paid_at']) ??
    null;
  const rejectedAt = pick<string>(r, ['rejectedAt', 'rejected_at']) ?? null;
  const proofMediaId =
    (pick<string>(nested ?? {}, ['proofMediaId', 'proof_media_id', 'mediaId', 'voucherMediaId']) ??
      pick<string>(r, [
        'payoutProofMediaId', 'payout_proof_media_id',
        'proofMediaId', 'proof_media_id', 'voucherMediaId',
      ])) ??
    null;
  const note = asStr(
    pick(nested ?? {}, ['note', 'remark', 'memo']) ?? pick(r, ['payoutNote', 'payout_note', 'payNote', 'pay_note', 'note']),
  );
  const hasPayout = base.status === 'paid' || !!(payerName || paidAt || proofMediaId);
  return {
    ...base,
    payeeName: asStr(pick(acc ?? {}, ['realName', 'real_name', 'name']) ?? pick(r, ['payeeName', 'payee_name', 'accountName', 'account_name'])),
    payeePhone: asStr(pick(acc ?? {}, ['phone', 'mobile']) ?? pick(r, ['payeePhone', 'payee_phone', 'contactPhone', 'contact_phone'])),
    payeeWechat: asStr(pick(acc ?? {}, ['wechatId', 'wechat_id', 'wechat', 'wx']) ?? pick(r, ['payeeWechat', 'payee_wechat'])),
    payout: hasPayout ? { payerName, paidAt, proofMediaId, note } : null,
    rejectReason: asStr(pick(r, ['rejectReason', 'reject_reason', 'reason', 'rejectNote'])),
    // 已处理时间：打款看 paidAt、驳回看 rejectedAt（页面文案按状态各取所需）
    reviewedAt: pick<string>(r, ['reviewedAt', 'reviewed_at']) ?? paidAt ?? rejectedAt ?? null,
  };
}

export async function getRequestDetail(id: string): Promise<WithdrawRequestDetail> {
  return normalizeDetail(await request<unknown>('GET', `/admin/withdraw/requests/${id}`));
}

// ---------------------------------------------------------------- 受保护取图

export type WithdrawProofKind = 'qr' | 'payout';

/**
 * 受保护图片 → 临时预览地址（**绝不允许把接口路径直接塞进 `<img src>`**）。
 *
 * 为什么必须绕一层：受保护媒体只认 `Authorization` 头，而 `<img src>` 带不上头；
 * 直连 `/admin/withdraw/proof/:id` 会 401/404，且**资金凭证不允许做成公开直链**。
 * 所以用 fetch 带令牌取二进制 → blob URL；调用方负责在关闭抽屉时 `URL.revokeObjectURL`。
 *
 * 失败时**抛出服务端中文原文**（如「该申请已打款」这类业务错误不吞）。
 */
export async function withdrawProofUrl(id: string, kind: WithdrawProofKind): Promise<string> {
  const token = getToken();
  let resp: Response;
  try {
    resp = await fetch(`/api/v1/admin/withdraw/proof/${id}?kind=${kind}`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    });
  } catch {
    throw new ApiException(-1, '网络连接失败，请检查网络', '');
  }
  if (!resp.ok) {
    // 服务端错误体是统一结构（code/message）→ 尽量把中文原文透出来，透不出再退回状态码
    let msg = '';
    let code = resp.status;
    try {
      const j = (await resp.json()) as { code?: number; message?: string };
      msg = asStr(j?.message);
      if (typeof j?.code === 'number') code = j.code;
    } catch {
      /* 非 JSON（如网关错误页）→ 用状态码兜底 */
    }
    throw new ApiException(code, msg || `取图失败（${resp.status}）`, '');
  }
  return URL.createObjectURL(await resp.blob());
}

// ---------------------------------------------------------------- 打款 / 驳回

/** 标记已打款（**支付记录截图必填**；重复调用由服务端中文 400 拒绝） */
export function payRequest(id: string, proofMediaId: string, note?: string) {
  return request('POST', `/admin/withdraw/requests/${id}/pay`, {
    proofMediaId,
    ...(note && note.trim() ? { note: note.trim() } : {}),
  });
}

/** 驳回（**必填原因**；服务端会把余额退回打手） */
export function rejectRequest(id: string, reason: string) {
  return request('POST', `/admin/withdraw/requests/${id}/reject`, { reason });
}

// ---------------------------------------------------------------- 提现设置

/** 提现设置（`GET/PUT /admin/withdraw/config`，**仅超管可写**） */
export interface WithdrawConfig {
  /** 单笔提现门槛（元） */
  minAmount: number;
  /** 单笔提现上限（元） */
  maxAmount: number;
  /** 每人每日可申请次数 */
  dailyLimit: number;
  /** 手续费率（百分数，0 = 不收费） */
  feeRate: number;
  /** 给打手看的说明文案（多行） */
  noticeText: string;
}

/**
 * 缺省值只用于**输入框初值**，不作为权威口径：真值一律以 `GET /admin/withdraw/config` 为准
 * （取不到时页面会明说"未取到服务端口径"，而不是把这里的数字伪装成线上生效值）。
 * 下面这组数字与 `server/src/modules/withdraw/withdraw-config.ts` 的
 * `WITHDRAW_CONFIG_DEFAULT` **逐值对齐**（min 10 / max 2000 / daily 1 / fee 0），改一边要改另一边。
 * 服务端硬闸门：min/max 1–1,000,000 整数、dailyLimit 1–20、feeRate 0–50 整数、noticeText ≤500 字且不含"积分"。
 */
export const DEFAULT_WITHDRAW_CONFIG: WithdrawConfig = {
  minAmount: 10,
  maxAmount: 2000,
  dailyLimit: 1,
  feeRate: 0,
  noticeText: '',
};

/** 服务端硬闸门（与 withdraw-config.ts 的常量同值；前端只是提前拦住，服务端才是权威） */
export const WITHDRAW_LIMITS = {
  amountMin: 1,
  amountMax: 1_000_000,
  dailyLimitMin: 1,
  dailyLimitMax: 20,
  feeRateMin: 0,
  feeRateMax: 50,
  noticeMax: 500,
};

export function normalizeWithdrawConfig(raw: unknown): WithdrawConfig {
  const r = (raw ?? {}) as Record<string, unknown>;
  return {
    minAmount: asNum(pick(r, ['minAmount', 'min_amount', 'minYuan', 'min']), DEFAULT_WITHDRAW_CONFIG.minAmount),
    maxAmount: asNum(pick(r, ['maxAmount', 'max_amount', 'maxYuan', 'max']), DEFAULT_WITHDRAW_CONFIG.maxAmount),
    dailyLimit: asNum(pick(r, ['dailyLimit', 'daily_limit', 'dailyTimes', 'daily_times']), DEFAULT_WITHDRAW_CONFIG.dailyLimit),
    feeRate: asNum(pick(r, ['feeRate', 'fee_rate', 'feePercent', 'fee_percent']), DEFAULT_WITHDRAW_CONFIG.feeRate),
    noticeText: asStr(pick(r, ['noticeText', 'notice_text', 'notice'])),
  };
}

export async function getWithdrawConfig(): Promise<WithdrawConfig> {
  return normalizeWithdrawConfig(await request<unknown>('GET', '/admin/withdraw/config'));
}

/** 保存提现设置（仅超管；服务端非超管一律中文 403，前端只是提前禁用） */
export function updateWithdrawConfig(body: WithdrawConfig) {
  return request('PUT', '/admin/withdraw/config', body);
}

// ---------------------------------------------------------------- 上传用途

/**
 * 打款凭证（支付记录截图）的上传用途 = `withdraw_proof`（**受保护**，资金凭证不可公开直连）。
 * 与 `recharge_proof` 同族：`POST /admin/media/upload` 的 `type` 字段。
 */
export const WITHDRAW_PROOF_MEDIA_TYPE = 'withdraw_proof';
