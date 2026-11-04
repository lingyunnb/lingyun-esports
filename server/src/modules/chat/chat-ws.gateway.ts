import { Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { OnGatewayConnection, SubscribeMessage, WebSocketGateway, WebSocketServer } from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { Repository } from 'typeorm';
import { ChatConversationAssign } from './chat-conversation-assign.entity';
import { ChatConversation } from './chat-conversation.entity';
import { ChatService } from './chat.service';

/**
 * 聊天 WS 网关（docs/07，与派单共享 /ws/chat 命名空间）：
 * - conv:join 房间加入前服务端校验归属（用户=会话属主；客服=实时查库权限+active 授权），越权拒绝并审计
 * - msg:send / msg:read / msg:recall / sync 业务事件委托 ChatService
 * - 连接建立时推送 unread:snapshot
 */
@WebSocketGateway({
  namespace: '/ws/chat',
  cors: { origin: true, credentials: true },
})
export class ChatWsGateway implements OnGatewayConnection {
  private readonly logger = new Logger('ChatWs');

  @WebSocketServer()
  server!: Server;

  constructor(
    private readonly chat: ChatService,
    @InjectRepository(ChatConversation) private readonly convRepo: Repository<ChatConversation>,
    @InjectRepository(ChatConversationAssign) private readonly assignRepo: Repository<ChatConversationAssign>,
  ) {}

  async handleConnection(client: Socket): Promise<void> {
    // 认证在 RealtimeGateway 完成（同一命名空间共享握手）；未认证的 socket 无 userId 标记
    const userId = client.data?.userId as string | undefined;
    if (!userId) return;
    try {
      const snapshot =
        client.data.role === 'worker'
          ? await this.workerSnapshot(userId)
          : await this.userSnapshot(userId);
      client.emit('unread:snapshot', snapshot);
    } catch (e) {
      this.logger.warn(`unread:snapshot 失败: ${(e as Error).message}`);
    }
  }

  /** 客户端主动拉取未读快照（网关连接顺序不保证时，重连后由客户端请求兜底） */
  @SubscribeMessage('sync:unread')
  async onSyncUnread(client: Socket) {
    const userId = client.data?.userId as string | undefined;
    if (!userId) return;
    try {
      const snapshot =
        client.data.role === 'worker'
          ? await this.workerSnapshot(userId)
          : await this.userSnapshot(userId);
      client.emit('unread:snapshot', snapshot);
    } catch (e) {
      this.logger.warn(`sync:unread 失败: ${(e as Error).message}`);
    }
  }

  private async userSnapshot(userId: string) {
    // 未读快照：客服（属主）+ 好友私聊 + 打手直聊（后两者都是双人会话，按属主/对端取未读）
    // 【2026-10-11】客服分支只算 `status='open'`：已结束的咨询不在会话列表里，
    // 未读快照也不得再把它算进总未读（否则底部导航"消息"红点与列表对不上 —— 真机报障口径：
    // "列表与总未读数一致"）。与 ChatService.listUserConversations 的过滤逐字同源。
    const convs = await this.convRepo
      .createQueryBuilder('c')
      .where(
        '(c.user_id = :u AND c.type = :cs AND c.status = :open) OR (c.type IN (:...duo) AND (c.user_id = :u OR c.peer_user_id = :u))',
        { u: userId, cs: 'cs', open: 'open', duo: ['friend', 'worker'] },
      )
      .getMany();
    return convs.map((c) => ({
      conversationId: c.id,
      unread: String(c.userId) === String(userId) ? c.unreadUser : c.unreadPeer,
    }));
  }

  private async workerSnapshot(workerUserId: string) {
    // 未读快照：我作为客服被授权的 CS 会话 + 我的好友/打手直聊（群组功能已下掉）
    // 【2026-10-11】被指派的客服会话同样只算 `status='open'`（已结束不再进列表，也就不该再挂红点），
    // 与 ChatService.workerConversations 同源。
    const assigns = await this.assignRepo.find({ where: { workerUserId, status: 'active' } });
    const base: Array<{ conversationId: string; unread: number }> = [];
    if (assigns.length) {
      const convs = await this.convRepo
        .createQueryBuilder('c')
        .where('c.id IN (:...ids) AND c.status = :open', { ids: assigns.map((a) => a.conversationId), open: 'open' })
        .getMany();
      base.push(...convs.map((c) => ({ conversationId: c.id, unread: c.unreadWorker })));
    }
    const duo = await this.convRepo
      .createQueryBuilder('c')
      .where('c.type IN (:...duo) AND (c.user_id = :u OR c.peer_user_id = :u)', {
        duo: ['friend', 'worker'],
        u: workerUserId,
      })
      .getMany();
    base.push(
      ...duo.map((c) => ({
        conversationId: c.id,
        unread: String(c.userId) === String(workerUserId) ? c.unreadUser : c.unreadPeer,
      })),
    );
    return base;
  }

  // ---------------- 事件（docs/07） ----------------

  /** 加入会话房间（服务端强制校验；越权拒绝并审计） */
  @SubscribeMessage('conv:join')
  async onJoin(client: Socket, payload: { conversationId?: string }) {
    const userId = client.data?.userId as string | undefined;
    if (!userId || !payload?.conversationId) {
      client.emit('conv:join:error', { conversationId: payload?.conversationId ?? null, reason: '参数缺失' });
      return;
    }
    try {
      if (client.data.role === 'worker') {
        await this.chat.assertWorkerCs(payload.conversationId, userId);
      } else {
        await this.chat.assertUserMember(payload.conversationId, userId);
      }
      await client.join(`conv:${payload.conversationId}`);
      client.emit('conv:join:ok', { conversationId: payload.conversationId });
    } catch (e) {
      this.logger.warn(`越权 join 会话被拒 uid=${userId} conv=${payload.conversationId}: ${(e as Error).message}`);
      client.emit('conv:join:error', { conversationId: payload.conversationId, reason: '无权限访问该会话' });
    }
  }

  @SubscribeMessage('msg:send')
  async onSend(client: Socket, payload: { conversationId?: string; clientMsgId?: string; msgType?: string; content?: string }) {
    const userId = client.data?.userId as string | undefined;
    if (!userId || !payload?.conversationId) return;
    try {
      await this.chat.sendMessage(
        { type: client.data.role === 'worker' ? 'worker' : 'user', userId },
        payload.conversationId,
        { clientMsgId: payload.clientMsgId, msgType: payload.msgType ?? 'text', content: payload.content ?? '' },
      );
    } catch (e) {
      client.emit('msg:error', { clientMsgId: payload.clientMsgId ?? null, message: (e as Error).message });
    }
  }

  @SubscribeMessage('msg:read')
  async onRead(client: Socket, payload: { conversationId?: string }) {
    const userId = client.data?.userId as string | undefined;
    if (!userId || !payload?.conversationId) return;
    try {
      await this.chat.markRead({ type: client.data.role === 'worker' ? 'worker' : 'user', userId }, payload.conversationId);
    } catch {
      // 已读失败静默（客户端可在下次拉取修正）
    }
  }

  @SubscribeMessage('msg:recall')
  async onRecall(client: Socket, payload: { msgId?: string }) {
    const userId = client.data?.userId as string | undefined;
    if (!userId || !payload?.msgId) return;
    try {
      await this.chat.recall({ type: client.data.role === 'worker' ? 'worker' : 'user', userId }, payload.msgId);
    } catch (e) {
      client.emit('msg:error', { message: (e as Error).message });
    }
  }

  @SubscribeMessage('sync')
  async onSync(client: Socket, payload: { conversationId?: string; lastSeq?: number }) {
    const userId = client.data?.userId as string | undefined;
    if (!userId || !payload?.conversationId) return;
    try {
      const result = await this.chat.sync(
        { type: client.data.role === 'worker' ? 'worker' : 'user', userId },
        payload.conversationId,
        Number(payload.lastSeq) || 0,
      );
      client.emit('sync:result', { conversationId: payload.conversationId, ...result });
    } catch {
      // 增量对齐失败走 HTTP 补拉兜底
    }
  }
}

