/// **首屏性能量化口径**（本任务「改前 / 改后」对比数字的产出地）
///
/// 为什么要有这个文件：负责人要的是"秒刷"，而"快了多少"必须能复现 —— 靠肉眼看模拟器
/// 既不可复现也不可回归。这里把三条口径钉死在**假时钟**上：
///
/// | 口径 | 定义 |
/// |---|---|
/// | 首屏请求数 | 从 `pumpWidget` 到**目标内容首次上屏**期间发出的 HTTP 请求条数 |
/// | 是否并行 | 该窗口内"同时在飞"的请求峰值（峰值 > 1 = 真的并发） |
/// | 首屏可见耗时 | 从 `pumpWidget` 到目标内容首次上屏推进的**假时钟**量（每请求固定 120ms 往返） |
///
/// 假通道对**每个请求**固定延迟 120ms（一次网络往返的替身），所以数字是"往返次数"的量级，
/// 单位是 ms 但只在同一个假通道下横向可比（真机绝对值另受 DNS/TLS/弱网影响）。
///
/// 另有一条**聊天实时接收**的口径：收到 1 条 `msg:new` 时，页面打了几次网络请求。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:boss_app/pages/messages_page.dart';
import 'package:boss_app/pages/orders_page.dart';
import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一次网络往返的替身（每个请求固定这么多延迟）
const Duration kRtt = Duration(milliseconds: 120);

const List<Map<String, dynamic>> _divisions = <Map<String, dynamic>>[
  <String, dynamic>{
    'id': '2',
    'code': 'delta_mobile',
    'gameId': '36',
    'gameName': '三角洲行动',
    'platform': 'mobile',
    'platformLabel': '手游',
    'name': '三角洲行动 · 手游',
    'shortName': '三角洲手游',
    'onlineDesc': '平均 3 分钟内接单',
    'themeColor': '#2563EB',
    'onlineCount': 12,
  },
  <String, dynamic>{
    'id': '3',
    'code': 'delta_pc',
    'gameId': '36',
    'gameName': '三角洲行动',
    'platform': 'pc',
    'platformLabel': '端游',
    'name': '三角洲行动 · 端游',
    'shortName': '三角洲端游',
    'onlineDesc': '平均 5 分钟内接单',
    'themeColor': '#06B6D4',
    'onlineCount': 8,
  },
];

Map<String, dynamic> _envelope(Object? data) => <String, dynamic>{'code': 0, 'message': 'ok', 'data': data};

/// 记录请求数 / 并发峰值 / 每次请求路径的假通道（每请求固定 [kRtt] 延迟）
class _LatencyAdapter implements HttpClientAdapter {
  final List<String> requests = <String>[];

  int _inFlight = 0;
  int maxInFlight = 0;

  /// 只统计目标内容上屏前的请求 —— [mark] 之后进入"静默期"（后台预热/后续刷新不计入首屏口径）
  bool counting = true;
  int count = 0;

  void markSettled() {
    counting = false;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.path;
    requests.add('${options.method} $path');
    if (counting) count += 1;
    _inFlight += 1;
    maxInFlight = math.max(maxInFlight, _inFlight);
    try {
      await Future<void>.delayed(kRtt);
      return ResponseBody.fromString(
        jsonEncode(_envelope(_body(path))),
        200,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    } finally {
      _inFlight -= 1;
    }
  }

  Object? _body(String path) {
    switch (path) {
      case '/divisions':
        return _divisions;
      case '/divisions/grouped':
        return <dynamic>[
          <String, dynamic>{'gameId': '36', 'gameName': '三角洲行动', 'platformCount': 2, 'divisions': _divisions},
        ];
      case '/public/clubs':
        return <dynamic>[
          <String, dynamic>{'id': '9', 'name': '祁连山官方馆', 'subTitle': '三角洲行动', 'description': '手游 + 端游', 'rating': '4.9', 'orderCount': 2847},
        ];
      case '/public/site':
        return <String, dynamic>{'clubTitle': '官方自营', 'clubParagraphs': <String>['全段位上分与护航']};
      case '/public/banners':
        return <dynamic>[];
      case '/public/recharge/config':
        return null;
      case '/public/categories':
        return <dynamic>[
          <String, dynamic>{'id': 'c1', 'name': '上分', 'gameId': '36'},
        ];
      case '/public/purchase-hint':
        return <String, dynamic>{'text': ''};
      case '/public/players':
        return <String, dynamic>{
          'list': <dynamic>[
            <String, dynamic>{'workerId': 'w1', 'nickname': '陪玩甲', 'intro': '只接三角洲手游', 'avatarMediaId': null},
          ],
          'total': 1,
        };
      case '/public/products':
        return <String, dynamic>{
          'list': <dynamic>[
            <String, dynamic>{
              'id': 'p1',
              'name': '三角洲行动 · 上分陪练（单小时）',
              'subtitle': '全程语音',
              'price': '38.00',
              'priceUnit': '小时',
              'salesCount': 12,
              'categoryId': 'c1',
              'divisionId': '2',
              'gameId': '36',
            },
          ],
          'total': 1,
        };
      case '/user/orders':
        return <String, dynamic>{
          'list': <dynamic>[
            <String, dynamic>{
              'id': 'o1',
              'orderNo': 'OD20261015001',
              'totalAmount': '38.00',
              'status': 'pending_take',
              'statusName': '待接单',
              'createdAt': '2026-10-15T10:00:00.000Z',
              'productName': '三角洲行动 · 上分陪练（单小时）',
              'priceUnit': '小时',
              'quantity': 1,
              'divisionId': '2',
              'gameId': '36',
            },
          ],
          'total': 1,
        };
      case '/user/conversations':
        return <String, dynamic>{
          'list': <dynamic>[
            <String, dynamic>{
              'id': 'cv1',
              'type': 'friend',
              'unread': 0,
              'lastSeq': 3,
              'peer': <String, dynamic>{'userId': 'f1', 'nickname': '好友甲', 'uid': 'F1', 'avatarMediaId': null},
              'lastMessage': <String, dynamic>{'content': '老内容', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-15T10:00:00.000Z'},
            },
          ],
          'total': 1,
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _api(_LatencyAdapter adapter, {String host = 'perf.local'}) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'http://$host/api/v1'))..httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 推进假时钟直到 [finder] 有命中，返回推进量（ms）；超时返回 -1
Future<int> _pumpUntil(WidgetTester tester, Finder finder, {int maxMs = 5000, int step = 10}) async {
  var ms = 0;
  while (ms < maxMs) {
    await tester.pump(Duration(milliseconds: step));
    ms += step;
    if (finder.evaluate().isNotEmpty) return ms;
  }
  return -1;
}

/// 走完首屏之后把**后台**遗留的请求/定时器排空（预热、SWR 后台刷新…），
/// 否则它们会以"pending timer"的形式污染下一个用例（实测确实会）
Future<void> _drain(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
    AuthStore.instance.debugSetSession(accessToken: 'perf-token');
    RealtimeClient.shared.debugDisabled = true;
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    AuthStore.debugStorageDisabled = false;
    ApiCache.instance.clear();
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugSetSession(accessToken: null);
    RealtimeClient.shared.debugOnOverride = null;
  });

  testWidgets('① 服务页（首页）冷缓存：首屏请求数 / 并发峰值 / 首屏可见耗时', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(adapter))));
    final int ms = await _pumpUntil(tester, find.text('精选服务'));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 服务页 冷缓存: 首屏可见耗时=${ms}ms 首屏请求数=${adapter.count} 并发峰值=${adapter.maxInFlight}');
    expect(ms, greaterThan(0), reason: '冷缓存下必须真的等到网络回来（用于证明口径有效）');
    expect(find.text('三角洲行动 · 手游'), findsOneWidget);
  });

  testWidgets('② 找陪玩页冷缓存：首屏请求数 / 并发峰值 / 首屏可见耗时', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _api(adapter))));
    final int ms = await _pumpUntil(tester, find.text('陪玩甲'));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 找陪玩页 冷缓存: 首屏可见耗时=${ms}ms 首屏请求数=${adapter.count} 并发峰值=${adapter.maxInFlight}');
    expect(find.text('陪玩甲'), findsOneWidget);
    expect(ms, greaterThan(0));
  });

  testWidgets('②b 找陪玩页（已知分部）：首屏请求数 / 并发峰值 / 首屏可见耗时', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _api(adapter), initialDivisionId: '2')));
    final int ms = await _pumpUntil(tester, find.text('陪玩甲'));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 找陪玩页 已知分部: 首屏可见耗时=${ms}ms 首屏请求数=${adapter.count} 并发峰值=${adapter.maxInFlight}');
    expect(find.text('陪玩甲'), findsOneWidget);
  });

  testWidgets('③ 商品列表页冷缓存：首屏请求数 / 并发峰值 / 首屏可见耗时', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(adapter), initialDivisionId: '2')));
    final int ms = await _pumpUntil(tester, find.text('三角洲行动 · 上分陪练（单小时）'));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 商品列表页 冷缓存: 首屏可见耗时=${ms}ms 首屏请求数=${adapter.count} 并发峰值=${adapter.maxInFlight}');
    expect(find.text('三角洲行动 · 上分陪练（单小时）'), findsOneWidget);
  });

  testWidgets('④ 订单页冷缓存：首屏请求数 / 并发峰值 / 首屏可见耗时', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(adapter))));
    final int ms = await _pumpUntil(tester, find.textContaining('订单号 OD20261015001'));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 订单页 冷缓存: 首屏可见耗时=${ms}ms 首屏请求数=${adapter.count} 并发峰值=${adapter.maxInFlight}');
    expect(find.textContaining('订单号 OD20261015001'), findsOneWidget);
  });

  testWidgets('⑤ 消息页冷缓存：首屏请求数 / 并发峰值 / 首屏可见耗时', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    final ApiClient api = _api(adapter, host: 'perf-msg.local');
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api)));
    final int ms = await _pumpUntil(tester, find.text('好友甲'));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 消息页 冷缓存: 首屏可见耗时=${ms}ms 首屏请求数=${adapter.count} 并发峰值=${adapter.maxInFlight}');
    expect(find.text('好友甲'), findsOneWidget);
  });

  testWidgets('⑥ 聊天实时接收：收到 1 条 msg:new → 网络请求次数', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    final _Bus bus = _Bus();
    RealtimeClient.shared.debugOnOverride = bus.register;

    final ApiClient api = _api(adapter, host: 'perf-chat.local');
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api)));
    for (int i = 0; i < 6; i++) {
      await tester.pump(kRtt);
    }
    expect(find.text('好友甲'), findsOneWidget);

    final int before = adapter.requests.length;
    adapter.counting = false;
    adapter.count = 0;
    bus.fire('msg:new', <String, dynamic>{
      'msgId': 'm9',
      'seq': 4,
      'conversationId': 'cv1',
      'senderType': 'worker',
      'senderId': 'f1',
      'senderNickname': '好友甲',
      'msgType': 'text',
      'content': '新内容来了',
      'recalled': false,
      'createdAt': '2026-10-15T10:01:00.000Z',
    });
    // 合并窗口（≤200ms）+ 可能的回源，都要跑完
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // ignore: avoid_print
    print('[PERF] 聊天 msg:new ×1 → 网络请求=${adapter.requests.length - before} 次');
    expect(find.text('新内容来了'), findsOneWidget, reason: '增量更新必须真的把新消息摘要上屏');
  });

  testWidgets('⑥b 缓存未命中时收到 1 条 msg:new → 网络请求次数（改前：整表重拉）', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    final _Bus bus = _Bus();
    RealtimeClient.shared.debugOnOverride = bus.register;

    final ApiClient api = _api(adapter, host: 'perf-chat-stale.local');
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: api)));
    for (int i = 0; i < 6; i++) {
      await tester.pump(kRtt);
    }
    expect(find.text('好友甲'), findsOneWidget);

    // 把会话列表缓存清掉（= 写操作失效后的真实状态）：此后任何"回源"都必须真的走网络
    // 注：不能靠"推进假时钟把缓存放过期"——`DateTime.now()` 在 testWidgets 里是**真实时钟**，
    // 假时钟推不动它（第一版就是这么写的，量出来 0 请求，是假阴性）。
    ApiCache.instance.invalidate('/user/conversations', apiBase: api.cacheScopeBase);

    final int before = adapter.requests.length;
    bus.fire('msg:new', <String, dynamic>{
      'msgId': 'm9',
      'seq': 4,
      'conversationId': 'cv1',
      'senderType': 'worker',
      'senderId': 'f1',
      'msgType': 'text',
      'content': '失效后新内容',
      'recalled': false,
      'createdAt': '2026-10-15T10:05:00.000Z',
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // ignore: avoid_print
    print('[PERF] 聊天 msg:new ×1（缓存未命中）→ 网络请求=${adapter.requests.length - before} 次');
    expect(find.text('失效后新内容'), findsOneWidget);
  });

  testWidgets('⑦ 聊天实时接收：200ms 内连续 3 条事件 → 本页 build 次数', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    final _Bus bus = _Bus();
    RealtimeClient.shared.debugOnOverride = bus.register;

    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: _api(adapter, host: 'perf-chat3.local'))));
    for (int i = 0; i < 6; i++) {
      await tester.pump(kRtt);
    }
    expect(find.text('好友甲'), findsOneWidget);

    final int buildsBefore = MessagesPage.debugBuildCount;
    for (int i = 0; i < 3; i++) {
      bus.fire('msg:new', <String, dynamic>{
        'msgId': 'm$i',
        'seq': 4 + i,
        'conversationId': 'cv1',
        'senderType': 'worker',
        'senderId': 'f1',
        'msgType': 'text',
        'content': '连发 $i',
        'recalled': false,
        'createdAt': '2026-10-15T10:0$i:00.000Z',
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    final int builds = MessagesPage.debugBuildCount - buildsBefore;
    // ignore: avoid_print
    print('[PERF] 聊天 3 条事件 → 本页 build 次数=$builds（改前=3）');
    expect(builds, 1, reason: '200ms 内的 3 条事件必须合并成**一次** UI 更新');
    expect(find.text('连发 2'), findsOneWidget);
  });

  testWidgets('⑧ 第二次进入（缓存已在）：首屏可见耗时 —— cache-first 口径', (WidgetTester tester) async {
    // 找陪玩：改前 240ms（/divisions 之后才发名单）→ 改后 0–10ms（缓存先画）
    final _LatencyAdapter pAdapter = _LatencyAdapter();
    final ApiClient pApi = _api(pAdapter, host: 'perf-warm-players.local');
    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: pApi)));
    await _pumpUntil(tester, find.text('陪玩甲'));
    await _drain(tester);
    pAdapter.counting = true;
    pAdapter.count = 0;
    pAdapter.maxInFlight = 0;
    await tester.pumpWidget(MaterialApp(home: PlayersPage(key: const ValueKey('re-enter-players'), api: pApi)));
    final int playersMs = await _pumpUntil(tester, find.text('陪玩甲'));
    pAdapter.markSettled();
    await _drain(tester);
    // ignore: avoid_print
    print('[PERF] 找陪玩页 二次进入(有缓存): 首屏可见耗时=${playersMs}ms 请求数=${pAdapter.count}');
    expect(find.text('陪玩甲'), findsOneWidget);

    // 订单页：改前 120ms（空列表 + 转圈）→ 改后 0–10ms（缓存先画）
    final _LatencyAdapter oAdapter = _LatencyAdapter();
    final ApiClient oApi = _api(oAdapter, host: 'perf-warm-orders.local');
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: oApi)));
    await _pumpUntil(tester, find.textContaining('订单号 OD20261015001'));
    await _drain(tester);
    oAdapter.counting = true;
    oAdapter.count = 0;
    await tester.pumpWidget(MaterialApp(home: OrdersPage(key: const ValueKey('re-enter-orders'), api: oApi)));
    final int ordersMs = await _pumpUntil(tester, find.textContaining('订单号 OD20261015001'));
    oAdapter.markSettled();
    await _drain(tester);
    // ignore: avoid_print
    print('[PERF] 订单页 二次进入(有缓存): 首屏可见耗时=${ordersMs}ms 请求数=${oAdapter.count}');
    expect(find.textContaining('订单号 OD20261015001'), findsOneWidget);

    // 消息页：改前 120ms（空列表 + 转圈）→ 改后 0–10ms（缓存先画）
    final _LatencyAdapter mAdapter = _LatencyAdapter();
    final ApiClient mApi = _api(mAdapter, host: 'perf-warm-msg.local');
    await tester.pumpWidget(MaterialApp(home: MessagesPage(api: mApi)));
    await _pumpUntil(tester, find.text('好友甲'));
    await _drain(tester);
    mAdapter.counting = true;
    mAdapter.count = 0;
    await tester.pumpWidget(MaterialApp(home: MessagesPage(key: const ValueKey('re-enter-msg'), api: mApi)));
    final int msgMs = await _pumpUntil(tester, find.text('好友甲'));
    mAdapter.markSettled();
    await _drain(tester);
    // ignore: avoid_print
    print('[PERF] 消息页 二次进入(有缓存): 首屏可见耗时=${msgMs}ms 请求数=${mAdapter.count}');
    expect(find.text('好友甲'), findsOneWidget);

    // 商品列表页：两跳（分类依赖分部）在冷缓存下消不掉，这里量的是"不再先给骨架屏"
    final _LatencyAdapter bAdapter = _LatencyAdapter();
    final ApiClient bApi = _api(bAdapter, host: 'perf-warm-products.local');
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: bApi, initialDivisionId: '2')));
    await _pumpUntil(tester, find.text('三角洲行动 · 上分陪练（单小时）'));
    await _drain(tester);
    bAdapter.counting = true;
    bAdapter.count = 0;
    await tester.pumpWidget(
      MaterialApp(home: ProductListPage(key: const ValueKey('re-enter-products'), api: bApi, initialDivisionId: '2')),
    );
    final int productsMs = await _pumpUntil(tester, find.text('三角洲行动 · 上分陪练（单小时）'));
    bAdapter.markSettled();
    await _drain(tester);
    // ignore: avoid_print
    print('[PERF] 商品列表页 二次进入(有缓存): 首屏可见耗时=${productsMs}ms 请求数=${bAdapter.count}');
    expect(find.text('三角洲行动 · 上分陪练（单小时）'), findsOneWidget);
  });

  testWidgets('⑨ 切走再切回服务页 tab（refreshSignal++）→ 请求数', (WidgetTester tester) async {
    final _LatencyAdapter adapter = _LatencyAdapter();
    final ValueNotifier<int> signal = ValueNotifier<int>(0);
    addTearDown(signal.dispose);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(adapter), refreshSignal: signal)));
    await _pumpUntil(tester, find.text('精选服务'));
    await _drain(tester);

    adapter.counting = true;
    adapter.count = 0;
    signal.value++; // HomeShell._switchTab(pageServices)
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    adapter.markSettled();
    await _drain(tester);

    // ignore: avoid_print
    print('[PERF] 服务页 切回本 tab: 请求数=${adapter.count}（改前=5 首屏回源 + 11 预取 = 16）');
    expect(adapter.count, lessThanOrEqualTo(5), reason: '切回 tab 只该回源首屏那 5 个；预取全进程只跑一次');
  });

  testWidgets('⑩ 首帧就有内容吗（缓存已在，按"pumpWidget 后第一帧"判定）', (WidgetTester tester) async {
    // 口径：`pumpWidget` 完成后**不额外 pump**，直接看目标文案在不在树上。
    // 这一条测的是"首个可见帧"：改前这些页面首帧是转圈/骨架，改后首帧就是内容。
    final _LatencyAdapter a = _LatencyAdapter();
    final ApiClient api = _api(a, host: 'perf-first-frame.local');

    Future<void> warm(Widget Function(Key) build, Finder target) async {
      await tester.pumpWidget(MaterialApp(home: build(const ValueKey('warm'))));
      await _pumpUntil(tester, target);
      await _drain(tester);
    }

    Future<bool> firstFrameHas(Widget Function(Key) build, Finder target) async {
      await tester.pumpWidget(MaterialApp(home: build(const ValueKey('first-frame'))));
      final bool hit = target.evaluate().isNotEmpty;
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump(kRtt);
      return hit;
    }

    Widget players(Key k) => PlayersPage(key: k, api: api);
    Widget orders(Key k) => OrdersPage(key: k, api: api);
    Widget messages(Key k) => MessagesPage(key: k, api: api);
    Widget products(Key k) => ProductListPage(key: k, api: api, initialDivisionId: '2');

    final Finder fPlayers = find.text('陪玩甲');
    final Finder fOrders = find.textContaining('订单号 OD20261015001');
    final Finder fMessages = find.text('好友甲');
    final Finder fProducts = find.text('三角洲行动 · 上分陪练（单小时）');

    await warm(players, fPlayers);
    final bool hasPlayers = await firstFrameHas(players, fPlayers);
    await warm(orders, fOrders);
    final bool hasOrders = await firstFrameHas(orders, fOrders);
    await warm(messages, fMessages);
    final bool hasMessages = await firstFrameHas(messages, fMessages);
    await warm(products, fProducts);
    final bool hasProducts = await firstFrameHas(products, fProducts);

    // ignore: avoid_print
    print('[PERF] 首帧是否有内容: 找陪玩=$hasPlayers 订单=$hasOrders 消息=$hasMessages 商品列表=$hasProducts');

    /**
     * 【2026-10-16 前提修正】原断言是 `everyElement(isTrue)`，把**订单页**也算进"首帧就该是内容"。
     *
     * 那条断言**建立在错误前提上**：订单页首帧有内容，唯一原因是 `/user/orders` 被缓存了
     * （实测 `cached=1`），而负责人定的红线是「**余额 / 订单 / 消息类一律不缓存**」。
     * 也就是说，这条测试把"私有数据被缓存"当成了性能目标 —— 越绿越错。
     *
     * 修正为两条**各自正确**的断言，而不是放宽：
     *   ① 公开数据（找陪玩/商品列表）—— 有缓存时首帧就该是内容（原意保留）；
     *   ② 私有数据（订单）—— **首帧不该是内容**（必须真回源），且缓存里不得有 `/user/orders`。
     * ② 是把原来那条错误断言换成了**红线守卫**：将来若有人把 `/user/orders` 从
     * `neverCachePrefixes` 里拿掉，这条会立刻变红并指出原因。
     */
    expect(<bool>[hasPlayers, hasProducts] /* 公开数据 */, everyElement(isTrue),
        reason: '缓存优先：公开数据有缓存时**首个可见帧**就该是内容，而不是转圈/骨架');

    expect(hasOrders, isFalse,
        reason: '红线：订单是私有数据，**不许**走缓存 —— 首帧就该是骨架/加载态，必须真回源');
    expect(ApiCache.instance.isNeverCached('/user/orders'),
        isTrue, reason: '红线：`/user/orders` 必须在 `neverCachePrefixes`（缓存键含账号维度，直接查路径即可）');
  });
}

/// 测试事件总线（与 worker_cs_hall_test 同一范式）：`RealtimeClient.debugOnOverride` 注入
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
