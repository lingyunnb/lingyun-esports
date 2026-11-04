import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { User } from '../user/user.entity';
import { Wallet } from './wallet.entity';
import { WalletTransaction } from './wallet-transaction.entity';
import { WalletAdminController } from './wallet-admin.controller';
import { WalletUserController } from './wallet-user.controller';
import { WalletWorkerController } from './wallet-worker.controller';
import { WalletService } from './wallet.service';

@Module({
  imports: [TypeOrmModule.forFeature([Wallet, WalletTransaction, User, OperationLog])],
  controllers: [WalletAdminController, WalletUserController, WalletWorkerController],
  providers: [WalletService, OperationLogService],
  exports: [WalletService],
})
export class WalletModule {}
