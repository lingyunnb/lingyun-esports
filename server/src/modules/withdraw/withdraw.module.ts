import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AuthModule } from '../auth/auth.module';
import { UserNotification } from '../friend/user-notification.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Media } from '../media/media.entity';
import { MediaModule } from '../media/media.module';
import { RechargeModule } from '../recharge/recharge.module';
import { RechargeSessionGuard } from '../recharge/recharge-session.guard';
import { SystemSettingModule } from '../setting/system-setting.module';
import { User } from '../user/user.entity';
import { WalletModule } from '../wallet/wallet.module';
import { Worker } from '../worker/worker.entity';
import { WithdrawAdminController } from './withdraw-admin.controller';
import { WithdrawRequest } from './withdraw-request.entity';
import { WithdrawReviewController } from './withdraw-review.controller';
import { WithdrawService } from './withdraw.service';
import { WithdrawWorkerController } from './withdraw-worker.controller';
import { WorkerWithdrawAccount } from './worker-withdraw-account.entity';

/**
 * 打手提现（人工打款）模块 —— 详见 CLAUDE.md「提现走人工打款」与 docs/06「提现」一节。
 *
 * ## 依赖说明（为什么是这几个）
 *
 * - `SystemSettingModule`：提现配置存在 `system_setting.withdraw_config`
 *   （`is_high_security=1` → 仅超管可写）。选它而不是单开配置表，就是为了**复用
 *   `is_high_security` 机制**、不把"仅超管可写"实现两遍（与 `recharge_config` 同一理由）。
 * - `WalletModule`：**扣款与退回都走 `WalletService`**（`withdrawDeductInTx` / `withdrawRefundInTx`
 *   → 内部是既有 `executeChange`）。本模块**不自己 UPDATE `wallet`、不自己拼 `wallet_transaction`**
 *   （docs/06 铁律：余额变化必须写流水 + 前后余额快照）。
 * - `MediaModule`：收款码（`withdraw_qr`）与打款凭证（`withdraw_proof`）都走既有媒体上传，
 *   两者都是 **protected** 用途；取图走本模块自己的窄通道。
 * - `RechargeModule`：**复用 `RechargeSessionGuard`**（受限会话 `kind='recharge'` 的闸门）。
 *   App 内「管理员身份」就是那一套受限会话 —— 提现复用它的守卫而不是新写一份，
 *   保证"受限会话只有一种语义"（同一规则只有一份实现）。
 * - `AuthModule` / `User` / `UserNotification`：通知复用既有 `user_notification` 表与
 *   `notification:new` 事件，不新造通知通道。
 * - `RealtimeGateway` 来自**全局** `RealtimeModule`（模块标了 `@Global`），无需在此 import。
 * - `OperationLogService`：本仓库既有姿势是**各模块自己 provide**
 *   （见 `order.module` / `recharge.module` / `admin.module`），这里沿用同一种。
 */
@Module({
  imports: [
    TypeOrmModule.forFeature([
      WorkerWithdrawAccount,
      WithdrawRequest,
      Worker,
      User,
      Media,
      UserNotification,
      OperationLog,
    ]),
    SystemSettingModule,
    WalletModule,
    MediaModule,
    AuthModule,
    RechargeModule,
  ],
  controllers: [WithdrawWorkerController, WithdrawAdminController, WithdrawReviewController],
  providers: [WithdrawService, OperationLogService, RechargeSessionGuard],
  exports: [WithdrawService],
})
export class WithdrawModule {}
