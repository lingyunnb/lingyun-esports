import { BadRequestException, ConflictException, ForbiddenException, HttpException, HttpStatus, Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import * as bcrypt from 'bcryptjs';
import { randomInt, randomUUID } from 'crypto';
import { DataSource, In, Repository } from 'typeorm';
import { MailerService, maskEmail } from '../../common/mail/mailer.service';
import { RateLimitService } from '../../common/rate-limit.service';
import { UID_PATTERN } from '../friend/friend.service';
import { Admin } from '../admin/admin.entity';
import { OperationLogService } from '../log/operation-log.service';
import { AdminRole } from '../rbac/entities/admin-role.entity';
import { Worker } from '../worker/worker.entity';
import { WorkerDivisionPermissionService } from '../worker/worker-division-permission.service';
import { User, UserRole } from '../user/user.entity';
import { WalletService } from '../wallet/wallet.service';
import { AuthToken, AuthTokenKind } from './auth-token.entity';
import { evaluateBan } from './account-ban.check';
import { COMPANION_REFRESH_ONLY, checkCompanionSession } from './companion-session.check';
import { RECHARGE_REFRESH_ONLY, checkRechargeSession } from './recharge-session.check';
import { WORKER_APP_SUNSET_GONE, checkWorkerAppSunset } from './worker-app-sunset';
import { EmailCodeService, EmailScene, normalizeEmail } from './email-code.service';
import { QqOauthClient, qqErrorToException } from './qq-oauth.client';
import { UserOAuth } from './user-oauth.entity';
import { LoginLog } from './login-log.entity';
import { COMPANION_ACCESS_TTL_SECONDS, COMPANION_REFRESH_TTL_SECONDS } from './worker-binding-limit';

const ACCESS_TTL_SECONDS = 2 * 60 * 60; // 2 小时
const REFRESH_TTL_SECONDS = 30 * 24 * 60 * 60; // 30 天（轮换制）
const LOGIN_RATE_LIMIT = 5; // 5 次/分/IP+账号（docs/03）

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

/** 签发选项：kind≠primary 时携带所属绑定 id 与更短 TTL（见 worker-binding-limit.ts / recharge-config.ts） */
export interface IssueTokenOptions {
  kind?: AuthTokenKind;
  bindingId?: string | null;
}

/**
 * 会话种类归一化：**以 opts.kind 为准，未知值一律回落 primary**（不信任调用方传进来的字符串）。
 * 抽成函数是为了让 `issueTokens` 与 `refresh` 的判定**永远同源**（两处各写一遍三元表达式必然分叉）。
 */
function normalizeKind(kind: unknown): AuthTokenKind {
  return kind === 'companion' || kind === 'recharge' ? kind : 'primary';
}

/**
 * 认证服务（docs/04）：
 * - 登录失败统一返回"账号或密码错误"，不泄露账号是否存在
 * - 每次登录/刷新登记 auth_token，登出/轮换即吊销
 * - 登录限流 + 全量登录日志
 */
@Injectable()
export class AuthService {
  private readonly logger = new Logger('Auth');

  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(AuthToken) private readonly authTokenRepo: Repository<AuthToken>,
    @InjectRepository(LoginLog) private readonly loginLogRepo: Repository<LoginLog>,
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
    @InjectRepository(Admin) private readonly adminRepo: Repository<Admin>,
    @InjectRepository(AdminRole) private readonly adminRoleRepo: Repository<AdminRole>,
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    private readonly rateLimit: RateLimitService,
    private readonly walletService: WalletService,
    /** 分部接单权限（/auth/me 附带展示，判定仍在接单侧实时查库） */
    private readonly divisionPerm: WorkerDivisionPermissionService,
    /** 邮箱验证码（负责人 2026-10-05：邮箱验证替代短信验证；2026-10-10 扩展 bind/login 场景） */
    private readonly emailCode: EmailCodeService,
    /** 邮件发送（失败只 warn + 返回 false，绝不抛给业务层） */
    private readonly mailer: MailerService,
    /** 找回密码/邮箱绑定/QQ 登录审计留痕（docs/09） */
    private readonly opLog: OperationLogService,
    /** 第三方登录绑定表 user_oauth（QQ；migration 1809000000000） */
    @InjectRepository(UserOAuth) private readonly userOauthRepo: Repository<UserOAuth>,
    /** QQ 互联 Graph API 客户端（服务端复核 openid；未配置时接口中文 503） */
    private readonly qq: QqOauthClient,
  ) {}

  /**
   * 老板端自助注册（工作端/管理员账号由后台创建，docs/04；可选自定义展示 ID，支持中文）
   *
   * 邮箱扩展（负责人 2026-10-05）：可选 `email` + `emailCode`。
   * - **不传 email**：行为与老版本**逐字节一致**（老客户端零影响）；
   * - 传 email：必须带有效 emailCode，否则中文 400；
   * - 邮箱唯一性先于验码检查（不浪费用户验证码，也不让已占用邮箱消耗限流额度）。
   */
  async register(dto: {
    username: string;
    password: string;
    nickname?: string;
    uid?: string;
    email?: string;
    emailCode?: string;
  }) {
    const exists = await this.userRepo.findOne({ where: { username: dto.username } });
    if (exists) {
      throw new ConflictException('用户名已存在');
    }
    const email = this.normalizeEmail(dto.email);
    if (email) {
      if (!dto.emailCode) {
        throw new BadRequestException('请填写邮箱验证码');
      }
      const taken = await this.userRepo.findOne({ where: { email } });
      if (taken) {
        throw new ConflictException('该邮箱已被注册');
      }
    }
    if (dto.uid) {
      // 2026-09-25：注册即校验 ID 格式（2-20 位中文/字母/数字/下划线），与好友搜索/修改 ID 规则一致
      if (!UID_PATTERN.test(dto.uid)) {
        throw new BadRequestException('ID 格式非法（2-20 位中文/字母/数字/下划线）');
      }
      const uidExists = await this.userRepo.findOne({ where: { uid: dto.uid } });
      if (uidExists) {
        throw new ConflictException('该 ID 已被使用');
      }
    }
    // 验码（一次性：成功即作废；错 ≥5 次作废；过期中文提示）
    if (email) {
      await this.emailCode.verifyOrThrow(email, 'register', dto.emailCode!);
    }
    const passwordHash = await bcrypt.hash(dto.password, 10);
    const verifiedAt = email ? new Date() : null;
    // 注册 = 账号 + 钱包（事务，docs/06：一人一钱包，注册即建）
    let user: User;
    try {
      user = await this.dataSource.transaction(async (em) => {
        const u = await em.save(
          em.create(User, {
            username: dto.username,
            uid: dto.uid ?? (await this.generateUid()),
            passwordHash,
            nickname: dto.nickname || dto.username,
            role: 'user',
            status: 1,
            email,
            emailVerifiedAt: verifiedAt,
          }),
        );
        await this.walletService.createWalletInTx(em, u.id);
        return u;
      });
    } catch (e) {
      // 并发兜底：唯一索引 UQ_user_email / 用户名唯一约束被同时注册的请求撞到 → 中文冲突而不是 500
      if (isDuplicateKeyError(e)) {
        throw new ConflictException(email ? '该邮箱已被注册' : '用户名已存在');
      }
      throw e;
    }
    return {
      id: user.id,
      username: user.username,
      uid: user.uid,
      nickname: user.nickname,
      // 仅回显是否已绑定邮箱，**不回显验证码**
      email: user.email,
      emailVerified: user.emailVerifiedAt !== null,
    };
  }

  /**
   * 获取邮箱验证码（负责人 2026-10-05；2026-10-10 扩展 bind/login 两个场景）
   *
   * 各场景的"发不发信"口径（**这是本接口唯一需要区分场景的地方**）：
   * - `register`：邮箱已被注册 → 中文 400（注册本就要告知占用，无法也不应隐藏；**行为逐字不变**）
   * - `reset`：**防用户枚举** —— 邮箱未注册时**仍返回成功**（文案与真发一致），**不发信**；
   *   但**限流判定与额度消耗与已注册侧完全一致**（2026-10-10 账号枚举修复，与 `login` 同一处顺序不变量）
   * - `bind`（绑定/换绑）：**只要限流通过就真发信**，不区分"该邮箱是否已被别的账号绑定"。
   *   为什么不去做"已被占用就不发"：绑定侧的唯一性拦截发生在 `POST /user/email/bind`（中文 409），
   *   若取码阶段就静默不发，用户永远拿不到码 → **409 这条路径在真实使用中不可达**（只剩竞态能触发），
   *   而"邮箱是否已注册"这条信息本来就能从 `scene=register` 拿到（既有口径，本轮不改），
   *   所以这里静默不发**换不来任何额外的防枚举收益**，只换来一个不可用的流程。
   * - `login`（邮箱验证码登录）：**仅当该邮箱已绑定某账号才真发信**；未绑定 → 与真发**逐字相同**的成功响应，
   *   不发信、不生成码，但**限流判定与额度消耗与已绑定侧完全一致**（2026-10-10 账号枚举修复：
   *   未绑定侧曾"既不校验也不扣额度"→ 同一邮箱连发第二次时 429/200 的差异就泄漏了"是否绑定"）。
   *
   * 响应**绝不返回验证码**，只返回「已发送」；限流口径三档不变（同邮箱 60s / 同邮箱 5 次·小时 / 同 IP 10 次·小时）。
   * ⚠️ 相关顺序不变量见方法体内 `login` / `reset` 分支前的注释块：**限流先于「邮箱是否存在」**，禁止调换。
   */
  async sendEmailCode(
    dto: { email: string; scene: EmailScene },
    ip: string,
    userAgent: string,
  ): Promise<{ ok: true; message: string }> {
    const email = this.normalizeEmail(dto.email);
    if (!email) throw new BadRequestException('邮箱格式不正确');
    const scene: EmailScene = dto.scene;
    const okMessage = '验证码已发送至邮箱，请注意查收（10 分钟内有效）';

    const existing = await this.userRepo.findOne({ where: { email }, select: ['id', 'username', 'status'] });

    if (scene === 'register' && existing) {
      await this.writeLoginLog('user', existing.id, existing.username, ip, userAgent, 'fail', '注册取码：邮箱已注册');
      throw new BadRequestException('该邮箱已被注册，请直接登录或使用找回密码');
    }

    /**
     * ⚠️⚠️ **顺序不变量（账号枚举修复 2026-10-10；禁止把这段挪到下面任何「邮箱是否存在」的判断之后）** ⚠️⚠️
     *
     * 限流判定 + 额度消耗**必须**发生在「该邮箱在本平台上是否存在」之前，且**存在与不存在两条分支
     * 消耗完全相同的额度**。这条对 `login`（是否已绑定账号）与 `reset`（是否已注册）**同样适用** ——
     * 两个场景都是"不发信，但必须照扣额度"。唯一的例外是 `register`：它**按设计**显式告知
     * 「该邮箱已被注册」（上面的 400），没有需要隐藏的差异，故其限流仍留在下面的放行路径 —— 别把 register 折进来。
     *
     * 历史缺陷（已实测确认，两个场景各犯过一次）：
     *   · `login` 未绑定分支曾在限流判定**之前**就 return —— 既不校验也不消费额度；
     *   · `reset` 未注册分支（2026-10-10 第二批修复前）同样在限流判定之前就 return。
     * 于是同一个邮箱在时间维度上产生 oracle：
     *   · 存在侧（已绑定/已注册）60s 内第二次请求 → **429**「请求过于频繁，请 N 秒后再试」
     *   · 不存在侧第二次请求                      → **恒 200**（且 Redis 里 `email:last:{scene}:*` /
     *     `email:cnt:{scene}:*` 只有存在侧有键，可旁路探测）
     * → 攻击者只要对同一邮箱连发两次，就能判断"该邮箱是否已注册/已绑定本平台账号"（账号枚举）。
     *
     * 为什么限流放前面是安全的：限流是**公开且对称**的行为（两种情况都被同样地限），本身不携带"邮箱是否存在"的信息；
     * 而把不存在分支的额度补上（下面静默分支里的 `consumeQuota()`）后，连"Redis 里有没有键"这条旁路也一起消失。
     * 不存在侧**依然绝不发信**（不生成码、不调 MailerService）——"不发信"与"不消耗额度"是两件事，不要混为一谈。
     *
     * **禁止挪回**：把 `assertRateLimits()` 移回任一场景的早返回之后，等价于把那枚 oracle 重新打开。
     * 回归断言与变异验证见 `scripts/tools/email-auth-e2e.js` ⑦d（login）/ ⑦e（reset）：
     * 变异 M3（login）/ M4（reset）——把限流判定与额度消耗挪回存在性判断之后——**必须变红**。
     */
    if (scene === 'login' || scene === 'reset') {
      await this.emailCode.assertRateLimits(email, scene, ip);
    }

    // 防枚举静默分支：**与真发逐字相同的成功响应**，但不发信；额度**照样消耗**（写与存在侧完全相同的 last/cnt 键）
    // → 第二次请求与存在侧同为 429、文案逐字相同。内部只留一条 login_log warn 供运维排查
    //（该表仅管理端可见，不构成客户端可探测差异）。
    if (scene === 'login' && !existing) {
      await this.emailCode.consumeQuota(email, scene, ip);
      await this.writeLoginLog('user', null, email, ip, userAgent, 'fail', '登录取码：邮箱未绑定任何账号（内部记录）');
      this.logger.warn(`邮箱登录取码：该邮箱未绑定任何账号，按防枚举策略静默返回 scene=login email=${maskEmail(email)}`);
      return { ok: true, message: okMessage };
    }
    if (scene === 'reset' && !existing) {
      await this.emailCode.consumeQuota(email, scene, ip);
      await this.writeLoginLog('user', null, email, ip, userAgent, 'fail', '找回密码取码：邮箱未注册（内部记录）');
      this.logger.warn(`找回密码取码：邮箱未注册，按防枚举策略静默返回 scene=reset email=${maskEmail(email)}`);
      return { ok: true, message: okMessage };
    }

    // 测试注入点：打桩发信失败（仅 MAIL_ALLOW_TEST_ENDPOINTS=true 生效）——必须在**额度消耗**前判定，否则会白扣额度
    // （login / reset 的限流判定已在上方前置；`assertRateLimits` 只读不写，故"发信失败不消耗额度"这条不变量仍然成立）
    if (await this.emailCode.isForceFail()) {
      this.logger.warn('[测试注入] 发信被强制置为失败，返回中文提示且不消耗限流额度');
      throw new BadRequestException('邮件发送失败，请稍后重试');
    }

    // 限流（Redis）：同邮箱 60s 内不可重发 / 同邮箱每小时 ≤5 次 / 同 IP 每小时 ≤10 次。
    // login / reset 已在上面**前置**判定（顺序不变量），这里只覆盖 register / bind 的放行路径。
    if (scene !== 'login' && scene !== 'reset') {
      await this.emailCode.assertRateLimits(email, scene, ip);
    }

    // 先落码，再发信；发信失败则回滚码（不留「用户没收到但码已存在」的脏状态）
    const code = await this.emailCode.issueCode(email, scene);
    // 邮件文案按场景区分（register/reset 两条**逐字未变**；bind/login 为本次新增）
    const mail = {
      register: { subject: '【祁连山电竞】注册邮箱验证码', action: '注册账号' },
      reset: { subject: '【祁连山电竞】找回密码验证码', action: '找回密码' },
      bind: { subject: '【祁连山电竞】绑定邮箱验证码', action: '绑定邮箱' },
      login: { subject: '【祁连山电竞】登录验证码', action: '登录账号' },
    }[scene];
    const ttlMin = Math.floor(this.emailCode.ttlSeconds / 60);
    const text = [
      `您正在${mail.action}，验证码为：${code}`,
      ``,
      `验证码 ${ttlMin} 分钟内有效，请勿泄露给他人。`,
      `如非本人操作，请忽略本邮件。`,
      ``,
      `—— 祁连山电竞`,
    ].join('\n');

    const sent = await this.mailer.send(email, mail.subject, text);
    if (!sent.ok) {
      await this.emailCode.revokeCode(email, scene);
      await this.writeLoginLog(
        'user',
        existing?.id ?? null,
        existing?.username ?? email,
        ip,
        userAgent,
        'fail',
        '邮件发送失败',
      );
      this.logger.warn(
        `验证码邮件发送失败，已回滚验证码 scene=${scene} email=${maskEmail(email)} detail=${sent.error ?? ''}`,
      );
      throw new BadRequestException('邮件发送失败，请稍后重试');
    }

    // 只在本单真正发信成功后才占用 60s 重发额度与小时计数
    await this.emailCode.markSent(email, scene, ip);
    this.logger.log(`验证码已发送 scene=${scene} email=${maskEmail(email)} messageId=${sent.messageId ?? '-'}`);
    return { ok: true, message: okMessage };
  }

  /**
   * 找回密码（邮箱验证码，负责人 2026-10-05）：不依赖旧密码，与既有「修改密码」对齐后续动作。
   *
   * 步骤：校验码（一次性）→ 沿用既有 bcrypt 哈希改密 → **吊销该用户全部 access/refresh 会话**
   *      → operation_log 审计 + login_log 留痕。
   */
  async resetPasswordByEmail(
    dto: { email: string; emailCode: string; newPassword: string },
    ip: string,
    /** 请求来源 UA（审计用；不传时该列留空） */
    userAgent = '',
  ) {
    // 密码规则沿用既有校验（8-64 位；DTO 已拦一层，这里兜业务层直接调用）
    if (!dto.newPassword || dto.newPassword.length < 8 || dto.newPassword.length > 64) {
      throw new BadRequestException('新密码须为 8-64 位');
    }
    const email = this.normalizeEmail(dto.email);
    if (!email) throw new BadRequestException('邮箱格式不正确');

    const user = await this.userRepo.findOne({ where: { email } });
    // 枚举防护：未注册邮箱也走「验证码已过期」这条通用文案（不暴露邮箱是否存在）
    if (!user) {
      await this.writeLoginLog('user', null, email, ip, '', 'fail', '找回密码：邮箱未注册');
      this.logger.warn(`找回密码：邮箱未注册 email=${maskEmail(email)}`);
      throw new BadRequestException('验证码已过期，请重新获取');
    }

    // 验码：一次性作废；错 ≥5 次作废；过期中文提示
    await this.emailCode.verifyOrThrow(email, 'reset', dto.emailCode);

    await this.userRepo.update(user.id, {
      passwordHash: await bcrypt.hash(dto.newPassword, 10),
      emailVerifiedAt: new Date(),
    });

    // 改密后全部会话吊销（与既有 changePassword 完全一致：防旧设备继续在线）
    const revoked = await this.authTokenRepo.update({ userId: user.id, revoked: 0 }, { revoked: 1 });

    // 审计（docs/09）：不落密码/验证码，只落主体与动作
    this.opLog.log({
      adminUserId: String(user.id),
      adminName: user.nickname ?? user.username,
      module: 'auth',
      action: 'password_reset_by_email',
      method: 'POST',
      path: '/auth/password/reset',
      requestBody: JSON.stringify({ userId: String(user.id), email: maskEmail(email), via: 'email_code' }),
      ip,
      result: 'success',
      errorMsg: null,
    });
    await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'success', '邮箱验证码重置密码');
    this.logger.log(
      `找回密码成功 userId=${user.id} email=${maskEmail(email)} 吊销会话=${revoked.affected ?? 0}`,
    );
    return { ok: true, message: '密码已重置，请使用新密码登录' };
  }


  /**
   * 三端统一登录入口（docs/04）。
   *
   * 2026-10-10 新增**邮箱验证码登录**（负责人拍板 1：密码登录照旧可用，不锁死任何现有账号）：
   * - **只传 username + password**（老客户端）：走下面原密码路径，逐字节兼容；
   * - **传了 `email`**：走 [loginByEmailCode]（校验 `scene=login` 的邮箱码），`username/password` 一并忽略；
   * - 两条路径**共用同一套**限流键规则、工作端到期收口、封禁判定、单设备顶号（`issueTokens`）与 `login_log` 口径。
   *
   * 限流键：老路径仍是 `login:{ip}:{username}`（**逐字未变**）；邮箱路径为 `login:{ip}:{email}`
   * （username 的字符集是 `[a-zA-Z0-9_]`，不可能等于含 `@` 的邮箱 → 两个键空间不会互相污染）。
   */
  async login(
    dto: { username?: string; password?: string; role: string; email?: string; emailCode?: string },
    ip: string,
    userAgent: string,
  ) {
    const email = this.normalizeEmail(dto.email);
    /** 登录标识（限流键与日志主体）：邮箱码登录用邮箱，否则用账号名 */
    const loginName = email ?? String(dto.username ?? '');

    const requestKey = `login:${ip}:${loginName}`;
    if (!(await this.rateLimit.allow(requestKey, LOGIN_RATE_LIMIT, 60))) {
      await this.writeLoginLog(dto.role, null, loginName, ip, userAgent, 'fail', '触发登录限流');
      /**
       * **429（不是 403）** —— 2026-10-13 统一限流语义（docs/03 第 35 行「429 = 触发限流」）。
       *
       * 改前这里是 `ForbiddenException`（403），与同平台其余限流点分裂：
       * 邮箱取码（`email-code.service.ts`）、打手绑定（`worker-identity.service.ts`）、
       * 充值管理员绑定（`recharge.service.ts`）**全都是 429**；只有登录/QQ 登录是 403。
       * 后果是客户端要为"同一个限流语义"写两套分支，且 403 在 HTTP 语义上是"已认证但无权限"，
       * 用来表达限流会与真正的权限拒绝混淆。
       *
       * ⚠️ **本文件另有语义完全不同的 403**：`账号角色不符`（见下面 `login` 的 `user.role !== dto.role`
       * 与 `loginByEmailCode` 的同名分支）—— 那是**越权判定**，必须**保持 403**，禁止一起改成 429。
       * 两者只靠中文文案区分：「登录尝试过于频繁，请稍后再试」= 限流（429）／
       * 「账号角色不符」= 越权（403）。**文案一个字都不要动**（测试与客户端按文案分流）。
       *
       * 与仓库既有写法一致：用 `HttpException` + `HttpStatus.TOO_MANY_REQUESTS`
       * （同 `email-code.service.ts:138`；`worker-identity.service.ts:158` 还额外带 `errorCode`，
       * 但本接口的 429 是**新增状态码、文案逐字不变**，故**不加 errorCode**，避免给客户端造出
       * 一个此前不存在的字段契约）。
       */
      throw new HttpException('登录尝试过于频繁，请稍后再试', HttpStatus.TOO_MANY_REQUESTS);
    }

    /**
     * 工作端到期收口（负责人 2026-10-06 定案「彻底废除工作端」）：
     * `system_setting.worker_app_sunset_at` 到期后，**工作端登录直接 403 中文**。
     *
     * - 判定**只有一份**：`modules/auth/worker-app-sunset.ts`（读配置 + 判断），
     *   与 `JwtAuthGuard`（已登录的 worker primary → 401）、`RealtimeGateway`（WS 拒连）共用
     *   —— 不在本文件里复制第二份 SQL 或第二个日期比较（安全审计 F1 的同类教训）。
     * - 位置刻意在**凭据校验之前**：工作端 App 一打开就登录，越早给出迁移文案越好；
     *   这里不泄露任何账号信息（限流先行、登录日志照写、文案对未登录者本就是公开口径）。
     * - **只挡 `role=worker` 的登录**：老板端（user）/ 管理端（admin）不受影响；
     *   老板端「打手态」走 `POST /user/identity/bind`（companion 会话）**不经过本方法**，
     *   因此替代品照常可用（本次最重要的一条不变量）。
     * - 2026-10-10：邮箱码登录**同样**受这条约束（它就是一次 primary 登录），判定与文案一字未改。
     */
    if (dto.role === 'worker') {
      const sunset = await checkWorkerAppSunset(this.dataSource);
      if (sunset.sunset) {
        await this.writeLoginLog(dto.role, null, loginName, ip, userAgent, 'fail', '工作端已停止服务（到期收口）');
        this.logger.log(`拒绝工作端登录（已到期 ${sunset.text}）loginName=${loginName}`);
        throw new ForbiddenException(WORKER_APP_SUNSET_GONE);
      }
    }

    // ---------- 邮箱验证码登录（传了 email 即走这条，忽略 username/password） ----------
    if (email) {
      return this.loginByEmailCode(email, dto, ip, userAgent);
    }

    // ---------- 原密码登录路径（**未传 email 时逐字不变**） ----------
    if (!dto.username || !dto.password) {
      // DTO 已保证（未传 email 时 username/password 必填 + 长度校验）；这里兜住"服务层被直接调用"的场景
      throw new BadRequestException('账号和密码不能为空');
    }

    const user = await this.userRepo
      .createQueryBuilder('u')
      .addSelect('u.passwordHash')
      .where('u.username = :username', { username: dto.username })
      .getOne();

    // 统一错误文案：不区分账号不存在/密码错误（docs/03）
    const fail = async (reason: string) => {
      await this.writeLoginLog(dto.role, user?.id ?? null, dto.username!, ip, userAgent, 'fail', reason);
      throw new UnauthorizedException('账号或密码错误');
    };

    if (!user || !user.passwordHash) {
      await fail('账号不存在');
    }
    if (user!.role !== dto.role) {
      await this.writeLoginLog(dto.role, user!.id, dto.username!, ip, userAgent, 'fail', '角色不符');
      throw new ForbiddenException('账号角色不符');
    }
    // 封禁检查（负责人需求）：到期自动解封继续登录；封禁中返回 errorCode=ACCOUNT_BANNED（客户端弹窗展示结束时间）
    // 2026-10-06 抽成公共方法（逻辑逐字未改）：绑定打手账号时复用同一套封禁语义
    await this.assertNotBanned(user!, dto.role, dto.username!, ip, userAgent);
    const ok = await bcrypt.compare(dto.password, user!.passwordHash);
    if (!ok) {
      await fail('密码错误');
    }

    const tokens = await this.issueTokens(user!);
    await this.userRepo.update(user!.id, { lastLoginAt: new Date(), lastLoginIp: ip });
    await this.writeLoginLog(dto.role, user!.id, dto.username!, ip, userAgent, 'success', null);
    this.logger.log(`登录成功 userId=${user!.id} role=${dto.role}`);
    return tokens;
  }

  /**
   * 邮箱验证码登录（2026-10-10）。
   *
   * ## 防枚举：失败一律同一句话
   * 「邮箱或验证码错误」**同时**覆盖「该邮箱没绑任何账号」「验证码不对」「验证码过期」「码错满 5 次作废」
   * 四种情况 —— 客户端拿到的状态码（400）与文案逐字相同，无法据此判断某个邮箱是否已绑定账号。
   *
   * ## 顺序为什么是这样（每一步都有理由）
   * 1. 先按邮箱查账号，**查不到就直接走统一失败**（不查 Redis、不做任何写操作 → 无副作用、无状态差异）；
   * 2. **验码成功之前不做角色校验/封禁校验**：否则 `role` 传错时会返回 403「账号角色不符」、
   *    封禁账号会返回 403「已被封禁」，这两个响应本身就是"该邮箱已绑定账号"的判别式；
   * 3. 验码成功（= 已证明邮箱可控）之后才做**既有登录的全部校验**：角色匹配 → 封禁（含到期自动解封）
   *    → 签发令牌（`issueTokens(user)`：**primary ↔ primary 互斥、旧会话置 revoked=2、中文文案不变**）
   *    → 更新最后登录时间/IP → `login_log`。
   *
   * ## 审计
   * - `login_log`：成功时 `fail_reason = '邮箱验证码登录（via=email_code）'`（与「邮箱验证码重置密码」
   *   那条留痕同口径：都在 `fail_reason` 里写明确切动作），失败时写具体原因；
   * - `operation_log`：`action=login_by_email_code` + `requestBody.via='email_code'`，邮箱**脱敏**，
   *   与 `resetPasswordByEmail` 的 `via=email_code` 完全一致；**绝不落验证码**。
   */
  private async loginByEmailCode(
    email: string,
    dto: { role: string; emailCode?: string },
    ip: string,
    userAgent: string,
  ) {
    /** 统一失败（防枚举）：同样的状态码 + 同样的中文，内部只把真实原因写进 login_log */
    const unifiedFail = async (reason: string): Promise<never> => {
      await this.writeLoginLog(dto.role, null, email, ip, userAgent, 'fail', reason);
      throw new BadRequestException('邮箱或验证码错误');
    };

    const user = await this.userRepo.findOne({ where: { email } });
    if (!user) return unifiedFail('邮箱验证码登录：该邮箱未绑定任何账号');
    if (!dto.emailCode) return unifiedFail('邮箱验证码登录：未提供验证码');

    const outcome = await this.emailCode.verifyCode(email, 'login', String(dto.emailCode));
    if (!outcome.ok) {
      return unifiedFail(`邮箱验证码登录：验证码未通过（${outcome.reason}）`);
    }

    // ---- 以下全部是既有登录校验（同一实现，不复制规则） ----
    if (user.role !== dto.role) {
      await this.writeLoginLog(dto.role, user.id, user.username, ip, userAgent, 'fail', '角色不符');
      throw new ForbiddenException('账号角色不符');
    }
    await this.assertNotBanned(user, dto.role, user.username, ip, userAgent);

    const tokens = await this.issueTokens(user);
    await this.userRepo.update(user.id, { lastLoginAt: new Date(), lastLoginIp: ip });
    await this.writeLoginLog(dto.role, user.id, user.username, ip, userAgent, 'success', '邮箱验证码登录（via=email_code）');
    this.opLog.log({
      adminUserId: String(user.id),
      adminName: user.nickname ?? user.username,
      module: 'auth',
      action: 'login_by_email_code',
      method: 'POST',
      path: '/auth/login',
      requestBody: JSON.stringify({
        userId: String(user.id),
        email: maskEmail(email),
        role: dto.role,
        via: 'email_code',
      }),
      ip,
      result: 'success',
      errorMsg: null,
    });
    this.logger.log(`邮箱验证码登录成功 userId=${user.id} role=${dto.role}`);
    return tokens;
  }

  // ================================================================================================
  // QQ 登录 / 绑定（2026-10-10，负责人「QQ 登录服务端接线」；客户端由后续批次做）
  //
  // 不变量（逐条对应负责人要求）：
  // 1. **绝不相信客户端传的 openid**：openid 一律来自服务端用 access_token 调 `oauth2.0/me` 的复核结果；
  //    入参 openid 只用于**比对**（不一致 → 中文 403，且不建号、不登录、不绑任何东西）。
  // 2. **未配置 `QQ_APP_ID`/`QQ_APP_KEY` → 中文 503「QQ 登录未配置」**，且**不做任何网络调用**。
  // 3. **超时 ≤10s**（在 `QqOauthClient` 内），网络失败 → 中文 503「QQ 登录服务暂时不可用，请稍后重试」。
  // 4. 绑定策略：① `(qq, openid)` 已存在 → 直接登录该账号；② 不存在 → **建新账号**（本平台账号体系，
  //    用户名/展示 ID 复用注册的既有生成器）并写 `user_oauth`；③ 已登录时走 `bindQq` 绑到当前账号。
  // 5. 建出来的账号是**老板账号（role=user）**；命中已绑定账号若不是 `role=user` → 403 中文
  //    （防止"QQ 登录凭空造出一个 worker primary 会话"，绕过工作端到期收口）。
  // ================================================================================================

  /**
   * QQ 登录（`POST /auth/qq/login`）。
   *
   * @returns 与 `POST /auth/login` **同结构**的令牌对（`accessToken/refreshToken/expiresIn`），
   *   另附 `isNewUser`（是否本次新建账号）与 `user` 摘要（客户端首屏可直接用）。
   */
  async loginByQq(
    dto: { accessToken?: string; access_token?: string; openid?: string },
    ip: string,
    userAgent: string,
  ) {
    // 限流：与密码登录同一档（5 次/分/IP）。键独立的理由：此刻还没有任何账号标识可用
    if (!(await this.rateLimit.allow(`login:${ip}:qq`, LOGIN_RATE_LIMIT, 60))) {
      await this.writeLoginLog('user', null, 'qq', ip, userAgent, 'fail', '触发登录限流');
      // 429：与上面 `login()` 同一口径（docs/03「429 = 触发限流」），文案逐字不变
      throw new HttpException('登录尝试过于频繁，请稍后再试', HttpStatus.TOO_MANY_REQUESTS);
    }

    const cred = await this.verifyQqCredential(dto, ip, userAgent, 'QQ 登录');
    const binding = await this.userOauthRepo.findOne({ where: { provider: 'qq', openid: cred.openid } });

    // ---------- ① 已绑定 → 直接登录该账号 ----------
    if (binding) {
      const user = await this.userRepo.findOne({ where: { id: binding.userId } });
      if (!user) {
        // 悬空绑定（账号被删且绑定行残留）：如实 401，不建新号（避免"删号即被顶替"）
        await this.writeLoginLog('user', null, 'qq', ip, userAgent, 'fail', 'QQ 绑定的账号不存在');
        throw new UnauthorizedException('账号不存在');
      }
      if (user.role !== 'user') {
        await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'fail', 'QQ 未绑定老板账号（角色不符）');
        throw new ForbiddenException('该 QQ 未绑定老板账号');
      }
      await this.assertNotBanned(user, 'user', user.username, ip, userAgent);
      const tokens = await this.issueTokens(user);
      await this.userRepo.update(user.id, { lastLoginAt: new Date(), lastLoginIp: ip });
      await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'success', 'QQ 登录（via=qq）');
      this.opLog.log({
        adminUserId: String(user.id),
        adminName: user.nickname ?? user.username,
        module: 'auth',
        action: 'login_by_qq',
        method: 'POST',
        path: '/auth/qq/login',
        requestBody: JSON.stringify({ userId: String(user.id), provider: 'qq', openid: maskOpenid(cred.openid), via: 'qq' }),
        ip,
        result: 'success',
        errorMsg: null,
      });
      this.logger.log(`QQ 登录成功 userId=${user.id}（已绑定）`);
      return { ...tokens, isNewUser: false, user: qqUserSummary(user) };
    }

    // ---------- ② 未绑定 → 建新账号 + 写 user_oauth ----------
    const info = await this.qq.fetchUserInfo(cred.accessToken, cred.openid);
    const created = await this.createQqUser(cred.openid, cred.unionid, info.nickname);
    const user = created.user;
    await this.assertNotBanned(user, 'user', user.username, ip, userAgent);
    const tokens = await this.issueTokens(user);
    await this.userRepo.update(user.id, { lastLoginAt: new Date(), lastLoginIp: ip });
    await this.writeLoginLog(
      'user',
      user.id,
      user.username,
      ip,
      userAgent,
      'success',
      created.created ? 'QQ 首次登录（新建账号，via=qq）' : 'QQ 登录（via=qq）',
    );
    this.opLog.log({
      adminUserId: String(user.id),
      adminName: user.nickname ?? user.username,
      module: 'auth',
      action: 'login_by_qq',
      method: 'POST',
      path: '/auth/qq/login',
      requestBody: JSON.stringify({
        userId: String(user.id),
        provider: 'qq',
        openid: maskOpenid(cred.openid),
        isNewUser: created.created,
        via: 'qq',
      }),
      ip,
      result: 'success',
      errorMsg: null,
    });
    this.logger.log(`QQ 登录成功 userId=${user.id}（${created.created ? '本次新建账号' : '并发兜底命中已有账号'}）`);
    return { ...tokens, isNewUser: created.created, user: qqUserSummary(user) };
  }

  /**
   * 把 QQ 绑到**当前登录账号**（`POST /auth/qq/bind`；主体只取 JWT `sub`）。
   *
   * - 该 QQ 已绑到自己 → **幂等成功**（顺手刷新 unionid），不报错；
   * - 该 QQ 已绑到别的账号 → 中文 409「该 QQ 已被其他账号绑定」（唯一键 `UK_user_oauth_provider_openid` 兜并发）；
   * - 一个平台账号**可以绑多个 QQ**（表结构是 N:1；登录时任一个都能进同一个账号）——
   *   与"一个 QQ 只能绑一个平台账号"（唯一键）不冲突，两者是不同方向的约束。
   */
  async bindQq(
    userId: string,
    dto: { accessToken?: string; access_token?: string; openid?: string },
    ip: string,
    userAgent: string,
  ) {
    if (!(await this.rateLimit.allow(`qqbind:${ip}`, LOGIN_RATE_LIMIT, 60))) {
      throw new ForbiddenException('操作过于频繁，请稍后再试');
    }
    const user = await this.userRepo.findOne({ where: { id: userId } });
    if (!user) throw new UnauthorizedException('账号不存在');

    const cred = await this.verifyQqCredential(dto, ip, userAgent, 'QQ 绑定');
    const existing = await this.userOauthRepo.findOne({ where: { provider: 'qq', openid: cred.openid } });

    if (existing) {
      if (String(existing.userId) === String(userId)) {
        // 幂等：重复绑定同一个 QQ 到同一账号 → 成功（只把 unionid 刷新到最新）
        await this.userOauthRepo.update(existing.id, { unionid: cred.unionid });
        await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'success', 'QQ 重复绑定（幂等，via=qq）');
        return {
          ok: true,
          bound: true,
          alreadyBound: true,
          openid: maskOpenid(cred.openid),
          message: '该 QQ 已绑定当前账号',
        };
      }
      await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'fail', 'QQ 绑定失败：该 QQ 已绑定其他账号');
      throw new ConflictException('该 QQ 已被其他账号绑定');
    }

    try {
      await this.userOauthRepo.save(
        this.userOauthRepo.create({
          provider: 'qq',
          openid: cred.openid,
          unionid: cred.unionid,
          userId: String(user.id),
        }),
      );
    } catch (e) {
      // 并发兜底：唯一键被同时绑定撞上 → 中文 409（不是 500）
      if (isDuplicateKeyError(e)) {
        await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'fail', 'QQ 绑定失败：唯一键冲突（并发绑定）');
        throw new ConflictException('该 QQ 已被其他账号绑定');
      }
      throw e;
    }

    this.opLog.log({
      adminUserId: String(user.id),
      adminName: user.nickname ?? user.username,
      module: 'auth',
      action: 'qq_bind',
      method: 'POST',
      path: '/auth/qq/bind',
      requestBody: JSON.stringify({ userId: String(user.id), provider: 'qq', openid: maskOpenid(cred.openid), via: 'qq' }),
      ip,
      result: 'success',
      errorMsg: null,
    });
    await this.writeLoginLog('user', user.id, user.username, ip, userAgent, 'success', 'QQ 绑定（via=qq）');
    this.logger.log(`QQ 绑定成功 userId=${user.id} openid=${maskOpenid(cred.openid)}`);
    return { ok: true, bound: true, alreadyBound: false, openid: maskOpenid(cred.openid), message: 'QQ 绑定成功' };
  }

  /**
   * QQ 凭据复核（登录与绑定**共用这一份**，绝不各写一套）：
   * ① 未配置 → 中文 503（不发任何网络请求）；② 缺 access_token → 中文 400；
   * ③ 服务端换 openid/unionid（超时 ≤10s，失败按原因给中文 400/503）；
   * ④ 入参 openid 与服务端结果比对（不一致 → 中文 403「openid 与服务端复核结果不一致」）。
   */
  private async verifyQqCredential(
    dto: { accessToken?: string; access_token?: string; openid?: string },
    ip: string,
    userAgent: string,
    scene: string,
  ): Promise<{ openid: string; unionid: string | null; accessToken: string }> {
    // 未配置：**先于任何网络调用**判定（负责人要求：中文 503「QQ 登录未配置」）
    if (!this.qq.configured) {
      await this.writeLoginLog('user', null, 'qq', ip, userAgent, 'fail', `${scene}：QQ 登录未配置`);
      throw qqErrorToException('unconfigured');
    }
    // 两种入参写法都收（accessToken 为正；access_token 是腾讯文档里的下划线别名）
    const accessToken = String(dto.accessToken ?? dto.access_token ?? '').trim();
    if (!accessToken) {
      await this.writeLoginLog('user', null, 'qq', ip, userAgent, 'fail', `${scene}：缺少 access_token`);
      throw new BadRequestException('缺少 QQ 授权凭证');
    }

    const me = await this.qq.resolveOpenId(accessToken);
    if (!me.ok) {
      await this.writeLoginLog('user', null, 'qq', ip, userAgent, 'fail', `${scene}：QQ 服务端复核失败（${me.reason}）`);
      throw qqErrorToException(me.reason);
    }
    // **服务端结果为准**：客户端传的 openid 只用于比对（伪造/串号在这里被挡住）
    const clientOpenid = String(dto.openid ?? '').trim();
    if (clientOpenid && clientOpenid !== me.data.openid) {
      await this.writeLoginLog('user', null, 'qq', ip, userAgent, 'fail', `${scene}：入参 openid 与服务端复核结果不一致`);
      this.logger.warn(`${scene}：客户端 openid 与服务端复核不一致，已拒绝（可能是伪造或串号）`);
      throw new ForbiddenException('QQ 授权校验失败：openid 与服务端复核结果不一致');
    }
    return { openid: me.data.openid, unionid: me.data.unionid, accessToken };
  }

  /**
   * 建 QQ 新账号（事务：账号 + 钱包 + `user_oauth` 绑定行，三者同生共死）。
   *
   * 用户名与展示 ID **复用注册的既有生成规则**：
   * - 展示 ID（中文 ID）→ `generateUid()`：`U` + 10 位随机数字 + 唯一性重试（**与注册逐字同一实现**）；
   * - 用户名 → 注册时由用户输入，QQ 登录没有输入，因此按 openid 派生 `qq_<openid 字母数字部分>`
   *   （超 32 位截断），占用则追加 4 位随机数字重试 —— 与 `generateUid()` **同一种"生成 + 查重重试"写法**。
   * - `passwordHash = ''`：**第三方账号没有密码**（可后续用邮箱验证码重置密码来获得密码登录能力）；
   *   登录侧对空 hash 的既有处理是「账号或密码错误」，因此它无法被密码登录。
   */
  private async createQqUser(
    openid: string,
    unionid: string | null,
    nickname: string | null,
  ): Promise<{ user: User; created: boolean }> {
    const username = await this.generateQqUsername(openid);
    try {
      const user = await this.dataSource.transaction(async (em) => {
        const u = await em.save(
          em.create(User, {
            username,
            uid: await this.generateUid(),
            // 无密码账号：'' 而不是 NULL（password_hash 列 NOT NULL）；登录侧 `!user.passwordHash` 一律按"无密码"处理
            passwordHash: '',
            nickname: qqNickname(nickname, openid),
            role: 'user',
            status: 1,
            email: null,
            emailVerifiedAt: null,
          }),
        );
        // 钱包与账号同事务创建（docs/06：一人一钱包；与注册同一实现）
        await this.walletService.createWalletInTx(em, u.id);
        await em.save(em.create(UserOAuth, { provider: 'qq', openid, unionid, userId: u.id }));
        return u;
      });
      return { user, created: true };
    } catch (e) {
      // 并发兜底：同一 QQ 同时首次登录 → 唯一键撞在 user_oauth 上 → 事务整体回滚（不留孤儿账号），
      // 回到"已存在"分支用刚建好的那个账号登录（幂等：两个并发请求最终都进同一个账号）
      if (isDuplicateKeyError(e)) {
        const again = await this.userOauthRepo.findOne({ where: { provider: 'qq', openid } });
        if (again) {
          const u = await this.userRepo.findOne({ where: { id: again.userId } });
          if (u) {
            this.logger.warn(`QQ 首次登录并发冲突，复用已建账号 userId=${u.id}`);
            return { user: u, created: false };
          }
        }
        throw new ConflictException('账号创建失败，请重试');
      }
      throw e;
    }
  }

  /** QQ 账号用户名：`qq_` + openid 的字母数字部分（≤32 位），占用则加 4 位随机数字重试（与 generateUid 同写法） */
  private async generateQqUsername(openid: string): Promise<string> {
    const safe = String(openid).replace(/[^a-zA-Z0-9_]/g, '');
    const base = `qq_${safe}`.slice(0, 28);
    for (let i = 0; i < 5; i++) {
      const username = i === 0 ? base : `${base}_${randomInt(1000, 10000)}`.slice(0, 32);
      const exists = await this.userRepo.findOne({ where: { username } });
      if (!exists) return username;
    }
    throw new BadRequestException('账号生成失败，请重试');
  }

  /**
   * 封禁/停用校验（**从 login 逐字抽出，行为完全不变**）：
   * 到期自动解封继续流程；封禁中抛 403 + `errorCode=ACCOUNT_BANNED`（带结束时间）。
   *
   * 抽出目的（合并双端·身份切换）：老板在 `POST /user/identity/bind` 里绑定打手账号时，
   * 必须与打手自己登录时**同一套**封禁判定，绝不新写第二套。
   *
   * 2026-10-16 收口（封禁秒踢）：判定本身改为调用 `account-ban.check.ts` 的**纯函数**
   * `evaluateBan()` —— 守则（`JwtAuthGuard` 每请求 401）与此处（登录/绑定 403）**共用同一句话**，
   * 不再各写一遍 `bannedUntil.getTime() <= Date.now()`（安全审计 F1 的同类根因）。
   * 本方法的**对外行为逐字不变**（同样的 403、同样的 errorCode、同样的两句中文），
   * 唯一补强：到期自动解封时**一并清 `ban_reason`**（解封后残留旧原因会误导下一次封禁展示）。
   */
  async assertNotBanned(user: User, role: string, loginName: string, ip: string, userAgent: string): Promise<void> {
    const decision = evaluateBan(user.status, user.bannedUntil);
    if (decision === 'ok') return;
    const bannedUntil = user.bannedUntil;
    if (decision === 'expired') {
      // 封禁到期：自动解封，继续正常流程
      await this.userRepo.update(user.id, { status: 1, bannedUntil: null, banReason: null });
      return;
    }
    await this.writeLoginLog(role, user.id, loginName, ip, userAgent, 'fail', '账号被封禁');
    throw new HttpException(
      {
        message: bannedUntil
          ? `您的账号已被封禁，结束时间：${formatChinaTime(bannedUntil)}`
          : '您的账号已被永久封禁',
        errorCode: 'ACCOUNT_BANNED',
      },
      HttpStatus.FORBIDDEN,
    );
  }

  /**
   * 密码校验（bcrypt.compare）—— 登录与「绑定打手身份」**共用同一实现**。
   * 兼容旧账号（无 passwordHash）→ 一律 false，不抛异常。
   */
  async comparePassword(user: Pick<User, 'passwordHash'>, plain: string): Promise<boolean> {
    if (!user?.passwordHash) return false;
    return bcrypt.compare(String(plain ?? ''), user.passwordHash);
  }

  /** 登录/绑定审计留痕（复用 login_log 表；userType 记 'identity' 便于区分"登录"与"绑定"事件） */
  recordIdentityEvent(
    userId: string | null,
    username: string,
    ip: string,
    userAgent: string,
    result: 'success' | 'fail',
    reason: string | null,
  ): Promise<LoginLog> {
    return this.writeLoginLog('identity', userId, username, ip, userAgent, result, reason);
  }

  /**
   * 安全事件留痕的**通用入口**（2026-10-10 邮箱绑定/QQ 登录新增）。
   *
   * 为什么要有它：`login_log` 的落库口径（列裁剪、IP/UA 截断、userType）只有这一处实现，
   * 邮箱绑定（`EmailBindingService`）与 QQ 绑定同属"账号安全事件"，必须与
   * 邮箱注册/找回密码写**同一张表、同一批字段**；让它们各自 `repo.save(create(...))`
   * 就等于把列裁剪与截断规则复制出第二、第三份（安全审计 F1 的同类根因）。
   */
  recordLoginEvent(
    userType: string,
    userId: string | null,
    username: string,
    ip: string,
    userAgent: string,
    result: 'success' | 'fail',
    reason: string | null,
  ): Promise<LoginLog> {
    return this.writeLoginLog(userType, userId, username, ip, userAgent, result, reason);
  }

  /**
   * refresh 轮换：吊销旧 refresh，签发新对（docs/04）
   *
   * 伴随会话（2026-10-06 合并双端）：companion 的 refresh **也在同一入口轮换**，但：
   * - 轮换前校验绑定仍 active（解绑后即使 refresh 没过期也拒绝续期）；
   * - 续签只顶该账号的其它 companion，**绝不动 primary**（primary 路径逐字节不变）；
   * - 续签 TTL 仍按 companion（12h 硬上限），不会把 12h 续成 30 天。
   *
   * @param opts.requireCompanion 安全审计 F5：`POST /user/identity/refresh`（文档口径"只吃
   *   companion refreshToken"的公开接口）传 true —— **库中登记不是 companion 的令牌一律 401 中文，
   *   且在任何写操作之前返回**（旧实现会把老板 primary 的 refreshToken 当 companion 续期，
   *   顺带走 primary 轮换分支把该账号正在用的 primary 会话吊销掉，实测原 token 立刻 401）。
   * @param opts.requireRecharge 同一条闸门的充值版：`POST /user/identity/refresh-recharge-admin` 传 true
   *   —— 非 recharge 令牌（含 primary/companion）一律 401 中文，**在任何写操作之前返回**，
   *   绝不让别的会话借这个入口被轮换/吊销。
   */
  async refresh(refreshToken: string, ip: string, opts?: { requireCompanion?: boolean; requireRecharge?: boolean }) {
    let payload: { sub?: string; jti?: string; type?: string; role?: string };
    try {
      payload = await this.jwt.verifyAsync(refreshToken, {
        secret: this.config.get<string>('JWT_REFRESH_SECRET'),
      });
    } catch {
      throw new UnauthorizedException('登录已过期，请重新登录');
    }
    if (payload.type !== 'refresh' || !payload.sub || !payload.jti) {
      throw new UnauthorizedException('令牌类型错误');
    }
    const session = await this.authTokenRepo.findOne({ where: { jti: payload.jti } });
    // 会话种类以**库中登记**为准（不信任令牌载荷，防自签提权/越权续期）
    const kind: AuthTokenKind = normalizeKind(session?.kind);
    // F5：kind 闸门放在**最前面**（早于任何 update/吊销语句）——非 companion 令牌从这里出去，
    // 不可能对 primary 会话产生任何副作用。
    if (opts?.requireCompanion && kind !== 'companion') {
      throw new UnauthorizedException(COMPANION_REFRESH_ONLY);
    }
    if (opts?.requireRecharge && kind !== 'recharge') {
      throw new UnauthorizedException(RECHARGE_REFRESH_ONLY);
    }
    if (!session || session.revoked === 1) {
      throw new UnauthorizedException(
        kind === 'primary'
          ? '登录已失效，请重新登录'
          : kind === 'companion'
            ? '伴随身份已失效，请重新绑定打手账号'
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
    // 主体绑定：refresh 令牌的 sub 必须与会话登记的用户一致。
    // 否则签名密钥泄露后，可用自己的有效 jti 搭配他人 sub 铸造出他人的全新会话。
    if (String(session.userId) !== String(payload.sub)) {
      throw new UnauthorizedException('登录已失效，请重新登录');
    }
    // 会话寿命：refresh 不得超出会话登记到期时间（防用截获 jti 无限续期）
    if (session.expireAt && new Date(session.expireAt).getTime() < Date.now()) {
      throw new UnauthorizedException(
        kind === 'primary'
          ? '登录已过期，请重新登录'
          : kind === 'companion'
            ? '伴随身份已过期，请重新绑定打手账号'
            : '受限管理身份已过期，请重新绑定管理员账号',
      );
    }
    const user = await this.userRepo.findOne({ where: { id: session.userId } });
    if (!user || user.status !== 1) {
      throw new UnauthorizedException('账号不可用');
    }
    // companion：每次续期都校验绑定仍 active（解绑/绑定关系被删 → 立即失效）。
    // 校验实现与 HTTP 守卫、WS 网关**共用同一份**（`checkCompanionSession`）：
    // 绑定 active + 打手即会话主体 + 打手未封禁/档案在职 + 老板未封禁（安全审计 F1：不再各写一套）。
    if (kind === 'companion') {
      const check = await checkCompanionSession(this.dataSource, {
        bindingId: session.bindingId,
        userId: String(session.userId),
      });
      if (!check.ok) {
        throw new UnauthorizedException(check.message);
      }
    }
    // recharge：每次续期都校验仍在白名单 + 未封禁 + 仍是 admin（移出白名单 → 续期即失效）
    if (kind === 'recharge') {
      const check = await checkRechargeSession(this.dataSource, { userId: String(session.userId) });
      if (!check.ok) {
        throw new UnauthorizedException(check.message);
      }
    }
    // 轮换：条件吊销旧 refresh（防竞态：若此刻已被新设备顶掉则拒绝，不误伤新会话）
    const r = await this.authTokenRepo.update({ id: session.id, revoked: 0 }, { revoked: 1 });
    if ((r.affected ?? 0) !== 1) {
      const cur = await this.authTokenRepo.findOne({ where: { jti: payload.jti } });
      if (cur?.revoked === 2) {
        throw new UnauthorizedException(
          kind === 'primary'
            ? '账号已在其他设备登录'
            : kind === 'companion'
              ? '伴随身份已失效（该打手账号已在别处登录），请重新绑定'
              : '受限管理身份已失效（该管理员账号已在别处登录），请重新绑定',
        );
      }
      throw new UnauthorizedException('登录已失效，请重新登录');
    }
    // 同设备轮换：旧会话按普通失效处理（不触发"顶掉"语义）
    // 受限会话沿用自身语义与绑定；primary 调用与历史完全一致（不传 opts，逐字节不变）
    return kind === 'primary'
      ? this.issueTokens(user, false)
      : this.issueTokens(user, false, { kind, bindingId: session.bindingId });
  }

  /** 修改密码（账号与安全，负责人设置需求）：校验旧密码 → 更新 → 吊销全部会话（含当前，需重新登录） */
  async changePassword(userId: string, dto: { oldPassword: string; newPassword: string }) {
    const user = await this.userRepo
      .createQueryBuilder('u')
      .addSelect('u.passwordHash')
      .where('u.id = :userId', { userId })
      .getOne();
    if (!user || !user.passwordHash) throw new UnauthorizedException('账号不存在');
    const okOld = await bcrypt.compare(dto.oldPassword ?? '', user.passwordHash);
    if (!okOld) throw new BadRequestException('原密码不正确');
    if (!dto.newPassword || dto.newPassword.length < 8 || dto.newPassword.length > 64) {
      throw new BadRequestException('新密码须为 8-64 位');
    }
    await this.userRepo.update(user.id, { passwordHash: await bcrypt.hash(dto.newPassword, 10) });
    // 改密后全部会话吊销（安全惯例：防旧设备继续在线）
    await this.authTokenRepo.update({ userId: user.id, revoked: 0 }, { revoked: 1 });
    return { ok: true };
  }

  /**
   * 登出：**把这次登录在 `auth_token` 里登记的全部行（access + refresh）一次性吊销**。
   *
   * ============================ 为什么必须保证 refresh 也被吊销 ============================
   * 旧实现只吊销"调用方给的那几个 jti"：
   * ```ts
   * await update({ jti: accessJti }, { revoked: 1 });     // 永远只吊销 access
   * if (refreshToken) { ...吊销 refreshToken 里的 jti... } // 客户端不传就什么都不做
   * ```
   * 于是"登出"是否干净**取决于客户端传没传 refreshToken**，而 `LogoutDto.refreshToken`
   * 是**可选**字段（`@IsOptional()`）。实测（2026-10-07 自证脚本 `recharge-proof-live-proof.js`
   * 的 `post('/auth/logout', restricted)` —— 只给 access）跑完 logout 后库里**残留**
   * `kind='recharge' / revoked=0` 一行、TTL 还剩约 3.9 小时：
   * 已"退出登录"的会话**仍能用这枚 refresh 换到新的 access**（`POST /auth/refresh` 只看 refresh 行），
   * 也就是**等于没退干净**。同类风险对 primary（老板端/工作端/管理端）与 companion（打手态）完全一样。
   *
   * ============================ 配对关系怎么定（不改表结构的取舍）============================
   * `auth_token` **没有** `family_id` / `session_id` 这类族标识列（docs/02），只有
   * `jti / user_id / role / kind / binding_id / expire_at / revoked / created_at`。
   * 可选路子与取舍：
   * - **① 按 `created_at` 时间窗配对**（找与 access 行同一批签发的 refresh 行）——
   *   ❌ 覆盖不全：签发那一刻是配对的，但**只要中间调过一次 `POST /auth/refresh` 轮换**，
   *   新 refresh 行的 `created_at` 就跑到几小时后去了；更别说"签发后一直没续期、很久以后才登出"。
   *   本任务要修的正是"登出后还有活 refresh"，用时间窗等于**把 bug 修成偶发**。
   * - **② 按 `user_id + kind` 收口**（本实现采用）—— 与**既有会话形态逐字一致**：
   *   三类会话在本平台**各自都只有一条活会话**，
   *   `issueTokens()` 每次签发都会把"同账号同族"的其它未吊销行先置 `revoked=1`
   *   （primary 见 `WHERE user_id=? AND kind='primary'`；companion/recharge 见 `WHERE kind=?` 那条），
   *   所以"该账号该族的活行集合"**恒等于**"这一次登录的那一对"。
   *   ⇒ 吊销它 = 精确吊销"我这次登录的全部令牌"，**不多不少**。
   * - **③ 加族标识列**：最干净，但要 migration 改表结构 —— 本任务明确要求**不改表结构**，故不采用。
   *
   * ============================ 语义边界（一条都不能松）============================
   * - **只吊销自己**：`WHERE user_id = 会话登记主体 AND kind = 本会话的 kind`。
   *   `userId` 由控制器传**守卫从库中登记行取出**的主体（`request.user.userId`），**绝不信任请求体**；
   * - **绝不影响其它 kind**（本条是硬要求）：`kind` 同样取自**库中 access 行**（不取令牌载荷）——
   *   companion 登出**绝不动 primary**（老板在管理端/老板态的登录照常），recharge 登出同理；
   * - **primary ↔ primary 互斥铁律不变**：该规则在 `issueTokens()`（登录/续期顶号置 `revoked=2`），
   *   本方法**不做任何跨会话判定**，只是把"同一族"的活行收干净 —— 登出不是踢别人下线。
   *
   * ============================ 返回值：给调用方踢 WS 用 ============================
   * 返回被吊销的 jti 列表（`revokedJtis`）——登出后**已建立的 WS 连接必须主动断开**，
   * 否则"HTTP 已 401、旧 WS 仍能收发消息"（安全审计 F1 的同一类根因）。
   *
   * @returns `{ ok, revoked, revokedJtis }`；`revoked` 是实际置 1 的行数（含 refresh ⇒ 正常为 2）。
   */
  async logout(accessJti: string, refreshToken?: string, userId?: string) {
    const kind = await this.resolveSessionKind(accessJti);
    // 前置条件①：吊销列表**一定包含本次 access 行**（即使它已被标记过——重复登出幂等）
    const jtis = new Set<string>([accessJti]);
    // 前置条件②：调用方带来的 refreshToken 也算一份（且做归属校验，见下）
    if (refreshToken) {
      const payload = await this.parseRefreshToken(refreshToken);
      if (payload?.jti) jtis.add(String(payload.jti));
    }
    let revoked = 0;
    if (userId) {
      // 读"该账号该族的全部活行"（access + refresh）——**先查后改**，为的是拿到 jti 去踢 WS
      const rows: Array<{ jti: string }> = await this.dataSource.query(
        `SELECT jti FROM auth_token WHERE user_id = ? AND kind = ? AND revoked = 0`,
        [String(userId), kind],
      );
      for (const r of rows) jtis.add(String(r.jti));
      const res = await this.authTokenRepo.update(
        { userId: String(userId), kind, revoked: 0 },
        { revoked: 1 },
      );
      revoked = res.affected ?? 0;
    } else {
      // 理论不可达（控制器必传 userId：守卫已从库中取出登记主体）。留兜底是为了"宁少杀不漏杀"：
      // 拿不到主体时只吊销明确点名的那几个 jti，**绝不**按 user_id 猜（那就可能误伤同账号其他会话）。
      const r = await this.authTokenRepo.update({ jti: In([...jtis]), revoked: 0 }, { revoked: 1 });
      revoked = r.affected ?? 0;
    }
    // 调用方带来的 refresh 做一次**归属校验 + 兜底吊销**：
    // 只在"该行确实存在、确实属于本次登出的账号、且 kind 相同"时命中（防"拿别人的 refresh 打我的登出"把它踢下线）。
    // 正常路径下它已在上面的同族吊销里被置 1，这里 affected=0，纯兜底。
    if (refreshToken && userId) {
      try {
        const payload = await this.parseRefreshToken(refreshToken);
        if (payload?.jti) {
          const r = await this.authTokenRepo.update(
            { jti: String(payload.jti), userId: String(userId), kind, revoked: 0 },
            { revoked: 1 },
          );
          revoked += r.affected ?? 0;
        }
      } catch {
        // refresh 无效则忽略（access 与同族行都已吊销）
      }
    }
    this.logger.log(`登出吊销会话 kind=${kind} 行数=${revoked} jti=${[...jtis].length} 个`);
    return { ok: true, revoked, revokedJtis: [...jtis] };
  }

  /**
   * 取 `auth_token` 中该 jti 的**会话种类**（`kind`）与主体，作为登出收口的唯一依据。
   *
   * 为什么必须查库、而不是读令牌载荷里的 `kind`：载荷是签名者写的，**库中登记行才是权威**
   * （与 `JwtAuthGuard` / `refresh()` / `RealtimeGateway.assertSessionActive` 同一条口径：
   * "会话种类以库中登记为准，不信任令牌载荷，防自签提权"）。
   *
   * 为什么取 access 行的 `user_id` 而不是 `binding_id`（companion 会话）：companion 行的
   * `user_id` 就是**打手**账号（安全审计 F1-c 已明确），而 companion 的 refresh 行与之同账号同 kind，
   * 按 `user_id + kind` 收口天然覆盖；若按 binding_id 收口反而会牵进 primary（那是明确的越权面）。
   *
   * 找不到 `kind` 时回落 `primary`：登出**只可能**缩到"该账号的 primary 族"，
   * 不影响 companion/recharge —— 与全站"未知值一律回落 primary"的既有归一化口径一致。
   */
  private async resolveSessionKind(accessJti: string): Promise<AuthTokenKind> {
    const rows: Array<{ kind: string | null }> = await this.dataSource.query(
      `SELECT kind FROM auth_token WHERE jti = ? LIMIT 1`,
      [accessJti],
    );
    return normalizeKind(rows[0]?.kind);
  }

  /** 校验并解出 refresh 令牌载荷的 jti（签名/类型/主体不合格一律返回 null，登出流程不因此报错） */
  private async parseRefreshToken(refreshToken: string): Promise<{ jti?: string; sub?: string } | null> {
    try {
      const payload: { sub?: string; jti?: string; type?: string } = await this.jwt.verifyAsync(refreshToken, {
        secret: this.config.get<string>('JWT_REFRESH_SECRET'),
      });
      if (payload?.type !== 'refresh' || !payload?.jti) return null;
      return payload;
    } catch {
      return null;
    }
  }

  /** 当前主体信息（按 role 附带工作端/管理员档案，docs/04） */
  /**
   * 背景媒体是图片还是视频（2026-10-21）
   *
   * `bg` 存图片、`bg_video` 存 mp4，两者共用 `user.background_media_id`。
   * 客户端拿到这个类型才能选对渲染方式：图片 → `Image.network`（GIF 自动播），
   * 视频 → 循环播放器。查不到（历史数据被删 / 无背景）一律返回 null，客户端按"无背景"处理。
   */
  private async resolveBackgroundType(
    mediaId: string | null,
  ): Promise<'image' | 'video' | null> {
    if (!mediaId) return null;
    try {
      const rows: Array<{ mime_type: string }> = await this.dataSource.query(
        'SELECT mime_type FROM media WHERE id = ? LIMIT 1',
        [mediaId],
      );
      const mime = rows?.[0]?.mime_type ?? '';
      if (!mime) return null;
      return mime.startsWith('video/') ? 'video' : 'image';
    } catch {
      // 类型查询失败不该让 /auth/me 整个 500：退化成"无背景"，页面照常可用
      return null;
    }
  }

  async me(authUser: { userId: string; role: string }) {
    const user = await this.userRepo.findOne({ where: { id: authUser.userId } });
    if (!user) {
      throw new UnauthorizedException('账号不存在');
    }
    const base = {
      id: user.id,
      username: user.username,
      uid: user.uid,
      nickname: user.nickname,
      avatarMediaId: user.avatarMediaId,
      backgroundMediaId: user.backgroundMediaId,
      // 背景是图还是视频（2026-10-21）
      //
      // 客户端必须知道这一位才能决定用 `Image.network` 还是视频播放器 ——
      // 只凭 mediaId 猜不出来（`/media/public/:id` 不带扩展名）。
      // 一次主键查询，无 N+1：每请求最多 1 次，且仅在有背景时发生。
      backgroundType: await this.resolveBackgroundType(user.backgroundMediaId),
      role: user.role,
      status: user.status,
      level: Number(user.level),
      totalSpent: Number(user.totalSpent),
    };
    if (user.role === 'worker') {
      const worker = await this.workerRepo.findOne({ where: { userId: user.id } });
      // 分部接单权限（负责人 2026-10-04）：工作端「我的」页展示自己有哪些分部的接单权限。
      // 实时查库（无缓存）——管理端刚授/刚撤的权，下次取 me 立刻反映。
      const divisionPermissions = worker ? (await this.divisionPerm.listWithFlags(worker.id)) : [];
      return {
        ...base,
        worker: worker
          ? {
              workerNo: worker.workerNo,
              canTakeOrder: worker.canTakeOrder === 1,
              canServeCustomer: worker.canServeCustomer === 1,
              status: worker.status,
              // 全部分部（含未授权的），客户端只展示已授权的那几个
              divisionPermissions,
            }
          : null,
      };
    }
    if (user.role === 'admin') {
      const admin = await this.adminRepo.findOne({ where: { userId: user.id } });
      const role = admin ? await this.adminRoleRepo.findOne({ where: { id: admin.roleId } }) : null;
      const permissions: { code: string }[] = role
        ? await this.dataSource.query(
            `SELECT p.code FROM admin_role_permission arp
             JOIN permission p ON p.id = arp.permission_id
             WHERE arp.role_id = ?`,
            [role.id],
          )
        : [];
      return {
        ...base,
        admin: {
          roleCode: role?.code ?? null,
          permissions: permissions.map((p) => p.code),
          // 所有者标记：前端据此显示「封号/注销其他管理员」按钮（服务端仍二次校验）
          isOwner: admin?.isOwner === 1,
        },
      };
    }
    return base;
  }

  /**
   * 签发新令牌对。
   * @param replaceOthers 新设备登录=true：顶掉该账号同族旧会话（revoked=2，旧端提示"账号已在其他设备登录"）；
   *                      refresh 轮换=false：旧会话按普通失效处理（revoked=1）
   * @param opts.kind     会话种类（默认 primary）——**三类会话互不干扰**（方案甲 + 充值管理员态）：
   *   - `primary`（普通登录：老板端/工作端/管理端）：只吊销**同账号的其它 primary**，
   *     `replaceOthers=true` 时置 `revoked=2`（"账号已在其他设备登录"），否则置 1。
   *     **单设备铁律逐字不变**：同账号第二次登录仍然顶掉第一次（测试钉死）。
   *   - `companion`（伴随会话）：只吊销同账号的其它 companion（revoked=1），**绝不触碰 primary**。
   *   - `recharge`（受限充值管理员会话）：只吊销同账号的其它 recharge（revoked=1），**绝不触碰 primary**
   *     —— 负责人定案"管理员态绝不顶掉 primary"：管理员在管理端的登录必须照常可用。
   *
   * 为什么 primary 的吊销语句要带 `kind='primary'`（2026-10-06 关键设计取舍）：
   * 设计稿 §3.2 承诺「阶段 2 用 companion 会话后两端**不再互相影响**」，R2 把不变式写成
   * 「**primary 之间仍互斥**；companion 每设备最多 1 条」。若 primary 登录把 companion 一起顶掉，
   * 打手手机上仍在运行的旧版工作端 App **每 2 小时续期一次**就会把老板的打手态踢下线
   * （提示"伴随身份已失效"，还要重新输打手账密）——"伴随"就不成立了。
   * 加 `kind='primary'` 后：**在只存在 primary 的世界里，语句与历史逐字节等价**
   * （没有 companion 行时过滤条件恒真），单设备语义一点没松；
   * 而 companion 侧仍有 12h TTL + 每请求校验绑定 + 解绑即吊销三重约束。
   */
  private async issueTokens(user: User, replaceOthers = true, opts?: IssueTokenOptions): Promise<TokenPair> {
    const kind: AuthTokenKind = normalizeKind(opts?.kind);
    // bindingId 只对 companion 有意义（recharge 的主体就是管理员账号本身，不需要绑定行）
    const bindingId = kind === 'companion' ? (opts?.bindingId ?? null) : null;
    if (kind === 'primary') {
      // 单设备登录铁律的落地点：同账号再登录 → 旧 primary 置 2（顶号），文案与历史完全一致
      await this.authTokenRepo.update(
        { userId: user.id, kind: 'primary', revoked: 0 },
        { revoked: replaceOthers ? 2 : 1 },
      );
    } else {
      /**
       * 受限会话（companion / recharge）：**只顶掉"同一账号的同类会话"**，primary 行不在命中范围。
       *
       * 两个 kind 用同一条语句是刻意的 —— 它们的语义完全一致（"非 primary 的受限会话各自成族"），
       * 将来再加第三种受限会话也不必改这里。`WHERE kind = ?` 而不是写死 kind，正是为此。
       */
      await this.authTokenRepo.update({ userId: user.id, kind, revoked: 0 }, { revoked: 1 });
    }
    // 受限会话统一 12h 硬上限（access 与 refresh 同 TTL）：到点必须重新输账密切换
    const restricted = kind !== 'primary';
    const accessTtl = restricted ? COMPANION_ACCESS_TTL_SECONDS : ACCESS_TTL_SECONDS;
    const refreshTtl = restricted ? COMPANION_REFRESH_TTL_SECONDS : REFRESH_TTL_SECONDS;
    const accessJti = randomUUID();
    const refreshJti = randomUUID();
    const accessExpireAt = new Date(Date.now() + accessTtl * 1000);
    const refreshExpireAt = new Date(Date.now() + refreshTtl * 1000);
    const accessSecret = this.config.get<string>('JWT_ACCESS_SECRET');
    const refreshSecret = this.config.get<string>('JWT_REFRESH_SECRET');

    const [accessToken, refreshToken] = await Promise.all([
      this.jwt.signAsync(
        // kind/bindingId 仅供观测与客户端分流：**任何校验都以库中 auth_token 行为准**，不信任载荷
        { type: 'access', role: user.role, kind, bindingId },
        { secret: accessSecret, subject: String(user.id), jwtid: accessJti, expiresIn: accessTtl },
      ),
      this.jwt.signAsync(
        { type: 'refresh', role: user.role, kind, bindingId },
        { secret: refreshSecret, subject: String(user.id), jwtid: refreshJti, expiresIn: refreshTtl },
      ),
    ]);

    await this.authTokenRepo.save([
      this.authTokenRepo.create({
        jti: accessJti,
        userId: user.id,
        role: user.role,
        kind,
        bindingId,
        expireAt: accessExpireAt,
      }),
      this.authTokenRepo.create({
        jti: refreshJti,
        userId: user.id,
        role: user.role,
        kind,
        bindingId,
        expireAt: refreshExpireAt,
      }),
    ]);
    return { accessToken, refreshToken, expiresIn: accessTtl };
  }

  /**
   * 签发**伴随会话**（companion）—— 只由"老板绑定打手账号"这一条路径调用（`/user/identity/bind`）。
   *
   * 安全属性（设计稿 R2 的缓解措施，逐条可验证）：
   * - 只能由绑定关系签发：`bindingId` 指向 `worker_identity_binding` 的 active 行；
   * - 不顶 primary：见 [issueTokens] 的 companion 分支；
   * - TTL 12h（access 与 refresh 同）：到点必须用打手账密重新切换；
   * - 每请求校验绑定有效性：见 `JwtAuthGuard`（解绑后即使令牌未过期也立即 401）；
   * - 可撤销：**任何释放路径**（老板主动解绑 / 打手停用 / 封禁 / 删除）都会按 `binding_id`
   *   批量吊销该绑定的全部 companion 会话 —— 实现只有一处：`worker-binding-release.ts` 的
   *   `releaseBindings()`（安全审计 F1-b 收口；本类不再提供第二份吊销助手，避免将来有人只调它、
   *   漏掉"释放绑定 + 审计 + 断开 WS"）。
   */
  async issueCompanionTokens(user: User, bindingId: string): Promise<TokenPair> {
    return this.issueTokens(user, false, { kind: 'companion', bindingId: String(bindingId) });
  }

  /**
   * 签发**受限充值管理员会话**（`kind='recharge'`）—— 只由
   * `POST /user/identity/bind-recharge-admin` 这一条路径调用。
   *
   * 安全属性（与 companion 同构，逐条可验证）：
   * - `recharge_admin` **白名单**是前置条件（不在名单里根本签发不出来）；
   * - **不顶 primary**：只吊销该账号的其它 recharge（管理员在管理端的登录照常可用）；
   * - TTL 12h（access 与 refresh 同）：到点必须重新输管理员账密；
   * - 每请求校验仍在白名单 + 未封禁 + 仍是 admin（见 `JwtAuthGuard` → `checkRechargeSession`）；
   * - 可撤销：移出白名单时按 `user_id + kind='recharge'` 批量吊销并断开 WS
   *   （`RechargeService.removeAdmin()`，唯一入口）。
   */
  async issueRechargeTokens(user: User): Promise<TokenPair> {
    return this.issueTokens(user, false, { kind: 'recharge' });
  }

  /**
   * 批量吊销某账号的**全部受限充值管理员会话**（`kind='recharge'` 且未吊销），返回被吊销的 jti 列表。
   *
   * 为什么返回 jti 而不是只回 affected：调用方（`RechargeService.removeAdmin`）需要拿这批 jti
   * 去 `RealtimeGateway.disconnectByJti()` **主动断开**已建立的 WS 连接 —— 与 companion 的
   * `worker-binding-release.ts` 同一口径（只 UPDATE 不踢线 = 旧连接继续收消息，正是安全审计 F1）。
   * **绝不动 primary**：`WHERE kind='recharge'` 把 primary/companion 行排除在外。
   */
  async revokeRechargeTokens(userId: string): Promise<{ jtis: string[]; affected: number }> {
    const rows: Array<{ jti: string }> = await this.dataSource.query(
      `SELECT jti FROM auth_token WHERE user_id = ? AND kind = 'recharge' AND revoked = 0`,
      [String(userId)],
    );
    const r = await this.authTokenRepo.update({ userId: String(userId), kind: 'recharge', revoked: 0 }, { revoked: 1 });
    return { jtis: rows.map((x) => String(x.jti)), affected: r.affected ?? 0 };
  }

  /** 对外展示 ID：U + 10 位数字，唯一冲突重试 */
  private async generateUid(): Promise<string> {
    for (let i = 0; i < 5; i++) {
      const uid = `U${randomInt(1_000_000_000, 10_000_000_000)}`;
      const exists = await this.userRepo.findOne({ where: { uid } });
      if (!exists) {
        return uid;
      }
    }
    throw new BadRequestException('ID 生成失败，请重试');
  }

  /**
   * 邮箱归一化：去首尾空白 + 转小写。
   *
   * 实现**只有一份**（`email-code.service.ts` 的 `normalizeEmail`）：Redis 验证码键是大小写敏感的字节比较，
   * 而 MySQL 唯一索引是大小写不敏感的 —— 两处各写一遍必然分叉（邮箱绑定/邮箱登录都要用同一规则）。
   */
  private normalizeEmail(raw?: string | null): string | null {
    return normalizeEmail(raw);
  }

  private writeLoginLog(
    userType: string,
    userId: string | null,
    username: string,
    ip: string,
    userAgent: string,
    result: 'success' | 'fail',
    failReason: string | null,
  ) {
    return this.loginLogRepo.save(
      this.loginLogRepo.create({
        userType,
        userId,
        /**
         * `login_log.username` 只有 varchar(32)，而**邮箱验证码路径**（登录/找回/取码）在这里传的是**邮箱**
         * （最长 120，`user.email` 的口径）—— 2026-10-10 实测：一个 35 字符的邮箱直接
         * `Data too long for column 'username'` → 未捕获异常 → **登录接口 500**（本该是中文 400）。
         *
         * 这里按 32 位截断，与同一个 create 里 `ip`/`userAgent` 已有的 `.slice()` 完全同一写法：
         * - 老路径（账号名 ≤32，DTO 已限制）**逐字不变**；
         * - 长邮箱（>32）从"500"变成"留痕为前缀 32 字符" —— 这是修复，不是行为变更。
         */
        username: String(username ?? '').slice(0, 32),
        ip: ip?.slice(0, 64) ?? null,
        userAgent: userAgent?.slice(0, 255) ?? null,
        result,
        failReason,
      }),
    );
  }
}

/** 封禁截止时间展示：数据库存 UTC，转为中国时间（UTC+8）显示 */
function formatChinaTime(d: Date): string {
  const t = new Date(d.getTime() + 8 * 3600_000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${t.getUTCFullYear()}-${p(t.getUTCMonth() + 1)}-${p(t.getUTCDate())} ${p(t.getUTCHours())}:${p(t.getUTCMinutes())}`;
}

/**
 * MySQL 唯一键冲突识别（ER_DUP_ENTRY=1062 / SQLSTATE 23000）。
 * 用途：并发注册撞上 `UQ_user_email` 或用户名唯一约束时返回中文 409，而不是把 500 抛给客户端。
 *
 * 2026-10-10 起**导出**：邮箱绑定（`UQ_user_email`）与 QQ 绑定（`UK_user_oauth_provider_openid`）
 * 走的是同一条并发兜底判定 —— 复制第二份 `errno === 1062` 判断必然有一天分叉。
 */
export function isDuplicateKeyError(e: unknown): boolean {
  const err = e as { code?: string; errno?: number; driverError?: { code?: string; errno?: number } };
  const code = err?.code ?? err?.driverError?.code;
  const errno = err?.errno ?? err?.driverError?.errno;
  return code === 'ER_DUP_ENTRY' || errno === 1062;
}

/** openid 脱敏（审计/日志里不出现完整第三方标识）：前 4 位 + **** + 后 4 位 */
function maskOpenid(openid: string): string {
  const s = String(openid ?? '');
  if (s.length <= 8) return s.slice(0, 2) + '****';
  return `${s.slice(0, 4)}****${s.slice(-4)}`;
}

/**
 * QQ 昵称落库前的清洗（`user.nickname` 是 varchar(32)）：
 * 去掉控制字符（换行/制表符会把日志与列表撑乱），按**字符**（而非 UTF-16 码元）截断 32 —— 
 * 否则 emoji/生僻字会被截成半个代理对（客户端渲染成乱码方框）。
 */
function qqNickname(nickname: string | null, openid: string): string {
  const cleaned = String(nickname ?? '')
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim();
  if (!cleaned) return `QQ用户${String(openid).slice(-4)}`;
  return Array.from(cleaned).slice(0, 32).join('');
}

/** 登录响应里的账号摘要（与 /auth/me 的字段口径一致，只取客户端首屏需要的） */
function qqUserSummary(user: User): { id: string; username: string; uid: string; nickname: string } {
  return { id: String(user.id), username: user.username, uid: user.uid, nickname: user.nickname };
}
