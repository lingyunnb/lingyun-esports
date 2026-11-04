import { BadRequestException } from '@nestjs/common';

/**
 * 打手提现（人工打款）——**全平台唯一真相**的配置契约。
 *
 * ## 与充值同源的取舍：为什么配置落 `system_setting.withdraw_config`
 *
 * 与 `recharge_config` **逐条同构**（理由见 `modules/recharge/recharge-config.ts` 顶部）：
 * 只有 `system_setting` 的**行属性** `is_high_security=1` 才能让"仅超管可写"这条规则
 * **复用既有机制**（`SystemSettingService.update()` 里的角色码判定），
 * 单开一张 `withdraw_config` 表就得把这条规则**再实现一遍**（安全审计 F1 的同一类根因）。
 * 读侧每次实时读库（无缓存）→ 运营改完**下一次请求**即生效。
 *
 * ## 合规口径（CLAUDE.md「提现走人工打款」）
 *
 * 提现 = **平台经手资金**的人工打款流程：打手提交申请 → 申请时**立即从余额扣减并锁定**
 * → 管理员核对收款信息后**线下微信打款** → 打款完成记 `paid`；打款失败则驳回
 * → **退回余额 + 反向流水**。本模块**没有**任何支付通道/代付 API/回调：
 * 打款动作由管理员在微信里手工完成，系统只负责"扣款、锁款、记账、留痕"。
 *
 * ## 金额单位（2026-10-09 计价单位变更后）
 *
 * 一律 `¥`/元，两位小数；**全模块不得出现"积分"**（唯一换算口径见 docs/06）。
 */

/** 配置在 `system_setting` 里的 key */
export const WITHDRAW_CONFIG_KEY = 'withdraw_config';

/** 该配置项的 description（写进 system_setting，管理端「全部配置项」表格直接显示） */
export const WITHDRAW_CONFIG_DESCRIPTION =
  '提现配置（单笔下限/上限、每日申请次数、手续费率、给打手看的说明文案；仅超管可改）';

/**
 * 单笔提现的**绝对天花板**（元）——与充值 `RECHARGE_YUAN_ABS_MAX` 同性质：
 * 上限本身可配，这是防"把配置写成天文数字"的硬闸门（不依赖配置正确性）。
 */
export const WITHDRAW_YUAN_ABS_MAX = 1_000_000;

/** 每日申请次数允许范围（默认 1） */
export const WITHDRAW_DAILY_LIMIT_MIN = 1;
export const WITHDRAW_DAILY_LIMIT_MAX = 20;

/** 手续费率（百分数，0–50 整数，与 `platform_commission_rate` 同口径；**当前固定 0**） */
export const WITHDRAW_FEE_RATE_MIN = 0;
export const WITHDRAW_FEE_RATE_MAX = 50;

/** 说明文案长度上限 */
export const WITHDRAW_NOTICE_MAX = 500;

/**
 * **未结清申请数上限：1**（负责人拍板，写死在代码里而**不是**配置项）。
 *
 * 为什么不做成配置：这是"同一打手不得同时有两笔在途提现"的**资金安全不变量**，
 * 与"每日次数"这种运营口径不同 —— 它就是数据库唯一键 `UK_wr_pending_worker`
 * （`pending_worker_id` 生成列）的语义，改它必须同时改表结构。
 * 运营侧的松紧由 `dailyLimit` 控制；在途并发由本常量 + 唯一键控制。
 */
export const WITHDRAW_PENDING_LIMIT = 1;

/**
 * 说明文案默认值（给打手看）。
 *
 * 用词刻意**不出现"积分"**（计价单位已统一为元），也如实说明"申请即扣款"这一关键语义
 * —— 打手在点提交前必须知道"余额立刻少了 100 元"，否则会被当成"钱不见了"。
 */
export const WITHDRAW_NOTICE_DEFAULT =
  '提现由平台人工打款：提交申请时金额会立即从余额扣除并锁定，管理员核对收款信息后通过微信打款。请确保姓名、手机号、微信号与收款码是同一人，信息不符会导致打款失败；打款失败或信息有误会驳回申请，金额原样退回余额。同一时间只能有一笔提现在处理中。';

/** 提现配置本体（`cfg_value.value` 的形状） */
export interface WithdrawConfig {
  /** 单笔下限（元，整数） */
  minAmount: number;
  /** 单笔上限（元，整数） */
  maxAmount: number;
  /** 每日申请次数上限 */
  dailyLimit: number;
  /** 手续费率（百分数，0–50；当前 0 = 不收手续费，仅作展示口径保留） */
  feeRate: number;
  /** 给打手看的说明文案 */
  noticeText: string;
}

/** 配置默认值（= 负责人定案原文；迁移把这份写进库里，读侧只在整行缺失/损坏时兜底） */
export const WITHDRAW_CONFIG_DEFAULT: WithdrawConfig = {
  minAmount: 10,
  maxAmount: 2000,
  dailyLimit: 1,
  feeRate: 0,
  noticeText: WITHDRAW_NOTICE_DEFAULT,
};

/** 原始值的人读描述（错误提示里带上，便于运营自查；与 recharge-config 同口径） */
function describeRaw(raw: unknown): string {
  if (raw === undefined) return '未填写';
  if (raw === null) return 'null';
  if (typeof raw === 'string') return `"${raw.slice(0, 20)}"`;
  if (typeof raw === 'number' || typeof raw === 'boolean') return String(raw);
  if (Array.isArray(raw)) return '数组';
  if (typeof raw === 'object') return '对象';
  return typeof raw;
}

/** 整数解析（接受 "10" 这类字符串并规整；不合法返回 null） */
function toInt(raw: unknown, min: number, max: number): number | null {
  let n: number;
  if (typeof raw === 'number') n = raw;
  else if (typeof raw === 'string' && raw.trim() !== '') n = Number(raw.trim());
  else return null;
  if (!Number.isFinite(n) || !Number.isInteger(n)) return null;
  if (n < min || n > max) return null;
  return n;
}

/**
 * 解析配置（**读侧兜底**：整行缺失/任一项非法都回落到该字段默认值并保留其余合法字段）。
 *
 * 为什么读侧不抛异常：`GET /worker/withdraw/config` 是打手提现页首屏依赖，
 * 一行配置被写坏就让整页 500 = 把运营的手误放大成线上故障。
 * 写侧（`assertWithdrawConfig`）才是硬闸门（非法 = 中文 400）。
 */
export function parseWithdrawConfig(raw: unknown): WithdrawConfig {
  const src = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const d = WITHDRAW_CONFIG_DEFAULT;

  const maxAmount = toInt(src['maxAmount'], 1, WITHDRAW_YUAN_ABS_MAX) ?? d.maxAmount;
  const minRaw = toInt(src['minAmount'], 1, WITHDRAW_YUAN_ABS_MAX) ?? d.minAmount;
  // 上下限被写反时收敛为合法区间（min ≤ max），而不是让整个提现功能不可用
  const minAmount = Math.min(minRaw, maxAmount);
  const dailyLimit = toInt(src['dailyLimit'], WITHDRAW_DAILY_LIMIT_MIN, WITHDRAW_DAILY_LIMIT_MAX);
  const feeRate = toInt(src['feeRate'], WITHDRAW_FEE_RATE_MIN, WITHDRAW_FEE_RATE_MAX);
  const noticeText =
    typeof src['noticeText'] === 'string' ? src['noticeText'].trim().slice(0, WITHDRAW_NOTICE_MAX) : '';

  return {
    minAmount,
    maxAmount,
    dailyLimit: dailyLimit ?? d.dailyLimit,
    feeRate: feeRate ?? d.feeRate,
    noticeText,
  };
}

/**
 * 写入口校验（管理端 `PUT /admin/withdraw/config` 与通用 `PUT /admin/settings/:key` 共用）：
 * 任一项非法 → 中文 400。返回**规整后**的配置。
 */
export function assertWithdrawConfig(raw: unknown): WithdrawConfig {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new BadRequestException('配置格式非法：应为对象');
  }
  const src = raw as Record<string, unknown>;

  const minAmount = toInt(src['minAmount'], 1, WITHDRAW_YUAN_ABS_MAX);
  if (minAmount === null) {
    throw new BadRequestException(`单笔提现下限必须是 1–${WITHDRAW_YUAN_ABS_MAX} 的整数（元）`);
  }
  const maxAmount = toInt(src['maxAmount'], 1, WITHDRAW_YUAN_ABS_MAX);
  if (maxAmount === null) {
    throw new BadRequestException(`单笔提现上限必须是 1–${WITHDRAW_YUAN_ABS_MAX} 的整数（元）`);
  }
  if (minAmount > maxAmount) {
    throw new BadRequestException(`单笔提现下限（${minAmount} 元）不能大于上限（${maxAmount} 元）`);
  }
  const dailyLimit = toInt(src['dailyLimit'], WITHDRAW_DAILY_LIMIT_MIN, WITHDRAW_DAILY_LIMIT_MAX);
  if (dailyLimit === null) {
    throw new BadRequestException(
      `每日申请次数必须是 ${WITHDRAW_DAILY_LIMIT_MIN}–${WITHDRAW_DAILY_LIMIT_MAX} 的整数`,
    );
  }
  const feeRate = toInt(src['feeRate'], WITHDRAW_FEE_RATE_MIN, WITHDRAW_FEE_RATE_MAX);
  if (feeRate === null) {
    throw new BadRequestException(`手续费率必须是 ${WITHDRAW_FEE_RATE_MIN}–${WITHDRAW_FEE_RATE_MAX} 的整数（百分数）`);
  }
  if (typeof src['noticeText'] !== 'string') {
    throw new BadRequestException('说明文案必须是字符串（可留空）');
  }
  const noticeText = src['noticeText'].trim();
  if (noticeText.length > WITHDRAW_NOTICE_MAX) {
    throw new BadRequestException(`说明文案最多 ${WITHDRAW_NOTICE_MAX} 字`);
  }
  if (noticeText.includes('积分')) {
    // 计价单位铁律（2026-10-09）：全站金额一律 ¥/元，文案里也不许出现"积分"
    throw new BadRequestException('说明文案请使用「元」，不要出现「积分」');
  }

  return { minAmount, maxAmount, dailyLimit, feeRate, noticeText };
}

// ============================================================================
// 金额与时间工具（**唯一实现**：服务层与 e2e 断言同源）
// ============================================================================

/** 金额规整：四舍五入到 2 位小数（先放大 100 倍再取整，规避浮点边界） */
export function roundYuan(raw: number): number {
  return Math.round(Number(raw) * 100) / 100;
}

/** 金额展示：一律 `¥` + 两位小数（**不出现"积分"**） */
export function fmtYuan(raw: number): string {
  return `¥${roundYuan(raw).toFixed(2)}`;
}

/** 数据库 DATETIME 约定（TypeORM `timezone: 'Z'`）：**库里存的是 UTC 墙钟的裸值** */
function toDbTime(ms: number): string {
  return new Date(ms).toISOString().slice(0, 19).replace('T', ' ');
}

/** 北京时间（Asia/Shanghai，UTC+8）当天的 `[起, 止)` 区间，格式 = 库里 DATETIME 的裸值 */
export function shanghaiDayRange(now: Date = new Date()): { start: string; end: string } {
  // 先把"现在"换算成北京墙钟，取出北京日期，再反推该日 00:00+08 的 UTC 瞬间
  const shanghai = new Date(now.getTime() + 8 * 3600 * 1000);
  const y = shanghai.getUTCFullYear();
  const m = shanghai.getUTCMonth();
  const d = shanghai.getUTCDate();
  const startMs = Date.UTC(y, m, d) - 8 * 3600 * 1000;
  return { start: toDbTime(startMs), end: toDbTime(startMs + 24 * 3600 * 1000) };
}

// ============================================================================
// 个人信息脱敏（**唯一实现**；docs/09、docs/03「个人信息合规」）
//
// 口径（2026-10-11 负责人定案）：**列表与详情都给完整值**（`account`）—— 能读到的
// 只有 `withdraw:review` 持有者，读取者本身就是审核人；`accountMasked` 保留做兼容。
// 但**非审核面一律脱敏/不出完整号**：`operation_log.request_body` 摘要、
// `user_notification` 文案、任何日志与打手侧回显（`GET /worker/withdraw/account` 仍是脱敏）。
// ============================================================================

/** 姓名脱敏：保留姓氏，其余以 `*` 代替（"张三" → "张*"；空值原样返回空串） */
export function maskRealName(raw: string | null | undefined): string {
  const v = String(raw ?? '').trim();
  if (!v) return '';
  if (v.length === 1) return v;
  return v[0] + '*'.repeat(v.length - 1);
}

/** 手机号脱敏：保留前 3 后 4（不足 7 位则只留前 1 位） */
export function maskPhone(raw: string | null | undefined): string {
  const v = String(raw ?? '').trim();
  if (!v) return '';
  if (v.length < 7) return v.slice(0, 1) + '*'.repeat(Math.max(v.length - 1, 0));
  return `${v.slice(0, 3)}****${v.slice(-4)}`;
}

/** 微信号脱敏：保留前 2 后 2（短号只留前 1 位） */
export function maskWechatId(raw: string | null | undefined): string {
  const v = String(raw ?? '').trim();
  if (!v) return '';
  if (v.length <= 4) return v.slice(0, 1) + '*'.repeat(Math.max(v.length - 1, 0));
  return `${v.slice(0, 2)}****${v.slice(-2)}`;
}
