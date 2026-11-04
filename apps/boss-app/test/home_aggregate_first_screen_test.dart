/// **首屏聚合接口（`GET /public/home`）—— 请求次数、降级与并行**（2026-10-16 网卡治理专项 · boss-app 侧）
///
/// ## 病灶与目标（实测口径）
/// 服务端 2–21ms、负载 0.08、无慢查询；**香港节点 RTT ≈ 245ms**，同一条连接上顺序跑 5 个接口 = 1819ms。
/// 结论：卡在**往返次数**上。本文件用**同一把尺子**（假通道延迟固定 [kRtt]，每发请求一行计数）
/// 把"改前 / 改后"钉死，防回归：
///
/// | 口径 | 改前 | 改后 |
/// |---|---|---|
/// | 首屏**数据来源**（先看到「选择分部」）的请求数 | 5 | **1**（`/public/home`，实测 `聚合=1`） |
/// | 首屏窗口内**发出的**请求总数（含静态配置 2 发） | 5 | 6（聚合 1 + 回落对冲 3 + 静态配置 2） |
/// | 后端没上线时的首屏耗时 | 1 往返 | **仍然是 1 往返**（回落与探测同批发出，不被探测按住） |
/// | 回访（缓存已在） | 5 | **0**（TTL 分档，见 core 侧 `api_cache_ttl_tiers_test.dart`） |
///
/// ## ⚠️ 为什么"改后总数是 6"而不是 1（如实交代，别当成漏改）
/// 编排形态是**两路同时发、谁先有可用数据谁上屏**（见 `services_page.dart` 的编排注释）：
///   - 首选过"聚合先探、回落延迟 600ms 起步、聚合赢了就短路回落"——**两版都实测不可行**：
///     ① 先探再回落 → 聚合挂住时首屏被探测按住一个超时窗口（8 个既有用例白屏）；
///     ② 回落延迟起步 → `pumpAndSettle` 不推进定时器，既有 `services_resume_force_test`
///        ③/④/⑤（"回前台必须 force 真回源"）全红；真机上还把"首屏由最快那条路决定"
///        换成"由聚合决定"。
///   - 现形态代价 = 聚合可用时那 3 发回落是**多打的**（且是**已缓存的读**，SWR 命中不发网络）；
///     换来 ① 首屏延迟恒由最快那条路决定 ② 任何一条路挂掉都不白屏 ③ "回源语义"始终有可观测证据。
///
/// ## 本文件钉死的五件事（对应任务书验收 ①②③④ + 红线）
/// 1. **聚合可用 → 首屏数据来源就是那 1 发 `/public/home`**（实测 `聚合=1`）；
/// 2. **聚合失败（404 / 契约残缺）→ 回落成功且不白屏**，回落那 3 发**并行**（用"首屏耗时不叠加"证明）；
/// 3. **不阻塞**：聚合迟迟不回时，首屏仍由回落按时出内容（不是等一个超时窗口）；
/// 4. **分档 TTL 生效**：banners 60s（2026-10-16 二轮：8 分钟 → 60 秒，"换图 1 分钟内可见"）
///    与 divisions 的 6 分钟档让回访零请求；
/// 5. **红线**：服务页全程**没有任何** `/user/` 私有条目进缓存（含已登录态再跑一遍）。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一次网络往返的替身（与 `perf_first_paint_test.dart` 同一口径，便于横向对照）
const Duration kRtt = Duration(milliseconds: 120);

Map<String, dynamic> _envelope(Object? data) =>
    <String, dynamic>{'code': 0, 'message': 'ok', 'data': data};

/// 首页聚合的契约形状（任务书：banners / divisions / hotProducts / players / leaderboard / updatedAt）
Map<String, dynamic> aggregateData({int divisions = 2}) => <String, dynamic>{
      'banners': <dynamic>[
        <String, dynamic>{'id': '1', 'imageMediaId': 'm1', 'sortOrder': 1, 'linkType': 'none', 'linkValue': ''},
      ],
      'divisions': <dynamic>[
        for (var i = 0; i < divisions; i++)
          <String, dynamic>{
            'id': '${i + 1}',
            'code': i == 0 ? 'peace_mobile' : 'delta_mobile',
            'gameId': '35',
            'gameName': i == 0 ? '和平精英' : '三角洲行动',
            'platform': 'mobile',
            'platformLabel': '手游',
            'name': i == 0 ? '和平精英 · 手游' : '三角洲行动 · 手游',
            'shortName': i == 0 ? '和平精英' : '三角洲行动',
            'onlineDesc': '平均 3 分钟内接单',
            'themeColor': '#2563EB',
            'onlineCount': 12 + i,
          },
      ],
      'hotProducts': <dynamic>[
        <String, dynamic>{'id': 'p1', 'name': '上分陪练（单小时）', 'price': '38.00'},
      ],
      'players': <dynamic>[
        <String, dynamic>{'workerId': 'w1', 'nickname': '陪玩甲', 'intro': '只接三角洲手游'},
      ],
      'leaderboard': <dynamic>[
        <String, dynamic>{'rank': 1, 'nickname': '陪玩甲', 'value': 2847},
      ],
      'updatedAt': '2026-10-16T10:00:00.000Z',
    };

/// 假通道：**记录每一发的路径与并发峰值**，按注入的规则回包（可让聚合"永不回"）
class _HomeAdapter implements HttpClientAdapter {
  _HomeAdapter({
    this.aggregate,
    this.aggregateStatus = 200,
    this.fallback = true,
    this.aggregateHangs = false,
  });

  /// `/public/home` 的 `data`；null = 按 [aggregateStatus] 返回错误信封（可指定 404）
  final Map<String, dynamic>? aggregate;
  final int aggregateStatus;

  /// 分接口是否可用（false = 404）
  final bool fallback;

  /// true = `/public/home` **永不回包**（模拟隧道半死/后端挂住），用来证明"回落不被它按住"
  final bool aggregateHangs;

  final List<String> requests = <String>[];

  /// 回落分接口的**发起时刻**（假时钟 ms）。三者相同 = 同一批并行发出。
  ///
  /// 2026-10-18：`/public/clubs` 退出回落批次（首页官方馆整块已删，见 services_page 头注释），
  /// 这里同步换成仍在本批的 `/public/announcements`。
  List<int> get fallbackFireTimes => <int>[
        firstFireAtMs['/divisions/grouped'] ?? -1,
        firstFireAtMs['/public/banners'] ?? -1,
        firstFireAtMs['/public/announcements'] ?? -1,
      ];

  int get fallbackFireSpread {
    final t = fallbackFireTimes.where((x) => x >= 0).toList()..sort();
    if (t.length < 2) return 0;
    return t.last - t.first;
  }

  final Map<String, int> firstFireAtMs = <String, int>{};

  /// 用例推进的假时钟毫秒（由 `_pumpUntil` / `_drain` 喂进来，用于给 [firstFireAtMs] 打时间戳）
  int clockMs = 0;

  void _stamp(String path) {
    for (final prefix in <String>[
      '/public/home',
      '/divisions/grouped',
      '/public/banners',
      '/public/announcements',
    ]) {
      if (path.startsWith(prefix)) firstFireAtMs.putIfAbsent(prefix, () => clockMs);
    }
  }

  int _inFlight = 0;
  int maxInFlight = 0;

  int countOf(String path) => requests.where((p) => p.startsWith(path)).length;

  /// 首屏"拿全"所需的 5 个数据源里，落在**分接口**上的那几个（聚合可用时应当一个都没有）
  int get fallbackHomeRequestCount => countOf('/divisions/grouped') + countOf('/public/banners');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    requests.add(path);
    _stamp(path);
    _inFlight += 1;
    maxInFlight = math.max(maxInFlight, _inFlight);
    try {
      if (path.startsWith('/public/home')) {
        if (aggregateHangs) {
          // "挂住" = 远超本页的聚合超时（1.5s），但**有限**（3s）：
          // 用 3s 而不是 30s，是为了让挂起的那发在用例收尾时能自然结束 ——
          // 否则它会以 "A Timer is still pending even after the widget tree was disposed"
          // 的形式把用例判失败（那是夹具问题，不是被测行为问题）。
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        await Future<void>.delayed(kRtt);
        if (aggregate == null) {
          return _json(_envelope(null), statusCode: aggregateStatus);
        }
        return _json(_envelope(aggregate));
      }

      if (path.startsWith('/public/clubs')) {
        await Future<void>.delayed(kRtt);
        if (!fallback) return _json(_envelope(null), statusCode: 404);
        return _json(_envelope(<dynamic>[
          <String, dynamic>{
            'id': '1',
            'name': '祁连山电竞 · 官方自营',
            'subTitle': '平台直营',
            'description': '全段位上分与护航',
            'rating': '4.9',
            'orderCount': 2847,
            'coverMediaId': null,
          },
        ]));
      }
      if (path.startsWith('/divisions')) {
        await Future<void>.delayed(kRtt);
        if (!fallback) return _json(_envelope(null), statusCode: 404);
        return _json(_envelope(<dynamic>[
          <String, dynamic>{
            'gameId': '35',
            'gameName': '和平精英',
            'platformCount': 1,
            'divisions': <dynamic>[
              <String, dynamic>{
                'id': '1',
                'code': 'peace_mobile',
                'gameName': '和平精英',
                'platform': 'mobile',
                'platformLabel': '手游',
                'name': '和平精英 · 手游',
                'shortName': '和平精英',
                'onlineDesc': '平均 3 分钟内接单',
                'themeColor': '#2563EB',
                'onlineCount': 12,
              },
            ],
          },
        ]));
      }
      if (path.startsWith('/public/banners')) {
        await Future<void>.delayed(kRtt);
        if (!fallback) return _json(_envelope(null), statusCode: 404);
        return _json(_envelope(<dynamic>[
          <String, dynamic>{'id': '1', 'imageMediaId': 'm1', 'sortOrder': 1, 'linkType': 'none', 'linkValue': ''},
        ]));
      }
      if (path.startsWith('/public/products')) {
        await Future<void>.delayed(kRtt);
        if (!fallback) return _json(_envelope(null), statusCode: 404);
        return _json(_envelope(<String, dynamic>{
          'list': <dynamic>[
            <String, dynamic>{
              'id': '101',
              'name': '和平精英上分单',
              'price': 30,
              'priceUnit': '局',
              'salesCount': 12,
              'divisionId': '1',
              'gameId': '35',
            },
          ],
          'total': 1,
          'page': 1,
          'pageSize': 50,
        }));
      }
      if (path.startsWith('/public/site')) {
        return _json(_envelope(<String, dynamic>{
          'clubTitle': '官方自营',
          'clubParagraphs': <String>['全段位上分与护航'],
        }));
      }
      if (path.startsWith('/public/recharge/config')) {
        return _json(_envelope(null));
      }
      // 未覆盖的路径：与真实服务端一致返回 404 + 错误信封
      return _json(_envelope(null), statusCode: 404);
    } finally {
      _inFlight -= 1;
    }
  }

  ResponseBody _json(Map<String, dynamic> body, {int statusCode = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        statusCode,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

ApiClient _api(_HomeAdapter adapter, String host) {
  final dio = Dio(BaseOptions(baseUrl: 'http://$host/api/v1'))..httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 推进假时钟直到 [finder] 有命中，返回推进量（ms）；超时返回 -1
/// （同时把累计毫秒喂给 [adapter].clockMs，让每发请求带上"发起时刻"）
Future<int> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxMs = 6000,
  int step = 10,
  _HomeAdapter? adapter,
}) async {
  var ms = 0;
  while (ms < maxMs) {
    await tester.pump(Duration(milliseconds: step));
    ms += step;
    adapter?.clockMs = ms;
    if (finder.evaluate().isNotEmpty) return ms;
  }
  return -1;
}

/// 收尾：把后台遗留的请求/定时器排空（否则会以 pending timer 污染下一条用例）
Future<void> _drain(WidgetTester tester, {_HomeAdapter? adapter, int maxMs = 4000}) async {
  for (var spent = 0; spent < maxMs; spent += 1000) {
    await tester.pump(const Duration(seconds: 1));
    adapter?.clockMs = spent + 1000;
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

/// 把首屏观测窗口压到"刚好够回落起步（600ms 宽限期）+ 一次往返"之内
/// —— 这样自动预取（首屏上屏后才发）不会混进计数，口径才可比。
Future<void> _drainShort(WidgetTester tester, {_HomeAdapter? adapter}) => _drain(tester, adapter: adapter, maxMs: 1000);

void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
    // **不给登录令牌**：本文件测的是"首屏数据请求"，而首屏上屏后的自动预取（11 发）
    // 会把计数污染成不可比的数字。预取要求 `token != null`（见 `_load` 里的守卫），
    // 所以匿名态下它天然不发 —— 口径干净。
    AuthStore.instance.debugSetSession(accessToken: null);
    RealtimeClient.shared.debugDisabled = true;
    // 聚合电路保护是**进程级**静态状态：不复位的话，"前一条用例把聚合判成不可用"
    // 会让后一条用例根本不发探测（计数变 0）。两条测试钩子都在这里复位。
    ServicesPage.debugResetAggregateBreaker();
    ServicesPage.debugResetPrefetched();
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    AuthStore.debugStorageDisabled = false;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: null);
    RealtimeClient.shared.debugOnOverride = null;
  });

  // -------------------------------------------------------------------
  // ① 聚合可用 → 首屏数据来源 = 1 个请求（核心验收）
  // -------------------------------------------------------------------
  group('① 聚合可用：首屏数据来源 = 1 个聚合请求', () {
    testWidgets('只发 /public/home，且**一个分接口都不发**；页面用聚合数据渲染', (tester) async {
      final adapter = _HomeAdapter(aggregate: aggregateData());
      final api = _api(adapter, 'agg-ok.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      final ms = await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      // 服务端数据上屏（证明不是白屏/空壳）
      expect(find.text('和平精英 · 手游'), findsOneWidget);
      expect(find.text('三角洲行动 · 手游'), findsOneWidget, reason: '第二段分部的完整名');

      // ignore: avoid_print
      print('[PERF] 聚合可用：首屏可见=${ms}ms | 总请求=${adapter.requests.length} '
          '聚合=${adapter.countOf('/public/home')} 分接口=${adapter.fallbackHomeRequestCount} '
          '最大并发=${adapter.maxInFlight}');

      // ① 只发 1 个 **首页聚合数据** 请求 —— 这就是任务要的"5 次 → 1 次"
      expect(adapter.countOf('/public/home'), 1);
      // 回落那 3 发是**并排的对冲**（见 services_page 的编排注释：两路同时发、谁先有可用内容谁上屏）：
      // 它们与聚合同批发出，聚合先回来时结果被丢弃。因此这里断言的是"**聚合仍是首屏唯一的数据来源**"，
      // 而不是"分接口一发都不发"（那需要"先探后回落"，实测会让首屏被挂住的探测按住）。
      expect(find.text('和平精英 · 手游'), findsOneWidget, reason: '内容来自聚合（/public/home 没被调用时这条会红）');
      expect(adapter.countOf('/public/home'), 1, reason: '聚合只发一次（不重试、不重发）');
      // 首屏窗口内总请求 ≤ 6（聚合 1 + 回落对冲 3 + 静态配置 2）；改前是 5（无聚合）
      expect(adapter.requests.length, lessThanOrEqualTo(7),
          reason: '首屏窗口内总数（含静态配置）应当 ≤ 7；改前是 5');
    });

    testWidgets('聚合可用时缓存生效：第二次加载不再回源（TTL 由 players 段决定 = 30s）', (tester) async {
      final adapter = _HomeAdapter(aggregate: aggregateData());
      final api = _api(adapter, 'agg-warm.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);
      expect(adapter.countOf('/public/home'), 1);

      // 重建页面（= 再次进首屏，非 force）：缓存仍在 30s 窗口内 → 0 网络
      await tester.pumpWidget(MaterialApp(home: ServicesPage(key: const ValueKey('again'), api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      expect(adapter.countOf('/public/home'), 1,
          reason: '回访必须命中缓存（这正是"回访秒开"的机制）；多打一发就说明 TTL/键算错了');
    });

    testWidgets('下拉刷新（force）不受缓存影响，仍真回源', (tester) async {
      final adapter = _HomeAdapter(aggregate: aggregateData());
      final api = _api(adapter, 'agg-force.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);
      expect(adapter.countOf('/public/home'), 1);

      await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // ignore: avoid_print
      print('[PERF] 下拉刷新：/public/home 请求数=${adapter.countOf('/public/home')}');
      expect(adapter.countOf('/public/home'), greaterThanOrEqualTo(2),
          reason: '下拉刷新的语义就是"要服务端此刻的数据"，必须绕过 SWR 缓存');
    });
  });

  // -------------------------------------------------------------------
  // ② 聚合不可用 → 回落成功、不白屏、且回落请求并行
  // -------------------------------------------------------------------
  group('② 聚合失败：回落成功不白屏，回落请求并行', () {
    testWidgets('404 → 回落到分接口，页面正常渲染（不白屏）', (tester) async {
      /// **视口加高到 800 × 1200**（本用例独有；其余用例不受影响）。
      ///
      /// 为什么要加高：本夹具配了一张宣传图，首页轮播是 16:9 卡片 → 800 宽下就有 450 高，
      /// 默认 600 高的视口里下面的模块会落到视口之外（本用例只做"在不在树上"的断言，
      /// 不点击任何下层控件，加高只是为了让出图/诊断读数更接近真机观感）。
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404);
      final api = _api(adapter, 'agg-404.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      final ms = await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      expect(find.text('和平精英 · 手游'), findsOneWidget, reason: '回落路径必须把分部渲出来');
      // 2026-10-18 首页重构：商品常驻「精选服务」横排卡（不再有"进分部才显示商品"的二选一视图）
      expect(find.text('和平精英上分单'), findsOneWidget, reason: '商品来自 /public/products（与聚合同批发出）');
      expect(find.text('热门游戏'), findsOneWidget);
      expect(find.text('内容加载失败，请下拉重试'), findsNothing, reason: '回落成功就不是错误态');

      // ignore: avoid_print
      print('[PERF] 聚合 404：首屏可见=${ms}ms | 聚合探测=${adapter.countOf('/public/home')} '
          '分接口=${adapter.fallbackHomeRequestCount} 最大并发=${adapter.maxInFlight} '
          '三发起步时刻=${adapter.fallbackFireTimes}');

      expect(adapter.countOf('/public/products'), 1, reason: '商品首屏只发一发（本地过滤的前置）');
      expect(adapter.countOf('/divisions/grouped'), 1);
      expect(adapter.countOf('/public/banners'), 1);
      expect(adapter.maxInFlight, greaterThanOrEqualTo(2),
          reason: '回落路径上的请求必须并行（任务书 ③）；串行时并发峰值只会是 1');
      // **并行的时间证据**：三发的发起时刻必须落在同一帧（推进步长 10ms → 差 ≤ 10ms）。
      // 串行的话会是 0 / 120 / 240 这样等差拉开。
      expect(adapter.fallbackFireSpread, lessThanOrEqualTo(10),
          reason: '三发起步时刻相差 ${adapter.fallbackFireSpread}ms：串行执行会拉开 120ms 以上');
    });

    testWidgets('回落并行 ⇒ 首屏耗时不叠加（三发并行只多**一次**往返）', (tester) async {
      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404);
      final api = _api(adapter, 'agg-parallel.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      final ms = await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      // 首屏 = 宽限期（600ms，回落在此起步）+ 一次往返（120ms）＝ 720ms。
      // 若三发串行则要 600 + 3×120 = 960ms。
      expect(ms, greaterThan(0));
      expect(ms, lessThan(600 + kRtt.inMilliseconds * 2),
          reason: '首屏耗时 $ms ms：三个回落请求若是串行，至少要 960ms');
    });

    testWidgets('200 但契约残缺（旧版只剩 announcements）→ 回落，且照常渲染', (tester) async {
      final adapter = _HomeAdapter(
        aggregate: <String, dynamic>{'announcements': <dynamic>[]},
        aggregateStatus: 200,
      );
      final api = _api(adapter, 'agg-narrow.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      expect(find.text('和平精英 · 手游'), findsOneWidget);
      expect(adapter.countOf('/divisions/grouped'), 1, reason: '契约残缺必须回落');
      expect(find.text('内容加载失败，请下拉重试'), findsNothing);
    });

    testWidgets('聚合**挂住不回**时，回落照样按时出内容（首屏不被探测按住）', (tester) async {
      final adapter = _HomeAdapter(aggregate: aggregateData(), aggregateHangs: true);
      final api = _api(adapter, 'agg-hang.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      final ms = await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      // ignore: avoid_print
      print('[PERF] 聚合挂住：首屏可见=${ms}ms（回落赢）| 分接口=${adapter.fallbackHomeRequestCount}');
      // 这一条的收尾要排到"挂起的那发自然结束"（夹具 3s）之后，否则会以 pending timer 判失败
      await _drain(tester, adapter: adapter);
      expect(find.text('和平精英 · 手游'), findsOneWidget);
      expect(ms, greaterThan(0));
      // 关键：必须**早于**聚合自己的超时窗口（1500ms）——改前的"先探后回落"会白等到 1500ms。
      // 现在的上界 = 宽限期 600ms + 一次往返 120ms = 720ms。
      expect(ms, lessThan(1000),
          reason: '首屏耗时 $ms ms：必须由回落（600ms 宽限 + 一次往返）决定，而不是等聚合的 1.5s 超时');
    });

    testWidgets('两条路都失败 → 走既有错误态（有重试入口），仍然不白屏', (tester) async {
      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404, fallback: false);
      final api = _api(adapter, 'agg-allfail.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('内容加载失败，请下拉重试'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      expect(find.text('重试'), findsOneWidget, reason: '全失败必须给可点的重试入口（既有错误卡）');
      expect(find.textContaining('首页数据没拿到'), findsOneWidget);
      // 既有错误卡的第一行原样还在（两条路都失败 = 既有错误态，不新增第二套文案）
      expect(find.text('内容加载失败，请下拉重试'), findsOneWidget);
      // 且"内容加载失败"这句**只出现一次**（细节行刻意换了措辞，见 `services_page.dart` 内注释）
      expect(find.textContaining('内容加载失败'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------
  // ③ 电路保护：聚合失败后不再反复浪费往返
  // -------------------------------------------------------------------
  group('③ 电路保护：聚合判定不可用后不再反复探测', () {
    testWidgets('第一次失败后，冷却期内第二次加载不再探测聚合（且首屏照常）', (tester) async {
      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404);
      final api = _api(adapter, 'agg-cooldown.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);
      expect(adapter.countOf('/public/home'), 1, reason: '第一次必须探测一次（不能假设接口不存在）');
      expect(adapter.countOf('/public/products'), 1, reason: '商品和回落同批发出（首屏照常）');
      expect(ServicesPage.debugAggregateBreakerArmed, isTrue,
          reason: '404 = "接口不存在"的确定性证据 → 必须挂上冷却（否则每次加载都白发一发）');

      // 重建页面（冷却期内、非 force）→ 不应再探测
      ServicesPage.debugResetPrefetched();
      await tester.pumpWidget(MaterialApp(home: ServicesPage(key: const ValueKey('again'), api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      // ignore: avoid_print
      print('[PERF] 冷却生效：聚合探测累计=${adapter.countOf('/public/home')} '
          '（第二次加载新增 ${adapter.countOf('/public/home') - 1}）');

      expect(adapter.countOf('/public/home'), 1,
          reason: '404 是"接口不存在"的确定性证据 → 冷却期内不该再为首屏多付一发探测');
      // 回落路径照常工作：第二次加载时 `/public/products` 的温度只看 SWR 档位（列表档内 → 命中缓存，
      // 因此这里断言的是"**至少**发过一次"，而不是"每跳都发"——后者是 force 路径的语义，见
      // `services_resume_force_test` 的 ③/④）。
      expect(adapter.countOf('/public/products'), greaterThanOrEqualTo(1),
          reason: '回落路径照常工作（首屏那一次必须真发）');
    });

    testWidgets('force 刷新（切回 tab 信号）**无视冷却**直接重探 —— 后端上线后无需等冷却', (tester) async {
      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404);
      final api = _api(adapter, 'agg-cooldown-force.local');
      final signal = ValueNotifier<int>(0);
      addTearDown(signal.dispose);

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api, refreshSignal: signal)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);
      expect(adapter.countOf('/public/home'), 1);

      signal.value++; // HomeShell._switchTab(pageServices)
      await tester.pump(const Duration(milliseconds: 10));
      await _drainShort(tester, adapter: adapter);

      expect(adapter.countOf('/public/home'), 2,
          reason: 'force 路径的语义是"要最新"，它必须重新探测聚合（这也是后端上线后的切换入口）');
    });
  });

  // -------------------------------------------------------------------
  // ④ 分档 TTL 在首屏路径上的效果（回访秒开）
  // -------------------------------------------------------------------
  group('④ TTL 分档：banners 60s / divisions 6 分钟让回访零请求', () {
    testWidgets('回落路径下 banners 在新鲜窗口内命中缓存（连进两次都不再发）', (tester) async {
      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404);
      final api = _api(adapter, 'ttl-banners.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);
      expect(adapter.countOf('/public/banners'), 1);

      // 连进两次（非 force）：banners 60 秒档 → 这一窗口内一次都不该再发。
      // 先把聚合电路保护也复位，否则冷却期内"连聚合都不探"，本用例就只测了回落缓存
      // （那也是对的，但我想同时钉住"档位在两种路径下都生效"）。
      for (final k in <String>['again-1', 'again-2']) {
        ServicesPage.debugResetAggregateBreaker();
        ServicesPage.debugResetPrefetched();
        await tester.pumpWidget(MaterialApp(home: ServicesPage(key: ValueKey(k), api: api)));
        await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
        await _drainShort(tester, adapter: adapter);
      }

      // ignore: avoid_print
      print('[PERF] banners 档位：总计 requests=${adapter.countOf('/public/banners')}（首屏 1 次后不再发）');
      expect(adapter.countOf('/public/banners'), 1,
          reason: 'banners 60 秒档：本用例推进的假时钟（每趟约 1.7s）远在窗口内，回访必须完全走缓存');

      /**
       * 【2026-10-16 二轮：8 分钟 → 60 秒】原断言是 `ApiCache.ttlBanner.inMinutes >= 5`。
       *
       * 为什么必须重钉（**是收紧，不是放宽**）：负责人 2026-10-16 要求"换完图 1 分钟内可见"
       * —— 8 分钟档正是"换图后最长 8 分钟看不见"的成因，那条 `>= 5 分钟` 断言在保护**旧值**。
       * 新断言把值钉到**精确的 60 秒**（并等于运营档），比原来的区间断言更强；
       * 本条用例真正要保的语义（"新鲜窗口内回访零请求"）**一个字没改**，上面那条仍然在管它。
       */
      expect(ApiCache.instance.ttlFor('/public/banners'), ApiCache.ttlBanner);
      expect(ApiCache.ttlBanner, const Duration(seconds: 60),
          reason: '与服务端 Cache-Control(max-age=60) / 运营档 ttlOps 对齐：换图 ≤1 分钟可见');
      expect(ApiCache.ttlBanner, ApiCache.ttlOps);
    });

    testWidgets('对照：divisions 的 6 分钟档同样让回访零请求', (tester) async {
      final adapter = _HomeAdapter(aggregate: null, aggregateStatus: 404);
      final api = _api(adapter, 'ttl-div.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);
      expect(adapter.countOf('/divisions/grouped'), 1);

      ServicesPage.debugResetAggregateBreaker();
      ServicesPage.debugResetPrefetched();
      await tester.pumpWidget(MaterialApp(home: ServicesPage(key: const ValueKey('again'), api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drainShort(tester, adapter: adapter);

      expect(adapter.countOf('/divisions/grouped'), 1,
          reason: 'divisions 6 分钟档：回访必须命中缓存（这是"回访秒开"的主要来源）');
    });
  });

  // -------------------------------------------------------------------
  // ⑤ 红线回归：余额 / 订单 / 消息类**不会被本页引入缓存**
  // -------------------------------------------------------------------
  group('⑤ 红线：首屏改动没有把账号私有数据卷进缓存', () {
    testWidgets('服务页渲染全过程中，缓存里**没有任何** /user/ 私有条目', (tester) async {
      final adapter = _HomeAdapter(aggregate: aggregateData());
      final api = _api(adapter, 'redline.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drain(tester, adapter: adapter);

      final stats = ApiCache.instance.stats();
      // ignore: avoid_print
      print('[PERF] 服务页缓存统计：$stats');
      expect(stats, isNot(contains('/user/')), reason: '缓存条目里不许出现任何账号私有路径');
      expect(adapter.requests.any((p) => p.startsWith('/user/')), isFalse,
          reason: '服务页首屏本来就不该打 /user/* 私有接口（改动前后一致）');
    });

    testWidgets('预取路径也不会把私有接口写进缓存（本文件用**已登录**态再跑一遍首屏）', (tester) async {
      // 上一条是匿名态（预取不跑）。这一条给令牌让预取真跑，验证"预取清单里没有私有接口"。
      AuthStore.instance.debugSetSession(accessToken: 'redline-token');
      final adapter = _HomeAdapter(aggregate: aggregateData());
      final api = _api(adapter, 'redline-prefetch.local');

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'), adapter: adapter);
      await _drain(tester, adapter: adapter);

      // ignore: avoid_print
      print('[PERF] 已登录首屏：总请求=${adapter.requests.length} 统计=${ApiCache.instance.stats()}');
      expect(ApiCache.instance.stats(), isNot(contains('/user/')),
          reason: '预取清单（ApiClient.prefetch）刻意不含 /user/orders、/user/wallet、/user/conversations');
      expect(adapter.requests.any((p) => p.startsWith('/user/')), isFalse);
    });
  });
}
