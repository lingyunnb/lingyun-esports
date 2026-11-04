import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { DivisionModule } from '../division/division.module';
import { LeaderboardModule } from '../leaderboard/leaderboard.module';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { MediaModule } from '../media/media.module';
import { ProductModule } from '../product/product.module';
import { PlayersModule } from '../worker/players.module';
import { Announcement } from './announcement.entity';
import { HomeBanner } from './home-banner.entity';
import { HomeModule } from './home-module.entity';
import { HomeAdminController } from './home-admin.controller';
import { HomePublicController } from './home-public.controller';
import { HomeService } from './home.service';
import { PublicHomeService } from './public-home.service';
import { TopWorker } from './top-worker.entity';

/**
 * `OperationLog` + `OperationLogService`：管理端首页内容（模块 / 宣传图 / 公告 / 优秀打手）
 * 的 9 个写接口必须写 `operation_log`（负责人铁律）。
 * 既有姿势 = 各模块自己 `forFeature([..., OperationLog])` + provide（见 `division.module`）——
 * ⚠️ **实体必须进 `forFeature`**，否则启动时 `OperationLogService` 的
 * `@InjectRepository(OperationLog)` 解析不到会抛 `UnknownDependenciesException`。
 *
 * 2026-10-16（任务②：首屏聚合 `GET /public/home`）：本模块**只导入不拥有**那四个子块的 service ——
 * `DivisionModule`（分部分组）/ `ProductModule`（商品）/ `LeaderboardModule`（榜单）/
 * `PlayersModule`（陪玩名单，含打手数值的生效值口径）。聚合层**一行 SQL 都不写**，
 * 各子块口径仍归属原模块（"同一规则只有一份实现"）。
 * 依赖方向是单向的：这四个模块都不 import 本模块（无循环依赖）。
 */
@Module({
  imports: [
    TypeOrmModule.forFeature([HomeModule, HomeBanner, Announcement, TopWorker, OperationLog]),
    MediaModule,
    DivisionModule,
    ProductModule,
    LeaderboardModule,
    PlayersModule,
  ],
  controllers: [HomePublicController, HomeAdminController],
  providers: [HomeService, PublicHomeService, OperationLogService],
})
export class HomeContentModule {}
