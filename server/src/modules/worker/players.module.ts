import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { RatingModule } from '../rating/rating.module';
import { ReviewModule } from '../review/review.module';
import { User } from '../user/user.entity';
import { PlayersService } from './players.service';
import { PublicPlayersController } from './public-players.controller';
import { PublicWorkersController } from './public-workers.controller';
import { Worker } from './worker.entity';
import { WorkerRatingManualModule } from './worker-rating-manual.module';

/**
 * 找陪玩 + 打手公开信息（公开）：
 * - `PublicPlayersController` → `PlayersService`：只返回 名字 + 介绍 + 头像 + 分部 + 三个数值 + 等级三件套
 *   （负责人 2026-10-03 硬规则；2026-10-15 追加数值；2026-10-16 数值改为**生效值**；
 *   2026-10-17 追加 `grade/gradeLabel/gradeName`，五维与进度**不在列表**里）
 * - `PublicWorkersController`：打手公开信息（接单次数 + 好评率 + 最近评价 + 等级/五维/进度）
 *   聚合读分别委托 `ReviewService` 与 `WorkerGradeService`（各自口径唯一一处，见两个服务的类注释）
 *
 * `PlayersService` 对外导出（2026-10-16 任务②）：聚合接口 `GET /public/home` 的 `players` 子块
 * 必须与 `GET /public/players` 是**同一份名单、同一段实现**（`HomeContentModule` import 本模块）。
 *
 * `RatingModule` 是 2026-10-17 新增的依赖：等级要由 `WorkerGradeService` 提供
 * （`grade` 的**唯一出处**），本模块只用它读（`batchGrades` / `detail`），不写任何等级数据。
 *
 * `WorkerRatingManualModule` 是 2026-10-18 新增的依赖：公开详情的 `rating.score` / `rating.sources`
 * 要由 `WorkerRatingManualService.resolveRating()` 解析（手填优先、逐维回落聚合）。
 * **它只服务展示**：等级判定（`WorkerGradeService`）不注入、也不读 `worker_rating_manual` ——
 * 「管理端手填值只影响展示，不影响等级判定，否则改分即可刷等级」。
 */
@Module({
  imports: [
    TypeOrmModule.forFeature([Worker, User]),
    ReviewModule,
    RatingModule,
    WorkerRatingManualModule,
  ],
  controllers: [PublicPlayersController, PublicWorkersController],
  providers: [PlayersService],
  exports: [PlayersService],
})
export class PlayersModule {}
