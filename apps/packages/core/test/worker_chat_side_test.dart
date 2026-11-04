/// 打手态聊天页的**侧别 + 会话 id** 传递（2026-10-11 遗留缺陷修复）
///
/// ## 缺陷（负责人任务书里点名的那个遗留）
/// 打手态进聊天页走 `home_shell.openWorkerChat`，它原来**不传 worker 侧路径/id**，于是
/// 「结束咨询」打的是**不带任何 id** 的 `POST /user/conversation/close`：
/// 服务端只能在"客服自己没在进行中的会话、且**恰好只服务一条**"时推断，
/// **同时服务 ≥2 条时不猜 → 404**（关不掉当前这条，红点还挂着）。
///
/// ## 修法的客户端一半（服务端一行未改）
/// `IdentityWorkerChatTarget.csServing` = 「我是不是这条咨询的**当事客服**」，
/// 与服务端 `resolveUserRouteActor` 的口径同一句（**当事客服 → worker 侧**）；
/// 由它推出的 `sendPath` 里**带会话 id**（`/worker/cs/conversations/<id>/messages`），
/// 聊天页再据此把「结束咨询」打到 `/worker/cs/conversations/<id>/close`。
///
/// 侧别判定的唯一口径（[_ownCsIds]）：`/worker/cs/conversations` 的客服行 = 「我发起的 ∪ 我服务的」，
/// `/user/conversations` 的客服行 = 「我发起的」→ **差集就是我正在服务的**那些。
///
/// ## 变异验证（报告里贴红/绿）
/// 把 `_open` 里的 `csServing: ...` 去掉（或恒为 false）→ ①② 立刻变红（侧别丢失、路径变 null）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求、按 "METHOD /path" 回包的假服务器（与 worker_messages_closed_cs_test 同一范式）
class _FakeServer implements HttpClientAdapter {
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};
  final List<String> requests = <String>[];

  void ok(String key, Object? data) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}), status: 200);

  void fail(String key, int status, String message) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': status, 'message': message, 'data': null}), status: status);

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
    final String base = 'http://chat-side-${seq++}.local';
    server = _FakeServer();
    final Dio dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    ApiClient.debugDefaultDio = dio;
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

  Map<String, dynamic> csRow({required String id, required int unread}) => <String, dynamic>{
        'id': id,
        'type': 'cs',
        'name': null,
        'orderId': null,
        'userNickname': '小苏',
        'unread': unread,
        'lastSeq': unread,
        'status': 'open',
      };

  /// 摆一屏打手态消息页，返回**每次点开捕获到的目标**
  Future<List<IdentityWorkerChatTarget>> pumpMessages(WidgetTester tester) async {
    final List<IdentityWorkerChatTarget> opened = <IdentityWorkerChatTarget>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: (int _) {},
          openChat: (BuildContext _, IdentityWorkerChatTarget t) async => opened.add(t),
        ),
      ),
    ));
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 【2026-10-17 重钉】负责人定案「消息页去掉上方胶囊、改为单页三分区」→ 已无「客服」分段可点：
    // 客服会话与老板段**一页并列**，所以这里不再需要切段。原来这一行 `tap(find.text('客服'))`
    // 在单页里还会撞上**行内角色标签**（同样是「客服」，两条会话就是两枚）→ 直接报多元素。
    // 本文件三条用例的断言（侧别、路径带 id、不猜）**一条没动**，改的只是"怎么让会话上屏"。
    return opened;
  }

  testWidgets('① 我**服务**的两条咨询（未读 10 / 3）→ 各自带自己的 id 与 worker 侧路径', (WidgetTester tester) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[csRow(id: '560', unread: 10), csRow(id: '561', unread: 3)],
    });
    // 我作为发起方的客服会话：一条都没有（这正是"专职客服"的形状）
    server.ok('GET /user/conversations', <String, dynamic>{'list': <dynamic>[], 'total': 0});

    final List<IdentityWorkerChatTarget> opened = await pumpMessages(tester);

    // 点第一条（未读数 10 那条 = 会话 560）
    await tester.tap(find.text('10'));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 点第二条（未读数 3 那条 = 会话 561）
    await tester.tap(find.text('3'));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(opened.length, 2, reason: '两条都要能点开');
    expect(opened[0].conversationId, '560');
    expect(opened[1].conversationId, '561');
    for (final IdentityWorkerChatTarget t in opened) {
      expect(t.csServing, isTrue, reason: '不在"我发起的"集合里 = 我是当事客服 → worker 侧');
      expect(t.sendPath, '/worker/cs/conversations/${t.conversationId}/messages',
          reason: '路径必须带**这一条**的会话 id（「结束咨询」据此精确关这一条）');
    }
    expect(opened[0].sendPath, isNot(opened[1].sendPath), reason: '同时服务多条时两条的 id 必须不同');
  });

  testWidgets('② 混在一段里的两种身份：**我发起的**（433）走 user 侧、**我服务的**（560）走 worker 侧',
      (WidgetTester tester) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      // 同一段里两条：560 = 我服务的（服务端按 active 指派给我），433 = 我自己发起的
      'list': <Map<String, dynamic>>[csRow(id: '560', unread: 10), csRow(id: '433', unread: 4)],
    });
    // 打手态「联系客服」建的那条（`chat_conversation.user_id = 我`）在老板侧列表里
    server.ok('GET /user/conversations', <String, dynamic>{
      'list': <Map<String, dynamic>>[<String, dynamic>{'id': '433', 'type': 'cs', 'unread': 4, 'status': 'open'}],
      'total': 1,
    });

    final List<IdentityWorkerChatTarget> opened = await pumpMessages(tester);

    await tester.tap(find.text('4')); // 433（我发起的）
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.tap(find.text('10')); // 560（我服务的）
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(opened.length, 2);
    final IdentityWorkerChatTarget own = opened.firstWhere((IdentityWorkerChatTarget t) => t.conversationId == '433');
    final IdentityWorkerChatTarget serving = opened.firstWhere((IdentityWorkerChatTarget t) => t.conversationId == '560');
    expect(own.csServing, isFalse, reason: '我发起的咨询与老板态逐字相同 → user 侧');
    expect(own.sendPath, isNull, reason: 'user 侧不加 worker 前缀（否则会被 assertWorkerCs 判 403）');
    expect(serving.csServing, isTrue);
    expect(serving.sendPath, '/worker/cs/conversations/560/messages');
  });

  testWidgets('③ 侧别判定数据拿不到（/user/conversations 失败）→ **不猜**：退回 user 侧',
      (WidgetTester tester) async {
    server.ok('GET /worker/cs/conversations', <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[csRow(id: '560', unread: 10)],
    });
    server.fail('GET /user/conversations', 500, '服务器开小差');

    final List<IdentityWorkerChatTarget> opened = await pumpMessages(tester);
    await tester.tap(find.text('10'));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(opened.single.conversationId, '560');
    expect(opened.single.csServing, isFalse, reason: '判定数据缺失时不猜 → 保持改动前的 user 侧行为');
    expect(opened.single.sendPath, isNull);
  });

  test('④ 侧别判据本身：csServing=false 不加前缀、true 时路径里必须有会话 id', () {
    const IdentityWorkerChatTarget own = IdentityWorkerChatTarget(conversationId: '560', title: '祁连山客服');
    const IdentityWorkerChatTarget serving =
        IdentityWorkerChatTarget(conversationId: '560', title: '老板', csServing: true);

    expect(own.csServing, isFalse, reason: '缺省 = 我是发起方（各「联系客服」入口）');
    expect(own.sendPath, isNull);
    expect(serving.sendPath, '/worker/cs/conversations/560/messages');
    expect(serving.sendPath, contains('560'), reason: '路径是「结束咨询」带 id 的唯一来源');
  });
}
