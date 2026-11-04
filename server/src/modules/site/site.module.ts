import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { SiteContent } from './site-content.entity';
import { SiteController } from './site.controller';

/** 官网模块（负责人 2026-09-25）：官网内容公开读取 + 管理端编辑 */
@Module({
  imports: [TypeOrmModule.forFeature([SiteContent, OperationLog])],
  controllers: [SiteController],
  providers: [OperationLogService],
})
export class SiteModule {}
