import { Body, Controller, Get, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { parsePage, parsePageSize } from '../../common/pagination';
import { OperationLogService } from '../log/operation-log.service';
import { AiChatDto, AiRecommendDto, AiService } from './ai.service';

/**
 * 老板端 AI 咨询「祁小山」（负责人 2026-10-04）
 *
 * - 身份只从 JWT sub 取（CurrentUser），请求体里的任何 id 都不作为身份
 * - chat 立即返回 { conversationId, messageId, accepted: true }，内容走 WS：
 *   ai:chunk / ai:done / ai:error / ai:handoff（realtime gateway，房间 uid:{userId}）
 * - 历史/停止/转人工走 HTTP（WS 上行可选，本版本统一用 HTTP）
 */
@ApiTags('user/ai')
@Controller('user/ai')
@UseGuards(JwtAuthGuard)
@ApiBearerAuth()
export class AiUserController {
  constructor(private readonly ai: AiService) {}

  @Post('chat')
  @ApiOperation({
    summary: 'AI 咨询提问（立即返回；回复经 WS ai:chunk/ai:done 下发）',
  })
  chat(@CurrentUser() user: { userId: string }, @Body() dto: AiChatDto) {
    return this.ai.chat(user.userId, dto ?? {});
  }

  @Get('config')
  @ApiOperation({ summary: 'AI 咨询配置（总开关/快捷问题/输入上限/开场白）' })
  config() {
    return this.ai.config();
  }

  @Post('recommend')
  @ApiOperation({
    summary: '找陪玩：按需求推荐打手（同步返回 reply + picks；20 秒超时降级为规则推荐）',
  })
  recommend(@CurrentUser() user: { userId: string }, @Body() dto: AiRecommendDto) {
    // 身份只从 JWT sub 取；body 里只有"需求"文本与可选分部，没有也不接受任何用户标识
    return this.ai.recommend(user.userId, dto ?? {});
  }

  @Get('messages')
  @ApiOperation({ summary: 'AI 咨询历史（倒序补拉：beforeSeq + limit）' })
  messages(
    @CurrentUser() user: { userId: string },
    @Query('conversationId') conversationId?: string,
    @Query('beforeSeq') beforeSeq?: string,
    @Query('limit') limit?: string,
  ) {
    return this.ai.messages(user.userId, { conversationId, beforeSeq, limit });
  }

  @Post('reset')
  @ApiOperation({
    summary: 'AI 会话轮换（离开会话页时调用）：新 session 从头开始，旧对话仍留在库里（管理端可查）',
  })
  reset(@CurrentUser() user: { userId: string }) {
    // 身份只从 JWT sub 取：请求体里的任何 id 都不作为身份（轮换对象永远是调用者自己）
    return this.ai.resetSession(user.userId);
  }

  @Post('handoff')
  @ApiOperation({ summary: '转人工：复用既有客服会话，返回 csConversationId（并 WS 下发 ai:handoff）' })
  handoff(@CurrentUser() user: { userId: string }) {
    return this.ai.handoff(user.userId);
  }

  @Post('stop')
  @ApiOperation({ summary: '停止当前生成（服务端中断上游请求）' })
  stop(@CurrentUser() user: { userId: string }, @Body() dto?: { messageId?: string }) {
    return this.ai.stop(user.userId, dto?.messageId);
  }
}

/** 管理端 AI 咨询查看（只读，权限点 admin:ai:read；查看消息留痕 operation_log） */
@ApiTags('admin/ai')
@Controller('admin/ai')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class AiAdminController {
  constructor(
    private readonly ai: AiService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get('conversations')
  @RequirePermission('admin:ai:read')
  @ApiOperation({ summary: '权限点 admin:ai:read：AI 咨询会话列表' })
  conversations(@Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.ai.adminConversations(parsePage(page), parsePageSize(pageSize));
  }

  @Get('messages')
  @RequirePermission('admin:ai:read')
  @ApiOperation({ summary: '权限点 admin:ai:read：某会话的消息（留痕）' })
  messages(
    @Query('conversationId') conversationId: string,
    @Query('limit') limit: string | undefined,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'ai',
      action: 'ai:read',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ conversationId }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return this.ai.adminMessages(String(conversationId ?? ''), parsePageSize(limit, 100, 500));
  }
}
