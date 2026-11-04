import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { Order } from '../order/order.entity';
import { ReviewModule } from '../review/review.module';
import { RatingAdminController } from './rating-admin.controller';
import { RatingService } from './rating.service';
import { RatingUserController } from './rating-user.controller';
import { RatingWorkerController } from './rating-worker.controller';
import { WorkerGrade } from './worker-grade.entity';
import { WorkerGradeService } from './worker-grade.service';
import { WorkerRating } from './worker-rating.entity';
import { WorkerRatingAgg } from './worker-rating-agg.entity';

/**
 * 打手等级 + 五维评分（负责人已审批 2026-10-17）
 *
 * 三块能力，三个控制器各管一族路由：
 *
 * | 路由 | 控制器 | 谁能调 |
 * |---|---|---|
 * | `POST/GET /user/orders/:id/rating` | `RatingUserController` | 老板 primary（`role=user`） |
 * | `GET /worker/grade` | `RatingWorkerController` | 打手态（companion）/ worker primary |
 * | `PUT/GET /admin/workers/:id/grade` | `RatingAdminController` | **仅超管**（`super_admin` ∪ `is_owner=1`） |
 *
 * ## 为什么单独开一个模块（`modules/rating`，而不是塞进 `review` 或 `worker`）
 *
 * - `review` 模块（`order_review`）是**好评/差评二值评价**，它的口径是"好评率"，
 *   服务于公开卡片与展示值；本模块是**五维打分**，服务于等级判定。两者的表、写入时机、
 *   消费方都不同 —— 混装会让"改好评率口径"意外影响等级判定（反之亦然）。
 * - `worker` 模块是**打手档案/权限/简介**；等级是"评价数据聚合出来的结果"，
 *   依赖 `ReviewService`（好评率）与订单（评分来源），放进去会让 worker 模块反向依赖订单模块。
 *
 * ## 依赖说明
 *
 * - `ReviewModule` → `ReviewService.workerStatsView()`：**好评率与完成单数的唯一口径出口**。
 *   本模块**不重写** `SUM(satisfied)/COUNT(*)`，避免"公开页 98.2 / 判级 98.0"这类两套口径。
 * - `Order`：评分落库时在事务内 `findOne(Order, { lock: 'pessimistic_write' })` 校验归属与状态。
 * - `OperationLog` **没有**进 `forFeature`：等级审计是"同事务裸 INSERT"（见 `WorkerGradeService` 类注释），
 *   有意不用 `OperationLogService` 的 fire-and-forget 写入，所以不需要它的实体注入。
 *
 * `WorkerGradeService` 对外导出：`PlayersModule`（找陪玩列表要 `grade/gradeLabel/gradeName`）与
 * `PublicWorkersController`（公开详情要等级 + 五维 + 进度）都注入它 —— 列表与详情的等级口径因此只有一份。
 */
@Module({
  imports: [TypeOrmModule.forFeature([WorkerGrade, WorkerRating, WorkerRatingAgg, Order]), ReviewModule],
  controllers: [RatingUserController, RatingWorkerController, RatingAdminController],
  providers: [RatingService, WorkerGradeService],
  exports: [WorkerGradeService, RatingService],
})
export class RatingModule {}
