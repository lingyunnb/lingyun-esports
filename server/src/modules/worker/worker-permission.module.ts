import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { Division } from '../division/division.entity';
import { Worker } from './worker.entity';
import { WorkerDivisionPermission } from './worker-division-permission.entity';
import { WorkerDivisionPermissionService } from './worker-division-permission.service';
import { WorkerPermissionController } from './worker-permission.controller';

/**
 * 工作端分部接单权限模块（负责人 2026-10-04）。
 *
 * 导出 [WorkerDivisionPermissionService] 供订单（大厅/抢单/派单/指定护航员）、
 * 公开找陪玩、管理端授权等模块复用 —— 判定口径只有一处，避免各写一份 SQL 走偏。
 */
@Module({
  imports: [TypeOrmModule.forFeature([Worker, Division, WorkerDivisionPermission])],
  controllers: [WorkerPermissionController],
  providers: [WorkerDivisionPermissionService],
  exports: [WorkerDivisionPermissionService],
})
export class WorkerPermissionModule {}
