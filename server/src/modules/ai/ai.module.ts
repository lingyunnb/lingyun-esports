import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { redisProvider } from '../../common/redis.provider';
import { ChatModule } from '../chat/chat.module';
import { OperationLog } from '../log/operation-log.entity';
import { OperationLogService } from '../log/operation-log.service';
import { SystemSettingModule } from '../setting/system-setting.module';
import { AiConversation } from './ai-conversation.entity';
import { AiMessage } from './ai-message.entity';
import { AiAdminController, AiUserController } from './ai.controller';
import { AiService } from './ai.service';
import { AiUpstreamClient } from './ai-upstream.client';

/**
 * AI 咨询「祁小山」模块（负责人 2026-10-04）
 * - 复用 ChatModule（转人工走既有客服会话）+ SystemSettingModule（配置可管理端调整）
 * - 复用全局 RealtimeGateway（WS 按用户房间下发 ai:* 事件）
 * - 零新增 npm 依赖（GLM 调用用 Node 内置 fetch + 手写 SSE 解析）
 */
@Module({
  imports: [TypeOrmModule.forFeature([AiConversation, AiMessage, OperationLog]), ChatModule, SystemSettingModule],
  controllers: [AiUserController, AiAdminController],
  providers: [AiService, AiUpstreamClient, OperationLogService, redisProvider],
  exports: [AiService],
})
export class AiModule {}
