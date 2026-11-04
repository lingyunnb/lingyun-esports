import { BadRequestException, HttpException, Inject, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { createHash, randomUUID } from 'crypto';
import Redis from 'ioredis';
import { Repository } from 'typeorm';
import { REDIS_CLIENT } from '../../common/redis.provider';
import { RealtimeGateway } from '../../realtime/realtime.gateway';
import { ChatService } from '../chat/chat.service';
import { SystemSettingService } from '../setting/system-setting.service';
import { takeOrderDivisionExistsSql } from '../worker/worker-division-permission.service';
import { AiConversation } from './ai-conversation.entity';
import { AiMessage } from './ai-message.entity';
import { AiUpstreamClient, UpstreamMessage } from './ai-upstream.client';
import {
  AiUserContext,
  buildSystemPrompt,
  buildRecommendSystemPrompt,
  formatPoints,
  isReasonTraceable,
  matchRule,
  orderNoTail,
  orderStatusLabel,
  parseRecommendPayload,
  RecommendCandidate,
  RecommendPickRaw,
  renderContextHint,
  ruleRecommend,
  shortText,
} from './ai-prompt';

/** 每用户每分钟请求上限（负责人：≤ 10 次/分） */
export const AI_RATE_LIMIT_PER_MINUTE = 10;
/** 全局（单实例）同时在跑的生成数上限（负责人：≤ 3） */
export const AI_MAX_CONCURRENT = 3;
/** 同用户同问题（且上下文相同）答案缓存时长（负责人：30 秒） */
export const AI_CACHE_TTL_SECONDS = 30;
/** 上游无数据超时：20 秒没有任何字节到达即中断并降级 */
export const AI_IDLE_TIMEOUT_MS = 20000;
/** 单次回复硬上限（防上游持续慢吐字节挂死） */
export const AI_TOTAL_TIMEOUT_MS = 60000;
/** 喂给模型的历史条数（最近 3 轮对话） */
const AI_HISTORY_TURNS = 6;
/**
 * `POST /user/ai/reset` 的防抖窗口（秒）——同一用户 2 秒内连续调用只轮换一次。
 * 客户端 dispose 与「进入兜底」可能各触发一次，防抖保证不会产生多余的 session（更不会多出会话行）。
 */
export const AI_RESET_THROTTLE_SECONDS = 2;

/** 找陪玩推荐：一次最多喂多少候选打手（负责人：最多 20 个的「名字 + 介绍」） */
export const AI_RECOMMEND_CANDIDATE_LIMIT = 20;
/** 找陪玩推荐：一次最多推荐几个人（负责人：1-3 个） */
export const AI_RECOMMEND_MAX_PICKS = 3;
/** 找陪玩推荐：20 秒没有结果就降级（负责人：20 秒超时降级） */
export const AI_RECOMMEND_TIMEOUT_MS = 20000;

export interface AiChatDto {
  message?: string;
  conversationId?: string;
  idempotencyKey?: string;
}

export interface AiConfigView {
  enabled: boolean;
  presets: Array<{ label: string; text: string }>;
  maxInputLength: number;
  greeting: string;
}

/** POST /user/ai/recommend 请求体（身份只从 JWT sub 取；这里只有"需求"两个字是用户输入） */
export interface AiRecommendDto {
  need?: string;
  /** 可选：限定分部（不传 = 全部分部） */
  divisionId?: string;
}

/** 推荐结果里的一条打手（**只有展示级字段**：与提示词白名单一致，无任何敏感字段） */
export interface AiRecommendPickView {
  workerId: string;
  name: string;
  intro: string;
  divisionName: string;
  reason: string;
}

/** POST /user/ai/recommend 响应（降级时 degraded=true；命中缓存时 cached=true） */
export interface AiRecommendResult {
  reply: string;
  picks: AiRecommendPickView[];
  degraded: boolean;
  cached: boolean;
  conversationId: string;
  messageId: string;
}

/** 无候选打手时的确定性答复（**不调用模型** —— 没有名单就不可能被编造） */
const NO_CANDIDATE_REPLY =
  '现在还没有可推荐的打手，我不给你编人。你可以先在下面看看全部陪玩，或者回我一句"转人工"，我帮你接人工客服按需求安排。';

const DEFAULT_PRESETS: Array<{ label: string; text: string }> = [
  { label: '怎么下单', text: '怎么下单？' },
  { label: '余额怎么用', text: '余额怎么用？' },
  { label: '退款规则', text: '退款规则是什么？' },
  { label: '转人工', text: '我要转人工客服' },
];
const DEFAULT_GREETING = '我是祁小山，祁连山电竞的客服。订单、余额、售后的事直接说，我帮你看。';
const DEFAULT_MAX_INPUT = 500;

/** 生成任务（内存态：全局并发闸 + /user/ai/stop 的中断句柄） */
interface ActiveGeneration {
  controller: AbortController;
  messageId: string;
  conversationId: string;
  startedAt: number;
}

/**
 * AI 咨询「祁小山」服务。
 *
 * 契约：POST /user/ai/chat 立即返回 `{ conversationId, messageId, accepted: true }`，
 * 回复内容通过 WS（realtime gateway，房间 uid:{userId}）以 ai:chunk / ai:done / ai:error 下发。
 *
 * 关键设计：
 * - 只读：本服务只查询该用户自己的订单/余额（脱敏），没有任何写业务数据的路径
 * - 限流：Redis 固定窗口 10 次/分/用户；全局并发 ≤ 3（单实例内存闸，pm2 单进程部署）
 * - 缓存：同用户 + 同问题 + 同上下文指纹 → 30 秒内复用答案（`cached=1`，不调用模型）
 * - 降级：上游超时/报错/未配置 → 本地规则库回答 + ai:error（说明）+ ai:done（可用答复）
 */
@Injectable()
export class AiService {
  private readonly logger = new Logger('Ai');
  /** 全局并发闸（单实例；PM2 fish-server 为单进程，fork 模式） */
  private inflight = 0;
  /** 进行中的生成（userId → 任务），/user/ai/stop 用 */
  private readonly active = new Map<string, ActiveGeneration>();

  constructor(
    @InjectRepository(AiConversation) private readonly convRepo: Repository<AiConversation>,
    @InjectRepository(AiMessage) private readonly msgRepo: Repository<AiMessage>,
    private readonly upstream: AiUpstreamClient,
    private readonly realtime: RealtimeGateway,
    private readonly chatService: ChatService,
    private readonly settings: SystemSettingService,
    @Inject(REDIS_CLIENT) private readonly redis: Redis,
  ) {}

  // ---------------- 对外：配置 ----------------

  /** GET /user/ai/config：总开关 + 快捷问题 chips + 输入上限 + 开场白（均可在管理端改） */
  async config(): Promise<AiConfigView> {
    const [enabled, greeting, maxLen, presets] = await Promise.all([
      this.settingValue<boolean>('ai_enabled', true),
      this.settingValue<string>('ai_greeting', DEFAULT_GREETING),
      this.settingValue<number>('ai_max_input_length', DEFAULT_MAX_INPUT),
      this.settingValue<Array<{ label?: unknown; text?: unknown }>>('ai_presets', DEFAULT_PRESETS),
    ]);
    const presetsView = (Array.isArray(presets) ? presets : DEFAULT_PRESETS)
      .map((p) => ({ label: String(p?.label ?? '').slice(0, 16), text: String(p?.text ?? '').slice(0, 100) }))
      .filter((p) => p.label && p.text);
    return {
      enabled: enabled !== false,
      presets: presetsView.length ? presetsView : DEFAULT_PRESETS,
      maxInputLength: Number.isFinite(Number(maxLen)) && Number(maxLen) > 0 ? Number(maxLen) : DEFAULT_MAX_INPUT,
      greeting: typeof greeting === 'string' && greeting ? greeting : DEFAULT_GREETING,
    };
  }

  private async settingValue<T>(key: string, fallback: T): Promise<T> {
    try {
      const row = await this.settings.get(key);
      const v = row?.cfgValue?.['value'];
      return (v === undefined || v === null ? fallback : (v as T));
    } catch {
      return fallback;
    }
  }

  // ---------------- 对外：提问 ----------------

  /**
   * POST /user/ai/chat：立即受理并返回，不阻塞等模型（生成在后台跑，内容走 WS）。
   * 用户身份只从 JWT sub 传入的 userId 取，请求体里的任何 id 都不作为身份。
   */
  async chat(userId: string, dto: AiChatDto): Promise<{
    conversationId: string;
    messageId: string;
    accepted: true;
    sessionId: string;
    cached?: boolean;
    duplicated?: boolean;
  }> {
    const cfg = await this.config();
    if (!cfg.enabled) {
      throw this.aiError(503, 'AI_DISABLED', 'AI 客服这会儿关着，你可以直接在消息页找人工客服。');
    }
    const message = typeof dto.message === 'string' ? dto.message.trim() : '';
    if (!message) throw new BadRequestException('消息不能为空');
    if (message.length > cfg.maxInputLength) {
      throw this.aiError(400, 'AI_INPUT_TOO_LONG', `一条最多 ${cfg.maxInputLength} 个字，你这条 ${message.length} 字，拆开说更清楚。`);
    }

    // ① 限流（每分钟 10 次；命中即 429 + 明确 errorCode）
    await this.assertUserRateLimit(userId);

    // ② 会话 + 当前 session：本次提问/生成/落库全程绑定这一个 session（reset 轮换后不会写进新 session）
    const conv = await this.getOrCreateConversation(userId);
    const sessionId = await this.ensureSession(conv);

    // ③ 幂等重放：同 idempotencyKey 第二次调用 → 回放同一答案，不重复落库、不重复调用模型。
    //    **只认同一 session 的键**：跨 session 的老键一律作废旧语义（否则会把上一条会话的答案搬进新会话）。
    let idempotencyKey = typeof dto.idempotencyKey === 'string' ? dto.idempotencyKey.trim().slice(0, 64) : '';
    if (idempotencyKey) {
      const existing = await this.msgRepo.findOne({ where: { userId, idempotencyKey } });
      if (existing && String(existing.sessionId) === sessionId) {
        const reply = existing.replyMsgId
          ? await this.msgRepo.findOne({ where: { msgId: existing.replyMsgId } })
          : null;
        if (reply) {
          this.emitReply(userId, existing.conversationId, reply.msgId, reply.content, reply.cached === 1, sessionId);
        }
        return {
          conversationId: String(existing.conversationId),
          messageId: existing.replyMsgId ?? existing.msgId,
          accepted: true,
          sessionId,
          duplicated: true,
        };
      }
      if (existing) {
        this.logger.log(`ai chat 忽略上一 session 的幂等键 uid=${userId}（换 session 后重新提问）`);
        idempotencyKey = '';
      }
    }

    // 客户端回传 conversationId 时校验归属（该用户只有一条长期会话）
    const bodyConvId = typeof dto.conversationId === 'string' ? dto.conversationId.trim() : '';
    if (bodyConvId && bodyConvId !== String(conv.id)) {
      throw this.aiError(400, 'AI_CONVERSATION_MISMATCH', '会话对不上，重新进一下 AI 咨询页面。');
    }

    // ④ 脱敏上下文（昵称 / 余额 / 最近 3 单状态+商品名+单号后 4 位）
    const ctx = await this.buildContext(userId);
    const replyMsgId = randomUUID();

    // ⑤ 同问缓存（同用户 + 同问题 + 同上下文指纹；30 秒）
    const cacheKey = this.cacheKey(userId, message, ctx);
    const cachedAnswer = await this.readCache(cacheKey);
    if (cachedAnswer) {
      const startedAt = Date.now();
      await this.persistExchange({
        conversationId: conv.id,
        sessionId,
        userId,
        message,
        replyMsgId,
        idempotencyKey: idempotencyKey || null,
        replyContent: cachedAnswer.content,
        provider: cachedAnswer.provider,
        model: cachedAnswer.model,
        cached: 1,
      });
      this.emitReply(userId, conv.id, replyMsgId, cachedAnswer.content, true, sessionId);
      this.logChat({
        userId,
        conversationId: conv.id,
        provider: cachedAnswer.provider,
        model: cachedAnswer.model,
        costMs: Date.now() - startedAt,
        degraded: false,
        cached: true,
      });
      return { conversationId: conv.id, messageId: replyMsgId, accepted: true, sessionId, cached: true };
    }

    // ⑥ 全局并发闸（≤ 3）：满了明确拒绝，不排队、不静默丢弃
    if (!this.acquireSlot()) {
      throw this.aiError(429, 'AI_BUSY', '前面还有人正在问，等几秒再发一次就行。');
    }

    // ⑦ 落用户消息（seq 事务内分配）→ 立即返回；生成在后台
    let userMsgId: string;
    try {
      const userRow = await this.persistUserMessage({
        conversationId: conv.id,
        sessionId,
        userId,
        message,
        replyMsgId,
        idempotencyKey: idempotencyKey || null,
      });
      userMsgId = userRow.msgId;
    } catch (e) {
      this.releaseSlot();
      throw e;
    }

    void this.runGeneration({
      userId,
      conversationId: conv.id,
      sessionId,
      replyMsgId,
      message,
      ctx,
      excludeMsgId: userMsgId,
    });
    return { conversationId: conv.id, messageId: replyMsgId, accepted: true, sessionId };
  }

  // ---------------- 对外：找陪玩推荐（AI 按需求挑打手） ----------------

  /**
   * POST /user/ai/recommend：按需求推荐打手（**同步返回**：客户端要拿 picks 直接渲染卡片）。
   *
   * 流程（每一步都可核验）：
   * 1. 身份只从 JWT sub（userId）取；请求体只认 `need` 与可选 `divisionId`
   * 2. 限流复用客服问答那一套（同用户 60 秒内 ≤ 10 次，同一预算）
   * 3. 候选打手：`worker.status=1 AND can_take_order=1 AND user.status=1`（与 `/public/players` 同口径），
   *    **SQL 只 SELECT 昵称/介绍/分部名**（手机号、真实姓名、工号根本不进内存）
   * 4. 无候选 → 直接给确定性答复（不调模型，物理上不可能编人）+ 转人工/看全部陪玩出口
   * 5. 同问缓存（同用户 + 同需求 + 同分部 + 同候选指纹，30 秒）→ 直接复用
   * 6. 调**同一套 GLM 上游与祁小山人设**，要求只输出 `{reply, picks:[{name,reason}]}`
   * 7. 服务端按名字映射回真实 workerId（映射不上就丢弃，**绝不猜**），最多 3 个
   * 8. 超时（20s）/上游报错/输出不可解析 → 规则降级（按需求关键词 ↔ 介绍/分部重合度，理由引用介绍原文）+ `degraded:true`
   * 9. user + assistant 两行落既有 `ai_message`；picks 快照写 `picks_json`
   */
  async recommend(userId: string, dto: AiRecommendDto): Promise<AiRecommendResult> {
    const cfg = await this.config();
    if (!cfg.enabled) {
      throw this.aiError(503, 'AI_DISABLED', 'AI 客服这会儿关着，你可以直接在消息页找人工客服。');
    }
    const need = typeof dto.need === 'string' ? dto.need.trim() : '';
    if (!need) {
      throw new BadRequestException('说说你的需求，比如"想找个带我上钻的，晚上 9 点后有空"');
    }
    if (need.length > cfg.maxInputLength) {
      throw this.aiError(
        400,
        'AI_INPUT_TOO_LONG',
        `一条最多 ${cfg.maxInputLength} 个字，你这条 ${need.length} 字，拆开说更清楚。`,
      );
    }
    // divisionId 只接受纯数字主键（非数字 = 当作"全部分部"，绝不拼进 SQL）
    const rawDivision = String(dto.divisionId ?? '').trim();
    const divisionId = /^\d+$/.test(rawDivision) ? rawDivision : '';

    await this.assertUserRateLimit(userId);

    const conv = await this.getOrCreateConversation(userId);
    const sessionId = await this.ensureSession(conv);
    const replyMsgId = randomUUID();
    const candidates = await this.loadRecommendCandidates(divisionId);

    // ① 无候选：不调模型（没有名单就不会有编造），确定性答复 + 两个出口
    if (!candidates.length) {
      await this.persistRecommendExchange({
        conversationId: conv.id,
        sessionId,
        userId,
        need,
        replyMsgId,
        reply: NO_CANDIDATE_REPLY,
        picks: [],
        provider: 'rule',
        model: 'none',
      });
      this.logger.log(
        `ai recommend uid=${userId} conv=${conv.id} candidates=0 picks=0 degraded=false cached=false reason=no_candidate`,
      );
      return {
        reply: NO_CANDIDATE_REPLY,
        picks: [],
        degraded: false,
        cached: false,
        conversationId: conv.id,
        messageId: replyMsgId,
      };
    }

    // ② 同问缓存（30 秒；候选变了指纹就变，不会拿旧名单的答案糊弄）
    const cacheKey = this.recommendCacheKey(userId, need, divisionId, candidates);
    const cached = await this.readRecommendCache(cacheKey);
    if (cached) {
      await this.persistRecommendExchange({
        conversationId: conv.id,
        sessionId,
        userId,
        need,
        replyMsgId,
        reply: cached.reply,
        picks: cached.picks,
        provider: cached.provider,
        model: cached.model,
      });
      this.logger.log(
        `ai recommend uid=${userId} conv=${conv.id} candidates=${candidates.length} picks=${cached.picks.length} degraded=false cached=true`,
      );
      return {
        reply: cached.reply,
        picks: cached.picks,
        degraded: false,
        cached: true,
        conversationId: conv.id,
        messageId: replyMsgId,
      };
    }

    // ③ 全局并发闸（与客服问答共用 ≤ 3）：满了明确拒绝，不排队
    if (!this.acquireSlot()) {
      throw this.aiError(429, 'AI_BUSY', '前面还有人正在问，等几秒再发一次就行。');
    }
    try {
      return await this.runRecommend({ userId, conversationId: conv.id, sessionId, replyMsgId, need, candidates, cacheKey });
    } finally {
      this.releaseSlot();
    }
  }

  /** 推荐生成主体：上游 → 解析 → 名字映射回真实打手 → 落库/缓存；任何失败都降级，绝不 500 */
  private async runRecommend(params: {
    userId: string;
    conversationId: string;
    sessionId: string;
    replyMsgId: string;
    need: string;
    candidates: RecommendCandidate[];
    cacheKey: string;
  }): Promise<AiRecommendResult> {
    const { userId, conversationId, sessionId, replyMsgId, need, candidates, cacheKey } = params;
    const startedAt = Date.now();
    let provider = this.upstream.provider;
    let model = this.upstream.model;
    let degraded = false;
    let reply = '';
    let picks: AiRecommendPickView[] = [];

    try {
      const messages: UpstreamMessage[] = [
        { role: 'system', content: buildRecommendSystemPrompt(candidates) },
        { role: 'user', content: `老板的需求：${need}` },
      ];
      const result = await this.upstream.streamChat({
        messages,
        // 同步接口：不需要给客户端推流，只等最终 JSON
        onDelta: () => {},
        idleTimeoutMs: AI_RECOMMEND_TIMEOUT_MS,
        totalTimeoutMs: AI_RECOMMEND_TIMEOUT_MS,
        debugTag: 'recommend',
      });
      const parsed = result.ok ? parseRecommendPayload(result.content) : null;
      if (parsed) {
        picks = this.mapPicks(parsed.picks, candidates);
        reply = shortText(parsed.reply, 120);
        // 模型只给了 picks 没给话术 → 服务端补一句（内容仍然只来自已挑中的人）
        if (!reply && picks.length) reply = `按你说的，我挑了 ${picks.length} 个，理由都在下面写着。`;
      } else {
        degraded = true;
        provider = 'rule';
        model = 'none';
        const rule = ruleRecommend(need, candidates);
        picks = this.mapPicks(rule.picks, candidates);
        reply = rule.reply;
        this.logger.warn(
          `ai recommend degrade uid=${userId} candidates=${candidates.length} ms=${Date.now() - startedAt} reason=${result.error ?? 'unparsable'}`,
        );
      }
    } catch (e) {
      // 兜底：模型层任何异常都转规则推荐（后台/请求线程绝不因上游异常 500）
      degraded = true;
      provider = 'rule';
      model = 'none';
      const rule = ruleRecommend(need, candidates);
      picks = this.mapPicks(rule.picks, candidates);
      reply = rule.reply;
      this.logger.error(`ai recommend failed uid=${userId}: ${(e as Error).message}`);
    }

    if (!reply) reply = NO_CANDIDATE_REPLY;

    // 落库（失败不影响这次答复交付，只记日志：用户已经看到内容了）
    try {
      await this.persistRecommendExchange({
        conversationId,
        sessionId,
        userId,
        need,
        replyMsgId,
        reply,
        picks,
        provider,
        model,
        cached: 0,
      });
      if (!degraded && picks.length) await this.writeRecommendCache(cacheKey, reply, picks, provider, model);
    } catch (e) {
      this.logger.error(`ai recommend persist failed uid=${userId}: ${(e as Error).message}`);
    }

    this.logger.log(
      `ai recommend uid=${userId} conv=${conversationId} candidates=${candidates.length} picks=${picks.length}` +
        ` provider=${provider} model=${model} ms=${Date.now() - startedAt} degraded=${degraded} cached=false`,
    );
    return { reply, picks, degraded, cached: false, conversationId, messageId: replyMsgId };
  }

  /**
   * 候选打手（口径与 `GET /public/players` 一致）。
   *
   * **只 SELECT 四个字段**：worker.id（回映射用，不进提示词）、user.nickname、user.intro、division.name。
   * 手机号（worker.phone / user.phone）、真实姓名（worker.real_name）、工号（worker.worker_no）
   * 不在查询里 —— 不是"过滤掉"，是**根本没查出来**。
   */
  private async loadRecommendCandidates(divisionId: string): Promise<RecommendCandidate[]> {
    let sql = `SELECT w.id AS workerId, u.nickname AS nickname, u.intro AS intro, d.name AS divisionName
       FROM worker w
       INNER JOIN user u ON u.id = w.user_id
       LEFT JOIN division d ON d.id = w.division_id
       WHERE w.status = 1 AND w.can_take_order = 1 AND u.status = 1
         AND TRIM(COALESCE(u.nickname, '')) <> ''`;
    const params: string[] = [];
    if (divisionId) {
      // 分部隔离（负责人 2026-10-04）：AI 推荐的候选打手也必须是**该分部有接单权限**的人，
      // 口径与「指定护航员 / 找陪玩 / 抢单大厅」完全一致（见 WorkerDivisionPermissionService）。
      sql += ` AND ${takeOrderDivisionExistsSql('?')}`;
      params.push(divisionId);
    }
    // limit 是代码常量（非用户输入），直接内联，避免 LIMIT ? 的驱动差异
    sql += ` ORDER BY w.id ASC LIMIT ${AI_RECOMMEND_CANDIDATE_LIMIT}`;
    const rows: Array<{
      workerId: string;
      nickname: string | null;
      intro: string | null;
      divisionName: string | null;
    }> = await this.msgRepo.manager.query(sql, params);
    return rows.map((r) => ({
      workerId: String(r.workerId),
      name: String(r.nickname ?? '').trim(),
      // 介绍截到 200 字喂模型（只截断、不改写；避免个别超长介绍挤掉候选名额）
      intro: shortText(String(r.intro ?? ''), 200),
      divisionName: String(r.divisionName ?? '').trim(),
    }));
  }

  /**
   * 把模型给的名字映射回真实打手：**名字对不上就丢弃**（绝不猜、绝不新建），同一人只留一次，最多 3 个。
   * 理由为空时回落到该打手介绍原文（≤30 字）——理由必须来自介绍或分部。
   */
  private mapPicks(raw: RecommendPickRaw[], candidates: RecommendCandidate[]): AiRecommendPickView[] {
    const byName = new Map<string, RecommendCandidate>();
    for (const c of candidates) {
      const key = this.normName(c.name);
      if (key && !byName.has(key)) byName.set(key, c);
    }
    const out: AiRecommendPickView[] = [];
    const seen = new Set<string>();
    for (const p of raw) {
      const hit = byName.get(this.normName(p.name));
      if (!hit || seen.has(hit.workerId)) continue;
      seen.add(hit.workerId);
      out.push({
        workerId: hit.workerId,
        name: hit.name,
        intro: hit.intro,
        divisionName: hit.divisionName,
        reason: this.cleanReason(p.reason, hit),
      });
      if (out.length >= AI_RECOMMEND_MAX_PICKS) break;
    }
    return out;
  }

  /** 名字归一化：只忽略空白差异（"小 北" == "小北"），不做任何模糊匹配 */
  private normName(name: string): string {
    return String(name ?? '').replace(/\s+/g, '');
  }

  /**
   * 推荐理由（三道闸，任一道不过就用介绍原文，保证"非空 + ≤30 字 + 有依据"）：
   * 1. 模型没给理由 → 介绍原文
   * 2. 理由夹带了**这个打手介绍/分部里没有的说法**（2-gram 重合率 < 0.6，如"经验丰富"、别人的特点）→ 介绍原文
   * 3. 介绍也没有 → 分部名 + "的打手"
   */
  private cleanReason(reason: string, c: RecommendCandidate): string {
    const r = shortText(reason, 30);
    const sources = [c.intro, c.divisionName, c.name];
    if (r && isReasonTraceable(r, sources)) return r;
    if (r) {
      this.logger.log(`ai recommend reason replaced worker=${c.workerId}（理由里有介绍/分部支持不了的说法，改用介绍原文）`);
    }
    const intro = shortText(c.intro, 30);
    if (intro) return intro;
    const division = shortText(c.divisionName, 30);
    return division ? `${division} 的打手` : '在官方名单里';
  }

  /** 推荐缓存键：同用户 + 同需求 + 同分部 + 同候选指纹（候选变了就不复用） */
  private recommendCacheKey(
    userId: string,
    need: string,
    divisionId: string,
    candidates: RecommendCandidate[],
  ): string {
    const norm = need.toLowerCase().replace(/\s+/g, ' ').trim();
    const sig = candidates.map((c) => `${c.workerId}:${c.name}`).join(',');
    const hash = createHash('sha1').update(`${norm}|${divisionId}|${sig}`).digest('hex');
    return `ai:rec:${userId}:${hash}`;
  }

  private async readRecommendCache(
    key: string,
  ): Promise<{ reply: string; picks: AiRecommendPickView[]; provider: string; model: string } | null> {
    try {
      const raw = await this.redis.get(key);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as {
        reply?: string;
        picks?: AiRecommendPickView[];
        provider?: string;
        model?: string;
      };
      if (!parsed?.reply || !Array.isArray(parsed.picks) || !parsed.picks.length) return null;
      return {
        reply: parsed.reply,
        picks: parsed.picks,
        provider: parsed.provider ?? 'glm',
        model: parsed.model ?? '',
      };
    } catch {
      return null;
    }
  }

  private async writeRecommendCache(
    key: string,
    reply: string,
    picks: AiRecommendPickView[],
    provider: string,
    model: string,
  ): Promise<void> {
    try {
      await this.redis.setex(
        key,
        AI_CACHE_TTL_SECONDS,
        JSON.stringify({ reply, picks, provider, model, at: Date.now() }),
      );
    } catch (e) {
      this.logger.warn(`ai recommend cache write failed: ${(e as Error).message}`);
    }
  }

  /** 推荐问答落库：user + assistant 两行（assistant 行带 picks 快照） */
  private async persistRecommendExchange(input: {
    conversationId: string;
    sessionId: string;
    userId: string;
    need: string;
    replyMsgId: string;
    reply: string;
    picks: AiRecommendPickView[];
    provider: string;
    model: string;
    cached?: number;
  }): Promise<void> {
    await this.persistUserMessage({
      conversationId: input.conversationId,
      sessionId: input.sessionId,
      userId: input.userId,
      message: input.need,
      replyMsgId: input.replyMsgId,
      idempotencyKey: null,
    });
    await this.persistAssistantMessage({
      conversationId: input.conversationId,
      sessionId: input.sessionId,
      userId: input.userId,
      replyMsgId: input.replyMsgId,
      content: input.reply,
      provider: input.provider,
      model: input.model,
      cached: input.cached ?? 0,
      picksJson: input.picks.map((p) => ({ ...p })),
    });
  }

  /** 后台生成：上游流式 → ai:chunk 多条 → ai:done；失败/超时 → 规则兜底 + ai:error + ai:done */
  private async runGeneration(params: {
    userId: string;
    conversationId: string;
    /** 本次提问发生时锁定的 session（生成中途 reset 也不会写进新 session） */
    sessionId: string;
    replyMsgId: string;
    message: string;
    ctx: AiUserContext;
    /** 本次提问的 msg_id（历史里要去掉它，避免重复喂给模型） */
    excludeMsgId?: string;
  }): Promise<void> {
    const { userId, conversationId, sessionId, replyMsgId, message, ctx, excludeMsgId } = params;
    const startedAt = Date.now();
    const controller = new AbortController();
    this.active.set(userId, { controller, messageId: replyMsgId, conversationId, startedAt });

    let provider = this.upstream.provider;
    let model = this.upstream.model;
    let degraded = false;
    let cached = 0;

    try {
      // 多轮历史**只取当前 session**（最近 3 轮）：reset 之后模型看不到上一次会话的任何内容
      const history = await this.loadHistory(conversationId, AI_HISTORY_TURNS, sessionId, excludeMsgId);
      // 分成比例**读配置**（管理端可改，默认平台 25%/打手 75%）：AI 向用户解释结算口径时与真实结算一致
      const commissionRate = await this.settings.platformCommissionRate();
      const messages: UpstreamMessage[] = [
        { role: 'system', content: buildSystemPrompt(ctx, commissionRate) },
        ...history.map((h) => ({
          role: (h.role === 'assistant' ? 'assistant' : 'user') as 'assistant' | 'user',
          content: h.content,
        })),
        { role: 'user', content: `${renderContextHint(ctx)}\n\n用户提问：${message}` },
      ];

      const result = await this.upstream.streamChat({
        messages,
        signal: controller.signal,
        idleTimeoutMs: AI_IDLE_TIMEOUT_MS,
        totalTimeoutMs: AI_TOTAL_TIMEOUT_MS,
        onDelta: (delta) => {
          this.realtime.emitToUser(userId, 'ai:chunk', { conversationId, messageId: replyMsgId, delta, sessionId });
        },
      });

      // 用户点了停止：有内容就交付部分内容，没内容就不落 assistant 行
      if (result.aborted && result.error === 'stopped') {
        if (result.content) {
          await this.persistAssistantMessage({ conversationId, sessionId, userId, replyMsgId, content: result.content, provider, model, cached: 0 });
          this.emitDone(userId, conversationId, replyMsgId, result.content, { stopped: true }, sessionId);
        } else {
          this.realtime.emitToUser(userId, 'ai:error', {
            conversationId,
            sessionId,
            messageId: replyMsgId,
            code: 'AI_STOPPED',
            message: '已停止这次回复。',
          });
        }
        this.logChat({ userId, conversationId, provider, model, costMs: Date.now() - startedAt, degraded: false, stopped: true });
        return;
      }

      if (result.ok && result.content) {
        await this.persistAssistantMessage({ conversationId, sessionId, userId, replyMsgId, content: result.content, provider, model, cached: 0 });
        await this.writeCache(this.cacheKey(userId, message, ctx), result.content, provider, model);
        this.emitDone(userId, conversationId, replyMsgId, result.content, {}, sessionId);
        this.logChat({ userId, conversationId, provider, model, costMs: Date.now() - startedAt, degraded: false });
        return;
      }

      // 降级：超时 / 上游报错 / 流中断（有半截内容也改用规则答复，绝不交付残句）
      degraded = true;
      provider = 'rule';
      model = 'none';
      const timedOut = result.error === 'timeout' || result.timedOut;
      const rule = matchRule(message, ctx);
      await this.persistAssistantMessage({ conversationId, sessionId, userId, replyMsgId, content: rule.content, provider, model, cached: 0 });
      this.realtime.emitToUser(userId, 'ai:error', {
        conversationId,
        sessionId,
        messageId: replyMsgId,
        code: timedOut ? 'AI_TIMEOUT' : 'AI_UPSTREAM',
        message: timedOut ? '我这边反应慢了，先给你说常见的情况。' : '我这边暂时查不了，先按常见情况回你。',
      });
      this.emitDone(userId, conversationId, replyMsgId, rule.content, { degraded: true, rule: rule.key }, sessionId);
      this.logger.warn(
        `ai degrade uid=${userId} provider=${provider} model=${model} ms=${Date.now() - startedAt} reason=${result.error ?? 'empty'} partial=${result.content.length}`,
      );
      this.logChat({ userId, conversationId, provider: 'rule', model: 'none', costMs: Date.now() - startedAt, degraded: true });
    } catch (e) {
      // 兜底：后台任务绝不把异常抛到进程（否则未捕获 rejection）
      degraded = true;
      const rule = matchRule(message, ctx);
      try {
        await this.persistAssistantMessage({ conversationId, sessionId, userId, replyMsgId, content: rule.content, provider: 'rule', model: 'none', cached: 0 });
        this.realtime.emitToUser(userId, 'ai:error', {
          conversationId,
          sessionId,
          messageId: replyMsgId,
          code: 'AI_INTERNAL',
          message: '我这边出了点问题，先给你说常见的情况。',
        });
        this.emitDone(userId, conversationId, replyMsgId, rule.content, { degraded: true, rule: rule.key }, sessionId);
      } catch (e2) {
        this.realtime.emitToUser(userId, 'ai:error', {
          conversationId,
          sessionId,
          messageId: replyMsgId,
          code: 'AI_INTERNAL',
          message: 'AI 客服暂时不可用，你可以转人工客服。',
        });
        this.logger.error(`ai fallback failed uid=${userId}: ${(e2 as Error).message}`);
      }
      this.logger.error(`ai generate failed uid=${userId}: ${(e as Error).message}`);
      this.logChat({ userId, conversationId, provider: 'rule', model: 'none', costMs: Date.now() - startedAt, degraded });
    } finally {
      const cur = this.active.get(userId);
      if (cur?.messageId === replyMsgId) this.active.delete(userId);
      this.releaseSlot();
    }
  }

  // ---------------- 对外：历史 / 转人工 / 停止 ----------------

  /**
   * GET /user/ai/messages?conversationId=&beforeSeq=&limit=（倒序补拉，结构对齐 chat 消息）
   *
   * **只返回当前 session 的消息**（`ai_conversation.current_session`）：轮换之后即使用户端没有调用
   * reset、或本地还留着旧列表，服务端也不会把上一条会话的内容发回去；旧 session 的消息仍在库里
   * （管理端 `GET /admin/ai/messages` 按 conversationId 能看到全部 session）。
   *
   * `seq` 仍是**会话级单调水位**（跨 session 连续，不按 session 归零）：
   * - 同一 session 内严格递增 → 客户端 `beforeSeq` 游标语义不变；
   * - 管理端跨 session 按 seq 排序仍是真实时间序（若按 session 归零，旧会话会插到新会话前面）。
   */
  async messages(userId: string, query: { conversationId?: string; beforeSeq?: string; limit?: string }) {
    const conv = await this.convRepo.findOne({ where: { userId } });
    if (!conv) return { list: [], hasMore: false, conversationId: '', sessionId: '' };
    const cid = typeof query.conversationId === 'string' ? query.conversationId.trim() : '';
    if (cid && cid !== String(conv.id)) throw new NotFoundException('会话不存在');
    const sessionId = await this.ensureSession(conv);
    const beforeSeq = Number(query.beforeSeq) > 0 ? Number(query.beforeSeq) : 0;
    const limitRaw = Number(query.limit);
    const limit = Number.isFinite(limitRaw) && limitRaw > 0 ? Math.min(Math.floor(limitRaw), 200) : 50;

    const qb = this.msgRepo
      .createQueryBuilder('m')
      .where('m.conversation_id = :cid AND m.session_id = :sid', { cid: conv.id, sid: sessionId })
      .orderBy('m.seq', 'DESC')
      .take(limit);
    if (beforeSeq > 0) qb.andWhere('m.seq < :beforeSeq', { beforeSeq });
    const msgs = await qb.getMany();
    return {
      list: msgs.reverse().map((m) => this.view(m)),
      hasMore: msgs.length === limit,
      conversationId: String(conv.id),
      sessionId,
    };
  }

  /**
   * POST /user/ai/reset：**会话轮换**（不删数据）——负责人 2026-10-04
   * 「用户退出祁小山之后应自动初始化，用户再次进入不要显示之前的对话」。
   *
   * 1. 先中断该用户正在跑的上游生成（复用 [stop]；客户端 dispose 时也会调 stop，这里兜底）
   * 2. 生成新 uuid 写入 `ai_conversation.current_session` → 用户侧读写立刻切到新 session（空会话）
   * 3. 顺手清掉该用户的 30 秒同问缓存（`ai:cache:{userId}:*`）：缓存键只含「问题 + 上下文指纹」，
   *    若不清，轮换后的第一条提问可能把上一条会话生成的答案（可能带上文口吻）当缓存回放
   * 4. **幂等**：2 秒内重复调用只轮换一次（Redis `SET NX EX`；Redis 不可用则不拦，宁可多换也不能不换）
   *
   * 身份只从 JWT sub 取；不创建新会话行（仍是每用户一条），旧 session 的消息一条都不动。
   */
  async resetSession(
    userId: string,
  ): Promise<{ ok: true; sessionId: string; rotated: boolean; stopped: number }> {
    // ① 正在生成 → 先中断（否则生成任务的半截答复会落在旧 session：虽然用户看不到，但没必要继续烧上游）
    const stopped = (await this.stop(userId)).stopped;

    const conv = await this.convRepo.findOne({ where: { userId } });
    // 从未提问过的用户：没有会话行可轮换（也就没有"上一次对话"），直接返回 ok
    if (!conv) return { ok: true, sessionId: '', rotated: false, stopped };

    // ② 幂等/防抖：2 秒内只轮换一次
    let first = true;
    try {
      first = (await this.redis.set(`ai:reset:${userId}`, '1', 'EX', AI_RESET_THROTTLE_SECONDS, 'NX')) === 'OK';
    } catch (e) {
      this.logger.warn(`ai reset throttle check failed (rotate anyway) uid=${userId}: ${(e as Error).message}`);
    }
    if (!first) {
      const fresh = await this.convRepo.findOne({ where: { userId } });
      const current = fresh?.currentSession ?? conv.currentSession ?? '';
      this.logger.log(`ai reset uid=${userId} conv=${conv.id} rotated=false throttled=true stopped=${stopped}`);
      return { ok: true, sessionId: current, rotated: false, stopped };
    }

    const next = randomUUID();
    await this.convRepo.update({ id: conv.id }, { currentSession: next });
    const cleared = await this.clearQuestionCache(userId);
    this.logger.log(
      `ai reset uid=${userId} conv=${conv.id} rotated=true stopped=${stopped} cacheCleared=${cleared}` +
        ` from=${shortText(conv.currentSession ?? '', 8)} to=${shortText(next, 8)}`,
    );
    return { ok: true, sessionId: next, rotated: true, stopped };
  }

  /**
   * POST /user/ai/handoff：转人工。
   * **复用既有客服会话**（ChatService.getUserConversation：取最近一条未结束 CS 会话，无则创建），
   * 成功后 WS 下发 ai:handoff（含 csConversationId），客户端直接跳到既有客服会话。
   */
  async handoff(userId: string): Promise<{ csConversationId: string }> {
    const cs = await this.chatService.getUserConversation(userId);
    const conv = await this.getOrCreateConversation(userId);
    const csConversationId = String(cs.id);
    this.realtime.emitToUser(userId, 'ai:handoff', { conversationId: String(conv.id), csConversationId });
    // 让管理端客服工作台感知到"有老板要人工"（复用既有 chat:activity 广播，仅提示）
    try {
      this.realtime.emitToAdmins('chat:activity', { conversationId: csConversationId, source: 'ai-handoff' });
    } catch {
      /* 广播失败不影响转人工结果 */
    }
    this.logger.log(`ai handoff uid=${userId} conv=${conv.id} handoff=true csConv=${csConversationId}`);
    return { csConversationId };
  }

  /** POST /user/ai/stop：中断该用户正在跑的上游请求（服务端 abort，客户端不再收 delta） */
  async stop(userId: string, messageId?: string): Promise<{ ok: true; stopped: number }> {
    const cur = this.active.get(userId);
    if (!cur) return { ok: true, stopped: 0 };
    if (messageId && messageId !== cur.messageId) return { ok: true, stopped: 0 };
    cur.controller.abort();
    this.logger.log(`ai stop uid=${userId} msg=${cur.messageId} ms=${Date.now() - cur.startedAt}`);
    return { ok: true, stopped: 1 };
  }

  // ---------------- 对外：管理端只读 ----------------

  /**
   * GET /admin/ai/conversations（权限点 admin:ai:read；只读，无写路径）
   *
   * 会话轮换后新增两个**只读**字段（供质检按会话分组查看）：
   * - `sessionCount`：这条长期会话累计出现过多少个 session（= 用户进过几次）
   * - `currentSession`：用户**当前**看到的 session（管理端要看的通常是全部 session 的消息）
   */
  async adminConversations(page: number, pageSize: number) {
    const rows: Array<{
      id: string; user_id: string; nickname: string | null; last_seq: string; current_session: string | null;
      created_at: Date; updated_at: Date; msg_count: number | string; session_count: number | string;
      last_content: string | null; last_role: string | null;
    }> = await this.convRepo.manager.query(
      `SELECT c.id, c.user_id, u.nickname, c.last_seq, c.current_session, c.created_at, c.updated_at,
              (SELECT COUNT(*) FROM ai_message m WHERE m.conversation_id = c.id) AS msg_count,
              (SELECT COUNT(DISTINCT m.session_id) FROM ai_message m WHERE m.conversation_id = c.id) AS session_count,
              (SELECT m.content FROM ai_message m WHERE m.conversation_id = c.id ORDER BY m.seq DESC LIMIT 1) AS last_content,
              (SELECT m.role FROM ai_message m WHERE m.conversation_id = c.id ORDER BY m.seq DESC LIMIT 1) AS last_role
       FROM ai_conversation c
       LEFT JOIN user u ON u.id = c.user_id
       ORDER BY c.updated_at DESC
       LIMIT ? OFFSET ?`,
      [pageSize, (page - 1) * pageSize],
    );
    const countRows: Array<{ cnt: number | string }> = await this.convRepo.manager.query(
      `SELECT COUNT(*) AS cnt FROM ai_conversation`,
    );
    return {
      list: rows.map((r) => ({
        id: String(r.id),
        userId: String(r.user_id),
        userNickname: r.nickname ?? '用户',
        lastSeq: Number(r.last_seq),
        currentSession: r.current_session ?? '',
        sessionCount: Number(r.session_count ?? 0),
        messageCount: Number(r.msg_count ?? 0),
        lastMessage: r.last_content ? { role: r.last_role ?? '', content: r.last_content.slice(0, 120) } : null,
        createdAt: r.created_at,
        updatedAt: r.updated_at,
      })),
      total: Number(countRows[0]?.cnt ?? 0),
      page,
      pageSize,
    };
  }

  /**
   * GET /admin/ai/messages?conversationId=（权限点 admin:ai:read）
   *
   * **不按 session 过滤**：质检要能看到这条会话的全部 session（每行带 `sessionId`，客户端按它分组即可）。
   */
  async adminMessages(conversationId: string, limit: number) {
    const rows: Array<{
      msg_id: string; seq: string; role: string; content: string; session_id: string;
      provider: string | null; model: string | null; cached: number; created_at: Date;
    }> = await this.convRepo.manager.query(
      `SELECT msg_id, seq, role, content, session_id, provider, model, cached, created_at
       FROM ai_message WHERE conversation_id = ? ORDER BY seq DESC LIMIT ?`,
      [conversationId, Math.min(Math.max(limit, 1), 500)],
    );
    return {
      conversationId,
      sessionCount: new Set(rows.map((r) => String(r.session_id ?? ''))).size,
      list: rows.reverse().map((r) => ({
        msgId: r.msg_id,
        seq: Number(r.seq),
        conversationId,
        sessionId: r.session_id,
        role: r.role,
        content: r.content,
        provider: r.provider,
        model: r.model,
        cached: Number(r.cached) === 1,
        createdAt: r.created_at,
      })),
    };
  }

  // ---------------- 内部：落库 ----------------

  /** 每用户一条长期会话（首次自动创建；唯一约束兜底并发）+ 首次即带当前 session */
  private async getOrCreateConversation(userId: string): Promise<AiConversation> {
    const found = await this.convRepo.findOne({ where: { userId } });
    if (found) return found;
    try {
      return await this.convRepo.save(
        this.convRepo.create({ userId, lastSeq: '0', currentSession: randomUUID() }),
      );
    } catch (e) {
      const err = e as { driverError?: { code?: string } };
      if (err.driverError?.code === 'ER_DUP_ENTRY') {
        const again = await this.convRepo.findOne({ where: { userId } });
        if (again) return again;
      }
      throw e;
    }
  }

  /**
   * 当前 session（空值兜底：老行/异常行不可能通过 migration 后仍为空，真出现就现分配一个并写回）。
   * 返回的 uuid 会被**本次请求全程持有** —— 落库/喂模型/WS 事件都用它，reset 改名不会串台。
   */
  private async ensureSession(conv: AiConversation): Promise<string> {
    const cur = String(conv.currentSession ?? '').trim();
    if (cur) return cur;
    const next = randomUUID();
    await this.convRepo.update({ id: conv.id }, { currentSession: next });
    conv.currentSession = next;
    this.logger.warn(`ai conversation 缺少 current_session，已补一个 uid=${conv.userId} conv=${conv.id}`);
    return next;
  }

  /** 会话内 seq 分配（事务 + 单条 UPDATE，保证递增无重复） */
  private async allocateSeq(conversationId: string): Promise<number> {
    const rows: Array<{ last_seq: string }> = await this.convRepo.manager.transaction(async (em) => {
      await em.query(`UPDATE ai_conversation SET last_seq = last_seq + 1 WHERE id = ?`, [conversationId]);
      return em.query(`SELECT last_seq FROM ai_conversation WHERE id = ?`, [conversationId]);
    });
    return Number(rows?.[0]?.last_seq ?? 0);
  }

  private async persistUserMessage(input: {
    conversationId: string;
    sessionId: string;
    userId: string;
    message: string;
    replyMsgId: string;
    idempotencyKey: string | null;
  }): Promise<AiMessage> {
    const seq = await this.allocateSeq(input.conversationId);
    return this.msgRepo.save(
      this.msgRepo.create({
        msgId: randomUUID(),
        conversationId: input.conversationId,
        sessionId: input.sessionId,
        userId: input.userId,
        role: 'user',
        content: input.message,
        seq: String(seq),
        provider: null,
        model: null,
        cached: 0,
        idempotencyKey: input.idempotencyKey,
        replyMsgId: input.replyMsgId,
      }),
    );
  }

  private async persistAssistantMessage(input: {
    conversationId: string;
    sessionId: string;
    userId: string;
    replyMsgId: string;
    content: string;
    provider: string;
    model: string;
    cached: number;
    /** 找陪玩推荐：本次挑中的打手快照（普通问答不传 = NULL） */
    picksJson?: Array<Record<string, unknown>>;
  }): Promise<AiMessage> {
    const seq = await this.allocateSeq(input.conversationId);
    return this.msgRepo.save(
      this.msgRepo.create({
        msgId: input.replyMsgId,
        conversationId: input.conversationId,
        sessionId: input.sessionId,
        userId: input.userId,
        role: 'assistant',
        content: input.content,
        seq: String(seq),
        provider: input.provider || null,
        model: input.model || null,
        cached: input.cached,
        idempotencyKey: null,
        replyMsgId: null,
        picksJson: input.picksJson ?? null,
      }),
    );
  }

  /** 一次问答落两行（user + assistant）—— 缓存命中路径复用 */
  private async persistExchange(input: {
    conversationId: string;
    sessionId: string;
    userId: string;
    message: string;
    replyMsgId: string;
    idempotencyKey: string | null;
    replyContent: string;
    provider: string;
    model: string;
    cached: number;
  }): Promise<void> {
    await this.persistUserMessage({
      conversationId: input.conversationId,
      sessionId: input.sessionId,
      userId: input.userId,
      message: input.message,
      replyMsgId: input.replyMsgId,
      idempotencyKey: input.idempotencyKey,
    });
    await this.persistAssistantMessage({
      conversationId: input.conversationId,
      sessionId: input.sessionId,
      userId: input.userId,
      replyMsgId: input.replyMsgId,
      content: input.replyContent,
      provider: input.provider,
      model: input.model,
      cached: input.cached,
    });
  }

  // ---------------- 内部：脱敏上下文 ----------------

  /**
   * 脱敏上下文（只喂必要字段）：
   * 昵称 / 余额 / 最近 3 单的「状态 + 商品名 + 单号后 4 位」。
   * **不含**手机号、真实姓名、完整单号、联系方式、他人数据。
   */
  private async buildContext(userId: string): Promise<AiUserContext> {
    let nickname = '';
    let points: string | null = null;
    const orders: AiUserContext['orders'] = [];
    try {
      const userRows: Array<{ nickname: string | null; balance: string | null }> = await this.msgRepo.manager.query(
        `SELECT u.nickname AS nickname, w.balance AS balance
         FROM user u LEFT JOIN wallet w ON w.user_id = u.id
         WHERE u.id = ? LIMIT 1`,
        [userId],
      );
      nickname = userRows[0]?.nickname ?? '';
      points = formatPoints(userRows[0]?.balance ?? null);
      // 只取 单号/状态/时间/商品名 —— 不取 contact_phone、game_player_id 等任何联系方式
      const orderRows: Array<{ order_no: string; status: string; created_at: Date; product_name: string | null }> =
        await this.msgRepo.manager.query(
          `SELECT o.order_no, o.status, o.created_at, p.name AS product_name
           FROM \`order\` o LEFT JOIN product p ON p.id = o.product_id
           WHERE o.user_id = ? ORDER BY o.id DESC LIMIT 3`,
          [userId],
        );
      for (const r of orderRows) {
        orders.push({
          status: orderStatusLabel(r.status),
          product: (r.product_name ?? '陪玩服务').slice(0, 32),
          tail: orderNoTail(r.order_no),
          createdAt: r.created_at ? new Date(r.created_at).toISOString().slice(0, 10) : '',
        });
      }
    } catch (e) {
      // 上下文取不到不影响咨询（模型/规则都按"查不到"处理）
      this.logger.warn(`ai context failed uid=${userId}: ${(e as Error).message}`);
    }
    return { nickname, points, orders };
  }

  /**
   * 最近 N 条对话（升序；排除本次刚落的提问行，本次提问单独放在末尾）。
   *
   * **必须传 sessionId**：喂给模型的多轮历史只取当前 session —— 这是"新会话不引用上一次会话内容"
   * 的关键闸门（隐私 + 防止顺着上文编）。
   */
  private async loadHistory(
    conversationId: string,
    limit: number,
    sessionId: string,
    excludeMsgId?: string,
  ): Promise<AiMessage[]> {
    const qb = this.msgRepo
      .createQueryBuilder('m')
      .where('m.conversation_id = :cid AND m.session_id = :sid AND m.role IN (:...roles)', {
        cid: conversationId,
        sid: sessionId,
        roles: ['user', 'assistant'],
      })
      .orderBy('m.seq', 'DESC')
      .take(limit);
    if (excludeMsgId) qb.andWhere('m.msg_id <> :excludeMsgId', { excludeMsgId });
    const msgs = await qb.getMany();
    return msgs.reverse();
  }

  // ---------------- 内部：限流 / 并发 / 缓存 ----------------

  private async assertUserRateLimit(userId: string): Promise<void> {
    const key = `rl:ai:chat:${userId}`;
    let count: number;
    try {
      count = await this.redis.incr(key);
      if (count === 1) await this.redis.expire(key, 60);
    } catch (e) {
      this.logger.warn(`ai rate limit check failed (pass) uid=${userId}: ${(e as Error).message}`);
      return;
    }
    if (count > AI_RATE_LIMIT_PER_MINUTE) {
      const ttl = await this.redis.ttl(key).catch(() => -1);
      const wait = ttl > 0 ? ttl : 60;
      throw this.aiError(429, 'AI_RATE_LIMITED', `问得有点快，${wait} 秒后再问；着急的话回我"转人工"，我帮你接人工客服。`);
    }
  }

  private acquireSlot(): boolean {
    if (this.inflight >= AI_MAX_CONCURRENT) return false;
    this.inflight += 1;
    return true;
  }

  private releaseSlot(): void {
    this.inflight = Math.max(0, this.inflight - 1);
  }

  /** 缓存键：同用户 + 同问题（归一化）+ 同上下文指纹（订单状态/余额变了就不复用旧答案） */
  private cacheKey(userId: string, message: string, ctx: AiUserContext): string {
    const norm = message.toLowerCase().replace(/\s+/g, ' ').trim();
    const ctxSig = `${ctx.points ?? ''}|${ctx.orders.map((o) => `${o.status}/${o.tail}`).join(',')}`;
    const hash = createHash('sha1').update(`${norm}|${ctxSig}`).digest('hex');
    return `ai:cache:${userId}:${hash}`;
  }

  private async readCache(key: string): Promise<{ content: string; provider: string; model: string } | null> {
    try {
      const raw = await this.redis.get(key);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as { content?: string; provider?: string; model?: string };
      if (!parsed?.content) return null;
      return { content: parsed.content, provider: parsed.provider ?? 'glm', model: parsed.model ?? '' };
    } catch {
      return null;
    }
  }

  private async writeCache(key: string, content: string, provider: string, model: string): Promise<void> {
    try {
      await this.redis.setex(key, AI_CACHE_TTL_SECONDS, JSON.stringify({ content, provider, model, at: Date.now() }));
    } catch (e) {
      this.logger.warn(`ai cache write failed: ${(e as Error).message}`);
    }
  }

  /**
   * 清掉该用户的同问缓存（`ai:cache:{userId}:*`）——**会话轮换时调用**。
   *
   * 缓存键只含「问题 + 上下文指纹」，不含 session；若不清，轮换后的第一条提问可能命中上一条会话
   * 生成的答案（口吻可能带着上文），就破坏了"新会话不看上文"。只用 SCAN + DEL，不阻塞 Redis。
   */
  private async clearQuestionCache(userId: string): Promise<number> {
    let cursor = '0';
    let deleted = 0;
    try {
      do {
        const [next, keys] = await this.redis.scan(cursor, 'MATCH', `ai:cache:${userId}:*`, 'COUNT', 200);
        cursor = next;
        if (keys.length) deleted += await this.redis.del(...keys);
      } while (cursor !== '0');
    } catch (e) {
      this.logger.warn(`ai cache clear failed uid=${userId}: ${(e as Error).message}`);
    }
    return deleted;
  }

  // ---------------- 内部：视图 / 事件 / 日志 ----------------

  private view(m: AiMessage) {
    return {
      msgId: m.msgId,
      seq: Number(m.seq),
      conversationId: String(m.conversationId),
      sessionId: m.sessionId,
      role: m.role,
      content: m.content,
      provider: m.provider,
      model: m.model,
      cached: m.cached === 1,
      createdAt: m.createdAt,
    };
  }

  /** 缓存命中/幂等重放：一次性把全文作为单个 delta + done 下发（客户端据 done 内容为准） */
  private emitReply(
    userId: string,
    conversationId: string,
    messageId: string,
    content: string,
    cached: boolean,
    sessionId: string,
  ): void {
    this.realtime.emitToUser(userId, 'ai:chunk', { conversationId, messageId, delta: content, sessionId });
    this.emitDone(userId, conversationId, messageId, content, cached ? { cached: true } : {}, sessionId);
  }

  private emitDone(
    userId: string,
    conversationId: string,
    messageId: string,
    content: string,
    extra: Record<string, unknown>,
    sessionId: string,
  ): void {
    // sessionId 随事件下发：客户端据此丢弃"上一次会话"的迟到 chunk/done（不会在新会话里冒出来）
    this.realtime.emitToUser(userId, 'ai:done', { conversationId, messageId, content, sessionId, ...extra });
  }

  /** 日志：只记 provider/model/耗时/是否降级/是否缓存/是否停止 —— 不记用户问题、不记手机号等敏感信息 */
  private logChat(input: {
    userId: string;
    conversationId: string;
    provider: string;
    model: string;
    costMs: number;
    degraded: boolean;
    cached?: boolean;
    stopped?: boolean;
  }): void {
    this.logger.log(
      `ai chat uid=${input.userId} conv=${input.conversationId} provider=${input.provider} model=${input.model} ms=${input.costMs}` +
        ` degraded=${input.degraded} cached=${input.cached === true} stopped=${input.stopped === true} handoff=false`,
    );
  }

  /** 业务错误码（errorCode 由全局异常过滤器透传到响应体，客户端据此差异化处理） */
  private aiError(status: number, errorCode: string, message: string): HttpException {
    return new HttpException({ message, errorCode }, status);
  }
}
