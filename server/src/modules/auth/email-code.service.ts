import { BadRequestException, HttpException, HttpStatus, Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomInt } from 'crypto';
import Redis from 'ioredis';
import { maskEmail } from '../../common/mail/mailer.service';

/**
 * 验证码用途（互不占用，同一邮箱各场景各自独立计码）：
 * - `register` 注册（2026-10-05 既有）
 * - `reset`    找回密码（2026-10-05 既有；**仅当该邮箱已注册才真发信**，未注册 → 静默成功，防枚举。
 *              ⚠️ 与 `login` 同款不变量：静默分支也**照扣额度**，且限流判定必须前置到"邮箱是否存在"之前，
 *              否则"同一邮箱连发第二次"的 429/200 差异就是账号枚举 oracle —— 2026-10-10 修复）
 * - `bind`     绑定/换绑邮箱（2026-10-10 新增；**与登录码分离**：绑定要当前密码 + 新邮箱码）
 * - `login`    邮箱验证码登录（2026-10-10 新增；**仅当该邮箱已绑定某账号才真发信**，防枚举。
 *              ⚠️ "不发信"≠"不消耗额度"：限流判定与额度消耗必须在"是否已绑定"判定**之前**且两条分支一致，
 *              否则同一邮箱连发第二次会得到 429（已绑定）/ 200（未绑定）→ 账号枚举 oracle）
 *
 * 场景键是 Redis 键的一部分（`email:code:{scene}:{email}`），因此**旧场景的键名与语义逐字未变**：
 * 新增两个场景不会复用/覆盖注册与找回的码。
 */
export type EmailScene = 'register' | 'reset' | 'bind' | 'login';

/** 全部合法场景（DTO 校验与测试端点共用一份，避免两处列表分叉） */
export const EMAIL_SCENES: readonly EmailScene[] = ['register', 'reset', 'bind', 'login'];

/** 场景合法性判定（类型守卫：测试端点用它，避免把新场景漏在 if 链外） */
export function isEmailScene(value: unknown): value is EmailScene {
  return typeof value === 'string' && (EMAIL_SCENES as readonly string[]).includes(value);
}

/** 校验结果（不抛异常，由业务层决定文案） */
export type VerifyOutcome =
  | { ok: true }
  | { ok: false; reason: 'none' | 'expired' | 'wrong' | 'too_many' };

/** 错误次数上限：错 ≥5 次该码作废（docs 安全口径） */
const MAX_ATTEMPTS = 5;
/** 计数键存活时长：必须长于码 TTL，否则「错满 5 次」会随码一起被清理而失去封堵意义 */
const ATTEMPT_TTL_SECONDS = 1800;

/**
 * 邮箱归一化：去首尾空白 + 转小写（**唯一实现**，AuthService 与 EmailBindingService 共用）。
 *
 * 为什么必须做：`A@qq.com` 与 `a@qq.com` 在 MySQL utf8mb4_0900_ai_ci 下本就判等（唯一索引生效），
 * 但 Redis 验证码键是**大小写敏感**的字节比较 —— 不归一化就会出现「用大写取码、小写验码」拿不到码的诡异失败。
 */
export function normalizeEmail(raw?: string | null): string | null {
  const v = String(raw ?? '').trim().toLowerCase();
  return v.length > 0 ? v : null;
}

/**
 * 邮箱验证码服务（负责人 2026-10-05）
 *
 * 存储（Redis，**键含 email + scene**）：
 * - `email:code:{scene}:{email}`   → JSON `{code, exp}`；**TTL = MAIL_CODE_TTL_SECONDS（默认 600s）**。
 *   `exp` 是权威过期时间：即使 Redis 尚未回收键，超过 exp 也一律判过期（不依赖 Redis 回收时序）。
 * - `email:try:{scene}:{email}`    → 错误次数计数（TTL 1800s）
 * - `email:last:{scene}:{email}`   → 最近一次成功发信时间戳（配合 60s 重发限制兜底）
 *
 * 安全要点：
 * 1. **一次性作废**：校验通过即删除码与错误计数，同一码不能用第二次。
 * 2. **错 ≥5 次作废**：第 5 次失败即删除码（并保留计数至 TTL），之后一律「验证码已失效」。
 * 3. **限流**：同邮箱 60s 内不可重发 / 同邮箱每小时 ≤5 次 / 同 IP 每小时 ≤10 次（Redis 固定窗口）。
 *    `assertRateLimits()` 只读判定、`consumeQuota()` 才写额度；**`scene=login` 未绑定邮箱与 `scene=reset`
 *    未注册邮箱也照样写**（额度对称是防枚举的一部分，见 `consumeQuota()` 与 AuthService.sendEmailCode
 *    的顺序不变量注释）。
 * 4. **响应绝不回显验证码**（生产）。
 * 5. **测试注入点**：`MAIL_DRIVER=console`（仅开发/测试）时允许经 Redis 开关把发信结果打桩为失败，
 *    用于断言「发信失败 → 中文提示 + 不产生脏数据」。**生产（smtp）下该开关被忽略**。
 */
@Injectable()
export class EmailCodeService {
  private readonly logger = new Logger('EmailCode');
  private readonly redis: Redis;

  constructor(private readonly config: ConfigService) {
    this.redis = new Redis({
      host: config.get<string>('REDIS_HOST', '127.0.0.1'),
      port: config.get<number>('REDIS_PORT', 6380),
      password: config.get<string>('REDIS_PASSWORD', '') || undefined,
      lazyConnect: true,
      maxRetriesPerRequest: 2,
    });
  }

  /** 码有效期（秒） */
  get ttlSeconds(): number {
    const n = Number(this.config.get<string | number>('MAIL_CODE_TTL_SECONDS', 600));
    return Number.isFinite(n) && n > 0 ? Math.floor(n) : 600;
  }

  /** 重发间隔（秒） */
  get resendSeconds(): number {
    const n = Number(this.config.get<string | number>('MAIL_CODE_RESEND_SECONDS', 60));
    return Number.isFinite(n) && n > 0 ? Math.floor(n) : 60;
  }

  /** 限流参数（默认值；`MAIL_IP_HOURLY_LIMIT` 可覆盖 IP 档，便于测试用小额度验证限流而不用真发 10 封） */
  static readonly LIMITS = {
    /** 同邮箱每小时 ≤5 次 */
    perEmailPerHour: 5,
    /** 同 IP 每小时 ≤10 次（默认；可用 env 覆盖） */
    perIpPerHour: 10,
  } as const;

  /** 同 IP 每小时上限（env 可覆盖，默认 10） */
  private get ipHourlyLimit(): number {
    const n = Number(this.config.get<string | number>('MAIL_IP_HOURLY_LIMIT', EmailCodeService.LIMITS.perIpPerHour));
    return Number.isFinite(n) && n > 0 ? Math.floor(n) : EmailCodeService.LIMITS.perIpPerHour;
  }

  private codeKey(scene: EmailScene, email: string): string {
    return `email:code:${scene}:${email}`;
  }
  private tryKey(scene: EmailScene, email: string): string {
    return `email:try:${scene}:${email}`;
  }
  private lastKey(scene: EmailScene, email: string): string {
    return `email:last:${scene}:${email}`;
  }

  /** 生成 6 位数字码（crypto.randomInt，非 Math.random —— 验证码是安全凭据） */
  private generateCode(): string {
    return String(randomInt(0, 1_000_000)).padStart(6, '0');
  }

  /**
   * 限流检查（**只读判断 + 计数**，第 1 步失败前端拿不到任何副作用）。
   * 三档全部命中才写入计数键，避免「因为发信失败也把用户额度扣掉」。
   */
  async assertRateLimits(email: string, scene: EmailScene, ip: string): Promise<void> {
    // 1) 60 秒重发限制（最严，先报这条，用户最可能遇到）
    const last = await this.redis.get(this.lastKey(scene, email));
    if (last) {
      const elapsed = Math.floor((Date.now() - Number(last)) / 1000);
      const wait = Math.max(1, this.resendSeconds - elapsed);
      throw new HttpException(`请求过于频繁，请 ${wait} 秒后再试`, HttpStatus.TOO_MANY_REQUESTS);
    }
    // 2) 同邮箱每小时 ≤5 次
    const emailCount = Number((await this.redis.get(`email:cnt:${scene}:${email}`)) ?? 0);
    if (emailCount >= EmailCodeService.LIMITS.perEmailPerHour) {
      throw new HttpException('该邮箱今日获取验证码次数过多，请 1 小时后再试', HttpStatus.TOO_MANY_REQUESTS);
    }
    // 3) 同 IP 每小时 ≤10 次
    const ipKey = `email:cnt:ip:${ip}`;
    const ipCount = Number((await this.redis.get(ipKey)) ?? 0);
    if (ipCount >= this.ipHourlyLimit) {
      throw new HttpException('当前网络获取验证码次数过多，请 1 小时后再试', HttpStatus.TOO_MANY_REQUESTS);
    }
  }

  /**
   * 发放额度（限流通过且确实要"占用一次取码机会"时才调用）：写 60s 重发锁 + 两个小时计数。
   *
   * **两个调用方**（两者额度语义必须完全一致，否则会产生可观测差异）：
   * 1. `markSent()` —— 真发信成功后（register / reset / bind 与 login 已绑定路径）；
   * 2. **不发信但照扣额度的防枚举静默分支**（AuthService.sendEmailCode）：`scene=login` 未绑定邮箱、
   *    `scene=reset` 未注册邮箱。为什么必须扣：不扣就等于"不存在侧不消耗额度"，同一邮箱连发第二次时
   *    存在侧=429 / 不存在侧=200，以及 Redis 里 `email:last:{scene}:*`、`email:cnt:{scene}:*` 只有存在侧存在
   *    —— 两条都是账号枚举 oracle。
   *    ⚠️ 与之配套的顺序要求：`assertRateLimits()` 必须在这些静默分支**之前**判定（同一处注释有完整说明）。
   */
  async consumeQuota(email: string, scene: EmailScene, ip: string): Promise<void> {
    const hour = 3600;
    const pipeline = this.redis.pipeline();
    pipeline.set(this.lastKey(scene, email), String(Date.now()), 'EX', this.resendSeconds);
    pipeline.incr(`email:cnt:${scene}:${email}`);
    pipeline.expire(`email:cnt:${scene}:${email}`, hour);
    pipeline.incr(`email:cnt:ip:${ip}`);
    pipeline.expire(`email:cnt:ip:${ip}`, hour);
    await pipeline.exec();
  }

  /**
   * 生成并落库验证码（**不发信**，发信由业务层用 MailerService 做，便于失败回滚额度）。
   * @returns 明文码（仅供业务层组邮件正文；**绝不进 HTTP 响应**）
   */
  async issueCode(email: string, scene: EmailScene): Promise<string> {
    const code = this.generateCode();
    const ttl = this.ttlSeconds;
    await this.redis.set(
      this.codeKey(scene, email),
      JSON.stringify({ code, exp: Date.now() + ttl * 1000 }),
      'EX',
      ttl,
    );
    // 重新发码时清掉旧错误计数与上一次的成功标记（否则新码会被上一轮的 5 次错误连坐）
    await this.redis.del(this.tryKey(scene, email));
    return code;
  }

  /** 撤销已发放的码（发信失败时回滚：不留「用户没收到但码已存在」的脏状态） */
  async revokeCode(email: string, scene: EmailScene): Promise<void> {
    await this.redis.del(this.codeKey(scene, email), this.tryKey(scene, email));
  }

  /** 记录一次成功发信（占用 60s 重发额度与小时计数）；未发信的静默分支用 `consumeQuota()` */
  async markSent(email: string, scene: EmailScene, ip: string): Promise<void> {
    await this.consumeQuota(email, scene, ip);
  }

  /**
   * 校验验证码。
   * @returns ok=false 时 reason 供业务层选中文文案：
   *   none/expired → 验证码不存在或已过期；wrong → 验证码错误；too_many → 错误次数过多已作废
   */
  async verifyCode(email: string, scene: EmailScene, input: string): Promise<VerifyOutcome> {
    const raw = await this.redis.get(this.codeKey(scene, email));
    if (!raw) return { ok: false, reason: 'none' };

    let stored: { code?: string; exp?: number };
    try {
      stored = JSON.parse(raw);
    } catch {
      // 值损坏：按不可用处理并清掉，避免永久卡死
      await this.redis.del(this.codeKey(scene, email), this.tryKey(scene, email));
      return { ok: false, reason: 'none' };
    }
    // exp 是权威过期判定（不依赖 Redis 回收时序）
    if (!stored.exp || stored.exp <= Date.now()) {
      await this.redis.del(this.codeKey(scene, email));
      return { ok: false, reason: 'expired' };
    }

    if (String(stored.code) === String(input)) {
      // 一次性作废：成功即删码与错误计数（并发下 del 幂等，第二个请求会命中 none）
      await this.redis.del(this.codeKey(scene, email), this.tryKey(scene, email));
      return { ok: true };
    }

    // 失败计数（第一次失败时设置 TTL）
    const tries = await this.redis.incr(this.tryKey(scene, email));
    if (tries === 1) await this.redis.expire(this.tryKey(scene, email), ATTEMPT_TTL_SECONDS);
    if (tries >= MAX_ATTEMPTS) {
      // 达到上限：该码作废（计数保留至 TTL，防止立刻重新发码后继续爆破新码）
      await this.redis.del(this.codeKey(scene, email));
      this.logger.warn(`邮箱验证码错误次数达上限，已作废 scene=${scene} email=${maskEmail(email)}`);
      return { ok: false, reason: 'too_many' };
    }
    return { ok: false, reason: 'wrong' };
  }

  /** 校验失败 → 统一抛中文 400（文案集中在此，避免各接口各写一套） */
  async verifyOrThrow(email: string, scene: EmailScene, input: string): Promise<void> {
    const r = await this.verifyCode(email, scene, input);
    if (r.ok) return;
    if (r.reason === 'none' || r.reason === 'expired') {
      throw new BadRequestException('验证码已过期，请重新获取');
    }
    if (r.reason === 'too_many') {
      throw new BadRequestException('验证码错误次数过多，请重新获取');
    }
    throw new BadRequestException('验证码错误');
  }

  // ---------------- 测试注入点（仅 MAIL_DRIVER=console 生效，生产忽略） ----------------

  private get testModeEnabled(): boolean {
    // 唯一开关：MAIL_ALLOW_TEST_ENDPOINTS（生产默认 false）。
    // 不绑定 MAIL_DRIVER —— 真发信（smtp）下的端到端测试也要能读码断言，见 auth.controller 注释。
    return String(this.config.get<string>('MAIL_ALLOW_TEST_ENDPOINTS', 'false')).toLowerCase() === 'true';
  }

  /** 是否处于「把发信结果打桩为失败」的测试态 */
  async isForceFail(): Promise<boolean> {
    if (!this.testModeEnabled) return false;
    return (await this.redis.get('email:test:forcefail')) === '1';
  }

  /** 打开/关闭「打桩发信失败」。**生产（MAIL_DRIVER=smtp）返回 false 且不写任何键** */
  async setForceFail(on: boolean): Promise<boolean> {
    if (!this.testModeEnabled) return false;
    if (on) await this.redis.set('email:test:forcefail', '1');
    else await this.redis.del('email:test:forcefail');
    return true;
  }

  /** 测试态下最近一次发放的码与「是否已过期」（生产返回 null，绝不回显） */
  async describeCodeForTest(
    email: string,
    scene: EmailScene,
  ): Promise<{ code: string | null; expired: boolean | null }> {
    if (!this.testModeEnabled) return { code: null, expired: null };
    const raw = await this.redis.get(this.codeKey(scene, email));
    if (!raw) return { code: null, expired: null };
    try {
      const parsed = JSON.parse(raw) as { code?: string; exp?: number };
      return { code: parsed.code ?? null, expired: parsed.exp ? parsed.exp <= Date.now() : null };
    } catch {
      return { code: null, expired: null };
    }
  }

  /** 健康检查用：Redis 可达性 */
  async ping(): Promise<boolean> {
    try {
      return (await this.redis.ping()) === 'PONG';
    } catch {
      return false;
    }
  }
}
