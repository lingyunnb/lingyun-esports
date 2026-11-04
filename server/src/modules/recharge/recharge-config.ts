import { BadRequestException } from '@nestjs/common';

/**
 * 充值（线下收款 + 人工审核）——**全平台唯一真相**的配置契约。
 *
 * ## 合规红线（写代码前先读，CLAUDE.md 结构规则 12）
 *
 * 本功能**不接任何支付通道**：没有支付 SDK、没有支付回调、没有支付单号、没有"支付成功"字样。
 * 收款码是**图片**，App 只负责展示；老板在**平台外**（微信/支付宝）自行付款，
 * 回来上传**转账截图**，由管理员**人工核对**后手工发放余额。**平台不经手资金**。
 * 因此这里的所有配置项都只描述"展示什么、换算多少、放几个人审"，不含任何交易/通道语义。
 *
 * ## 为什么配置落 `system_setting` 而不是单开 `recharge_config` 表
 *
 * 负责人原话给了两个选项（"`recharge_config`（或用 `system_setting`，你判断哪个更合适并说明）"），
 * 本实现选 **`system_setting.recharge_config`**，理由是**只有它才能真正"复用 is_high_security 机制"**：
 * - "仅超管可写"这套机制**本身就是 `system_setting` 行的属性**（`is_high_security=1` +
 *   `SystemSettingService.update()` 的 `actorRoleCode !== 'super_admin'` 判定）。
 *   单开一张表就得把这条规则**再实现一遍**（另写一个"查角色码 → 比 super_admin"的分支）——
 *   与 `docs/04` 反复强调的"同一规则只有一份实现"直接冲突，也是安全审计 F1 的同一类根因。
 * - 单行 JSON 的读写与既有 `platform_commission_rate` / `purchase_points_hint` /
 *   `worker_binding_max_per_boss` **完全同一套**：管理端「系统设置」页无需新增页面就能看到并编辑，
 *   写入口唯一（`SystemSettingService.update` → `validate` 按 key 校验）。
 * - 读侧成本等价：`setting_key` 唯一索引 → 主键级单行读（实测约 2ms），且**不缓存**（每次实时读库）。
 * - 代价（已知并接受）：`cfg_value` 是 JSON，DB 层不能给单个字段加类型约束 ——
 *   由本文件的 `parseRechargeConfig` / `assertRechargeConfig` 在**唯一写入口**与**读侧兜底**两处把关
 *   （与 `parseWorkerBindingMax` / `parseCommissionRate` 同口径）。
 *
 * 表结构部分（`recharge_qr_code` / `recharge_request` / `recharge_admin`）仍按负责人给定口径建**真表**
 * ——它们是业务数据（要分页、要唯一约束、要行锁、要审计），不是配置。
 */

/** 配置在 `system_setting` 里的 key */
export const RECHARGE_CONFIG_KEY = 'recharge_config';

/** 该配置项的 description（写进 system_setting，管理端「全部配置项」表格直接显示） */
export const RECHARGE_CONFIG_DESCRIPTION =
  '充值配置（金额档位/1 元到账余额比例/自定义上下限/每人待审核上限/受限管理员上限/说明文案；仅超管可改）';

/** 默认金额档位（负责人定案原文） */
export const RECHARGE_AMOUNT_OPTIONS_DEFAULT: number[] = [6, 10, 20, 38, 68, 98, 128, 198, 328, 648];
/** 金额档位条数上限（防误粘贴把配置撑爆；10 档是负责人给的原样，留一倍余量） */
export const RECHARGE_AMOUNT_OPTIONS_MAX = 20;
/** 单笔自定义金额允许的最大值（元）——上限本身可配，这是防"配出天文数字"的绝对天花板 */
export const RECHARGE_YUAN_ABS_MAX = 1_000_000;
/** 1 元到账余额的比例允许范围（默认 1，即 1 元 = 1 元） */
export const RECHARGE_POINTS_PER_YUAN_MIN = 1;
export const RECHARGE_POINTS_PER_YUAN_MAX = 1000;
/** 每个老板"待审核"申请数上限的允许范围（默认 3） */
export const RECHARGE_PENDING_LIMIT_MIN = 1;
export const RECHARGE_PENDING_LIMIT_MAX = 20;
/**
 * 受限充值管理员**硬上限：5 个账号**（负责人定案：最多 5 个账号）。
 *
 * 为什么是常量而不是纯配置：负责人明确"最多 5 个账号"，`admin_limit` 只是**在同一上限内收紧**
 * （1–5），即便有人把配置写成 10，服务端仍按 5 拒绝 —— 硬上限不依赖配置正确性。
 * 并发安全不靠这个数字，靠"配置行行锁 + `recharge_admin.user_id` 唯一键"（见 recharge.service.ts）。
 */
export const RECHARGE_ADMIN_LIMIT_MAX = 5;
export const RECHARGE_ADMIN_LIMIT_DEFAULT = 5;
/** 说明文案长度上限 */
export const RECHARGE_NOTICE_MAX = 500;

/**
 * 说明文案默认值（给老板看）。
 *
 * 用词刻意规避一切"在线支付"暗示：只出现"平台外付款""上传截图""人工核对""平台不经手资金"，
 * 不出现"支付成功/到账/订单号"等会被误读为平台收款能力的字眼。
 */
export const RECHARGE_NOTICE_DEFAULT =
  '本平台不提供在线支付。请扫描下方收款码，在微信或支付宝自行付款；付款后上传转账截图，管理员人工核对后按付款金额 1:1 到账余额。余额仅可用于平台内消费，不可提现、不可转让。平台不经手资金，请勿向任何人索要或提供账号密码。';

/** 充值配置本体（`cfg_value.value` 的形状） */
export interface RechargeConfig {
  /** 金额档位（元，升序去重） */
  amountOptions: number[];
  /** 是否允许自定义金额 */
  customEnabled: boolean;
  /** 自定义金额下限（元，整数） */
  minYuan: number;
  /** 自定义金额上限（元，整数） */
  maxYuan: number;
  /** 1 元到账多少余额（默认 1 = 1:1；整数比例，换算结果保留 2 位小数） */
  pointsPerYuan: number;
  /** 每个老板最多同时存在几条待审核申请 */
  pendingLimitPerUser: number;
  /** 受限充值管理员账号数上限（1–5，硬上限 5） */
  adminLimit: number;
  /** 给老板看的说明文案 */
  noticeText: string;
}

/** 配置默认值（= 负责人定案原文；迁移把这份写进库里，读侧只在整行缺失/损坏时兜底） */
export const RECHARGE_CONFIG_DEFAULT: RechargeConfig = {
  amountOptions: [...RECHARGE_AMOUNT_OPTIONS_DEFAULT],
  customEnabled: true,
  minYuan: 1,
  maxYuan: 10000,
  pointsPerYuan: 1,
  pendingLimitPerUser: 3,
  adminLimit: RECHARGE_ADMIN_LIMIT_DEFAULT,
  noticeText: RECHARGE_NOTICE_DEFAULT,
};

/** 原始值的人读描述（错误提示里带上，便于运营自查；与 worker-binding-limit 同口径） */
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
 * 为什么读侧不抛异常：`GET /public/recharge/config` 是老板端"充值"页首屏依赖，
 * 一行配置被写坏就让整页 500 = 把运营的手误放大成线上故障。写侧（`assertRechargeConfig`）
 * 才是硬闸门（非法 = 中文 400）；读侧按字段回退，坏掉的那一项用默认值继续服务。
 */
export function parseRechargeConfig(raw: unknown): RechargeConfig {
  const src = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const d = RECHARGE_CONFIG_DEFAULT;

  let amountOptions = d.amountOptions;
  if (Array.isArray(src['amountOptions'])) {
    const cleaned = src['amountOptions']
      .map((v) => toInt(v, 1, RECHARGE_YUAN_ABS_MAX))
      .filter((v): v is number => v !== null);
    if (cleaned.length > 0) amountOptions = [...new Set(cleaned)].sort((a, b) => a - b);
  }

  const maxYuan = toInt(src['maxYuan'], 1, RECHARGE_YUAN_ABS_MAX) ?? d.maxYuan;
  const minRaw = toInt(src['minYuan'], 1, RECHARGE_YUAN_ABS_MAX) ?? d.minYuan;
  // 上下限被写反时收敛为合法区间，而不是让自定义金额功能整块失效
  const minYuan = Math.min(minRaw, maxYuan);

  const pending = toInt(src['pendingLimitPerUser'], RECHARGE_PENDING_LIMIT_MIN, RECHARGE_PENDING_LIMIT_MAX);
  const adminLimit = toInt(src['adminLimit'], 1, RECHARGE_ADMIN_LIMIT_MAX);
  const pointsPerYuan = toInt(src['pointsPerYuan'], RECHARGE_POINTS_PER_YUAN_MIN, RECHARGE_POINTS_PER_YUAN_MAX);

  const noticeRaw = typeof src['noticeText'] === 'string' ? src['noticeText'].trim().slice(0, RECHARGE_NOTICE_MAX) : '';

  return {
    // 档位里超过上限的值一并剔除（上限被调小后，旧档位不该成为绕过校验的通道）
    amountOptions: amountOptions.filter((v) => v <= maxYuan),
    customEnabled: typeof src['customEnabled'] === 'boolean' ? src['customEnabled'] : d.customEnabled,
    minYuan,
    maxYuan,
    pointsPerYuan: pointsPerYuan ?? d.pointsPerYuan,
    pendingLimitPerUser: pending ?? d.pendingLimitPerUser,
    adminLimit: adminLimit ?? d.adminLimit,
    noticeText: noticeRaw,
  };
}

/**
 * 写入口校验（管理端 `PUT /admin/recharge/config` 与通用 `PUT /admin/settings/:key` 共用）：
 * 任一项非法 → 中文 400。返回**规整后**的配置（字符串数字变整数、档位升序去重）。
 */
export function assertRechargeConfig(raw: unknown): RechargeConfig {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new BadRequestException('配置格式非法：应为对象');
  }
  const src = raw as Record<string, unknown>;

  // ① 金额档位
  if (!Array.isArray(src['amountOptions'])) {
    throw new BadRequestException('金额档位必须是数组，例如 [6,10,20]');
  }
  if (src['amountOptions'].length === 0) {
    throw new BadRequestException('金额档位至少保留 1 个');
  }
  if (src['amountOptions'].length > RECHARGE_AMOUNT_OPTIONS_MAX) {
    throw new BadRequestException(`金额档位最多 ${RECHARGE_AMOUNT_OPTIONS_MAX} 个`);
  }
  const options: number[] = [];
  for (const v of src['amountOptions']) {
    const n = toInt(v, 1, RECHARGE_YUAN_ABS_MAX);
    if (n === null) {
      throw new BadRequestException(`金额档位必须是 1–${RECHARGE_YUAN_ABS_MAX} 的整数（元），当前值非法：${describeRaw(v)}`);
    }
    options.push(n);
  }
  const amountOptions = [...new Set(options)].sort((a, b) => a - b);

  // ② 自定义开关
  if (typeof src['customEnabled'] !== 'boolean') {
    throw new BadRequestException('自定义金额开关必须是布尔值');
  }
  // ③ 上下限
  const minYuan = toInt(src['minYuan'], 1, RECHARGE_YUAN_ABS_MAX);
  if (minYuan === null) {
    throw new BadRequestException(`自定义金额下限必须是 1–${RECHARGE_YUAN_ABS_MAX} 的整数（元）`);
  }
  const maxYuan = toInt(src['maxYuan'], 1, RECHARGE_YUAN_ABS_MAX);
  if (maxYuan === null) {
    throw new BadRequestException(`自定义金额上限必须是 1–${RECHARGE_YUAN_ABS_MAX} 的整数（元）`);
  }
  if (minYuan > maxYuan) {
    throw new BadRequestException(`自定义金额下限（${minYuan} 元）不能大于上限（${maxYuan} 元）`);
  }
  // 档位必须落在 [minYuan, maxYuan] 内：否则会出现"档位可选、提交却因区间校验被拒"的自相矛盾配置
  for (const v of amountOptions) {
    if (v < minYuan || v > maxYuan) {
      throw new BadRequestException(`金额档位 ${v} 元超出自定义区间（${minYuan}–${maxYuan} 元），请先调整上下限`);
    }
  }
  // ④ 到账比例
  const pointsPerYuan = toInt(src['pointsPerYuan'], RECHARGE_POINTS_PER_YUAN_MIN, RECHARGE_POINTS_PER_YUAN_MAX);
  if (pointsPerYuan === null) {
    throw new BadRequestException(
      `1 元到账比例必须是 ${RECHARGE_POINTS_PER_YUAN_MIN}–${RECHARGE_POINTS_PER_YUAN_MAX} 的整数`,
    );
  }
  // ⑤ 每人待审核上限
  const pendingLimitPerUser = toInt(src['pendingLimitPerUser'], RECHARGE_PENDING_LIMIT_MIN, RECHARGE_PENDING_LIMIT_MAX);
  if (pendingLimitPerUser === null) {
    throw new BadRequestException(
      `每人待审核上限必须是 ${RECHARGE_PENDING_LIMIT_MIN}–${RECHARGE_PENDING_LIMIT_MAX} 的整数`,
    );
  }
  // ⑥ 受限管理员上限（硬上限 5，配置只能在 1–5 内收紧）
  const adminLimit = toInt(src['adminLimit'], 1, RECHARGE_ADMIN_LIMIT_MAX);
  if (adminLimit === null) {
    throw new BadRequestException(`受限管理员上限必须是 1–${RECHARGE_ADMIN_LIMIT_MAX} 的整数（最多 5 个账号）`);
  }
  // ⑦ 说明文案（允许留空 = 客户端不显示这段说明）
  if (typeof src['noticeText'] !== 'string') {
    throw new BadRequestException('说明文案必须是字符串（可留空）');
  }
  const noticeText = src['noticeText'].trim();
  if (noticeText.length > RECHARGE_NOTICE_MAX) {
    throw new BadRequestException(`说明文案最多 ${RECHARGE_NOTICE_MAX} 字`);
  }

  return {
    amountOptions,
    customEnabled: src['customEnabled'],
    minYuan,
    maxYuan,
    pointsPerYuan,
    pendingLimitPerUser,
    adminLimit,
    noticeText,
  };
}

/**
 * 受限充值管理员会话 TTL：**与 companion 一致 12 小时**（负责人定案）。
 *
 * 为什么和打手态同一档而不是 primary 的 2h/30d：
 * 这是"受限会话"的共同语义 —— 权限被白名单收窄到一族接口，因此寿命必须短、且**到点必须重新输账密**。
 * access 与 refresh 同 TTL（12h 是硬上限，不会被续成 30 天）。
 */
export const RECHARGE_ACCESS_TTL_SECONDS = 12 * 60 * 60;
export const RECHARGE_REFRESH_TTL_SECONDS = 12 * 60 * 60;

/** 绑定受限管理员态接口的限流：与 `/auth/login`、`/user/identity/bind` 同一策略（5 次/分/IP+账号） */
export const RECHARGE_BIND_RATE_LIMIT = 5;
export const RECHARGE_BIND_RATE_WINDOW_SECONDS = 60;
