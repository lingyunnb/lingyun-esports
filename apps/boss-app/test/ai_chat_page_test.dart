import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ai_fakes.dart';

/// 祁小山 AI 会话页（设计稿 site/design/ai-entry-v3.html 第 5 节）
///
/// 覆盖任务书点名要测的五态 + 历史：
/// ① 空态 3 chips + 禁用态发送键 ② 发送 → 我方气泡 → ai:chunk/ai:done → 回答
/// ③ 生成中「停止」 ④ 答不了 → 「转人工客服」 ⑤ 错误态「发送失败 · 点这里重发」 ⑥ 历史（进页首拉 + 顶部触底补拉）
void main() {
  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  /// 客服会话页（转人工跳转目标）用的空数据 ApiClient
  ApiClient csApi() {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter();
    return ApiClient(dio: dio);
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required FakeAiSource source,
    required FakeAiRealtime bus,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: AiChatPage(api: csApi(), source: source, realtime: bus),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('ai-input')), text);
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pumpAndSettle();
  }

  testWidgets('① 空态：自我介绍 + 3 个快捷问题 chips + 禁用态发送键（config 拿不到就用本地兜底）', (tester) async {
    final source = FakeAiSource(failSend: false)..config = const AiChatConfig();
    final bus = FakeAiRealtime();
    // 配置接口失败 → chips 必须回落到本地三条兜底文案
    await tester.pumpWidget(MaterialApp(
      home: AiChatPage(
        api: csApi(),
        source: _ConfigFailingSource(source),
        realtime: bus,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(kAiIntroTitle), findsOneWidget);
    expect(find.text(kAiIntroSub), findsOneWidget);
    for (final q in kAiFallbackPresets) {
      expect(find.text(q), findsOneWidget, reason: '空态必须有快捷问题：$q');
    }
    expect(find.byKey(const Key('ai-presets')), findsOneWidget);
    expect(find.text(kAiHandoffHint), findsOneWidget);

    // 发送键禁用态：空输入 → 点它没有任何反应（不产生消息、不调发送接口）
    final send = tester.widget<Container>(
      find.descendant(of: find.byKey(const Key('ai-send')), matching: find.byType(Container)).first,
    );
    expect((send.decoration! as BoxDecoration).color, AppColors.disabledBg,
        reason: '空输入时发送键应为禁用底色 token（2026-10-16 方案 F 收敛为 AppColors.disabledBg）');
    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pumpAndSettle();
    expect(source.sendCalls, isEmpty);
    expect(find.byType(ChatV4MessageList), findsNothing, reason: '空输入点发送不应该冒出任何消息');
  });

  testWidgets('①b 空态 chips 文案来自 /user/ai/config presets（服务端给了就用服务端的）', (tester) async {
    final source = FakeAiSource()
      ..config = const AiChatConfig(presets: ['超时怎么算', '怎么取消订单']);
    await pumpPage(tester, source: source, bus: FakeAiRealtime());

    expect(find.text('超时怎么算'), findsOneWidget);
    expect(find.text('怎么取消订单'), findsOneWidget);
    expect(find.text('怎么下单'), findsNothing, reason: '服务端给了 presets 就不再用本地兜底');
  });

  testWidgets('② 发送：我方气泡 + 生成中 3 点等待 + ai:chunk 流式 + ai:done 定稿', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    // 点空态的 chips 也能直接提问（快捷问题的价值就在这里）
    await tester.tap(find.text('怎么下单'));
    await tester.pumpAndSettle();
    expect(source.sendCalls.single['message'], '怎么下单');
    expect(source.sendCalls.single['idempotencyKey'], isNotNull, reason: '发送必须带幂等键（重发复用同一个）');

    // 我方气泡（实色主色）
    expect(find.text('怎么下单'), findsWidgets);
    expect(find.byType(ChatV4MessageList), findsOneWidget);

    // 服务端受理 → 生成中：出现 3 点等待气泡 + 输入栏「停止」
    expect(find.byKey(const Key('ai-stop')), findsOneWidget);
    expect(find.byKey(const Key('ai-send')), findsNothing);
    expect(find.byType(ChatV4MessageList), findsOneWidget);

    // 流式：两次 chunk 累积
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '按官方自营的平均数据，'});
    await tester.pumpAndSettle();
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '铂金 2 到钻石大约 6–8 局。'});
    await tester.pumpAndSettle();
    expect(find.textContaining('铂金 2 到钻石大约 6–8 局'), findsOneWidget);

    // 定稿：done 的 content 覆盖为服务端权威内容；生成中结束 → 发送键回来
    bus.fire('ai:done', {'conversationId': 'c-1', 'messageId': 'ai-1', 'content': '铂金 2 到钻石大约 6–8 局，看队友。'});
    await tester.pumpAndSettle();
    expect(find.text('铂金 2 到钻石大约 6–8 局，看队友。'), findsOneWidget);
    expect(find.byKey(const Key('ai-stop')), findsNothing);
    expect(find.byKey(const Key('ai-send')), findsOneWidget);
  });

  testWidgets('③ 生成中：右侧「停止」调 POST /user/ai/stop，且等待气泡收尾（无内容不留空壳）', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '那超时了会扣积分吗');
    expect(find.byKey(const Key('ai-stop')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-stop')));
    await tester.pumpAndSettle();

    expect(source.stopCalls.single['conversationId'], 'c-1');
    expect(source.stopCalls.single['messageId'], 'ai-1');
    expect(find.byKey(const Key('ai-stop')), findsNothing);
    expect(find.byKey(const Key('ai-send')), findsOneWidget);
    // 停止后迟到的 chunk/done 不再改写页面（不冒出新气泡）
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '迟到的内容'});
    bus.fire('ai:done', {'conversationId': 'c-1', 'messageId': 'ai-1', 'content': '迟到定稿'});
    await tester.pumpAndSettle();
    expect(find.textContaining('迟到'), findsNothing);
  });

  testWidgets('③b 生成中已有半截内容时按停止：保留内容并标「已停止」', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '能指定打手吗');
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '可以在下单备注里写'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-stop')));
    await tester.pumpAndSettle();

    expect(find.textContaining('可以在下单备注里写'), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
  });

  testWidgets('④ 答不了（ai:error）→ 答案下方「转人工客服」卡 → 成功后跳既有客服会话页', (tester) async {
    final source = FakeAiSource(handoffResult: 'cs-88');
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '昨天那单打手一直没上号，能退吗');
    bus.fire('ai:error', {'conversationId': 'c-1', 'messageId': 'ai-1', 'code': 'UPSTREAM', 'message': '上游超时'});
    await tester.pumpAndSettle();

    // 卡片：浅底 + 发丝线 + 描边按钮（不是实色主按钮）
    expect(find.byKey(const Key('ai-handoff-card')), findsOneWidget);
    expect(find.text('转人工客服'), findsOneWidget);
    expect(find.textContaining('这单我答不上来'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-handoff')));
    await tester.pumpAndSettle();

    expect(source.handoffCalls.single['conversationId'], 'c-1');
    expect(source.handoffCalls.single['messageId'], 'ai-1');
    // 复用既有客服会话页（不新建第二套聊天页）
    expect(find.byType(ChatDetailPage), findsOneWidget);
    final page = tester.widget<ChatDetailPage>(find.byType(ChatDetailPage));
    expect(page.conversationId, 'cs-88');
    expect(page.csConversation, isTrue);
  });

  testWidgets('④b 用户点名要人工 → 回答下方也给转人工卡（不用等 AI 说答不了）', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '我要找人工客服');
    bus.fire('ai:done', {'conversationId': 'c-1', 'messageId': 'ai-1', 'content': '好，点下面这个按钮。'});
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai-handoff-card')), findsOneWidget);
    expect(find.text('好，给你接人工客服'), findsOneWidget);
  });

  testWidgets('⑤ 错误态：发送失败 → 「发送失败 · 点这里重发」#DC2626 → 重发复用同一幂等键', (tester) async {
    final source = FakeAiSource(failSend: true);
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '超时了会扣积分吗');
    expect(find.text('发送失败 · 点这里重发'), findsOneWidget);
    final err = tester.widget<Text>(find.text('发送失败 · 点这里重发'));
    expect(err.style!.color, const Color(0xFFB42318));
    expect(err.style!.fontWeight, FontWeight.w600);
    // 失败后不生成本地等待气泡
    expect(find.byKey(const Key('ai-stop')), findsNothing);

    final firstKey = source.sendCalls.single['idempotencyKey'];
    source.failSend = false;
    await tester.tap(find.byKey(const Key('ai-retry')));
    await tester.pumpAndSettle();

    expect(source.sendCalls.length, 2);
    expect(source.sendCalls.last['idempotencyKey'], firstKey, reason: '重发必须复用同一 idempotencyKey（服务端幂等）');
    expect(find.text('发送失败 · 点这里重发'), findsNothing);
    expect(find.byKey(const Key('ai-stop')), findsOneWidget);
  });

  testWidgets('⑥ 历史：进页面先拉 /user/ai/messages；顶部触底用 beforeSeq 补拉更早历史', (tester) async {
    final source = FakeAiSource(
      history: [
        for (var i = 1; i <= 30; i++)
          AiMessage(
            id: 'h$i',
            fromMe: i.isOdd,
            content: '第 $i 条历史消息',
            at: DateTime(2026, 10, 4, 21, 0).add(Duration(minutes: i)),
            seq: i,
          ),
      ],
      olderHistory: [
        AiMessage(id: 'h0', fromMe: false, content: '更早的：我是祁小山', at: DateTime(2026, 10, 4, 20, 0), seq: 0),
      ],
    );
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    // 首拉不带 beforeSeq
    expect(source.messageCalls.first['beforeSeq'], isNull);
    expect(find.text('第 30 条历史消息'), findsOneWidget);
    expect(find.text(kAiIntroTitle), findsNothing, reason: '有历史就不显示空态');

    // 拖到顶部 → onLoadMore → beforeSeq = 最旧 seq
    await tester.drag(find.byType(ChatV4MessageList), const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(source.messageCalls.any((c) => c['beforeSeq'] == 1), isTrue,
        reason: '顶部触底补拉必须带 beforeSeq（最旧 seq），实际调用：${source.messageCalls}');
    // 排空列表内部的 800ms 防抖 Timer（否则测试结束时会报 pending timer）
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('⑦ 后端契约：messageId 是「AI 回复 id」→ 不能覆盖我方消息 id；chunk 早于响应也能按 id 归并', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await tester.enterText(find.byKey(const Key('ai-input')), '怎么下单');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pumpAndSettle();

    // 服务端给 messageId=ai-1（AI 回复 id）→ 页面用它认领回答；我方气泡 id 仍是本地占位，
    // 若被覆盖，chunk 归并会把「回答」当「我方消息」从而渲染错位
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '先选分部'});
    await tester.pumpAndSettle();
    final items = tester.widgetList<ChatV4MessageList>(find.byType(ChatV4MessageList)).single.items;
    expect(items.length, 2, reason: '一条我方提问 + 一条回答（id 冲突会丢消息）');
    expect(items.where((i) => i.isMine).length, 1);
    expect(items.first.text, '怎么下单');
    expect(items.last.isMine, isFalse);
    expect(items.last.text, '先选分部');
    expect(items.map((i) => i.id).toSet().length, 2, reason: '我方气泡与回答不得同 id');
  });

  testWidgets('⑧ 降级：先 ai:error 再 ai:done{degraded} → error 只当提示条，气泡用 done.content', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '退款要多久');
    bus.fire('ai:error', {'conversationId': 'c-1', 'messageId': 'ai-1', 'code': 'AI_BUSY', 'message': ''});
    await tester.pumpAndSettle();
    bus.fire('ai:done', {
      'conversationId': 'c-1',
      'messageId': 'ai-1',
      'content': '退款审核通过后 1–3 个工作日到账。这单要走人工核对，点下面的按钮。',
      'degraded': true,
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('退款审核通过后'), findsOneWidget, reason: '降级后气泡仍用 done.content');
    expect(find.text('现在问的人有点多，过一会儿再问我'), findsOneWidget, reason: 'error 落成提示条');
    expect(find.byKey(const Key('ai-handoff-card')), findsOneWidget, reason: '降级答复要带转人工出口');
  });

  testWidgets('⑨ errorCode → 中文：限流用服务端秒数、超长给动作（不是「网络异常」这类空话）', (tester) async {
    final source = FakeAiSource(failSend: true)
      ..failSendCode = 'AI_RATE_LIMITED'
      ..failSendMessage = '还有 12 秒后再问';
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '在吗');
    expect(find.text('还有 12 秒后再问 · 点这里重发'), findsOneWidget);

    // 超长：换服务端错误码 → 同一位置换文案（仍可重发）
    source.failSendCode = 'AI_INPUT_TOO_LONG';
    source.failSendMessage = '消息过长';
    await tester.tap(find.byKey(const Key('ai-retry')));
    await tester.pumpAndSettle();
    expect(find.text('问题太长了，砍到 500 字以内再发我 · 点这里重发'), findsOneWidget);
    // 契约映射表本身
    expect(friendlyAiError('AI_DISABLED', ''), contains('人工客服'));
    expect(friendlyAiError('AI_CONVERSATION_MISMATCH', ''), contains('重新问'));
    // 通用失败：不给「网络连接失败，请检查网络」这类空话，按设计稿文案 + 动作
    expect(friendlyAiError('', '网络连接失败，请检查网络'), '发送失败');
  });

  testWidgets('⑩ 停止后服务端回 done{stopped:true}：半截内容保留 + 「已停止」（不覆盖用户已看到的）', (tester) async {
    final source = FakeAiSource();
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    await typeAndSend(tester, '能指定打手吗');
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '可以在备注里写'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ai-stop')));
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);

    // 停止后的迟到事件一律忽略（含 done{stopped:true}），避免回答在用户按停后又长出来
    bus.fire('ai:done', {'conversationId': 'c-1', 'messageId': 'ai-1', 'content': '更长的完整答复', 'stopped': true});
    await tester.pumpAndSettle();
    expect(find.text('更长的完整答复'), findsNothing);
    expect(find.textContaining('可以在备注里写'), findsOneWidget);
  });

  testWidgets('⑪ 服务端 enabled=false：页面仍可进，但空态直接给「转人工客服」出口', (tester) async {
    final source = FakeAiSource()..config = const AiChatConfig(enabled: false);
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    expect(find.byKey(const Key('ai-disabled')), findsOneWidget);
    expect(find.text('祁小山这会儿没开'), findsOneWidget);
    expect(find.byKey(const Key('ai-disabled-handoff')), findsOneWidget);
  });

  testWidgets('⑫ config 的 greeting/maxInputLength 都生效（开场白与 500 字上限由服务端下发）', (tester) async {
    final source = FakeAiSource()
      ..config = const AiChatConfig(greeting: '我是祁小山，今天想聊点什么？', maxInputLength: 30);
    await pumpPage(tester, source: source, bus: FakeAiRealtime());

    expect(find.text('我是祁小山，今天想聊点什么？'), findsOneWidget);
    expect(find.text(kAiIntroTitle), findsNothing);
    final field = tester.widget<TextField>(find.byKey(const Key('ai-input')));
    expect(field.maxLength, 30);
  });
}

/// 只在 loadConfig 上抛错的包装（验证 chips 兜底路径）
class _ConfigFailingSource implements AiChatSource {
  _ConfigFailingSource(this._inner);

  final AiChatSource _inner;

  @override
  Future<AiChatConfig> loadConfig(String token) async => throw const ApiException(-1, '网络连接失败，请检查网络', '');

  @override
  Future<AiHistoryPage> loadMessages(String token, {String? conversationId, int? beforeSeq, int limit = 20}) =>
      _inner.loadMessages(token, conversationId: conversationId, beforeSeq: beforeSeq, limit: limit);

  @override
  Future<AiSendResult> send(String token, {required String message, String? conversationId, String? idempotencyKey}) =>
      _inner.send(token, message: message, conversationId: conversationId, idempotencyKey: idempotencyKey);

  @override
  Future<void> stop(String token, {required String conversationId, String? messageId}) =>
      _inner.stop(token, conversationId: conversationId, messageId: messageId);

  @override
  Future<bool> reset(String token) => _inner.reset(token);

  @override
  Future<String?> handoff(String token, {required String conversationId, String? messageId}) =>
      _inner.handoff(token, conversationId: conversationId, messageId: messageId);
}

/// 客服会话页的极小 fixture（进页只需不崩：空历史 + 空 info）
class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = jsonEncode({'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': <dynamic>[]}});
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
