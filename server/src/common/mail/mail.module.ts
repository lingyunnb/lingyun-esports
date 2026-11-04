import { Global, Module } from '@nestjs/common';
import { MailerService } from './mailer.service';

/**
 * 邮件模块（负责人 2026-10-05）：全局注册，认证模块直接注入 MailerService。
 * 仅封装 nodemailer（MIT），不含业务逻辑。
 */
@Global()
@Module({
  providers: [MailerService],
  exports: [MailerService],
})
export class MailModule {}
