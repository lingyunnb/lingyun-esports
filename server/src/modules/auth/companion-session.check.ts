/**
 * 伴随会话（companion）可用性校验 —— **HTTP 守卫与 WebSocket 网关的唯一实现**（安全审计 F1 修复）。
 *
 * 为什么必须抽成一份（审计 F1 的根因）：
 * HTTP 侧 `JwtAuthGuard.assertCompanionUsable` 每次请求都校验"绑定 active + 两侧账号状态"，
 * 但 `RealtimeGateway.assertSessionActive` 只查 `auth_token(jti/user_id/revoked/expire_at)`——
 * 于是"绑定已被释放/老板已被封禁"时 **HTTP 已 401，而 WS 连接还能 join 房间并继续收到 msg:new 全文**。
 * 把 SQL 复制一份到网关只是把同一个分叉往后推（下一次改校验条件时必然只改一边），
 * 所以这里给出**唯一**实现：守卫（每请求）与网关（握手 + 心跳）都调用它。
 *
 * 校验内容（任一不满足即不可用）：
 * 1. `binding_id` 非空，且绑定行存在、`status='active'`（解绑 / 封禁 / 停用 / 删除触发的释放都会置 unbound）；
 * 2. 绑定里的 `worker_user_id` **必须等于会话主体**（防绑定 id 被张冠李戴）；
 * 3. 打手账号未封禁（`user.status=1`）、打手档案在职（`worker.status=1`）；
 * 4. **老板账号未封禁且仍存在**（`boss_user_id → user.status=1`，双保险：专兜历史悬空 active 行）。
 *
 * 只读、无缓存（每次调用一条 SQL）——"解绑即刻失效"必须建立在实时查库上。
 */
export interface SqlRunner {
  query: (sql: string, parameters?: unknown[]) => Promise<unknown>;
}

/** companion 会话失效时的统一中文提示（401：客户端据此清打手态并回到老板态） */
export const COMPANION_GONE = '伴随身份已失效，请重新绑定打手账号';
/** companion 的**老板账号**侧失效（被封禁/已注销）时的中文提示（401，可操作：重新登录老板账号） */
export const COMPANION_BOSS_GONE = '老板账号已被封禁，伴随身份已失效，请重新登录老板账号';
/** 打手账号被封禁（401；与"解绑"区分，便于客服定位） */
export const COMPANION_WORKER_BANNED = '该打手账号已被封禁，伴随身份不可用';
/** 打手档案被停用（401） */
export const COMPANION_WORKER_DISABLED = '该打手账号已停用，伴随身份不可用';
/**
 * `POST /user/identity/refresh` **只吃 companion** refreshToken（审计 F5）：
 * primary 的 refreshToken 打进来必须在**任何写操作之前** 401 —— 否则会走 primary 轮换分支，
 * 把该账号正在使用的 primary 会话一并吊销（实测原 token 立刻 401）。
 */
export const COMPANION_REFRESH_ONLY = '该令牌不是伴随身份，请使用 /auth/refresh';

/** 不可用原因（HTTP 映射为 401 中文；WS 映射为 auth:expired + 断线） */
export type CompanionInvalidReason =
  | 'binding-gone'
  | 'worker-banned'
  | 'worker-disabled'
  | 'boss-banned';

export type CompanionCheckResult =
  | { ok: true }
  | { ok: false; reason: CompanionInvalidReason; message: string };

interface CompanionRow {
  bindingStatus: string;
  bindingWorkerId: string | number;
  userStatus: number;
  workerStatus: number | null;
  bossUserStatus: number | null;
}

/**
 * 校验一条 companion 会话是否仍然可用。
 * @param runner 数据库执行者（守卫/网关传 DataSource；事务内传 EntityManager）
 * @param session 会话登记信息（`auth_token.kind='companion'` 的行）：绑定 id + 会话主体
 */
export async function checkCompanionSession(
  runner: SqlRunner,
  session: { bindingId: string | null | undefined; userId: string | number },
): Promise<CompanionCheckResult> {
  const bindingId = session.bindingId === null || session.bindingId === undefined ? '' : String(session.bindingId);
  if (!bindingId) return { ok: false, reason: 'binding-gone', message: COMPANION_GONE };

  const rows = (await runner.query(
    `SELECT b.status AS bindingStatus, b.worker_user_id AS bindingWorkerId,
            u.status AS userStatus, w.status AS workerStatus,
            bu.status AS bossUserStatus
     FROM worker_identity_binding b
     JOIN user u ON u.id = b.worker_user_id
     LEFT JOIN worker w ON w.user_id = b.worker_user_id
     LEFT JOIN user bu ON bu.id = b.boss_user_id
     WHERE b.id = ? LIMIT 1`,
    [bindingId],
  )) as unknown;
  const row = firstRow<CompanionRow>(rows);
  if (!row || row.bindingStatus !== 'active') {
    return { ok: false, reason: 'binding-gone', message: COMPANION_GONE };
  }
  // 绑定里的打手必须就是会话主体（防止绑定 id 与主体错配；签名密钥泄露也换不来别人的绑定）
  if (String(row.bindingWorkerId) !== String(session.userId)) {
    return { ok: false, reason: 'binding-gone', message: COMPANION_GONE };
  }
  if (Number(row.userStatus) !== 1) {
    return { ok: false, reason: 'worker-banned', message: COMPANION_WORKER_BANNED };
  }
  if (row.workerStatus === null || Number(row.workerStatus) !== 1) {
    return { ok: false, reason: 'worker-disabled', message: COMPANION_WORKER_DISABLED };
  }
  // 老板侧（**双保险**）：老板账号被封禁（status=2）或已注销（行不存在 → null）→ 不可用。
  // 正常路径下封禁/删除已把绑定置 unbound（第 1 条先命中）；这一条只在悬空 active 行上生效。
  if (row.bossUserStatus === null || Number(row.bossUserStatus) !== 1) {
    return { ok: false, reason: 'boss-banned', message: COMPANION_BOSS_GONE };
  }
  return { ok: true };
}

/** typeorm 原生查询在不同驱动配置下可能返回 [rows, fields] 或 rows，这里统一取首行 */
export function firstRow<T>(raw: unknown): T | null {
  const arr = (Array.isArray(raw) && Array.isArray(raw[0]) ? raw[0] : raw) as T[] | undefined;
  return arr && arr.length ? arr[0] : null;
}
