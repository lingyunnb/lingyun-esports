import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { ClubAdminController, ClubPublicController } from './club.controller';
import { Club } from './club.entity';
import { ClubService } from './club.service';

/**
 * 官方自营馆模块（负责人 2026-10-04）：首页官方馆卡片内容与封面图由管理端维护。
 *
 * `OperationLog` + `OperationLogService`：三个管理端写接口（create/update/delete）必须写
 * `operation_log`（负责人铁律）。既有姿势 = 各模块自己 `forFeature([..., OperationLog])`
 * + provide（见 `division.module`）—— ⚠️ **实体必须进 `forFeature`**，否则启动时
 * `OperationLogService` 的 `@InjectRepository(OperationLog)` 解析不到会抛
 * `UnknownDependenciesException`。
 */
@Module({
  imports: [TypeOrmModule.forFeature([Club, OperationLog])],
  controllers: [ClubPublicController, ClubAdminController],
  providers: [ClubService, OperationLogService],
  exports: [ClubService],
})
export class ClubModule {}
