import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { RateLimitService } from '../../common/rate-limit.service';
import { AuthModule } from '../auth/auth.module';
import { UserNotification } from '../friend/user-notification.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Media } from '../media/media.entity';
import { MediaModule } from '../media/media.module';
import { SystemSettingModule } from '../setting/system-setting.module';
import { User } from '../user/user.entity';
import { WalletModule } from '../wallet/wallet.module';
import { RechargeAdminController } from './recharge-admin.controller';
import { RechargeAdmin } from './recharge-admin.entity';
import { RechargePublicController } from './recharge-public.controller';
import { RechargeQrCode } from './recharge-qr-code.entity';
import { RechargeRequest } from './recharge-request.entity';
import { RechargeReviewController } from './recharge-review.controller';
import { RechargeSessionGuard } from './recharge-session.guard';
import { RechargeIdentityController, RechargeUserController } from './recharge-user.controller';
import { RechargeService } from './recharge.service';

/**
 * 充值（线下收款 + 人工审核）模块 —— 详见 CLAUDE.md 结构规则 12 与 docs/04。
 *
 * ## 依赖说明（为什么是这几个）
 *
 * - `SystemSettingModule`：充值配置存在 `system_setting.recharge_config`（`is_high_security=1` → 仅超管可写）。
 *   选它而不是单开配置表，就是为了**复用 `is_high_security` 机制**、不把"仅超管可写"实现两遍。
 * - `WalletModule`：发放走 `WalletService.grantInTx()` —— **复用既有超管发余额能力**，
 *   本模块不自己 UPDATE `wallet`、不自己拼 `wallet_transaction`（docs/06 铁律：余额变化必须写流水 + 前后余额快照）。
 * - `MediaModule`：收款码与转账截图都走既有媒体上传；凭证用 `recharge_proof`（**受保护**）用途。
 * - `AuthModule`：绑定管理员态要复用 `AuthService.comparePassword` / `assertNotBanned` /
 *   `issueRechargeTokens` / `recordIdentityEvent` —— 与登录、打手态绑定**同一套**实现。
 * - `TypeOrmModule.forFeature`：三张本模块的表 + `User` + `Media` + `UserNotification` + `OperationLog`
 *   （通知复用既有 `user_notification` 表与 `notification:new` 事件，不新造一套通知）。
 * - `RealtimeGateway` 来自**全局** `RealtimeModule`（模块标了 `@Global`），无需在此 import。
 * - `OperationLogService`：**`@Controller('admin/recharge')` 全部写接口必须留痕**（负责人 2026-10-06 铁律）。
 *   本仓库的既有姿势是**各模块自己 provide**（见 `order.module` / `tip.module` / `admin.module`），
 *   而不是把 log 模块做成全局单例 —— 这里沿用同一种，避免出现第二种取用方式。
 */
@Module({
  imports: [
    TypeOrmModule.forFeature([RechargeQrCode, RechargeRequest, RechargeAdmin, User, Media, UserNotification, OperationLog]),
    SystemSettingModule,
    WalletModule,
    MediaModule,
    AuthModule,
  ],
  controllers: [
    RechargePublicController,
    RechargeUserController,
    RechargeIdentityController,
    RechargeReviewController,
    RechargeAdminController,
  ],
  providers: [RechargeService, RechargeSessionGuard, RateLimitService, OperationLogService],
  /**
   * `RechargeSessionGuard` 随模块导出：提现（`WithdrawModule`）的 App 内「管理员身份」入口
   * **复用同一个守卫**（受限会话 `kind='recharge'` 的语义只有一种，不新写第二份）。
   */
  exports: [RechargeService, RechargeSessionGuard],
})
export class RechargeModule {}
