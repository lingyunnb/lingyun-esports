import { Module } from '@nestjs/common';

import { SystemSettingModule } from '../setting/system-setting.module';
import { IdentityBindingAdminController } from './identity-binding-admin.controller';
import { IdentityBindingAdminService } from './identity-binding-admin.service';

/**
 * 身份绑定只读模块（管理端）。
 *
 * 依赖取舍：
 * - 不加 `TypeOrmModule.forFeature([WorkerIdentityBinding])`：本模块只读，查询是**原生 SQL 聚合**
 *   （列表 + 计数 + 分组汇总 + 关联老板/打手账号与工号），走 `DataSource` 反而更直白，
 *   也避免与 `AuthModule` 重复注册同一实体（`auth.module.ts` 已注册）。
 * - 复用 `SystemSettingModule` 导出的 `SystemSettingService` 读绑定上限（**唯一真相**在
 *   `system_setting.worker_binding_max_per_boss`，与绑定写入路径同一个 key/解析器/默认值）。
 */
@Module({
  imports: [SystemSettingModule],
  controllers: [IdentityBindingAdminController],
  providers: [IdentityBindingAdminService],
  exports: [IdentityBindingAdminService],
})
export class IdentityBindingModule {}
