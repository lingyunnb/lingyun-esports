import { BadRequestException, ConflictException, Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { maskEmail } from '../../common/mail/mailer.service';
import { OperationLogService } from '../log/operation-log.service';
import { User } from '../user/user.entity';
import { AuthService, isDuplicateKeyError } from './auth.service';
import { EmailCodeService, normalizeEmail } from './email-code.service';

/** 绑定入参（DTO 已做格式校验，这里再做一次业务层兜底） */
export interface BindEmailInput {
  email: string;
  emailCode: string;
  password: string;
}

/**
 * 邮箱绑定 / 换绑（负责人 2026-10-10 拍板 2：**当前密码 + 新邮箱验证码**）。
 *
 * ## 为什么单独一个 service（而不是塞进 AuthService）
 * 它**不是登录**：不改会话、不签令牌、不顶设备（单设备铁律完全不涉及），
 * 只是"账号设置页的一次凭据写入"；放这里能让 AuthService 保持"登录/令牌/会话"这一条主线。
 * 与注册/找回密码**同口径**的两件事仍复用既有实现，不重写：
 * - 密码校验 → `AuthService.comparePassword`（登录/绑定打手共用的那一份）；
 * - 验证码校验 → `EmailCodeService.verifyOrThrow`（scene=bind，一次性作废、错满 5 次作废）；
 * - 留痕 → `operation_log` + `login_log`（与「邮箱注册」「邮箱找回密码」完全相同的两张表与字段口径）。
 *
 * ## 语义（逐条对应负责人要求）
 * - **绑定与换绑同一接口**（`POST /user/email/bind`）：原有邮箱时语义 = **覆盖**，审计里区分 bind/rebind
 *   并做**新旧邮箱脱敏对比**（`maskEmail`，绝不落明文验证码，也不落明文密码）；
 * - 校验顺序：邮箱格式 → **当前密码** → **邮箱唯一** → **验证码**。
 *   把密码放在最前：登录态被盗但密码未知时，不泄露任何"这个邮箱是否已被占用"的信息；
 *   把唯一性放在验码前：与注册同口径 —— **不浪费用户验证码**（占用了的邮箱不必再验码）；
 * - 邮箱唯一 = 「一个邮箱只能绑一个账号」：先查后写，**并发兜底靠 `UQ_user_email` 唯一索引**
 *   （撞键 → 中文 409，绝不 500）；绑到自己当前的邮箱是**幂等成功**（刷新 `email_verified_at`）；
 * - 成功只写 `email` + `email_verified_at = now()`：**不动任何令牌/会话**（区别于改密码/找回密码的"全量吊销"）；
 * - 解绑本轮**不做**：邮箱已是登录凭据（`scene=login`），开放解绑等于开放"登录凭据被移除/被换走"的入口，
 *   等负责人明确要"换邮箱而不留空"还是"允许置空"再定（见 docs/待确认事项）。
 */
@Injectable()
export class EmailBindingService {
  private readonly logger = new Logger('EmailBind');

  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    /** 密码校验（bcrypt.compare 的**唯一实现**） */
    private readonly auth: AuthService,
    /** 邮箱验证码（scene=bind；一次性作废 + 错满 5 次作废 + 限流全在它里面） */
    private readonly emailCode: EmailCodeService,
    /** 审计：与邮箱注册/找回密码同表同字段（module=auth） */
    private readonly opLog: OperationLogService,
  ) {}

  /**
   * 绑定 / 换绑邮箱。
   *
   * @param userId 主体 id —— **只来自 JWT（守卫注入）**，绝不接受请求体里的 userId
   */
  async bind(userId: string, dto: BindEmailInput, ip: string, userAgent: string) {
    const email = normalizeEmail(dto.email);
    if (!email) throw new BadRequestException('邮箱格式不正确');

    // 会话主体（密码列默认 select:false，需显式 addSelect 才能比对）
    const user = await this.userRepo
      .createQueryBuilder('u')
      .addSelect('u.passwordHash')
      .where('u.id = :userId', { userId })
      .getOne();
    if (!user) throw new UnauthorizedException('账号不存在');

    // ---------- 1) 当前密码（负责人拍板：换绑验证 = 当前密码 + 新邮箱码） ----------
    const okPassword = await this.auth.comparePassword(user, dto.password ?? '');
    if (!okPassword) {
      await this.auth.recordLoginEvent('user', user.id, user.username, ip, userAgent, 'fail', '绑定邮箱失败：密码错误');
      throw new BadRequestException('密码错误');
    }

    // ---------- 2) 邮箱唯一（一个邮箱只能绑一个账号） ----------
    const taken = await this.userRepo.findOne({ where: { email }, select: ['id', 'username'] });
    if (taken && String(taken.id) !== String(user.id)) {
      await this.auth.recordLoginEvent(
        'user',
        user.id,
        user.username,
        ip,
        userAgent,
        'fail',
        '绑定邮箱失败：邮箱已被其他账号绑定',
      );
      throw new ConflictException('该邮箱已被其他账号绑定');
    }

    // ---------- 3) 新邮箱验证码（scene=bind，一次性作废） ----------
    try {
      await this.emailCode.verifyOrThrow(email, 'bind', dto.emailCode);
    } catch (e) {
      await this.auth.recordLoginEvent('user', user.id, user.username, ip, userAgent, 'fail', '绑定邮箱失败：验证码校验未通过');
      throw e;
    }

    // ---------- 4) 覆盖写（首次绑定与换绑同一路径） ----------
    const oldEmail = normalizeEmail(user.email);
    const rebound = !!oldEmail && oldEmail !== email;
    try {
      await this.userRepo.update(user.id, { email, emailVerifiedAt: new Date() });
    } catch (e) {
      // 并发兜底：两个账号同时绑同一邮箱 → UQ_user_email 撞键 → 中文 409（不是 500）
      if (isDuplicateKeyError(e)) {
        await this.auth.recordLoginEvent(
          'user',
          user.id,
          user.username,
          ip,
          userAgent,
          'fail',
          '绑定邮箱失败：邮箱已被其他账号绑定（并发撞唯一索引）',
        );
        throw new ConflictException('该邮箱已被其他账号绑定');
      }
      throw e;
    }

    // ---------- 5) 审计（两张表，口径与邮箱注册/找回密码一致） ----------
    // 明文验证码/密码**一律不落**；邮箱只落脱敏值（新旧对比供安全审计回看）
    this.opLog.log({
      adminUserId: String(user.id),
      adminName: user.nickname ?? user.username,
      module: 'auth',
      action: rebound ? 'email_rebind' : 'email_bind',
      method: 'POST',
      path: '/user/email/bind',
      requestBody: JSON.stringify({
        userId: String(user.id),
        action: rebound ? 'rebind' : 'bind',
        email: maskEmail(email),
        oldEmail: oldEmail ? maskEmail(oldEmail) : null,
        emailVerified: true,
        via: 'password+email_code',
      }),
      ip,
      result: 'success',
      errorMsg: null,
    });
    await this.auth.recordLoginEvent(
      'user',
      user.id,
      user.username,
      ip,
      userAgent,
      'success',
      rebound
        ? `邮箱换绑（${oldEmail ? maskEmail(oldEmail) : '-'} → ${maskEmail(email)}）`
        : `邮箱绑定（${maskEmail(email)}）`,
    );
    this.logger.log(`邮箱${rebound ? '换绑' : '绑定'}成功 userId=${user.id} email=${maskEmail(email)}`);

    return {
      ok: true,
      /** **脱敏**邮箱（完整邮箱不返回：本人知道自己的邮箱，设置页只需显示"绑的是哪一个"） */
      email: maskEmail(email),
      emailVerified: true,
      /** 是否属于"换绑"（原本已有邮箱且与新邮箱不同） */
      rebound,
      message: rebound ? '邮箱换绑成功' : '邮箱绑定成功',
    };
  }

  /**
   * 当前账号的邮箱状态（设置页展示用）。
   *
   * 只可能查**自己**（userId 来自 JWT）→ 但返回的仍是**脱敏**邮箱：
   * 客户端对"完整邮箱"没有使用场景，少下发一次就少一次泄露面（日志/前端埋点/截图）。
   */
  async status(userId: string) {
    const user = await this.userRepo.findOne({ where: { id: userId }, select: ['id', 'email', 'emailVerifiedAt'] });
    if (!user) throw new UnauthorizedException('账号不存在');
    return {
      bound: !!user.email,
      email: user.email ? maskEmail(user.email) : null,
      verified: !!user.emailVerifiedAt,
      verifiedAt: user.emailVerifiedAt ?? null,
    };
  }
}
