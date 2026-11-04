import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Media } from './media.entity';
import { MediaAdminController, MediaController } from './media.controller';
import { MediaService } from './media.service';

/**
 * `OperationLog` + `OperationLogService`（2026-10-13）：`DELETE /admin/media/:id` 是**破坏性动作**
 * （删库行 + 物理删文件，不可逆），按负责人铁律「管理端任何会改变库内容的接口，成功后必须写
 * `operation_log`」必须留痕。此前该接口**完全没有留痕** —— 实测真库 `operation_log` 里
 * `module='media'` 或 `path LIKE '%media%'` 的行数为 **0**（连上传都没有）。
 *
 * ## 为什么只给 DELETE 补，`POST /admin/media/upload` 刻意不补
 * 上传是**高频**动作（管理端配商品图/Banner/分部图标时连续传很多张），
 * 每张都写一条审计会让 `operation_log` 被"上传"淹没 —— 而审计的价值在于**异常动作可回溯**。
 * 删除是**低频 + 不可逆 + 破坏性**：删错了必须有据可查（谁、什么时候、删了哪个 mediaId、
 * 什么用途、多大、什么 sha256、删前是否被引用）。
 * 结论：**只补 DELETE**；上传保持不留痕。这个取舍是刻意的，不是遗漏 —— 若将来上传要留痕，
 * 请先解决"日志膨胀"（例如按批次聚合），不要直接在这里加一行 `opLog.log`。
 *
 * ⚠️ **两件都要做，缺一即崩**（本项目已踩过一次，`UnknownDependenciesException` 崩溃循环 46 次）：
 * `OperationLogService` 构造里注入了 `@InjectRepository(OperationLog)` —— 只 provide service
 * 而不把 `OperationLog` 实体放进 `forFeature`，Nest 启动时就解析不到依赖。
 * 本模块此前两者都没有，故**两处一起加**（与 `game.module.ts` / `division.module.ts` 同一姿势）。
 */
@Module({
  imports: [TypeOrmModule.forFeature([Media, OperationLog])],
  controllers: [MediaController, MediaAdminController],
  providers: [MediaService, OperationLogService],
  exports: [MediaService],
})
export class MediaModule {}
