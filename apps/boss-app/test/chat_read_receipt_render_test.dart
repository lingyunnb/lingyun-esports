import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 已读回执 + 系统消息渲染（负责人 2026-10-04）
///
/// 覆盖三条渲染路径（页面业务逻辑不变，这里只锁渲染契约）：
/// - pending（未收服务端 ACK）→ 时钟
/// - 已 ACK、对方未读 → **单勾**；对方已读位点 >= 本条 seq → **双勾**
/// - msgType='system'（订单节点）→ 居中中性灰 chip（文案直出）
///
/// 勾的判定靠 `CustomPaint.size` 区分：单勾 Size(10,9) / 双勾 Size(15,9)。
void main() {
  ChatV4Item item({
    required bool isMine,
    required int seq,
    String text = '消息',
    bool pending = false,
    bool system = false,
  }) =>
      ChatV4Item(
        id: 'm$seq$text',
        text: text,
        isMine: isMine,
        senderId: isMine ? 'me' : 'peer',
        at: DateTime(2026, 10, 4, 10, 0),
        seq: seq,
        pending: pending,
        system: system,
      );

  Future<void> pumpPage(WidgetTester tester, List<ChatV4Item> items, {int peerReadSeq = 0}) async {
    await tester.pumpWidget(MaterialApp(
      home: ChatV4Page(
        nickname: '对端',
        statusText: '在线',
        items: items,
        peerReadSeq: peerReadSeq,
        onSend: (_) {},
        onPickImage: () {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  bool hasSize(WidgetTester tester, Size size) =>
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).any((w) => w.size == size);

  testWidgets('我方消息 pending → 时钟（不是单勾/双勾）', (tester) async {
    await pumpPage(tester, [item(isMine: true, seq: 0, text: '发送中', pending: true)]);
    expect(tester.takeException(), isNull);
    expect(find.text('发送中'), findsOneWidget);
    expect(find.byIcon(AppIcon.clock), findsOneWidget);
    expect(hasSize(tester, const Size(10, 9)), isFalse, reason: 'pending 不应出现单勾');
    expect(hasSize(tester, const Size(15, 9)), isFalse, reason: 'pending 不应出现双勾');
  });

  testWidgets('已 ACK 且对方未读 → 单勾；对方已读位点 >= seq → 双勾', (tester) async {
    // 对方位点 0：单勾
    await pumpPage(tester, [item(isMine: true, seq: 7, text: '已送达未读')]);
    expect(tester.takeException(), isNull);
    expect(hasSize(tester, const Size(10, 9)), isTrue, reason: '应有单勾');
    expect(hasSize(tester, const Size(15, 9)), isFalse);
    expect(find.byIcon(AppIcon.clock), findsNothing);

    // 对方位点 7 >= seq 7：双勾
    await pumpPage(tester, [item(isMine: true, seq: 7, text: '对方已读')], peerReadSeq: 7);
    expect(hasSize(tester, const Size(15, 9)), isTrue, reason: '应有双勾');
    expect(hasSize(tester, const Size(10, 9)), isFalse);

    // 位点差一条（6 < 7）：仍单勾（不允许提前变双勾）
    await pumpPage(tester, [item(isMine: true, seq: 7, text: '还差一条')], peerReadSeq: 6);
    expect(hasSize(tester, const Size(10, 9)), isTrue);
    expect(hasSize(tester, const Size(15, 9)), isFalse);
  });

  testWidgets('系统消息（订单节点）→ 居中中性灰 chip，文案直出', (tester) async {
    await pumpPage(tester, [
      item(isMine: true, seq: 1, text: '好的'),
      item(isMine: false, seq: 2, text: '护航员已接单 · 单号 0087', system: true),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.text('护航员已接单 · 单号 0087'), findsOneWidget);
    // 系统行不上头像、不带我方勾：只有上面那条我方消息的勾
    expect(tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where((w) => w.size == const Size(10, 9) || w.size == const Size(15, 9)).length, 1);
  });

  group('页面接线（ChatDetailPage + conversationInfo.peerReadSeq）', () {
    setUp(() {
      RealtimeClient.shared.debugDisabled = true;
      AppSettings.debugStorageDisabled = true;
      AuthStore.instance.debugSetSession(accessToken: 'test-token');
      // SWR 缓存是进程级单例：不清会把上一个用例的 info（peerReadSeq）串到下一个用例
      ApiCache.instance.clear();
    });
    tearDown(() {
      RealtimeClient.shared.debugDisabled = false;
      AppSettings.debugStorageDisabled = false;
      AuthStore.instance.debugSetSession();
      ApiCache.instance.clear();
    });

    ApiClient apiWith(int peerReadSeq, {int infoDelayMs = 0}) {
      final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
      dio.httpClientAdapter = _Adapter({
        '/user/conversations/75/messages': {
          'code': 0, 'message': 'ok',
          'data': {
            'list': [
              {'msgId': 'm1', 'seq': 1, 'senderType': 'user', 'senderId': 'me', 'msgType': 'text', 'content': '我发的', 'recalled': false, 'createdAt': '2026-10-04T02:00:00.000Z'},
              {'msgId': 'm2', 'seq': 2, 'senderType': 'user', 'senderId': 'other', 'msgType': 'text', 'content': '对方回的', 'recalled': false, 'createdAt': '2026-10-04T02:01:00.000Z'},
              {'msgId': 'm3', 'seq': 3, 'senderType': 'system', 'senderId': '0', 'msgType': 'system', 'content': '护航员已接单 · 单号 0087', 'recalled': false, 'createdAt': '2026-10-04T02:02:00.000Z'},
            ],
          },
        },
        '/user/conversations/75/info': {
          'code': 0, 'message': 'ok',
          'data': {'id': '75', 'type': 'friend', 'status': 'open', 'peerReadSeq': peerReadSeq, 'staffNo': ''},
        },
      }, delays: {'/user/conversations/75/info': infoDelayMs});
      return ApiClient(dio: dio);
    }

    testWidgets('对端已读到 seq=1 → 我方第 1 条直接双勾（历史先到、info 后到也要重算）', (tester) async {
      // info 延迟 300ms：历史先渲染（此时位点=0 → 单勾），info 到达后必须重算渲染项才可能变双勾
      await tester.pumpWidget(MaterialApp(home: ChatDetailPage(conversationId: '75', title: '好友', api: apiWith(1, infoDelayMs: 300))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('我发的'), findsOneWidget);
      expect(find.text('护航员已接单 · 单号 0087'), findsOneWidget, reason: '系统消息走居中 chip 渲染');
      expect(hasSize(tester, const Size(15, 9)), isTrue, reason: 'peerReadSeq=1 >= seq=1 → 双勾（不能等下一条消息）');
      await tester.pump(const Duration(milliseconds: 700)); // 排空 resync 定时器
    });

    testWidgets('对端位点 0 → 我方消息仍单勾（不虚标已读）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ChatDetailPage(conversationId: '75', title: '好友', api: apiWith(0))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(hasSize(tester, const Size(10, 9)), isTrue, reason: '未读 → 单勾');
      expect(hasSize(tester, const Size(15, 9)), isFalse);
      await tester.pump(const Duration(milliseconds: 700));
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, {this.delays = const {}});

  final Map<String, Map<String, dynamic>> raw;
  final Map<String, int> delays;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    final delay = delays[key] ?? 0;
    if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
    final body = key.isEmpty
        ? jsonEncode({'code': 0, 'message': 'ok', 'data': {'list': <dynamic>[]}})
        : jsonEncode(raw[key]);
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
