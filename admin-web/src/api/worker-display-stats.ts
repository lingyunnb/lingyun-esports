/**
 * 打手「展示数据」管理端接口（负责人 2026-10-16 指令：**只能改接单次数与好评率的展示值**）
 * ============================================================================
 * ## 口径（写死在这里，别在页面里另解一遍）
 *   · **接单次数（`completedOrders`）+ 好评率（`satisfiedRate`）** 可由管理端设「展示值」；
 *   · **评价内容一律真实** —— 本模块**不提供**任何评价写入通道（不是"先不做"，是没有这个接口）；
 *   · **未设展示值 = 跟随真实值**（`null`，不是 0）。
 *
 * ## 契约（后端并行实现，见任务书）
 * ```
 * GET  /api/v1/admin/workers/:id/stats
 *   → { real:      { completedOrders, reviewCount, satisfiedRate },
 *       display:   { completedOrders, satisfiedRate },     // null = 跟随真实
 *       effective: { completedOrders, reviewCount, satisfiedRate } }
 * PUT  /api/v1/admin/workers/:id/display-stats
 *   body: { completedOrders: 1234 | null, satisfiedRate: 98.2 | null }
 *   · completedOrders：0–999999 整数；satisfiedRate：0.0–100.0 一位小数（**百分数**）
 *   · 返回更新后的 stats
 * 权限：worker:adjust（服务端只授 super_admin；非超管一律 403）
 * ```
 * ⚠️ **`:id` 是 `worker.id`**（不是 `user.id`）—— 与本控制器的兄弟路由
 * （`POST /admin/workers/:id/permission`、`PUT /admin/workers/:id/players-profile`）同源，
 * 别拿「身份绑定」那套 `userId` 塞进来（那是 `user.id`，混用会打到别人档案上）。
 *
 * ⚠️ `satisfiedRate` 是**百分数**（`98.2` = 98.2%），**不是 0–1 比率**；
 * 怎么显示一律走 `@/utils/worker-stats`（唯一出口，那里也有踩坑记录）。
 *
 * ## 读侧别名归一（沿用 `api/recharge.ts` / `api/withdraw.ts` 的既有做法）
 * 服务端字段名以落盘代码为准，可能与契约定稿略有差异 → 本文件只做**读侧**容错（候选键表），
 * 写侧一律用契约字段名。真机联调若发现差异，只改候选表，页面不用动。
 */
import { request } from '@/api/client';

/** 一组统计（真实值 / 最终生效值同形） */
export interface WorkerStatsTriple {
  /** 接单次数（整数计数） */
  completedOrders: number;
  /** 评价条数（好评率的样本数：**为 0 时好评率算不出来**） */
  reviewCount: number;
  /** 好评率：**百分数**（`98.2` = 98.2%）或 `null`（无评价）——不是 0–1 比率 */
  satisfiedRate: number | null;
}

/**
 * 管理端设置的「展示值」。
 * **两个字段各自独立**：`null` = 该项**跟随真实值**（不是 0、不是空字符串）。
 */
export interface WorkerStatsDisplay {
  completedOrders: number | null;
  satisfiedRate: number | null;
}

export interface WorkerStats {
  /** 真实值（订单与真实评价的实时统计，只读） */
  real: WorkerStatsTriple;
  /** 展示值（管理端设的对外数字；null = 跟随真实） */
  display: WorkerStatsDisplay;
  /** 最终生效值（对外真正下发的值 —— 预览是否与它一致，就是"有没有改对"的唯一判据） */
  effective: WorkerStatsTriple;
}

function asRecord(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === 'object' ? (v as Record<string, unknown>) : {};
}

/** 按候选键取第一个**存在**的键（刻意不用 `??` 链：`0` 是合法值，不能被跳过） */
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

/** 真实值 / 生效值：缺失即 0 / null（与 App 端「字段缺失各自降级」同一姿势，绝不编数字） */
function normTriple(raw: unknown): WorkerStatsTriple {
  const o = asRecord(raw);
  return {
    completedOrders: readNum(o, ['completedOrders', 'completed_orders', 'orderCount', 'order_count']) ?? 0,
    reviewCount: readNum(o, ['reviewCount', 'review_count', 'reviews', 'commentCount']) ?? 0,
    satisfiedRate: readNum(o, ['satisfiedRate', 'satisfied_rate', 'goodRate', 'good_rate']),
  };
}

/** 展示值：**只认 null 与数字**，缺字段即 null（= 跟随真实）—— 绝不用 0 兜底 */
function normDisplay(raw: unknown): WorkerStatsDisplay {
  const o = asRecord(raw);
  return {
    completedOrders: readNum(o, ['completedOrders', 'completed_orders']),
    satisfiedRate: readNum(o, ['satisfiedRate', 'satisfied_rate']),
  };
}

function normStats(raw: unknown): WorkerStats | null {
  const o = asRecord(raw);
  // 服务端未回传任何一组数据（例如 204 / data=null）→ 交给调用方决定（宁可重读，不猜）
  if (!('real' in o) && !('display' in o) && !('effective' in o)) return null;
  return {
    real: normTriple(o.real),
    display: normDisplay(o.display),
    effective: normTriple(o.effective ?? o.real),
  };
}

/**
 * 读取某打手的真实值 / 展示值 / 最终生效值。
 * 权限不足（非超管）时服务端返回 403，由调用方给出「需要超管权限」的兜底提示。
 */
export async function fetchWorkerStats(workerId: string): Promise<WorkerStats> {
  const data = await request<unknown>('GET', `/admin/workers/${encodeURIComponent(workerId)}/stats`);
  const stats = normStats(data);
  if (!stats) throw new Error('接口未返回统计数据');
  return stats;
}

/**
 * 保存展示值：`null` = **恢复跟随真实值**。
 *
 * 返回更新后的 stats；服务端未回传时返回 `null`（调用方按需要重读，不本地猜测）。
 * 写操作会落 `operation_log`（服务端负责），前端不重复留痕。
 */
export async function saveWorkerDisplayStats(
  workerId: string,
  body: WorkerStatsDisplay,
): Promise<WorkerStats | null> {
  const data = await request<unknown>('PUT', `/admin/workers/${encodeURIComponent(workerId)}/display-stats`, {
    completedOrders: body.completedOrders,
    satisfiedRate: body.satisfiedRate,
  });
  return normStats(data);
}
