import { BadRequestException } from '@nestjs/common';

/**
 * 「一个老板账号能绑几个打手账号」——**全平台唯一真相**（合并双端·身份切换，方案甲）。
 *
 * 负责人 2026-10-06 拍板：
 * - 默认 **1**（一个老板账号默认绑 1 个打手账号）；
 * - **上限可配**（管理端改 `system_setting.worker_binding_max_per_boss`，立即生效，无缓存）；
 * - 该配置行 `is_high_security = 1` → **仅超级管理员可改**（复用 `docs/04` 既有最高安全档机制，
 *   与 `purchase_points_hint` 同档；普通管理员可读、写在 `SystemSettingService.update` 被拒）。
 *
 * 为什么不把上限写死在唯一键里（"一个老板只能有一条 active"）：
 * 上限一旦可配成 2/3，固定唯一键就会把合法绑定一票否决。因此：
 * - **打手侧**用真唯一键钉死（`UK_wib_active_worker`）：一个打手账号同时只能被一个老板绑定 —— 这是语义硬约束，与上限无关；
 * - **老板侧**用「槽位 + 唯一键」实现可配上限（`UK_wib_active_boss_slot`）：第 i 条 active 绑定占槽位 i，
 *   上限 N 时最多 N 条；并发抢同一槽位由唯一键兜底（不会因竞态越过上限）。
 */
export const WORKER_BINDING_MAX_PER_BOSS_KEY = 'worker_binding_max_per_boss';
/** 默认上限 1 个（负责人 2026-10-06 定案） */
export const WORKER_BINDING_MAX_PER_BOSS_DEFAULT = 1;
/** 允许范围 1–10（0 等于「谁都不能绑」，语义上应由功能开关承担；>10 则老板侧身份列表无法展示） */
export const WORKER_BINDING_MAX_PER_BOSS_MIN = 1;
export const WORKER_BINDING_MAX_PER_BOSS_MAX = 10;
/** 管理端/错误提示统一口径 */
export const WORKER_BINDING_MAX_RANGE_TEXT = `${WORKER_BINDING_MAX_PER_BOSS_MIN}–${WORKER_BINDING_MAX_PER_BOSS_MAX} 的整数`;
export const WORKER_BINDING_MAX_PER_BOSS_DESCRIPTION =
  '一个老板账号最多可绑定的打手账号数（默认 1；超出时绑定接口返回中文提示，仅超管可改）';

/**
 * 伴随会话（companion）访问令牌 TTL：**12 小时**（设计稿 §3.2 / A3 定案）。
 *
 * 与 primary 的差异（安全性来源）：
 * - primary = 2 小时 access + 30 天 refresh（单设备互斥）；
 * - companion = 12 小时 access **且 refresh 也只有 12 小时**（硬上限：到点必须重新用打手账密切换一次），
 *   且每次请求都要校验绑定仍 active（见 JwtAuthGuard）→ 解绑/停用立即失效，偷到令牌也活不过 12 小时。
 */
export const COMPANION_ACCESS_TTL_SECONDS = 12 * 60 * 60;
export const COMPANION_REFRESH_TTL_SECONDS = 12 * 60 * 60;

/** 绑定接口限流：与 `/auth/login` **同一策略**（5 次/分/IP+账号，docs/03）——防打手账密爆破 */
export const BIND_RATE_LIMIT = 5;
export const BIND_RATE_WINDOW_SECONDS = 60;

/** 原始值的人读描述（错误提示里带上，便于运营自查；与 commission-rate 同口径） */
function describeRaw(raw: unknown): string {
  if (raw === undefined) return '未填写';
  if (raw === null) return 'null';
  if (typeof raw === 'string') return `"${raw.slice(0, 20)}"`;
  if (typeof raw === 'number' || typeof raw === 'boolean') return String(raw);
  if (Array.isArray(raw)) return '数组';
  if (typeof raw === 'object') return '对象';
  return typeof raw;
}

/** 规整为合法上限；非法返回 null（不抛异常，供读配置回退用，与 parseCommissionRate 同语义） */
export function parseWorkerBindingMax(raw: unknown): number | null {
  let n: number;
  if (typeof raw === 'number') {
    n = raw;
  } else if (typeof raw === 'string' && raw.trim() !== '') {
    n = Number(raw.trim());
  } else {
    return null;
  }
  if (!Number.isFinite(n) || !Number.isInteger(n)) return null;
  if (n < WORKER_BINDING_MAX_PER_BOSS_MIN || n > WORKER_BINDING_MAX_PER_BOSS_MAX) return null;
  return n;
}

/** 写入口校验：非法直接 400 + 中文错误（管理端「系统设置」页改这一项时立即得到反馈） */
export function assertWorkerBindingMax(raw: unknown): number {
  const n = parseWorkerBindingMax(raw);
  if (n === null) {
    throw new BadRequestException(
      `绑定上限必须是 ${WORKER_BINDING_MAX_RANGE_TEXT}（单位：个），当前值非法：${describeRaw(raw)}`,
    );
  }
  return n;
}
