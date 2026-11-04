import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { BindingReleaseModule } from '../auth/binding-release.module';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { AdminRole } from '../rbac/entities/admin-role.entity';
import { AdminRolePermission } from '../rbac/entities/admin-role-permission.entity';
import { Permission } from '../rbac/entities/permission.entity';
import { ReviewModule } from '../review/review.module';
import { Worker } from '../worker/worker.entity';
import { WorkerPermissionModule } from '../worker/worker-permission.module';
import { WorkerRatingManualModule } from '../worker/worker-rating-manual.module';
import { User } from '../user/user.entity';
import { AdminAdminController } from './admin-admin.controller';
import { AdminAdminService } from './admin-admin.service';
import { Admin } from './admin.entity';
import { WorkerAdminController } from './worker-admin.controller';
import { WorkerAdminService } from './worker-admin.service';
import { WorkerRatingManualController } from './worker-rating-manual.controller';

/** 管理端模块：工作端管理 + 管理员与角色管理 */
@Module({
  imports: [
    TypeOrmModule.forFeature([User, Worker, Admin, AdminRole, AdminRolePermission, Permission, OperationLog]),
    // 分部接单权限（负责人 2026-10-04）：管理端按分部授权/撤销，写 worker_division_permission
    WorkerPermissionModule,
    // 停用打手即释放绑定（含 companion 令牌吊销 + identity 审计 + 断开 WS，F1-b/F4）
    BindingReleaseModule,
    // 展示值（接单次数/好评率）读写口（2026-10-16）：
    // `GET /admin/workers/:id/stats`、`PUT /admin/workers/:id/display-stats` 只借它的 `ReviewService`
    // —— 那两个数字的**唯一口径**在那里（`publicWorkerStats` / `satisfiedRateText`），
    // 在本模块重写一遍查询与好评率格式化就会分叉成两套口径（安全审计 F1 的同一类根因）。
    ReviewModule,
    // 六维手填值（2026-10-18）：`GET/PUT /admin/workers/:id/rating-manual` 的读写实现。
    // **只影响展示**：它写的是 `worker_rating_manual`，绝不碰 agg / grade / stats（见控制器类注释）。
    WorkerRatingManualModule,
  ],
  controllers: [WorkerAdminController, WorkerRatingManualController, AdminAdminController],
  providers: [WorkerAdminService, AdminAdminService, OperationLogService],
  exports: [OperationLogService],
})
export class AdminModule {}
