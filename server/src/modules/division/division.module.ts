import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { DivisionAdminController, DivisionPublicController } from './division.controller';
import { Division } from './division.entity';
import { DivisionService } from './division.service';

/** 分部模块（负责人 2026-10-03）：游戏 + 平台的主维度，客户端零硬编码 */
@Module({
  // OperationLog 为分部增删改的审计写入注册（operation_log 留痕，沿用 forum/refund 等处做法）
  imports: [TypeOrmModule.forFeature([Division, OperationLog])],
  controllers: [DivisionPublicController, DivisionAdminController],
  providers: [DivisionService, OperationLogService],
  exports: [DivisionService],
})
export class DivisionModule {}
