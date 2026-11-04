import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';
import { User } from './user.entity';
import { mapMoney } from '../../common/money.transformer';
import {
  ACCOUNT_BANNED_CODE,
  buildBanMessage,
  normalizeBanReason,
} from '../auth/account-ban.check';
import { BindingReleaseService } from '../auth/binding-release.service';
import { ReleaseSink } from '../auth/worker-binding-release';

/**
 * 用户管理（负责人需求）：仅管理老板端/工作端账号（管理员账号走「管理员与角色」模块）。
 * - 封号：自定义时长（天）或永久；封禁即吊销全部会话（REST 401 + WS 心跳踢下线）+ **顺手解绑名下全部绑定**（2026-10-06）
 * - 到期自动解封：封禁到期后首次登录自动恢复（无需定时任务）；**解封不自动恢复绑定**
 * - 删除：事务内清理该账号全部个人数据（会话/聊天/AI 咨询/好友/钱包/工作档案等）
 *   + **事务内释放名下全部绑定（两侧）**；订单、结算、登录日志等业务与审计记录保留（防账务断链）
 */
@Injectable()
export class UserAdminService {
  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectDataSource() private readonly dataSource: DataSource,
    /** 释放绑定（置 unbound + 吊销 companion 令牌 + 写 identity 审计 + 断开 WS）——F1/F4 修复后的唯一入口 */
    private readonly bindingRelease: BindingReleaseService,
  ) {}

  async list(q: { page: number; pageSize: number; keyword?: string; role?: string }) {
    const qb = this.dataSource
      .createQueryBuilder(User, 'u')
      .leftJoin('wallet', 'w', 'w.user_id = u.id')
      .select([
        'u.id AS id', 'u.username AS username', 'u.uid AS uid', 'u.nickname AS nickname',
        'u.role AS role', 'u.status AS status', 'u.banned_until AS bannedUntil',
        'u.level AS level', 'u.last_login_at AS lastLoginAt', 'u.created_at AS createdAt',
        'COALESCE(w.balance, 0) AS balance',
      ])
      .where('u.role IN (:...roles)', { roles: ['user', 'worker'] });
    if (q.role === 'user' || q.role === 'worker') {
      qb.andWhere('u.role = :role', { role: q.role });
    }
    if (q.keyword) {
      qb.andWhere('(u.username LIKE :kw OR u.uid LIKE :kw OR u.nickname LIKE :kw)', { kw: `%${q.keyword}%` });
    }
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb.orderBy('u.id', 'DESC').offset((q.page - 1) * q.pageSize).limit(q.pageSize).getRawMany();
    return { list: list.map((r) => mapMoney(r, ['balance'])), total: Number(total?.cnt ?? 0), page: q.page, pageSize: q.pageSize };
  }

  /**
   * 封号：days 为空 → 永久；days>0 → 封禁至 now+days 天。吊销全部会话（立即踢下线）。
   *
   * **封禁即解绑（对称，负责人 2026-10-06 裁决）**：被封账号的两侧 active 绑定都要顺手置 `unbound`
   * （写 `unbound_at`，保留历史行）：
   * - 该账号**作为打手**被老板绑着（`worker_user_id`）—— 否则老板侧 `GET /user/identity` 仍显示"已绑定"；
   * - 该账号**作为老板**绑着打手（`boss_user_id`）—— 这是**不对称缺口的来源**：老板被封禁时只释放打手侧，
   *   其名下的伴随会话仍然可用（实测「封禁老板 → companion 请求 200 → 200，releasedBindings=0」）。
   *
   * 语句顺序刻意是「封禁 → 吊销会话 → 解绑」：前两步是安全关键（少一步 = 被封账号还能用），
   * 第三步是语义收口 + 让 companion 依赖的绑定立即失效；这样即使第三步抛错（500 被管理员看到并重试），
   * 也**不会**削弱封禁效果。
   * 本路径原本没有事务，按裁决**不为它新开事务**（同一请求内同步串行执行）。
   *
   * ⚠️ **`auth_token` 行的 `user_id` 归属（审计 F1 纠正的错误假设，2026-08-06 复核）**：
   * companion 会话的 `user_id` 是**打手**账号（`auth_token.user_id = 打手 user_id`，`kind='companion'`，
   * 另有 `binding_id` 指向绑定行）——**不是**老板。
   * 所以下面这条 `WHERE user_id = 该账号` 的吊销：
   * - 封**打手**时命中它自己的 primary + companion（本来就该全吊销）；
   * - 封**老板**时**扫不到**老板名下那条 companion（它的 user_id 是打手）→ 必须靠
   *   `BindingReleaseService.releaseBoth()` 里**按 `binding_id`** 的吊销兜住（F1-b 已实现，实测有效）。
   * 旧注释曾写「companion 会话同属该 user_id，一并被吊销」，与事实相反，已删除——别再按那个假设写代码。
   */
  async ban(id: string, dto: { days?: number | null; reason?: string }, actor?: BanReleaseActor) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('账号不存在');
    if (user.role === 'admin') throw new BadRequestException('管理员账号请在「管理员与角色」页面管理');
    let bannedUntil: Date | null = null;
    if (dto.days != null) {
      if (!Number.isFinite(dto.days) || dto.days < 1 || dto.days > 36500) {
        throw new BadRequestException('封禁时长须为 1-36500 天');
      }
      bannedUntil = new Date(Date.now() + Math.floor(dto.days) * 86400_000);
    }
    /**
     * **封禁原因落库**（2026-10-16 缺口 3）：原因此前**只在 `operation_log` 里**，
     * `user` 表没有原因列 → 客户端"显示被封原因"没有数据源。
     * 清洗（trim + 按字符截断 200 + 空串归 NULL）只有一份：`normalizeBanReason()`。
     */
    const banReason = normalizeBanReason(dto.reason);
    await this.userRepo.update(id, { status: 2, bannedUntil, banReason });

    /**
     * 吊销该账号**自身**的全部会话（primary + 它作为打手的 companion）：
     * 在线端下一次 API 请求 401；WS 由下面的 `kickRevoked` **立即断开**（不等心跳，≈秒级）。
     * 注意：**老板名下那条 companion 的 user_id 是打手**，不在这条语句的命中范围 —— 它由下一步
     * 按 binding_id 吊销（见方法头注释的纠错说明）。
     *
     * 为什么先 `SELECT jti` 再 UPDATE（2026-10-16 秒踢）：`disconnectByJti` 按 jti 找连接，
     * 而吊销语句本身不返回 jti —— 不先取一次就只能等客户端下一次心跳
     * （socket.io pingInterval 25s），那是"最长 25 秒才断"，不是负责人要的"秒踢"。
     */
    const ownJtis = await this.selectRevocableJtis(id);
    await this.dataSource.query(`UPDATE auth_token SET revoked = 1 WHERE user_id = ? AND revoked = 0`, [id]);
    /**
     * 立即断开该账号自己的会话（primary + 它作为打手的 companion）。
     * 载荷带上**封禁文案 + 机器码**：WS 侧客户端据此弹同一句「账号已被封禁：<原因>（…）」，
     * 而不是等下一次 HTTP 请求（用户可能正停在消息页不动，只有 WS 在跑）。
     * 断开机制本身是既有唯一实现（`BindingReleaseService.kickRevoked` → `RealtimeGateway.disconnectByJti`），
     * 这里只是**带上载荷**，不复制第二份踢线逻辑。
     */
    this.bindingRelease.kickRevoked(ownJtis, {
      message: buildBanMessage(banReason, bannedUntil),
      errorCode: ACCOUNT_BANNED_CODE,
    });
    // 封禁即解绑（两侧，见方法头注释；只动 active 行，unbound 历史行保留）
    // + 按 binding_id 吊销 companion 会话 + 写 identity 审计 + 主动断开这些会话的 WS（F1/F4）
    const released = await this.bindingRelease.releaseBoth(id, {
      source: 'user-banned',
      actorUserId: actor?.adminUserId ?? null,
      actorLabel: actor?.adminUserId ? `admin:${actor.adminUserId}` : null,
      ip: actor?.ip ?? null,
      userAgent: actor?.userAgent ?? null,
    });
    return {
      ok: true,
      permanent: bannedUntil === null,
      bannedUntil: bannedUntil ? bannedUntil.toISOString() : null,
      /** 本次记录的封禁原因（NULL = 未填；纯新增字段，客户端可忽略） */
      banReason,
      /** 本次释放的绑定总数（0 = 该账号两侧都没有生效中的绑定；纯新增字段，客户端可忽略） */
      releasedBindings: released.total,
      /** 其中：该账号作为**打手**被释放的行数（`worker_user_id = 该账号`） */
      releasedAsWorker: released.workerSide,
      /** 其中：该账号作为**老板**被释放的行数（`boss_user_id = 该账号` → 其名下 companion 立即失去绑定） */
      releasedAsBoss: released.bossSide,
    };
  }

  /**
   * 取该账号**当前可吊销**的全部会话 jti（`revoked = 0`）。
   *
   * 只服务"封禁后立即断开 WS"这一件事：`disconnectByJti` 的索引是 jti，
   * 而吊销语句（`UPDATE ... WHERE user_id = ?`）不返回 jti。
   * 按 `user_id` 主外键关系查（`auth_token` 有 `user_id` 索引），**不是**全表扫；
   * 一个账号的有效会话通常 1–2 行（单设备铁律：primary 互斥）。
   */
  private async selectRevocableJtis(userId: string): Promise<string[]> {
    const raw: unknown = await this.dataSource.query(
      `SELECT jti FROM auth_token WHERE user_id = ? AND revoked = 0`,
      [userId],
    );
    const rows = (Array.isArray(raw) && Array.isArray(raw[0]) ? raw[0] : raw) as Array<{ jti: string }> | undefined;
    return Array.isArray(rows) ? rows.map((r) => String(r.jti)) : [];
  }

  /**
   * 解封（管理员提前解除，或到期手动恢复）。
   *
   * ⚠️ **解封不自动恢复绑定**（负责人 2026-10-06 裁决）：`unbound` 行绝不在这里翻回 active ——
   * 需要老板在老板端**重新输打手账密绑定**（`POST /user/identity/bind`）。理由：封禁期间该打手账号
   * 的密码可能已按安全流程处理、账号也可能已被别人绑定，静默恢复会出现"打手态突然又能进了"的越权面。
   */
  async unban(id: string) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('账号不存在');
    if (user.status !== 2) throw new BadRequestException('该账号未被封禁');
    /**
     * **解封必须清空 `ban_reason`**（2026-10-16）：残留旧原因会在下一次封禁时被展示成
     * 「账号已被封禁：<上一次的原因>」——那是误导性文案（用户会按错的原因申诉）。
     * 到期自动解封（`checkAccountBan` 的 expired 分支）用同一口径清空。
     */
    await this.userRepo.update(id, { status: 1, bannedUntil: null, banReason: null });
    return { ok: true };
  }

  /**
   * 删除账号（老板/工作端）：清理个人数据，保留订单/结算/登录日志等业务审计记录。
   *
   * **删除即释放绑定（两侧，负责人 2026-10-06 裁决 · 缺口 2）**：在**既有事务内**调用 `releaseUserBindings`
   * （与封禁路径同一个助手），把 `worker_user_id = 被删` 与 `boss_user_id = 被删` 的 active 绑定都置
   * `unbound`（**历史行保留**，不物理删除）。不释放的后果（实测）：
   * - 老板侧 `GET /user/identity` 报 400「打手档案不存在」（`workerSummary` 找不到被删的打手档案）；
   * - 该打手名额被**永久占用**（active 行还在 → 唯一键 `UK_wib_active_worker` 挡住重新绑定）。
   * 释放后名额由生成列唯一键自动让出（unbound 行不占名额）→ 可重新绑定。
   *
   * 安全审计 F1-b / F4：释放走 `BindingReleaseService.releaseBothInTx()` —— 除置 unbound 外，
   * 还会**按 `binding_id` 吊销该绑定的 companion 令牌**（否则被删老板名下的伴随会话在 WS 上还活着）
   * 并写 identity 审计。WS 断开放在**事务提交后**（回滚时不该踢线）。
   */
  async deleteUser(id: string, actor?: BanReleaseActor) {
    const user = await this.userRepo.findOne({ where: { id } });
    if (!user) throw new NotFoundException('账号不存在');
    if (user.role === 'admin') throw new BadRequestException('管理员账号请在「管理员与角色」页面管理');
    const { released, revokedJtis } = await this.dataSource.transaction(async (em) => {
      // 绑定（两侧释放：置 unbound + 按 binding_id 吊销 companion 令牌 + 写 identity 审计；
      // 见方法头注释。放在事务最前：与后面的个人数据清理同生共死）
      const rel = await this.bindingRelease.releaseBothInTx(em, id, {
        source: 'user-deleted',
        actorUserId: actor?.adminUserId ?? null,
        actorLabel: actor?.adminUserId ? `admin:${actor.adminUserId}` : null,
        ip: actor?.ip ?? null,
        userAgent: actor?.userAgent ?? null,
      });
      // 会话
      await em.query('DELETE FROM auth_token WHERE user_id = ?', [id]);
      // 聊天：指派（本人为客服 + 本人会话的指派）→ 消息 → 会话（本人或对方）
      await em.query(
        `DELETE FROM chat_conversation_assign WHERE worker_user_id = ?
         OR conversation_id IN (SELECT id FROM chat_conversation WHERE user_id = ? OR peer_user_id = ?)`,
        [id, id, id],
      );
      await em.query('DELETE FROM chat_message WHERE sender_id = ?', [id]);
      await em.query('DELETE FROM chat_conversation WHERE user_id = ? OR peer_user_id = ?', [id, id]);
      // AI 咨询「祁小山」：消息 → 会话（会话按 user_id 一人一条；消息归属同 user_id）
      await em.query('DELETE FROM ai_message WHERE user_id = ?', [id]);
      await em.query('DELETE FROM ai_conversation WHERE user_id = ?', [id]);
      // 好友与系统通知（申请/关系两个方向）
      await em.query('DELETE FROM user_friend WHERE requester_id = ? OR addressee_id = ?', [id, id]);
      await em.query('DELETE FROM user_notification WHERE user_id = ?', [id]);
      // 玩家圈（论坛）已于 2026-10-05 整体下线：模块与路由已删除，此处**不再清理 forum_* 表**，
      // 表与历史数据一律保留（负责人要求：删功能不删库；如需彻底清库须单独批准）。
      // 反馈与等级流水
      await em.query('DELETE FROM user_feedback WHERE user_id = ?', [id]);
      await em.query('DELETE FROM user_level_log WHERE user_id = ?', [id]);
      // 工作端档案：首页打手展示、榜单、统计、档案（订单保留，历史订单展示打手编号不受影响）
      const workers: Array<{ id: string }> = await em.query('SELECT id FROM worker WHERE user_id = ?', [id]);
      for (const w of workers) {
        await em.query('DELETE FROM top_worker WHERE worker_id = ?', [w.id]);
        await em.query('DELETE FROM leaderboard_entry WHERE worker_id = ?', [w.id]);
        await em.query('DELETE FROM worker_stats WHERE worker_id = ?', [w.id]);
        /**
         * 打手等级 + 五维聚合（2026-10-17 新增的两张表，migration `1817000000000`）：
         * 它们是**派生状态**（"这个人现在几级 / 现在均分多少"），与 `worker_stats` 同一性质
         * —— 档案没了就必须一起消失，否则将来 worker.id 被复用时会凭空继承一个等级。
         * ⚠️ `worker_rating`（五维原始评分）**刻意保留**：那是历史评价数据，
         * 与上面**同样保留**的 `order_review` 同一口径（删功能不删历史数据）。
         */
        await em.query('DELETE FROM worker_grade WHERE worker_id = ?', [w.id]);
        await em.query('DELETE FROM worker_rating_agg WHERE worker_id = ?', [w.id]);
      }
      await em.query('DELETE FROM worker WHERE user_id = ?', [id]);
      // 钱包与流水
      await em.query('DELETE FROM wallet_transaction WHERE user_id = ?', [id]);
      await em.query('DELETE FROM wallet WHERE user_id = ?', [id]);
      // 账号本体
      await em.query('DELETE FROM user WHERE id = ?', [id]);
      return { released: rel, revokedJtis: rel.revokedJtis };
    });
    // 事务**提交成功后**才主动断开被吊销会话的 WS 连接（回滚时不该踢线：那些会话仍然有效）
    this.bindingRelease.kickRevoked(revokedJtis);
    return {
      ok: true,
      /** 本次释放的绑定总数（0 = 两侧都没有生效中的绑定） */
      releasedBindings: released.total,
      /** 其中：被删账号作为**打手**被释放的行数 */
      releasedAsWorker: released.workerSide,
      /** 其中：被删账号作为**老板**被释放的行数（其名下 companion 立即失去绑定） */
      releasedAsBoss: released.bossSide,
    };
  }
}

/**
 * 释放绑定的触发者上下文（审计 F4：解绑留痕要记"谁"）+ 请求侧证据（IP/UA）。
 * 控制器从 `@CurrentUser()` / `@Req()` 取；服务层可选传入（缺省时审计 reason 的 `by=` 记 `system`）。
 */
export interface BanReleaseActor {
  /** 管理员的 user id（admin 表的 user_id；与 `@CurrentUser().userId` 一致） */
  adminUserId?: string | null;
  ip?: string | null;
  userAgent?: string | null;
}
