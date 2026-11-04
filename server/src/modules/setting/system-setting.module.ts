import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { BackupService } from './backup.service';
import { OrderNoticeAdminController } from './order-notice.controller';
import { OrderFormAdminController, OrderFormPublicController } from './order-form.controller';
import { PurchaseHintAdminController, PurchaseHintPublicController } from './purchase-hint.controller';
import { SystemSettingController } from './system-setting.controller';
import { SystemSetting } from './system-setting.entity';
import { SystemSettingService } from './system-setting.service';
import { SystemStatusController } from './system-status.controller';

/**
 * 系统设置模块。
 *
 * `OperationLog` / `OperationLogService` 进这里的原因：`SystemSettingService.update()` 是
 * **全项目唯一的配置写入口**，2026-10-06 起它负责写 `module='setting'` 的审计行
 * ——「改了什么、改前是什么」必须可回溯（负责人铁律：管理员动作必须留痕）。
 * 本仓库的既有姿势是各模块自己 provide `OperationLogService`（见 `order.module` / `tip.module`），
 * 这里沿用同一种，不引入第二种取用方式。
 */
@Module({
  imports: [TypeOrmModule.forFeature([SystemSetting, OperationLog])],
  controllers: [
    SystemSettingController,
    SystemStatusController,
    OrderFormPublicController,
    OrderFormAdminController,
    // 下单须知（商品级覆盖 → 平台默认）：平台默认这一层的读写
    OrderNoticeAdminController,
    // 购买提示（选择服务页小字，负责人 2026-10-05）：公开读 + 管理端读写（仅超管可写）
    PurchaseHintPublicController,
    PurchaseHintAdminController,
  ],
  providers: [SystemSettingService, BackupService, OperationLogService],
  exports: [SystemSettingService],
})
export class SystemSettingModule {}
