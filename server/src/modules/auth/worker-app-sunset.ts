import { BadRequestException } from '@nestjs/common';
import { firstRow, type SqlRunner } from './companion-session.check';

/**
 * ============================ 工作端到期收口（服务端唯一实现）============================
 *
 * 背景（负责人 2026-10-06 定案「彻底废除工作端」）：
 * 工作端 App **只在客户端**按日期自动阻断（`apps/worker-app/lib/widgets/worker_sunset.dart`，
 * 判定取「本地时间 / 服务端 Date 头」中较晚者）。这留下一处**改手机时间 + 离线**即可绕过的缺口
 * （见 `开发日志/2026-10-06.md` 第 7 节「已知绕过点」）。本轮把口子**收到服务端**：
 * 到期后由服务端拒绝「工作端 App」的全部使用，客户端一行不改。
 *
 * ## 收口口径（逐条对应负责人定案，**不放宽**）
 *
 * 1. **到期时间**：`system_setting.worker_app_sunset_at`，**默认 `2026-10-13 00:00:00`（Asia/Shanghai）**；
 *    `is_high_security = 1` → **仅超管可改**（复用既有最高安全档机制，`SystemSettingService.update` 判定）；
 *    读侧**每次实时读库、无缓存**（改完下一次请求即生效，没有"改了不生效"的窗口）。
 * 2. **到期后拒绝**：`role=worker` 的 **primary** 会话 ——
 *    ① `POST /auth/login`（`role=worker`）→ 403 中文；
 *    ② 已登录的 worker primary 令牌打**任何**受保护接口（`/worker/*`、`/user/*`、其余）→ 401 中文；
 *    ③ WS（Socket.IO `/ws/chat`）worker primary 连接 → 握手直接断开、心跳重校验后踢线。
 * 3. **绝对不能影响**（本次最重要的一条不变量）：
 *    - **老板端「打手态」的 companion 会话**（`auth_token.kind='companion'`）—— 那正是工作端的替代品，
 *      **必须照常可用**（`/worker/*` 照常 200）。companion 的 `role` 也是 `worker`，
 *      因此判定**必须先看 kind**：只有 `kind='primary'` 才可能被拦。
 *    - 老板端（`role=user`）、管理端（`role=admin`）、受限充值会话（`kind='recharge'`）一律不受影响。
 * 4. **判定只有一份**：本文件（读配置 + 判断）。三处调用方共用：
 *    - `AuthService.login`（登录 403）
 *    - `JwtAuthGuard`（每请求 401）
 *    - `RealtimeGateway.assertSessionActive`（握手 + 心跳）
 *    与安全审计 F1 同一教训：**禁止在任何调用方复制第二份 SQL 或第二个日期比较**
 *    （复制出来的第二份迟早与这里分叉 —— F1 的根因就是"守卫有、网关另写一套"）。
 *
 * ## 时间口径
 *
 * 配置值按 **Asia/Shanghai 墙钟**解释（中国大陆自 1991 年起无夏令时，UTC+8 为固定偏移 →
 * 不需要 tz 数据库、不引依赖）；同时接受**带显式时区的 ISO 8601**（如 `2026-10-12T16:00:00Z`），
 * 两者指向同一时刻。落库统一规整为 `YYYY-MM-DD HH:mm:ss`（中国墙钟），与既有
 * `formatChinaTime`（auth.service）/ 全站"库里存 UTC、展示转 +8"的口径一致，运营读库所见即所得。
 */

/** 配置键（管理端「系统设置」页的 key；`PUT /admin/settings/worker_app_sunset_at`） */
export const WORKER_APP_SUNSET_KEY = 'worker_app_sunset_at';
/** 默认到期时间（Asia/Shanghai 墙钟）—— 负责人定案：2026-10-13 00:00 */
export const WORKER_APP_SUNSET_DEFAULT_TEXT = '2026-10-13 00:00:00';
/** 同一时刻的 UTC 写法（2026-10-13 00:00 +08:00 = 2026-10-12 16:00Z）—— 纯函数与测试的唯一基准 */
export const WORKER_APP_SUNSET_DEFAULT_ISO = '2026-10-12T16:00:00.000Z';
/** 缺省/非法回落值（读侧回退用；**不是**"关闭开关"——要延后请改成更晚的时间） */
export const WORKER_APP_SUNSET_DEFAULT = new Date(WORKER_APP_SUNSET_DEFAULT_ISO);
/** 管理端配置说明（`GET /admin/settings` 直接展示） */
export const WORKER_APP_SUNSET_DESCRIPTION =
  '工作端 App 服务到期时间（Asia/Shanghai 墙钟，默认 2026-10-13 00:00:00）：到期后服务端拒绝 worker 的 primary 会话（登录 403 / 已登录 401 / WS 拒连），老板端「打手态」（companion 会话）不受影响（仅超管可改）';

/**
 * 到期后的统一中文文案 —— **login 403 与守卫 401 逐字一致**（客户端按文案引导迁移）。
 * 括号里就是迁移动作（我的 → 身份 → 切换身份 → 绑定打手账号），与老板端 v1.11.21 已上线的入口逐字对齐。
 */
export const WORKER_APP_SUNSET_GONE =
  '工作端已停止服务，请使用「祁连山电竞」App（我的 → 身份 → 切换身份 → 绑定打手账号）继续接单';

/** 中国墙钟正则（`YYYY-MM-DD` / `YYYY-MM-DD HH:mm` / `YYYY-MM-DD HH:mm:ss`，空格与 T 都收） */
const CHINA_WALL_CLOCK = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?$/;
/** 带显式时区的 ISO 8601（尾缀必须是 Z 或 ±HH:MM —— 不带时区的一律按中国墙钟解释，见上） */
const ISO_WITH_ZONE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?(Z|[+-]\d{2}:\d{2})$/i;

/** 中国时区固定偏移（小时）—— 中国大陆无夏令时，写常量而不是引 tz 库（零依赖铁律） */
const CHINA_OFFSET_HOURS = 8;

const pad2 = (n: number) => String(n).padStart(2, '0');

/** Date → 中国墙钟文本（`YYYY-MM-DD HH:mm:ss`）；与 auth.service 的 `formatChinaTime` 同一口径 */
export function formatChinaWallClock(date: Date): string {
  const t = new Date(date.getTime() + CHINA_OFFSET_HOURS * 3600_000);
  return (
    `${t.getUTCFullYear()}-${pad2(t.getUTCMonth() + 1)}-${pad2(t.getUTCDate())} ` +
    `${pad2(t.getUTCHours())}:${pad2(t.getUTCMinutes())}:${pad2(t.getUTCSeconds())}`
  );
}

/** 字段合法区间校验（防 2026-13-32 / 25:00 这类"看起来像日期"的脏值被 Date.UTC 静默进位） */
function assertFields(y: number, mo: number, d: number, h: number, mi: number, s: number): boolean {
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) return false;
  // 用 UTC 回环确认日期真实存在（如 2 月 30 日会被进位到 3 月）
  const probe = new Date(Date.UTC(y, mo - 1, d, h, mi, s));
  return (
    probe.getUTCFullYear() === y &&
    probe.getUTCMonth() === mo - 1 &&
    probe.getUTCDate() === d &&
    probe.getUTCHours() === h &&
    probe.getUTCMinutes() === mi &&
    probe.getUTCSeconds() === s
  );
}

/**
 * 解析配置值为时刻。接受两种写法（其余一律 null → 写侧 400 / 读侧回落默认）：
 * - 中国墙钟：`2026-10-13` / `2026-10-13 00:00` / `2026-10-13 00:00:00`（按 Asia/Shanghai 解释）
 * - 带时区 ISO：`2026-10-12T16:00:00Z` / `2026-10-13T00:00:00+08:00`（可带毫秒）
 */
export function parseWorkerAppSunsetAt(raw: unknown): Date | null {
  if (typeof raw !== 'string') return null;
  const text = raw.trim();
  if (!text) return null;

  const wall = CHINA_WALL_CLOCK.exec(text);
  if (wall) {
    const [, y, mo, d, h, mi, s] = wall;
    const yy = Number(y);
    const mm = Number(mo);
    const dd = Number(d);
    const hh = h === undefined ? 0 : Number(h);
    const mi2 = mi === undefined ? 0 : Number(mi);
    const ss = s === undefined ? 0 : Number(s);
    if (!assertFields(yy, mm, dd, hh, mi2, ss)) return null;
    return new Date(Date.UTC(yy, mm - 1, dd, hh - CHINA_OFFSET_HOURS, mi2, ss));
  }

  const iso = ISO_WITH_ZONE.exec(text);
  if (iso) {
    const [, y, mo, d, h, mi, s, ms, zone] = iso;
    const yy = Number(y);
    const mm = Number(mo);
    const dd = Number(d);
    const hh = Number(h);
    const mi2 = Number(mi);
    const ss = s === undefined ? 0 : Number(s);
    const mss = ms === undefined ? 0 : Number(ms.padEnd(3, '0'));
    if (!assertFields(yy, mm, dd, hh, mi2, ss)) return null;
    const base = Date.UTC(yy, mm - 1, dd, hh, mi2, ss, mss);
    if (zone.toUpperCase() === 'Z') return new Date(base);
    const sign = zone.startsWith('-') ? -1 : 1;
    const offH = Number(zone.slice(1, 3));
    const offM = Number(zone.slice(4, 6));
    if (offH > 23 || offM > 59) return null;
    return new Date(base - sign * (offH * 60 + offM) * 60_000);
  }

  return null;
}

/** 原始值的人读描述（错误提示里带上，便于运营自查；与 commission-rate / worker-binding-limit 同口径） */
function describeRaw(raw: unknown): string {
  if (raw === undefined) return '未填写';
  if (raw === null) return 'null';
  if (typeof raw === 'string') return `"${raw.slice(0, 40)}"`;
  if (typeof raw === 'object') return Array.isArray(raw) ? '数组' : '对象';
  return typeof raw;
}

/** 写入口校验：返回**规整后的中国墙钟文本**（落库口径唯一）；非法抛 400 中文 */
export function assertWorkerAppSunsetAt(raw: unknown): string {
  const at = parseWorkerAppSunsetAt(raw);
  if (!at) {
    throw new BadRequestException(
      `工作端到期时间格式非法：应为 "YYYY-MM-DD HH:mm:ss"（Asia/Shanghai，如 ${WORKER_APP_SUNSET_DEFAULT_TEXT}）` +
        `或带时区的 ISO 8601（如 ${WORKER_APP_SUNSET_DEFAULT_ISO}），当前值：${describeRaw(raw)}`,
    );
  }
  return formatChinaWallClock(at);
}

/** 判定结果（三处调用方共用同一形状） */
export interface WorkerAppSunsetState {
  /** true = 已到期（服务端收口生效） */
  sunset: boolean;
  /** 生效的到期时刻 */
  at: Date;
  /** 生效值的中国墙钟文本（便于日志/断言） */
  text: string;
  /** 值的来源：db 库中配置 / default 缺省（行不存在或值非法时回落，与读侧回退口径一致） */
  source: 'db' | 'default';
  /** 到期时的统一中文文案；未到期为 null */
  message: string | null;
}

/** 纯判定：**到期时刻已到或已过**即收口（边界取 `>=`：10-13 00:00:00 这一秒就已停止服务） */
export function isWorkerAppSunset(now: Date, at: Date): boolean {
  return now.getTime() >= at.getTime();
}

/**
 * **唯一读配置实现**：每次调用实时读库（**无缓存**），行缺失或值非法时回落默认时间并标注 source。
 *
 * 为什么不用 `SystemSettingService.get()`：那会绕成"服务 → 服务"的依赖（守卫/网关都拿不到该 Service，
 * 且它返回实体后各调用方还得各自解析 `cfg_value`）。这里用**一条只读 SQL**（`setting_key` 唯一索引，
 * 主键级开销）换取"改完下一次请求即生效"，与 `checkCompanionSession` / `checkRechargeSession`
 * 完全同构（同一个 `SqlRunner` 形状，守卫/网关/登录服务都直接传 `DataSource`）。
 */
export async function readWorkerAppSunsetAt(runner: SqlRunner): Promise<{
  at: Date;
  text: string;
  source: 'db' | 'default';
}> {
  const rows = (await runner.query(
    `SELECT cfg_value AS cfgValue FROM system_setting WHERE setting_key = ? LIMIT 1`,
    [WORKER_APP_SUNSET_KEY],
  )) as unknown;
  const row = firstRow<{ cfgValue: unknown }>(rows);
  let raw = row?.cfgValue as unknown;
  // mysql2 对 JSON 列一般已解析为对象；驱动/配置变化时可能是字符串 → 防御性二次解析
  if (typeof raw === 'string') {
    try {
      raw = JSON.parse(raw);
    } catch {
      raw = null;
    }
  }
  const value =
    raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>)['value'] : undefined;
  const at = parseWorkerAppSunsetAt(value);
  if (!at) {
    return { at: WORKER_APP_SUNSET_DEFAULT, text: WORKER_APP_SUNSET_DEFAULT_TEXT, source: 'default' };
  }
  return { at, text: formatChinaWallClock(at), source: 'db' };
}

/**
 * **唯一判定函数**（读配置 + 判断）：到期与否 + 统一文案。
 * `now` 可注入（测试钉边界，不读系统时钟之外的东西）。
 */
export async function checkWorkerAppSunset(runner: SqlRunner, now: Date = new Date()): Promise<WorkerAppSunsetState> {
  const { at, text, source } = await readWorkerAppSunsetAt(runner);
  const sunset = isWorkerAppSunset(now, at);
  return { sunset, at, text, source, message: sunset ? WORKER_APP_SUNSET_GONE : null };
}

/**
 * 会话侧判定（守卫与 WS 网关**共用**，避免两处各写一遍 kind 三元表达式）：
 * **只有 `kind='primary'` 且 `role='worker'` 的会话**才受到期收口影响。
 *
 * 为什么必须先看 kind：companion（老板端打手态）的 `role` **也是 `worker`**
 * —— 只按 role 判定会把替代品一起打死（本次最重要的一条不变量）。
 * 未知 kind 一律按 primary 处理（与 `auth.service.normalizeKind` 同口径：缺省即 primary）。
 */
export function isWorkerPrimarySession(kind: unknown, role: unknown): boolean {
  const k = kind === 'companion' || kind === 'recharge' ? kind : 'primary';
  return k === 'primary' && String(role ?? '') === 'worker';
}
