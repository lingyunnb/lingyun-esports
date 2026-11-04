import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { SystemSettingModule } from '../setting/system-setting.module';
import { LevelAdminController } from './level-admin.controller';
import { LevelPublicController } from './level-public.controller';
import { LevelService } from './level.service';
import { UserLevelLog } from './user-level-log.entity';

/** 用户等级模块（负责人需求 #7 + 2026-09-25 等级阈值后台可配） */
@Module({
  imports: [TypeOrmModule.forFeature([UserLevelLog, OperationLog]), SystemSettingModule],
  controllers: [LevelAdminController, LevelPublicController],
  providers: [LevelService, OperationLogService],
  exports: [LevelService],
})
export class LevelModule {}
