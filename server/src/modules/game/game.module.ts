import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Product } from '../product/product.entity';
import { CatalogSeedService } from './catalog.seed';
import { Category } from './category.entity';
import { GameConfig } from './game-config.entity';
import { Game } from './game.entity';
import { GameAdminController } from './game-admin.controller';
import { GameService } from './game.service';

/**
 * `OperationLog` + `OperationLogService`：管理端游戏/分类的 7 个写接口必须写 `operation_log`
 * （负责人铁律「管理端任何会改变库内容的接口，成功后必须留痕」）。
 * 既有姿势 = 各模块自己 `forFeature([..., OperationLog])` + provide（见 `division.module`）——
 * ⚠️ **`OperationLog` 实体必须进 `forFeature`**：`OperationLogService` 构造里注入了
 * `@InjectRepository(OperationLog)`，只 provide service 而不注册实体会在启动时抛
 * `UnknownDependenciesException: Nest can't resolve dependencies of the OperationLogService`。
 */
@Module({
  imports: [TypeOrmModule.forFeature([Game, GameConfig, Category, Product, OperationLog])],
  controllers: [GameAdminController],
  providers: [GameService, CatalogSeedService, OperationLogService],
  exports: [GameService],
})
export class GameModule {}
