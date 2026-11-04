/**
 * 打手六维评分（手填）管理端接口（负责人 2026-10-18 指令）
 * ============================================================================
 * ## 为什么有这个接口
 * 老板评价是**自愿**的：没有评价 → `worker_rating_agg` 无行（或全 0 + `sample_count = 0`）
 * → 陪玩主页六轴（评分 / 技术水平 / 情绪价值 / 抗压能力 / 声音听感 / 综合表现）**全显示 `--`**。
 * 管理端需要一个**只影响展示**的手填通道，让新打手/冷门打手的主页雷达图也有数据。
 *
 * ## 契约
 * ```
 * GET  /api/v1/admin/workers/:id/rating-manual
 *   → { workerId, manual{六列, null=未手填}, effective{六维生效值}, sources{六维来源},
 *       samples, updatedBy, updatedAt }
 * PUT  /api/v1/admin/workers/:id/rating-manual
 *   body: { score?, skill?, emotion?, stress?, voice?, shop? }   // 六项均可选
 *   · 数字 0–10，最多两位小数；显式 null = 清除该项（回自动）；**省略 = 不改**
 *   · 返回与 GET 同形（管理端不必再取一次）
 * 权限：admin:worker:write（与既有打手管理同一个权限点，未新增）
 * ```
 *
 * ⚠️ **`:id` 是 `worker.id`**（不是 `user.id`）—— 与本页其它接口
 * （`PUT /admin/workers/:id/players-profile`、`POST /admin/workers/:id/permission`）同源。
 *
 * ⚠️ **只影响展示，不影响等级**：等级判定只读 `worker_rating_agg` / `worker_stats` / `order_review`。
 * 这一点在 UI 上也必须写出来（本页脚注与弹窗说明各一处），否则运营会以为改分能升级。
 *
 * ## 六维与五维
 * 五维 = 老板评价的五列（`skill/emotion/stress/voice/shop`）；「评分」（`score`）是雷达图第一轴，
 * 原本由**好评率 ÷ 10** 算出来，服务端没有对应列 —— 手填后由 `sources.score === 'manual'` 优先采用。
 */
import { request } from '@/api/client';

/** 六维字段（顺序 = 雷达图六轴） */
export const RATING_DIMS6 = ['score', 'skill', 'emotion', 'stress', 'voice', 'shop'] as const;
export type RatingDim6 = (typeof RATING_DIMS6)[number];

/** 单维来源：手填 / 自动（聚合或好评率换算）/ 都没有 */
export type RatingSource = 'manual' | 'auto' | 'none';

/** 六维中文名（**唯一出处**：表格列、弹窗标签、校验提示都读它） */
export const DIM_LABELS: Readonly<Record<RatingDim6, string>> = {
  score: '评分',
  skill: '技术水平',
  emotion: '情绪价值',
  stress: '抗压能力',
  voice: '声音听感',
  shop: '综合表现',
};

/** 六维值（`null` = 该维没有数据；**不是 0**） */
export type RatingValues = Record<RatingDim6, number | null>;

export interface WorkerRatingManual {
  workerId: string;
  /** 手填值（`null` = 未手填 → 该项回自动）—— 表单回填用 */
  manual: RatingValues;
  /** 生效值（手填优先，否则自动；都没有 → null） */
  effective: RatingValues;
  /** 逐维来源 */
  sources: Record<RatingDim6, RatingSource>;
  /** 老板评价条数（`worker_rating_agg.sample_count`；手填不改变它） */
  samples: number;
  /** 最后修改人（user.id；null = 从未手填过） */
  updatedBy: string | null;
  /** 最后修改时间（null = 从未手填过） */
  updatedAt: string | null;
}

/** 提交体：只带**改动过**的字段（省略 = 不改；`null` = 清除） */
export type RatingManualPatch = Partial<Record<RatingDim6, number | null>>;

function asRecord(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === 'object' ? (v as Record<string, unknown>) : {};
}

/** 按候选键取第一个**存在**的键（`0` 是合法值，不能被跳过） */
function readNum(row: Record<string, unknown>, keys: string[]): number | null {
  for (const k of keys) {
    if (!(k in row)) continue;
    const v = row[k];
    if (v === null || v === undefined || v === '') return null;
    const n = typeof v === 'number' ? v : Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

/** 六维值：缺字段即 `null`（= 没有数据）—— 绝不用 0 兜底 */
function normValues(raw: unknown): RatingValues {
  const o = asRecord(raw);
  const out = {} as RatingValues;
  for (const dim of RATING_DIMS6) out[dim] = readNum(o, [dim]);
  return out;
}

/** 逐维来源：只认三值，其余按 `none`（不猜） */
function normSources(raw: unknown): Record<RatingDim6, RatingSource> {
  const o = asRecord(raw);
  const out = {} as Record<RatingDim6, RatingSource>;
  for (const dim of RATING_DIMS6) {
    const v = o[dim];
    out[dim] = v === 'manual' || v === 'auto' ? v : 'none';
  }
  return out;
}

function normManual(raw: unknown): WorkerRatingManual {
  const o = asRecord(raw);
  return {
    workerId: String(o.workerId ?? ''),
    manual: normValues(o.manual),
    effective: normValues(o.effective),
    sources: normSources(o.sources),
    samples: readNum(o, ['samples', 'sampleCount']) ?? 0,
    updatedBy: o.updatedBy == null ? null : String(o.updatedBy),
    updatedAt: o.updatedAt == null ? null : String(o.updatedAt),
  };
}

/** 读取某打手的六维手填值与生效值 */
export async function fetchWorkerRatingManual(workerId: string): Promise<WorkerRatingManual> {
  const data = await request<unknown>(
    'GET',
    `/admin/workers/${encodeURIComponent(workerId)}/rating-manual`,
  );
  return normManual(data);
}

/**
 * 保存六维手填值。
 *
 * `patch` 里**只放改动过的字段**：省略的字段服务端保持原值不动
 * （`null` 才是"清除该项"，与"没改"是两件事）。
 */
export async function saveWorkerRatingManual(
  workerId: string,
  patch: RatingManualPatch,
): Promise<WorkerRatingManual> {
  const data = await request<unknown>(
    'PUT',
    `/admin/workers/${encodeURIComponent(workerId)}/rating-manual`,
    patch,
  );
  return normManual(data);
}

/** 六维值的展示文案（`9.86` / `8.5` / `10` / `--`；整数不带小数点、不吃尾零） */
export function dimText(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return '--';
  const v = Number(value);
  if (v === Math.round(v)) return String(Math.round(v));
  const s = v.toFixed(2);
  return s.endsWith('0') ? s.slice(0, -1) : s;
}

/** 来源标签（表格里显示「手填」/「自动」/「—」） */
export function sourceText(source: RatingSource): string {
  return source === 'manual' ? '手填' : source === 'auto' ? '自动' : '—';
}
