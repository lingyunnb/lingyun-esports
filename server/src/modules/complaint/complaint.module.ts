import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { UserNotification } from '../friend/user-notification.entity';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { Media } from '../media/media.entity';
import { Order } from '../order/order.entity';
import { User } from '../user/user.entity';
import { Worker } from '../worker/worker.entity';
import { ComplaintAdminController } from './complaint-admin.controller';
import { ComplaintUserController } from './complaint-user.controller';
import { Complaint } from './complaint.entity';
import { ComplaintService } from './complaint.service';

/** 投诉工单模块（顶部导航「投诉」：老板提交 → 管理端处理 → 结果通知） */
@Module({
  imports: [TypeOrmModule.forFeature([Complaint, Order, Worker, User, Media, UserNotification, OperationLog])],
  controllers: [ComplaintUserController, ComplaintAdminController],
  providers: [ComplaintService, OperationLogService],
  exports: [ComplaintService],
})
export class ComplaintModule {}
