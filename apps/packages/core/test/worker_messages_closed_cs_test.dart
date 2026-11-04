/// 打手态 · **消息列表：已结束的客服会话不显示、不计红点**（2026-10-11 真机报障）
///
/// 负责人报障（真机截图，打手态 · 工号 W0000）：
///   ① 消息 › 客服段出现**三行完全一样**的「祁连山客服」（无预览、无时间），其中一行挂未读 10；
///   ② 点开其中一行 → 顶部「本次咨询已结束」+ 中间「会话不存在」+「重试」。
/// 要求：「都结束咨询了为啥还会显示那个会话还有红点 **这个结束之后就不显示了**」。
///
/// 服务端已修（列表 SQL 只取 `status='open'` 的客服会话 + 未读快照同口径 + 客服侧打开不再 404），
/// 本文件钉的是**客户端双保险**：即便服务端（旧版/缓存）返回了已结束的客服会话，客户端也
/// **不渲染、不计入未读总数**（否则底部导航「消息」红点会与列表对不上）。
///
/// 变异验证（报告里贴红/绿）：把 `_refresh` 里的
/// `.where((c) => !IdentityWorkerMessagesPage.isClosedCs(c))` 去掉 → ②③ 立刻变红。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求、按 "METHOD /path" 回包的假服务器（与 worker_cs_hall_test 同一范式）
class _FakeServer implements HttpClientAdapter {
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};
  final List<String> requests = <String>[];

  void ok(String key, Object? data) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}), status: 200);

  int calls(String key) => requests.where((String r) => r == key).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    final ({String body, int status})? resp = route[key];
    if (resp == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      resp.body,
      resp.status,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakeServer server;
  int seq = 0;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    final String base = 'http://cs-closed-${seq++}.local';
    server = _FakeServer();
    final Dio dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    ApiClient.debugDefaultDio = dio;
    // 打手态（companion）会话
    AuthStore.instance.debugSetSession(accessToken: 'boss-primary');
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: 'companion-worker-token',
      workerMe: AuthMe.fromJson(<String, dynamic>{
        'id': 'w1',
        'nickname': '小云',
        'uid': 'U2393620058',
        'worker': <String, dynamic>{'workerNo': 'W0000', 'canTakeOrder': true, 'canServeCustomer': true},
      }),
    );
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiClient.debugDefaultDio = null;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  /// 一条客服会话摘要 —— **按服务端已落地的真实字段名**（`chat.service.ts#workerConversations`）
  Map<String, dynamic> cs({
    required String id,
    required String status,
    int unread = 0,
    int lastSeq = 0,
  }) =>
      <String, dynamic>{
        'id': id,
        'type': 'cs',
        'name': null,
        'orderId': null,
        'userNickname': '小云',
        'unread': unread,
        'lastSeq': lastSeq,
        'status': status,
      };

  testWidgets('① 已结束的客服会话**不渲染**（三行重复只留进行中的那条）；进行中的那条照常显示',
      (WidgetTester tester) async {
    // 真机形状：两条自建已结束（无消息）+ 一条正在服务（未读 10）
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[
        cs(id: '429', status: 'closed', unread: 0, lastSeq: 0),
        cs(id: '433', status: 'closed', unread: 0, lastSeq: 1),
        cs(id: '560', status: 'open', unread: 10, lastSeq: 10),
      ],
    });
    server.ok('GET /user/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

    final List<int> reported = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: reported.add,
          openChat: (BuildContext _, IdentityWorkerChatTarget __) async {},
        ),
      ),
    ));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // 【2026-10-17 重钉】负责人定案「消息页去掉上方胶囊，改为单页三分区」→ 不再有「客服」分段可点，
    // 客服会话与老板段一页并列。原断言的实质（已结束的三条收敛成一条）**一条没减**，只是不需要先切段。
    expect(find.text('祁连山客服'), findsOneWidget, reason: '三行重复必须收敛成一行：已结束的两条不上屏');
    expect(find.text('429'), findsNothing);
    expect(find.text('433'), findsNothing);
  });

  testWidgets('② 已结束客服会话的未读**不计入**总未读（底部导航「消息」红点与列表一致）',
      (WidgetTester tester) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[
        cs(id: '560', status: 'open', unread: 10, lastSeq: 10),
        cs(id: '561', status: 'closed', unread: 7, lastSeq: 7),
      ],
    });
    server.ok('GET /user/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

    final List<int> reported = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: reported.add,
          openChat: (BuildContext _, IdentityWorkerChatTarget __) async {},
        ),
      ),
    ));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(reported, isNotEmpty, reason: '列表加载完必须上报未读（shell 只认这一个数据源）');
    expect(reported.last, 10, reason: '已结束那条的 7 个未读不许计入（真机报障：结束了还挂红点）');
  });

  testWidgets('③ 全部客服会话都已结束时 → 三段全空，只给一次全页空态（不显示任何已结束会话）',
      (WidgetTester tester) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[
        cs(id: '429', status: 'closed'),
        cs(id: '433', status: 'closed'),
      ],
    });
    server.ok('GET /user/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: (int _) {},
          openChat: (BuildContext _, IdentityWorkerChatTarget __) async {},
        ),
      ),
    ));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('祁连山客服'), findsNothing, reason: '已结束的会话一条都不该留下');
    // 【2026-10-17 重钉】单页三分区后**空段整段不渲染**（不再有"客服段空态"这个占位），
    // 三条会话全被过滤掉 = 三段全空 → 正确终态是全页空态。原断言的实质（不许留下已结束会话）不减。
    expect(find.text(IdentityWorkerMessagesPage.emptyPageTitle), findsOneWidget, reason: '全页空态才是正确终态');
    expect(find.text(IdentityWorkerMessagesPage.emptyCsTitle), findsNothing,
        reason: '分段控件删除后不再有"客服段空态"这种占位');
    expect(find.text(IdentityWorkerMessagesPage.segments[1]), findsNothing, reason: '空段连标题都不出现');
  });

  test('④ 判据本身：isClosedCs 只认 type=cs 且 status=closed（缺 status 视作 open，不误藏）', () {
    expect(IdentityWorkerMessagesPage.closedCsRule, contains('status=closed'));
    expect(
      IdentityWorkerMessagesPage.isClosedCs(
          ConversationSummaryModel.fromJson(<String, dynamic>{'id': '1', 'type': 'cs', 'status': 'closed'})),
      isTrue,
    );
    expect(
      IdentityWorkerMessagesPage.isClosedCs(
          ConversationSummaryModel.fromJson(<String, dynamic>{'id': '2', 'type': 'cs', 'status': 'open'})),
      isFalse,
      reason: '进行中的客服会话必须照常显示',
    );
    expect(
      IdentityWorkerMessagesPage.isClosedCs(
          ConversationSummaryModel.fromJson(<String, dynamic>{'id': '3', 'type': 'worker', 'status': 'closed'})),
      isFalse,
      reason: '打手直聊不适用这条判据（它的生命周期由服务端物理删除管理）',
    );
    expect(
      IdentityWorkerMessagesPage.isClosedCs(ConversationSummaryModel.fromJson(<String, dynamic>{'id': '4', 'type': 'cs'})),
      isFalse,
      reason: '服务端没给 status 时不隐藏（宁可不隐藏，也不误藏进行中的会话）',
    );
  });
}
