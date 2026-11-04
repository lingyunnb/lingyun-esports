import { Module } from '@nestjs/common';

import { BindingReleaseService } from './binding-release.service';

/**
 * 绑定释放模块（安全审计 F1-b）：把"释放绑定 + 吊销 companion 令牌 + 写审计 + 断开 WS"
 * 收成一个可注入的服务，供 **AuthModule（老板主动解绑）/ UserModule（封禁、删除）/
 * AdminModule（打手停用两个入口）** 共用 —— 三个模块都 import 本模块，避免各自复制释放逻辑。
 *
 * 只依赖全局的 `DataSource`（TypeOrmModule.forRoot）与全局 `RealtimeModule` 导出的
 * `RealtimeGateway`，因此不需要 import 任何业务模块（零循环依赖风险）。
 */
@Module({
  providers: [BindingReleaseService],
  exports: [BindingReleaseService],
})
export class BindingReleaseModule {}
