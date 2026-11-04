/**
 * 打手简介（陪玩介绍）校验规则 —— **纯函数，唯一实现**
 *
 * ============================ 背景（负责人 2026-10-17 改定）============================
 * 结构规则 6 原定「找陪玩列表 = 头像 + 名字 + 介绍，**介绍由管理端填写**」。
 * 2026-10-17 负责人改定：**介绍让打手自己写**，管理端仍可改（兜底）。
 * 因此写入 `user.intro` 现在有**两个入口**：
 * - 打手自写：`PUT /worker/profile`（本文件的规则把关，主体只从 JWT `sub` 取）
 * - 管理端兜底：`PUT /admin/workers/:id/players-profile`（既有能力，行为未变；不受本文件限制，
 *   管理端仍可写 0–200 字 —— 这与"负责人随时能替打手改"的兜底语义一致）
 *
 * 为什么规则单独一个文件：它是**安全边界**（唯一自由文本口子），必须能被单测直接调用，
 * 且只能有一份 —— 复制到控制器/客户端各写一遍是安全审计 F1 的同一类根因（同一规则两份必然分叉）。
 *
 * ============================ 为什么必须拦联系方式 ============================
 * 负责人明确要求「请勿私加打手」。简介是打手**唯一**的自由文本出口，也是唯一能绕过平台撮合、
 * 把交易导到平台外的地方（绕开平台抽成 + 平台对交易争议完全失去裁决依据）。
 * 而平台**不接任何支付通道**（结构规则 12 合规红线），线下私聊成交 = 平台零证据。
 * 所以这里对手机号 / 微信号 / QQ 号一律**拒写**，而不是存下来再审核。
 *
 * 拦截口径（宁可严格，因为简介只有 120 字，正常文案不会出现长数字串或"微信/QQ"字样）：
 * - 手机号：11 位 `1[3-9]…`（先去掉空格/`-`/`.`/`·` 等分隔再判，防 `138 0013 8000` 这类拆写）；
 * - 微信号：关键词 `微信 / 薇信 / 威信 / weixin / wechat / vx / wx / 加v`；
 * - QQ 号：关键词 `qq / 扣扣 / 企鹅`，以及**任何 5–11 位连续数字**（纯数字串正是 QQ 号的形态；
 *   真实简介不会出现这么长的纯数字，代价可接受）；
 * - 全部命中都回同一句中文：「简介里不能留联系方式」——**刻意不解释命中了哪条规则**，
 *   否则等于把过滤规则告诉对方去逐条试探（与 docs/09 账号枚举文案同一条思路）。
 */
export const INTRO_MIN_LENGTH = 2;
export const INTRO_MAX_LENGTH = 120;
/** 最多允许 1 个换行（简介是单段短句；找陪玩卡片固定行高，多个换行会撑出空白） */
export const INTRO_MAX_NEWLINES = 1;

/** 命中联系方式时的统一中文文案（不暴露具体命中规则） */
export const INTRO_CONTACT_FORBIDDEN = '简介里不能留联系方式';

export type IntroCheck = { ok: true; intro: string } | { ok: false; message: string };

/**
 * 不可见 / 控制字符：除 `\n`（U+000A）之外的 C0、全部 C1、零宽字符、行分隔符、双向控制符、BOM。
 * 它们肉眼不可见，却能让简介在列表里"看起来是空的"或把两行挤在一起，一律拒写。
 */
const INVISIBLE_CHARS = /[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u202a-\u202e\ufeff]/;

/** 联系方式判定用的"紧凑串"：去掉常见分隔符，防 `138-0013-8000` / `1 3 8 …` 这类拆写绕过 */
const SEPARATORS = /[\s\-_.·—–|,，、/\\]/g;

const PHONE_RE = /1[3-9]\d{9}/;
/** 微信号关键词（`wx`/`vx` 大小写不敏感；`加v` 是中文语境里最常见的写法） */
const WECHAT_RE = /微信|薇信|威信|weixin|wechat|vx|wx|加\s*v/i;
/** QQ 关键词 */
const QQ_KEYWORD_RE = /qq|扣扣|企鹅/i;
/** 裸数字串：5–11 位连续数字（QQ 号形态） */
const BARE_DIGITS_RE = /(^|\D)\d{5,11}(\D|$)/;

/** 长度为「字符数」而不是 UTF-16 码元数（emoji / 生僻字按 1 个字算，避免把 60 个 emoji 判成 120 字） */
export function introLength(text: string): number {
  return Array.from(text).length;
}

/**
 * 校验并归一化打手提交的简介。
 *
 * 顺序：类型 → 换行归一 → 首尾空白 → 不可见字符 → 长度 → 内容（联系方式）。
 * **校验顺序本身也是口径**：先结构后内容，保证「121 字且带手机号」这种输入报的是长度错，
 * 客户端能就近把提示落到输入框上（长度问题用户自己能改）。
 */
export function checkWorkerIntro(raw: unknown): IntroCheck {
  if (typeof raw !== 'string') {
    return { ok: false, message: '简介格式不正确' };
  }
  // `\r\n` 归一为 `\n`（部分安卓输入法/粘贴会带 CRLF），归一后仍残留的 `\r` 交给下面的不可见字符判定
  const intro = raw.replace(/\r\n/g, '\n');

  if (intro.trim() !== intro) {
    return { ok: false, message: '简介首尾不能有空格或换行' };
  }
  if (INVISIBLE_CHARS.test(intro)) {
    return { ok: false, message: '简介里不能有不可见字符' };
  }
  const newlines = (intro.match(/\n/g) ?? []).length;
  if (newlines > INTRO_MAX_NEWLINES) {
    return { ok: false, message: `简介最多只能有 ${INTRO_MAX_NEWLINES} 个换行` };
  }
  const len = introLength(intro);
  if (len < INTRO_MIN_LENGTH) {
    return { ok: false, message: `简介至少 ${INTRO_MIN_LENGTH} 个字` };
  }
  if (len > INTRO_MAX_LENGTH) {
    return { ok: false, message: `简介最多 ${INTRO_MAX_LENGTH} 个字` };
  }
  if (looksLikeContact(intro)) {
    return { ok: false, message: INTRO_CONTACT_FORBIDDEN };
  }
  return { ok: true, intro };
}

/** 是否像联系方式（导出便于单测逐条打靶，也便于管理端将来复用同一条口径） */
export function looksLikeContact(intro: string): boolean {
  const compact = intro.replace(SEPARATORS, '');
  if (PHONE_RE.test(compact)) return true;
  if (WECHAT_RE.test(intro)) return true;
  if (QQ_KEYWORD_RE.test(intro)) return true;
  if (BARE_DIGITS_RE.test(compact)) return true;
  return false;
}
