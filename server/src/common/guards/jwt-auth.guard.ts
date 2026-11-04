import { CanActivate, ExecutionContext, ForbiddenException, Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';
import { AuthToken, AuthTokenKind } from '../../modules/auth/auth-token.entity';
import {
  COMPANION_GONE,
  COMPANION_BOSS_GONE,
  checkCompanionSession,
} from '../../modules/auth/companion-session.check';
import { checkRechargeSession } from '../../modules/auth/recharge-session.check';
import {
  ACCOUNT_BANNED_CODE,
  checkAccountBan,
} from '../../modules/auth/account-ban.check';
import {
  WORKER_APP_SUNSET_GONE,
  checkWorkerAppSunset,
  isWorkerPrimarySession,
} from '../../modules/auth/worker-app-sunset';

export interface AuthUser {
  userId: string;
  role: string;
  jti: string;
  /** 会话种类（取自 auth_token 库中登记，不信任令牌载荷）：primary 普通登录 / companion 伴随会话 / recharge 受限充值管理员 */
  kind: AuthTokenKind;
  /** companion 会话所属绑定 id（primary/recharge 为 null） */
  bindingId: string | null;
}

/*
 * companion 会话失效时的中文提示（401：客户端据此清打手态并回到老板态）与**校验实现**都在
 * `modules/auth/companion-session.check.ts` —— HTTP 守卫与 WS 网关共用同一份，不再各写一套
 * （安全审计 F1：WS 侧曾自行其事，导致"HTTP 已 401、WS 还在推消息"）。
 * 受限充值管理员会话（kind='recharge'）的校验同构，实现同样只有一份：
 * `modules/auth/recharge-session.check.ts`。
 */
/** companion 越界访问老板侧/管理端接口时的中文提示（403：身份还在，但这个操作不允许） */
const COMPANION_FORBIDDEN = '伴随身份无此操作权限，请切回老板身份后操作';
/** 受限充值管理员越界访问非充值族接口时的中文提示（403：身份还在，但这个操作不允许） */
const RECHARGE_ADMIN_FORBIDDEN = '受限管理身份仅可处理充值审核，请用管理端完成其它操作';

/**
 * JWT 认证守卫（docs/04）：
 * 1. 校验 Bearer access token（签名/过期/type）
 * 2. 校验 auth_token 表登记且未吊销（登出/轮换/踢下线立即失效）
 * 3. 注入 req.user = { userId, role, jti, kind, bindingId }——主体 id 的唯一可信来源
 *
 * ============================ 伴随会话（companion）============================
 * 合并双端·身份切换（方案甲，负责人 2026-10-06 拍板③）：老板端内用打手账密切换身份时，
 * 签发的是 `kind=companion` 的受限会话。它**不是** primary，因此既要"能用打手侧接口"，
 * 又必须"绝不能被当成 primary 用"。规则如下（全部以**库中登记**为准，绝不信任令牌载荷）：
 *
 * A. 每请求有效性校验（每次请求都查库，无缓存）——**实现只有一份**：
 *    `modules/auth/companion-session.check.ts` 的 `checkCompanionSession()`，本守卫与
 *    `RealtimeGateway`（WS 握手 + 心跳）共用（安全审计 F1：WS 侧曾漏掉这一层：
 *    "HTTP 已 401，旧 WS 连接仍能 join 房间并继续收到 msg:new 全文"）。校验内容：
 *    - `auth_token.kind='companion'` 且 `binding_id` 非空；
 *    - 绑定行存在且 `status='active'`（**解绑即刻失效** → 401 中文）；
 *    - 绑定里的 `worker_user_id` 必须等于会话主体（防绑定 id 被张冠李戴）；
 *    - 打手账号未被封禁（`user.status=1`）、打手档案在职（`worker.status=1`）；
 *    - **老板账号未被封禁且仍存在**（`boss_user_id` → `user.status=1`，2026-10-06 缺口 1 双保险：
 *      封禁/删除已对称释放绑定，这一条兜住历史悬空 active 行 → 401「老板账号已被封禁…」）。
 *
 * B. 接口族**白名单（默认拒绝）**——companion 只能访问：
 *    - `/worker/*`                打手侧全部（大厅/抢单/派单确认/开始/提交/我的订单/收益/待遇/客服会话/排行榜）
 *    - `/user/conversation*`      客服会话（老板/客服两段消息）
 *    - `/user/conversations*`     会话列表（含 `type` 区分 客服/老板/好友）/ 消息历史 / 发送消息 /
 *                                 **一键已读 `POST /user/conversations/:id/read`**（消息族前缀覆盖）
 *    - `GET /user/friends`        好友列表（打手态消息页【好友】段的**读**数据源；负责人 2026-10-06）
 *    - `POST /user/friends/:id/conversation` 打开与**已是好友**的会话（服务端只认 accepted 关系）
 *    - `GET /user/profile/*`      资料读（聊天里点头像看公开资料）
 *    - `/media/*`                 聊天图片等媒体上传与受保护读取
 *    - `GET /auth/me`、`POST /auth/logout`、`POST /auth/refresh`
 *    其余一律 403 中文（`COMPANION_FORBIDDEN`）。**特别地**：
 *    - `/user/identity/*`（绑定的绑定/解绑/状态）→ 老板侧能力，companion 不可用；
 *    - `/auth/password`（改密码）、`PUT /user/profile`（改资料）、`POST /user/profile/uid`（改 ID）→ 账号级写操作，companion 不可用；
 *    - `/user/orders`（下单）、`/user/wallet`、`/user/tips`、`/user/refunds`、`/user/complaints`、`/user/ai/*` → 老板态能力；
 *    - `/user/friends*` 里**除** `GET /user/friends`（列表）与 `POST /user/friends/:id/conversation`（开会话）
 *      以外的全部路由 → 好友关系的**写**能力（搜索/申请/同意/拒绝/删除）与系统通知，companion 一律不可用；
 *    - `/admin/*`（管理端）→ 不只是白名单，`RolesGuard` 也会按 `role` 拦（companion 的 role 是 worker）。
 *    白名单是**允许清单**而不是黑名单：将来新增接口默认对 companion 关闭，必须显式加进来才能用
 *    （黑名单模式会在"新接口忘了加规则"时静默放开，这是不可接受的默认值）。
 *
 * C. 与单设备登录（primary）的关系：
 *    - primary 的校验路径**逐字节未改**（含 revoked=1/2 的原有文案）；
 *    - **各类会话互不干扰**（`AuthService.issueTokens` 的实际实现）：primary 登录/续期**只顶掉同账号的其它
 *      primary**（`WHERE user_id=? AND kind='primary'`：登录 replaced → revoked=2「账号已在其他设备登录」，
 *      续期 → revoked=1），**不触碰 companion/recharge**；companion 签发/续期**只顶同账号的其它 companion**，
 *      recharge 同理 —— 都绝不触碰 primary。
 *    - **单设备铁律一点没松**：primary ↔ primary 仍然互斥（同账号第二次登录照旧顶掉第一次，文案不变）——
 *      在只有 primary 行的世界里，带 `kind='primary'` 的吊销语句与历史实现**逐字节等价**（过滤条件恒真）。
 *      companion 侧另有三重约束兜底：12h TTL + 每请求校验绑定 active + 解绑/封禁即吊销。
 *
 * ==================== 受限充值管理员会话（recharge，2026-10-06）====================
 * 老板端「身份」里新增的**管理员态**（负责人定案：最多 5 个账号、权限仅限余额/充值相关）。
 * 它与 companion 是**同一类东西的两个实例**——"受限会话"：复用同一套机制，不新造一套。
 *
 * A. 每请求有效性校验（无缓存，实现只有一份 `checkRechargeSession`）：
 *    - 会话主体仍在 `recharge_admin` 白名单（**移出白名单 → 下一次请求立即 401 中文**）；
 *    - 账号未封禁（`user.status=1`）、仍是 `role='admin'`。
 * B. 接口族**白名单（默认拒绝）**——recharge 只能访问：
 *    - `/recharge/*`              充值审核族（待审列表 / 发放 / 驳回 / 当前身份 / 凭证读取）
 *    - `GET /auth/me`、`POST /auth/logout`、`POST /auth/refresh`
 *    其余一律 403 中文（`RECHARGE_ADMIN_FORBIDDEN`）。**特别地**：
 *    - `/admin/*`（含 `/admin/users`、`/admin/products`、`/admin/recharge/*`）→ 403。
 *      为什么连本功能的**管理端**接口也不放行：那些接口的定义是"管理端（`admin:*` 权限）"，
 *      受限会话要改配置/收款码必须走管理端登录（primary），这正是"权限仅限余额相关"的落地。
 *    - `/user/*`（`/user/orders`、`/user/wallet`、`/user/identity/*`、`/user/recharge/*`、`PUT /user/profile`…）→ 403；
 *    - `/auth/password`（改密码）→ 403；
 *    - `/media/*` → 403（**刻意不给**：`/media/protected/:id` 对 `role=admin` 放行**任意**受保护媒体，
 *      受限会话不该拿到这个面。充值凭证改走 `/recharge/proof/:requestId`——只放行"这张申请的那张图"）。
 *    与 companion 一样是**允许清单**：将来新增接口默认对 recharge 关闭。
 * C. WS：`RealtimeGateway` **拒绝** recharge 会话握手（受限会话无实时需求；且它的 role 是 admin，
 *    放进来会 join 管理端广播房间 `admin` —— 那是明确的越权面）。
 *
 * ==================== 工作端到期收口（2026-10-06 定案）====================
 * 到期后（`system_setting.worker_app_sunset_at`，默认 `2026-10-13 00:00` Asia/Shanghai）：
 * - **拒绝** `role=worker` 的 **primary** 会话：本守卫每请求 401 中文
 *   （`/worker/*`、`/user/*` 及一切受保护接口），`AuthService.login` 403 中文，
 *   `RealtimeGateway` 握手/心跳拒绝 —— 三处**共用同一个判定函数**
 *   `modules/auth/worker-app-sunset.ts` 的 `checkWorkerAppSunset()`（读库无缓存）。
 * - **绝不影响**：老板端「打手态」companion 会话（`kind='companion'`，`role` 同样是 worker，
 *   但它正是工作端的替代品，必须照常可用）、老板端（user）、管理端（admin）、受限充值会话（recharge）。
 *   边界由 `isWorkerPrimarySession(kind, role)` 一句话定义（**只看 kind=primary**），
 *   守卫与网关共用同一句，不各写一遍。
 *
 * ==================== primary 会话的封禁判定（2026-10-16 负责人需求）====================
 * 封禁要「秒踢 + 客户端能显示"被封禁 + 原因"」，三条缺口各自落在：
 * 1. **文案分不开**：封禁与"自己退出登录"都只是 `revoked=1` → 本守卫在 **revoked 检查之前**
 *    先判封禁（判定与文案构造的唯一实现：`modules/auth/account-ban.check.ts`），
 *    返回 401 + `errorCode=ACCOUNT_BANNED` + `账号已被封禁：<原因>（解封时间：…）/（永久）`；
 * 2. **主路径缺封禁判定**：`kind='primary'` 每请求实时读 `user.status / banned_until / ban_reason`
 *    （companion / recharge 各自的 check 已含 `user.status`，不重复查）；
 * 3. **原因没落库**：`user.ban_reason`（migration `1816000000000`），解封/到期自动解封一律清空。
 * 到期自动解封与 `AuthService.assertNotBanned` 共用同一句纯判定（不造第二套）。
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const token = this.extractBearer(request);
    if (!token) {
      throw new UnauthorizedException('未登录');
    }

    let payload: { sub?: string; role?: string; jti?: string; type?: string };
    try {
      payload = await this.jwt.verifyAsync(token, {
        secret: this.config.get<string>('JWT_ACCESS_SECRET'),
      });
    } catch {
      throw new UnauthorizedException('登录已过期，请重新登录');
    }
    if (payload.type !== 'access' || !payload.sub || !payload.jti) {
      throw new UnauthorizedException('令牌类型错误');
    }

    // 会话登记校验（登出/轮换后立即失效；被新设备登录顶掉则明确提示，docs/04 单设备会话）
    const session = await this.dataSource.getRepository(AuthToken).findOne({
      where: { jti: payload.jti },
    });
    if (!session) {
      throw new UnauthorizedException('登录已失效，请重新登录');
    }
    // 会话种类以库中登记为准（令牌载荷里的 kind 只作观测，不参与判定）
    const kind: AuthTokenKind =
      session.kind === 'companion' ? 'companion' : session.kind === 'recharge' ? 'recharge' : 'primary';

    /**
     * ==================== primary 会话的封禁判定（2026-10-16 负责人需求）====================
     *
     * 缺口（负责人原话：「我设置封禁的号为啥没有直接被踢下线」）：companion / recharge 两条受限会话
     * **每请求实时查库**校验账号未封禁，而 primary（老板/打手正常登录）这条**主路径**
     * 历史上只校验了会话登记（`auth_token` 行 + revoked + 过期），**从未加载 `user.status`**
     * —— 封禁实际只剩"吊销令牌"一道防线，某条路径忘了吊销就是完全不生效
     * （COMPANION 侧那条 `user.status=1` 是 2026-10-06 才补的，primary 一直缺）。
     *
     * 判定实现**不在本文件**：`modules/auth/account-ban.check.ts` 的 `checkAccountBan()`
     * （与 `AuthService.assertNotBanned` 共用同一句纯判定 + 同一句文案构造；安全审计 F1 的教训：
     * 同一规则写两份必然分叉）。本处只负责"哪种会话受影响"：
     * **`kind='primary'`** —— companion / recharge 各自的 check 里已含 `user.status`，不重复查。
     *
     * ⚠️ **位置必须先于下面 revoked=1 的分支**（这是本次的关键，不是随手放的）：
     * 封禁的落地动作之一就是"吊销该账号全部会话"（`revoked=1`），于是**被封的令牌连文案都走不到
     * 封禁分支**就会被 `revoked=1` 拦下、返回那句与"自己退出登录"一模一样的
     * 「登录已失效，请重新登录」—— 用户看到这句话根本不知道自己被封了、更看不到原因
     * （这正是缺口 1）。因此先判封禁：**封禁期间一律给封禁文案 + 机器码**，
     * `revoked=1` 退化成"封禁失效之后"（解封后旧令牌仍被吊销）的第二道防线。
     *
     * 到期自动解封：`checkAccountBan` 里顺手复位（`status=1` + `banned_until=NULL` + `ban_reason=NULL`），
     * 与 `AuthService.assertNotBanned` 的既有"到期登录时自动解封"**是同一件事**，不造第二套。
     *
     * 机器码：`ACCOUNT_BANNED`（客户端据此程序化识别，**不靠文案匹配**），
     * 透传沿用既有机制（`AllExceptionsFilter` 把 `errorCode` 原样写进响应体）。
     *
     * 代价：primary 会话每请求多 **一条按主键的单行 SELECT**（无 JOIN、无全表扫、无 N+1）；
     * 仅当恰好在这次请求跨过封禁到期时刻才多一条幂等 UPDATE。
     */
    if (kind === 'primary') {
      const ban = await checkAccountBan(this.dataSource, String(session.userId));
      if (ban.decision === 'banned') {
        throw new UnauthorizedException({
          message: ban.message ?? '账号已被封禁',
          errorCode: ACCOUNT_BANNED_CODE,
        });
      }
    }

    if (session.revoked === 1) {
      throw new UnauthorizedException(
        kind === 'primary'
          ? '登录已失效，请重新登录'
          : kind === 'companion'
            ? COMPANION_GONE
            : '受限管理身份已失效，请重新绑定管理员账号',
      );
    }
    if (session.revoked === 2) {
      throw new UnauthorizedException(
        kind === 'primary'
          ? '账号已在其他设备登录'
          : kind === 'companion'
            ? '伴随身份已失效（该打手账号已在别处登录），请重新绑定'
            : '受限管理身份已失效（该管理员账号已在别处登录），请重新绑定',
      );
    }
    // 主体绑定：令牌 sub 必须与会话登记的用户一致。
    // 仅校验「jti 存在」是不够的——签名密钥一旦泄露，攻击者可拿任一有效 jti
    // 搭配任意 sub 伪造身份（实测可冒用他人）。此处把身份钉死在会话记录上。
    if (String(session.userId) !== String(payload.sub)) {
      throw new UnauthorizedException('登录已失效，请重新登录');
    }
    // 会话寿命校验：令牌不得超出会话登记的到期时间。
    // 否则签名密钥泄露时，可用截获的 jti 铸造一张超长期令牌，
    // 在原令牌 2 小时过期后仍持续有效（实测可复现）。
    if (session.expireAt && new Date(session.expireAt).getTime() < Date.now()) {
      throw new UnauthorizedException(
        kind === 'primary'
          ? '登录已过期，请重新登录'
          : kind === 'companion'
            ? COMPANION_GONE
            : '受限管理身份已过期，请重新绑定管理员账号',
      );
    }

    // companion 专属：绑定有效性（每请求实时查库） + 接口族白名单
    if (kind === 'companion') {
      // 校验实现**不在本文件**：与 WS 网关共用 `checkCompanionSession`（见该文件顶部说明）
      const check = await checkCompanionSession(this.dataSource, {
        bindingId: session.bindingId,
        userId: String(session.userId),
      });
      if (!check.ok) {
        throw new UnauthorizedException(check.message);
      }
      if (!isCompanionAllowedRoute(request.method, request.path)) {
        throw new ForbiddenException(COMPANION_FORBIDDEN);
      }
    }

    // recharge 专属（受限充值管理员）：白名单/封禁有效性（每请求实时查库） + 接口族白名单
    if (kind === 'recharge') {
      // 校验实现同样只有一份：`checkRechargeSession`（HTTP 守卫与 WS 网关共用）
      const check = await checkRechargeSession(this.dataSource, { userId: String(session.userId) });
      if (!check.ok) {
        // **移出白名单 / 账号被封禁 → 立即 401 中文**（不等令牌过期，也不需要重新登录）
        throw new UnauthorizedException(check.message);
      }
      if (!isRechargeAdminAllowedRoute(request.method, request.path)) {
        throw new ForbiddenException(RECHARGE_ADMIN_FORBIDDEN);
      }
    }

    /**
     * ==================== 工作端到期收口（2026-10-06 定案）====================
     * 到期后（`system_setting.worker_app_sunset_at`，默认 `2026-10-13 00:00` Asia/Shanghai）
     * **worker 的 primary 会话**一律 401 中文：`/worker/*`、`/user/*` 以及其余全部受保护接口。
     *
     * 判定**不在本文件**：读配置 + 判断都在 `modules/auth/worker-app-sunset.ts`
     * （与 `AuthService.login`、`RealtimeGateway` 共用同一函数；安全审计 F1 的教训：
     * 同一规则写两份必然分叉）。本处只负责"哪种会话受影响"这一句：
     * **必须同时满足 `kind='primary'` 且 `role='worker'`**，
     * 因为老板端「打手态」的 companion 会话 `role` **也是 worker** ——
     * 它正是工作端的替代品，**必须照常可用**（本次最重要的一条不变量）。
     * 老板端（user）/ 管理端（admin）/ 受限充值会话（recharge）同样一概不受影响。
     */
    if (isWorkerPrimarySession(kind, session.role || payload.role)) {
      const sunset = await checkWorkerAppSunset(this.dataSource);
      if (sunset.sunset) {
        throw new UnauthorizedException(WORKER_APP_SUNSET_GONE);
      }
    }

    request.user = {
      userId: String(session.userId),
      // 角色同样以会话登记为准，不信任令牌载荷（防自签提权）
      role: session.role || payload.role || '',
      jti: payload.jti,
      kind,
      bindingId: session.bindingId ? String(session.bindingId) : null,
    } satisfies AuthUser;
    return true;
  }
  private extractBearer(request: { headers?: Record<string, unknown> }): string | null {
    const auth = request.headers?.['authorization'];
    if (typeof auth === 'string' && auth.startsWith('Bearer ')) {
      return auth.slice(7);
    }
    return null;
  }
}

/**
 * companion 接口族白名单（纯函数，便于单测/复查）。
 *
 * 入参 `path` 为 Express 的 `request.path`（含全局前缀 `/api/v1`），这里先剥掉前缀再比对，
 * 因此路由前缀变更（如 /api/v2）不会让白名单静默失效。
 */
export function isCompanionAllowedRoute(method: string, path: string): boolean {
  const m = String(method ?? 'GET').toUpperCase();
  const p = String(path ?? '').replace(/^\/api\/v\d+/, '') || '/';

  // 打手侧全部接口（大厅/抢单/派单确认/开始/提交/我的订单/收益/待遇/客服/排行榜）
  if (p === '/worker' || p.startsWith('/worker/')) return true;

  // 消息：客服会话（老板/客服两段）与会话消息读写；打手态消息页的唯一数据源
  // - `POST /user/conversations/:id/read`（一键已读 REST 兜底，2026-10-06 缺口 3）由下面的
  //   `/user/conversations/*` 前缀规则**一并放行**（打手态也要能一键已读 → 显式记录在案，避免被误删）
  if (p === '/user/conversation' || p.startsWith('/user/conversation/')) return true;
  if (p === '/user/conversations' || p.startsWith('/user/conversations/')) return true;

  /**
   * 好友（打手态消息页的【好友】段，负责人 2026-10-06）：**只放行两条读/开会话路径**。
   *
   * 为什么是这两条：
   * - `GET /user/friends`：好友列表。老板态消息页早已不拉它（2026-10-05 起改由 `/user/conversations`
   *   的 `type` 分区），但打手态要做"该账号确实有好友（会话）时才显示好友段"，需要一条好友维度的数据源；
   *   工作端消息页的好友段也是这一条（`apps/worker-app/lib/pages/messages_page.dart`）。
   * - `POST /user/friends/:userId/conversation`：打开会话。这是**取会话 id** 的路径（"打开与好友的会话"），
   *   服务端 `FriendService.openConversation` 先查 `status='accepted'` 的好友关系，不是好友直接 400
   *   —— 因此它**不可能**借由 companion 建立任何新的好友关系，只是把已有好友关系映射成会话 id。
   *
   * 好友消息的**历史/发送/未读**全部走 `/user/conversations*`（上面已放行），这里不再重复开口子。
   * 其余 `/user/friends*` 一律落到函数末尾的默认拒绝（403 中文）：
   * `GET /user/friends/search`（搜索用户）、`GET|POST /user/friends/requests*`（申请/同意/拒绝）、
   * `DELETE /user/friends/:userId`（删好友）—— 这些都是**好友关系的写能力或加好友流程**，
   * companion 永远不能碰（负责人不变量）。
   */
  if (m === 'GET' && p === '/user/friends') return true;
  if (m === 'POST' && /^\/user\/friends\/[^/]+\/conversation$/.test(p)) return true;

  // 资料**读**（公开资料页）；写资料/改 ID 属于账号级写操作 → 明确排除
  if (m === 'GET' && (p === '/user/profile' || p.startsWith('/user/profile/'))) return true;

  // 聊天图片等媒体（上传 + 受保护读取）
  if (p === '/media' || p.startsWith('/media/')) return true;

  // 会话自身：我是谁 / 登出 / 续期（改密码 /auth/password 明确排除）
  if (m === 'GET' && p === '/auth/me') return true;
  if (m === 'POST' && p === '/auth/logout') return true;
  if (m === 'POST' && p === '/auth/refresh') return true;

  // 默认拒绝：/user/identity/*（绑定管理）、/user/orders、/user/wallet、/user/tips、
  // /user/refunds、/user/complaints、/user/friends* 的写路径与加好友流程（搜索/申请/同意/拒绝/删除）、
  // /user/notifications*、/user/ai/*、/admin/* 等一律 403
  return false;
}

/**
 * 受限充值管理员会话（`kind='recharge'`）的接口族白名单（纯函数，便于单测/复查）。
 *
 * 入参 `path` 为 Express 的 `request.path`（含全局前缀 `/api/v1`），先剥前缀再比对，
 * 与 [isCompanionAllowedRoute] 完全同构（路由前缀变更不会让白名单静默失效）。
 *
 * 放行清单（负责人定案，**逐条对应**，不多不少）：
 * 1. `/recharge/*` —— 充值审核族：`GET /recharge/requests`、`POST /recharge/requests/:id/grant|reject`、
 *    `GET /recharge/me`、`GET /recharge/proof/:requestId`（凭证图片，见下方说明）；
 * 2. `GET /auth/me` —— 客户端进入管理员态后确认"我是谁"；
 * 3. `POST /auth/logout` —— 退出管理员态（吊销本条受限会话）；
 * 4. `POST /auth/refresh` —— 12h 窗口内续期（续期时同样的白名单校验照跑）。
 *
 * **关于 `/recharge/proof/:requestId`（相册式凭证读取）**：负责人给的放行清单里没有 `/media/*`，
 * 而"管理员核对转账截图"是整条业务链路的必要环节（列表只回 url 是不够的，图必须能看到）。
 * 两条路可选：① 把 `/media/protected/*` 加进白名单 —— 但 `MediaController` 对 `role='admin'`
 * 放行**任意**受保护媒体（聊天图片也在内），受限会话不该拿到这个面；
 * ② 在 `/recharge/*` 内部开一条"只能看这张申请的那张图"的窄通道 —— 本实现选 ②，
 * 它严格落在负责人给的 `/recharge/*` 前缀之内，权限面最小。
 * 详见 docs/待确认事项.md「充值凭证图片的读取通道」。
 */
export function isRechargeAdminAllowedRoute(method: string, path: string): boolean {
  const m = String(method ?? 'GET').toUpperCase();
  const p = String(path ?? '').replace(/^\/api\/v\d+/, '') || '/';

  // 1. 充值审核族（唯一业务族；新增充值接口时**默认**落进这条前缀即被放行，
  //    因此新接口必须自己在 Controller 层做主体/权限校验，不要依赖白名单收窄）
  if (p === '/recharge' || p.startsWith('/recharge/')) return true;

  /**
   * 2. **提现审核族**（负责人 2026-10-11：App 内「管理员身份」也要能处理提现）。
   *
   * ⚠️ 本条是**显式新增**的：受限会话是**允许清单**，不加这一条则 `/withdraw/*` 整族 403 中文
   * （这正是"允许清单而不是黑名单"的设计意图 —— 新接口默认对外关闭，必须显式打开）。
   *
   * 放行的是 `/withdraw/*` 这一族（列表/详情/收款码与打款凭证取图/打款/驳回），
   * 与 `/recharge/*` 完全同构：Controller 层仍要过 `withdraw:review` / `withdraw:pay`
   * 两个窄权限点（`PermissionsGuard`），且**没有**配置写入接口（改门槛只走管理端 primary 会话）。
   *
   * **打款凭证上传已天然覆盖，因此本条一个字都不用改**（2026-10-11）：
   * App 内管理员态传图走 `POST /withdraw/requests/:id/pay-proof`（multipart），
   * 落在本前缀内 → 白名单无需新增条目；**尤其没有**顺手把 `/media/*` 放开
   * （`/media/protected/:id` 对 `role=admin` 放行任意受保护媒体，受限会话不该拿到这个面）。
   * 写侧同样被收窄到"这一张申请"：服务层要求该申请存在且 `status='pending'`
   * （已打款 → 中文 400），文件沿用 `MediaService` 既有校验、用途固定 `withdraw_proof`。
   */
  if (p === '/withdraw' || p.startsWith('/withdraw/')) return true;

  // 3~5. 会话自身：我是谁 / 登出 / 续期（改密码 /auth/password 明确排除）
  if (m === 'GET' && p === '/auth/me') return true;
  if (m === 'POST' && p === '/auth/logout') return true;
  if (m === 'POST' && p === '/auth/refresh') return true;

  // 默认拒绝：/admin/*（含 /admin/recharge/*、/admin/withdraw/*）、/user/*（订单/钱包/身份/资料/通知/AI）、
  // /media/*、/auth/password、/worker/* 等一律 403 中文
  return false;
}
