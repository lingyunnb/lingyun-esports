import { firstRow, SqlRunner } from './companion-session.check';

/**
 * 受限充值管理员会话（`auth_token.kind='recharge'`）可用性校验 —— **HTTP 守卫与 WS 网关的唯一实现**。
 *
 * 与 `companion-session.check.ts` 同构（同一类"受限会话"的两个实例）：
 * 校验实现只有一份，守卫每请求调用，绝不复制第二份 SQL（安全审计 F1 的教训）。
 *
 * 校验内容（任一不满足即不可用 → 401 中文）：
 * 1. 会话主体在 `recharge_admin` **白名单**里（**移出白名单 = 立即失效**，不等令牌过期）；
 * 2. 该账号未被封禁（`user.status=1`，到期封禁由 `AuthService.assertNotBanned` 的既有语义负责解封）；
 * 3. 该账号仍是 `role='admin'`（白名单行在、但账号被改成普通用户 → 不可用；
 *    与 `recharge_admin` 表注释里"必须是 role=admin 账号"这条口径对齐）。
 *
 * **只读、无缓存**（每次调用一条 SQL）——"移出白名单即刻失效"必须建立在实时查库上。
 * 注意：这里**不查权限点**。权限点是独立一层（`recharge:review` / `recharge:grant`），
 * 由 `PermissionsGuard` 按 `admin_role_permission` 实时校验；两层各管一段，互不代偿。
 */
/** 移出白名单 / 账号不可用时统一的中文提示（401：客户端据此退回老板态） */
export const RECHARGE_ADMIN_GONE = '受限管理身份已失效，请联系超级管理员重新授权';
/** 账号被封禁（401；与"被移出白名单"区分，便于客服定位） */
export const RECHARGE_ADMIN_BANNED = '该管理员账号已被封禁，受限管理身份不可用';
/** 账号不再是管理员角色（401） */
export const RECHARGE_ADMIN_NOT_ADMIN = '该账号已不是管理员，受限管理身份不可用';
/**
 * `POST /user/identity/refresh-recharge-admin` **只吃 recharge** refreshToken：
 * 别的令牌打进来必须在**任何写操作之前** 401 —— 否则会走 primary/companion 轮换分支，
 * 把该账号正在使用的会话一并吊销（与安全审计 F5 的 companion 版同一条闸门）。
 */
export const RECHARGE_REFRESH_ONLY = '该令牌不是受限管理身份，请重新绑定管理员账号';

export type RechargeInvalidReason = 'not-whitelisted' | 'banned' | 'not-admin';

export type RechargeCheckResult =
  | { ok: true }
  | { ok: false; reason: RechargeInvalidReason; message: string };

interface RechargeRow {
  whitelisted: number | string;
  userStatus: number | null;
  userRole: string | null;
}

/**
 * 校验一条受限充值管理员会话是否仍然可用。
 * @param runner 数据库执行者（守卫传 DataSource；事务内可传 EntityManager）
 * @param session 会话登记信息（`auth_token.kind='recharge'` 的行）：会话主体 = 该管理员账号
 */
export async function checkRechargeSession(
  runner: SqlRunner,
  session: { userId: string | number },
): Promise<RechargeCheckResult> {
  const userId = String(session?.userId ?? '');
  if (!userId) return { ok: false, reason: 'not-whitelisted', message: RECHARGE_ADMIN_GONE };

  const raw: unknown = await runner.query(
    `SELECT
       (SELECT COUNT(1) FROM recharge_admin ra WHERE ra.user_id = u.id) AS whitelisted,
       u.status AS userStatus,
       u.role AS userRole
     FROM user u
     WHERE u.id = ? LIMIT 1`,
    [userId],
  );
  const row = firstRow<RechargeRow>(raw);
  // 账号行不存在（已注销）→ 与"移出白名单"同一句提示（不泄露账号是否存在）
  if (!row) return { ok: false, reason: 'not-whitelisted', message: RECHARGE_ADMIN_GONE };
  if (Number(row.whitelisted) < 1) {
    return { ok: false, reason: 'not-whitelisted', message: RECHARGE_ADMIN_GONE };
  }
  if (row.userStatus === null || Number(row.userStatus) !== 1) {
    return { ok: false, reason: 'banned', message: RECHARGE_ADMIN_BANNED };
  }
  if (String(row.userRole ?? '') !== 'admin') {
    return { ok: false, reason: 'not-admin', message: RECHARGE_ADMIN_NOT_ADMIN };
  }
  return { ok: true };
}
