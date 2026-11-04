/**
 * 分页参数安全解析（docs/03、docs/09）
 *
 * 背景：查询参数一律是不可信输入。历史实现形如 `Number(page) || 1`，
 * 只挡住了 NaN，挡不住负数与 Infinity —— 负数 truthy 不会回落默认值，
 * 最终把非法值交给 TypeORM 的 skip/take，触发 500（已复现 9 个端点）。
 * 小数（pageSize=10.9）同样会让 take 非法。
 *
 * 因此统一在此钳制：NaN / 非有限数 / <1 / 小数，全部收敛到合法区间。
 */

/** 页码上限：仅用于约束 OFFSET，避免超深分页拖垮查询（任何真实数据集都远达不到） */
const MAX_PAGE = 1_000_000;

/** 解析页码：非法值回落 fallback，并钳制到 [1, MAX_PAGE] */
export function parsePage(raw?: string | number | null, fallback = 1): number {
  const n = Math.trunc(Number(raw));
  if (!Number.isFinite(n) || n < 1) return fallback;
  return Math.min(n, MAX_PAGE);
}

/** 解析每页数量：非法值回落 fallback，并钳制到 [1, max]（默认上限 50，与服务端既定分页规范一致） */
export function parsePageSize(raw?: string | number | null, fallback = 20, max = 50): number {
  const n = Math.trunc(Number(raw));
  if (!Number.isFinite(n) || n < 1) return fallback;
  return Math.min(n, max);
}

/** 解析游标/序号类参数（如 beforeSeq / afterSeq / limit）：非法值回落 fallback，不小于 min */
export function parseSeq(raw?: string | number | null, fallback = 0, min = 0): number {
  const n = Math.trunc(Number(raw));
  if (!Number.isFinite(n) || n < min) return fallback;
  return n;
}
