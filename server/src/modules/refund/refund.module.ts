import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { UserNotification } from '../friend/user-notification.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { OrderModule } from '../order/order.module';
import { Order } from '../order/order.entity';
import { OrderPriceSnapshot } from '../order/order-price-snapshot.entity';
import { SystemSettingModule } from '../setting/system-setting.module';
import { User } from '../user/user.entity';
import { RefundAdminController } from './refund-admin.controller';
import { RefundRequest } from './refund-request.entity';
import { RefundService } from './refund.service';
import { RefundUserController } from './refund-user.controller';

/** 退款申请模块（顶部导航「退款」：老板申请 → 管理端审批 → 原路退回余额） */
@Module({
  imports: [
    TypeOrmModule.forFeature([RefundRequest, Order, OrderPriceSnapshot, User, UserNotification, OperationLog]),
    OrderModule,
    SystemSettingModule,
  ],
  controllers: [RefundUserController, RefundAdminController],
  providers: [RefundService, OperationLogService],
  exports: [RefundService],
})
export class RefundModule {}
