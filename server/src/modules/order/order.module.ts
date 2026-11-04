import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { GameAccountModule } from '../game-account/game-account.module';
import { LevelModule } from '../level/level.module';
import { ChatModule } from '../chat/chat.module';
import { DivisionModule } from '../division/division.module';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { SystemSettingModule } from '../setting/system-setting.module';
import { User } from '../user/user.entity';
import { Wallet } from '../wallet/wallet.entity';
import { WalletTransaction } from '../wallet/wallet-transaction.entity';
import { Worker } from '../worker/worker.entity';
import { WorkerPermissionModule } from '../worker/worker-permission.module';
import { OrderAppeal } from './order-appeal.entity';
import { OrderPriceSnapshot } from './order-price-snapshot.entity';
import { OrderSettlement } from './order-settlement.entity';
import { OrderStatusLog } from './order-status-log.entity';
import { Order } from './order.entity';
import { OrderAdminController } from './order-admin.controller';
import { OrderService } from './order.service';
import { OrderUserController } from './order-user.controller';
import { OrderWorkerController } from './order-worker.controller';

@Module({
  imports: [TypeOrmModule.forFeature([Order, OrderPriceSnapshot, OrderStatusLog, OrderSettlement, OrderAppeal, Wallet, WalletTransaction, Worker, User, OperationLog]), SystemSettingModule, LevelModule, ChatModule, WorkerPermissionModule, DivisionModule, GameAccountModule],
  controllers: [OrderUserController, OrderWorkerController, OrderAdminController],
  providers: [OrderService, OperationLogService],
  exports: [OrderService],
})
export class OrderModule {}
