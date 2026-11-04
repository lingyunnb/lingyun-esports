import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { UserNotification } from '../friend/user-notification.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Order } from '../order/order.entity';
import { OrderPriceSnapshot } from '../order/order-price-snapshot.entity';
import { SystemSettingModule } from '../setting/system-setting.module';
import { User } from '../user/user.entity';
import { Wallet } from '../wallet/wallet.entity';
import { WalletTransaction } from '../wallet/wallet-transaction.entity';
import { Worker } from '../worker/worker.entity';
import { OrderTip } from './order-tip.entity';
import { TipAdminController } from './tip-admin.controller';
import { TipUserController } from './tip-user.controller';
import { TipWorkerController } from './tip-worker.controller';
import { TipService } from './tip.service';

/** 打赏模块（顶部导航「打赏」：老板 → 打手，余额 100% 过手，docs/06） */
@Module({
  imports: [
    TypeOrmModule.forFeature([OrderTip, Order, OrderPriceSnapshot, Wallet, WalletTransaction, Worker, User, UserNotification, OperationLog]),
    SystemSettingModule,
  ],
  controllers: [TipUserController, TipWorkerController, TipAdminController],
  providers: [TipService, OperationLogService],
  exports: [TipService],
})
export class TipModule {}
