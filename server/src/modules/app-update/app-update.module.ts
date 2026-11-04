import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { AppUpdateAdminController } from './app-update-admin.controller';
import { AppUpdatePublicController } from './app-update-public.controller';
import { AppUpdateService } from './app-update.service';
import { AppVersion } from './app-version.entity';

/** 客户端版本更新模块（云端更新，仅老板端） */
@Module({
  imports: [TypeOrmModule.forFeature([AppVersion, OperationLog])],
  controllers: [AppUpdateAdminController, AppUpdatePublicController],
  providers: [AppUpdateService, OperationLogService],
})
export class AppUpdateModule {}
