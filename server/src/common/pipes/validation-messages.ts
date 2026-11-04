import { BadRequestException, HttpStatus, ValidationError } from '@nestjs/common';

/**
 * 校验错误中文化（负责人 2026-10-04 报障）
 *
 * 问题：全局 ValidationPipe 直接把 class-validator 的**英文默认消息**透出，
 * 客户端只能原样弹给用户看，注册页底部出现
 * `username must be longer than or equal to 3 characters; password must be longer than or equal to 8 characters`。
 *
 * 方案（根治，全后端）：
 * 1. 字段名 → 中文标签（`FIELD_LABELS`），未收录的字段**回退成字段名本身**（绝不抛错）；
 * 2. 英文约束消息 → 中文规则映射（`translateConstraintMessage`）；
 * 3. 已带中文的自定义 message（DTO 里写了中文的）**原样保留**，不二次改写；
 * 4. 未识别的英文 → 兜底「「{标签}」填写有误」并打一条 warn（保留原文，便于后续补映射）；
 * 5. 结构化返回 `fields[]`，供客户端把错误落到**对应输入框下方**（而不是只弹一条浮层）。
 *
 * 注意：class-validator 的 `ValidationError.constraints` **不含约束实参**（N、枚举列表），
 * 所以 N 从消息文本反解；枚举列表从约束名 `isIn` 对应文本的 `values: a, b` 反解。
 * 反解失败一律走兜底文案，不会抛错。
 */

/** 字段名 → 中文标签 */
export const FIELD_LABELS: Readonly<Record<string, string>> = {
  // ---- 账号 / 认证 ----
  username: '账号',
  account: '账号',
  password: '密码',
  oldPassword: '原密码',
  newPassword: '新密码',
  confirmPassword: '确认密码',
  refreshToken: '登录凭证',
  token: '登录凭证',
  uid: '用户ID',
  userId: '用户ID',
  nickname: '昵称',
  displayName: '展示名称',
  realName: '真实姓名',
  phone: '手机号',
  contactPhone: '联系电话',
  code: '验证码',
  email: '邮箱',
  emailCode: '邮箱验证码',
  scene: '场景',
  role: '角色',
  roleCode: '角色标识',
  permissions: '权限点',

  // ---- 交易 / 金额 ----
  price: '价格',
  priceUnit: '价格单位',
  amount: '金额',
  maxAmount: '最高金额',
  minAmount: '最低金额',
  quantity: '数量',
  qty: '数量',
  walletId: '钱包',
  orderId: '订单',
  orderNo: '订单号',
  refundId: '退款单',
  idempotencyKey: '幂等键',

  // ---- 内容 / 文案 ----
  content: '内容',
  title: '标题',
  subtitle: '副标题',
  summary: '简介',
  description: '描述',
  detail: '详情',
  name: '名称',
  value: '取值',
  text: '文本',
  remark: '备注',
  reason: '原因',
  handlerRemark: '处理意见',
  keyword: '关键词',
  type: '类型',
  status: '状态',
  linkType: '跳转类型',
  linkValue: '跳转目标',

  // ---- 分页 / 排序 ----
  page: '页码',
  pageSize: '每页条数',
  sortOrder: '排序号',
  sort: '排序',

  // ---- 媒体 ----
  mediaId: '媒体',
  mediaType: '媒体类型',
  imageMediaId: '图片',
  imageUrl: '图片地址',
  avatarMediaId: '头像',
  avatarUrl: '头像地址',
  coverMediaId: '封面',
  videoMediaId: '视频',
  videoCoverMediaId: '视频封面',

  // ---- 目录 / 归属 ----
  id: '编号',
  ids: '商品',
  gameId: '游戏',
  categoryId: '分类',
  productId: '商品',
  divisionId: '分部',
  targetDivisionId: '目标分部',
  targetCategoryId: '目标分类',
  workerId: '打手',
  workerNo: '工号',
  designatedWorkerId: '指定打手',
  serviceFlow: '服务流程',
  serviceRules: '服务须知',

  // ---- 其它常见 ----
  configs: '配置项',
  extraJson: '附加信息',
  pinned: '置顶',
  visible: '可见性',
  rating: '评分',
};

/** 取字段中文标签；未收录 → 回退字段名本身（绝不抛错） */
export function labelForField(fieldKey: string): string {
  if (!fieldKey) return '参数';
  return FIELD_LABELS[fieldKey] ?? fieldKey;
}

/**
 * 字段路径 → 中文标签
 *
 * 支持 `a.b.c` / `items.0.mediaId` 这类嵌套路径：逐段解析，优先用
 * `parent.child`、`child` 组合查表，最后回退到叶子字段名。
 * 例：`items.0.mediaId` → `items.mediaId` → `mediaId` → 「媒体」
 */
export function labelForPath(path: string): string {
  const segs = String(path ?? '')
    .split('.')
    .filter((s) => s.length > 0 && !/^\d+$/.test(s));
  if (segs.length === 0) return '参数';
  for (let i = segs.length - 1; i >= 0; i--) {
    if (i > 0) {
      const pair = `${segs[i - 1]}.${segs[i]}`;
      if (FIELD_LABELS[pair]) return FIELD_LABELS[pair];
    }
    if (FIELD_LABELS[segs[i]]) return FIELD_LABELS[segs[i]];
  }
  return segs[segs.length - 1] || '参数';
}

/** 含中日韩汉字（或全角标点）→ 视为已经是中文文案，不要再机翻 */
function hasChinese(text: string): boolean {
  return /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3000-\u303f\uff01-\uff5e]/.test(text);
}

/** 去掉 class-validator 插值后的 `username ` 前缀，返回纯约束描述 */
function stripPropertyPrefix(text: string, fieldKey: string): string {
  let s = text.trim();
  for (const p of [fieldKey, '$property']) {
    if (p && s.toLowerCase().startsWith(p.toLowerCase() + ' ')) {
      s = s.slice(p.length + 1).trim();
    }
  }
  return s;
}

/** isIn 的约束文本形如 `role must be one of the following values: user, worker` */
function valuesFromIsInMessage(body: string): string[] {
  const fromText = /values\s*:\s*(.+)$/i.exec(body)?.[1];
  return fromText ? fromText.split(',').map((s) => s.trim()).filter(Boolean) : [];
}

/**
 * 英文约束描述 → 中文（按 class-validator 常见约束做规则映射）
 *
 * `must be longer than or equal to N **characters**` → 「至少 N 个字符」；
 * 不带 characters 的数值下限（@Min）→ 「不能小于 N」。
 */
export function translateConstraintMessage(rawMessage: string, fieldKey: string, label: string): string {
  const raw = String(rawMessage ?? '').trim();
  if (raw.length === 0) return `「${label}」填写有误`;
  // 整条已是中文（DTO 自定义的中文消息，如「用户名仅支持字母、数字、下划线」）→ 原样保留
  if (hasChinese(raw)) return raw;

  const body = stripPropertyPrefix(raw, fieldKey);
  // 去掉字段前缀后仍含中文 → 这是 DTO 自定义消息（全角/汉字正则、中文提示），原样保留：
  //   例：`uid must match /^[一-龥A-Za-z0-9_]{2,20}$/ regular expression`
  if (hasChinese(body)) return raw;

  // ---- 未知字段（forbidNonWhitelisted）----
  if (/^property\s+.+\s+should\s+not\s+exist$/i.test(body)) {
    const extra = /^property\s+(.+?)\s+should/i.exec(body)?.[1] ?? '';
    return `不支持字段 ${extra ? labelForField(extra) : label}`;
  }

  // ---- 枚举 ----
  if (/one of the following values|must be one of/i.test(body)) {
    const items = valuesFromIsInMessage(body);
    return items.length > 0 ? `只能是：${items.join('、')}` : `「${label}」取值不在允许范围内`;
  }

  // ---- 长度 ----
  // 下限 1 等价于「不能为空」；[1, N] 只报「最多 N 个字符」——
  // 避免出现「至少 1 个字符」「长度需为 1-32 个字符」这类废话（负责人要求文案是人话）
  const charsWord = /characters?/i.test(body);
  let min: number | undefined = Number(/longer than or equal to\s+(\d+)/i.exec(body)?.[1]);
  let max: number | undefined = Number(/shorter than or equal to\s+(\d+)/i.exec(body)?.[1]);
  if (!Number.isFinite(min)) min = undefined;
  if (!Number.isFinite(max)) max = undefined;
  if (min === 1 || min === 0) min = undefined;
  if (charsWord || min !== undefined || max !== undefined) {
    if (min !== undefined && max !== undefined) return `长度需为 ${min}-${max} 个字符`;
    if (min !== undefined) return charsWord ? `至少 ${min} 个字符` : `至少 ${min}`;
    if (max !== undefined) return charsWord ? `最多 ${max} 个字符` : `最多 ${max}`;
    return '不能为空';
  }

  // ---- 空值 ----
  if (/should not be empty|must not be empty|not be empty/i.test(body)) return '不能为空';

  // ---- 格式 ----
  if (/must be an email/i.test(body)) return '邮箱格式不正确';
  if (/must be a (mobile )?phone number/i.test(body)) return '手机号格式不正确';
  if (/must be a url/i.test(body)) return '网址格式不正确';
  if (/must be a uuid/i.test(body)) return '编号格式不正确';
  if (/must be a date/i.test(body)) return '日期格式不正确';
  if (/regular expression|must match/i.test(body)) return '格式不正确';
  if (
    /must be a boolean|must be a string|must be an array|must be an object|must be a nested value|must be an array of|must be an instance of/i.test(
      body,
    )
  ) {
    return '格式不正确';
  }

  // ---- 数值 ----
  if (/must be an integer/i.test(body)) return '必须是整数';
  if (/must be a positive number/i.test(body)) return '必须是正数';
  if (/must be a negative number/i.test(body)) return '必须是负数';
  if (/must be a number|number conforming|must be a numeric|must be a decimal/i.test(body)) return '必须是数字';

  // ---- 上下限（@Min / @Max 等）----
  const minHit = /not be less than\s+(-?\d+)/i.exec(body);
  if (minHit) return `不能小于 ${minHit[1]}`;
  const maxHit = /not be greater than\s+(-?\d+)/i.exec(body);
  if (maxHit) return `不能大于 ${maxHit[1]}`;

  // ---- 其它格式类 ----
  if (/must be an ip|must be a port|must be a mongo id|must be a json|must be a number string/i.test(body)) {
    return '格式不正确';
  }

  // ---- 兜底：未识别英文 → 统一文案（原文由调用方打 warn 保留）----
  return `「${label}」填写有误`;
}

export interface ValidationFieldError {
  /** 原始字段路径（客户端据此定位输入框，保持英文原样） */
  field: string;
  /** 字段中文标签（未收录 → 字段名本身） */
  label: string;
  /** 中文错误文案（不含英文） */
  message: string;
}

export interface ValidationResult {
  message: string;
  fields: ValidationFieldError[];
  /** 请求体里多带的、DTO 未声明的字段名（forbidNonWhitelisted） */
  unknownFields: string[];
}

/** 单个字段（含嵌套 children）→ 一条中文错误 */
function fieldErrorOf(e: ValidationError, path: string): ValidationFieldError | null {
  const label = labelForPath(path) || labelForField(e.property);
  const constraints = e.constraints ?? {};
  const parts: string[] = [];
  for (const key of Object.keys(constraints)) {
    const text = translateConstraintMessage(constraints[key], e.property, label);
    if (text && !parts.includes(text)) parts.push(text);
  }
  if (parts.length === 0) return null;
  return { field: path, label, message: parts.slice(0, 3).join('；') };
}

/** ValidationError[] → 中文字段错误清单（展开嵌套 children） */
export function collectFieldErrors(errors: readonly ValidationError[]): ValidationFieldError[] {
  const out: ValidationFieldError[] = [];
  const walk = (errs: readonly ValidationError[], prefix: string) => {
    for (const e of errs ?? []) {
      const path = prefix ? `${prefix}.${e.property}` : e.property;
      const item = fieldErrorOf(e, path);
      if (item) out.push(item);
      if (e.children && e.children.length > 0) walk(e.children, path);
    }
  };
  walk(errors ?? [], '');
  return out;
}

/** ValidationError[] → 中文结果（message 汇总 + fields 明细） */
export function toChineseValidationResult(errors: readonly ValidationError[]): ValidationResult {
  const unknownFields: string[] = [];
  const known: ValidationError[] = [];
  for (const e of errors ?? []) {
    const keys = Object.keys(e.constraints ?? {});
    if (keys.length === 1 && keys[0] === 'whitelistValidation') {
      unknownFields.push(e.property);
      continue;
    }
    known.push(e);
  }

  const fields = collectFieldErrors(known);
  // 未知字段也放进 fields（客户端能定位到输入框的走行内提示，定位不到的走浮层兜底）。
  // 这类消息本身已说明字段，汇总时不加「{标签}」前缀（否则会拼成「hacker不支持字段 hacker」）。
  const extraLabels = new Map<string, string>();
  for (const p of unknownFields) {
    if (!fields.some((f) => f.field === p)) {
      fields.push({ field: p, label: p, message: `不支持字段 ${labelForField(p)}` });
      extraLabels.set(p, '');
    }
  }

  const message =
    fields.length > 0 ? fields.map((f) => `${extraLabels.get(f.field) ?? f.label}${f.message}`).join('；') : '请求参数有误';
  return { message, fields, unknownFields };
}

/** 仅需要 warn 能力时传入（避免直接依赖 Nest Logger 类型） */
export interface ValidationLogger {
  warn(message: string): void;
}

/** 未识别的英文消息 → 打 warn（保留原文，便于后续补映射） */
export function warnUnmappedEnglish(errors: readonly ValidationError[], logger: ValidationLogger): void {
  const seen = new Set<string>();
  const walk = (errs: readonly ValidationError[]) => {
    for (const e of errs ?? []) {
      for (const key of Object.keys(e.constraints ?? {})) {
        const raw = e.constraints?.[key];
        if (typeof raw !== 'string' || raw.length === 0) continue;
        const label = labelForPath(e.property) || labelForField(e.property);
        const translated = translateConstraintMessage(raw, e.property, label);
        if (translated === `「${label}」填写有误` && !seen.has(raw)) {
          seen.add(raw);
          logger.warn(`校验消息未收录英文规则，已用兜底中文：${raw}`);
        }
      }
      if (e.children && e.children.length > 0) walk(e.children);
    }
  };
  walk(errors);
}

/** 结构化 400：`fields[]` 供客户端定位输入框（向后兼容 message） */
export function buildValidationException(errors: readonly ValidationError[], logger?: ValidationLogger): BadRequestException {
  const { message, fields } = toChineseValidationResult(errors);
  if (logger) warnUnmappedEnglish(errors ?? [], logger);
  return new BadRequestException({
    code: HttpStatus.BAD_REQUEST,
    message,
    data: null,
    errorCode: 'VALIDATION_FAILED',
    fields,
  });
}

/** 兜底：任意「纯英文」的 HTTP 错误消息 → 中文（不把英文/ SQL / 堆栈吐给客户端） */
export function toChineseFallbackMessage(rawMessage: string, status: number): string {
  const raw = String(rawMessage ?? '').trim();
  if (raw.length > 0 && hasChinese(raw)) return raw;

  const lowered = raw.toLowerCase();
  if (lowered.includes('json')) return '请求数据格式不正确';
  if (lowered.includes('payload too large') || lowered.includes('entity too large')) return '请求内容过大，请分批提交';
  if (lowered.includes('unsupported media type')) return '不支持的内容类型';
  if (lowered.includes('validation failed')) return '请求参数有误';

  if (status === HttpStatus.BAD_REQUEST) return '请求参数有误';
  if (status === HttpStatus.UNAUTHORIZED) return '登录已失效，请重新登录';
  if (status === HttpStatus.FORBIDDEN) return '无权限访问';
  if (status === HttpStatus.NOT_FOUND) return '请求的资源不存在';
  if (status === HttpStatus.CONFLICT) return '数据冲突，请刷新后重试';
  if (status === HttpStatus.TOO_MANY_REQUESTS) return '操作过于频繁，请稍后再试';
  if (status >= 500) return '服务器内部错误';
  return '请求失败，请稍后重试';
}

/** 需要中文化判定的对外工具（异常过滤器用） */
export function isChineseMessage(text: string): boolean {
  return hasChinese(String(text ?? ''));
}

/**
 * 状态/动作枚举值 → 中文（面向管理端的提示里不再出现 `handled` / `approve` 这类英文标识）
 * 未收录 → 回退原值（不抛错）
 */
const ENUM_LABELS: Readonly<Record<string, string>> = {
  // 投诉/申诉/退款工单
  pending: '待处理',
  processing: '处理中',
  handled: '已处理',
  rejected: '已驳回',
  approved: '已通过',
  approve: '通过',
  reject: '驳回',
  refund: '退款',
  // 订单
  pending_take: '待接单',
  pending_dispatch: '待确认派单',
  taken: '已接单',
  in_progress: '进行中',
  pending_confirm: '待确认',
  completed: '已完成',
  cancelled: '已取消',
  abnormal: '异常',
  // 角色
  user: '老板端用户',
  worker: '工作端用户',
  admin: '管理员',
};

/** 枚举值 → 中文（未收录回退原值） */
export function enumLabel(value: string): string {
  const key = String(value ?? '').trim();
  return ENUM_LABELS[key] ?? key;
}

/** 一组枚举值 → 中文顿号串（用于「只能是：…」这类提示） */
export function enumListLabel(values: readonly string[]): string {
  return values.map((v) => enumLabel(v)).join('、');
}

/** 上传类型标识 → 中文用途（面向用户的提示里不出现 avatar/forum_image 这类内部标识） */
const MEDIA_TYPE_LABELS: Readonly<Record<string, string>> = {
  avatar: '头像',
  bg: '个人背景',
  product: '商品图',
  game_icon: '游戏图标',
  forum_image: '动态图片',
  forum_video: '动态视频',
  chat_image: '聊天图片',
  chat_video: '聊天视频',
  complaint_image: '投诉截图',
  app_package: 'App 安装包',
  banner: '首页横幅',
};

/** 上传类型 → 中文 */
export function mediaTypeLabel(value: string): string {
  const key = String(value ?? '').trim();
  return MEDIA_TYPE_LABELS[key] ?? key;
}
