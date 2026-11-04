import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/** 发信结果：ok=false 时业务层据此返回中文「邮件发送失败，请稍后重试」，**绝不 500** */
export interface MailResult {
  ok: boolean;
  /** 实际使用的驱动（便于测试与排障断言） */
  driver: 'smtp' | 'console';
  /** SMTP 返回的 messageId（console 模式为 null） */
  messageId?: string | null;
  /** 失败原因（已脱敏，绝不含口令） */
  error?: string;
}

/**
 * 邮件发送抽象（负责人 2026-10-05：邮箱验证替代短信验证）
 *
 * 设计要点（硬约束）：
 * 1. **发送失败不抛给业务层**：任何异常在 send() 内部被吞掉，只记 warn 并返回 `{ok:false}`。
 *    业务层拿到 false 就返回中文「邮件发送失败，请稍后重试」——用户侧是可重试的提示，不是 500。
 * 2. **SMTP 超时 ≤10s**：connectionTimeout / greetingTimeout / socketTimeout 全部 10s，
 *    绝不允许一个卡住的 SMTP 连接把 HTTP 请求线程拖死（不卡死铁律）。
 * 3. **驱动可切换**（父任务授权）：`MAIL_DRIVER=smtp|console`
 *    - `smtp`（**默认，生产唯一允许值**）：真发信。
 *    - `console`（**仅开发与自动化测试，生产禁用**）：不发真信，把「收件人+主题+验证码」打到日志并返回成功。
 *      用于 SMTP 授权码失效（QQ 535）期间把全部业务逻辑跑通。
 * 4. **日志脱敏**：MAIL_PASS 永不进日志；失败原因里的口令字面量会被替换成 <REDACTED>。
 */
@Injectable()
export class MailerService {
  private readonly logger = new Logger('Mailer');

  constructor(private readonly config: ConfigService) {}

  /** 驱动：仅当显式配置为 console 才降级；任何其它值（含未配置）一律 smtp（生产安全默认） */
  get driver(): 'smtp' | 'console' {
    return String(this.config.get<string>('MAIL_DRIVER', 'smtp')).toLowerCase() === 'console' ? 'console' : 'smtp';
  }

  get enabled(): boolean {
    return String(this.config.get<string>('MAIL_ENABLED', 'false')).toLowerCase() === 'true';
  }

  /** 发件人展示串：`"祁连山电竞" <qilianshan@qq.com>` */
  private fromAddress(): string {
    const name = this.config.get<string>('MAIL_FROM_NAME', '');
    const addr = this.config.get<string>('MAIL_FROM') || this.config.get<string>('MAIL_USER', '');
    return name ? `"${name}" <${addr}>` : addr;
  }

  /** 口令脱敏：任何往外抛的文本里都不允许出现 MAIL_PASS 字面量 */
  private redact(text: string): string {
    const pass = this.config.get<string>('MAIL_PASS', '');
    let out = String(text ?? '');
    if (pass && pass.length > 0) out = out.split(pass).join('<REDACTED>');
    return out;
  }

  /** 惰性加载 nodemailer（未启用邮件时不加载，避免无谓开销） */
  private transporter(): { sendMail: (o: Record<string, unknown>) => Promise<{ messageId?: string }>; close?: () => void } {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const nodemailer = require('nodemailer');
    return nodemailer.createTransport({
      host: this.config.get<string>('MAIL_HOST', 'smtp.qq.com'),
      port: Number(this.config.get<string | number>('MAIL_PORT', 465)),
      secure: String(this.config.get<string>('MAIL_SECURE', 'true')).toLowerCase() === 'true',
      auth: {
        user: this.config.get<string>('MAIL_USER', ''),
        pass: this.config.get<string>('MAIL_PASS', ''),
      },
      // 不卡死铁律：三层超时全部 10s 内
      connectionTimeout: 10_000,
      greetingTimeout: 10_000,
      socketTimeout: 10_000,
    });
  }

  /**
   * 发一封纯文本邮件。**永不抛异常**。
   * @returns ok=true 表示已交给 SMTP（或被 console 驱动记录）
   */
  async send(to: string, subject: string, text: string): Promise<MailResult> {
    const driver = this.driver;
    if (!this.enabled) {
      this.logger.warn(`邮件通道未启用（MAIL_ENABLED=false），跳过发送 to=${maskEmail(to)}`);
      return { ok: false, driver, error: 'MAIL_ENABLED=false' };
    }

    // ---- console 驱动：仅开发/自动化测试（生产禁用）。不发真信，验证码写日志 ----
    if (driver === 'console') {
      this.logger.log(
        `[console 驱动·仅开发测试·生产禁用] 拦截发信 to=${maskEmail(to)} subject=${subject} 正文=${text}`,
      );
      return { ok: true, driver, messageId: null };
    }

    // ---- smtp 驱动：失败只 warn + 返回 false，绝不抛给业务层 ----
    let transport: { sendMail: (o: Record<string, unknown>) => Promise<{ messageId?: string }>; close?: () => void } | null =
      null;
    try {
      transport = this.transporter();
      const info = await transport.sendMail({ from: this.fromAddress(), to, subject, text });
      const messageId = info?.messageId ?? null;
      this.logger.log(`邮件已发送 to=${maskEmail(to)} messageId=${messageId}`);
      return { ok: true, driver, messageId };
    } catch (e) {
      const err = e as { code?: string; responseCode?: number; message?: string };
      const detail = this.redact(
        `${err?.code ?? ''}${err?.responseCode ? `(${err.responseCode})` : ''} ${err?.message ?? String(e)}`.trim(),
      );
      this.logger.warn(`邮件发送失败 to=${maskEmail(to)}：${detail}`);
      return { ok: false, driver, error: detail };
    } finally {
      try {
        transport?.close?.();
      } catch {
        // 关闭连接失败不影响结果
      }
    }
  }
}

/** 邮箱脱敏（日志里不出现完整收件人） */
export function maskEmail(email: string): string {
  const [name, domain] = String(email ?? '').split('@');
  if (!domain) return '<invalid>';
  const head = name.slice(0, 2);
  return `${head}${'*'.repeat(Math.max(1, name.length - 2))}@${domain}`;
}
