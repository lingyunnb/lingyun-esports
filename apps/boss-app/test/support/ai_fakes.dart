import 'dart:async';

import 'package:boss_app/services/ai_chat_service.dart';
import 'package:fish_core/fish_core.dart';

/// 测试用假数据源 / 假事件通道（**不需要后端、不需要真 socket**）
///
/// 与页面之间只隔 [AiChatSource] / [AiRealtime] 两个抽象 —— 这正是「联调只改数据源」的验证方式：
/// 假实现能跑通全部 UI 与状态机，真实现只是把同样的方法换成 HTTP/WS 调用。
class FakeAiSource implements AiChatSource {
  FakeAiSource({
    this.config = const AiChatConfig(),
    List<AiMessage>? history,
    this.olderHistory = const [],
    this.failSend = false,
    this.failStop = false,
    this.failReset = false,
    this.failHandoff = false,
    this.handoffResult = 'cs-88',
    this.sessionId,
    this.rotateOnReset = false,
    this.failLoad = false,
  }) : history = history ?? const [];

  AiChatConfig config;
  List<AiMessage> history;

  /// 补拉（beforeSeq 非空）时返回的更早历史
  List<AiMessage> olderHistory;

  /// 服务端「当前 session」（null = 老接口没给这个字段，页面的 session 兜底不生效）
  String? sessionId;

  /// **调用顺序**日志（`config` / `reset` / `messages` / `send` / `stop` / `handoff`）：
  /// 页面「进入先 reset、再拉历史」的顺序断言用它（两个独立调用列表看不出先后）。
  final List<String> order = [];

  /// 挂住 reset（可空）：置位后 [reset] 会一直等这个 Completer ——
  /// 用来验证「reset 没回来之前不拉历史、不渲染旧消息」。
  Completer<bool>? resetGate;

  /// 像真服务端一样轮换：reset 成功后换一个新 sessionId 并清空历史（默认关，老用例按固定历史返回）
  bool rotateOnReset;

  int _rotations = 0;

  bool failSend;
  bool failStop;
  bool failReset;
  bool failHandoff;

  /// 离线：`GET /user/ai/messages` / `GET /user/ai/config` 也一并失败（整页进错误态）
  final bool failLoad;

  /// 发送失败时抛的错误码（验证 errorCode → 中文 的映射）
  String failSendCode = '';

  /// 发送失败时的服务端消息
  String failSendMessage = '网络连接失败，请检查网络';

  String? handoffResult;

  final List<Map<String, dynamic>> sendCalls = [];
  final List<Map<String, dynamic>> stopCalls = [];
  final List<String> resetCalls = [];
  final List<Map<String, dynamic>> handoffCalls = [];
  final List<Map<String, dynamic>> messageCalls = [];

  int _seq = 0;

  /// 每次 send 后服务端返回的 session（会话轮换测试可断言它换新值）
  String replySessionId = 'sess-1';

  @override
  Future<AiChatConfig> loadConfig(String token) async {
    order.add('config');
    if (failLoad) throw const ApiException(-1, '网络连接失败，请检查网络', '');
    return config;
  }

  @override
  Future<AiHistoryPage> loadMessages(String token, {String? conversationId, int? beforeSeq, int limit = 20}) async {
    order.add('messages');
    messageCalls.add({'conversationId': conversationId, 'beforeSeq': beforeSeq, 'limit': limit});
    if (failLoad) throw const ApiException(-1, '网络连接失败，请检查网络', '');
    final items = beforeSeq == null ? history : olderHistory;
    return AiHistoryPage(
      conversationId: conversationId ?? 'c-1',
      sessionId: sessionId,
      items: items,
      hasMore: beforeSeq == null ? olderHistory.isNotEmpty : false,
    );
  }

  @override
  Future<AiSendResult> send(String token, {required String message, String? conversationId, String? idempotencyKey}) async {
    order.add('send');
    sendCalls.add({'message': message, 'conversationId': conversationId, 'idempotencyKey': idempotencyKey});
    if (failSend) throw ApiException(-1, failSendMessage, '', errorCode: failSendCode);
    _seq += 1;
    return AiSendResult(conversationId: 'c-1', messageId: 'ai-$_seq', sessionId: replySessionId);
  }

  @override
  Future<void> stop(String token, {required String conversationId, String? messageId}) async {
    order.add('stop');
    stopCalls.add({'conversationId': conversationId, 'messageId': messageId});
    if (failStop) throw const ApiException(-1, '网络连接失败，请检查网络', '');
  }

  @override
  Future<bool> reset(String token) async {
    order.add('reset');
    resetCalls.add(token);
    final gate = resetGate;
    if (gate != null && !await gate.future) {
      throw const ApiException(-1, '网络连接失败，请检查网络', '');
    }
    if (failReset) throw const ApiException(-1, '网络连接失败，请检查网络', '');
    if (rotateOnReset) {
      // 真服务端行为：换新 session + 旧 session 的消息不再下发（一条都没删）
      _rotations += 1;
      sessionId = 'sess-r$_rotations';
      history = const [];
      olderHistory = const [];
    }
    return true;
  }

  @override
  Future<String?> handoff(String token, {required String conversationId, String? messageId}) async {
    order.add('handoff');
    handoffCalls.add({'conversationId': conversationId, 'messageId': messageId});
    if (failHandoff) throw const ApiException(-1, '网络连接失败，请检查网络', '');
    return handoffResult;
  }
}

/// 假事件通道：测试里直接 [fire] 触发 `ai:chunk` / `ai:done` / `ai:error` / `ai:handoff`
class FakeAiRealtime implements AiRealtime {
  final Map<String, List<void Function(dynamic)>> _handlers = {};
  bool connected = false;
  String? token;

  @override
  void connect({required String token}) {
    connected = true;
    this.token = token;
  }

  @override
  void Function() on(String event, void Function(dynamic) handler) {
    _handlers.putIfAbsent(event, () => []).add(handler);
    return () => _handlers[event]?.remove(handler);
  }

  /// 触发一次事件（copy 一份，避免回调里退订导致并发修改）
  void fire(String event, dynamic data) {
    for (final h in [...?_handlers[event]]) {
      h(data);
    }
  }
}
