import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/ai_chat_service.dart';
import '../services/ai_cold_start.dart';
import '../widgets/chat_v4.dart';
import 'chat_detail_page.dart';

/// 祁小山 · AI 咨询会话页（设计稿 site/design/ai-entry-v3.html 第 5 节）
///
/// 入口（2026-10-04 tab 化）：底栏中间凸起按钮 → **shell 内的一个分支**（`HomeShell`
/// 的 `IndexedStack`，底栏常驻）；找陪玩页「问祁小山」也走同一条分支。
/// 页头没有返回箭头（tab 不需要）；只有作为 push 路由（独立使用 / 测试，`activeSignal == null`）时才保留。
///
/// ## 视觉：一行都不另立一套
/// 复用已定稿的 v4 聊天（`widgets/chat_v4.dart`）：
/// - `ChatV4Header`（56 高 + 发丝线 + 名字 15.5/w600 + 副标题 11）
/// - `ChatV4MessageList`（气泡圆角 14 / 尾角 / 节奏 6-18-24 / 时间只在同批末条 / 顶部触底补拉）
/// - `ChatV4Item` / `ChatV4Peer` / `ChatV4Metrics` / `ChatV4Palette`
/// 本页**新增**的只有设计稿点名属于「祁小山」的四件：自我介绍空态、快捷问题 chips、
/// 生成中「3 点 + 停止」、答不了时的「转人工客服」卡（外加错误态重发行）。
///
/// ## 状态机（发送 / 流式 / 停止 / 转人工 / 错误 / 历史分页）
/// ```
/// 发送:  本地占位(pending 时钟) → POST /user/ai/chat → accepted(双勾) → 生成中(3 点)
/// 流式:  WS ai:chunk(delta 追加) → WS ai:done(content 覆盖为准) → 生成中结束
/// 停止:  输入栏「停止」→ POST /user/ai/stop → 本地立即收尾（无内容则撤掉等待气泡，有内容标「已停止」）
///        → 该 messageId 进入 _stopped，后到的 chunk/done 一律忽略
/// 转人工: 答不了(ai:error) / 用户点名要人工 / WS ai:handoff → 答案下方「转人工客服」卡
///        → POST /user/ai/handoff（或 WS 已给 csConversationId）→ push 既有客服会话页（复用 ChatDetailPage）
/// 错误:  POST 失败 → 我方气泡下「发送失败 · 点这里重发」`AppColors.error`（同 idempotencyKey 重发，服务端幂等）
/// 历史:  进页 GET /user/ai/messages → 顶部触底 beforeSeq 倒序补拉（复用 v4 列表的视口保持逻辑）
/// ```
///
/// ## 会话生命周期（负责人 2026-10-04 改版定稿：**只有冷启动轮换**）
/// ```
/// 进入本页:   initState → bootstrap: 等冷启动初始化落定（AiColdStart.settled）→ 拉 config + 历史
///            **不 reset** —— 同一次运行内再进来要看到刚才的对话
/// 切走本页:   分支失活（activeSignal=false）→ 生成中则 POST /user/ai/stop 打断上游；**不 reset**、
///            不清消息（页面常驻，回来还是原来那段对话；消息由本页自己持有，shell 不做任何缓存）
/// 页面销毁:   dispose（push 方式被 pop）→ 同样只 stop，不 reset
/// 冷启动:     App 大退后重新打开 → `AiColdStart.ensureResetOnce()` 发一次 POST /user/ai/reset
///            → 服务端换 current_session → 本次运行看到全新对话（旧数据一条不删，管理端仍可查）
/// 兜底:       冷启动 reset 失败（离线）时，本进程第一次加载若发现服务端 session 还是本机
///            **上次已展示过**的那条（AiSessionTrace）→ 按空会话渲染，等价于"大退后为空"
/// ```
///
/// ## 数据源边界
/// 页面只依赖 [AiChatSource] / [AiRealtime]（`lib/services/ai_chat_service.dart`）——
/// 后端接口微调时**只改数据源，不改本页与 UI**。
class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key, this.api, this.source, this.realtime, this.activeSignal});

  /// 透传给客服会话页（测试注入用；不传则各页自建）
  final ApiClient? api;

  /// 数据源（测试注入；生产走 HTTP 实现）
  final AiChatSource? source;

  /// 实时事件通道（测试注入；生产走全局 RealtimeClient 单例）
  final AiRealtime? realtime;

  /// **分支激活信号**（tab 化用）：`HomeShell` 持有，AI 分支激活 = true、切走 = false。
  ///
  /// - 传了（tab 模式）：页面常驻，失活时只停生成、不 reset、不清消息；页头无返回箭头
  /// - 不传（push 模式：独立使用 / 测试）：与既有行为一致，弹栈时 dispose → 只 stop
  final ValueListenable<bool>? activeSignal;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final AiChatSource _source = widget.source ?? HttpAiChatSource(api: _api);
  late final AiRealtime _bus = widget.realtime ?? SocketAiRealtime();

  /// 消息序列（本页唯一业务状态；渲染时映射成 ChatV4Item）
  final List<_AiMsg> _msgs = [];

  /// 快捷问题（来自 /user/ai/config；取不到用本地兜底）
  List<String> _presets = kAiFallbackPresets;
  AiChatConfig _config = const AiChatConfig();

  String? _conversationId;

  /// 服务端**当前 session**（`GET /user/ai/messages` / `POST /user/ai/chat` 下发）。
  /// 会话轮换（`POST /user/ai/reset`）后服务端会换一个新 uuid：本页只认与它一致的 WS 事件，
  /// 上一次会话的迟到 chunk/done 一律丢弃（不会在新会话里冒出来）。null = 服务端没给（老接口/假数据）。
  String? _sessionId;

  /// 转人工后的客服会话 id（WS ai:handoff 或 POST /user/ai/handoff 给）
  String? _csConversationId;

  int _oldestSeq = 0;

  /// 本页当前是否处于**激活的分支**（tab 模式看 [AiChatPage.activeSignal]）。
  ///
  /// push 模式（activeSignal == null）恒为 true = 既有语义；tab 模式下页面常驻，
  /// 失活（用户切到别的 tab）时 WS 事件一律不上屏 —— 等价于 push 模式里"页面已被 dispose"。
  bool _active = true;

  /// 服务端 `hasMore`（null/true = 还能往上翻）
  bool _hasMoreHistory = true;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 生成中（输入栏右侧由「发送」变「停止」）
  bool _generating = false;
  String? _generatingId;

  /// 已被「停止」的答案 id（后到的 chunk/done 不再改写它）
  final Set<String> _stopped = {};

  /// 当前答案的转人工理由（asked = 用户点名要人工；failed = AI 答不了）
  final Map<String, String> _handoffReason = {};

  bool _handoffBusy = false;

  final TextEditingController _input = TextEditingController();
  final List<void Function()> _offEvents = [];

  String get _meId => AuthStore.instance.me?.id ?? 'me';

  @override
  void initState() {
    super.initState();
    final signal = widget.activeSignal;
    _active = signal?.value ?? true;
    signal?.addListener(_onBranchActiveChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    widget.activeSignal?.removeListener(_onBranchActiveChanged);
    for (final off in _offEvents) {
      off();
    }
    _input.dispose();
    // 页面真的销毁（push 方式被 pop）= 这次生成没人看了 → 只打断上游，**不轮换会话**
    //（轮换只发生在冷启动，见 [AiColdStart]；dispose 不能 await、也不再碰 context，失败静默）。
    _stopOnExit();
    super.dispose();
  }

  /// 分支激活/失活（tab 化：页面常驻，`dispose` 不再触发 → 生命周期挂在这里）
  ///
  /// - **切走**（false）：生成中先 `POST /user/ai/stop` 打断上游（页面不可见了，继续生成没意义）；
  ///   **不 reset、不清消息** —— 同一次运行内切回来要看到刚才那段对话。
  ///   顺带收回焦点：常驻页面的输入框不会随分支隐藏而失焦，否则键盘会跟到别的 tab 上面。
  /// - **切回**（true）：什么都不做。消息、滚动、输入内容都是本页自己的状态，原样保留。
  void _onBranchActiveChanged() {
    final next = widget.activeSignal?.value ?? true;
    if (next == _active) return; // 同一个值重复通知（例如连点当前 tab）不当成一次切换
    _active = next;
    if (next) return;
    if (_generating) unawaited(_stop());
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// 页面销毁时"尽力而为"地停掉这次生成（fire-and-forget，不改任何 state）
  void _stopOnExit() {
    final token = AuthStore.instance.accessToken;
    if (token == null || !_generating) return;
    final cid = _conversationId;
    if (cid == null || cid.isEmpty) return;
    unawaited(
      _source.stop(token, conversationId: cid, messageId: _generatingId).catchError((Object _) {}),
    );
  }

  // -------------------------------------------------------------------------
  // 初始化：拉 config（chips 文案）+ 拉当前 session 的历史 —— **不 reset**
  //（会话轮换只在冷启动发生一次：[AiColdStart]）
  // -------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      setState(() {
        _error = '未登录';
        _loading = false;
      });
      return;
    }
    _setupRealtime(token);
    unawaited(_loadConfig(token));
    // 冷启动那次 reset 还在飞的时候**不许**先拉历史：否则上一条会话的消息会先铺上屏、
    // 随后被新 session 顶掉 —— 用户看到"旧对话闪一下"。没发过请求时它是完成的 Future，等于没等。
    // 等待**有上限**：弱网下 reset 卡住时不能让整个页面停在 loading（5 秒后照常拉历史）。
    await AiColdStart.settled.timeout(const Duration(seconds: 5), onTimeout: () {});
    if (!mounted) return;
    await _loadHistory(token);
  }

  void _setupRealtime(String token) {
    _bus.connect(token: token);
    _offEvents.add(_bus.on('ai:chunk', _onChunk));
    _offEvents.add(_bus.on('ai:done', _onDone));
    _offEvents.add(_bus.on('ai:error', _onError));
    _offEvents.add(_bus.on('ai:handoff', _onHandoff));
  }

  Future<void> _loadConfig(String token) async {
    try {
      final cfg = await _source.loadConfig(token);
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _presets = cfg.presets;
      });
    } on ApiException {
      // 配置拉不到不阻断：chips 用本地兜底文案
    }
  }

  /// 首拉历史 —— 服务端已按**当前 session** 过滤（换 session 后旧对话不再下发），这里再做两道客户端兜底：
  ///
  /// ① **冷启动 reset 没发出去也要空**：[AiColdStart.takeColdStartStaleGuard] 只在"本进程第一次加载历史
  ///    且这次冷启动没轮换成功"时放行 —— 此时服务端返回的还是本机**上次已展示过**的 session
  ///    （[AiSessionTrace] 记忆，安全存储尽力持久化）→ 一律不显示，等价于"大退后为空"。
  ///    同一次运行里的后续加载**不再**走这条路：切走再切回来必须看到刚才的对话。
  ///    旧消息一条不删，管理端照旧可查。
  /// ② **只显示当前 session 的消息**：即便服务端漏过滤，session 对不上的消息也不上屏。
  Future<void> _loadHistory(String token) async {
    try {
      final page = await _source.loadMessages(token);
      if (!mounted) return;
      final sid = page.sessionId ?? '';
      final coldStartGuard = AiColdStart.takeColdStartStaleGuard();
      final stale = coldStartGuard && sid.isNotEmpty && sid == await AiSessionTrace.seenFor(_meId);
      final scoped = sid.isEmpty
          ? page.items
          : page.items.where((m) => m.sessionId == null || m.sessionId == sid).toList();
      final shown = stale ? const <AiMessage>[] : scoped;
      if (sid.isNotEmpty) await AiSessionTrace.remember(_meId, sid);
      if (!mounted) return;
      setState(() {
        _error = null;
        _loading = false;
        if (sid.isNotEmpty) _sessionId = sid;
        if (page.conversationId != null && page.conversationId!.isNotEmpty) {
          _conversationId = page.conversationId;
        }
        _msgs
          ..clear()
          ..addAll(shown.map(_fromHistory));
        _oldestSeq = shown.isEmpty
            ? 0
            : shown.map((e) => e.seq).where((s) => s > 0).fold<int>(1 << 30, (a, b) => a < b ? a : b);
        if (_oldestSeq == 1 << 30) _oldestSeq = 0;
        // 兜底隐藏时不允许再往上翻（否则会把上一条会话的旧消息翻回来）
        _hasMoreHistory = stale ? false : (page.hasMore ?? true);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  _AiMsg _fromHistory(AiMessage m) => _AiMsg(
        id: m.id,
        mine: m.fromMe,
        text: m.content,
        at: m.at,
        seq: m.seq > 0 ? m.seq : (m.fromMe ? 1 : 0),
        readByPeer: m.fromMe,
      );

  /// 顶部触底：拉更早的历史（beforeSeq = 当前最旧 seq）
  Future<void> _loadMore() async {
    final token = AuthStore.instance.accessToken;
    if (token == null || _loadingMore || _oldestSeq <= 0 || !_hasMoreHistory) return;
    _loadingMore = true;
    try {
      final page = await _source.loadMessages(token, conversationId: _conversationId, beforeSeq: _oldestSeq);
      final known = _msgs.map((m) => m.id).toSet();
      final older = page.items.where((e) => !known.contains(e.id)).map(_fromHistory).toList();
      if (!mounted) return;
      setState(() {
        _hasMoreHistory = page.hasMore ?? true;
        if (older.isEmpty) return;
        _msgs.insertAll(0, older);
        final seqs = older.map((m) => m.seq).where((s) => s > 0);
        if (seqs.isNotEmpty) {
          final minSeq = seqs.reduce((a, b) => a < b ? a : b);
          if (minSeq > 0) _oldestSeq = minSeq;
        }
      });
    } on ApiException {
      // 静默：下次触底再试
    } finally {
      _loadingMore = false;
    }
  }

  // -------------------------------------------------------------------------
  // 发送 / 流式 / 停止
  // -------------------------------------------------------------------------

  /// 是否像在点名要人工（设计稿：用户不满可直接给转人工卡）
  static bool _looksLikeAskingHuman(String text) {
    final t = text.trim();
    return t.contains('人工') || t.contains('客服') || t.contains('投诉');
  }

  Future<void> _send(String raw) async {
    final token = AuthStore.instance.accessToken;
    final text = raw.trim();
    if (token == null || text.isEmpty || _generating) return;
    final msg = _AiMsg(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      mine: true,
      text: text,
      at: DateTime.now(),
      pending: true,
      idempotencyKey: generateIdempotencyKey(),
    );
    _input.clear();
    setState(() => _msgs.add(msg));
    await _dispatch(token, msg);
  }

  /// POST /user/ai/chat（重发复用同一 idempotencyKey → 服务端幂等不会重复入库）
  ///
  /// ⚠️ 契约要点（2026-10-04 联调确认）：响应里的 `messageId` 是**这次 AI 回复**的 id，
  /// 不是用户消息 id —— 用户气泡保留本地 id，只用它去认领回答（chunk 可能比响应先到，按 id 归并）。
  Future<void> _dispatch(String token, _AiMsg msg) async {
    setState(() {
      msg.pending = true;
      msg.failed = false;
      msg.failReason = null;
    });
    try {
      final r = await _source.send(
        token,
        message: msg.text,
        conversationId: _conversationId,
        idempotencyKey: msg.idempotencyKey,
      );
      if (!mounted) return;
      setState(() {
        msg.pending = false;
        msg.failed = false;
        msg.seq = 1;
        msg.readByPeer = true; // 服务端已受理 → 双勾（设计稿我方气泡带双勾）
        if (r.conversationId.isNotEmpty) _conversationId = r.conversationId;
        // 服务端回执带当前 session（reset 之后是新 uuid）→ 之后只认这条 session 的 WS 事件
        if (r.sessionId != null && r.sessionId!.isNotEmpty) _sessionId = r.sessionId;
        _generating = true;
        _generatingId = r.messageId.isEmpty ? msg.id : r.messageId;
        if (_looksLikeAskingHuman(msg.text)) _handoffReason[_generatingId!] = 'asked';
      });
      _ensureWaiting(_generatingId!);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        msg.pending = false;
        msg.failed = true;
        // 错误码 → 中文（不写「网络异常」这类空话；限流用服务端给的具体秒数）
        msg.failReason = friendlyAiError(e.errorCode, e.message);
        // 会话对不上（400）：清掉本地 conversationId，重发就会开一条新会话
        if (e.errorCode == 'AI_CONVERSATION_MISMATCH') _conversationId = null;
        _generating = false;
        _generatingId = null;
      });
    }
  }

  /// 重发（气泡下「发送失败 · 点这里重发」）
  Future<void> _retry(_AiMsg msg) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    await _dispatch(token, msg);
  }

  _AiMsg _ensureWaiting(String id) {
    final idx = _msgs.indexWhere((m) => !m.mine && m.id == id);
    if (idx >= 0) return _msgs[idx];
    final msg = _AiMsg(id: id, mine: false, text: '', at: DateTime.now(), waiting: true);
    _msgs.add(msg);
    return msg;
  }

  /// 停止生成（POST /user/ai/stop）
  Future<void> _stop() async {
    final token = AuthStore.instance.accessToken;
    final id = _generatingId;
    setState(() {
      _generating = false;
      _generatingId = null;
      if (id != null) {
        _stopped.add(id);
        final idx = _msgs.indexWhere((m) => !m.mine && m.id == id);
        if (idx >= 0) {
          final m = _msgs[idx];
          m.waiting = false;
          // 一点内容都没来 → 撤掉等待气泡（不留空壳）；有半截内容 → 保留并标「已停止」
          if (m.text.trim().isEmpty) {
            _msgs.removeAt(idx);
          } else {
            m.stopped = true;
          }
        }
      }
    });
    final cid = _conversationId;
    if (token == null || cid == null || cid.isEmpty) return;
    try {
      await _source.stop(token, conversationId: cid, messageId: id);
    } on ApiException {
      // 停止是「尽力而为」：本地已经收尾，服务端失败不弹错（下次提问会重新走一遍）
    }
  }

  // -------------------------------------------------------------------------
  // WS 事件（契约见任务书）
  // -------------------------------------------------------------------------

  ({String conversationId, String sessionId, String messageId, String delta}) _chunkOf(dynamic data) {
    final m = data is Map ? data : const {};
    return (
      conversationId: '${m['conversationId'] ?? ''}',
      sessionId: '${m['sessionId'] ?? ''}',
      messageId: '${m['messageId'] ?? ''}',
      delta: '${m['delta'] ?? ''}',
    );
  }

  /// 事件是否属于本页当前会话：**会话 + session 双重判定**。
  /// session 对不上 = 上一次会话的迟到事件（例如切走时刚发起的那次生成）→ 丢弃，不在当前会话里冒出来；
  /// 任一侧为空（服务端没给 / 还没拿到）则按原语义接受，避免丢真事件。
  bool _belongsToPage(String conversationId, String sessionId) {
    if (conversationId.isNotEmpty) {
      final cur = _conversationId;
      if (cur != null && cur.isNotEmpty && cur != conversationId) return false;
    }
    if (sessionId.isNotEmpty) {
      final cur = _sessionId;
      if (cur != null && cur.isNotEmpty && cur != sessionId) return false;
    }
    return true;
  }

  /// 事件是否该上屏：页面（分支）不可见时一律不上屏 ——
  /// tab 化后页面常驻，`mounted` 不再能代表"用户看得见"，用 [_active] 代替
  /// （否则切走后迟到的 chunk 会把 [_generating] 重新点着，切回来看到的是一个早已死掉的「停止」键）。
  bool get _canRender => mounted && _active;

  void _onChunk(dynamic data) {
    final e = _chunkOf(data);
    if (!_canRender || _stopped.contains(e.messageId) || !_belongsToPage(e.conversationId, e.sessionId)) return;
    if (e.messageId.isEmpty) return;
    setState(() {
      final ans = _ensureWaiting(e.messageId);
      ans.waiting = false;
      ans.text += e.delta;
      _generating = true;
      _generatingId = e.messageId;
    });
  }

  void _onDone(dynamic data) {
    final e = _chunkOf(data);
    if (!_canRender || _stopped.contains(e.messageId)) return;
    if (!_belongsToPage(e.conversationId, e.sessionId)) return;
    final map = data is Map ? data : const {};
    final content = '${map['content'] ?? ''}';
    setState(() {
      final ans = _ensureWaiting(e.messageId);
      ans.waiting = false;
      if (content.isNotEmpty) ans.text = content; // 服务端 content 为准
      // 停止（服务端回 done{stopped:true}）：留半截内容 + 「已停止」
      if (map['stopped'] == true) {
        ans.stopped = true;
        _stopped.add(e.messageId);
      }
      // 降级（先 ai:error 再 done{degraded:true}）：气泡用规则答复，提示条保留在下方
      if (map['degraded'] == true) ans.handoff = true;
      // 用户点名要人工 → 回答落地后把「转人工客服」卡摆出来（不用等 AI 说答不了）
      if (_handoffReason[e.messageId] == 'asked') ans.handoff = true;
      _generating = false;
      _generatingId = null;
    });
  }

  /// WS `ai:error`：契约里它是**提示条**（降级时后面还会跟一条 `ai:done` 给规则答复）
  void _onError(dynamic data) {
    if (!_canRender) return;
    final e = _chunkOf(data);
    if (_stopped.contains(e.messageId) || !_belongsToPage(e.conversationId, e.sessionId)) return;
    final map = data is Map ? data : const {};
    final code = '${map['code'] ?? ''}';
    final notice = friendlyAiError(code, '${map['message'] ?? ''}');
    setState(() {
      final ans = _ensureWaiting(e.messageId);
      ans.waiting = false;
      ans.notice = notice;
      // 一个字都没来（真错误、非降级）→ 气泡里给一句能接话的，再把「转人工」摆出来
      if (ans.text.trim().isEmpty) ans.text = notice;
      ans.handoff = code != 'AI_RATE_LIMITED' && code != 'AI_INPUT_TOO_LONG';
      _handoffReason[e.messageId] = 'failed';
      _generating = false;
      _generatingId = null;
    });
  }

  void _onHandoff(dynamic data) {
    if (!_canRender) return;
    final m = data is Map ? data : const {};
    final cs = '${m['csConversationId'] ?? ''}';
    final mid = '${m['messageId'] ?? ''}';
    setState(() {
      if (cs.isNotEmpty) _csConversationId = cs;
      final idx = mid.isEmpty ? _msgs.lastIndexWhere((x) => !x.mine) : _msgs.indexWhere((x) => !x.mine && x.id == mid);
      if (idx >= 0) {
        _msgs[idx].handoff = true;
        _handoffReason[_msgs[idx].id] ??= 'asked';
      }
    });
  }

  // -------------------------------------------------------------------------
  // 转人工：成功 → 跳到既有客服会话页（复用 ChatDetailPage 与它的路由参数）
  // -------------------------------------------------------------------------

  Future<void> _handoff(_AiMsg ans) async {
    if (_handoffBusy) return;
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    setState(() => _handoffBusy = true);
    var cs = _csConversationId;
    if (cs == null || cs.isEmpty) {
      final cid = _conversationId;
      if (cid != null && cid.isNotEmpty) {
        try {
          cs = await _source.handoff(token, conversationId: cid, messageId: ans.id);
        } on ApiException catch (e) {
          if (mounted) AppToast.info(context, e.message);
        }
      }
    }
    if (!mounted) return;
    setState(() => _handoffBusy = false);
    if (cs == null || cs.isEmpty) {
      AppToast.info(context, '客服这会儿没接上，过会儿再点一次');
      return;
    }
    _csConversationId = cs;
    await _openCsPage(cs);
  }

  /// 空态（服务端 enabled=false）用：还没开过 AI 会话也能转人工 ——
  /// 先试 `/user/ai/handoff`，没有会话就退回既有客服入口 `GET /user/conversation`（自动建会话）。
  Future<void> _handoffByConversation() async {
    if (_handoffBusy) return;
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    setState(() => _handoffBusy = true);
    var cs = _csConversationId;
    final cid = _conversationId;
    try {
      if ((cs == null || cs.isEmpty) && cid != null && cid.isNotEmpty) {
        cs = await _source.handoff(token, conversationId: cid);
      }
      if (cs == null || cs.isEmpty) {
        final resp = await _api.request('GET', '/user/conversation', token: token);
        final id = '${(resp['data'] as Map<String, dynamic>?)?['id'] ?? ''}';
        if (id.isNotEmpty) cs = id;
      }
    } on ApiException catch (e) {
      if (mounted) AppToast.info(context, e.message);
    }
    if (!mounted) return;
    setState(() => _handoffBusy = false);
    if (cs == null || cs.isEmpty) {
      AppToast.info(context, '客服这会儿没接上，过会儿再点一次');
      return;
    }
    _csConversationId = cs;
    await _openCsPage(cs);
  }

  /// 跳既有客服会话页（参数与消息页 `_openChat` 一致）：**不新建第二套聊天页**
  Future<void> _openCsPage(String csId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatDetailPage(
          conversationId: csId,
          title: '联系客服',
          csConversation: true,
          peerNickname: '祁连山客服',
          api: widget.api,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  /// 业务消息 → v4 渲染项（footer 在 build 里现挂，保证回调永远指向当前 state）
  List<ChatV4Item> _renderItems() => _msgs
      .map((m) => ChatV4Item(
            id: m.id,
            text: m.text,
            isMine: m.mine,
            senderId: m.mine ? _meId : 'qishan',
            at: m.at,
            seq: m.seq,
            pending: m.pending,
            failed: m.failed,
            waiting: m.waiting,
            readByPeer: m.readByPeer,
            footer: _footer(m),
          ))
      .toList();

  Widget? _footer(_AiMsg m) {
    if (m.failed) return _failLine(m);
    final parts = <Widget>[
      // 提示条（WS ai:error / AI_STOPPED）：与气泡正文重复时不重复渲染
      if (m.notice != null && m.notice!.trim().isNotEmpty && m.notice != m.text) _noticeLine(m.notice!),
      if (m.stopped)
        Text('已停止', style: TextStyle(fontSize: 10.5, color: ChatV4Palette.of(context).textTertiary)),
      if (m.handoff) _handoffCard(m),
    ];
    if (parts.isEmpty) return null;
    if (parts.length == 1) return parts.first;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          parts[i],
        ],
      ],
    );
  }

  /// 发送失败时气泡下的红字：默认设计稿文案；有服务端错误码时换成具体原因 + 同一个重发动作
  Widget _failLine(_AiMsg m) {
    final reason = m.failReason;
    final text = reason == null || reason == '发送失败' ? '发送失败 · 点这里重发' : '$reason · 点这里重发';
    return GestureDetector(
      key: const Key('ai-retry'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _retry(m),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          text,
          // 2026-10-14 品牌升级：走 token（AppColors.error = #B42318），不再硬编码旧 error #DC2626
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.error),
        ),
      ),
    );
  }

  /// AI 侧提示条（WS ai:error）：小灰字挂在气泡下，不抢气泡（降级时气泡仍用 done.content）
  ///
  /// 说明文字走 `mutedText`（白底 7.4:1），不再写死旧灰 `#98A2B3`（品牌升级后它已不是任何 token）。
  Widget _noticeLine(String notice) => Text(
        notice,
        style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText),
      );

  /// 答不了 / 用户不满 → 答案下方的转人工卡（冷灰蓝浅底 + 发丝线 + r10 + 描边按钮）
  Widget _handoffCard(_AiMsg m) {
    final reason = _handoffReason[m.id] ?? 'asked';
    final title = switch (reason) {
      'failed' => '这单我答不上来，人工能查记录',
      'asked' => '好，给你接人工客服',
      _ => '要我帮你转人工客服吗？',
    };
    return Container(
      key: const Key('ai-handoff-card'),
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      decoration: BoxDecoration(
        // 2026-10-14 品牌升级：浅底走 token `AppColors.bgPage`（#F4F6F9），
        // 不再写死旧页底色 #F5F7FB —— 写死会让"卡片比页面底色深"这个细节与全站脱钩。
        color: AppColors.bgPage,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 5),
          Text(
            // 时段来自服务端（没下发就说"尽快接入"，**不承诺时间**，见 csAvailabilityLine）
            csAvailabilityLine(serviceHours: _config.serviceHours, replyHint: _config.replyHint),
            style: const TextStyle(fontSize: 10.5, color: AppColors.textPlaceholder),
          ),
          const SizedBox(height: 11),
          GestureDetector(
            key: const Key('ai-handoff'),
            behavior: HitTestBehavior.opaque,
            onTap: _handoffBusy ? null : () => _handoff(m),
            child: Container(
              height: 30,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                // 描边按钮：一屏只允许一个实色主按钮（就是发送键）
                border: Border.all(color: AppColors.primary, width: 1),
              ),
              child: _handoffBusy
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('转人工客服',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.primary)),
            ),
          ),
        ],
      ),
    );
  }

  /// 空态（设计稿第 5 节 ②）：自我介绍 + 3 个快捷问题 chips + 转人工说明
  Widget _emptyState(ChatV4Palette c) => LayoutBuilder(
        builder: (context, cons) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, (cons.maxHeight * 0.22).clamp(24.0, 160.0), 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_config.greeting,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.textPrimary)),
              const SizedBox(height: 8),
              Text(kAiIntroSub, style: TextStyle(fontSize: 11.5, color: c.textTertiary)),
              const SizedBox(height: 20),
              Wrap(
                key: const Key('ai-presets'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in _presets)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _send(q),
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(16),
                          // 气泡/卡片描边走会话调色板（= 设计 token 的发丝线族），不再写死旧值 #E2E8F0
                          border: Border.all(color: c.hairlineStrong, width: 1),
                        ),
                        // widthFactor 1 = 胶囊按文字宽度收缩（Container 一旦带 alignment 就会撑满整行）
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            q,
                            style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              // 服务端关掉 AI（enabled=false）时，空态直接把「转人工」摆出来（后端契约第 8 条）
              if (!_config.enabled) ...[
                Container(
                  key: const Key('ai-disabled'),
                  constraints: const BoxConstraints(maxWidth: 300),
                  padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
                  decoration: BoxDecoration(
                    // 2026-10-14 品牌升级：浅底走 token `AppColors.bgPage`（#F4F6F9）+ 发丝线，不再写死旧页底色
                    color: AppColors.bgPage,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.divider, width: 1),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('祁小山这会儿没开',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                      const SizedBox(height: 5),
                      Text(csManualHandoffLine(serviceHours: _config.serviceHours),
                          style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText)),
                      const SizedBox(height: 11),
                      GestureDetector(
                        key: const Key('ai-disabled-handoff'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _handoffByConversation(),
                        child: Container(
                          height: 30,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.primary, width: 1),
                          ),
                          child: const Text('转人工客服',
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.primary)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
              ],
              Text(kAiHandoffHint, style: TextStyle(fontSize: 10.5, color: c.textTertiary)),
            ],
          ),
        ),
      );

  /// 输入栏：白底 + 顶发丝线；输入框 r18 #EFF2F7；右侧「发送」两态 / 生成中「停止」（描边）
  Widget _composer(ChatV4Palette c) {
    final active = _input.text.trim().isNotEmpty && !_generating;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(color: c.inputBg, borderRadius: BorderRadius.circular(18)),
                  child: TextField(
                    key: const Key('ai-input'),
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    // 服务端上限 500（AI_INPUT_TOO_LONG）：客户端先拦，别让用户白等一次错误
                    maxLength: _config.maxInputLength,
                    buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                    textInputAction: TextInputAction.send,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (v) => _send(v),
                    style: TextStyle(fontSize: 13.5, color: c.textPrimary, height: 1.4),
                    decoration: InputDecoration(
                      hintText: '问点什么…',
                      hintStyle: TextStyle(fontSize: 13.5, color: c.textTertiary),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_generating)
                GestureDetector(
                  key: const Key('ai-stop'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _stop,
                  child: Container(
                    height: 34,
                    constraints: const BoxConstraints(minWidth: 64),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(10),
                      // 停止键描边走会话调色板（= 设计 token 的发丝线族），不再写死旧值 #E2E8F0
                      border: Border.all(color: c.hairlineStrong, width: 1),
                    ),
                    child: Text('停止',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.textSecondary)),
                  ),
                )
              else
                GestureDetector(
                  key: const Key('ai-send'),
                  behavior: HitTestBehavior.opaque,
                  // 空内容 → 禁用态（只有样式，不响应点击）
                  onTap: active ? () => _send(_input.text) : null,
                  child: Container(
                    height: 34,
                    constraints: const BoxConstraints(minWidth: 64),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      color: active ? c.primary : c.sendDisabledBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '发送',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: active ? Colors.white : c.textTertiary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 页头头像 = 入口图标（同一枚祁山标，#DFE7F4 底 / #3A5A99 线）
  Widget _headerAvatar() => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: const BoxDecoration(color: AppQishanMark.avatarBg, shape: BoxShape.circle),
        child: const AppQishanMark(size: 17, color: AppQishanMark.avatarInk),
      );

  @override
  Widget build(BuildContext context) {
    final c = ChatV4Palette.of(context);
    final items = _renderItems();
    return Scaffold(
      backgroundColor: c.page,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: ChatV4Header(
              nickname: '祁小山',
              statusText: kAiHeaderSubtitle,
              online: false,
              statusDot: false,
              showMore: false,
              // tab 化（有分支信号）时不出现返回箭头：底栏就是导航，返回键行为也归 shell（回上一个 tab）
              showBack: widget.activeSignal == null,
              avatarOverride: _headerAvatar(),
            ),
          ),
          Expanded(
            child: _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _error = null;
                            });
                            _bootstrap();
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                : _loading
                    ? const SizedBox.shrink()
                    : items.isEmpty
                        ? _emptyState(c)
                        : ChatV4MessageList(
                            items: items,
                            peer: ChatV4Peer(nickname: '祁小山', avatarOverride: _headerAvatar()),
                            onLoadMore: _loadMore,
                            composer: _composer(c),
                          ),
          ),
          // 空态时输入栏不在列表里，单独挂在底部（有消息时由列表自带 composer）
          if (_error == null && !_loading && items.isEmpty) _composer(c),
        ],
      ),
    );
  }
}

/// 页面内部消息模型（可变：流式追加/状态翻转都在同一条上做）
///
/// 只声明「创建时就要定」的字段；`failed/stopped/handoff` 这类状态由事件翻转（默认 false）。
class _AiMsg {
  _AiMsg({
    required this.id,
    required this.mine,
    required this.text,
    required this.at,
    this.seq = 0,
    this.pending = false,
    this.waiting = false,
    this.readByPeer = false,
    this.idempotencyKey,
  });

  String id;
  final bool mine;
  String text;
  final DateTime at;
  int seq;
  bool pending;
  bool failed = false;

  /// 发送失败的具体原因（服务端 errorCode → 中文）；null = 用设计稿默认文案
  String? failReason;

  /// AI 侧提示条（WS ai:error，例如「现在问的人有点多…」）
  String? notice;
  bool waiting;
  bool stopped = false;
  bool handoff = false;
  bool readByPeer;
  final String? idempotencyKey;
}
