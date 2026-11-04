/// 打手态 · **消息页实时接收改增量**（2026-10-15 聊天实时接收优化）
///
/// 缺陷现场（本任务的原始报障口径）：`worker_messages_page.dart` 里
/// ```dart
/// _offEvents.add(_realtime.on('msg:new', (_) => _refresh()));   // 收到一条消息就【重拉整个列表】
/// _offEvents.add(_realtime.on('unread:update', (_) => _refresh()));
/// ```
/// 对方发一句话，客户端要打 1–2 次全量列表请求、列表被重建 1–2 次（卡顿/闪烁/滚动跳位/输入框抖动）。
///
/// 本文件钉死改后的四条不变量（**功能一个不少**：未读仍以服务端权威值为准、新会话仍会回源补摘要）：
///  ① 收到 1 条 `msg:new` → **0 网络请求**，且该会话摘要就地更新、置顶；
///  ② 200ms 内的连续 3 条事件 → 本页 `build` **只多 1 次**（且 3 条一条都不丢）；
///  ③ `unread:update` → 用服务端权威值就地覆盖（客户端不自增）；
///  ④ 首屏两条数据源**并行**（1 个往返可见）+ 有缓存时**首帧就有内容**（附发丝线级"正在刷新"弱提示）。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录请求、固定延迟、能给出"并发峰值"的假服务器（口径与 boss-app 的 perf 用例同一套）
class _FakeServer implements HttpClientAdapter {
  _FakeServer();

  /// 一次网络往返的替身（每个请求固定 120ms）：
  /// 断言"首屏一个往返内可见"就是靠它 —— 串行两条会花 240ms。
  static const Duration latency = Duration(milliseconds: 120);

  final List<String> requests = <String>[];

  int _inFlight = 0;
  int maxInFlight = 0;

  /// 路由：`"METHOD /path"` → data
  final Map<String, Object?> route = <String, Object?>{};

  int calls(String key) => requests.where((String r) => r == key).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    _inFlight += 1;
    maxInFlight = math.max(maxInFlight, _inFlight);
    try {
      await Future<void>.delayed(latency);
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': route[key] ?? <dynamic>[]}),
        200,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    } finally {
      _inFlight -= 1;
    }
  }

  @override
  void close({bool force = false}) {}
}

/// 测试事件总线（`RealtimeClient.debugOnOverride` 注入；生产永远为 null）
class _Bus {
  final Map<String, List<void Function(dynamic)>> _handlers = <String, List<void Function(dynamic)>>{};

  void Function() register(String event, void Function(dynamic) handler) {
    (_handlers[event] ??= <void Function(dynamic)>[]).add(handler);
    return () => _handlers[event]?.remove(handler);
  }

  void fire(String event, dynamic data) {
    for (final void Function(dynamic) h in List<void Function(dynamic)>.from(_handlers[event] ?? const [])) {
      h(data);
    }
  }
}

Map<String, dynamic> _conv({
  required String id,
  String type = 'worker',
  int unread = 0,
  int lastSeq = 0,
  String content = '',
  String? peerNickname = '老板甲',
}) =>
    <String, dynamic>{
      'id': id,
      'type': type,
      'unread': unread,
      'lastSeq': lastSeq,
      'status': 'open',
      'peer': <String, dynamic>{'userId': 'u-$id', 'nickname': peerNickname, 'uid': 'U1', 'avatarMediaId': null},
      'lastMessage': <String, dynamic>{'content': content, 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-15T10:00:00.000Z'},
    };

Map<String, dynamic> _msg({
  required String conversationId,
  int seq = 1,
  String content = '新消息',
  String msgType = 'text',
  bool recalled = false,
  String senderType = 'user',
}) =>
    <String, dynamic>{
      'msgId': 'm-$conversationId-$seq',
      'seq': seq,
      'conversationId': conversationId,
      'senderType': senderType,
      'senderId': 'u-$conversationId',
      'senderNickname': '老板甲',
      'msgType': msgType,
      'content': content,
      'recalled': recalled,
      'createdAt': '2026-10-15T10:01:00.000Z',
    };

void main() {
  late _FakeServer server;
  late _Bus bus;
  int seq = 0;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
    IdentityWorkerMessagesPage.debugBuildCount = 0;
    final String base = 'http://wm-incr-${seq++}.local';
    server = _FakeServer();
    final Dio dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    ApiClient.debugDefaultDio = dio;
    bus = _Bus();
    RealtimeClient.shared.debugOnOverride = bus.register;
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
    RealtimeClient.shared.debugOnOverride = null;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  /// 挂载消息页并等首屏（两条请求各 120ms → 并行后 1 个往返就够）
  Future<void> mount(WidgetTester tester, {List<int>? reported}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: (int v) => reported?.add(v),
          openChat: (BuildContext _, IdentityWorkerChatTarget __) async {},
        ),
      ),
    ));
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('① 收到 1 条 msg:new → **0 网络请求**，摘要就地更新并置顶', (WidgetTester tester) async {
    server.route['GET /worker/cs/conversations'] = <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[
        _conv(id: 'c1', content: '旧内容', lastSeq: 3),
        _conv(id: 'c2', content: '别人的'),
      ],
    };
    server.route['GET /user/conversations'] = <String, dynamic>{'list': <dynamic>[], 'total': 0};

    await mount(tester);
    expect(find.text('旧内容'), findsOneWidget);
    final int before = server.requests.length;

    bus.fire('msg:new', _msg(conversationId: 'c2', seq: 9, content: '置顶的新内容'));
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(server.requests.length - before, 0, reason: '增量更新：一条消息**不许**换来一次全量列表请求');
    expect(find.text('置顶的新内容'), findsOneWidget, reason: '新摘要必须立刻上屏（改前：命中 15s 缓存时列表压根不更新）');
    // 置顶（与服务端 ORDER BY updated_at DESC 同序）：新内容这一行在旧内容之上
    final double? updatedY = tester.getTopLeft(find.text('置顶的新内容')).dy;
    final double? oldY = tester.getTopLeft(find.text('旧内容')).dy;
    expect(updatedY, lessThan(oldY!), reason: '有新消息的会话排到最前');
  });

  testWidgets('② 200ms 内的连续 3 条事件 → 本页 build 只多 1 次（且 3 条都不丢）',
      (WidgetTester tester) async {
    server.route['GET /worker/cs/conversations'] = <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[_conv(id: 'c1', content: '旧内容', lastSeq: 3)],
    };
    server.route['GET /user/conversations'] = <String, dynamic>{'list': <dynamic>[], 'total': 0};

    await mount(tester);
    final int builds = IdentityWorkerMessagesPage.debugBuildCount;
    final int reqs = server.requests.length;

    // 3 条事件（20ms 一条，全落在同一个 200ms 合并窗口里）
    bus.fire('msg:new', _msg(conversationId: 'c1', seq: 4, content: '连发 1'));
    await tester.pump(const Duration(milliseconds: 20));
    bus.fire('msg:new', _msg(conversationId: 'c1', seq: 5, content: '连发 2'));
    await tester.pump(const Duration(milliseconds: 20));
    bus.fire('msg:new', _msg(conversationId: 'c1', seq: 6, content: '连发 3'));
    await tester.pump(const Duration(milliseconds: 20));
    // 合并窗口还没到：此时**一次 UI 更新都还没发生**
    expect(IdentityWorkerMessagesPage.debugBuildCount - builds, 0, reason: '200ms 窗口内不许逐条重建列表');
    await tester.pump(const Duration(milliseconds: 400));

    expect(IdentityWorkerMessagesPage.debugBuildCount - builds, 1, reason: '3 条事件合并成**一次** UI 更新');
    expect(server.requests.length - reqs, 0, reason: '合并后也不发全量请求');
    expect(find.text('连发 3'), findsOneWidget, reason: '最后一条必须是最新那条（3 条按序合进本地列表）');
  });

  testWidgets('③ unread:update → 用服务端权威值就地覆盖（0 请求、客户端不自增）',
      (WidgetTester tester) async {
    server.route['GET /worker/cs/conversations'] = <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[_conv(id: 'c1', unread: 0, content: '旧内容')],
    };
    server.route['GET /user/conversations'] = <String, dynamic>{'list': <dynamic>[], 'total': 0};
    final List<int> reported = <int>[];

    await mount(tester, reported: reported);
    final int reqs = server.requests.length;

    bus.fire('unread:update', <String, dynamic>{'conversationId': 'c1', 'unread': 7});
    await tester.pump(const Duration(milliseconds: 400));

    expect(server.requests.length - reqs, 0, reason: '未读变化同样走增量，不许重拉列表');
    expect(find.text('7'), findsOneWidget, reason: '未读角标按服务端权威值显示');
    expect(reported.last, 7, reason: '底部导航红点上报的也是权威值');
  });

  testWidgets('④ 首屏：两条数据源并行（1 个往返可见）', (WidgetTester tester) async {
    server.route['GET /worker/cs/conversations'] = <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[_conv(id: 'c1', content: '旧内容')],
    };
    server.route['GET /user/conversations'] = <String, dynamic>{'list': <dynamic>[], 'total': 0};

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          api: ApiClient(),
          onUnreadChanged: (int _) {},
          openChat: (BuildContext _, IdentityWorkerChatTarget __) async {},
        ),
      ),
    ));
    // 只推进**一个**往返（130ms > 120ms 延迟）：两条并行的话此刻内容已经在屏上
    for (int i = 0; i < 13; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(server.requests.length, 2, reason: '两条数据源都发了');
    expect(server.maxInFlight, 2, reason: '必须**同时**在飞（改前是串行 await → 峰值 1、白等两个往返）');
    expect(find.text('旧内容'), findsOneWidget, reason: '一个往返之内首屏就可见（改前要两个）');
  });

  testWidgets('⑤ 缓存优先：第二次挂载首帧就有内容 + 发丝线级"正在刷新"弱提示',
      (WidgetTester tester) async {
    server.route['GET /worker/cs/conversations'] = <String, dynamic>{
      'hasCsPermission': true,
      'list': <Map<String, dynamic>>[_conv(id: 'c1', content: '缓存里的内容')],
    };
    server.route['GET /user/conversations'] = <String, dynamic>{'list': <dynamic>[], 'total': 0};

    // 第一次挂载：真实拉取 + 落缓存
    await mount(tester);

    // 第二次挂载（全新页面、同一个 ApiClient / 同一份缓存）：**首帧**就应该是内容
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IdentityWorkerMessagesPage(
          key: const ValueKey('reenter'),
          api: ApiClient(),
          onUnreadChanged: (int _) {},
          openChat: (BuildContext _, IdentityWorkerChatTarget __) async {},
        ),
      ),
    ));
    expect(find.text('缓存里的内容'), findsOneWidget, reason: '首帧必须已经有内容（改前首帧是一屏转圈）');
    expect(find.byKey(IdentityWorkerMessagesPage.refreshingHairlineKey), findsOneWidget,
        reason: '画的是**上一次的**数据 → 必须给发丝线级"正在刷新"弱提示');

    // 回源完成后：弱提示消失，内容仍是服务端那份
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.byKey(IdentityWorkerMessagesPage.refreshingHairlineKey), findsNothing,
        reason: '"正在刷新"提示必须随回源完成而熄灭（不许永久挂着）');
    expect(find.text('缓存里的内容'), findsOneWidget);
  });
}
