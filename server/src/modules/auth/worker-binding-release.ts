/**
 * 打手侧绑定的**强制释放**（负责人 2026-10-06 裁决；安全审计 F1-b / F4 加固）。
 *
 * 背景：老板 ↔ 打手 的绑定（`worker_identity_binding`）只在**老板主动解绑**时才会从 active 落到
 * unbound。打手被封禁/停用后，绑定行仍是 active —— 伴随会话虽然已经失效（`JwtAuthGuard` 每请求
 * 校验 user.status / worker.status → 401），但老板侧 `GET /user/identity` 仍显示"已绑定"，
 * 解封后语义混乱（看起来还能用，实际要重新走一遍绑定）。
 *
 * 裁决：**管理端封禁/停用打手时，顺手把该打手的 active 绑定置为 unbound**（写 `unbound_at`，保留历史行）。
 * 因此本文件的 `releaseWorkerBindings` 给"封禁 / 停用"两个入口共用。
 *
 * 补充（2026-10-06 缺口 1 / 缺口 2 裁决）：释放必须**对称** —— 同一账号既可能是打手（被绑的一方），
 * 也可能是老板（绑定别人、持有 companion 的一方）：
 * - `releaseBossBindings`：`boss_user_id = 该账号`（封禁老板 → 其名下伴随会话的来源要一起断）；
 * - `releaseUserBindings`：两侧一起释放，**封禁（`UserAdminService.ban`）与删除（`deleteUser`）共用**。
 *
 * ======================= 安全审计 F1（中危）修复：释放必须**同时**做三件事 =======================
 * 审计实测：绑定被释放后 HTTP 已 401，但**旧 WS 连接仍在收 msg:new 全文**、**同一令牌还能新建 WS**。
 * 根因是释放路径只 UPDATE 了绑定行、**不吊销令牌**，而 WS 侧只看 `auth_token.revoked`。因此本文件是
 * **所有释放路径的唯一实现**，一次调用内完成：
 * 1. **置 unbound**（`status='active'` 是 WHERE 的一部分，历史行一律不碰）；
 * 2. **按 `binding_id` 吊销该绑定的全部 companion 会话**（`revoked=1`，语义与"老板主动解绑"完全一致：
 *    `AuthService.revokeCompanionTokensByBinding` 的既有口径）并回传被吊销的 jti 列表，
 *    供调用方**立即断开**这些会话的 WS 连接（`BindingReleaseService` → `disconnectByJti`）；
 * 3. **写持久化审计**（`login_log.user_type='identity'`，与"绑定"同一口径）：谁触发、哪个 bindingId、
 *    老板 id、打手 id、来源（主动解绑/打手停用/封禁/删除）、IP、UA、时间。
 *
 * 为什么审计写 `login_log` 而不是 `operation_log`（审计 F4 要求二选一）：
 * - 需求明确要记 **UA**，而 `operation_log` **没有 UA 列**（只有 ip/request_body）；
 * - `login_log` 已经是"绑定身份事件"的账本（`AuthService.recordIdentityEvent` 写的就是它，
 *   `user_type='identity'`），解绑写进去后"绑定生命周期"在同一张表里可一次性查全（bind + unbind）；
 * - 管理端封禁/删除/改档案**已经**在 `operation_log` 留了"管理员动作"那一行，身份事件再写一份进去
 *   只会让"这条绑定什么时候没的"分散在两张表里，且丢失 UA。
 *
 * 4 条硬约束（照裁决执行，别在调用点自己发挥）：
 * 1. **同步**：调用方 `await` 它，在同一请求内完成 —— 不排队、不发事件、不留后台任务；
 * 2. **不新开事务**：调用方在**既有**写入流程里顺带执行（封禁路径本来就没有事务，就不为它单开一个；
 *    删除路径用**既有事务**的 `EntityManager`（`em.query`）传入，此时 WS 断开由调用方在提交后触发）；
 * 3. **只动 active 行**：历史 unbound 行（含此前的解绑记录）一律不碰；`unbound_at` 记下释放时刻，
 *    便于审计"这一行是什么时候因为封禁掉的"；
 * 4. **幂等**：没有 active 行时零写入（不写审计、不吊销、不踢线），重复调用安全。
 *
 * 唯一键语义（migration 1801000000000）：两个唯一键建在生成列上（status≠active 时为 NULL），
 * 所以置 unbound 之后**名额自动释放** —— 打手解封后可被同一个或另一个老板重新绑定。
 *
 * ⚠️ 与"解封"的关系：**解封不自动恢复绑定**（负责人裁决）。`unban` 只回写 `user.status=1`，
 * 绝不把 unbound 行翻回 active —— 必须由老板重新输密码绑定（`POST /user/identity/bind`）。
 */

/** 数据库执行者（DataSource 或事务 EntityManager，二者签名一致） */
export interface SqlRunner {
  query: (sql: string, parameters?: unknown[]) => Promise<unknown>;
}

/** 释放触发来源（写进审计 reason 的"来源="，也是排查"谁把绑定弄没了"的第一现场） */
export type BindingReleaseSource = 'boss-unbind' | 'worker-disabled' | 'user-banned' | 'user-deleted';

const SOURCE_TEXT: Record<BindingReleaseSource, string> = {
  'boss-unbind': '老板主动解绑',
  'worker-disabled': '系统释放（打手档案停用）',
  'user-banned': '系统释放（封禁账号）',
  'user-deleted': '系统释放（删除账号）',
};

/** 审计上下文：谁触发 + 来源 + 请求侧证据（IP/UA） */
export interface ReleaseSink {
  source: BindingReleaseSource;
  /** 触发者的 user id（老板本人 / 管理员账号的 user id）；系统自动释放且无触发者时留空 */
  actorUserId?: string | null;
  /** 触发者标签（写进 reason 的 `by=`）；缺省按来源推导（主动解绑=user:<boss>，系统释放=system） */
  actorLabel?: string | null;
  ip?: string | null;
  userAgent?: string | null;
}

/** 一条被释放的绑定（含两侧 id，供回带/日志/审计） */
export interface ReleasedBinding {
  bindingId: string;
  bossUserId: string;
  workerUserId: string;
  bossUsername: string;
}

/** 一次释放的完整结果 */
export interface ReleaseOutcome {
  /** 被置为 unbound 的绑定（0 条 = 本来就没有 active 绑定，幂等路径） */
  bindings: ReleasedBinding[];
  /** 本次按 `binding_id` 吊销的 companion 会话 jti（access + refresh），用于立即断开 WS */
  revokedJtis: string[];
  /** 本次吊销的会话行数 */
  revokedSessions: number;
  /** 本次写入的持久化审计行数（login_log user_type='identity'） */
  auditRows: number;
  /** 本次真正释放的行数（历史口径，HTTP 响应 `releasedBindings` 用它） */
  total: number;
  /** 该账号作为**打手**被释放的行数（`worker_user_id = 该账号`） */
  workerSide: number;
  /** 该账号作为**老板**被释放的行数（`boss_user_id = 该账号` → 其名下 companion 立即失去绑定） */
  bossSide: number;
}

/** 释放范围：按打手侧 / 老板侧 / 指定绑定 id（老板主动解绑走 binding） */
export type ReleaseScope =
  | { side: 'worker'; userId: string }
  | { side: 'boss'; userId: string }
  | { side: 'binding'; bindingId: string };

const EMPTY: ReleaseOutcome = {
  bindings: [], revokedJtis: [], revokedSessions: 0, auditRows: 0, total: 0, workerSide: 0, bossSide: 0,
};

/** `?,?,?` —— 显式展开占位符（不依赖驱动的数组展开行为） */
function placeholders(n: number): string {
  return new Array(n).fill('?').join(',');
}

function affectedRowsOf(raw: unknown): number {
  const first = Array.isArray(raw) ? raw[0] : raw;
  const n = Number((first as { affectedRows?: number } | null | undefined)?.affectedRows);
  return Number.isFinite(n) ? n : 0;
}

function rowsOf<T>(raw: unknown): T[] {
  const arr = (Array.isArray(raw) && Array.isArray(raw[0]) ? raw[0] : raw) as T[] | undefined;
  return Array.isArray(arr) ? arr : [];
}

/** `login_log.fail_reason` 是 varchar(100)：超长直接截断，宁可少几个字符也不能让审计写入失败 */
function clamp100(s: string): string {
  return s.length > 100 ? s.slice(0, 100) : s;
}

/**
 * **释放绑定的唯一实现**（审计 F1-b/F4）：
 * 置 unbound → 按 binding_id 吊销 companion 令牌 → 写 identity 审计。
 * 返回被释放的绑定与被吊销的 jti（调用方据此断开 WS）。
 */
export async function releaseBindings(
  runner: SqlRunner,
  scope: ReleaseScope,
  sink: ReleaseSink,
): Promise<ReleaseOutcome> {
  const column = scope.side === 'worker' ? 'b.worker_user_id' : scope.side === 'boss' ? 'b.boss_user_id' : 'b.id';
  const value = scope.side === 'worker' ? String(scope.userId)
    : scope.side === 'boss' ? String(scope.userId)
      : String(scope.bindingId);

  // ① 先取出将被释放的 active 行（含老板登录名，供审计的 username 列）
  const rawRows = await runner.query(
    `SELECT b.id AS bindingId, b.boss_user_id AS bossUserId, b.worker_user_id AS workerUserId,
            bu.username AS bossUsername
       FROM worker_identity_binding b
       LEFT JOIN \`user\` bu ON bu.id = b.boss_user_id
      WHERE ${column} = ? AND b.status = 'active'
      ORDER BY b.id ASC`,
    [value],
  );
  const bindings: ReleasedBinding[] = rowsOf<{
    bindingId: string | number; bossUserId: string | number; workerUserId: string | number; bossUsername: string | null;
  }>(rawRows).map((r) => ({
    bindingId: String(r.bindingId),
    bossUserId: String(r.bossUserId),
    workerUserId: String(r.workerUserId),
    bossUsername: r.bossUsername ?? '',
  }));
  if (bindings.length === 0) return { ...EMPTY }; // 幂等：没有 active 行 = 什么都不做（不写审计、不吊销）

  const ids = bindings.map((b) => b.bindingId);
  const ph = placeholders(ids.length);

  // ② 绑定行 → unbound（保留历史行；只动 active 行）
  await runner.query(
    `UPDATE worker_identity_binding
        SET status = 'unbound', unbound_at = NOW(3), updated_at = NOW(3)
      WHERE id IN (${ph}) AND status = 'active'`,
    ids,
  );

  // ③ 按 binding_id 吊销该绑定的 companion 会话（access + refresh）——
  //    与"老板主动解绑"完全相同的语义（revoked=1）；先查 jti 再吊销，jti 用于立即断开 WS。
  const jtiRows = await runner.query(
    `SELECT jti FROM auth_token
      WHERE binding_id IN (${ph}) AND kind = 'companion' AND revoked = 0`,
    ids,
  );
  const revokedJtis = rowsOf<{ jti: string }>(jtiRows).map((r) => String(r.jti));
  let revokedSessions = 0;
  if (revokedJtis.length > 0) {
    revokedSessions = affectedRowsOf(
      await runner.query(
        `UPDATE auth_token SET revoked = 1
          WHERE binding_id IN (${ph}) AND kind = 'companion' AND revoked = 0`,
        ids,
      ),
    );
  }

  // ④ 持久化审计（复用 login_log 的 identity 口径：绑定/解绑同一张表，含 IP/UA/时间）
  // reason 的字段顺序刻意是「来源 → 触发者 → binding → 两侧 id」：`fail_reason` 是 varchar(100)，
  // 极端情况下（超长登录名 + 20 位 id）会被 clamp100 截断，保证**最重要的"谁触发/哪个绑定"先保住**。
  const actor = sink.actorLabel ?? (sink.source === 'boss-unbind'
    ? (sink.actorUserId ? `user:${sink.actorUserId}` : 'user')
    : (sink.actorUserId ? `admin:${sink.actorUserId}` : 'system'));
  const values: string[] = [];
  const params: unknown[] = [];
  for (const b of bindings) {
    values.push('(?,?,?,?,?,?,?)');
    params.push(
      'identity',
      b.bossUserId,
      (b.bossUsername || `user#${b.bossUserId}`).slice(0, 32),
      sink.ip ? String(sink.ip).slice(0, 64) : null,
      sink.userAgent ? String(sink.userAgent).slice(0, 255) : null,
      'success',
      clamp100(
        `解绑：${SOURCE_TEXT[sink.source]} | by=${actor} | binding=${b.bindingId} | boss=${b.bossUserId} | worker=${b.workerUserId}`,
      ),
    );
  }
  await runner.query(
    `INSERT INTO login_log (user_type, user_id, username, ip, user_agent, result, fail_reason)
     VALUES ${values.join(',')}`,
    params,
  );

  const total = bindings.length;
  return {
    bindings,
    revokedJtis,
    revokedSessions,
    auditRows: total,
    total,
    workerSide: scope.side === 'worker' ? total : 0,
    bossSide: scope.side === 'boss' ? total : 0,
  };
}

/** 释放某打手的全部 active 绑定（**打手侧**：该账号被谁绑着） */
export function releaseWorkerBindings(
  runner: SqlRunner,
  workerUserId: string,
  sink: ReleaseSink,
): Promise<ReleaseOutcome> {
  return releaseBindings(runner, { side: 'worker', userId: String(workerUserId) }, sink);
}

/**
 * 释放某老板名下的全部 active 绑定（**老板侧**：`boss_user_id = 该账号`）。
 *
 * 缺口 1（负责人 2026-10-06 裁决）：封禁 / 删除账号必须**对称**释放 —— 只释放"该用户作为打手"的绑定，
 * 会留下"老板被封禁 / 被删除，其名下的伴随会话仍可用"或"打手名额被永久占用"的缺口（实测：
 * 封禁老板 → companion 请求仍是 200，`releasedBindings=0`）。历史行一律保留（`status=unbound` + `unbound_at`）。
 */
export function releaseBossBindings(
  runner: SqlRunner,
  bossUserId: string,
  sink: ReleaseSink,
): Promise<ReleaseOutcome> {
  return releaseBindings(runner, { side: 'boss', userId: String(bossUserId) }, sink);
}

/** 老板**主动**解绑指定的那一条绑定（`POST /user/identity/unbind`；语义与其它路径共用同一实现） */
export function releaseOneBinding(
  runner: SqlRunner,
  bindingId: string,
  sink: ReleaseSink,
): Promise<ReleaseOutcome> {
  return releaseBindings(runner, { side: 'binding', bindingId: String(bindingId) }, sink);
}

/**
 * 释放某账号的**两侧** active 绑定 —— **封禁 / 删除两个入口共用的唯一助手**（负责人 2026-10-06 裁决）。
 *
 * - 本人作为打手：`worker_user_id = 该账号`（复用 `releaseWorkerBindings`，与打手停用/封禁路径同一实现）；
 * - 本人作为老板：`boss_user_id = 该账号`（`releaseBossBindings`）—— **只做打手侧就是本次的不对称缺口**。
 */
export async function releaseUserBindings(
  runner: SqlRunner,
  userId: string,
  sink: ReleaseSink,
): Promise<ReleaseOutcome> {
  const workerSide = await releaseWorkerBindings(runner, userId, sink);
  const bossSide = await releaseBossBindings(runner, userId, sink);
  return {
    bindings: [...workerSide.bindings, ...bossSide.bindings],
    revokedJtis: [...workerSide.revokedJtis, ...bossSide.revokedJtis],
    revokedSessions: workerSide.revokedSessions + bossSide.revokedSessions,
    auditRows: workerSide.auditRows + bossSide.auditRows,
    total: workerSide.total + bossSide.total,
    workerSide: workerSide.total,
    bossSide: bossSide.total,
  };
}
