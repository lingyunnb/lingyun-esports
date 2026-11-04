import { Module } from '@nestjs/common';

import { WorkerRatingManualService } from './worker-rating-manual.service';

/**
 * 打手六维「手填值」模块（负责人 2026-10-18）
 *
 * 只提供**一个服务** [WorkerRatingManualService]，两处消费：
 *
 * | 消费方 | 用途 |
 * |---|---|
 * | `PlayersModule` → `PublicWorkersController` | `GET /public/workers/:id` 的 `rating` 里带 `score` + `sources`（手填优先） |
 * | `AdminModule` → `WorkerAdminController` | `GET/PUT /admin/workers/:id/rating-manual`（权限点 `admin:worker:write`） |
 *
 * 为什么单独开一个模块而不是塞进 `WorkerProfileModule` / `RatingModule`：
 * - `RatingModule` 是**等级判定**的领地（`WorkerGradeService`），而本服务的数据
 *   **绝不允许参与判级**（见服务类注释 ②）。物理上分开，能让"谁读了手填表"一眼可查；
 * - `WorkerProfileModule` 是打手态自己的档案（`/worker/profile`），与"管理端给打手填展示值"无关。
 *
 * 服务本身**无状态**（只持有 `DataSource`），所以即便被两个模块各拿一份实例也不会出现
 * 两份状态 —— 但口径（六维解析规则）只有 `WorkerRatingManualService` 这一份实现。
 */
@Module({
  providers: [WorkerRatingManualService],
  exports: [WorkerRatingManualService],
})
export class WorkerRatingManualModule {}
