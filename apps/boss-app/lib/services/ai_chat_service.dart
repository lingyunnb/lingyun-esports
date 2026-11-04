/// 祁小山 AI 咨询 —— 数据源与实时通道（后端契约见任务书；**UI 只依赖这里的抽象**）
///
/// 为什么单独一层：
/// - 后端 AI 模块与客户端**并行开发**，接口字段仍可能微调（任务书：联调时若不一致以服务端实际为准）；
/// - 因此页面只认 [AiChatSource] / [AiRealtime] 两个抽象，联调时**只改本文件，不动页面与 UI**；
/// - 单元测试可注入假数据源与假事件通道，不需要真 socket、不需要真后端。
///
/// 接口契约（**2026-10-04 与后端联调确认版**，按服务端实际行为对接；联调时若再变以服务端为准）：
/// - `POST /user/ai/chat` body `{message, conversationId?, idempotencyKey?}` → **201**
///   `{conversationId, messageId, accepted, cached?, duplicated?}`
///   ⚠️ **`messageId` 是「这次 AI 回复」的 id**（不是用户消息 id）→ chunk/done/error 全用它配对；
///   用户气泡保留本地 id，绝不能被它覆盖（否则用户消息与回答同 id）。
/// - WS（复用 [RealtimeClient]，namespace `/ws/chat`，房间 `uid:{userId}`，**无需 join**）：
///   `ai:chunk {conversationId,messageId,delta}`（逐字，一次几十条）·
///   `ai:done {conversationId,messageId,content, degraded?, cached?, stopped?, rule?}`（**content 为准**）·
///   `ai:error {conversationId,messageId,code,message}` · `ai:handoff {conversationId,csConversationId}`
///   ⚠️ 极端情况下 **chunk 可能早于 HTTP 响应到达** → 一律按 messageId 归并（先占位、后归并），不假定顺序。
/// - 降级：**先 `ai:error` 再 `ai:done{degraded:true}`** → error 只当提示条，气泡仍用 done.content。
/// - 停止走 HTTP：`POST /user/ai/stop`（body 可带 `{messageId}`）；有半截内容回 `ai:done{stopped:true}`，
///   无内容回 `ai:error{code:'AI_STOPPED'}`。
/// - 错误码在响应体 `errorCode`（见 [friendlyAiError]）。
/// - `GET /user/ai/messages?conversationId=&beforeSeq=&limit=` → `{list:[...],hasMore,conversationId,sessionId}`，
///   list 按 seq 升序，补拉传 `beforeSeq = 当前最小 seq`；
///   ⚠️ **只返回当前 session 的消息**（服务端 `ai_conversation.current_session` 过滤）——
///   旧 session 的对话不会下发，用户重进即空会话，旧数据仍在库里（管理端可见）。
/// - `POST /user/ai/reset` → `{ok, sessionId, rotated, stopped}`：**会话轮换**（离开会话页时调用）。
///   旧消息一条不删，只是用户侧切到新 session；生成中途调用会先中断上游。
/// - `GET /user/ai/config` → `{enabled,presets:[{label,text}],maxInputLength,greeting}`。
/// - `POST /user/ai/handoff` → `{csConversationId}`（WS 同时下发 `ai:handoff`）。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/foundation.dart';

/// 本地兜底快捷问题（`/user/ai/config` 取不到时用；三条都是本平台真会被问的）
const List<String> kAiFallbackPresets = <String>['怎么下单', '余额怎么用', '退款规则'];

/// 空态首句与副句（设计稿 ai-entry-v3 第 5 节原文，不写「智能助手」这类腔调）
const String kAiIntroTitle = '我是祁小山，有什么想问的？';
const String kAiIntroSub = '平台规则、下单、余额、退款这类问题，我基本都能答。';

/// 转人工的说明（**不承诺时间**）
///
/// 【2026-10-08 客服大厅专项】原文是「答不上来的，我会给你接人工客服（9:00–次日 2:00 在线）」——
/// 那个时段是**客户端写死的**，而客服改成"有客服权限的打手主动接咨询"之后，
/// 在不在线取决于此刻有没有客服接单，**没有任何客户端能承诺的时段**。
/// 负责人对未接入态的口径是「不承诺时间」，所以这里只留动作、不留时段。
const String kAiHandoffHint = '答不上来的，我会给你接人工客服';

/// 客服在线时段的**兜底显示文案**：空串
///
/// 语义 ="服务端没下发时段" → **不显示时段**（而不是编一个）。
/// 为什么不留一个默认时段：见 [kAiHandoffHint] 的说明 —— 时段不是客户端能承诺的事实。
/// 服务端真配了 `serviceHours` / `csServiceHours` 时**照旧原样展示**（那是服务端配置，
/// 不归客户端改；本轮只改客户端兜底）。
const String kCsServiceHoursFallback = '';

/// 会话页页头副标题（设计稿原文）
const String kAiHeaderSubtitle = '平台规则与订单问题，随时问';

/// 转人工卡上「客服在不在线」这一句（**唯一出口**，两个渲染点共用）
///
/// - 服务端配了时段 → 「客服 9:00–次日 2:00 在线 · 平均 5 分钟回复」（**原样保留服务端配置**）；
/// - 服务端没配 → 「客服会尽快接入 · 平均 5 分钟回复」。
///
/// 为什么做成函数而不是在页面里写三元：这两句话必须**同一个口径**，
/// 页面各写一遍迟早出现"一处说尽快、一处还留着旧时段"。
String csAvailabilityLine({required String serviceHours, required String replyHint}) {
  final String h = serviceHours.trim();
  final String hint = replyHint.trim();
  final String head = h.isEmpty ? '客服会尽快接入' : '客服 $h 在线';
  return hint.isEmpty ? head : '$head · $hint';
}

/// 祁小山未开时那张卡上的一句（同一个口径的另一种句式）
String csManualHandoffLine({required String serviceHours}) {
  final String h = serviceHours.trim();
  return h.isEmpty ? '订单和退款的事直接找人工，客服会尽快接入' : '订单和退款的事直接找人工，客服 $h 在线';
}

/// AI 配置（`GET /user/ai/config` → `{enabled,presets:[{label,text}],maxInputLength,greeting}`）
class AiChatConfig {
  const AiChatConfig({
    this.enabled = true,
    this.presets = kAiFallbackPresets,
    this.maxInputLength = 500,
    this.greeting = kAiIntroTitle,
    this.serviceHours = kCsServiceHoursFallback,
    this.replyHint = '平均 5 分钟回复',
  });

  /// 服务端开关（false → 页面仍可进，但提示引导转人工客服）
  final bool enabled;

  /// 快捷问题（空态 chips 的文案；服务端下发，取不到才用本地兜底）
  final List<String> presets;

  /// 单条提问字数上限（服务端校验 500，客户端先拦）
  final int maxInputLength;

  /// 空态首句（服务端可下发；默认「我是祁小山，有什么想问的？」）
  final String greeting;

  /// 人工客服在线时段（转人工卡上的说明）
  ///
  /// **来源**：服务端 `GET /user/ai/config` 的 `serviceHours` / `csServiceHours`（取不到 → 空串）。
  /// 客户端**不再**兜底一个写死时段（2026-10-08 客服大厅专项）；空串 = 这一句不渲染时段。
  final String serviceHours;

  /// 人工客服回复时效（转人工卡上的说明）
  final String replyHint;

  /// 宽容解析：presets 既可能是 `[{label,text}]` 也可能是 `["文案"]`；
  /// 空列表仍回落到本地兜底（后端契约 2026-10-04：chips 与开场白都用服务端下发）
  factory AiChatConfig.fromJson(Map<String, dynamic>? json) {
    final raw = json?['presets'] ?? json?['quickQuestions'] ?? json?['questions'];
    final list = (raw as List<dynamic>? ?? const [])
        .map((e) => e is Map ? '${e['text'] ?? e['label'] ?? e['title'] ?? e['content'] ?? ''}' : '$e')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(6)
        .toList();
    final greeting = '${json?['greeting'] ?? ''}'.trim();
    return AiChatConfig(
      enabled: json?['enabled'] != false,
      presets: list.isEmpty ? kAiFallbackPresets : list,
      maxInputLength: (json?['maxInputLength'] as num?)?.toInt() ?? 500,
      greeting: greeting.isEmpty ? kAiIntroTitle : greeting,
      // 时段只认服务端下发（`serviceHours` 优先，其次 `csServiceHours`）；都没有 → 空串
      // （空串时调用处不渲染"客服 X 在线"，改说"客服会尽快接入"）
      serviceHours: '${json?['serviceHours'] ?? json?['csServiceHours'] ?? kCsServiceHoursFallback}'.trim(),
      replyHint: '${json?['replyHint'] ?? '平均 5 分钟回复'}',
    );
  }
}

/// 服务端错误码 → 能直接给用户看的中文（后端契约 2026-10-04 第 6 条）
///
/// 原则（docs/21）：不写「网络异常」这类空话，说清楚「发生了什么 + 你接下来能做什么」。
String friendlyAiError(String errorCode, String serverMessage) {
  switch (errorCode) {
    case 'AI_RATE_LIMITED':
      // 服务端消息自带「xx 秒后再问」，优先用它（具体数字比空话有用）
      return serverMessage.isNotEmpty ? serverMessage : '问得有点快，等一会儿再问我';
    case 'AI_BUSY':
      return '现在问的人有点多，过一会儿再问我';
    case 'AI_DISABLED':
      return '祁小山这会儿没开，可以找人工客服';
    case 'AI_INPUT_TOO_LONG':
      return '问题太长了，砍到 500 字以内再发我';
    case 'AI_CONVERSATION_MISMATCH':
      return '会话对不上了，重新问一次就行';
    case 'AI_STOPPED':
      return '已停止';
    default:
      // 其余（含网络失败）：按设计稿文案给动作，不把「网络连接失败，请检查网络」这类
      // 通用报错原样丢给用户（docs/21：不写空话，直接给动作）
      return '发送失败';
  }
}

/// 一条 AI 会话消息（历史与实时都映射成它）
class AiMessage {
  const AiMessage({
    required this.id,
    required this.fromMe,
    required this.content,
    required this.at,
    this.seq = 0,
    this.sessionId,
  });

  final String id;

  /// true = 用户（我方气泡 `AppColors.primary`）；false = 祁小山（白底气泡）
  final bool fromMe;
  final String content;
  final DateTime at;
  final int seq;

  /// 服务端给的归属 session（`ai_message.session_id`）；老接口/假数据可能没有 → null
  final String? sessionId;

  /// 宽容解析：字段名按 messageId/id/msgId、role/senderType/fromMe、content/text 依次尝试
  static AiMessage? fromJson(Map<String, dynamic> json) {
    final id = '${json['messageId'] ?? json['id'] ?? json['msgId'] ?? ''}'.trim();
    final content = '${json['content'] ?? json['text'] ?? ''}';
    if (id.isEmpty && content.isEmpty) return null;
    final role = '${json['role'] ?? json['senderType'] ?? json['sender'] ?? ''}'.toLowerCase();
    final fromMe = json['fromMe'] is bool
        ? json['fromMe'] as bool
        : (role == 'user' || role == 'me' || role == 'mine');
    final atRaw = json['createdAt'] ?? json['created_at'] ?? json['at'];
    final sid = '${json['sessionId'] ?? json['session_id'] ?? ''}'.trim();
    return AiMessage(
      id: id.isEmpty ? 'h${json['seq'] ?? content.hashCode}' : id,
      fromMe: fromMe,
      content: content,
      at: atRaw is String ? (DateTime.tryParse(atRaw)?.toLocal() ?? DateTime.now()) : DateTime.now(),
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      sessionId: sid.isEmpty ? null : sid,
    );
  }
}

/// 历史一页（`GET /user/ai/messages` → `{list:[{msgId,seq,conversationId,sessionId,role,content,...}],hasMore}`）
class AiHistoryPage {
  const AiHistoryPage({this.conversationId, this.sessionId, this.items = const [], this.hasMore});

  final String? conversationId;

  /// 服务端**当前 session**（会话轮换后的新 uuid）；null = 服务端没给这个字段（老接口/假数据）
  final String? sessionId;

  /// 按 seq **升序**（服务端已排好，直接铺列表）
  final List<AiMessage> items;

  /// 还有更早的历史；**null = 服务端没给这个字段**（按「还有」处理，避免历史翻不上去）
  final bool? hasMore;
}

/// 发送结果（`POST /user/ai/chat`）
class AiSendResult {
  const AiSendResult({
    required this.conversationId,
    required this.messageId,
    this.accepted = true,
    this.sessionId,
  });

  final String conversationId;
  final String messageId;
  final bool accepted;

  /// 本次提问落库所用的 session（reset 后服务端返回新值；客户端据此认领 WS 事件）
  final String? sessionId;
}

/// 客户端「上一次已经展示过的 session」记忆 —— `POST /user/ai/reset` 失败时的**兜底**。
///
/// 为什么需要：正常路径靠服务端按 session 过滤（重进必空）；但若用户离线退出、进程被杀等
/// 导致 reset 没发出去，服务端不会轮换，用户再进来就会看到上一次的对话。
/// 客户端把"已经展示过的 session"记下（进程内 + 安全存储尽力持久化），
/// 下次进入若服务端返回的还是同一条 session → 说明没轮换成功 → 页面按空会话渲染（旧数据不删）。
///
/// 只存 uuid，不含任何聊天内容；存储不可用时退化为进程内记忆（App 不重启仍有效）。
class AiSessionTrace {
  AiSessionTrace._();

  static final Map<String, String> _memory = {};

  static String _key(String userKey) => 'ai_seen_session_$userKey';

  /// 上次已展示过的 session（没有则 null）
  static Future<String?> seenFor(String userKey) async {
    if (userKey.isEmpty) return null;
    final mem = _memory[userKey];
    if (mem != null && mem.isNotEmpty) return mem;
    final stored = await AppSettings.instance.readAiSeenSession(_key(userKey));
    if (stored != null && stored.isNotEmpty) {
      _memory[userKey] = stored;
      return stored;
    }
    return null;
  }

  /// 记住本次展示的 session（进程内立即生效，持久化尽力而为）
  static Future<void> remember(String userKey, String sessionId) async {
    if (userKey.isEmpty || sessionId.isEmpty) return;
    _memory[userKey] = sessionId;
    await AppSettings.instance.writeAiSeenSession(_key(userKey), sessionId);
  }

  /// 测试钩子：清空进程内记忆（安全存储本身在 widget 测试里是关闭的）
  @visibleForTesting
  static void debugReset() => _memory.clear();

  /// 测试钩子：当前进程内记忆（只读）—— 用例可自检"本机确实没有 session 记忆"（换机/清数据场景）
  @visibleForTesting
  static Map<String, String> get debugMemory => Map.unmodifiable(_memory);
}

/// AI 咨询数据源（UI 唯一依赖的数据入口）
abstract class AiChatSource {
  /// `GET /user/ai/config`：快捷问题等（失败不阻断页面，回落到本地兜底）
  Future<AiChatConfig> loadConfig(String token);

  /// `GET /user/ai/messages`：首屏不带 beforeSeq；顶部触底补拉带 beforeSeq（更早的历史）
  Future<AiHistoryPage> loadMessages(String token, {String? conversationId, int? beforeSeq, int limit = 20});

  /// `POST /user/ai/chat`
  Future<AiSendResult> send(
    String token, {
    required String message,
    String? conversationId,
    String? idempotencyKey,
  });

  /// `POST /user/ai/stop`：打断生成（不传 messageId 即停当前这条）
  Future<void> stop(String token, {required String conversationId, String? messageId});

  /// `POST /user/ai/reset`：**会话轮换**（离开会话页时调用；服务端会先中断正在跑的生成）。
  /// 返回 true = 服务端已受理（`ok:true`）；失败由调用方静默处理（下次进入由兜底保证空会话）。
  Future<bool> reset(String token);

  /// `POST /user/ai/handoff`：转人工，返回客服会话 id（拿不到返回 null，由 WS `ai:handoff` 兜底）
  Future<String?> handoff(String token, {required String conversationId, String? messageId});
}

/// HTTP 实现（走既有 [ApiClient]：鉴权/重试/错误码统一）
class HttpAiChatSource implements AiChatSource {
  HttpAiChatSource({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  @override
  Future<AiChatConfig> loadConfig(String token) async {
    final resp = await _api.request('GET', '/user/ai/config', token: token);
    return AiChatConfig.fromJson(resp['data'] as Map<String, dynamic>?);
  }

  @override
  Future<AiHistoryPage> loadMessages(
    String token, {
    String? conversationId,
    int? beforeSeq,
    int limit = 20,
  }) async {
    final resp = await _api.request('GET', '/user/ai/messages', token: token, queryParameters: {
      if (conversationId != null && conversationId.isNotEmpty) 'conversationId': conversationId,
      if (beforeSeq != null && beforeSeq > 0) 'beforeSeq': beforeSeq,
      'limit': limit,
    });
    final data = resp['data'] as Map<String, dynamic>?;
    final rawList = (data?['list'] as List<dynamic>? ?? const []);
    final list = rawList
        .whereType<Map<String, dynamic>>()
        .map(AiMessage.fromJson)
        .whereType<AiMessage>()
        .toList();
    // conversationId 契约里在**每条消息**上（顶层可能没有）→ 顶层缺就取第一条
    final cid = data?['conversationId'] ??
        (rawList.isNotEmpty && rawList.first is Map ? (rawList.first as Map)['conversationId'] : null);
    // 当前 session：服务端按它过滤过 list（旧 session 的消息不会下发）
    final sid = data?['sessionId'] ??
        (rawList.isNotEmpty && rawList.first is Map ? (rawList.first as Map)['sessionId'] : null);
    return AiHistoryPage(
      conversationId: cid == null ? null : '$cid',
      sessionId: sid == null || '$sid'.isEmpty ? null : '$sid',
      items: list,
      hasMore: data?['hasMore'] is bool ? data!['hasMore'] as bool : null,
    );
  }

  @override
  Future<AiSendResult> send(
    String token, {
    required String message,
    String? conversationId,
    String? idempotencyKey,
  }) async {
    final resp = await _api.request('POST', '/user/ai/chat', token: token, data: {
      'message': message,
      if (conversationId != null && conversationId.isNotEmpty) 'conversationId': conversationId,
      if (idempotencyKey != null && idempotencyKey.isNotEmpty) 'idempotencyKey': idempotencyKey,
    });
    final data = resp['data'] as Map<String, dynamic>? ?? const {};
    return AiSendResult(
      conversationId: '${data['conversationId'] ?? conversationId ?? ''}',
      messageId: '${data['messageId'] ?? ''}',
      accepted: data['accepted'] != false,
      sessionId: '${data['sessionId'] ?? ''}'.isEmpty ? null : '${data['sessionId']}',
    );
  }

  @override
  Future<void> stop(String token, {required String conversationId, String? messageId}) async {
    await _api.request('POST', '/user/ai/stop', token: token, data: {
      'conversationId': conversationId,
      if (messageId != null && messageId.isNotEmpty) 'messageId': messageId,
    });
  }

  @override
  Future<bool> reset(String token) async {
    final resp = await _api.request('POST', '/user/ai/reset', token: token, data: const {});
    final data = resp['data'] as Map<String, dynamic>? ?? const {};
    return data['ok'] != false;
  }

  @override
  Future<String?> handoff(String token, {required String conversationId, String? messageId}) async {
    final resp = await _api.request('POST', '/user/ai/handoff', token: token, data: {
      'conversationId': conversationId,
      if (messageId != null && messageId.isNotEmpty) 'messageId': messageId,
    });
    final data = resp['data'] as Map<String, dynamic>? ?? const {};
    final cs = '${data['csConversationId'] ?? data['conversationId'] ?? ''}';
    return cs.isEmpty ? null : cs;
  }
}

/// 实时事件通道（薄适配层）
///
/// 生产实现复用全局单例 [RealtimeClient]（一条连接，docs/07）；
/// 测试注入假实现即可直接触发 `ai:chunk` 等事件，不需要真 socket。
abstract class AiRealtime {
  void connect({required String token});

  /// 订阅事件，返回退订函数
  void Function() on(String event, void Function(dynamic data) handler);
}

class SocketAiRealtime implements AiRealtime {
  SocketAiRealtime([RealtimeClient? client]) : _client = client ?? RealtimeClient.shared;

  final RealtimeClient _client;

  @override
  void connect({required String token}) => _client.connect(token: token);

  @override
  void Function() on(String event, void Function(dynamic data) handler) => _client.on(event, handler);
}
