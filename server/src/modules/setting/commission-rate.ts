import { BadRequestException } from '@nestjs/common';

/**
 * 平台抽成比例（负责人 2026-10-04：抽成改 25% 且管理端可自定义）——**全平台唯一真相**。
 *
 * 取值语义：**百分数整数**（`25` = 平台抽 25%、打手拿 75%）。
 * - 为什么不用小数 `0.25`：管理端就是「数字输入 + % 后缀」，运营按百分数思考；
 *   整数彻底避开浮点误差，也让「抽成 30 → 打手 70」的口径一眼可核（历史数据里
 *   `order_settlement.worker_percentage` 本来就是 70/30 这种整数百分数，语义延续）。
 * - 允许范围 0–50（0 = 平台不抽成，50 = 平台最多抽一半）；非法值一律后端 400 拒绝（中文）。
 * - 库里配置被人手工改坏时，**读侧一律回落默认 25%**，绝不因为一条脏配置把结算算错。
 *
 * 读入口只有两个（禁止在业务代码里再散落硬编码）：
 * - 结算：[SystemSettingService.platformCommissionRate] → [splitAmount]
 * - AI 提示词：[SystemSettingService.platformCommissionRate] → [buildSystemPrompt]
 */
export const PLATFORM_COMMISSION_RATE_KEY = 'platform_commission_rate';
/** 默认抽成 25%（打手 75%），负责人 2026-10-04 定案 */
export const PLATFORM_COMMISSION_RATE_DEFAULT = 25;
export const PLATFORM_COMMISSION_RATE_MIN = 0;
export const PLATFORM_COMMISSION_RATE_MAX = 50;

/** 允许的取值上限文案（管理端/错误提示统一口径：0–50 的整数） */
export const PLATFORM_COMMISSION_RATE_RANGE_TEXT = `${PLATFORM_COMMISSION_RATE_MIN}–${PLATFORM_COMMISSION_RATE_MAX} 的整数`;

/** 原始值的人读描述（错误提示里带上，便于运营自查） */
function describeRaw(raw: unknown): string {
  if (raw === undefined) return '未填写';
  if (raw === null) return 'null';
  if (typeof raw === 'string') return `"${raw.slice(0, 20)}"`;
  if (typeof raw === 'number' || typeof raw === 'boolean') return String(raw);
  if (Array.isArray(raw)) return '数组';
  if (typeof raw === 'object') return '对象';
  return typeof raw;
}

/**
 * 把任意输入规整成合法抽成比例（百分数整数）；非法返回 null（不抛异常，供读配置回退用）。
 * 兼容数字字符串（`"25"` → 25，管理端输入框偶尔会传字符串）。
 */
export function parseCommissionRate(raw: unknown): number | null {
  let n: number;
  if (typeof raw === 'number') {
    n = raw;
  } else if (typeof raw === 'string' && raw.trim() !== '') {
    n = Number(raw.trim());
  } else {
    return null;
  }
  if (!Number.isFinite(n) || !Number.isInteger(n)) return null;
  if (n < PLATFORM_COMMISSION_RATE_MIN || n > PLATFORM_COMMISSION_RATE_MAX) return null;
  return n;
}

/** 写入口校验：非法直接 400 + 中文错误（与全局校验中文化同一口径） */
export function assertCommissionRate(raw: unknown): number {
  const n = parseCommissionRate(raw);
  if (n === null) {
    throw new BadRequestException(
      `抽成比例必须是 ${PLATFORM_COMMISSION_RATE_RANGE_TEXT}（单位：%），当前值非法：${describeRaw(raw)}`,
    );
  }
  return n;
}

/** 打手分成比例 = 100 - 平台抽成 */
export function workerPercentageOf(commissionRate: number): number {
  return 100 - commissionRate;
}

/** 结算分账结果（金额保留 0.01，四舍五入到分） */
export interface SettlementSplit {
  /** 平台抽成比例（百分数整数，如 25） */
  platformPercentage: number;
  /** 打手分成比例（百分数整数，如 75） */
  workerPercentage: number;
  /** 打手入账金额 */
  workerAmount: number;
  /** 平台入账金额 */
  platformAmount: number;
}

/**
 * 按订单金额与生效抽成比例做分账（**金额守恒**：workerAmount + platformAmount === total）。
 *
 * 守恒做法：先按打手比例四舍五入到 0.01，平台 = 总额 - 打手（而不是各自四舍五入），
 * 这样任何小数金额下「打手 + 平台 = 订单额」都严格成立，绝不分出/分丢 1 分钱。
 */
export function splitAmount(total: number, commissionRate: number): SettlementSplit {
  const platformPercentage = commissionRate;
  const workerPercentage = workerPercentageOf(commissionRate);
  const workerAmount = Math.round(total * workerPercentage) / 100;
  const platformAmount = Math.round((total - workerAmount) * 100) / 100;
  return { platformPercentage, workerPercentage, workerAmount, platformAmount };
}
