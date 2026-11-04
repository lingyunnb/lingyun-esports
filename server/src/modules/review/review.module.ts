import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { UserNotification } from '../friend/user-notification.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Order } from '../order/order.entity';
import { User } from '../user/user.entity';
import { Worker } from '../worker/worker.entity';
import { OrderReview } from './order-review.entity';
import { ReviewAdminController } from './review-admin.controller';
import { ReviewUserController } from './review-user.controller';
import { ReviewService } from './review.service';

/**
 * 评价模块（负责人 2026-10-15：「做评价与评分体系」）
 *
 * 三块能力：老板侧提交/回显（`/user/orders/:id/review`）、管理端治理（`/admin/reviews`）、
 * 以及公开打手页要用的聚合读（`ReviewService.publicWorkerProfile / publicWorkerReviews`，
 * 由 `PlayersModule` 的 `PublicWorkersController` 暴露为 `/public/workers/*`）。
 *
 * 为什么公开打手页的**聚合读**放在本模块：好评率/评价条数/最近评价的数据源都是 `order_review`，
 * 口径（只算 `hidden=0`、只给脱敏昵称、无评价返回 null）必须**只有一处实现**；
 * 控制器的落点仍在 worker 模块（`public-players.controller.ts` 的邻居），
 * 这样"公开打手相关接口"在目录上依旧聚在一起，而口径不出现第二份。
 *
 * `OperationLogService` 按既有姿势由本模块自己 provide（docs/03：不做全局单例）；
 * `RealtimeGateway` 来自 `@Global()` 的 `RealtimeModule`，无需 import。
 */
@Module({
  imports: [
    TypeOrmModule.forFeature([OrderReview, Order, Worker, User, UserNotification, OperationLog]),
  ],
  controllers: [ReviewUserController, ReviewAdminController],
  providers: [ReviewService, OperationLogService],
  exports: [ReviewService],
})
export class ReviewModule {}
