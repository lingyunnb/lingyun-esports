/**
 * 通用工具：金额与订单状态
 * ============================================================================
 * **与 App 端逐值对齐**，不是另发明一套：
 * - 金额：`¥` + 两位小数 + 千分位（项目铁律；全站不出现"积分"）
 * - 状态：9 种真实取值 → 五档形态，且**不只靠颜色**
 *   （对齐 `apps/boss-app/lib/widgets/order_status_tag.dart` 的 `OrderStatusStyle`；
 *    这里输出形态 class + 图标名，由 `<OrderStatusTag>` 渲染）
 */

/** 金额：¥1,234.50（两位小数 + 千分位） */
export function fmtMoney(v: unknown): string {
  const n = typeof v === 'number' ? v : parseFloat(String(v ?? '').replace(/[^\d.-]/g, ''));
  if (!Number.isFinite(n)) return '0.00';
  return n.toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** 带符号的金额（¥ 与数字分开，便于给 ¥ 用小一号字） */
export function moneyParts(v: unknown): { sym: string; num: string } {
  return { sym: '¥', num: fmtMoney(v) };
}

/** ISO → 本地时间；同日只给 时:分，跨日给 月-日 时:分（与 App 的紧凑口径一致） */
export function fmtTime(iso?: string): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  const now = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  const hm = `${p(d.getHours())}:${p(d.getMinutes())}`;
  const sameDay = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  return sameDay ? hm : `${p(d.getMonth() + 1)}-${p(d.getDate())} ${hm}`;
}

/** 订单状态五档（对齐 App 的 `orderStatusStyleFor`） */
export type StatusTier = 'wait' | 'live' | 'ok' | 'off' | 'bad' | 'bad-hi';

export interface StatusView {
  tier: StatusTier;
  /** 形态 class（.stag--xxx） */
  cls: string;
  /** 语义色（供图标着色；**不单独承担区分度**） */
  color: string;
}

const TIERS: Record<string, StatusView> = {
  // ① 待处理档（琥珀浅底 · 700）
  pending_take: { tier: 'wait', cls: 'stag--wait', color: 'var(--warn)' },
  pending_dispatch: { tier: 'wait', cls: 'stag--wait', color: 'var(--warn)' },
  pending_confirm: { tier: 'wait', cls: 'stag--wait', color: 'var(--warn)' },
  // ② 进行档（**全页唯一实色** · 白字 · 700）
  taken: { tier: 'live', cls: 'stag--live', color: '#fff' },
  in_progress: { tier: 'live', cls: 'stag--live', color: '#fff' },
  // ③ 完成档（青瓷浅底 · 700）
  completed: { tier: 'ok', cls: 'stag--ok', color: 'var(--celadon)' },
  // ④ 中性终态（灰 · 600）—— 取消是正常终态，**不是错误**
  canceled: { tier: 'off', cls: 'stag--off', color: 'var(--g2)' },
  // ⑤ 异常（红 · 700）/ 售后（描边 2dp + 800，比异常更重一档）
  abnormal: { tier: 'bad', cls: 'stag--bad', color: 'var(--danger)' },
  after_sale: { tier: 'bad-hi', cls: 'stag--bad-hi', color: 'var(--danger)' },
};

export function statusView(status?: string): StatusView {
  return TIERS[String(status ?? '')] ?? { tier: 'off', cls: 'stag--off', color: 'var(--g2)' };
}

/** 每档一个独立图标（**去色后仍能两两分辨**的第一重信号）—— 用 SVG path 表达，避免引图标库 */
export const STATUS_ICON: Record<StatusTier, string> = {
  wait: 'M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z',            // 时钟
  live: 'm13 2-9 12h7l-1 8 9-12h-7l1-8Z',                              // 闪电
  ok: 'm5 13 4 4L19 7',                                                // 对勾
  off: 'M6 6l12 12M18 6L6 18',                                         // 叉
  bad: 'M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z', // 警示
  'bad-hi': 'M4 4h16v12H7l-3 3V4Z',                                    // 申诉单
};
