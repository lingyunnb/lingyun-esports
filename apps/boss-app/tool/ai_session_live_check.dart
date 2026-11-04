/// 祁小山 AI 咨询 —— **冷启动轮换真机链路**（真实后端 + 真实页面，不在默认 `flutter test` 范围内）
///
/// 负责人 2026-10-04（改版后语义）：**"强制初始化"改成"大退 App 初始化"**
/// - 同一次 App 运行内：离开 AI 页再回来，**刚才的对话还在**（不 reset）
/// - App 大退后重新打开（进程重启 = 冷启动）：**一次** `POST /user/ai/reset` → 会话为空
///
/// 跑法（后端在 127.0.0.1:3100 运行时）：
/// ```
/// cd apps/boss-app
/// flutter test tool/ai_session_live_check.dart ^
///   --dart-define=API_BASE_URL=http://127.0.0.1:3100/api/v1 ^
///   --dart-define=WS_BASE_URL=http://127.0.0.1:3100
/// ```
/// 它走客户端自己的栈（`ApiClient` + `HttpAiChatSource` + 真实 `AiChatPage` + 真 socket），断言：
/// 1. **冷启动** → `AiColdStart.ensureResetOnce()` 恰好 1 次 `POST /user/ai/reset`（服务端 session 换新）
/// 2. 进 AI 页 → 空会话（开场白 + 服务端 chips），**不再因为"进入"而 reset**
/// 3. 点 chip 提问 → 出流式回答（页面消息 ≥ 2），服务端该 session 有 ≥ 2 条
/// 4. **切走（分支失活）→ 切回（分支激活）**：页面消息数不变（**同一次运行内对话保留**），reset 仍是 1 次
/// 5. 服务端证据：sessionId 与提问时**同一条**（切走/切回没有轮换）
/// 6. **模拟下一次冷启动**（进程重启）→ 第 2 次 reset → 服务端 session 换新、历史为空
/// 7. 冷启动后打开页面 → 消息数 = 0（大退后为空），开场白 + chips 照常
///
/// 联调账号命名 `qishan_cold_<时间戳>`，跑完用
/// `node scripts/tmp/ai-session-live-cleanup.js` 清理（专用清理脚本，不改动其他账号）。
library;

import 'dart:io';

import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/services/ai_cold_start.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录 reset/stop 调用（联调要能**证明**"只有冷启动发了一次 reset"，而不是靠肉眼推断）
class _LoggingSource implements AiChatSource {
  _LoggingSource(this._inner);

  final AiChatSource _inner;
  int resetCount = 0;
  final List<String?> stopMessageIds = [];

  @override
  Future<AiChatConfig> loadConfig(String token) => _inner.loadConfig(token);

  @override
  Future<AiHistoryPage> loadMessages(String token, {String? conversationId, int? beforeSeq, int limit = 20}) =>
      _inner.loadMessages(token, conversationId: conversationId, beforeSeq: beforeSeq, limit: limit);

  @override
  Future<AiSendResult> send(String token, {required String message, String? conversationId, String? idempotencyKey}) =>
      _inner.send(token, message: message, conversationId: conversationId, idempotencyKey: idempotencyKey);

  @override
  Future<void> stop(String token, {required String conversationId, String? messageId}) {
    stopMessageIds.add(messageId);
    // ignore: avoid_print
    print('[客户端] POST /user/ai/stop（打断上游）messageId=$messageId');
    return _inner.stop(token, conversationId: conversationId, messageId: messageId);
  }

  @override
  Future<bool> reset(String token) async {
    resetCount += 1;
    // ignore: avoid_print
    print('[客户端] POST /user/ai/reset（第 $resetCount 次 —— 只应来自冷启动初始化）');
    final r = await _inner.reset(token);
    // ignore: avoid_print
    print('[客户端] POST /user/ai/reset → ok=$r');
    return r;
  }

  @override
  Future<String?> handoff(String token, {required String conversationId, String? messageId}) =>
      _inner.handoff(token, conversationId: conversationId, messageId: messageId);
}

void main() {
  // flutter_test 默认把所有 HTTP 打成 400（防误连网）；真联调要放开
  setUp(() => HttpOverrides.global = null);

  final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
  final username = 'qishan_cold_$stamp';
  const password = 'Probe#2026';

  /// 页面上的消息数（空态时没有 ChatV4MessageList → 0）
  int pageMessages(WidgetTester tester) {
    final lists = tester.widgetList<ChatV4MessageList>(find.byType(ChatV4MessageList));
    return lists.isEmpty ? 0 : lists.single.items.length;
  }

  testWidgets('祁小山会话生命周期：冷启动 1 次 reset → 提问 → 切走再切回对话仍在 → 再冷启动为空', (tester) async {
    final api = ApiClient(); // 默认地址 = AppConfig.apiBase（`baseUrl:` 形参已删除）
    final raw = HttpAiChatSource(api: api);
    final source = _LoggingSource(raw);
    late String token;
    late AiChatConfig cfg;
    String? sessionBeforeColdStart;
    String? sessionAfterFirstAsk;
    String? sessionAfterSecondColdStart;

    // ---------- 1. 联调小号：注册 + 登录 + 服务端 config ----------
    await tester.runAsync(() async {
      // ignore: avoid_print
      print('== API_BASE_URL=${AppConfig.apiBaseUrl} / WS=${AppConfig.wsBaseUrl} ==');
      final reg = await api.request('POST', '/auth/register',
          data: {'username': username, 'password': password, 'nickname': '祁小山冷启动联调'});
      // ignore: avoid_print
      print('[1] POST /auth/register → code=${reg['code']} message=${reg['message']}');
      final login = await api.request('POST', '/auth/login',
          data: {'username': username, 'password': password, 'role': 'user'});
      token = '${(login['data'] as Map<String, dynamic>)['accessToken']}';
      // ignore: invalid_use_of_visible_for_testing_member
      AuthStore.instance.debugSetSession(accessToken: token);
      cfg = await raw.loadConfig(token);
      final page0 = await raw.loadMessages(token);
      sessionBeforeColdStart = page0.sessionId;
      // ignore: avoid_print
      print('[1] 登录成功 user=$username token=${token.substring(0, 12)}…');
      // ignore: avoid_print
      print('[2] GET /user/ai/config → greeting=「${cfg.greeting}」presets=${cfg.presets} maxInputLength=${cfg.maxInputLength}');
      // ignore: avoid_print
      print('[3] 冷启动前 GET /user/ai/messages → 条数=${page0.items.length} sessionId=$sessionBeforeColdStart（新号还没有会话）');
    });

    /// 真实异步等待（网络/WS 都在 runAsync 里跑，需要手动 pump 刷新）
    Future<void> settle(int rounds) async {
      for (var i = 0; i < rounds; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    // ---------- 2. 冷启动初始化：**一次** POST /user/ai/reset ----------
    // 进程刚刚开始（= 大退后重新打开）：AiColdStart 的进程内标记是干净的
    // ignore: invalid_use_of_visible_for_testing_member
    AiColdStart.debugResetRun();
    await tester.runAsync(() => AiColdStart.ensureResetOnce(source: source));
    await tester.runAsync(() => settle(6));
    // ignore: avoid_print
    print('[4] 冷启动初始化：POST /user/ai/reset 次数=${source.resetCount}（必须 = 1）· rotated=${AiColdStart.rotatedThisRun}');
    expect(source.resetCount, 1, reason: '冷启动必须恰好轮换一次会话');
    expect(AiColdStart.rotatedThisRun, isTrue, reason: '服务端已受理 reset');

    // 再调一次（模拟 shell 重新挂载 / tab 切换 / hot restart 之外的一切）：不能重复发
    await tester.runAsync(() => AiColdStart.ensureResetOnce(source: source));
    expect(source.resetCount, 1, reason: '一次运行只发一次（进程内一次性标记）');

    await tester.runAsync(() async {
      final page = await raw.loadMessages(token);
      // ignore: avoid_print
      print('[4] 冷启动后 GET /user/ai/messages → 条数=${page.items.length} sessionId=${page.sessionId}'
          '（冷启动前=$sessionBeforeColdStart；没有消息时服务端不下发 sessionId，新号前后都是 null 属正常）');
      expect(page.items.length, 0, reason: '冷启动轮换 → 用户侧空会话');
    });

    // ---------- 3. 进 AI 页（tab 模式：有分支信号 = 底栏常驻那种） ----------
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(MaterialApp(
      home: AiChatPage(source: source, realtime: SocketAiRealtime(), api: api, activeSignal: active),
    ));
    await tester.runAsync(() => settle(30));
    // ignore: avoid_print
    print('[5] 进入 AI 页：reset 次数=${source.resetCount}（进入不再轮换）· 消息数=${pageMessages(tester)}'
        '（空态，服务端 ${cfg.presets.length} 个 chips）· 返回箭头=${find.byIcon(AppIcon.arrowLeft).evaluate().isNotEmpty}');
    expect(source.resetCount, 1, reason: '进入 AI 页**不再** reset');
    expect(find.text(cfg.greeting), findsOneWidget, reason: '空态首句用服务端 greeting');
    for (final q in cfg.presets) {
      expect(find.text(q), findsOneWidget, reason: '快捷问题用服务端 presets：$q');
    }
    expect(pageMessages(tester), 0);
    expect(find.byIcon(AppIcon.arrowLeft), findsNothing, reason: 'tab 化的 AI 页没有返回箭头');

    // ---------- 4. 点 chip 提问 → 等生成结束 ----------
    await tester.tap(find.text(cfg.presets.first));
    await tester.pump();
    var waited = 0;
    await tester.runAsync(() async {
      while (waited < 600) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waited += 1;
        if (waited > 5 && find.byKey(const Key('ai-stop')).evaluate().isEmpty) break;
      }
    });
    final afterAsk = pageMessages(tester);
    final bubbles = tester
        .widgetList<Text>(find.descendant(of: find.byType(ChatV4MessageList), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('[6] 点 chip「${cfg.presets.first}」提问 → 等待 ${waited * 100}ms 生成结束，页面消息数=$afterAsk');
    for (final b in bubbles) {
      // ignore: avoid_print
      print('[6]   气泡・${b.replaceAll('\n', ' ').substring(0, b.length.clamp(0, 60))}');
    }
    expect(afterAsk, greaterThanOrEqualTo(2), reason: '提问 + 回答都要在页面上');

    await tester.runAsync(() async {
      final page = await raw.loadMessages(token);
      sessionAfterFirstAsk = page.sessionId;
      // ignore: avoid_print
      print('[7] 提问后 GET /user/ai/messages → 条数=${page.items.length} sessionId=$sessionAfterFirstAsk');
      expect(page.items.length, greaterThanOrEqualTo(2), reason: '这轮问答已经在服务端落库（历史留档供质检）');
    });

    // ---------- 5. 切走（分支失活）→ 切回（分支激活）：对话必须还在，且不 reset ----------
    active.value = false; // 用户点了别的 tab
    await tester.pumpAndSettle();
    await tester.runAsync(() => settle(4));
    // ignore: avoid_print
    print('[8] 切走（AI 分支失活）：reset 次数=${source.resetCount}（切走不轮换）· '
        'stop 次数=${source.stopMessageIds.length}（没在生成就不发 stop）');
    expect(source.resetCount, 1, reason: '切走 AI 页**不**轮换会话');

    active.value = true; // 用户点回中间凸起
    await tester.pumpAndSettle();
    await tester.runAsync(() => settle(6));
    final reentered = pageMessages(tester);
    // ignore: avoid_print
    print('[9] 切回（AI 分支激活）：消息数=$reentered（必须与切走前一致 = 同一次运行内对话保留）· '
        'reset 次数=${source.resetCount}');
    expect(reentered, afterAsk, reason: '同一次运行内切回来必须还能看到刚才的对话');
    expect(source.resetCount, 1, reason: '切回也不轮换；reset 只来自冷启动');
    expect(find.byType(ChatV4MessageList), findsOneWidget);

    // 服务端证据：session 没被换掉（还是提问时那条）
    await tester.runAsync(() async {
      final page = await raw.loadMessages(token);
      // ignore: avoid_print
      print('[9] 切走切回后 GET /user/ai/messages → 条数=${page.items.length} sessionId=${page.sessionId}'
          '（提问时=$sessionAfterFirstAsk）');
      expect(page.sessionId, sessionAfterFirstAsk, reason: '切走/切回都没有轮换 session');
      expect(page.items.length, greaterThanOrEqualTo(2), reason: '历史还在（就是页面上那段对话）');
    });

    // ---------- 6. 模拟**下一次冷启动**（大退后重新打开）→ 第 2 次 reset → 会话为空 ----------
    // 服务端 reset 有 2 秒防抖（Redis `SET NX EX 2`）：等它过期，保证这次是真轮换
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    // ignore: invalid_use_of_visible_for_testing_member
    AiColdStart.debugResetRun(); // 进程重启 = 大退后重新打开
    await tester.runAsync(() => AiColdStart.ensureResetOnce(source: source));
    await tester.runAsync(() => settle(6));
    // ignore: avoid_print
    print('[10] 第二次冷启动：POST /user/ai/reset 次数=${source.resetCount}（必须 = 2）· rotated=${AiColdStart.rotatedThisRun}');
    expect(source.resetCount, 2, reason: '新的冷启动才再轮换一次');

    // 冷启动后重新进页面（先卸载，避免复用同一个 State）
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await tester.pumpWidget(MaterialApp(
      home: AiChatPage(source: source, realtime: SocketAiRealtime(), api: api, activeSignal: active),
    ));
    await tester.runAsync(() => settle(30));
    final afterColdStart = pageMessages(tester);
    // ignore: avoid_print
    print('[11] 冷启动后进入 AI 页：消息数=$afterColdStart（必须为 0）· 开场白=${find.text(cfg.greeting).evaluate().isNotEmpty} '
        'chips=${cfg.presets.where((q) => find.text(q).evaluate().isNotEmpty).length}/${cfg.presets.length}');
    expect(afterColdStart, 0, reason: '大退后重新打开 → AI 会话是空的');
    expect(find.byType(ChatV4MessageList), findsNothing, reason: '不能闪现上一次的对话');
    expect(find.text(cfg.greeting), findsOneWidget, reason: '开场白照常');
    expect(find.byKey(const Key('ai-presets')), findsOneWidget, reason: '快捷问题照常');

    await tester.runAsync(() async {
      final page = await raw.loadMessages(token);
      sessionAfterSecondColdStart = page.sessionId;
      // ignore: avoid_print
      print('[12] 冷启动后 GET /user/ai/messages → 条数=${page.items.length} sessionId=$sessionAfterSecondColdStart'
          '（提问时=$sessionAfterFirstAsk）');
      expect(page.items.length, 0);
      expect(sessionAfterSecondColdStart, isNot(sessionAfterFirstAsk), reason: '冷启动的 reset 必须真的轮换 session');
    });

    // 收尾①：显式销毁页面（tab 化后 dispose 只 stop，不再有 fire-and-forget reset）
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    await tester.runAsync(() => settle(25));

    // 收尾②：断开真实 WS + 关掉 Dio 的 HttpClient 连接池
    // （否则 socket.io 心跳与 HttpClient keep-alive 的 3 秒 idle Timer 会让 testWidgets 报 pending timer）
    await tester.runAsync(() async {
      RealtimeClient.shared.disconnect();
      api.dio.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(seconds: 4));
    // ignore: avoid_print
    print('[13] 联调账号（跑完请清理）：$username；客户端累计 reset 调用 ${source.resetCount} 次'
        '（= 两次冷启动；进入/切走/切回/销毁都不发）');
    expect(source.resetCount, 2, reason: '全程只有两次冷启动各一次 reset');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
