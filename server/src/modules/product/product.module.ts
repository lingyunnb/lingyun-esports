import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { Division } from '../division/division.entity';
import { GameModule } from '../game/game.module';
import { OperationLog } from '../log/operation-log.entity';
import { MediaModule } from '../media/media.module';
import { SystemSettingModule } from '../setting/system-setting.module';
import { ProductMedia } from './product-media.entity';
import { Product } from './product.entity';
import { ProductAdminController } from './product-admin.controller';
import { ProductService } from './product.service';
import { PublicCatalogController } from './public-catalog.controller';

@Module({
  imports: [
    // OperationLog 只为「移动商品」的审计写入注册（与数据变更同事务，见 ProductService.moveProducts）
    // Division 只读注册：「服务方式」要下发分部平台标签（division.platform_label），零写入
    TypeOrmModule.forFeature([Product, ProductMedia, OperationLog, Division]),
    GameModule,
    MediaModule,
    // 下单须知两层取值（商品级 → 平台默认）：读 system_setting 的 order_notice_default
    SystemSettingModule,
  ],
  controllers: [ProductAdminController, PublicCatalogController],
  providers: [ProductService],
  exports: [ProductService],
})
export class ProductModule {}
