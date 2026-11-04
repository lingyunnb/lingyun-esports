import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { InjectDataSource } from '@nestjs/typeorm';
import {
  OnGatewayConnection,
  OnGatewayDisconnect,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { DataSource } from 'typeorm';
import { checkCompanionSession } from '../modules/auth/companion-session.check';
import { ACCOUNT_BANNED_CODE, checkAccountBan } from '../modules/auth/account-ban.check';
import {
  checkWorkerAppSunset,
  isWorkerPrimarySession,
} from '../modules/auth/worker-app-sunset';

/**
 * 实时网关（docs/07）：namespace /ws/chat，Socket.IO。
 * - 握手 auth.token = JWT access token，校验失败立即断开
 * - 房间：uid:{userId}（本人消息/派单）；admin（管理端广播）
 * - 心跳：应用层 ping→pong；底层 keepalive 由 socket.io pingInterval/pingTimeout 兜底（约 45s 无帧即断，严于 docs/07 的 60s）
 * - 派单事件（docs/07）：dispatch:new / dispatch:expired（仅目标 worker）
 *
 * ============================ 会话有效性（安全审计 F1 修复）============================
 * 握手与心跳都必须做**与 HTTP 守卫同一套**校验，否则会出现"HTTP 已 401（绑定已释放/老板已封禁），
 * 而这条 WS 连接还能 join 房间、继续收到 msg:new 全文"的持续泄漏通道。校验实现**只有一份**：
 * `checkCompanionSession()`（`modules/auth/companion-session.check.ts`）—— 本网关与 `JwtAuthGuard` 共用，
 * 不在本文件里复制第二份 SQL（复制出来的第二份迟早与守卫分叉，这正是本次漏洞的根因）。
 * primary 会话另有**封禁判定**（2026-10-16「封禁秒踢」）：同样复用 `checkAccountBan()` 这一份实现，
 * 与守卫同构（见 [assertSessionActive]）；其余业务校验（会话登记/revoked/过期）与历史逐字一致。
 *
 * 受限充值管理员会话（`kind='recharge'`，2026-10-06）**在握手阶段直接拒绝**：
 * 它没有实时需求，且 role=admin 会被加进 `admin` 广播房间（越权面）。详见 [assertSessionActive]。
 *
 * 另外提供 `disconnectByJti()`：释放绑定/封禁/移出充值管理员白名单时**主动断开**对应会话的 WS 连接
 * （不等下一次心跳）。
 */
@WebSocketGateway({
  namespace: '/ws/chat',
  cors: { origin: true, credentials: true },
  pingInterval: 25000,
  pingTimeout: 20000,
})
export class RealtimeGateway implements OnGatewayConnection, OnGatewayDisconnect {
  private readonly logger = new Logger('Realtime');

  /** jti → 该会话的 WS 连接（同一令牌多设备时是多个 socket）；用于"释放/封禁后立即踢线" */
  private readonly socketsByJti = new Map<string, Set<Socket>>();

  @WebSocketServer()
  server!: Server;

  constructor(
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  async handleConnection(client: Socket): Promise<void> {
    try {
      const token = (client.handshake.auth as { token?: string } | undefined)?.token;
      if (!token) throw new Error('no token');
      // access token 使用 JWT_ACCESS_SECRET 显式校验（与签发同源，docs/04）
      const payload = await this.jwt.verifyAsync<{ sub: string; role: string; jti?: string }>(token, {
        secret: this.config.get<string>('JWT_ACCESS_SECRET'),
      });
      // 会话登记校验（docs/04 单设备会话：被顶掉/已登出的令牌不允许建立 WS）
      // 同时取回会话登记的角色：角色以库为准，不信任令牌载荷（防自签提权混入 admin 房间）
      const role = await this.assertSessionActive(String(payload.jti ?? ''), String(payload.sub));
      client.data.userId = String(payload.sub);
      client.data.role = role;
      client.data.jti = String(payload.jti ?? '');
      this.trackSocket(client.data.jti as string, client);
      await client.join(`uid:${payload.sub}`);
      if (role === 'admin') {
        await client.join('admin');
      }
      // 心跳即重校验会话：被新设备顶掉/登出/被封禁后最长一个心跳周期内踢下线
      client.on('ping', async () => {
        try {
          await this.assertSessionActive(String(client.data.jti ?? ''), String(client.data.userId ?? ''));
          client.emit('pong');
        } catch (e) {
          const reason = (e as Error).message;
          const replaced = reason === 'replaced';
          /**
           * 封禁（2026-10-16）：载荷带上文案与机器码，让"只开着 WS、没在发请求"的用户
           * 也能看到「账号已被封禁：<原因>（…）」而不是通用的「登录已失效」。
           * 文案同样出自唯一实现 `buildBanMessage`（经 `checkAccountBan` 返回），本文件不自己拼字符串。
           * 这一发查询只在**踢线那一刻**发生一次（不是每心跳），失败/已被解封时回落空载荷（= 历史行为）。
           */
          let payload: Record<string, unknown> = {};
          if (!replaced && reason === 'account-banned') {
            const ban = await checkAccountBan(this.dataSource, String(client.data.userId ?? ''));
            if (ban.decision === 'banned') {
              payload = { message: ban.message, errorCode: ACCOUNT_BANNED_CODE };
            }
          }
          client.emit(replaced ? 'auth:session-replaced' : 'auth:expired', payload);
          client.disconnect(true);
        }
      });
      this.logger.debug(`ws 连接 uid=${payload.sub} role=${payload.role} socket=${client.id}`);
    } catch {
      this.logger.warn(`ws 拒绝未认证连接 socket=${client.id}`);
      client.disconnect(true);
    }
  }

  /**
   * auth_token 会话登记校验（jti 存在且未吊销；被顶掉/登出即失效）。
   * jti 与 user_id 一并作为查询条件，身份钉死在会话记录上；
   * 返回会话登记的角色，供调用方以库为准判定权限。
   *
   * **companion 会话额外走与 HTTP 守卫同一套校验**（`checkCompanionSession`：绑定 active +
   * 打手即会话主体 + 打手未封禁/档案在职 + 老板未封禁）——握手与心跳都调用本方法，
   * 因此"绑定被释放/老板被封禁"时：新连接被拒、老连接在下一次心跳被踢（并被 `disconnectByJti`
   * 主动即时断开）。**primary 会话不查绑定**（与历史一致），但**要查封禁**
   * （`checkAccountBan`，2026-10-16「封禁秒踢」：与 HTTP 守卫同一条实现与同一条防线语义）。
   * **recharge（受限充值管理员）会话直接拒绝**（无实时需求 + role=admin 会 join 管理端广播房间）。
   */
  private async assertSessionActive(jti: string, userId: string): Promise<string> {
    if (!jti) throw new Error('no jti');
    const raw: unknown = await this.dataSource.query(
      `SELECT revoked, role, kind, binding_id AS bindingId, expire_at AS expireAt
         FROM auth_token WHERE jti = ? AND user_id = ? LIMIT 1`,
      [jti, userId],
    );
    // mysql2 原始结果可能是 [rows, fields]，防御性解包（与 log.controller 的 unwrapRows 一致）
    const rows = (Array.isArray(raw) && raw.length >= 1 && Array.isArray(raw[0]) ? raw[0] : raw) as Array<{
      revoked: number;
      role: string;
      kind: string | null;
      bindingId: string | number | null;
      expireAt: Date | string;
    }>;
    const row = rows[0];
    if (!row || Number(row.revoked) === 1) throw new Error('expired');
    if (Number(row.revoked) === 2) throw new Error('replaced');
    // 会话寿命：WS 连接不得超出会话登记的到期时间（防用截获 jti 铸造超长期令牌）
    if (row.expireAt && new Date(row.expireAt).getTime() < Date.now()) throw new Error('expired');
    // 伴随会话：复用 HTTP 守卫那份校验（**不复制 SQL**）；任一不满足 → 拒绝握手 / 心跳踢线
    if (String(row.kind ?? '') === 'companion') {
      const check = await checkCompanionSession(this.dataSource, {
        bindingId: row.bindingId === null || row.bindingId === undefined ? null : String(row.bindingId),
        userId: String(userId),
      });
      if (!check.ok) {
        this.logger.warn(`ws companion 会话不可用（${check.reason}）jti=${jti} uid=${userId}`);
        throw new Error('companion-gone');
      }
    }
    // 受限充值管理员会话（2026-10-06）：**直接拒绝握手**，不走心跳。
    //
    // 为什么是"拒绝"而不是"像 companion 那样校验后放行"：
    // 1. 受限会话没有任何实时需求（充值审核是纯 REST 流程）；
    // 2. 它的 role 就是 `admin` → 放进来会立刻 `join('admin')` 房间，从而收到**管理端广播**
    //    （新订单/派单等）——这是明确的越权面，与"权限仅限充值相关"直接冲突；
    // 3. 白名单默认拒绝的同一思路：不需要的能力**默认关闭**，而不是"校验一下再开"。
    // 被移出白名单时 `RechargeService.removeAdmin()` 仍会调 `disconnectByJti`（防御性：若将来
    // 有人放开这里，踢线逻辑已经就位，不必再补一次）。
    if (String(row.kind ?? '') === 'recharge') {
      this.logger.warn(`ws 拒绝受限管理会话（该会话无实时能力）jti=${jti} uid=${userId}`);
      throw new Error('recharge-not-allowed');
    }
    /**
     * 工作端到期收口（2026-10-06 定案）：到期后 **worker 的 primary 连接**握手直接拒绝、
     * 心跳（每个 ping 都走本方法）重校验后踢线。判定**只有一份** ——
     * `modules/auth/worker-app-sunset.ts` 的 `checkWorkerAppSunset()`，与 `JwtAuthGuard` /
     * `AuthService.login` 共用（不在本文件复制第二份 SQL 或日期比较；F1 的根因就是"网关另写一套"）。
     *
     * **companion（老板端打手态）不受影响**：它的 `kind` 是 companion（上面已单独校验绑定有效性），
     * `isWorkerPrimarySession()` 只认 `kind='primary'`，因此打手态的实时能力（消息/派单）照常。
     * 代价：worker primary 连接每次心跳多一条 `system_setting` 主键级 SELECT（唯一索引），
     * 换来"改配置下一次心跳即生效"，与全站"权限/绑定实时查库"同一口径。
     */
    if (isWorkerPrimarySession(row.kind, row.role)) {
      const sunset = await checkWorkerAppSunset(this.dataSource);
      if (sunset.sunset) {
        this.logger.warn(`ws 拒绝工作端连接（工作端已到期 ${sunset.text}）jti=${jti} uid=${userId}`);
        throw new Error('worker-app-sunset');
      }
    }
    /**
     * **primary 会话的封禁判定**（2026-10-16 负责人需求「封禁秒踢」）——走到这里的会话
     * 既不是 companion（上面已校验绑定有效性）也不是 recharge（上面直接拒绝），**剩下的都是 primary**。
     *
     * 判定与文案构造**不在本文件**：`modules/auth/account-ban.check.ts` 的 `checkAccountBan()`
     * （与 `JwtAuthGuard` / `AuthService.assertNotBanned` 共用同一份实现，**不复制第二份 SQL**；
     * 这正是安全审计 F1 的教训）。
     *
     * 为什么 WS 侧也要这一条（HTTP 守卫已经有一条了）：
     * - 封禁的**主要**踢线动作是 `UserAdminService.ban()` → `disconnectByJti`（立即断开，秒级），
     *   且吊销令牌后新连接会被上面的 `revoked` 分支拒掉；
     * - 但"**忘了吊销令牌**"正是历史漏过的形态（只靠吊销 = 单点）——本守卫（每请求）与本方法
     *   （握手 + 每 25s 心跳）各查一次 `user.status`，把"漏吊销"从"封禁完全失效"降级为
     *   "最长一个心跳周期内断线"。两道防线并存，与 HTTP 侧同构。
     * 代价：每条 **primary** WS 连接每次心跳多一条按主键的单行 SELECT（companion/recharge 不受影响）。
     */
    if (String(row.kind ?? '') !== 'companion' && String(row.kind ?? '') !== 'recharge') {
      const ban = await checkAccountBan(this.dataSource, String(userId));
      if (ban.decision === 'banned') {
        this.logger.warn(`ws 拒绝被封禁账号的连接 jti=${jti} uid=${userId}`);
        throw new Error('account-banned');
      }
    }
    return String(row.role ?? '');
  }

  /** 登记 jti → socket（同一令牌可多连接） */
  private trackSocket(jti: string, client: Socket): void {
    if (!jti) return;
    const set = this.socketsByJti.get(jti) ?? new Set<Socket>();
    set.add(client);
    this.socketsByJti.set(jti, set);
  }

  /**
   * **主动断开**指定会话（jti）的全部 WS 连接：释放绑定 / 封禁 / 删除账号时由
   * `BindingReleaseService` 调用，不必等客户端下一次心跳（F1 修复要求"已连接的 WS 被主动断开"）。
   *
   * 先发 `auth:expired`（客户端据此清打手态/提示重新登录）再断开；返回实际断开的 socket 数。
   * 找不到连接不算错（该令牌可能根本没连过 WS）——真正的失效判定在库里，这里只是加速。
   *
   * @param payload 随事件下发的载荷（缺省 `{}` = 与历史逐字节一致）。
   *   封禁路径（2026-10-16）带 `{ message, errorCode: 'ACCOUNT_BANNED' }`：
   *   被踢的用户可能**正停在某个页面不发请求**（只有 WS 在跑），只发一个空事件的话
   *   客户端只能弹出通用的「登录已失效，请重新登录」——看不到"被封了、为什么被封"。
   *   文案与机器码的唯一构造出处：`modules/auth/account-ban.check.ts`。
   */
  disconnectByJti(
    jtis: Array<string | null | undefined>,
    event = 'auth:expired',
    payload: Record<string, unknown> = {},
  ): number {
    const uniq = [...new Set(jtis.map((j) => String(j ?? '')).filter((j) => j.length > 0))];
    let kicked = 0;
    for (const jti of uniq) {
      const set = this.socketsByJti.get(jti);
      if (!set || set.size === 0) continue;
      for (const s of Array.from(set)) {
        try {
          s.emit(event, payload);
        } catch {
          /* 连接已被对端关闭：忽略 */
        }
        try {
          s.disconnect(true);
        } catch {
          /* 同上 */
        }
        kicked += 1;
      }
      this.socketsByJti.delete(jti);
    }
    if (kicked > 0) {
      this.logger.log(`主动断开 WS：会话 ${uniq.length} 个 / socket ${kicked} 个（事件 ${event}）`);
    }
    return kicked;
  }

  handleDisconnect(client: Socket): void {
    const jti = String(client.data?.jti ?? '');
    const set = jti ? this.socketsByJti.get(jti) : undefined;
    if (set) {
      set.delete(client);
      if (set.size === 0) this.socketsByJti.delete(jti);
    }
    this.logger.debug(`ws 断开 uid=${String(client.data?.userId ?? '?')} socket=${client.id}`);
  }

  /** 推给指定用户（其全部设备） */
  emitToUser(userId: string | number, event: string, data: unknown): void {
    this.server?.to(`uid:${userId}`).emit(event, data);
  }

  /** 是否在线（任一设备连着 WS 即在线；好友列表在线状态展示用，2026-09-25）。
   *  注意：本网关注入的是 /ws/chat 命名空间（非默认命名空间），房间须从
   *  `server.adapter.rooms` 读取（命名空间的 sockets 是 Map，没有 adapter）。 */
  isOnline(userId: string | number): boolean {
    try {
      const rooms = (this.server?.adapter as { rooms?: Map<unknown, unknown> } | undefined)?.rooms;
      const s = rooms?.get(`uid:${userId}`);
      return !!s && (s as Set<unknown>).size > 0;
    } catch (_) {
      return false;
    }
  }

  /** 推给全部在线管理员 */
  emitToAdmins(event: string, data: unknown): void {
    this.server?.to('admin').emit(event, data);
  }

  /** 广播给全部在线连接（首页内容更新等全局事件，需求：管理端改完 App 立即同步） */
  emitToAll(event: string, data: unknown): void {
    this.server?.emit(event, data);
  }
}
