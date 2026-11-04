import { firstRow, type SqlRunner } from './companion-session.check';

/**
 * ============================ 账号封禁判定（服务端**唯一**实现）============================
 *
 * 背景（负责人 2026-10-16：「封禁要秒踢，且客户端要能显示"被封禁 + 原因"」）：
 *
 * 1. **文案分不开**：封禁走的还是"吊销令牌"（`auth_token.revoked = 1`），
 *    与"用户自己退出登录"**状态完全相同** → 客户端只能看到「登录已失效，请重新登录」，
 *    用户根本看不出自己被封了、为什么被封。本文件提供**能区分封禁**的文案与机器码。
 * 2. **主防线缺失**：companion / recharge 两条受限会话**每请求实时查库**校验账号未封禁，
 *    而 primary（老板/打手正常登录）这条主路径**历史上只校验了会话登记**，
 *    从未加载 `user.status`。一旦某条路径忘了吊销令牌（历史上就漏过），封禁完全不生效。
 * 3. **原因没落库**：`ban(id, { reason })` 的原因**只进了 operation_log**，
 *    `user` 表只有 `status` + `banned_until` 两列 → 想显示"因为什么被封"没有数据源。
 *
 * 本文件与 `companion-session.check.ts` / `recharge-session.check.ts` / `worker-app-sunset.ts`
 * 同构（三处既有范式），是**判定与文案的唯一出处**：
 *   - `JwtAuthGuard`（每请求 401 + `errorCode=ACCOUNT_BANNED`，**先于 revoked 检查**）
 *   - `AuthService.assertNotBanned`（登录/绑定 403，文案逐字不变）
 *   - `UserAdminService.ban / unban`（落库）
 *
 * ## 到期自动解封：**不造第二套**
 *
 * 既有语义只有一条（`AuthService.assertNotBanned` 的历史实现）：
 * `status=2` 且 `banned_until` 非空且 **已过期** → 「到期自动解封」，顺手把 `status` 复位 1。
 * 本文件把它抽成**纯函数** `evaluateBan()`（判定）与 `checkAccountBan()`（查库 + 顺手复位），
 * 登录路径与守卫路径共用同一句话，绝不各写一遍日期比较。
 * 本次只补一处：到期复位时**一并清 `ban_reason`**（否则解封后残留旧原因会误导下一次封禁的展示）。
 *
 * ## 性能（这是**每请求**都跑的路径）
 *
 * 一次调用 = **一条按主键（`user.id`）的单行 SELECT**；仅当"恰好在这次请求跨过封禁到期时刻"
 * 时才多一条 UPDATE（幂等，且之后不会再发生）。没有 JOIN、没有全表扫、没有 N+1
 * （守卫每个请求只调用**一次**，且只有 `kind='primary'` 的会话会走到这里 ——
 * companion / recharge 各自的 check 里已经有自己的 `user.status` 查询，不重复查）。
 */

/**
 * 封禁的稳定机器码（客户端**靠它**程序化识别"这是封禁，不是普通失效"，**绝不靠文案匹配**）：
 * 与登录路径 `AuthService.assertNotBanned` 的 403 共用同一个串（`ACCOUNT_BANNED`）。
 * 透传机制沿用既有实现：`AllExceptionsFilter` 会把 `errorCode` 原样写进响应体
 * （`VALIDATION_FAILED` / `RATE_LIMITED` / `ACCOUNT_BANNED` 都走这条）。
 */
export const ACCOUNT_BANNED_CODE = 'ACCOUNT_BANNED';

/** `user.ban_reason` 的列宽（varchar(200)）；写入前统一按**字符**截断，保证落库不报 1064/1406 */
export const BAN_REASON_MAX = 200;

/** 判定结果（三态；`expired` 与 `banned` 的区别就是"要不要放行 + 要不要复位"） */
export type BanDecision = 'ok' | 'expired' | 'banned';

/**
 * **纯判定**（无 IO，便于单测钉边界）：
 * - `status === 1` → `ok`（未封禁）；
 * - `banned_until` 非空且 `<= now` → `expired`（**到期自动解封**，放行并由调用方复位）；
 * - 其余（`status !== 1`）→ `banned`（`banned_until` 为 NULL = 永久封禁）。
 *
 * 边界取 `<=`：与 `AuthService.assertNotBanned` 的历史实现逐字一致
 * （`bannedUntil.getTime() <= Date.now()` → 那一毫秒起就放行）。
 */
export function evaluateBan(status: unknown, bannedUntil: unknown, now: Date = new Date()): BanDecision {
  if (Number(status) === 1) return 'ok';
  const until = toDate(bannedUntil);
  if (until && until.getTime() <= now.getTime()) return 'expired';
  return 'banned';
}

/** `banned_until` 来自驱动时可能是 Date / 字符串 / null，统一成 Date（非法值一律 null = 永久） */
export function toDate(value: unknown): Date | null {
  if (value === null || value === undefined || value === '') return null;
  const d = value instanceof Date ? value : new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d;
}

/** 中国墙钟（`YYYY-MM-DD HH:mm`）——与 `auth.service.formatChinaTime` 同一口径（库里存 UTC，展示 +8） */
function formatChinaTime(d: Date): string {
  const t = new Date(d.getTime() + 8 * 3600_000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${t.getUTCFullYear()}-${p(t.getUTCMonth() + 1)}-${p(t.getUTCDate())} ${p(t.getUTCHours())}:${p(t.getUTCMinutes())}`;
}

/**
 * **封禁文案的唯一构造实现**（守卫 401 与 WS 踢线共用；客户端原样展示，不改写一个字）。
 *
 * - 有原因：`账号已被封禁：<原因>（解封时间：2026-11-01 12:00）`
 * - 永久：  `账号已被封禁：<原因>（永久）`
 * - 无原因：省略「：原因」那一段（`账号已被封禁（永久）` / `账号已被封禁（解封时间：…）`）
 */
export function buildBanMessage(reason: string | null | undefined, bannedUntil: Date | null): string {
  const r = String(reason ?? '').trim();
  const tail = bannedUntil ? `（解封时间：${formatChinaTime(bannedUntil)}）` : '（永久）';
  return r ? `账号已被封禁：${r}${tail}` : `账号已被封禁${tail}`;
}

/** 一次封禁判定的完整结果 */
export interface AccountBanState {
  /** 判定：ok 放行 / expired 到期已复位 / banned 拦下 */
  decision: BanDecision;
  /** banned 时的完整中文文案（含原因与解封时间）；其余为 null */
  message: string | null;
  /** 库中的封禁原因（可能为 null） */
  reason: string | null;
  /** 库中的解封时刻（NULL = 永久） */
  bannedUntil: Date | null;
  /** 本次是否**顺手**把到期的封禁复位了（status=1 + banned_until=NULL + ban_reason=NULL） */
  autoUnbanned: boolean;
}

interface BanRow {
  status: number | string;
  bannedUntil: Date | string | null;
  banReason: string | null;
}

/**
 * **唯一查库实现**：按主键读 `user.status / banned_until / ban_reason` →
 * `evaluateBan` → 到期则**顺手复位**（与登录路径同一条语义）。
 *
 * @param runner 数据库执行者（守卫/服务传 `DataSource`；事务内可传 `EntityManager` ——
 *   但注意本函数会写库，事务内调用请确认那是你想要的语义）
 * @param userId 会话主体（`auth_token.user_id`）
 * @param now 可注入（测试钉边界）
 *
 * 账号行不存在（已注销）→ 视为 `ok`：**本函数只管封禁**，账号是否存在由各自的会话校验负责
 * （companion/recharge 有自己的判定；primary 的"用户被删"由 `auth_token` 行被删兜住）。
 * 这里**刻意不返回 401**：多一条"账号不存在"的分支就等于多一处会话存在性 oracle（审计 F3）。
 */
export async function checkAccountBan(
  runner: SqlRunner,
  userId: string | number,
  now: Date = new Date(),
): Promise<AccountBanState> {
  const id = String(userId ?? '');
  if (!id) return { decision: 'ok', message: null, reason: null, bannedUntil: null, autoUnbanned: false };

  const raw = (await runner.query(
    `SELECT status, banned_until AS bannedUntil, ban_reason AS banReason
       FROM \`user\` WHERE id = ? LIMIT 1`,
    [id],
  )) as unknown;
  const row = firstRow<BanRow>(raw);
  if (!row) return { decision: 'ok', message: null, reason: null, bannedUntil: null, autoUnbanned: false };

  const bannedUntil = toDate(row.bannedUntil);
  const reason = row.banReason === null || row.banReason === undefined ? null : String(row.banReason);
  const decision = evaluateBan(row.status, row.bannedUntil, now);

  if (decision === 'expired') {
    // 到期自动解封（**与登录路径同一件事**：status 复位 + banned_until 清空），
    // 外加本次新增的 ban_reason 清空 —— 解封后残留旧原因会误导"下一次被封"的展示。
    // 幂等：只有恰好在这次请求跨过到期时刻才会写一次。
    await runner.query(
      `UPDATE \`user\` SET status = 1, banned_until = NULL, ban_reason = NULL, updated_at = NOW(3) WHERE id = ?`,
      [id],
    );
    return { decision: 'expired', message: null, reason: null, bannedUntil: null, autoUnbanned: true };
  }

  if (decision === 'banned') {
    return { decision, message: buildBanMessage(reason, bannedUntil), reason, bannedUntil, autoUnbanned: false };
  }
  return { decision: 'ok', message: null, reason, bannedUntil, autoUnbanned: false };
}

/**
 * 写入前的封禁原因清洗（**唯一实现**，`ban()` 调用）：
 * 去首尾空白、按**字符**截断到 200（`user.ban_reason` 是 varchar(200)，
 * 按 UTF-16 码元截断会把 emoji/生僻字截成半个代理对）、空串一律归 `null`
 * （"没有原因" = NULL，而不是空字符串 —— 展示层与 SQL 判定都只看 NULL）。
 */
export function normalizeBanReason(raw: unknown): string | null {
  const text = String(raw ?? '').trim();
  if (!text) return null;
  return Array.from(text).slice(0, BAN_REASON_MAX).join('');
}
