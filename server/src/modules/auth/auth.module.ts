import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { RateLimitService } from '../../common/rate-limit.service';
import { Admin } from '../admin/admin.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { AdminRole } from '../rbac/entities/admin-role.entity';
import { AdminRolePermission } from '../rbac/entities/admin-role-permission.entity';
import { Permission } from '../rbac/entities/permission.entity';
import { SystemSettingModule } from '../setting/system-setting.module';
import { Worker } from '../worker/worker.entity';
import { WorkerPermissionModule } from '../worker/worker-permission.module';
import { User } from '../user/user.entity';
import { WalletModule } from '../wallet/wallet.module';
import { AuthToken } from './auth-token.entity';
import { AuthController, AuthEmailTestController } from './auth.controller';
import { AuthService } from './auth.service';
import { BindingReleaseModule } from './binding-release.module';
import { EmailBindingService } from './email-binding.service';
import { EmailCodeService } from './email-code.service';
import { LoginLog } from './login-log.entity';
import { QqOauthClient } from './qq-oauth.client';
import { SeedService } from './seed.service';
import { UserEmailController } from './user-email.controller';
import { UserOAuth } from './user-oauth.entity';
import { WorkerIdentityBinding } from './worker-identity-binding.entity';
import { WorkerIdentityController } from './worker-identity.controller';
import { WorkerIdentityService } from './worker-identity.service';

@Module({
  imports: [
    TypeOrmModule.forFeature([
      User,
      Worker,
      Admin,
      AdminRole,
      AdminRolePermission,
      Permission,
      AuthToken,
      LoginLog,
      // 老板 ↔ 打手 身份绑定（合并双端·身份切换，方案甲；migration 1801000000000）
      WorkerIdentityBinding,
      // 第三方登录绑定（QQ；migration 1809000000000）
      UserOAuth,
      // 找回密码审计留痕（docs/09；沿用 division/forum 的 opLog 做法）
      OperationLog,
    ]),
    // 绑定释放（置 unbound + 吊销 companion 令牌 + identity 审计 + 断开 WS）——F1-b/F4 后所有释放路径的唯一入口
    BindingReleaseModule,
    // 注册流程需创建钱包（docs/06）
    WalletModule,
    // /auth/me 附带「我的分部接单权限」（工作端展示用，负责人 2026-10-04）
    WorkerPermissionModule,
    // 绑定上限 worker_binding_max_per_boss（system_setting，仅超管可改；实时读库无缓存）
    SystemSettingModule,
    // MailerService 由全局 MailModule 提供（main app.module 注册）
    // JwtModule 已在 app.module 全局注册
  ],
  controllers: [AuthController, AuthEmailTestController, WorkerIdentityController, UserEmailController],
  providers: [
    AuthService,
    RateLimitService,
    SeedService,
    EmailCodeService,
    OperationLogService,
    WorkerIdentityService,
    /** 邮箱绑定/换绑（2026-10-10；/user/email/*） */
    EmailBindingService,
    /** QQ 互联 Graph 客户端（服务端复核 openid；未配置即中文 503） */
    QqOauthClient,
  ],
  exports: [RateLimitService, AuthService, WorkerIdentityService],
})
export class AuthModule {}
