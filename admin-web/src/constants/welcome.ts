/**
 * 欢迎序列文案 —— **唯一常量文件**（负责人 2026-10-11 审批）
 * ============================================================================
 * 页面里**不许内联任何一句欢迎文案**：以后改字只改这一处。
 * 逐字照用，不要改字、不要改标点（含中文顿号与逗号）。
 *
 * 角色区分：`is_owner=1`（董事长/所有者）→ 两行；其他角色（运营/客服/充值管理员）→ 只显示一行。
 */

/** 所有者（is_owner=1）看到的两行 */
export const WELCOME_OWNER_LINES = ['山高人为峰，客至心自明', '欢迎回来，董事长'] as const;

/** 其他管理角色看到的一行 */
export const WELCOME_OTHER_LINES = ['欢迎回来'] as const;

/**
 * 按角色取欢迎文案行。
 * @param isOwner `/auth/me` 返回的 `admin.isOwner === true`（与后端 is_owner 同源）
 */
export function welcomeLines(isOwner: boolean): readonly string[] {
  return isOwner ? WELCOME_OWNER_LINES : WELCOME_OTHER_LINES;
}

/**
 * 全屏欢迎序列节奏（毫秒），与负责人给的规格逐值对应，改节奏也只改这里。
 *
 * 总时长（不可跳过时）= fadeIn 250 + hold 700 + fadeIn 250 + hold 900 + fadeOut 300 = **2400ms**
 * → 落在负责人要求的「约 2.4–2.8s」区间内。
 */
export const WELCOME_TIMING = {
  /** 第 1 行淡入 */
  line1FadeIn: 250,
  /** 第 1 行停留 */
  hold1: 700,
  /** 第 2 行淡入 */
  line2FadeIn: 250,
  /** 第 2 行停留 */
  hold2: 900,
  /** 整屏淡出 */
  fadeOut: 300,
} as const;

/** 不可跳过时的总时长（ms），供验收脚本断言节奏用 */
export const WELCOME_TOTAL_MS =
  WELCOME_TIMING.line1FadeIn +
  WELCOME_TIMING.hold1 +
  WELCOME_TIMING.line2FadeIn +
  WELCOME_TIMING.hold2 +
  WELCOME_TIMING.fadeOut;
