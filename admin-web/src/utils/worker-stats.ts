/**
 * 打手统计（接单次数 / 好评率）的**显示与校验唯一出口**
 * ============================================================================
 * ## ⚠️ 好评率是「百分数」，不是 0–1 比率（踩过坑，别再改回去）
 *
 * 服务端唯一生成点 `satisfiedRateText()`（`server/src/modules/review/review.service.ts`）
 * 下发的是**百分数字符串、保留 1 位小数**：`"98.2"` 表示 **98.2%**；**无评价时为 `null`**。
 * 本文件与 App 端唯一出口 `satisfiedRateText()`
 * （`apps/boss-app/lib/models/review_models.dart`）的判定**逐条对齐** —— 三端必须渲染成同一个字面量。
 *
 * **历史事故（本文件就是为它写的）**：曾写成"两种口径都吃"（`v <= 1 ? v * 100 : v`）。
 * 于是 100 条评价里只有 1 条好评时，服务端给的 `"1.0"`（= **1%**）被渲染成 **100%** ——
 * 把差评显示成满分，用户会照着"满分"去下单。所以这里：
 *   · **绝不 `× 100`**、绝不猜"是不是比率"；
 *   · 0–100 的区间校验与"怎么显示"写在同一个文件里
 *     （`PUT /admin/workers/:id/display-stats` 的合法区间与显示口径本就是同一个口径）。
 *
 * ## 用法
 * ```ts
 * rateText(98.2)                  // '98.2%'
 * rateText('1.0')                 // '1%'      ← 不是 100%
 * rateText(98.75)                 // '98.8%'   ← 一位小数（四舍五入）
 * rateText(98)                    // '98%'     ← 整数不带小数点
 * satisfiedRateText(null, 0)      // '暂无评价'
 * satisfiedRateText(98.2, 42)     // '98.2%'
 * rateText(null)                  // '—'       ← 纯格式化，不替调用方判「暂无评价」
 * ordersText(2847)                // '2,847 次'
 * parseRateInput('98.2')          // { kind: 'ok', value: 98.2 }
 * parseRateInput('150')           // { kind: 'invalid', message: '…' }
 * ```
 */

/** 无评价时好评率的**唯一文案**（页面与校验共用同一个字面量，不可能漂移） */
export const NO_REVIEW_TEXT = '暂无评价';

/** 接单次数展示值的合法区间（后端契约：0–999999 整数） */
export const ORDERS_MIN = 0;
export const ORDERS_MAX = 999999;

/** 好评率展示值的合法区间（后端契约：0.0–100.0 一位小数；**百分数口径**） */
export const RATE_MIN = 0;
export const RATE_MAX = 100;

/** 可接受后端下发的三种形态：number / 百分数字符串（如 `"98.2"`）/ null */
export type StatLike = number | string | null | undefined;

/**
 * 归一成有限数字：`null` / `''` / `undefined` / `NaN` / `Infinity` 一律 `null`
 * （返回 `null` 而不是 0 —— 让调用方能区分「真的是 0」与「没这个值」）。
 */
export function toStatNumber(v: StatLike): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

/** 一位小数、整数不带小数点（`98.0` → `98`、`98.75` → `98.8`）——与 App 端逐字一致 */
function oneDecimalText(n: number): string {
  const fixed = n.toFixed(1);
  return fixed.endsWith('.0') ? fixed.slice(0, -2) : fixed;
}

/**
 * 好评率 → `98.2%` / `1%` / `暂无评价`（**只认百分数口径**）。
 *
 * 判定顺序（与 App 端 `satisfiedRateText()` 同序，保证两端同值）：
 *   ① `null` / 非数字 / 负数 → 「暂无评价」（不猜，绝不编 100）；
 *   ② 超出 `0–100` → 按 `0–100` 收敛（保持与 App 端一致的渲染，不产出 `105%` 这种越界文案）；
 *   ③ 其余按百分数理解 + 一位小数。
 *
 * `reviewCount` 传了就一并参判：**明确为 0 条时同样给「暂无评价」** —— 0 条评价算不出好评率。
 */
export function satisfiedRateText(v: StatLike, reviewCount?: StatLike): string {
  const n = toStatNumber(v);
  if (n === null || n < RATE_MIN) return NO_REVIEW_TEXT;
  const count = toStatNumber(reviewCount);
  if (count !== null && count <= 0) return NO_REVIEW_TEXT;
  const clamped = Math.min(Math.max(n, RATE_MIN), RATE_MAX);
  return `${oneDecimalText(clamped)}%`;
}

/**
 * 已确定的百分数 → `98.2%`（**纯数字格式化，不做「有无评价」判定**）。
 *
 * 用于「展示值」这种运营**显式设定**的数字 —— 它填了就是填了，不该被「暂无评价」覆盖。
 * 非数字 → `—`（中性占位，不猜）。
 */
export function rateText(v: StatLike): string {
  const n = toStatNumber(v);
  if (n === null) return '—';
  const clamped = Math.min(Math.max(n, RATE_MIN), RATE_MAX);
  return `${oneDecimalText(clamped)}%`;
}

/** 计数文案（`2847` → `2,847 次`；缺失 → `—`）—— 千分位只服务"接单次数"这类整数计数 */
export function ordersText(v: StatLike): string {
  const n = toStatNumber(v);
  if (n === null) return '—';
  const s = Math.trunc(Math.abs(n))
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${n < 0 ? '-' : ''}${s} 次`;
}

// ---------------------------------------------------------------- 输入解析 / 校验
/**
 * 输入框解析结果（三态，调用方**不必自己判空**）：
 *   · `blank`   —— 留空 = **跟随真实**（不是 0！）
 *   · `ok`      —— 合法，`value` 为可提交的数字
 *   · `invalid` —— 不合法，`message` 是给运营看的中文原因（前端先挡，后端也会挡）
 */
export type FieldParse =
  | { kind: 'blank' }
  | { kind: 'ok'; value: number }
  | { kind: 'invalid'; message: string };

/** 接单次数输入解析：**0–999999 的整数**（小数 / 负数 / 字母 / 越界一律 invalid） */
export function parseOrdersInput(raw: string): FieldParse {
  const s = raw.trim();
  if (s === '') return { kind: 'blank' };
  if (!/^\d+$/.test(s)) {
    if (s.startsWith('-')) return { kind: 'invalid', message: `接单次数不能小于 ${ORDERS_MIN}` };
    return { kind: 'invalid', message: '接单次数需为整数（不能带小数点或其它字符）' };
  }
  const n = Number(s);
  if (n > ORDERS_MAX) return { kind: 'invalid', message: `接单次数不能大于 ${ORDERS_MAX}` };
  return { kind: 'ok', value: n };
}

/**
 * 好评率输入解析：**0.0–100.0、最多一位小数**，且**只认百分数**。
 *
 * 输入框里填的 `98.2` **就是** `98.2%`（不是 0.982、不会被 ×100）。
 * 多填小数位（如 `98.25`）直接判不合法并说明，**不做静默四舍五入**（静默改数字比报错更难查）。
 */
export function parseRateInput(raw: string): FieldParse {
  const s = raw.trim();
  if (s === '') return { kind: 'blank' };
  if (!/^\d+(\.\d)?$/.test(s)) {
    if (s.startsWith('-')) return { kind: 'invalid', message: `好评率不能小于 ${RATE_MIN}` };
    if (/^\d+\.\d{2,}$/.test(s)) return { kind: 'invalid', message: '好评率最多一位小数（如 98.2）' };
    return { kind: 'invalid', message: '好评率需为数字（百分数，如 98.2 表示 98.2%）' };
  }
  const n = Number(s);
  if (n > RATE_MAX) {
    return { kind: 'invalid', message: `好评率不能大于 ${RATE_MAX}（这里是百分数：100 表示 100%）` };
  }
  return { kind: 'ok', value: n };
}
