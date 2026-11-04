/// 祁小山 AI 咨询 —— **真实后端联调**（不在默认 `flutter test` 范围内，手动跑）
///
/// 跑法（后端在 127.0.0.1:3100 运行时）：
/// ```
/// cd apps/boss-app
/// flutter test tool/ai_live_check.dart ^
///   --dart-define=API_BASE_URL=http://127.0.0.1:3100/api/v1 ^
///   --dart-define=WS_BASE_URL=http://127.0.0.1:3100
/// ```
/// 它**走客户端自己的栈**：`ApiClient` + `RealtimeClient` + `HttpAiChatSource`（页面用的同一个数据源），
/// 因此验证的是「客户端实现 ↔ 服务端实现」的真实契约，而不是另一套用 curl 拼的请求。
///
/// 输出（原样打印，报告直接引用）：
/// 1. 注册/登录 → 拿真 token（联调小号，用户名带时间戳，不与人工账号冲突）
/// 2. `GET /user/ai/config` 原文
/// 3. `POST /user/ai/chat` 原文 + WS `ai:chunk` 条数 / 首字延迟 / `ai:done` 全文
/// 4. `GET /user/ai/messages` 原文（校验落库与 seq 升序）
/// 5. `POST /user/ai/stop` 打断 + 服务端回执（`ai:done{stopped}` 或 `ai:error{AI_STOPPED}`）
/// 6. `POST /user/ai/handoff` 原文（csConversationId）
library;

import 'dart:convert';
import 'dart:io';

import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // flutter_test 默认把所有 HTTP 打成 400（防误连网）；真联调要放开。
  // 必须放在 setUp 里：testWidgets 会在初始化 TestWidgetsFlutterBinding 时重新装回 mock 覆盖。
  setUp(() => HttpOverrides.global = null);

  final stamp = DateTime.now().millisecondsSinceEpoch % 1000000;
  final username = 'qishan_probe_$stamp';
  const password = 'Probe#2026';

  late ApiClient api;
  String token = '';
  String conversationId = '';
  final chunks = <String>[];
  String? doneContent;
  Map<String, dynamic>? doneRaw;
  Map<String, dynamic>? errorRaw;
  Map<String, dynamic>? handoffEvent;
  DateTime? sentAt;
  Duration? firstChunkAfter;

  test('祁小山 AI 真机链路（真实后端）', () async {
    // `ApiClient` 的 `baseUrl:` 形参已被删除（见 core/api_client.dart 构造函数注释）：
    // 裸 `ApiClient()` 的默认地址就是 `AppConfig.apiBase`（= 运行期下发地址 ?? AppConfig.apiBaseUrl），
    // 与本脚本原先显式传入的地址**同源** —— 去掉形参不改变目标地址，只去掉一个已废弃的旋钮。
    api = ApiClient();
    // ignore: avoid_print
    print('== API_BASE_URL = ${AppConfig.apiBaseUrl} / WS = ${AppConfig.wsBaseUrl} ==');

    // ---------- 1. 联调小号：注册 + 登录 ----------
    final reg = await api.request('POST', '/auth/register',
        data: {'username': username, 'password': password, 'nickname': '祁小山联调'});
    // ignore: avoid_print
    print('[1] POST /auth/register → ${jsonEncode(reg)}');

    final login = await api.request('POST', '/auth/login',
        data: {'username': username, 'password': password, 'role': 'user'});
    final loginData = login['data'] as Map<String, dynamic>;
    token = '${loginData['accessToken']}';
    // ignore: avoid_print
    print('[1] POST /auth/login → code=${login['code']} uid=${loginData['user']?['uid']} '
        'token=${token.isEmpty ? '空' : '${token.substring(0, 18)}…(${token.length} 字符)'}');
    expect(token.isNotEmpty, isTrue, reason: '登录必须拿到 accessToken');

    // tool/ 不是 test/ 目录，analyze 会把 debugSetSession 当成生产误用：这里确实是一次性联调脚本
    // ignore: invalid_use_of_visible_for_testing_member
    AuthStore.instance.debugSetSession(accessToken: token);

    // ---------- 2. 配置 ----------
    final source = HttpAiChatSource(api: api);
    final config = await source.loadConfig(token);
    // ignore: avoid_print
    print('[2] GET /user/ai/config → enabled=${config.enabled} maxInputLength=${config.maxInputLength} '
        'greeting=${config.greeting} presets=${config.presets}');

    // ---------- 3. WS 订阅（真实 RealtimeClient，单例一条连接） ----------
    final bus = SocketAiRealtime();
    bus.connect(token: token);
    bus.on('ai:chunk', (data) {
      final m = data as Map;
      if (firstChunkAfter == null && sentAt != null) {
        firstChunkAfter = DateTime.now().difference(sentAt!);
      }
      chunks.add('${m['delta']}');
      if (chunks.length <= 3) {
        // ignore: avoid_print
        print('[3] WS ai:chunk#${chunks.length} → ${jsonEncode(m)}');
      }
    });
    bus.on('ai:done', (data) {
      doneRaw = Map<String, dynamic>.from(data as Map);
      doneContent = '${doneRaw!['content']}';
      // ignore: avoid_print
      print('[3] WS ai:done → ${jsonEncode(data)}');
    });
    bus.on('ai:error', (data) {
      errorRaw = Map<String, dynamic>.from(data as Map);
      // ignore: avoid_print
      print('[3] WS ai:error → ${jsonEncode(data)}');
    });
    bus.on('ai:handoff', (data) {
      handoffEvent = Map<String, dynamic>.from(data as Map);
      // ignore: avoid_print
      print('[6] WS ai:handoff → ${jsonEncode(data)}');
    });
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // ---------- 4. 提问 ----------
    sentAt = DateTime.now();
    final sendWatch = Stopwatch()..start();
    final sent = await source.send(token, message: '怎么下单？大概几步能开始打');
    sendWatch.stop();
    conversationId = sent.conversationId;
    // ignore: avoid_print
    print('[4] POST /user/ai/chat → conversationId=${sent.conversationId} '
        'messageId=${sent.messageId}(= 本次 AI 回复 id) accepted=${sent.accepted} 耗时 ${sendWatch.elapsedMilliseconds}ms');

    // 等 done（最多 60s；GLM-4-Flash 正常 2–6s）
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (doneContent == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('[4] WS 汇总：chunk 条数=${chunks.length} 首字延迟=${firstChunkAfter?.inMilliseconds}ms '
        'done=${doneContent == null ? '未收到（超时）' : '已收到'}');
    if (chunks.isNotEmpty) {
      // ignore: avoid_print
      print('[4] 流式累积（前 120 字）→ ${chunks.join().substring(0, chunks.join().length.clamp(0, 120))}');
    }
    // ignore: avoid_print
    print('[4] 最终回答（done.content 原文）→ $doneContent');
    expect(doneContent, isNotNull, reason: '真实后端必须回 ai:done');

    // ---------- 5. 历史落库 ----------
    final page = await source.loadMessages(token, conversationId: conversationId, limit: 10);
    // ignore: avoid_print
    print('[5] GET /user/ai/messages → hasMore=${page.hasMore} 条数=${page.items.length}');
    for (final m in page.items) {
      // ignore: avoid_print
      print('[5]   seq=${m.seq} ${m.fromMe ? '我' : '祁小山'} id=${m.id} → '
          '${m.content.replaceAll('\n', ' ').substring(0, m.content.length.clamp(0, 60))}');
    }
    expect(page.items.length, greaterThanOrEqualTo(2), reason: '提问与回答都应落库');

    // ---------- 6. 停止（先发一条，1.2s 后打断） ----------
    chunks.clear();
    doneContent = null;
    errorRaw = null;
    final sent2 = await source.send(token, message: '那三角洲行动端游和手游的价目差多少？说详细点', conversationId: conversationId);
    sentAt = DateTime.now();
    // ignore: avoid_print
    print('[7] 第二条 POST /user/ai/chat → messageId=${sent2.messageId}');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final beforeStop = chunks.length;
    await source.stop(token, conversationId: conversationId, messageId: sent2.messageId);
    // ignore: avoid_print
    print('[7] POST /user/ai/stop → 已发（停止前已收 $beforeStop 条 chunk）');
    final stopDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (doneContent == null && errorRaw == null && DateTime.now().isBefore(stopDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('[7] 停止回执 → done=${doneContent == null ? '无' : '有 stopped=${doneRaw?['stopped']}'} '
        'error=${errorRaw == null ? '无' : jsonEncode(errorRaw)}');

    // ---------- 7. 转人工 ----------
    final cs = await source.handoff(token, conversationId: conversationId);
    // ignore: avoid_print
    print('[8] POST /user/ai/handoff → csConversationId=$cs');
    if (handoffEvent != null) {
      // ignore: avoid_print
      print('[8] WS 也下发了 ai:handoff → ${jsonEncode(handoffEvent)}');
    }
    expect(cs, isNotNull, reason: '转人工必须返回客服会话 id');

    await Future<void>.delayed(const Duration(seconds: 1));
    if (errorRaw != null && errorRaw!['message'] != null) {
      // ignore: avoid_print
      print('[9] 提示：出现 ai:error=${jsonEncode(errorRaw)} → 客户端映射为「${friendlyAiError('${errorRaw!['code']}', '${errorRaw!['message']}')}」');
    }
    RealtimeClient.shared.disconnect();
  }, timeout: const Timeout(Duration(minutes: 3)));

  // -------------------------------------------------------------------------
  // 真实后端 + **真实页面**：不用任何假实现，跑一遍「进页面 → 点 chip → 出回答」
  // -------------------------------------------------------------------------
  testWidgets('真实后端 + 真实页面：空态来自服务端 config，点 chip 后页面真的长出回答', (tester) async {
    final api2 = ApiClient(); // 同上：默认地址 = AppConfig.apiBase
    late String tk;
    late AiChatConfig cfg;
    final pageSource = HttpAiChatSource(api: api2);

    // ⚠️ testWidgets 跑在 FakeAsync 里：真实网络 I/O 必须放进 runAsync，否则永远等不到
    await tester.runAsync(() async {
      final reg2 = await api2.request('POST', '/auth/register',
          data: {'username': 'qishan_page_$stamp', 'password': password, 'nickname': '祁小山页面联调'});
      expect(reg2['code'], 0);
      final login2 = await api2.request('POST', '/auth/login',
          data: {'username': 'qishan_page_$stamp', 'password': password, 'role': 'user'});
      tk = '${(login2['data'] as Map<String, dynamic>)['accessToken']}';
      // ignore: invalid_use_of_visible_for_testing_member
      // ignore: invalid_use_of_visible_for_testing_member
      AuthStore.instance.debugSetSession(accessToken: tk);
      cfg = await pageSource.loadConfig(tk);
    });
    // ignore: avoid_print
    print('=== 页面联调：服务端 config greeting=「${cfg.greeting}」 presets=${cfg.presets} ===');

    await tester.pumpWidget(MaterialApp(
      home: AiChatPage(source: pageSource, realtime: SocketAiRealtime(), api: api2),
    ));

    // runAsync = 真实异步（网络/WS），内部手动 pump 让页面刷新
    Future<void> settle(int rounds) async {
      for (var i = 0; i < rounds; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await tester.runAsync(() => settle(30));
    // 空态：开场白与 chips 都来自服务端
    expect(find.text(cfg.greeting), findsOneWidget, reason: '空态首句必须用服务端 greeting');
    for (final q in cfg.presets) {
      expect(find.text(q), findsOneWidget, reason: '快捷问题必须用服务端 presets：$q');
    }
    // ignore: avoid_print
    print('=== 页面联调：空态渲染 OK（服务端 ${cfg.presets.length} 个 chips）');

    // 点第一个 chip 提问
    await tester.tap(find.text(cfg.presets.first));
    await tester.pump();
    var waited = 0;
    await tester.runAsync(() async {
      // 等到「停止」消失（生成结束）或超时 60s
      while (waited < 600) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waited += 1;
        if (waited > 5 && find.byKey(const Key('ai-stop')).evaluate().isEmpty) break;
      }
    });
    // ignore: avoid_print
    print('=== 页面联调：等待 ${waited * 100}ms 后生成结束 ===');

    // 读出页面上真实渲染出来的气泡文字
    final bubbles = tester
        .widgetList<Text>(find.descendant(of: find.byType(ChatV4MessageList), matching: find.byType(Text)))
        .map((t) => t.data ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('=== 页面联调：页面上的气泡文字 ${bubbles.length} 条 ===');
    for (final b in bubbles) {
      // ignore: avoid_print
      print('===   ・$b');
    }
    expect(bubbles.any((b) => b == cfg.presets.first), isTrue, reason: '我方提问要上屏');
    expect(bubbles.any((b) => b.length > 20), isTrue, reason: '服务端的真实回答要出现在页面上');
    expect(find.byKey(const Key('ai-stop')), findsNothing, reason: '生成结束后「停止」要收回「发送」');
    expect(find.byKey(const Key('ai-send')), findsOneWidget);

    // 收尾：断开真实 WS（否则 socket_io 的心跳 Timer 会让 testWidgets 报 pending timer）
    await tester.runAsync(() async {
      RealtimeClient.shared.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
