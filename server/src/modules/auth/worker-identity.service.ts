import {
  BadRequestException,
  ForbiddenException,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
} from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, EntityManager, Repository } from 'typeorm';

import { RateLimitService } from '../../common/rate-limit.service';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { Worker } from '../worker/worker.entity';
import { WorkerDivisionPermissionService } from '../worker/worker-division-permission.service';
import { AuthService } from './auth.service';
import { BindingReleaseService } from './binding-release.service';
import { WorkerIdentityBinding } from './worker-identity-binding.entity';
import {
  BIND_RATE_LIMIT,
  BIND_RATE_WINDOW_SECONDS,
  COMPANION_ACCESS_TTL_SECONDS,
  COMPANION_REFRESH_TTL_SECONDS,
  WORKER_BINDING_MAX_PER_BOSS_DEFAULT,
  WORKER_BINDING_MAX_PER_BOSS_KEY,
  parseWorkerBindingMax,
} from './worker-binding-limit';

/** 绑定接口入参（"绑谁"三选一 + 打手账密） */
export interface BindIdentityInput {
  username?: string;
  uid?: string;
  workerNo?: string;
  password: string;
}

/** 打手档案摘要：**只含客户端要展示的字段，绝不含密码/邮箱/手机号/真实姓名等敏感项** */
export interface WorkerProfileSummary {
  workerNo: string;
  nickname: string;
  avatarMediaId: string | null;
  canTakeOrder: boolean;
  canServeCustomer: boolean;
  workerStatus: number;
  divisionPermissions: Awaited<ReturnType<WorkerDivisionPermissionService['listWithFlags']>>;
}

/** 一条绑定的视图（老板侧「我的」页 / 切换身份弹层的数据源） */
export interface BindingView {
  bindingId: string;
  status: 'active' | 'unbound';
  boundAt: Date | null;
  unboundAt: Date | null;
  worker: WorkerProfileSummary;
}

/**
 * 老板 ↔ 打手 身份绑定 + 伴随会话（合并双端·身份切换，方案甲；负责人 2026-10-06 拍板）。
 *
 * 职责边界（与 `AuthService` 的分工）：
 * - 本服务：绑定关系生命周期（bind/unbind/status/companion refresh）、上限读取、中文报错、审计；
 * - `AuthService`：账号密码校验（bcrypt）、封禁语义、令牌签发（primary/companion）；
 * - `JwtAuthGuard`：companion 会话的**每请求**有效性校验与接口族白名单。
 *
 * 铁律：
 * - 主体 id 只从 JWT `sub` 取（谁是老板）；请求体里只有打手的**定位标识**，绝不接受 boss id；
 * - 打手账密校验**复用既有 bcrypt 实现**（`AuthService.comparePassword`）与既有封禁语义
 *   （`AuthService.assertNotBanned`），不新写第二套；
 * - 上限来自 `system_setting.worker_binding_max_per_boss`（默认 1，仅超管可改，每次实时读库）；
 * - 解绑 **保留历史行**（status=unbound），并立即吊销该绑定的 companion 会话。
 */
@Injectable()
export class WorkerIdentityService {
  private readonly logger = new Logger('WorkerIdentity');

  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
    @InjectRepository(WorkerIdentityBinding) private readonly bindingRepo: Repository<WorkerIdentityBinding>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly settings: SystemSettingService,
    private readonly divisionPerm: WorkerDivisionPermissionService,
    private readonly rateLimit: RateLimitService,
    private readonly auth: AuthService,
    /** 释放绑定（置 unbound + 吊销 companion 令牌 + 写 identity 审计 + 断开 WS）——F1-b/F4 后的唯一入口 */
    private readonly bindingRelease: BindingReleaseService,
  ) {}

  /** 当前绑定上限（实时读库，默认 1；库里被写坏时回落默认值并告警） */
  async maxPerBoss(): Promise<number> {
    const raw = await this.settings.get(WORKER_BINDING_MAX_PER_BOSS_KEY);
    const parsed = parseWorkerBindingMax(raw?.cfgValue?.['value']);
    if (parsed === null) {
      if (raw) {
        this.logger.warn(
          `配置 ${WORKER_BINDING_MAX_PER_BOSS_KEY} 非法（${JSON.stringify(raw.cfgValue)}），本次回落默认 ${WORKER_BINDING_MAX_PER_BOSS_DEFAULT}`,
        );
      }
      return WORKER_BINDING_MAX_PER_BOSS_DEFAULT;
    }
    return parsed;
  }

  /**
   * `GET /user/identity`：当前老板账号的绑定状态（含打手档案摘要，不含任何敏感字段）。
   * 未绑定也返回 200（`bound:false`）——客户端据此渲染"去绑定"入口，而不是把 404 当错误。
   */
  async status(bossUserId: string) {
    const max = await this.maxPerBoss();
    const rows = await this.bindingRepo.find({
      where: { bossUserId: String(bossUserId), status: 'active' },
      order: { id: 'ASC' },
    });
    const bindings: BindingView[] = [];
    for (const row of rows) {
      bindings.push(await this.toView(row));
    }
    return {
      bound: bindings.length > 0,
      activeCount: bindings.length,
      maxPerBoss: max,
      bindings,
      /** 上限语义提示（客户端"我的"页展示；上限 1 = 一个老板账号默认绑 1 个打手账号） */
      message: bindings.length >= max ? `已达绑定上限（最多 ${max} 个）` : '可继续绑定',
    };
  }

  /**
   * `POST /user/identity/bind`：校验打手账密 → 建绑定 → 签发**伴随会话**。
   *
   * 校验顺序（刻意把"密码"放在"角色/封禁"之前：不知道密码的人得不到任何账号情报）：
   * 1. 限流（与 `/auth/login` 同策略 5 次/分/IP+账号，防打手账密爆破）→ 429 中文
   * 2. 定位账号（username / uid / workerNo 三选一）→ 查不到：400「账号或密码错误」
   *    **防枚举（安全审计 F2）**：这里与下一步密码错**必须逐字同一句**——旧实现分开写
   *    「账号不存在或密码错误」/「账号或密码错误」，两个字的差异就足以批量判定某登录名是否注册
   *    （限流是按账号分桶的，换账号即可继续探测）。口径与 `/auth/login` 统一为「账号或密码错误」。
   * 3. bcrypt 校验 → 错：400「账号或密码错误」（与第 2 步同一句）
   * 4. 角色必须是 worker → 否则 403「该账号不是打手账号，无法绑定」
   * 5. 封禁（复用 AuthService.assertNotBanned：到期自动解封 / 封禁中 403 + ACCOUNT_BANNED）
   * 6. 打手档案在职 → 停用：400「该打手账号已停用，无法绑定」
   * 7. 绑定关系（事务 + 老板行锁 + 唯一键兜底）：
   *    - 已被**他人**绑定 → 400「该打手账号已被其他老板绑定…」
   *    - 自己已达上限 → 400「绑定数量已达上限（当前上限 N 个）…」
   *    - 已绑给自己 → 直接复用该绑定并**重新签发 companion**（换机/12h 过期后再切换的正常路径）
   *    - 曾绑过（unbound 历史行存在，含被封禁/停用被系统释放，2026-10-06 裁决）→ 新建 active 行并把
   *      `rebound` 标为 true（unbound 历史行原地保留，不复活）
   * 8. 签发 companion（**不顶 primary**）→ 返回 companionToken（老板 token 不动）
   */
  async bind(bossUserId: string, input: BindIdentityInput, ip: string, userAgent: string) {
    const account = String(input.username ?? input.uid ?? input.workerNo ?? '').trim();
    if (!account) {
      throw new BadRequestException('请填写打手账号（登录名 / 展示 ID / 工号）');
    }
    // 限流：与 /auth/login 同策略（5 次/分/IP+账号）。绑定失败也计入（防"只试密码"绕过）
    if (!(await this.limitAllow(`identity-bind:${ip}:${account}`))) {
      await this.auth.recordIdentityEvent(null, account, ip, userAgent, 'fail', '触发绑定限流');
      throw new HttpException(
        { message: '绑定尝试过于频繁，请稍后再试', errorCode: 'RATE_LIMITED' },
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }

    const target = await this.findWorkerAccount(account);
    if (!target) {
      await this.auth.recordIdentityEvent(null, account, ip, userAgent, 'fail', '绑定：账号不存在');
      // 与下一步"密码错误"**逐字同一句**（安全审计 F2：文案差异 = 账号存在性枚举面）
      throw new BadRequestException('账号或密码错误');
    }
    if (!(await this.auth.comparePassword(target, input.password))) {
      await this.auth.recordIdentityEvent(target.id, target.username, ip, userAgent, 'fail', '绑定：密码错误');
      throw new BadRequestException('账号或密码错误');
    }
    if (target.role !== 'worker') {
      await this.auth.recordIdentityEvent(target.id, target.username, ip, userAgent, 'fail', '绑定：角色不是打手');
      throw new ForbiddenException('该账号不是打手账号，无法绑定');
    }
    await this.auth.assertNotBanned(target, 'identity', target.username, ip, userAgent);
    const worker = await this.workerRepo.findOne({ where: { userId: target.id } });
    if (!worker || worker.status !== 1) {
      await this.auth.recordIdentityEvent(target.id, target.username, ip, userAgent, 'fail', '绑定：打手已停用');
      throw new BadRequestException('该打手账号已停用，无法绑定');
    }

    const { row, rebound } = await this.createBinding(String(bossUserId), String(target.id));
    const tokens = await this.auth.issueCompanionTokens(target, String(row.id));
    await this.auth.recordIdentityEvent(
      target.id,
      target.username,
      ip,
      userAgent,
      'success',
      // 事件描述区分三种来源：首次新建 / 同一 active 行复用 / 曾绑过（含被封禁停用释放）后再绑
      rebound ? '绑定：已绑过该打手（重新签发伴随会话）' : '绑定：新建',
    );
    this.logger.log(`绑定打手身份 boss=${bossUserId} worker=${target.id} binding=${row.id} rebound=${rebound}`);

    return {
      bindingId: String(row.id),
      rebound,
      boundAt: row.boundAt,
      /** 老板自己的 token **不变**（仍用原 token 调老板侧接口）；companion 只用于打手态 */
      bossTokenUnchanged: true,
      companionToken: tokens.accessToken,
      companionRefreshToken: tokens.refreshToken,
      companionExpiresIn: tokens.expiresIn,
      maxPerBoss: await this.maxPerBoss(),
      worker: await this.workerSummary(target.id, worker),
    };
  }

  /**
   * `POST /user/identity/unbind`：解绑（**保留历史行**）并**立即吊销**该绑定的 companion 会话。
   * 上限可配 >1 时用 `bindingId` 指定解哪一条；只有一条时可省略。
   *
   * 安全审计 F1-b / F4：不再自己 `bindingRepo.update` + `revokeCompanionTokensByBinding`，
   * 而是走 **`BindingReleaseService.releaseBinding()`**（与"打手停用/封禁/删除"触发的系统释放
   * **同一实现**）：置 unbound → 按 `binding_id` 吊销 companion 令牌（revoked=1）→ 写 identity 审计
   * （来源=老板主动解绑，含 IP/UA）→ **主动断开**这些会话的 WS 连接。四条释放路径从此不会各自漂移。
   */
  async unbind(bossUserId: string, bindingId?: string, actor?: { ip?: string; userAgent?: string }) {
    const where = bindingId
      ? { bossUserId: String(bossUserId), id: String(bindingId), status: 'active' as const }
      : { bossUserId: String(bossUserId), status: 'active' as const };
    const actives = await this.bindingRepo.find({ where, order: { id: 'ASC' } });
    if (!actives.length) {
      // 指定了 bindingId 却没命中 → 精确提示（可能已被解绑/不属于本账号），而不是笼统的"没有绑定"
      throw new BadRequestException(
        bindingId ? '未找到该绑定（可能已解绑或不属于当前账号）' : '当前没有已绑定的打手账号',
      );
    }
    if (actives.length > 1) {
      throw new BadRequestException('存在多个绑定，请指定要解绑的 bindingId');
    }
    const row = actives[0];
    const boss = await this.userRepo.findOne({ where: { id: String(bossUserId) } });
    const workerUser = await this.userRepo.findOne({ where: { id: row.workerUserId } });
    const worker = await this.workerRepo.findOne({ where: { userId: row.workerUserId } });
    // 释放（置 unbound + 吊销 companion + 审计 + 断开 WS）——与系统释放同一实现
    const released = await this.bindingRelease.releaseBinding(String(row.id), {
      source: 'boss-unbind',
      actorUserId: String(bossUserId),
      // 登录名截到 12 字：审计 reason 是 varchar(100)，触发者标签不该把两侧 id 挤掉
      actorLabel: `user:${bossUserId}${boss?.username ? `(${boss.username.slice(0, 12)})` : ''}`,
      ip: actor?.ip ?? null,
      userAgent: actor?.userAgent ?? null,
    });
    this.logger.log(
      `解绑打手身份 boss=${bossUserId} binding=${row.id} 吊销会话=${released.revokedSessions} 断开WS=${released.revokedJtis.length}`,
    );
    return {
      ok: true,
      bindingId: String(row.id),
      workerNo: worker?.workerNo ?? '',
      nickname: workerUser?.nickname ?? '',
      revokedSessions: released.revokedSessions,
      message: '已解绑，打手态登录已失效',
    };
  }

  /**
   * `POST /user/identity/refresh`：伴随会话续期（12h 窗口内换新 access）。
   * 走 `AuthService.refresh` 同一套轮换逻辑（校验绑定仍 active、只顶 companion、TTL 仍 12h）。
   *
   * 安全审计 F5：**只吃 companion 的 refreshToken**（`requireCompanion`）——primary 的 refreshToken
   * 打进来会在**任何写操作之前** 401 中文，绝不轮换/吊销该账号原有 primary 会话。
   */
  async refreshCompanion(refreshToken: string, ip: string) {
    const pair = await this.auth.refresh(refreshToken, ip, { requireCompanion: true });
    return {
      companionToken: pair.accessToken,
      companionRefreshToken: pair.refreshToken,
      companionExpiresIn: pair.expiresIn,
      /** 与 access/refresh 同 TTL：12h 到点必须用打手账密重新切换（设计稿 A3） */
      companionTtlSeconds: COMPANION_ACCESS_TTL_SECONDS,
      companionRefreshTtlSeconds: COMPANION_REFRESH_TTL_SECONDS,
    };
  }

  /** 打手档案摘要（客户端展示用；不含任何敏感字段） */
  async workerSummary(workerUserId: string, worker?: Worker | null): Promise<WorkerProfileSummary> {
    const w = worker ?? (await this.workerRepo.findOne({ where: { userId: String(workerUserId) } }));
    const u = await this.userRepo.findOne({ where: { id: String(workerUserId) } });
    if (!w || !u) {
      throw new BadRequestException('打手档案不存在');
    }
    return {
      workerNo: w.workerNo,
      nickname: u.nickname || u.username,
      avatarMediaId: u.avatarMediaId ?? null,
      canTakeOrder: w.canTakeOrder === 1,
      canServeCustomer: w.canServeCustomer === 1,
      workerStatus: w.status,
      // 分部接单权限：实时查库（管理端刚授/刚撤的权，下一次读取即反映），客户端不得缓存判定
      divisionPermissions: await this.divisionPerm.listWithFlags(w.id),
    };
  }

  private async toView(row: WorkerIdentityBinding): Promise<BindingView> {
    return {
      bindingId: String(row.id),
      status: row.status,
      boundAt: row.boundAt ?? null,
      unboundAt: row.unboundAt ?? null,
      worker: await this.workerSummary(row.workerUserId),
    };
  }

  /**
   * 建绑定（事务：**老板行锁**把同一老板的并发绑定串行化 + 唯一键兜底）。
   *
   * 为什么两层都要：
   * - 行锁保证「读到的 active 条数」与「插入」在同一临界区，服务层上限判定不会被并发绕过；
   * - 唯一键（UK_wib_active_worker / UK_wib_active_boss_slot）是**最终真相**：
   *   即使将来有人绕过本服务直写库、或行锁因异常被跳过，也绝不会出现"一个打手被两人绑"或"超出上限"。
   */
  private async createBinding(
    bossUserId: string,
    workerUserId: string,
  ): Promise<{ row: WorkerIdentityBinding; rebound: boolean }> {
    return this.dataSource.transaction(async (em: EntityManager) => {
      const repo = em.getRepository(WorkerIdentityBinding);
      // 老板账号行锁（同一老板的并发绑定串行化；锁的是 user 行，不影响其它账号）
      await em.query('SELECT id FROM `user` WHERE id = ? FOR UPDATE', [String(bossUserId)]);

      // ① 该打手是否已被绑定（含"已绑给自己"）
      const taken = await repo.findOne({ where: { workerUserId: String(workerUserId), status: 'active' } });
      if (taken) {
        if (String(taken.bossUserId) === String(bossUserId)) {
          // 已绑给自己：复用该绑定（客户端"再切换一次身份"的正常路径），随后重新签发 companion
          return { row: taken, rebound: true };
        }
        throw new BadRequestException('该打手账号已被其他老板绑定，请先让对方解绑');
      }

      // ② 老板侧上限（默认 1，可配；实时读库）
      const max = await this.maxPerBoss();
      const actives = await repo.find({
        where: { bossUserId: String(bossUserId), status: 'active' },
        select: ['id', 'slot'],
      });
      if (actives.length >= max) {
        throw new BadRequestException(
          `绑定数量已达上限（当前上限 ${max} 个），请先解绑后再绑定新的打手账号`,
        );
      }
      // ③ 取最小空闲槽位（槽位 + 唯一键 = 上限可配且并发安全）
      const used = new Set(actives.map((a) => Number(a.slot)));
      let slot = 1;
      while (used.has(slot)) slot += 1;

      /**
       * ④ 这一对（老板, 打手）此前绑定过吗？—— 决定 `rebound` 标志（客户端"重新绑定"文案 + 回归断言）。
       *
       * 什么时候会命中：老板解绑后重绑、以及**打手被封禁/停用被系统释放**（`releaseWorkerBindings`，
       * 负责人 2026-10-06 裁决）后解封重绑。后者必须仍报 `rebound:true` —— 语义是"重新绑定一个
       * 曾经绑过的打手"，而不是"首次建立绑定"。
       *
       * 注意这里**只读不写**：那条 unbound 行是"因封禁/解绑而释放"的审计证据（含 unbound_at），
       * 一律原地保留，本次另建一条 active 行；`taken` 判定只看 active，所以不会与唯一键冲突。
       */
      const priorReleased = await repo.findOne({
        where: { bossUserId: String(bossUserId), workerUserId: String(workerUserId), status: 'unbound' },
        order: { id: 'DESC' },
        select: ['id'],
      });

      const row = repo.create({
        bossUserId: String(bossUserId),
        workerUserId: String(workerUserId),
        status: 'active',
        slot,
        boundAt: new Date(),
        unboundAt: null,
      });
      try {
        return { row: await repo.save(row), rebound: !!priorReleased };
      } catch (e) {
        // 并发撞唯一键：把 MySQL 1062 翻译成中文 400（而不是 500）
        const msg = String((e as { message?: string })?.message ?? '');
        if (msg.includes('UK_wib_active_worker')) {
          throw new BadRequestException('该打手账号已被其他老板绑定，请先让对方解绑');
        }
        if (msg.includes('UK_wib_active_boss_slot')) {
          throw new BadRequestException(
            `绑定数量已达上限（当前上限 ${max} 个），请先解绑后再绑定新的打手账号`,
          );
        }
        throw e;
      }
    });
  }

  /** 按登录名 / 展示 ID / 工号定位打手账号（带 passwordHash；主体 id 一律以库为准） */
  private async findWorkerAccount(account: string): Promise<User | null> {
    const user = await this.userRepo
      .createQueryBuilder('u')
      .addSelect('u.passwordHash')
      .where('u.username = :account OR u.uid = :account', { account })
      .getOne();
    if (user) return user;
    // 工号：worker_no → user_id（唯一）
    const worker = await this.workerRepo.findOne({ where: { workerNo: account } });
    if (!worker) return null;
    return this.userRepo
      .createQueryBuilder('u')
      .addSelect('u.passwordHash')
      .where('u.id = :id', { id: String(worker.userId) })
      .getOne();
  }

  /** 绑定限流（Redis 固定窗口；限流服务故障时放行，与既有 RateLimitService 同语义） */
  private async limitAllow(key: string): Promise<boolean> {
    return this.rateLimit.allow(key, BIND_RATE_LIMIT, BIND_RATE_WINDOW_SECONDS);
  }
}
