import { Body, Controller, Get, HttpCode, Param, Post, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import { Request } from 'express';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { ChatService } from './chat.service';
import { parsePage, parsePageSize, parseSeq } from '../../common/pagination';

/** 用户端聊天（docs/07）：会话 + 消息历史/增量 + HTTP 发送兜底 */
@ApiTags('user/chat')
@Controller('user')
@UseGuards(JwtAuthGuard)
@ApiBearerAuth()
export class ChatUserController {
  constructor(private readonly chat: ChatService) {}

  @Get('conversation')
  @ApiOperation({ summary: '我的客服会话（自动创建，含未读数）' })
  conversation(@CurrentUser() user: { userId: string }) {
    return this.chat.getUserConversation(user.userId);
  }

  @Get('conversations')
  @ApiOperation({ summary: '我的会话列表（客服 + 好友；含对方资料/最后一条消息/我的未读/状态）' })
  conversations(@CurrentUser() user: { userId: string }) {
    return this.chat.listUserConversations(user.userId);
  }

  @Post('conversation/close')
  @ApiOperation({ summary: '本次咨询已完成（需求 #7）：结束当前客服会话，保留历史；再咨询自动开新会话' })
  close(@CurrentUser() user: { userId: string; role?: string }) {
    // sessionRole 透传：打手态（companion，role=worker）的「结束咨询」走的就是这条（请求体不带 id），
    // 由 ChatService.closeByUser 决定"关哪一条"（详见该方法的注释：老语义优先，绝不猜）
    return this.chat.closeByUser(user.userId, user.role ?? 'user');
  }

  @Get('conversations/:id/info')
  @ApiOperation({ summary: '会话状态信息（成员校验；聊天详情页判断已结束）' })
  async info(@CurrentUser() user: { userId: string; role?: string }, @Param('id') id: string) {
    // 自称方判定：老板态 = user 侧（一行未变）；打手态（companion/worker）若是我**正在服务**的
    // 客服会话 → worker 侧（修复"列表里有、点开 404「会话不存在」"）
    const actor = await this.chat.resolveUserRouteActor(user.userId, user.role ?? '', id);
    return this.chat.conversationInfo(actor, id);
  }

  @Get('conversation/messages')
  @ApiOperation({ summary: '消息历史（倒序分页）' })
  async history(@CurrentUser() user: { userId: string }, @Query('beforeSeq') beforeSeq?: string, @Query('limit') limit?: string) {
    const conv = await this.chat.getUserConversation(user.userId);
    return this.chat.history({ type: 'user', userId: user.userId }, conv.id, parseSeq(beforeSeq, 0), parsePageSize(limit, 50, 200));
  }

  @Get('conversation/sync')
  @ApiOperation({ summary: '增量同步（afterSeq 之后的消息）' })
  sync(@CurrentUser() user: { userId: string }, @Query('afterSeq') afterSeq?: string) {
    return this.syncUser(user.userId, Number(afterSeq) || 0);
  }

  @Post('conversation/messages')
  @ApiOperation({ summary: '发送客服会话消息（HTTP 兜底；WS msg:send 优先）' })
  send(
    @CurrentUser() user: { userId: string },
    @Body() dto: { clientMsgId?: string; msgType?: string; content: string },
  ) {
    return this.sendAsUser(user.userId, dto);
  }

  @Post('conversations/:id/messages')
  @ApiOperation({ summary: '发送会话消息（CS 或好友会话；HTTP 兜底，WS msg:send 优先）' })
  async sendTo(
    @CurrentUser() user: { userId: string; role?: string },
    @Param('id') id: string,
    @Body() dto: { clientMsgId?: string; msgType?: string; content: string },
  ) {
    // 与 info/history/sync 同一自称方判定：客服（打手态）回复老板时落 `sender_type='worker'`、
    // 未读记到老板侧 —— 与 `/worker/cs/conversations/:id/messages` 完全同一条写路径
    const actor = await this.chat.resolveUserRouteActor(user.userId, user.role ?? '', id);
    return this.chat.sendMessage(actor, id, dto);
  }

  /**
   * 一键已读（REST 兜底，负责人 2026-10-06 裁决 · 缺口 3）。
   *
   * 客户端「一键已读」按钮打的就是这条（`apps/packages/core/lib/src/identity/worker_messages_page.dart`、
   * `apps/boss-app/lib/pages/messages_page.dart`）—— 此前服务端**没有这个路由**（404「请求的资源不存在」），
   * 于是按钮是**静默 no-op**（客户端 catch 掉异常、未读数不清零）。现在转发到 `ChatService.markRead`
   * （与 WS `msg:read` 同一实现，语义完全一致），**重复调用幂等**，返回 `{ ok: true, unread: 0 }`。
   *
   * 权限：只认**当事方**（会话属主/对端，或被指派的客服）→ 否则 404/403 中文；companion（打手态）
   * 在消息族白名单内，`role=worker` 时按会话归属判定侧别（自己发起的客服会话也能已读）。
   */
  @Post('conversations/:id/read')
  // 200（不是 POST 默认的 201）：这是**幂等的"标记已读"**，不创建任何资源 —— 与 `/auth/login`、
  // `/user/identity/bind|unbind` 等非创建型 POST 的既有口径一致（负责人裁决的验收口径也是 200）
  @HttpCode(200)
  @ApiOperation({ summary: '会话标记已读（一键已读；语义与 WS msg:read 一致，幂等）' })
  read(@CurrentUser() user: { userId: string; role?: string }, @Param('id') id: string) {
    return this.chat.markReadAsCaller(user.userId, user.role ?? '', id);
  }

  @Get('conversations/:id/messages')
  @ApiOperation({ summary: '会话消息历史（CS 或好友会话，倒序分页）' })
  async historyOf(
    @CurrentUser() user: { userId: string; role?: string },
    @Param('id') id: string,
    @Query('beforeSeq') beforeSeq?: string,
    @Query('limit') limit?: string,
  ) {
    const actor = await this.chat.resolveUserRouteActor(user.userId, user.role ?? '', id);
    return this.chat.history(actor, id, parseSeq(beforeSeq, 0), parsePageSize(limit, 50, 200));
  }

  @Get('conversations/:id/sync')
  @ApiOperation({ summary: '会话增量同步（CS 或好友会话）' })
  async syncOf(
    @CurrentUser() user: { userId: string; role?: string },
    @Param('id') id: string,
    @Query('afterSeq') afterSeq?: string,
  ) {
    const actor = await this.chat.resolveUserRouteActor(user.userId, user.role ?? '', id);
    return this.chat.sync(actor, id, Number(afterSeq) || 0);
  }

  // 便捷内部方法（同步/发送复用）
  private async syncUser(userId: string, afterSeq: number) {
    const conv = await this.chat.getUserConversation(userId);
    return this.chat.sync({ type: 'user', userId }, conv.id, afterSeq);
  }

  private async sendAsUser(userId: string, dto: { clientMsgId?: string; msgType?: string; content: string }) {
    const conv = await this.chat.getUserConversation(userId);
    return this.chat.sendMessage({ type: 'user', userId }, conv.id, dto);
  }
}

/** 客服端（工作端持客服权限，docs/07：实时查库 + active 授权） */
@ApiTags('worker/cs')
@Controller('worker/cs')
@UseGuards(JwtAuthGuard, RolesGuard)
@Roles('worker')
@ApiBearerAuth()
export class ChatWorkerController {
  constructor(
    private readonly chat: ChatService,
    private readonly opLog: OperationLogService,
  ) {}

  /**
   * 客服大厅：待接入列表（负责人 2026-10-08「有客服权限的人用打手端主动接」）。
   *
   * 与既有 `GET conversations` 的关系：这里是**池子**（还没人接的），`conversations` 是**我的**
   * （已指派给我的）。两者合起来才是客服的完整工作台 —— 既有接口语义**一个字未改**。
   *
   * 权限：`@Roles('worker')`（类上）+ 服务层**每请求实时查库** `worker.can_serve_customer=1`；
   * 无客服权限 → 403 中文「无客服权限」。
   * 分页：`docs/03` 既有口径（默认 20 / 硬上限 50，`parsePageSize`）。
   */
  @Get('hall')
  @ApiOperation({ summary: '客服大厅：待接入列表（需客服权限，每请求实时查库；等待最久在前；抢占式接入）' })
  hall(@CurrentUser() user: { userId: string }, @Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.chat.csHall(user.userId, parsePage(page), parsePageSize(pageSize));
  }

  /**
   * 客服大厅：主动接入（抢占式）。
   *
   * **HTTP 200 而不是 POST 默认的 201**：这是**幂等的"接入"**（自己重复点 → `alreadyClaimed: true`
   * 同样 200），不创建任何面向客户端的资源 —— 与既有口径一致
   * （`POST /user/conversations/:id/read` 的幂等 POST 也是 200；`/auth/login`、
   * `/user/identity/bind|unbind` 同属"非创建型 POST"）。客户端按 2xx 处理即可。
   *
   * 错误：409「该咨询已被其他客服接入」（抢慢了，**不静默成功**）/
   * 404「会话不存在」/ 400「该咨询已结束，无法接入」/ 403「无客服权限」。
   */
  @Post('hall/:conversationId/claim')
  @HttpCode(200)
  @ApiOperation({ summary: '客服大厅：主动接入（抢占式；已被别人接走 → 409 中文；自己重复点 → 幂等成功）' })
  async claim(
    @CurrentUser() user: { userId: string },
    @Param('conversationId') conversationId: string,
    @Req() req: Request,
  ) {
    const result = await this.chat.claimCsConversation(user.userId, conversationId);
    /**
     * 审计留痕：**与 `admin/chat` 的 `chat:assign` 用同一张表、同一套字段**（口径统一，
     * 一个会话的接入史在一处回看）。两点必须写清楚，避免后人误读：
     * - `admin_id` 存的是**操作者** = 客服（打手）的 user id，**不是**管理员 —— 该列自
     *   2026-10-06 起允许为 NULL（`OperationLogInput.adminUserId` 的注释），这里刻意存操作者，
     *   否则"谁接的"就丢了；
     * - `assigned_by`（指派表那一列）= 接入者自己 = **自主接入**（与管理员改派区分）。
     * 只在**真正写入**的那一次留痕（幂等重复点不改库，也就不留痕）。
     */
    if (!result.alreadyClaimed) {
      this.opLog.log({
        adminUserId: user.userId,
        adminName: '',
        module: 'chat',
        action: 'chat:claim',
        method: req.method,
        path: req.path,
        requestBody: JSON.stringify({
          conversationId,
          workerUserId: user.userId,
          source: 'worker-hall',
          assignedBy: 'self',
        }),
        ip: req.ip,
        requestId: req.requestId,
      });
    }
    return result;
  }

  /**
   * 客服大厅：退回池子（**负责人尚未定案** → 由 `system_setting.cs_hall_release_enabled` 控制，
   * 默认开放；置 `{"value":0}` 立刻 403 中文「客服退回功能未开放」，要彻底删除见 `cs-hall.ts`）。
   *
   * 语义 = 把自己那一行 active 指派置为 `released`（**历史保留**）→ 会话重新进入待接入池
   * → 通知大厅重新出现。同样 200（幂等：重复退回 → `alreadyReleased: true`）。
   * 错误：403「客服退回功能未开放」/403「无客服权限」/404「会话不存在」/
   * 400「该咨询已结束，无需退回」/400「你不是该咨询的接入客服，无法退回」。
   */
  @Post('hall/:conversationId/release')
  @HttpCode(200)
  @ApiOperation({ summary: '客服大厅：退回池子（开关控制，负责人尚未定案；幂等）' })
  async release(
    @CurrentUser() user: { userId: string },
    @Param('conversationId') conversationId: string,
    @Req() req: Request,
  ) {
    const result = await this.chat.releaseCsConversation(user.userId, conversationId);
    if (!result.alreadyReleased) {
      this.opLog.log({
        adminUserId: user.userId,
        adminName: '',
        module: 'chat',
        action: 'chat:release',
        method: req.method,
        path: req.path,
        requestBody: JSON.stringify({ conversationId, workerUserId: user.userId, source: 'worker-hall' }),
        ip: req.ip,
        requestId: req.requestId,
      });
    }
    return result;
  }

  @Get('conversations')
  @ApiOperation({ summary: '我的客服会话列表（active 授权）' })
  list(@CurrentUser() user: { userId: string }) {
    return this.chat.workerConversations(user.userId);
  }

  @Get('conversations/:id/messages')
  @ApiOperation({ summary: '会话消息历史' })
  history(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Query('beforeSeq') beforeSeq?: string, @Query('limit') limit?: string) {
    return this.chat.history({ type: 'worker', userId: user.userId }, id, parseSeq(beforeSeq, 0), parsePageSize(limit, 50, 200));
  }

  @Get('conversations/:id/info')
  @ApiOperation({ summary: '会话状态信息（客服权限+授权校验）' })
  info(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.chat.conversationInfo({ type: 'worker', userId: user.userId }, id);
  }

  @Post('conversations/:id/close')
  @ApiOperation({ summary: '客服结束本次咨询（需求 #7）：保留历史，用户再咨询自动开新会话' })
  close(@CurrentUser() user: { userId: string }, @Param('id') id: string) {
    return this.chat.closeByWorker(user.userId, id);
  }

  @Post('conversations/:id/messages')
  @ApiOperation({ summary: '客服发送消息（HTTP 兜底）' })
  send(@CurrentUser() user: { userId: string }, @Param('id') id: string, @Body() dto: { clientMsgId?: string; msgType?: string; content: string }) {
    return this.chat.sendMessage({ type: 'worker', userId: user.userId }, id, dto);
  }
}

/** 管理端聊天管理（docs/07：admin:chat:read 查看 + admin:chat:assign 指派客服） */
@ApiTags('admin/chat')
@Controller('admin/chat')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class ChatAdminController {
  constructor(
    private readonly chat: ChatService,
    private readonly opLog: OperationLogService,
  ) {}

  @Get('conversations')
  @RequirePermission('admin:chat:read')
  @ApiOperation({ summary: '权限点 admin:chat:read：会话列表' })
  list(@Query('page') page?: string, @Query('pageSize') pageSize?: string) {
    return this.chat.adminConversations(parsePage(page), parsePageSize(pageSize));
  }

  @Get('conversations/:id/messages')
  @RequirePermission('admin:chat:read')
  @ApiOperation({ summary: '权限点 admin:chat:read：查看会话消息（留痕）' })
  messages(@Param('id') id: string, @Query('limit') limit?: string) {
    return this.messagesOf(id, parsePageSize(limit, 100, 500));
  }

  @Post('conversations/:id/assign')
  @RequirePermission('admin:chat:assign')
  @ApiOperation({ summary: '权限点 admin:chat:assign：指派客服（改派后原客服被强制离开）' })
  async assign(@Param('id') id: string, @Body() dto: { workerUserId: string }, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.chat.assignConversation(id, dto.workerUserId, user.userId);
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'chat',
      action: 'chat:assign',
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify({ conversationId: id, workerUserId: dto.workerUserId }),
      ip: req.ip,
      requestId: req.requestId,
    });
    return result;
  }

  private messagesOf(conversationId: string, limit: number) {
    return this.chat.adminMessages(conversationId, limit);
  }
}
