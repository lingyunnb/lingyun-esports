import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { RealtimeModule } from '../../realtime/realtime.module';
import { ChatModule } from '../chat/chat.module';
import { User } from '../user/user.entity';
import { FriendController } from './friend.controller';
import { FriendService } from './friend.service';
import { UserFriend } from './user-friend.entity';
import { UserNotification } from './user-notification.entity';

/** 好友系统 + 系统通知（负责人需求 #16/#24） */
@Module({
  imports: [TypeOrmModule.forFeature([UserFriend, UserNotification, User]), RealtimeModule, ChatModule],
  controllers: [FriendController],
  providers: [FriendService],
  exports: [FriendService],
})
export class FriendModule {}
