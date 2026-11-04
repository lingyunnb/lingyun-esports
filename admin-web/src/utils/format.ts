/**
 * 金额显示（管理端**唯一实现**）
 * ============================================================================
 * 口径（负责人 2026-10-09 拍板）：平台计价单位从「积分（1 元 = 10 积分）」改为
 * 「余额（1 元 = 1 元）」，存量金额由服务端按 **10:1** 折算（商品 88.00 → 8.80、
 * 钱包 999999 → 99999.90）。**API 字段名不变**，本文件只负责「怎么显示」。
 *
 * 硬要求：
 * - 金额一律带 `¥` 前缀 + **恒两位小数**（例：`¥8.80`、`¥99,999.90`）；
 * - 千分位（`,`）统一走这里，禁止各页面自己 `toFixed` / `toLocaleString` 拼金额
 *   （分散实现必然出现「有的 ¥8.8、有的 ¥8.80、有的 8.8 元」三种写法）。
 *
 * 用法：
 * ```ts
 * formatYuan(8.8)              // ¥8.80
 * formatYuan('99999.9')        // ¥99,999.90   ← 后端 DECIMAL 常以字符串下发，直接收
 * formatYuanSigned(-24.75)     // -¥24.75      ← 流水金额（正数自动带 +）
 * formatYuanOr(row.balance)    // 有值 ¥0.00 / 空值「—」← 表格列（不把缺失值谎报成 0）
 * ```
 *
 * ⚠️ 负数写成 `-¥24.75`（符号在 `¥` 左边），不是 `¥-24.75` —— 中文财务习惯前者。
 */

/** 可接受后端 DECIMAL 的三种下发形态：number / 字符串 / null */
export type AmountLike = number | string | null | undefined;

/**
 * 归一成有限数字：`null`/`''`/`undefined`/`NaN`/`Infinity` 一律返回 `null`
 * （返回 `null` 而不是 0 —— 让调用方能区分「真的是 0」与「没这个值」）。
 */
export function toAmountNumber(v: AmountLike): number | null {
  if (v === null || v === undefined || v === '') return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

/** 整数部分加千分位（小数部分原样保留，避免误伤 `.` 后的三位数字） */
function groupThousands(intPart: string): string {
  return intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/**
 * 金额 → `¥1,234.56`（元；恒两位小数 + 千分位）。
 *
 * 非有限值按 `0` 处理 —— 用在「金额列必须有值」的地方（如 `n-statistic`）；
 * 表格列若想把缺失值显示成「—」，请用 {@link formatYuanOr}。
 */
export function formatYuan(v: AmountLike): string {
  const n = toAmountNumber(v) ?? 0;
  const fixed = Math.abs(n).toFixed(2);
  const [intPart, decPart] = fixed.split('.');
  return `${n < 0 ? '-' : ''}¥${groupThousands(intPart)}.${decPart}`;
}

/** 带符号金额 → `+¥12.00` / `-¥12.00` / `¥0.00`（余额流水、人工调整这类有方向的金额） */
export function formatYuanSigned(v: AmountLike): string {
  const n = toAmountNumber(v) ?? 0;
  return n > 0 ? `+${formatYuan(n)}` : formatYuan(n);
}

/** 表格用：有值走 {@link formatYuan}，缺失/非法值给占位符（默认「—」） */
export function formatYuanOr(v: AmountLike, placeholder = '—'): string {
  return toAmountNumber(v) === null ? placeholder : formatYuan(v);
}
