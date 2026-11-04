import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Inject,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { randomUUID } from 'crypto';
import Redis from 'ioredis';
import { EntityManager, Repository } from 'typeorm';
import { REDIS_CLIENT } from '../../common/redis.provider';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { SystemSettingService } from '../setting/system-setting.service';
import { User } from '../user/user.entity';
import { Worker } from '../worker/worker.entity';
import { ChatConversationAssign } from './chat-conversation-assign.entity';
import { ChatConversationMember } from './chat-conversation-member.entity';
import { ChatConversation } from './chat-conversation.entity';
import { ChatMessage } from './chat-message.entity';
import {
  CS_HALL_PREVIEW_MAX,
  CS_HALL_PREVIEW_NONE,
  CS_HALL_RELEASE_DEFAULT,
  CS_HALL_RELEASE_DISABLED_VALUE,
  CS_HALL_RELEASE_KEY,
} from './cs-hall';

export type ChatActor = { type: 'user' | 'worker'; userId: string };

/** 订单群固定管理员（负责人要求：每个订单群自动包含该账号；按 uid 服务端解析，绝不信任客户端参数） */
export const ORDER_GROUP_ADMIN_UID = 'U9115350851';

/**
 * 「待接入池」的**唯一查询口径**（客服大厅，2026-10-08；2026-10-08 晚修正：只收"已经有老板消息"的会话）
 * —— hall 列表 / 总数（`total` 与 `waitingTotal` 同值）/ 广播受众三处共用这一份 SQL 片段。
 *
 * 口径来自负责人需求本身：「有人申请客服」= 老板发起的客服会话、**且老板至少发过一条消息**、
 * 且**还没有客服接入**。
 *
 * 三个条件各自解决什么：
 * 1. `type='cs' AND status='open'` —— 客服会话且未结束（会话结束时本来就不该再出现在待接入里）；
 * 2. `EXISTS(... m.sender_type='user')` —— **2026-10-08 晚新增（产品口径修正）**：
 *    老板**打开客服页那一刻就建了会话**（`getUserConversation` 的既有行为，一行不改），
 *    若把他还没打字时的空会话也算"有人申请客服"，大厅里就会冒出一排 `（暂无消息）` 的空条目
 *    （客服点了才发现没人说话）—— 这不是"有人申请"，是噪音。
 *    **只认老板自己发的消息**（`sender_type='user'`）而不是"会话里有任意一条消息"：
 *    管理端可以把一个**空会话**直接指派给客服（`assignConversation` 不要求先有消息），
 *    客服回复后即便退回池子，那条也**不是老板在等**，不该进池（等价写法 `EXISTS(chat_message)` 会漏进这一种）。
 * 3. `NOT EXISTS(... a.status='active')` —— "是否已被接入"以 `chat_conversation_assign` 里
 *    **有没有 active 行**为唯一判据（与 `assertWorkerCs` / 管理端列表同一判据）。
 *
 * 为什么用 `NOT EXISTS` 而不是 `LEFT JOIN ... IS NULL`：前者在"一个会话存在多行历史指派"时
 * 语义更直白（"不存在任何 active 行"），也不会因为 JOIN 出多行而把列表撑出重复项。
 *
 * ⚠️ 改动这里 = 同时改动列表、总数（含 `waitingTotal`）、广播受众三处 —— 这是刻意的：口径只有一份。
 * （三者同源的复核证据见 docs/03「客服大厅」与开发日志：列表与 `COUNT(*)` 直接内插本常量，
 * `waitingTotal` 直接取 `total` 的同一个变量；对外广播的**受众**用的是另一份共享判定
 * `onlineCsWorkerIds()`，由 `csHall.onlineCsCount` 与 `emitToOnlineCs` 共用 —— 它管"推给谁"，
 * 不管"哪些会话在池子里"，两者都只有一份实现。）
 */
const CS_POOL_SQL = `c.type = 'cs' AND c.status = 'open'
     AND EXISTS (SELECT 1 FROM chat_message pm
                  WHERE pm.conversation_id = c.id AND pm.sender_type = 'user')
     AND NOT EXISTS (SELECT 1 FROM chat_conversation_assign a
                      WHERE a.conversation_id = c.id AND a.status = 'active')`;

/**
 * 客服大厅「等待起点」表达式：**恒为首条老板咨询的发出时刻**（排序与时长同源）。
 *
 * 2026-10-08 晚随池子口径一起收紧：进池的前提就是"已经有老板消息"（`CS_POOL_SQL` 第 2 条），
 * 所以 `fm`（首条 `sender_type='user'` 的消息）必然存在，起点不再有歧义 ——
 * 老板 10:00 打开客服页建会话、10:10 才发第一句，等待时间从 **10:10** 起算（不是 10:00）。
 *
 * `COALESCE(fm.created_at, c.created_at)` 的兜底**保留为纯防御**（历史数据、将来若有人放宽池子条件、
 * 或某条会话的消息被异常清理）：宁可退化成"从会话创建时刻算"，也不要让 `TIMESTAMPDIFF` 拿到 NULL
 * 把整列变成 NULL（排序与时长会一起坏掉）。
 */
const CS_WAITING_SINCE_SQL = `COALESCE(fm.created_at, c.created_at)`;

/** 聊天服务（docs/07）：会话/客服授权/订单群/消息发送（事务 seq + clientMsgId 幂等）/已读/撤回/同步/限流 */
@Injectable()
export class ChatService {
  private readonly logger = new Logger('Chat');

  constructor(
    @InjectRepository(ChatConversation) private readonly convRepo: Repository<ChatConversation>,
    @InjectRepository(ChatConversationAssign) private readonly assignRepo: Repository<ChatConversationAssign>,
    @InjectRepository(ChatConversationMember) private readonly memberRepo: Repository<ChatConversationMember>,
    @InjectRepository(ChatMessage) private readonly msgRepo: Repository<ChatMessage>,
    private readonly realtime: RealtimeGateway,
    private readonly settings: SystemSettingService,
    @Inject(REDIS_CLIENT) private readonly redis: Redis,
  ) {}

  // ---------------- 权限校验（docs/07：join 前服务端强制校验） ----------------

  /** 用户：会话属主或对端（好友私聊与打手直聊都是双人会话，均按此校验） */
  async assertUserMember(conversationId: string, userId: string): Promise<ChatConversation> {
    const conv = await this.convRepo.findOne({ where: { id: conversationId } });
    if (!conv) throw new NotFoundException('会话不存在');
    const isMember =
      String(conv.userId) === String(userId) ||
      ((conv.type === 'friend' || conv.type === 'worker') && String(conv.peerUserId) === String(userId));
    if (!isMember) throw new NotFoundException('会话不存在');
    return conv;
  }

  /** 客服：实时查库 can_serve_customer=1 且存在 active 授权（docs/04 铁律）；好友/打手直聊=双成员校验（工作端可发消息） */
  async assertWorkerCs(conversationId: string, workerUserId: string): Promise<ChatConversation> {
    const conv = await this.convRepo.findOne({ where: { id: conversationId } });
    if (!conv) throw new NotFoundException('会话不存在');
    // 工作端账号与老板的单聊（worker 角色也是 user 表成员，无需客服授权）
    if ((conv.type === 'friend' || conv.type === 'worker') &&
      (String(conv.userId) === String(workerUserId) || String(conv.peerUserId) === String(workerUserId))) {
      return conv;
    }
    await this.workerOf(workerUserId);
    const assign = await this.assignRepo.findOne({ where: { conversationId, workerUserId, status: 'active' } });
    if (!assign) throw new ForbiddenException('无该会话客服授权');
    return conv;
  }

  // ---------------- 打手直聊（负责人 2026-10-04：群组功能全部下掉，改为一对一） ----------------

  /**
   * 确保「老板 ↔ 打手」一对一单个会话存在（抢单/派单成功事务内调用）。
   *
   * 群组功能已按要求全部下掉，不再建订单群、不写成员表、不拉管理员：
   * - 会话类型 `worker`，属主 = 老板，对端 = 打手，走与好友会话完全相同的读写/未读机制
   * - 一对一同两人复用同一会话（重新分配打手 = 与新打手另开会话，旧会话保留历史）
   * - 并发安全：先查后插，`UQ_conv_peer` 类唯一约束冲突时回查复用
   */
  async ensureWorkerDirectTx(
    em: EntityManager,
    bossUserId: string,
    workerUserId: string,
  ): Promise<ChatConversation> {
    const convRepo = em.getRepository(ChatConversation);
    const existing = await convRepo.findOne({
      where: [
        { type: 'worker', userId: bossUserId, peerUserId: workerUserId },
        { type: 'worker', userId: workerUserId, peerUserId: bossUserId },
      ],
    });
    if (existing) return existing;
    try {
      return await convRepo.save(
        convRepo.create({
          type: 'worker',
          userId: bossUserId,
          peerUserId: workerUserId,
          status: 'open',
        }),
      );
    } catch (e) {
      const err = e as { driverError?: { code?: string } };
      if (err.driverError?.code === 'ER_DUP_ENTRY') {
        const again = await convRepo.findOne({
          where: [
            { type: 'worker', userId: bossUserId, peerUserId: workerUserId },
            { type: 'worker', userId: workerUserId, peerUserId: bossUserId },
          ],
        });
        if (again) return again;
      }
      throw e;
    }
  }

  /**
   * 同一对 (老板, 打手) 是否还有**其它**未完成订单在用这个直聊会话。
   *
   * 唯一判据（完成 / 取消 / 售后驳回还原三条收尾路径共用，避免 SQL 双份漂移）：
   * `status NOT IN ('completed','canceled')` = 未完成（待接单/待派单/已接单/进行中/待确认/异常/售后中）。
   * 调用方给出的 `excludeOrderId` = 本次正在收尾的那一单（它自己不算「其它」）。
   */
  async countUnfinishedOrdersTx(
    em: EntityManager,
    bossUserId: string,
    workerUserId: string,
    excludeOrderId?: string,
  ): Promise<number> {
    const rows: Array<{ n: number | string }> = await em.query(
      `SELECT COUNT(*) AS n FROM \`order\` o JOIN worker w ON w.id = o.worker_id
       WHERE o.user_id = ? AND w.user_id = ? AND o.status NOT IN ('completed','canceled')
         AND (? IS NULL OR o.id <> ?)`,
      [bossUserId, workerUserId, excludeOrderId ?? null, excludeOrderId ?? null],
    );
    return Number(rows?.[0]?.n ?? 0);
  }

  /**
   * 订单**结束**（完成结算 / 取消 / 售后驳回还原）后收尾「老板 ↔ 打手」直聊会话。
   *
   * 负责人 2026-10-04 **方案①** 定案：同一对老板/打手的直聊会话是**多单共用**的，
   * 只要还有未完成订单在用，会话就必须**保持 `open`**：
   * - 还有**其它未完成订单** → **原样保留、什么都不做**（不置 closed、不删数据、不推 chat:closed）。
   *   旧语义把会话置 closed，会让 `sendMessage` 抛「会话已关闭」、客户端输入栏
   *   `composerEnabled: !_closed` 直接置灰 → 另一单还在服务期间双方发不出消息（本次修复的 bug）。
   * - 没有其它未完成订单（**最后一单也结束**）→ **物理删除**：消息（chat_message）
   *   + 成员/未读状态（chat_conversation_member）+ 客服指派（chat_conversation_assign）
   *   + 会话行（chat_conversation）全部清理，两端 `GET /user/conversations` /
   *   `GET /worker/cs/conversations` 立即不再返回该会话。
   * - 返回值交给调用方：删除 → 事务提交后推 `conv:removed`；保留（`kept=true`）→ **不推任何会话事件**。
   *
   * 注：`chat_conversation.user_read_seq / peer_read_seq` 即「已读位点」，仅随会话行删除；
   *     其它会话的已读位点与系统消息（`appendSystemMessageTx`）能力不受影响。
   */
  async settleWorkerDirectTx(
    em: EntityManager,
    bossUserId: string,
    workerUserId: string,
    excludeOrderId?: string,
  ): Promise<{ conversationId: string; removed: boolean; closed: boolean; kept: boolean } | null> {
    const convRepo = em.getRepository(ChatConversation);
    const conv = await convRepo.findOne({
      where: [
        { type: 'worker', userId: bossUserId, peerUserId: workerUserId },
        { type: 'worker', userId: workerUserId, peerUserId: bossUserId },
      ],
    });
    if (!conv) return null;

    const pending = await this.countUnfinishedOrdersTx(em, bossUserId, workerUserId, excludeOrderId);
    if (pending > 0) {
      // 方案①：会话共用中 → 保持 open 原样不动（消息可继续发；调用方不推会话事件）
      return { conversationId: String(conv.id), removed: false, closed: false, kept: true };
    }

    // 结束并删除：按依赖顺序物理清理（这些表无外键约束，顺序仅为语义清晰）
    await em.query('DELETE FROM chat_message WHERE conversation_id = ?', [conv.id]);
    await em.query('DELETE FROM chat_conversation_member WHERE conversation_id = ?', [conv.id]);
    await em.query('DELETE FROM chat_conversation_assign WHERE conversation_id = ?', [conv.id]);
    await em.query('DELETE FROM chat_conversation WHERE id = ?', [conv.id]);
    return { conversationId: String(conv.id), removed: true, closed: true, kept: false };
  }

  /**
   * 订单关联会话信息（管理端订单详情展示）。
   *
   * 群组功能已于 2026-10-04 全部下掉：订单不再建群，老板与打手是一对一直聊（type=worker）。
   * 管理端订单详情改为展示「该订单老板与该打手的直聊会话」，无则返回 null。
   */
  async directInfoByOrder(orderId: string) {
    const order = await this.convRepo.manager.query(
      `SELECT o.user_id, w.user_id AS worker_user_id
       FROM \`order\` o LEFT JOIN worker w ON w.id = o.worker_id WHERE o.id = ? LIMIT 1`,
      [orderId],
    );
    const row = order?.[0] as { user_id: string | null; worker_user_id: string | null } | undefined;
    if (!row?.user_id || !row?.worker_user_id) return null;
    const conv = await this.convRepo.findOne({
      where: [
        { type: 'worker', userId: String(row.user_id), peerUserId: String(row.worker_user_id) },
        { type: 'worker', userId: String(row.worker_user_id), peerUserId: String(row.user_id) },
      ],
    });
    if (!conv) return null;
    const userRepo = this.convRepo.manager.getRepository(User);
    const [boss, worker] = await Promise.all([
      userRepo.findOne({ where: { id: String(row.user_id) } }),
      userRepo.findOne({ where: { id: String(row.worker_user_id) } }),
    ]);
    return {
      conversationId: conv.id,
      name: `${boss?.nickname ?? '老板'} ↔ ${worker?.nickname ?? '打手'}`,
      createdAt: conv.createdAt,
      members: [
        { userId: String(row.user_id), role: 'boss', nickname: boss?.nickname ?? '', uid: boss?.uid ?? '', unread: Number(conv.unreadUser) },
        { userId: String(row.worker_user_id), role: 'worker', nickname: worker?.nickname ?? '', uid: worker?.uid ?? '', unread: Number(conv.unreadPeer) },
      ],
    };
  }

  private async workerOf(workerUserId: string): Promise<Worker> {
    const worker = await this.assignRepo.manager.findOne(Worker, { where: { userId: workerUserId, status: 1 } });
    if (!worker || worker.canServeCustomer !== 1) {
      throw new ForbiddenException('无客服权限');
    }
    return worker;
  }

  // ---------------- 会话 ----------------

  /** 用户客服会话（需求 #7）：取最近一条未结束会话；无则自动创建新会话（结束后再咨询 = 新会话） */
  async getUserConversation(userId: string) {
    let conv = await this.convRepo.findOne({
      where: { userId, type: 'cs', status: 'open' },
      order: { id: 'DESC' },
    });
    if (!conv) {
      conv = await this.convRepo.save(this.convRepo.create({ userId, type: 'cs' }));
      /**
       * **新会话建立的实时提示（负责人 2026-10-08）**：会话是在这一刻创建的。
       *
       * ⚠️ **池子口径当晚已收窄**（`CS_POOL_SQL`：老板至少发过一条消息才进池）—— 所以"建了会话"
       * **不等于**"进池"：这条 `cs:new{reason:'created'}` 只是"有老板打开了客服页"的提示，
       * 在线客服收到后刷新大厅，**此刻列表里不会出现该会话**；真正让它出现在池子里的是老板的
       * 首条消息（`sendMessage` 里那条 `cs:new{reason:'first-message'}`，全程只此一次）。
       *
       * 触发时机按任务口径**不改**（保留 `created` + `first-message` 两个 reason，客户端一律当刷新信号），
       * 语义差别靠 `reason` 字段表达（docs/07 的 reason 三值表未变）。
       * `void` 不 await：广播失败/变慢都不该拖住老板打开客服页这条高频路径。
       * 幂等：只有"本次真的新建了会话"才走到这里（已存在直接返回，不重复广播）。
       */
      void this.announceCsNew(conv.id, 'created', userId);
    }
    const assign = await this.assignRepo.findOne({ where: { conversationId: conv.id, status: 'active' } });
    return {
      id: conv.id,
      unread: conv.unreadUser,
      lastSeq: Number(conv.lastSeq),
      assigned: !!assign,
      status: conv.status,
      closedAt: conv.closedAt,
      closedBy: conv.closedBy,
    };
  }

  /** 会话状态信息（聊天详情页用；含成员校验 + 真实客服工号 + 对端已读位点） */
  async conversationInfo(actor: ChatActor, conversationId: string) {
    const conv =
      actor.type === 'user'
        ? await this.assertUserMember(conversationId, actor.userId)
        : await this.assertWorkerCs(conversationId, actor.userId);
    // 客服工号（2026-10-04）：取该会话 active 指派客服的真实 worker_no；无指派 → 空串
    // （客户端据此显示「人工客服」而不再按会话 id 编造 CS-xx）
    const assign = await this.assignRepo.findOne({ where: { conversationId: conv.id, status: 'active' } });
    let staffNo = '';
    if (assign) {
      const staff = await this.assignRepo.manager.findOne(Worker, { where: { userId: assign.workerUserId } });
      staffNo = staff?.workerNo ?? '';
    }
    return {
      id: conv.id,
      type: conv.type,
      status: conv.status,
      closedAt: conv.closedAt,
      closedBy: conv.closedBy,
      // 真实客服工号（无指派为空串）
      staffNo,
      // 已读位点：对端读到第几条（单勾/双勾的服务端权威来源）+ 我方位点 + 会话最新 seq
      peerReadSeq: Number(conv[this.peerReadFieldOf(conv, actor)] ?? 0),
      myReadSeq: Number(conv[this.readerReadFieldOf(conv, actor)] ?? 0),
      lastSeq: Number(conv.lastSeq),
    };
  }

  /** 读者自己的已读位点字段（markRead 时更新） */
  private readerReadFieldOf(conv: ChatConversation, actor: ChatActor): 'userReadSeq' | 'peerReadSeq' | 'workerReadSeq' {
    if (conv.type === 'cs') return actor.type === 'worker' ? 'workerReadSeq' : 'userReadSeq';
    return String(conv.userId) === String(actor.userId) ? 'userReadSeq' : 'peerReadSeq';
  }

  /** 对端（会话内另一方）的已读位点字段（读取给别人看） */
  private peerReadFieldOf(conv: ChatConversation, actor: ChatActor): 'userReadSeq' | 'peerReadSeq' | 'workerReadSeq' {
    if (conv.type === 'cs') return actor.type === 'worker' ? 'userReadSeq' : 'workerReadSeq';
    return String(conv.userId) === String(actor.userId) ? 'peerReadSeq' : 'userReadSeq';
  }

  /**
   * 老板点击"本次咨询已完成"（需求 #7）：结束当前 CS 会话，保留历史；再咨询自动开新会话。
   *
   * 【2026-10-11 真机报障修复②：打手态的「结束咨询」原来关错了会话】
   * 打手态聊天页复用老板端 `ChatDetailPage`（`openWorkerChat` 不传 sendPath），页面上的
   * 「结束咨询」打的就是本接口、**请求体不带 conversationId**（`data: {}`）。而本方法只按
   * `user_id = 我 AND status = 'open'` 找 —— 对正在服务某位老板的客服来说，那找到的是
   * **他自己那条「联系客服」的会话**（通常根本不存在 → 404「没有进行中的客服会话」），
   * 于被服务的那条咨询**仍然挂着他的红点**（负责人真机：「都结束咨询了为啥还会显示那个会话还有红点」）。
   *
   * 修法（**严格增量、绝不猜**）：老语义先走 —— 我有自己的进行中客服会话就结束它；
   * 只有"我一条自己的都没有"且**恰好服务着一条进行中的咨询**时，才结束那一条（此前这里是 404）。
   * 服务着 2 条以上时**不做任何猜测**，仍旧 404（宁可不动作，也不能替客服随便关掉别人的咨询）——
   * 那种情况下要精确关闭必须由客户端带上 `conversationId` 走 `/worker/cs/conversations/:id/close`，
   * 属老板端待发版的改动（见开发日志的"待发版"一节）。
   */
  async closeByUser(userId: string, sessionRole = 'user') {
    let conv = await this.convRepo.findOne({
      where: { userId, type: 'cs', status: 'open' },
      order: { id: 'DESC' },
    });
    if (!conv && String(sessionRole) === 'worker') conv = await this.singleAssignedOpenCsOf(userId);
    if (!conv) throw new NotFoundException('没有进行中的客服会话');
    conv.status = 'closed';
    conv.closedAt = new Date();
    conv.closedBy = 'user';
    // 已结束 = 未读归零（两侧一起清）：列表不再显示它，总未读也不该再挂着这一笔
    conv.unreadUser = 0;
    conv.unreadWorker = 0;
    await this.convRepo.save(conv);
    const assign = await this.assignRepo.findOne({ where: { conversationId: conv.id, status: 'active' } });
    if (assign) this.realtime.emitToUser(assign.workerUserId, 'chat:closed', { conversationId: conv.id, by: 'user' });
    this.realtime.emitToAdmins('chat:activity', { conversationId: conv.id });
    return { ok: true, conversationId: conv.id };
  }

  /**
   * 我（客服）**恰好服务着一条**进行中的咨询 → 返回它；0 条或 ≥2 条一律 null。
   *
   * 只服务 `closeByUser` 的兼容分支（打手态结束咨询不带 id），**不做任何猜测**：
   * 两条以上时"关哪条"必须由调用方给出 conversationId。
   */
  private async singleAssignedOpenCsOf(workerUserId: string): Promise<ChatConversation | null> {
    const rows: Array<{ id: string }> = await this.convRepo.manager.query(
      `SELECT c.id FROM chat_conversation c
        JOIN chat_conversation_assign a ON a.conversation_id = c.id AND a.status = 'active'
       WHERE a.worker_user_id = ? AND c.type = 'cs' AND c.status = 'open'
       ORDER BY c.updated_at DESC LIMIT 2`,
      [workerUserId],
    );
    if (rows.length !== 1) return null;
    return this.convRepo.findOne({ where: { id: String(rows[0].id) } });
  }

  /** 客服点击"结束本次咨询"（需求 #7） */
  async closeByWorker(workerUserId: string, conversationId: string) {
    const conv = await this.assertWorkerCs(conversationId, workerUserId);
    // 守卫（2026-10-04）：assertWorkerCs 会放行 friend/worker 类型，但「结束会话」只允许客服会话，
    // 否则工作端可经接口把老板↔打手直聊会话置 closed，导致双方发不出消息（UI 不暴露该按钮，属接口层漏洞）
    if (conv.type !== 'cs') throw new BadRequestException('仅客服会话可结束');
    if (conv.status !== 'open') throw new BadRequestException('会话已结束');
    conv.status = 'closed';
    conv.closedAt = new Date();
    conv.closedBy = 'worker';
    // 已结束 = 未读归零（两侧一起清；与 closeByUser 同一口径）：
    // 修复前实测（scripts/tmp/cs-closed-e2e.js 证据）：客服结束咨询后 `unread_worker` 仍是 4、
    // 会话仍留在两端列表 → 真机表现就是"都结束了还挂着红点"
    conv.unreadUser = 0;
    conv.unreadWorker = 0;
    await this.convRepo.save(conv);
    this.realtime.emitToUser(conv.userId, 'chat:closed', { conversationId: conv.id, by: 'worker' });
    return { ok: true, conversationId: conv.id };
  }

  /** 好友会话（共享单行：属主=较小 id；唯一约束兜底并发创建） */
  async getOrCreateFriendConversation(userA: string, userB: string): Promise<ChatConversation> {
    const owner = BigInt(userA) < BigInt(userB) ? String(userA) : String(userB);
    const peer = BigInt(userA) < BigInt(userB) ? String(userB) : String(userA);
    let conv = await this.convRepo.findOne({ where: { type: 'friend', userId: owner, peerUserId: peer } });
    if (conv) return conv;
    try {
      conv = await this.convRepo.save(this.convRepo.create({ type: 'friend', userId: owner, peerUserId: peer }));
      return conv;
    } catch (e) {
      const err = e as { driverError?: { code?: string } };
      if (err.driverError?.code === 'ER_DUP_ENTRY') {
        const existing = await this.convRepo.findOne({ where: { type: 'friend', userId: owner, peerUserId: peer } });
        if (existing) return existing;
      }
      throw e;
    }
  }

  /**
   * 用户侧会话列表（CS + 好友 + 打手直聊；含对方资料/最后一条消息/我的未读）。
   *
   * 【2026-10-11 真机报障修复】**已结束的客服会话不再进列表**（`c.status = 'open'`）：
   * 结束咨询只是把会话置 `closed`（`closeByUser` / `closeByWorker` 保留历史，一行不删），
   * 而原查询只按 `c.user_id = ? AND c.type = 'cs'` 取行 —— 于是**每一次历史咨询都会在消息页
   * 客服段常驻一行**（真机截图：三行一模一样的「祁连山客服」，点进去还是"已结束"）。
   *
   * 口径（负责人 2026-10-11 原话「这个结束之后就不显示了」）：
   * - 已结束 → **不出现在任何会话列表**（老板侧这里 / 客服侧 `workerConversations` 同一口径）；
   * - 历史**不删**：按 id 直接打开仍可读（`assertUserMember` / `assertWorkerCs` 都不看 status），
   *   所以不存在"列表里有、点开 404"的自相矛盾；
   * - 未读：已结束的会话在 `close*` 里两侧清零，且下面的未读快照（WS `unread:snapshot`）同样排除它
   *   → 列表未读合计与总未读一致。
   */
  async listUserConversations(userId: string) {
    const rows: Array<{
      id: string; type: string; user_id: string; peer_user_id: string | null; order_id: string | null; name: string | null;
      unread_user: number; unread_worker: number; unread_peer: number; member_unread: number | null; last_seq: string; updated_at: Date;
      status: string; closed_at: Date | null; closed_by: string | null;
      peer_nickname: string | null; peer_uid: string | null; peer_avatar: string | null;
    }> = await this.convRepo.manager.query(
      `SELECT c.id, c.type, c.user_id, c.peer_user_id, c.order_id, c.name, c.unread_user, c.unread_worker, c.unread_peer, c.last_seq, c.updated_at,
              c.status, c.closed_at, c.closed_by,
              u.nickname AS peer_nickname, u.uid AS peer_uid, u.avatar_media_id AS peer_avatar,
              NULL AS member_unread
       FROM chat_conversation c
       LEFT JOIN user u ON u.id = c.peer_user_id
       WHERE (c.user_id = ? AND c.type = 'cs' AND c.status = 'open')
          OR (c.type = 'friend' AND (c.user_id = ? OR c.peer_user_id = ?))
          OR (c.type = 'worker' AND (c.user_id = ? OR c.peer_user_id = ?))
       ORDER BY c.updated_at DESC`,
      [userId, userId, userId, userId, userId],
    );
    if (!rows.length) return { list: [], total: 0 };
    const ids = rows.map((r) => r.id);
    const lastRows: Array<{ conversation_id: string; content: string; msg_type: string; sender_type: string; sender_id: string; recalled: number; created_at: Date }> =
      await this.convRepo.manager.query(
        `SELECT m.conversation_id, m.content, m.msg_type, m.sender_type, m.sender_id, m.recalled, m.created_at
         FROM chat_message m
         JOIN (SELECT conversation_id, MAX(seq) AS ms FROM chat_message WHERE conversation_id IN (?) GROUP BY conversation_id) t
           ON t.conversation_id = m.conversation_id AND t.ms = m.seq`,
        [ids],
      );
    const lastMap = new Map(lastRows.map((r) => [String(r.conversation_id), r]));
    return {
      list: rows.map((r) => {
        const last = lastMap.get(String(r.id));
        const isOwner = String(r.user_id) === String(userId);
        // cs：属主看 unread_user，客服看 unread_worker；好友/打手直聊：属主看 unread_user，对端看 unread_peer
        const unread = r.type === 'cs'
          ? (isOwner ? Number(r.unread_user) : Number(r.unread_worker))
          : (isOwner ? Number(r.unread_user) : Number(r.unread_peer));
        return {
          id: r.id,
          type: r.type,
          name: null,
          orderId: null,
          // 好友与打手直聊：都展示对方资料（打手直聊的对方即接单打手）
          peer: (r.type === 'friend' || r.type === 'worker') && r.peer_user_id
            ? {
                userId: String(r.peer_user_id) === String(userId) ? String(r.user_id) : String(r.peer_user_id),
                nickname: r.peer_nickname ?? '',
                uid: r.peer_uid ?? '',
                avatarMediaId: r.peer_avatar,
              }
            : null,
          unread,
          lastSeq: Number(r.last_seq),
          status: r.status,
          closedAt: r.closed_at,
          closedBy: r.closed_by,
          lastMessage: last
            ? {
                content: last.content,
                msgType: last.msg_type,
                senderType: last.sender_type,
                senderId: String(last.sender_id),
                recalled: Number(last.recalled) === 1,
                createdAt: last.created_at,
              }
            : null,
          updatedAt: r.updated_at,
        };
      }),
      total: rows.length,
    };
  }

  /**
   * 工作端会话列表：**我作为客服被指派的 CS 会话 ∪ 我自己作为发起方的 CS 会话** + 我的打手直聊 + 我的好友会话。
   *
   * 缺口 4（负责人 2026-10-06 裁决）：打手态「联系客服」走的是 `GET /user/conversation`，它建的是
   * **以打手账号为 user 侧**的 CS 会话（`chat_conversation.user_id = 打手账号`，没有指派客服）。
   * 原实现只返回「被指派的会话」，于是打手联系了客服却在客服段看不到这条会话、也永远看不到客服回复
   * （功能坏掉）。现在集合 = `被指派（a.id 非空） ∪ 该打手作为发起方（c.user_id = 我）`。
   *
   * 不泄漏别人的会话（硬约束）：两个条件都是**当事方**判定 —— 要么我是客服侧（有 active 指派），
   * 要么我是发起方（会话属主）。与该账号无关的第三条会话永远不会进这个列表（测试钉死）。
   *
   * 【2026-10-11 真机报障修复】**已结束的客服会话不再进这个列表**（`c.status = 'open'`，与
   * `listUserConversations` 同一口径）。真机证据（打手态 W0000）：客服段出现**三行一模一样**的
   * 「祁连山客服」—— 两条是自己发起、已被结束的历史咨询（0 消息、无预览无时间），
   * 第三条才是正在服务的会话；点开其中带红点的那条（被指派的进行中会话）又走的是
   * `/user/conversations/:id/*`，被 `assertUserMember` 判成非成员 → **404「会话不存在」**
   * （列表里有、点开没有 = 自相矛盾，已由 `resolveUserRouteActor` 一并修掉）。
   *
   * 注意：**不是**"客服看不到自己服务过的历史" —— 历史一行未删，按 id 打开仍可读（`assertWorkerCs`
   * 只看 active 指派，不看 status）；只是不再挂在会话列表里当红点来源。
   */
  async workerConversations(workerUserId: string) {
    const hasCs = await this.assignRepo.manager
      .findOne(Worker, { where: { userId: workerUserId, status: 1 } })
      .then((w) => !!w && w.canServeCustomer === 1)
      .catch(() => false);
    const rows: Array<{
      id: string; user_id: string; nickname: string; type: string;
      unread_user: number; unread_worker: number; unread_peer: number; last_seq: string; status: string; updated_at: Date;
    }> = await this.convRepo.manager.query(
      `SELECT c.id, c.user_id, u.nickname, c.type, c.unread_user, c.unread_worker, c.unread_peer, c.last_seq, c.status, c.updated_at
       FROM chat_conversation c
       LEFT JOIN user u ON u.id = c.user_id
       LEFT JOIN chat_conversation_assign a ON a.conversation_id = c.id AND a.status = 'active' AND a.worker_user_id = ?
       WHERE (c.type = 'cs' AND c.status = 'open' AND (a.id IS NOT NULL OR c.user_id = ?))
          OR (c.type = 'worker' AND c.peer_user_id = ?)
          OR (c.type = 'friend' AND (c.user_id = ? OR c.peer_user_id = ?))
       ORDER BY c.updated_at DESC`,
      [workerUserId, workerUserId, workerUserId, workerUserId, workerUserId],
    );
    return {
      hasCsPermission: hasCs,
      list: rows.map((r) => ({
        id: r.id,
        type: r.type,
        name: null,
        orderId: null,
        // CS 会话：我是发起方时昵称就是我自己的账号昵称（客户端客服段固定显示「祁连山客服」，不看这个字段）
        userNickname: r.nickname ?? '用户',
        // CS 会话未读分两侧（缺口 4 新增的"自发起"行必须按发起方口径取）：
        // - 我是发起方（user_id = 我）→ `unread_user`（客服回复我的未读）；
        // - 我是被指派的客服 → `unread_worker`（老板消息的客服侧未读）。
        // 打手直聊：属主是老板、工作端在对端位置 → `unread_peer`（既有口径逐字未变）。
        unread: r.type === 'cs'
          ? (String(r.user_id) === String(workerUserId) ? Number(r.unread_user) : Number(r.unread_worker))
          : Number(r.unread_peer),
        lastSeq: Number(r.last_seq),
        status: r.status,
        updatedAt: r.updated_at,
      })),
    };
  }

  /** 管理端会话列表（含指派状态） */
  async adminConversations(page: number, pageSize: number) {
    const rows: Array<{
      id: string; user_id: string; nickname: string; unread_user: number; unread_worker: number;
      status: string; cs_worker_user_id: string | null; updated_at: Date; type: string; peer_nickname: string | null;
    }> = await this.convRepo.manager.query(
      `SELECT c.id, c.user_id, u.nickname, c.unread_user, c.unread_worker, c.status,
              a.worker_user_id AS cs_worker_user_id, c.updated_at, c.type, pu.nickname AS peer_nickname
       FROM chat_conversation c
       LEFT JOIN user u ON u.id = c.user_id
       LEFT JOIN user pu ON pu.id = c.peer_user_id
       LEFT JOIN chat_conversation_assign a ON a.conversation_id = c.id AND a.status = 'active'
       ORDER BY c.updated_at DESC
       LIMIT ? OFFSET ?`,
      [pageSize, (page - 1) * pageSize],
    );
    // 注意：manager.query（TypeORM 0.3）直接返回 rows；dataSource.query 才是 [rows, fields]
    const countRows = (await this.convRepo.manager.query(`SELECT COUNT(*) AS cnt FROM chat_conversation`)) as Array<{ cnt: number | string }>;
    const cnt = Number(countRows[0]?.cnt ?? 0);
    return {
      list: rows.map((r) => ({
        id: r.id,
        userId: r.user_id,
        userNickname: r.nickname ?? '用户',
        unreadUser: Number(r.unread_user),
        unreadWorker: Number(r.unread_worker),
        status: r.status,
        csWorkerUserId: r.cs_worker_user_id,
        type: r.type,
        peerNickname: r.peer_nickname,
        updatedAt: r.updated_at,
      })),
      total: Number(cnt),
      page,
      pageSize,
    };
  }

  /**
   * 管理员指派客服（docs/07：改派后原客服被强制 leave 并推送提示）。
   *
   * ## 功能语义（**一字未改**）
   * 管理端仍可**强制改派**：把该会话现有的 active 指派置为 `inactive`，再插入新的一行 active；
   * 权限点（`admin:chat:assign`）、留痕（控制器写 `chat:assign`）、返回结构、路由全部不变。
   *
   * ## 并发安全（2026-10-08 晚补：与客服大厅 claim 的竞态）
   * **问题**：客服大厅的 [`claimCsConversation`] 是抢占式的，而本方法原先**不加行锁** ——
   * 两者同毫秒发生时，管理端读到的"没有 active 行"在读完之后被 claim 插了一行，
   * 管理端那次 INSERT 便撞上唯一键 `UK_cca_active` → `ER_DUP_ENTRY` 未被捕获 → 前端看到 **500**。
   *
   * **修法**（与 `claimCsConversation` / `sendMessage` 抢**同一张表的同一行**、同一写法）：
   * 1. **请求开始时的观测**：先读一次 active 指派（= 管理员在列表上看到、并据此点"改派"的状态）；
   * 2. 事务内 `SELECT ... FOR UPDATE` **锁会话行** → 与 claim 串行化（谁先拿锁谁先落库，另一边等）；
   * 3. 锁内**复核**（同样是 `FOR UPDATE` 读，确保读到的是最新已提交版本而不是本事务快照）：
   *    若"我操作开始时没有 active 指派、此刻却已经有了"（典型：等锁期间大厅有人抢先把会话接走）
   *    → **中文 409「该咨询已被其他客服接入」**，不再让唯一键把错误冒成 500；
   * 4. 复核通过 → 仍在**同一个事务**内完成"原 active 置 inactive + 插新 active"（要么全成、要么全回滚，
   *    不会留下两行 active、也不会留下半截改派）；唯一键冲突再兜一层 → 同样中文 409；
   * 5. 广播放在**事务提交之后**：原客服 `chat:unassigned`（被强制离开）+ 新客服 `chat:assigned`
   *    —— 可见效果与原先一致，但回滚后不会推出假事件。
   *
   * **为什么 409 只认"从无到有"这一种变化**，而不是"active 集合任何变化都 409"：
   * 强制改派是既有语义 —— 对一个**已经有客服在接**的会话改派必须照旧成功（否则"管理端兜底"就没了）。
   * 真正要拦的只有"我以为没人接、其实刚被人接走"这一种：管理端的改派意图建立在过期状态上，
   * 而抢先接入的客服已经拿到会话（`chat:assigned` 已推送、老板侧也已提示"客服 X 已接入"），
   * 再让管理端盖一次会造成"客服刚接到就被改走"。其余变化（原客服退回池子、另一个管理员改派）
   * 都不会撞唯一键，照旧按既有语义执行（`observedKey` 非空时直接走强制改派）。
   */
  async assignConversation(conversationId: string, workerUserId: string, assignedBy: string) {
    await this.workerOf(workerUserId);

    // ① 请求开始时的观测（= 管理员点"改派"那一刻的状态）：只取 worker 指纹，不含行 id
    const observedKey = this.activeAssignKey(
      await this.assignRepo.find({ where: { conversationId, status: 'active' } }),
    );

    const outcome = await this.convRepo.manager.transaction(async (em) => {
      // ② 行锁：SELECT ... FOR UPDATE（与 claimCsConversation / sendMessage 同一把锁、同一写法）
      const locked = await em.findOne(ChatConversation, {
        where: { id: conversationId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!locked) throw new NotFoundException('会话不存在');
      if (locked.type !== 'cs') throw new BadRequestException('仅客服会话可指派客服');

      // ③ 锁内复核（FOR UPDATE 读 = 最新已提交版本）：等锁期间"没人接"变成"有人接" → 中文 409
      const prev = await em.find(ChatConversationAssign, {
        where: { conversationId, status: 'active' },
        lock: { mode: 'pessimistic_write' },
      });
      if (observedKey === '' && this.activeAssignKey(prev) !== '') {
        throw new ConflictException('该咨询已被其他客服接入');
      }

      // ④ 强制改派（既有语义）：原 active 置 inactive → 插新 active，同一事务内完成
      for (const p of prev) {
        p.status = 'inactive';
        await em.save(p);
      }
      let assign: ChatConversationAssign;
      try {
        assign = await em.save(
          em.create(ChatConversationAssign, { conversationId, workerUserId, assignedBy, status: 'active' }),
        );
      } catch (e) {
        // 数据库层兜底（与 claim 同一取舍）：唯一键 UK_cca_active 说明有别的写入路径先插了 active 行
        if ((e as { driverError?: { code?: string } }).driverError?.code === 'ER_DUP_ENTRY') {
          throw new ConflictException('该咨询已被其他客服接入');
        }
        throw e;
      }
      return { assign, replaced: prev.map((p) => String(p.workerUserId)) };
    });

    // ⑤ 提交后再广播（回滚不会推出假事件；口径与既有行为一致：原客服被强制离开 → 收到 chat:unassigned）
    for (const uid of outcome.replaced) {
      this.realtime.emitToUser(uid, 'chat:unassigned', { conversationId });
    }
    this.realtime.emitToUser(workerUserId, 'chat:assigned', { conversationId });
    return outcome.assign;
  }

  /**
   * active 指派集合的稳定指纹（`assignConversation` 的锁内复核用）。
   * 只取 `worker_user_id` 并排序：**同一批人接同一个会话**（哪怕换了一行历史记录）不算"变了"，
   * 这样"原客服退回池子后又被自己重新接回"这类情形不会被误判成并发冲突。
   */
  private activeAssignKey(rows: ChatConversationAssign[]): string {
    return rows.map((r) => String(r.workerUserId)).sort().join(',');
  }

  // ---------------- 客服大厅（负责人 2026-10-08：有客服权限的打手主动接咨询） ----------------

  /**
   * 待接入列表（`GET /worker/cs/hall`）。
   *
   * ## 池子口径
   * `type='cs' AND status='open'`、**老板至少发过一条消息**、且无 active 指派 —— 唯一出处是模块级常量
   * [`CS_POOL_SQL`]（列表 / 总数 / 广播受众三处共用，禁止第二份 SQL）。
   *
   * ⚠️ **2026-10-08 晚修正**：进池前提从"会话存在"改为"**老板已经发过至少一条消息**"。
   * 老板打开客服页就会建会话（`getUserConversation` 一行未改），但"建了会话"不等于"有人申请客服" ——
   * 否则大厅里会出现 `（暂无消息）` 的空条目（客服点进去没人说话）。老板发第一条消息的那一刻，
   * 会话才真正进池（对应广播 `cs:new{reason:'first-message'}`，见 [sendMessage]）。
   *
   * ## 排序与等待时长
   * **等待最久的在前**（`ORDER BY 等待起点 ASC, id ASC`）。等待起点 = **首条老板咨询的发出时刻**
   * （`CS_WAITING_SINCE_SQL`）；`COALESCE` 到会话创建时刻的兜底只是防御，新口径下进池就必有消息。
   * 老板打开客服页就建了会话、过了 10 分钟才发第一条消息，用"创建时刻"会把等待时间算多，
   * 用"首条消息时刻"才是他真的在等的时间。两个时刻都由**数据库时钟**（`NOW()` / `TIMESTAMPDIFF`）
   * 计算，不掺应用进程时钟 —— 同一块表写的时间，比在 Node 里 `Date.now()` 减更不会漂。
   *
   * ## 敏感字段
   * 只回 `nickname` + `uid`（中文 ID）。**不回** `username`（那是登录名，客服不需要，回了等于把
   * 一列可爆破的账号名摊开给所有客服）、不回 `phone`、不回 `email`、不回任何钱包/订单信息。
   * 与 `workerConversations` 的既有口径一致（那里也只给 `nickname`）。
   *
   * ## 权限
   * **每请求实时查库**（`workerOf` → `worker.can_serve_customer=1 AND status=1`），无缓存；
   * 无客服权限 → **403 中文「无客服权限」**（不返回空列表：大厅是"持客服权限才能进的入口"，
   * 与接单大厅"无分部权限返回空列表"的取舍不同 —— 接单大厅是高频首屏、权限按分部细分，
   * 而客服入口本就只对持客服权限的账号显示。见 docs/03 的口径说明）。
   */
  async csHall(workerUserId: string, page: number, pageSize: number) {
    await this.workerOf(workerUserId);

    // 总数与列表**同源**：同一个 `CS_POOL_SQL` 内插在两处（这条 COUNT 与下面列表的 WHERE），
    // 下面返回的 `waitingTotal` 又直接取 `total` 这同一个变量 → 三者不可能口径漂移。
    const totalRows: Array<{ cnt: number | string }> = await this.convRepo.manager.query(
      `SELECT COUNT(*) AS cnt FROM chat_conversation c WHERE ${CS_POOL_SQL}`,
    );
    const total = Number(totalRows?.[0]?.cnt ?? 0);

    const rows: Array<{
      id: string; created_at: Date; first_at: Date | null; first_type: string | null; first_content: string | null;
      first_recalled: number | null; msg_count: number | string; nickname: string | null; user_uid: string | null;
      waited_seconds: number | string;
    }> = await this.convRepo.manager.query(
      `SELECT c.id, c.created_at, u.nickname, u.uid AS user_uid,
              fm.msg_type AS first_type, fm.content AS first_content, fm.recalled AS first_recalled,
              fm.created_at AS first_at,
              (SELECT COUNT(*) FROM chat_message m WHERE m.conversation_id = c.id) AS msg_count,
              TIMESTAMPDIFF(SECOND, ${CS_WAITING_SINCE_SQL}, NOW()) AS waited_seconds
         FROM chat_conversation c
         LEFT JOIN user u ON u.id = c.user_id
         LEFT JOIN chat_message fm ON fm.id = (
              SELECT m2.id FROM chat_message m2
               WHERE m2.conversation_id = c.id AND m2.sender_type = 'user'
               ORDER BY m2.seq ASC LIMIT 1)
        WHERE ${CS_POOL_SQL}
        ORDER BY ${CS_WAITING_SINCE_SQL} ASC, c.id ASC
        LIMIT ? OFFSET ?`,
      [pageSize, (page - 1) * pageSize],
    );

    const onlineCsUserIds = await this.onlineCsWorkerIds();
    return {
      list: rows.map((r) => {
        const waitedSeconds = Math.max(0, Number(r.waited_seconds ?? 0));
        return {
          conversationId: String(r.id),
          // 发起方（老板；也可能是打手态账号「联系客服」发起的会话）昵称 + 中文 ID
          userNickname: r.nickname ?? '用户',
          userUid: r.user_uid ?? '',
          preview: this.csPreviewOf(r.first_type, r.first_content, Number(r.first_recalled) === 1),
          msgCount: Number(r.msg_count ?? 0),
          waitedSeconds,
          waitedText: this.humanWait(waitedSeconds),
          // 等待起点（= 排序依据）+ 会话创建时刻，客户端可原样展示。
          // 新口径下 `first_at` 必然存在（进池就要求有老板消息），`?? r.created_at` 只是防御兜底
          waitingSince: r.first_at ?? r.created_at,
          createdAt: r.created_at,
        };
      }),
      total,
      page,
      pageSize,
      /** 与 `total` 同值：显式给一个"待接入总数"的名字，客户端顶部可直接显示"当前 N 人等待" */
      waitingTotal: total,
      /** 当前有客服权限且在线的打手数（口径见 [onlineCsWorkerIds]） */
      onlineCsCount: onlineCsUserIds.length,
    };
  }

  /**
   * 主动接入（`POST /worker/cs/hall/:conversationId/claim`）—— **抢占式，谁先点谁得**。
   *
   * ## 并发安全（项目铁律：条件写判 affectedRows，禁 Redis 锁双源）
   * 1. **客服权限实时查库**（`workerOf`，无缓存）→ 403 中文；
   * 2. 事务内 `SELECT ... FOR UPDATE` **锁会话行**（与 `sendMessage` 抢的是同一张表的同一行）
   *    → 所有 claim 在这里串行化，第二个请求必然在第一个提交**之后**才读到 active 行；
   * 3. 锁内**复核**「仍是 `cs` + `open` + 无 active 指派」——复核结果就是最终判定；
   * 4. **条件写 + affectedRows 判结果**：`INSERT ... status='active'` 的 `affectedRows` 必须是 1，
   *    否则（0 行）一律 409 中文，**绝不静默成功**。数据来源只有这张表，没有第二把锁、没有 Redis。
   * 5. **数据库层兜底**：唯一键 `UK_cca_active`（生成列 `active_conversation_id`）保证"同一会话最多一行 active"，
   *    即使将来有人绕过行锁（管理端改派、运维 SQL、新写的接口）也插不进第二行 →
   *    捕获 `ER_DUP_ENTRY` 后同样回**中文 409**（而不是把 SQL 错误原样抛成 500）。
   *
   * ## 幂等
   * 自己已经接过（active 行就是自己）→ 直接返回 `alreadyClaimed: true`，不报错、不产生第二行
   * —— 客户端重复点/网络重发不会看到红字。
   *
   * ## 存在性口径（安全审计 F3 的既有教训）
   * 「会话不存在」与「存在但不是客服会话」一律 **404「会话不存在」**（不向客服泄漏平台上还有哪些
   * 别的类型的会话）；「已结束」→ 400 中文。管理端 assign 的既有文案与状态码**未改**。
   *
   * ## 留痕
   * 真正写入的那一次由控制器写 `operation_log`（`module='chat'`、`action='chat:claim'`，
   * 与 `admin/chat` 的 `chat:assign` **同一张表、同一套字段**）—— 一个会话的接入史
   * （管理员改派 + 客服自主接入 + 退回池子）永远能在同一处回看。
   */
  async claimCsConversation(workerUserId: string, conversationId: string) {
    const worker = await this.workerOf(workerUserId);

    const outcome = await this.convRepo.manager.transaction(async (em) => {
      // ② 行锁：SELECT ... FOR UPDATE（事务内；与 sendMessage 同一把锁 → 并发 claim 串行化）
      const locked = await em.findOne(ChatConversation, {
        where: { id: conversationId },
        lock: { mode: 'pessimistic_write' },
      });
      if (!locked || locked.type !== 'cs') throw new NotFoundException('会话不存在');
      if (locked.status !== 'open') throw new BadRequestException('该咨询已结束，无法接入');

      // ③ 锁内复核：此刻读到的 active 行不可能再被别的 claim 插入（插入方必须先拿同一把行锁）
      const active = await em.find(ChatConversationAssign, { where: { conversationId, status: 'active' } });
      const mine = active.find((a) => String(a.workerUserId) === String(workerUserId));
      if (mine) return { alreadyClaimed: true };
      if (active.length > 0) throw new ConflictException('该咨询已被其他客服接入');

      // ④ 条件写：affectedRows 是"接入成功"的唯一判据
      let affected = 0;
      try {
        const res: { affectedRows?: number } = await em.query(
          `INSERT INTO chat_conversation_assign (conversation_id, worker_user_id, status, assigned_by)
           VALUES (?, ?, 'active', ?)`,
          [conversationId, workerUserId, workerUserId],
        );
        affected = Number(res?.affectedRows ?? 0);
      } catch (e) {
        // 唯一键 UK_cca_active：有别的写入路径先插了 active 行（绕过行锁）→ 同样是"已被接入"
        if ((e as { driverError?: { code?: string } }).driverError?.code === 'ER_DUP_ENTRY') {
          throw new ConflictException('该咨询已被其他客服接入');
        }
        throw e;
      }
      if (affected !== 1) throw new ConflictException('该咨询已被其他客服接入');
      return { alreadyClaimed: false };
    });

    const nickname = (await this.nicknamesOf([workerUserId])).get(String(workerUserId)) ?? '';
    const payload = {
      conversationId: String(conversationId),
      workerUserId: String(workerUserId),
      workerNickname: nickname,
      workerNo: worker.workerNo,
    };
    // ① 抢到的人：沿用既有事件名 chat:assigned（打手态消息页已监听 → 自动刷新会话列表）
    this.realtime.emitToUser(workerUserId, 'chat:assigned', payload);
    if (!outcome.alreadyClaimed) {
      // ② 大厅其他人：该条从列表移除。载荷字段名按需求口径 `{conversationId, byNickname}` 命名
      //    （`by*` = "被谁接走了"，与 ①/③ 的 `worker*` = "接他的人是谁" 区分：一个给大厅，一个给当事人）
      void this.emitToOnlineCs(
        'cs:claimed',
        {
          conversationId: String(conversationId),
          byUserId: String(workerUserId),
          byNickname: nickname,
          byWorkerNo: worker.workerNo,
        },
        workerUserId,
      );
      // ③ 老板侧：同一个 chat:assigned 事件（载荷含客服昵称/工号，老板端据此显示「客服 X 已接入」）
      const conv = await this.convRepo.findOne({ where: { id: conversationId } });
      if (conv) this.realtime.emitToUser(conv.userId, 'chat:assigned', payload);
    }
    return {
      ok: true,
      conversationId: String(conversationId),
      alreadyClaimed: outcome.alreadyClaimed,
      workerUserId: String(workerUserId),
      workerNo: worker.workerNo,
    };
  }

  /**
   * 退回池子（`POST /worker/cs/hall/:conversationId/release`）—— **负责人尚未定案，由开关控制开放**。
   *
   * 语义：把自己的那行 active 指派置为 `released`（**历史保留**，不删除）→ 会话重新进入待接入池
   * → 大厅里其他人重新看到它。
   *
   * 判定同样是**条件写判 affectedRows**（`WHERE ... AND worker_user_id = ? AND status='active'`）：
   * - 改到 1 行 = 退回成功（通知三方）；
   * - 0 行分两种：我已经退回过（历史行 `released` 存在）→ **幂等成功**；
   *   其余（没接过 / 是别人在接 / 会话已结束）→ 中文 400。
   *
   * 开关：`system_setting.cs_hall_release_enabled`（默认 1=开放，`{"value":0}`=关闭 → 403 中文）。
   * 读侧实时读库、无缓存 → 关掉下一次请求立刻生效。要彻底删除见 `cs-hall.ts` 顶部说明。
   */
  async releaseCsConversation(workerUserId: string, conversationId: string) {
    await this.workerOf(workerUserId);
    const enabled = await this.settings.value(CS_HALL_RELEASE_KEY, CS_HALL_RELEASE_DEFAULT);
    if (enabled === CS_HALL_RELEASE_DISABLED_VALUE) {
      throw new ForbiddenException('客服退回功能未开放');
    }

    const conv = await this.convRepo.findOne({ where: { id: conversationId } });
    if (!conv || conv.type !== 'cs') throw new NotFoundException('会话不存在');
    if (conv.status !== 'open') throw new BadRequestException('该咨询已结束，无需退回');

    const res: { affectedRows?: number } = await this.convRepo.manager.query(
      `UPDATE chat_conversation_assign SET status = 'released'
        WHERE conversation_id = ? AND worker_user_id = ? AND status = 'active'`,
      [conversationId, workerUserId],
    );
    if (Number(res?.affectedRows ?? 0) !== 1) {
      const released = await this.assignRepo.findOne({
        where: { conversationId, workerUserId: String(workerUserId), status: 'released' },
      });
      if (released) return { ok: true, conversationId: String(conversationId), alreadyReleased: true };
      throw new BadRequestException('你不是该咨询的接入客服，无法退回');
    }

    // 通知三方：本人（沿用 chat:unassigned，打手态已监听）、老板、大厅其他人（cs:new → 重新出现）
    this.realtime.emitToUser(workerUserId, 'chat:unassigned', { conversationId: String(conversationId), by: 'worker' });
    this.realtime.emitToUser(conv.userId, 'chat:unassigned', { conversationId: String(conversationId), by: 'worker' });
    void this.announceCsNew(conversationId, 'released');
    return { ok: true, conversationId: String(conversationId), alreadyReleased: false };
  }

  /**
   * 「当前有客服权限且在线」的打手 user id —— **客服权限 + 在线判定的唯一出处**
   * （`csHall` 的 `onlineCsCount` 与大厅广播共用，禁止第二份判定）。
   *
   * 口径与依据：
   * - **有客服权限**：`worker.status = 1 AND worker.can_serve_customer = 1`（实时查库，无缓存；
   *   与 `workerOf` / `assertWorkerCs` 同一张表同一判据）；
   * - **在线**：沿用**既有机制** `RealtimeGateway.isOnline(userId)` —— 即 `/ws/chat` 命名空间里
   *   `uid:{userId}` 房间存在连接（好友列表的在线状态用的就是它）。**没有**另造心跳表、
   *   也没有"近 N 分钟活跃"这类新口径：项目里唯一的"在线"就是"此刻 WS 连着"，
   *   socket.io 的 `pingInterval 25s / pingTimeout 20s` 负责把死连接摘掉，
   *   所以"在线"最坏情况滞后约 45s，与好友在线状态的既有精度完全一致。
   *
   * 为什么不用 Redis/DB 记在线：那是**第二套在线判定**，与 WS 真实连接状态必然漂移
   * （进程重启、多实例、连接抖动），而本方法一次遍历只是内存 Map 查询（打手规模下可忽略）。
   */
  private async onlineCsWorkerIds(): Promise<string[]> {
    const workers = await this.assignRepo.manager.find(Worker, {
      where: { status: 1, canServeCustomer: 1 },
      select: ['userId'],
    });
    return workers.map((w) => String(w.userId)).filter((uid) => this.realtime.isOnline(uid));
  }

  /**
   * 把大厅事件推给「有客服权限且在线」的打手（可排除某个 user id）。
   *
   * **复用既有网关机制**：逐人 `RealtimeGateway.emitToUser`（推 `uid:{id}` 房间）——
   * 与派单通知/未读推送同一条通道，不新建房间、不新建广播通道、不引入第二套 WS。
   * 用"逐人推"而不是 `emitToAll`：后者会把"平台上有人申请客服"这一事实推给**所有**在线连接
   * （包括老板端），是没必要的面；而客服名单本来就要查（`onlineCsCount` 同一次结果）。
   *
   * 失败只告警不抛出：广播失败不该让"接咨询"这件事失败（与全站"推送尽力而为、状态以库为准"一致）。
   */
  private async emitToOnlineCs(event: string, payload: unknown, excludeUserId?: string): Promise<void> {
    try {
      const uids = await this.onlineCsWorkerIds();
      for (const uid of uids) {
        if (excludeUserId && uid === String(excludeUserId)) continue;
        this.realtime.emitToUser(uid, event, payload);
      }
    } catch (e) {
      this.logger.warn(`${event} 广播失败: ${(e as Error).message}`);
    }
  }

  /**
   * 大厅刷新广播（`cs:new`）：**老板新建客服会话**（`created`）/ **老板首次发消息**（`first-message`，
   * = 真正进池的那一刻）/ **客服退回池子**（`released`）时触发，让在线客服的大厅列表自动刷新（不必轮询）。
   *
   * ⚠️ `reason` 只表达"为什么刷新"，**不表达"池子里一定有它"**：`created` 那次会话还没进池
   * （池子要求老板至少发过一条消息，见 [`CS_POOL_SQL`]），客户端刷新后列表不会有变化 —— 这是刻意的
   * （触发时机按任务口径不改，语义靠字段区分）。真正"进池"的推送是 `first-message`。
   *
   * 刻意 `void` 调用（不 await）：这是**通知**，不是业务前置条件 —— 广播慢/失败都不能让
   * 老板的"发消息"或"打开客服"变慢或失败。内部已 catch，不会产生 unhandled rejection。
   */
  private async announceCsNew(conversationId: string | number, reason: 'created' | 'first-message' | 'released', initiatorUserId?: string): Promise<void> {
    let nickname = '';
    try {
      if (initiatorUserId) {
        nickname = (await this.nicknamesOf([initiatorUserId])).get(String(initiatorUserId)) ?? '';
      }
    } catch {
      // 昵称取不到不影响刷新（客户端只把它当提示文案）
    }
    await this.emitToOnlineCs('cs:new', {
      conversationId: String(conversationId),
      reason,
      userNickname: nickname,
    });
  }

  /**
   * 首条咨询的一行摘要（超长截断；图片等非文字给占位）—— 只用于大厅列表，不改任何原始数据。
   *
   * 新池子口径（`CS_POOL_SQL`：必须有老板消息）下，"没有首条消息"这件事在列表里不可能出现，
   * 所以 `CS_HALL_PREVIEW_NONE`（`（暂无消息）`）与"已撤回"分支都只是**防御性兜底**
   * （留着重在语义完整：这个函数对"任何首条消息形状"都能给出一个不泄漏内容的一行摘要）。
   */
  private csPreviewOf(msgType: string | null, content: string | null, recalled: boolean): string {
    if (!msgType) return CS_HALL_PREVIEW_NONE;
    if (recalled) return '【消息已撤回】';
    if (msgType === 'image') return '【图片】';
    if (msgType !== 'text') return '【消息】';
    const text = String(content ?? '').replace(/\s+/g, ' ').trim();
    if (!text) return CS_HALL_PREVIEW_NONE;
    return text.length > CS_HALL_PREVIEW_MAX ? `${text.slice(0, CS_HALL_PREVIEW_MAX)}…` : text;
  }

  /** 等待时长的人读文本（秒 → 「刚刚 / N 分钟 / N 小时 M 分钟 / N 天 M 小时」） */
  private humanWait(seconds: number): string {
    const s = Math.max(0, Math.floor(seconds));
    if (s < 60) return '刚刚';
    const m = Math.floor(s / 60);
    if (m < 60) return `${m} 分钟`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h} 小时 ${m % 60} 分钟`;
    return `${Math.floor(h / 24)} 天 ${h % 24} 小时`;
  }


  /** 客服主动结束会话（或管理员关闭） */
  async closeConversation(conversationId: string, actor: ChatActor) {
    const conv = await this.convRepo.findOne({ where: { id: conversationId } });
    if (!conv) throw new NotFoundException('会话不存在');
    conv.status = 'closed';
    conv.closedAt = new Date();
    conv.closedBy = 'admin';
    // 已结束 = 未读归零（与 closeByUser / closeByWorker 同一口径）
    conv.unreadUser = 0;
    conv.unreadWorker = 0;
    await this.convRepo.save(conv);
    this.realtime.emitToUser(conv.userId, 'chat:closed', { conversationId });
  }

  // ---------------- 消息（docs/07 核心） ----------------

  /** 发送限流：20 条/分/主体（Redis 计数，docs/07） */
  private async checkRateLimit(actor: ChatActor): Promise<void> {
    const key = `chat:rate:${actor.type}:${actor.userId}`;
    const n = await this.redis.incr(key);
    if (n === 1) await this.redis.expire(key, 60);
    if (n > 20) {
      throw new BadRequestException('发送过于频繁，请稍后再试');
    }
  }

  /**
   * 发送消息：
   * - 事务内行锁会话 → seq = last_seq + 1 → 落库 → 更新 last_seq 与未读数（docs/07 顺序保证）
   * - clientMsgId 幂等：唯一键冲突时回查原消息重发 ACK，不重复落库
   * - 广播：msg:ack → 发送方；msg:new → 会话房间；unread:update → 对方
   */
  async sendMessage(actor: ChatActor, conversationId: string, dto: { clientMsgId?: string; msgType?: string; content: string }) {
    const content = (dto.content ?? '').trim().slice(0, 5000);
    if (!content) throw new BadRequestException('消息内容为空');
    const msgType = dto.msgType || 'text';
    if (!['text', 'image'].includes(msgType)) throw new BadRequestException('不支持的消息类型');
    await this.checkRateLimit(actor);

    // 归属校验（docs/07 铁律）
    const conv =
      actor.type === 'user'
        ? await this.assertUserMember(conversationId, actor.userId)
        : await this.assertWorkerCs(conversationId, actor.userId);
    if (conv.status !== 'open') throw new BadRequestException('会话已关闭');

    const clientMsgId = dto.clientMsgId ? String(dto.clientMsgId).slice(0, 64) : null;

    // 幂等先行：同 clientMsgId 直接重发原 ACK
    if (clientMsgId) {
      const dup = await this.msgRepo.findOne({ where: { conversationId, clientMsgId } });
      if (dup) {
        this.realtime.emitToUser(actor.userId, 'msg:ack', this.ackView(dup));
        return this.messageView(dup);
      }
    }

    /**
     * 「首次发消息进池」标记（负责人 2026-10-08）：客服会话里**老板的第一条消息**也要推 `cs:new`——
     * 老板常常先打开客服页（会话已建）再打字，只靠"创建时广播"会让客服看不到内容变化。
     *
     * 取值在**事务内、行锁之后**读 `locked.lastSeq`：并发两条首消息被行锁串行化后，
     * 只有真正的那一条看到 `last_seq = 0` → 只广播一次（不是靠"猜"，是锁给的确定性）。
     */
    let csFirstUserMessage = false;
    const message = await this.convRepo.manager.transaction(async (em) => {
      const locked = await em.findOne(ChatConversation, { where: { id: conversationId }, lock: { mode: 'pessimistic_write' } });
      if (!locked || locked.status !== 'open') throw new BadRequestException('会话不可用');
      const seq = Number(locked.lastSeq) + 1;
      if (locked.type === 'cs' && actor.type === 'user' && Number(locked.lastSeq) === 0) csFirstUserMessage = true;
      const msgId = randomUUID();
      try {
        const msg = await em.save(
          em.create(ChatMessage, {
            msgId, conversationId, seq: String(seq), senderType: actor.type, senderId: actor.userId,
            msgType, content, clientMsgId,
          }),
        );
        locked.lastSeq = String(seq);
        // 未读归属：好友会话记对方侧；CS 会话用户发→客服侧，客服发→用户侧
        if (actor.type === 'user' && locked.type === 'friend') {
          if (String(locked.userId) === String(actor.userId)) locked.unreadPeer += 1;
          else locked.unreadUser += 1;
        } else if (actor.type === 'user') {
          locked.unreadWorker += 1;
        } else {
          locked.unreadUser += 1;
        }
        await em.save(locked);
        return msg;
      } catch (e) {
        // 并发同 clientMsgId：唯一键冲突 → 回查幂等重发（不重复落库）
        const err = e as { driverError?: { code?: string } };
        if (clientMsgId && err.driverError?.code === 'ER_DUP_ENTRY') {
          const existing = await em.findOne(ChatMessage, { where: { conversationId, clientMsgId } });
          if (existing) return existing;
        }
        throw e;
      }
    });

    // 广播（docs/07）
    this.realtime.emitToUser(actor.userId, 'msg:ack', this.ackView(message));
    const senderNickname = (await this.nicknamesOf([actor.userId])).get(String(actor.userId)) ?? '';
    this.realtime.server.to(`conv:${conversationId}`).emit('msg:new', this.messageView(message, senderNickname));
    if (actor.type === 'user' && (conv.type === 'friend' || conv.type === 'worker')) {
      // 好友/打手直聊：对方未读 +1 推送（事务后重读拿准确值）
      const fresh = await this.convRepo.findOne({ where: { id: conversationId } });
      const peerId = String(conv.userId) === String(actor.userId) ? conv.peerUserId : conv.userId;
      if (fresh && peerId) {
        const peerUnread = String(fresh.userId) === String(peerId) ? fresh.unreadUser : fresh.unreadPeer;
        this.realtime.emitToUser(peerId, 'unread:update', { conversationId, unread: Number(peerUnread) });
      }
    } else if (actor.type === 'user') {
      // CS：通知管理员 + 实时推给被指派客服（工作端列表立即刷新未读，修复调研缺口 A）
      this.realtime.emitToAdmins('chat:activity', { conversationId });
      const assigns = await this.assignRepo.find({ where: { conversationId, status: 'active' } });
      for (const a of assigns) {
        const fresh = await this.convRepo.findOne({ where: { id: conversationId } });
        this.realtime.emitToUser(a.workerUserId, 'unread:update', { conversationId, unread: Number(fresh?.unreadWorker ?? 0) });
      }
      // 还没人接入 + 这是本会话的第一条消息 → 让在线客服的大厅立刻出现这条待接入（cs:new）
      if (csFirstUserMessage && assigns.length === 0) {
        void this.announceCsNew(conversationId, 'first-message', actor.userId);
      }
    } else {
      this.realtime.emitToUser(conv.userId, 'unread:update', { conversationId, unread: conv.unreadUser + 1 });
    }
    return this.messageView(message);
  }

  /**
   * 标记已读（docs/07 msg:read）：清自己侧未读 + 记录**自己的已读位点**，
   * 并把「对方读到哪一条」推给会话内另一方（负责人 2026-10-04：单勾=已送达 / 双勾=已读）。
   *
   * 位点取服务端数据：该会话内「非系统消息、非本人发送」的最大 seq —— 即读者确实收到的对方消息里最新的一条；
   * 比直接拿 `conversation.lastSeq` 更准（不会把并发在途的自己发的消息算成对方已读）。
   */
  async markRead(actor: ChatActor, conversationId: string) {
    const conv =
      actor.type === 'user'
        ? await this.assertUserMember(conversationId, actor.userId)
        : await this.assertWorkerCs(conversationId, actor.userId);
    // 群组功能已下掉（2026-10-04）：不再有成员行未读，直聊路径统一走会话自身未读字段
    let changed = false;
    if (actor.type === 'worker' && conv.type === 'cs' && conv.unreadWorker > 0) {
      conv.unreadWorker = 0;
      changed = true;
    } else if (actor.type === 'worker' && conv.type === 'worker' && conv.unreadPeer > 0) {
      // 打手直聊：工作端位于对端
      conv.unreadPeer = 0;
      changed = true;
    } else if (actor.type === 'worker' && (conv.type === 'friend' || conv.type === 'worker')) {
      if (String(conv.userId) === String(actor.userId) && conv.unreadUser > 0) {
        conv.unreadUser = 0;
        changed = true;
      } else if (String(conv.peerUserId) === String(actor.userId) && conv.unreadPeer > 0) {
        conv.unreadPeer = 0;
        changed = true;
      }
    } else if (actor.type === 'user' && (conv.type === 'friend' || conv.type === 'worker')) {
      // 好友/打手直聊：清自己一侧未读
      if (String(conv.userId) === String(actor.userId) && conv.unreadUser > 0) {
        conv.unreadUser = 0;
        changed = true;
      } else if (String(conv.peerUserId) === String(actor.userId) && conv.unreadPeer > 0) {
        conv.unreadPeer = 0;
        changed = true;
      }
    } else if (actor.type === 'user' && conv.unreadUser > 0) {
      conv.unreadUser = 0;
      changed = true;
    }
    // 已读位点：只前进不回退（重进会话/重复已读不会把双勾打回单勾）
    const readSeq = await this.readPositionOf(conversationId, actor.userId);
    const readField = this.readerReadFieldOf(conv, actor);
    if (readSeq > Number(conv[readField] ?? 0)) {
      conv[readField] = String(readSeq);
      changed = true;
    }
    if (changed) await this.convRepo.save(conv);
    this.realtime.server.to(`conv:${conversationId}`).emit('msg:read:ack', { conversationId, lastSeq: Number(conv.lastSeq), readerType: actor.type });
    // 把读者的位点推给会话内另一方（含读者自己，客户端按 readerUserId 过滤）→ 对方消息行双勾
    this.realtime.server.to(`conv:${conversationId}`).emit('msg:read', {
      conversationId,
      readerUserId: String(actor.userId),
      readerType: actor.type,
      lastSeq: readSeq,
    });
    // 读者本人也要收到未读清零（返回会话列表时角标立即消失，修复调研缺口 C）
    this.realtime.emitToUser(actor.userId, 'unread:update', { conversationId, unread: 0 });
    // 回带「我这一侧」的未读（清完即 0，幂等重复调用同样为 0）——WS 忽略返回值，REST 一键已读用它回执
    return { ok: true, unread: Number(conv[this.ownUnreadFieldOf(conv, actor)] ?? 0) };
  }

  /**
   * 用户侧聊天接口（`/user/conversations/:id/*`）的**自称方判定** —— 本次真机报障修复的核心之一。
   *
   * ## 为什么需要它（真机证据）
   * 打手态聊天页复用老板端 `ChatDetailPage`（`home_shell.openWorkerChat` 不传 sendPath），
   * 于是**列表**走 `/worker/cs/conversations`（那里有"我作为客服被指派"的会话），
   * **打开**却走 `/user/conversations/:id/{messages,info}`（`assertUserMember` 只认
   * 会话属主/对端）→ 客服点开自己正在服务的那条 → **404「会话不存在」**
   * （真机截图：列表里有、点进去"会话不存在"+「重试」，同时顶部被客户端当成"本次咨询已结束"）。
   *
   * ## 判定（与 `markReadAsCaller` 逐字同一套，全部落在"当事方"上）
   * 1. 我是**用户侧**成员（cs 属主 / friend、worker 双人会话任一方）→ `user` 侧（语义不变）；
   * 2. 否则调用者**不是** worker 角色 → 仍旧 `user` 侧（老板态一行未变）；
   * 3. 否则必须是该会话的**当事客服**（`isWorkerPartyOf`：active 指派）→ 返回 `worker` 侧
   *    （后续 `assertWorkerCs` 会再做"档案在职 + can_serve_customer=1"的实时校验，
   *    撤了客服权限仍是正当的 403「无客服权限」，不会被这里洗成 200）；
   * 4. 其余（会话存在但我既不是成员也不是被指派客服）→ **404「会话不存在」**（安全审计 F3 口径：
   *    非当事方与"查无此会话"逐字相同，自增会话 id 不可枚举）。
   *
   * **不新增第二份 SQL**：`isWorkerPartyOf` 是既有实现，`markReadAsCaller` 同时改成复用它。
   */
  async resolveUserRouteActor(userId: string, sessionRole: string, conversationId: string): Promise<ChatActor> {
    const conv = await this.convRepo.findOne({ where: { id: conversationId } });
    if (!conv) throw new NotFoundException('会话不存在');
    const isUserSide =
      String(conv.userId) === String(userId) ||
      ((conv.type === 'friend' || conv.type === 'worker') && String(conv.peerUserId) === String(userId));
    if (isUserSide || String(sessionRole) !== 'worker') return { type: 'user', userId };
    if (!(await this.isWorkerPartyOf(conv, userId))) throw new NotFoundException('会话不存在');
    return { type: 'worker', userId };
  }

  /**
   * REST 一键已读（负责人 2026-10-06 裁决 · 缺口 3）：`POST /user/conversations/:id/read`。
   *
   * **与 WS `msg:read` 语义完全一致**：复用同一个 `markRead`（同一已读位点、同一未读清零、同一
   * `msg:read` / `msg:read:ack` / `unread:update` 推送），不新写第二套已读逻辑；重复调用幂等。
   * 唯一的差别是**「我是会话哪一侧」的判定依据**：
   * - WS 按**连接角色**（`client.data.role === 'worker'` → 客服侧）；
   * - REST 没有连接角色，按**会话归属**判定 —— 否则打手态（companion，role=worker）对
   *   「自己作为用户发起的那条客服会话」会被误判成客服侧，被 `assertWorkerCs`（只认 active 指派）403，
   *   而这正是打手态「一键已读」必须能用的那条会话。
   *
   * 判定顺序（全部落在"当事方"上，不泄漏他人会话是否存在）：
   * 1. 我是**用户侧**成员（cs 属主 / friend、worker 双人会话任一方）→ `user` 侧；
   * 2. 否则会话角色是 worker（客服账号 / 打手账号）→ `worker` 侧，但**先确认我确实是该会话的当事方**
   *    （双人会话任一方，或该会话的 active 指派客服）—— 见 [isWorkerPartyOf]；
   * 3. 其余（含"会话存在但我既不是成员也不是被指派客服"）→ 一律 **404「会话不存在」**。
   *
   * 安全审计 F3（会话存在性 oracle）：旧实现在第 2 步直接 `assertWorkerCs`，非当事方拿到
   * **403「无该会话客服授权」**（无客服权限时是 403「无客服权限」），而同会话的
   * `GET /user/conversations/:id/messages` 是 404「会话不存在」—— 文案差异使**自增会话 id 可枚举**
   * （404/403 分布 = 平台上存在哪些会话）。现在非当事方与"查无此会话"逐字同口径（404「会话不存在」），
   * 而当事方的**正当 403 语义保留**：被指派客服若被撤了客服权限，仍走 `assertWorkerCs` → 403「无客服权限」。
   *
   * 2026-10-11：判定逻辑**原样抽到** [resolveUserRouteActor]（用户侧的消息/状态/同步/发送四条路由
   * 与这里共用同一份），本方法只剩"判定 → markRead"两行。
   */
  async markReadAsCaller(userId: string, sessionRole: string, conversationId: string) {
    const actor = await this.resolveUserRouteActor(userId, sessionRole, conversationId);
    return this.markRead(actor, conversationId);
  }

  /**
   * 调用者（worker 账号）是否为该会话的**当事方**：
   * - 双人会话（friend / worker）任一方 → 是（用户侧分支已覆盖，这里兜底）；
   * - 客服会话（cs）→ 必须是该会话的 **active 指派客服**（与 `assertWorkerCs` 同一判据，实时查库）。
   * 只读判定，不做任何写操作；真正的权限与"无客服权限"判定仍在 `assertWorkerCs`（保住正当 403 语义）。
   */
  private async isWorkerPartyOf(conv: ChatConversation, workerUserId: string): Promise<boolean> {
    if (
      (conv.type === 'friend' || conv.type === 'worker') &&
      (String(conv.userId) === String(workerUserId) || String(conv.peerUserId) === String(workerUserId))
    ) {
      return true;
    }
    const assign = await this.assignRepo.findOne({
      where: { conversationId: conv.id, workerUserId: String(workerUserId), status: 'active' },
    });
    return !!assign;
  }

  /**
   * markRead 清零的「读者自己一侧」未读字段（与上面的清分支**逐条对应**，仅用于回带 `unread`）：
   * - 客服侧（actor=worker）看 CS 的 `unread_worker`、打手直聊的 `unread_peer`；
   * - 用户侧（actor=user）看 CS 的 `unread_user`、双人会话按属主/对端取。
   */
  private ownUnreadFieldOf(conv: ChatConversation, actor: ChatActor): 'unreadUser' | 'unreadWorker' | 'unreadPeer' {
    if (actor.type === 'worker') {
      if (conv.type === 'cs') return 'unreadWorker';
      if (conv.type === 'worker') return 'unreadPeer';
      return String(conv.userId) === String(actor.userId) ? 'unreadUser' : 'unreadPeer';
    }
    if (conv.type === 'cs') return 'unreadUser';
    return String(conv.userId) === String(actor.userId) ? 'unreadUser' : 'unreadPeer';
  }

  /** 读者当前已读位点 = 该会话内「非系统消息、非本人发送」的最大 seq（无则 0） */
  private async readPositionOf(conversationId: string, readerUserId: string): Promise<number> {
    const rows: Array<{ maxSeq: number | string | null }> = await this.msgRepo.manager.query(
      `SELECT COALESCE(MAX(seq), 0) AS maxSeq FROM chat_message
       WHERE conversation_id = ? AND sender_type <> 'system' AND sender_id <> ?`,
      [conversationId, readerUserId],
    );
    return Number(rows?.[0]?.maxSeq ?? 0);
  }

  // ---------------- 系统消息（负责人 2026-10-04：订单关键节点） ----------------

  /**
   * 写入一条**系统消息**（复用既有 `chat_message`，不新增表）：
   * `sender_type='system'` + `sender_id=0` + `msg_type='system'` + `content` 为文案。
   * - 与真人消息共用同一 seq 递增（事务内行锁会话，保证顺序）
   * - **不计未读**（订单节点已有 order:update 推送，避免未读角标虚高）
   * - 广播 `msg:new` 到会话房间；客户端收到 msgType='system' → 居中中性灰 chip
   */
  async appendSystemMessageTx(em: EntityManager, conversationId: string, content: string): Promise<ChatMessage | null> {
    const text = (content ?? '').trim().slice(0, 255);
    if (!text) return null;
    const locked = await em.findOne(ChatConversation, { where: { id: conversationId }, lock: { mode: 'pessimistic_write' } });
    if (!locked) return null;
    const seq = Number(locked.lastSeq) + 1;
    const msg = await em.save(
      em.create(ChatMessage, {
        msgId: randomUUID(),
        conversationId,
        seq: String(seq),
        senderType: 'system',
        senderId: '0',
        msgType: 'system',
        content: text,
        clientMsgId: null,
      }),
    );
    locked.lastSeq = String(seq);
    await em.save(locked);
    this.realtime.server.to(`conv:${conversationId}`).emit('msg:new', this.messageView(msg));
    return msg;
  }

  /** 订单节点系统消息：写入「老板 ↔ 打手」直聊会话（会话不存在则同一事务内建立） */
  async appendOrderSystemMessageTx(
    em: EntityManager,
    bossUserId: string,
    workerUserId: string,
    content: string,
  ): Promise<ChatMessage | null> {
    const conv = await this.ensureWorkerDirectTx(em, bossUserId, workerUserId);
    return this.appendSystemMessageTx(em, conv.id, content);
  }

  /** 撤回（docs/07：仅发送者本人 + 120s 窗口（system_setting 可配）；软状态不物理删除） */
  async recall(actor: ChatActor, msgId: string) {
    const msg = await this.msgRepo.findOne({ where: { msgId } });
    if (!msg) throw new NotFoundException('消息不存在');
    if (msg.senderType !== actor.type || String(msg.senderId) !== String(actor.userId)) {
      throw new ForbiddenException('只能撤回自己发送的消息');
    }
    const window = await this.settings.value('chat_recall_seconds', 120);
    if (Date.now() - msg.createdAt.getTime() > window * 1000) {
      throw new BadRequestException(`超过撤回窗口（${window} 秒）`);
    }
    msg.recalled = 1;
    msg.recalledAt = new Date();
    await this.msgRepo.save(msg);
    this.realtime.server.to(`conv:${msg.conversationId}`).emit('msg:recalled', { msgId, conversationId: msg.conversationId });
    return { ok: true };
  }

  /** 增量同步（docs/07 sync / HTTP afterSeq 补拉）：含归属校验 */
  async sync(actor: ChatActor, conversationId: string, afterSeq: number) {
    if (actor.type === 'user') await this.assertUserMember(conversationId, actor.userId);
    else await this.assertWorkerCs(conversationId, actor.userId);
    const msgs = await this.msgRepo
      .createQueryBuilder('m')
      .where('m.conversation_id = :conversationId AND m.seq > :afterSeq', { conversationId, afterSeq })
      .orderBy('m.seq', 'ASC')
      .take(500)
      .getMany();
    const nick = await this.nicknamesOf(msgs.map((m) => m.senderId));
    return { list: msgs.map((m) => this.messageView(m, nick.get(String(m.senderId)))), hasMore: msgs.length === 500 };
  }

  /** HTTP 历史（倒序分页） */
  async history(actor: ChatActor, conversationId: string, beforeSeq: number | undefined, limit: number) {
    if (actor.type === 'user') await this.assertUserMember(conversationId, actor.userId);
    else await this.assertWorkerCs(conversationId, actor.userId);
    const qb = this.msgRepo
      .createQueryBuilder('m')
      .where('m.conversation_id = :conversationId', { conversationId })
      .orderBy('m.seq', 'DESC')
      .take(Math.min(limit, 200));
    if (beforeSeq !== undefined && Number(beforeSeq) > 0) qb.andWhere('m.seq < :beforeSeq', { beforeSeq });
    const msgs = await qb.getMany();
    const nick = await this.nicknamesOf(msgs.map((m) => m.senderId));
    return { list: msgs.reverse().map((m) => this.messageView(m, nick.get(String(m.senderId)))) };
  }

  /** 管理端查看会话消息（docs/07：admin:chat:read，操作留痕由控制器写 operation_log） */
  async adminMessages(conversationId: string, limit: number) {
    const rows: Array<{ msg_id: string; seq: string; sender_type: string; sender_id: string; msg_type: string; content: string; recalled: number; created_at: Date }> =
      await this.convRepo.manager.query(
        `SELECT m.msg_id, m.seq, m.sender_type, m.sender_id, m.msg_type, m.content, m.recalled, m.created_at
         FROM chat_message m WHERE m.conversation_id = ? ORDER BY m.seq DESC LIMIT ?`,
        [conversationId, Math.min(limit, 500)],
      );
    return {
      list: rows.reverse().map((r) => ({
        msgId: r.msg_id, seq: Number(r.seq), senderType: r.sender_type, senderId: r.sender_id,
        msgType: r.msg_type, content: r.content, recalled: Number(r.recalled) === 1, createdAt: r.created_at,
      })),
    };
  }

  // ---------------- 视图 ----------------

  private ackView(m: ChatMessage) {
    return { clientMsgId: m.clientMsgId, msgId: m.msgId, seq: Number(m.seq), createdAt: m.createdAt };
  }

  private messageView(m: ChatMessage, senderNickname?: string | null) {
    return {
      msgId: m.msgId,
      seq: Number(m.seq),
      conversationId: m.conversationId,
      senderType: m.senderType,
      senderId: m.senderId,
      senderNickname: senderNickname ?? '',
      msgType: m.msgType,
      content: m.content,
      recalled: m.recalled === 1,
      createdAt: m.createdAt,
    };
  }

  /** 批量取发送者昵称（订单群消息展示用） */
  private async nicknamesOf(userIds: Array<string | number>): Promise<Map<string, string>> {
    const uniq = [...new Set(userIds.map((v) => String(v)))];
    if (!uniq.length) return new Map();
    const rows: Array<{ id: string; nickname: string | null }> = await this.convRepo.manager.query(
      `SELECT id, nickname FROM user WHERE id IN (?)`,
      [uniq],
    );
    return new Map(rows.map((r) => [String(r.id), r.nickname ?? '']));
  }
}
