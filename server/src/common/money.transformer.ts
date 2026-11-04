/** 金额字段转换器：MySQL decimal 读出为字符串，统一转 number（业务代码零改动） */
export const moneyTransformer = {
  to: (v: unknown) => (v === undefined ? undefined : v),
  from: (v: unknown) => (v === null || v === undefined || v === '' ? v : Number(v)),
};

/**
 * 把原始 SQL 查询结果中的 DECIMAL 金额字段转成 number。
 * createQueryBuilder/query 的 raw 查询绕过实体 transformer，mysql2 对 DECIMAL 返回字符串
 * （如 "5.50"），直接返回给前端会导致展示 "5.50"、"135078.00" 这类带尾零的文本。
 * 用法：getRawMany().map((r) => mapMoney(r, ['totalAmount', 'unitPrice']))
 */
export function mapMoney<T extends Record<string, unknown>>(row: T, keys: Array<keyof T>): T {
  for (const k of keys) {
    if (row[k] !== null && row[k] !== undefined) (row as Record<string, unknown>)[k as string] = Number(row[k]);
  }
  return row;
}
