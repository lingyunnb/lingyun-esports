import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { redisProvider } from '../../common/redis.provider';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { SystemSettingModule } from '../setting/system-setting.module';
import { ChatConversationAssign } from './chat-conversation-assign.entity';
import { ChatConversationMember } from './chat-conversation-member.entity';
import { ChatConversation } from './chat-conversation.entity';
import { ChatMessage } from './chat-message.entity';
import { ChatAdminController, ChatUserController, ChatWorkerController } from './chat.controller';
import { ChatService } from './chat.service';
import { ChatWsGateway } from './chat-ws.gateway';

@Module({
  imports: [
    TypeOrmModule.forFeature([ChatConversation, ChatConversationAssign, ChatConversationMember, ChatMessage, OperationLog]),
    SystemSettingModule,
  ],
  controllers: [ChatUserController, ChatWorkerController, ChatAdminController],
  providers: [ChatService, ChatWsGateway, OperationLogService, redisProvider],
  exports: [ChatService],
})
export class ChatModule {}
