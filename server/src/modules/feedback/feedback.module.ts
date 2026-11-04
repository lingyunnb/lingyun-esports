import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { User } from '../user/user.entity';
import { FeedbackAdminController } from './feedback-admin.controller';
import { FeedbackUserController } from './feedback-user.controller';
import { FeedbackService } from './feedback.service';
import { UserFeedback } from './user-feedback.entity';

/** 意见反馈模块（设置页入口） */
@Module({
  imports: [TypeOrmModule.forFeature([UserFeedback, User, OperationLog])],
  controllers: [FeedbackUserController, FeedbackAdminController],
  providers: [FeedbackService, OperationLogService],
  exports: [FeedbackService],
})
export class FeedbackModule {}
