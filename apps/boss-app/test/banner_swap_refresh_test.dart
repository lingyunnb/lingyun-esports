/// **换宣传图后的"秒刷新 + 不等转圈"**（2026-10-16 负责人「加秒刷新 + 不要在等转圈」· boss-app 侧）
///
/// ## 三道口径（本文件逐条钉死）
/// 1. **旧图留屏上**：换图后回源期间，页面上**仍是旧宣传图**（不是空白、不是骨架、不是转圈）；
/// 2. **静默替换**：新数据回来原地替换（宣传图框体**恒 156** —— 2026-10-16 负责人二次定案
///    「图片展示大小还是原来的、上传的图片自动拉伸」，图片走 `BoxFit.fill` 拉伸铺满），
///    全程 `CircularProgressIndicator` 一个都不可见；
/// 3. **不吃缓存**：下拉刷新 / 回前台 / 切回本 tab 三条路径都 `forceRefresh: true`，
///    运营改完不必等 TTL 到点（TTL 只是"没人操作时的兜底新鲜度"）。
///
/// ## 为什么"旧图留屏上"能在页面级测出来
/// 服务页的骨架口径是 `_loading = _divisions.isEmpty` —— **已经有数据时刷新不清空、不转圈**，
/// 新数据回来才 `setState` 原地替换（见 `services_page.dart` 的 `_load`）。
/// 图片那一层另有空窗：换图后 `mediaId` 变 → 新地址不在磁盘缓存里 → 由
/// `CachedNetImage.keepPreviousOnUrlChange` 把旧图留屏上（core 侧另有专项测试）。
/// 本文件用**可控延迟的假通道**把"回源还在飞"的那一刻稳定地抓下来，两层一起验。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一次网络往返的替身（与 `perf_first_paint_test` 同一口径）
const Duration kRtt = Duration(milliseconds: 120);

/// 框体高度 = **16:9 通栏**（方案 G 2026-10-17：390 × 219.375）。
///
/// 2026-10-16 那版是"恒 156 + `BoxFit.fill` 拉伸"；方案 G 把首页宣传图定为稿内的
/// 16:9 通栏，于是老板端首页给 `HomeBannerCarousel.frameHeight` 传 16:9
/// （组件默认仍是 156，core 侧那批几何用例一个字没改）。
/// 图片尺寸（1920×1080 也一样）仍**不参与定高**；图片走 `BoxFit.fill` 拉伸铺满。
const double kBannerHeightFixed = 390 * 9 / 16;

Map<String, dynamic> _envelope(Object? data) =>
    <String, dynamic>{'code': 0, 'message': 'ok', 'data': data};

/// 线上宣传图的真实形状（`media` 292/293、1920×1080，线上实测返回 imageWidth/imageHeight）
Map<String, dynamic> banner(String mediaId, String title) => <String, dynamic>{
      'id': mediaId == '292' ? '136' : '137',
      'title': title,
      'subtitle': '',
      'imageMediaId': mediaId,
      'imageUrl': '',
      'imageWidth': 1920,
      'imageHeight': 1080,
      'linkType': 'none',
      'linkValue': '',
      'sortOrder': 0,
      'startAt': null,
      'endAt': null,
    };

/// 首页聚合体的完整形状（与 `PublicHomeService.aggregate` 一致：五段 + updatedAt）
Map<String, dynamic> aggregate(String mediaId, String title, {bool noBanners = false}) => <String, dynamic>{
      'announcements': <dynamic>[],
      'banners': noBanners ? <dynamic>[] : <dynamic>[banner(mediaId, title)],
      'divisions': <dynamic>[
        <String, dynamic>{
          'id': '1',
          'code': 'peace_mobile',
          'gameId': '35',
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
      'hotProducts': <dynamic>[
        <String, dynamic>{'id': 'p1', 'name': '上分陪练', 'price': '38.00'},
      ],
      'players': <dynamic>[
        <String, dynamic>{'workerId': 'w1', 'nickname': '陪玩甲', 'intro': '只接三角洲手游'},
      ],
      'leaderboard': <dynamic>[
        <String, dynamic>{'rank': 1, 'nickname': '陪玩甲', 'value': 2847},
      ],
      'updatedAt': '2026-10-16T10:00:00.000Z',
    };

/// 可变假通道：运营"换图"就改 [mediaId]/[title]；[delay] 用来把"回源还在飞"的那一刻钉住
class _SwapAdapter implements HttpClientAdapter {
  _SwapAdapter({this.noBanners = false});

  /// 服务端当前那条宣传图的 `imageMediaId`（运营换图就改它）
  String mediaId = '292';

  /// 服务端当前那条宣传图的标题
  String title = '欢迎光临祁连山电竞';

  /// 管理端一张都没配（空 banners）
  bool noBanners;

  /// 所有路径的基础延迟（首屏 120ms；要看 flight 期间的状态时调大，如 500ms）
  Duration delay = kRtt;

  final List<String> requests = <String>[];

  int countOf(String path) => requests.where((p) => p.startsWith(path)).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.path);
    await Future<void>.delayed(delay);
    return ResponseBody.fromString(
      jsonEncode(_envelope(_body(options.path))),
      200,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  /// 各路径的 payload（改写成 if 链：三元套娃已经不可读了）
  Object? _body(String path) {
    if (path.startsWith('/public/home')) return aggregate(mediaId, title, noBanners: noBanners);
    if (path.startsWith('/public/banners')) return noBanners ? <dynamic>[] : <dynamic>[banner(mediaId, title)];
    // 2026-10-18：首页新增商品双列列表（底部官方馆已删）→ 这里补一条商品，否则内容区会落到
    // 「暂无服务」空态，而 case ③ 断言"页面不出现『暂无』字样"（那条断言的本意是
    // "轮播空态不许写占位假话"，不该被商品空态误伤）。
    // 商品**不给封面**（无 coverUrl / coverMediaId）：case ① 断言"页面上每个 CachedNetImage
    // 都开了 keepPreviousOnUrlChange"，多一张没开的图会误判。
    if (path.startsWith('/public/products')) {
      return <String, dynamic>{
        'list': <dynamic>[
          <String, dynamic>{
            'id': 'p1',
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
      };
    }
    // `/public/site` 的消费方按 Map 解析（本页已不再请求它，留着不碍事）
    if (path.startsWith('/public/site')) {
      return <String, dynamic>{'clubTitle': '官方自营', 'clubParagraphs': <String>['全段位上分与护航']};
    }
    // 其余公开接口（充值配置 / 分类 / 公告）一律 null：调用方按"这份数据没有"处理
    return null;
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _api(_SwapAdapter adapter, String host) {
  final dio = Dio(BaseOptions(baseUrl: 'http://$host/api/v1'))..httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 推进假时钟直到 [finder] 命中（返回推进量 ms；超时 -1）
Future<int> _pumpUntil(WidgetTester tester, Finder finder, {int maxMs = 6000, int step = 10}) async {
  var ms = 0;
  while (ms < maxMs) {
    await tester.pump(Duration(milliseconds: step));
    ms += step;
    if (finder.evaluate().isNotEmpty) return ms;
  }
  return -1;
}

/// 收尾：把后台遗留的请求/定时器排空（不排干净会以 pending timer 污染下一条用例）
Future<void> _drain(WidgetTester tester, {int maxMs = 4000}) async {
  for (var spent = 0; spent < maxMs; spent += 1000) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

/// 页面上有没有"转圈"（宣传图那块与内容区都不该有）
Finder get _spinner => find.byType(CircularProgressIndicator);

/// 宣传图框体高度（**恒 156**，与图片尺寸无关；换图前后都不许跳）
double _bannerHeight(WidgetTester tester) => tester.getSize(find.byType(HomeBannerCarousel)).height;

/// 与设计稿同框：390 × 844（**必须改 `tester.view.physicalSize`** —— 只改 `MediaQuery.data.size`
/// 不会改渲染视口，那样通栏会按默认 800 宽渲染，框体尺寸就不是 390 × 156 了）
void sizeView(WidgetTester tester, [Size size = const Size(390, 844)]) {
  tester.view.physicalSize = Size(size.width * 3, size.height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
    ApiCache.instance.debugClockOffset = Duration.zero;
    // 匿名态：首屏上屏后的自动预取（要求 token）不会发 → 请求计数干净可比
    AuthStore.instance.debugSetSession(accessToken: null);
    RealtimeClient.shared.debugDisabled = true;
    ServicesPage.debugResetAggregateBreaker();
    ServicesPage.debugResetPrefetched();
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    AuthStore.debugStorageDisabled = false;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.debugClockOffset = Duration.zero;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  // -------------------------------------------------------------------
  // ① 换图：回源期间旧图留屏上 + 静默替换 + 全程不转圈
  // -------------------------------------------------------------------
  group('① 换图（force 回源）：旧图留屏上、没有转圈、原地换成新图', () {
    testWidgets('切回本 tab 期间仍是旧图；新数据回来静默替换（全程 0 个转圈）', (tester) async {
      final adapter = _SwapAdapter();
      final api = _api(adapter, 'banner-swap.local');
      final signal = ValueNotifier<int>(0);
      addTearDown(signal.dispose);
      sizeView(tester);

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api, refreshSignal: signal)));
      await _pumpUntil(tester, find.text('欢迎光临祁连山电竞'));
      await _drain(tester);

      expect(find.text('欢迎光临祁连山电竞'), findsOneWidget);
      expect(find.byType(HomeBannerCarousel), findsOneWidget);
      expect(_bannerHeight(tester), closeTo(kBannerHeightFixed, 0.01),
          reason: '框体恒 156（负责人 2026-10-16 二次定案：图片展示大小还是原来的）');
      // ignore: avoid_print
      print('[SWAP] 框体：宽=${tester.getSize(find.byType(HomeBannerCarousel)).width} '
          '高=${_bannerHeight(tester)}（恒 156，图片 1920×1080 走 BoxFit.fill 拉伸铺满）');
      expect(_spinner, findsNothing, reason: '首屏上屏后不该有转圈');

      // 运营换图，并把回源变慢 → 把"还在飞"的那一刻稳定抓下来
      adapter.mediaId = '293';
      adapter.title = '和平补偿制度';
      adapter.delay = const Duration(milliseconds: 500);
      final before = adapter.countOf('/public/home');

      signal.value++; // 切回服务页 tab → _load(force: true)
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 200)); // 回源还在飞

      expect(find.text('欢迎光临祁连山电竞'), findsOneWidget, reason: '回源期间旧图留屏上（不是空白/骨架）');
      expect(find.text('和平补偿制度'), findsNothing, reason: '新数据还没到，不该提前显示');
      expect(_spinner, findsNothing, reason: '负责人要的"不要在等转圈"：回源期间不许有转圈');
      expect(_bannerHeight(tester), closeTo(kBannerHeightFixed, 0.01), reason: '框体高度不因回源而抖动');

      await _drain(tester);
      // ignore: avoid_print
      print('[SWAP] 换图：/public/home 请求数 $before → ${adapter.countOf('/public/home')}（force 路径真回源）');
      expect(adapter.countOf('/public/home'), greaterThan(before),
          reason: 'force 路径必须真回源 —— 这是"换图 1 分钟内可见"的主动路径，不吃 TTL');
      expect(find.text('和平补偿制度'), findsOneWidget, reason: '新图原地替换（静默，不闪骨架）');
      expect(find.text('欢迎光临祁连山电竞'), findsNothing);
      expect(_spinner, findsNothing, reason: '替换全程无转圈');
      expect(_bannerHeight(tester), closeTo(kBannerHeightFixed, 0.01), reason: '换完图仍是 156，高度永不跳');
    });

    testWidgets('照片那张图的 URL 真的换成了新 mediaId（不是只换了文案）', (tester) async {
      final adapter = _SwapAdapter();
      final api = _api(adapter, 'banner-swap-url.local');
      final signal = ValueNotifier<int>(0);
      addTearDown(signal.dispose);
      sizeView(tester);

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api, refreshSignal: signal)));
      await _pumpUntil(tester, find.text('欢迎光临祁连山电竞'));
      await _drain(tester);

      List<String> urls() =>
          tester.widgetList<CachedNetImage>(find.byType(CachedNetImage)).map((w) => w.url).toList();

      expect(urls().any((u) => u.contains('/media/public/292')), isTrue,
          reason: '首屏取的是 mediaId=292（线上第一条）');
      expect(
        tester.widgetList<CachedNetImage>(find.byType(CachedNetImage)).every((w) => w.keepPreviousOnUrlChange),
        isTrue,
        reason: '轮播里的图都开了"旧图留屏上"——换图时（mediaId 变）它才起作用',
      );

      adapter.mediaId = '293';
      adapter.title = '和平补偿制度';
      signal.value++;
      await _drain(tester);

      expect(urls().any((u) => u.contains('/media/public/293')), isTrue, reason: '换图后取的是新地址');
      expect(urls().any((u) => u.contains('/media/public/292')), isFalse, reason: '旧地址不再被引用');
    });
  });

  // -------------------------------------------------------------------
  // ② 下拉刷新：真绕过缓存拿到新图
  // -------------------------------------------------------------------
  group('② 下拉刷新：force 回源拿到新图（运营改完不必等 60 秒）', () {
    testWidgets('下拉刷新后，宣传图与文案都换成新的，且没有转圈', (tester) async {
      final adapter = _SwapAdapter();
      final api = _api(adapter, 'banner-pull.local');
      sizeView(tester);

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('欢迎光临祁连山电竞'));
      await _drain(tester);
      final before = adapter.countOf('/public/home');

      adapter.mediaId = '293';
      adapter.title = '和平补偿制度';

      // 下拉刷新（RefreshIndicator → _load(force: true)）
      await tester.fling(find.byType(ListView), const Offset(0, 320), 1200);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // ignore: avoid_print
      print('[SWAP] 下拉刷新：/public/home 请求数 $before → ${adapter.countOf('/public/home')}');
      expect(adapter.countOf('/public/home'), greaterThan(before), reason: '下拉刷新必须真回源（绕 TTL）');
      expect(find.text('和平补偿制度'), findsOneWidget);
      expect(_spinner, findsNothing);
    });
  });

  // -------------------------------------------------------------------
  // ③ 没有宣传图时行为逐字不变（零占位 + 不占高）
  // -------------------------------------------------------------------
  group('③ 管理端一张都没配：轮播零占位（不占高、不显示灰块）', () {
    testWidgets('banners 为空 → 高度 0，页面其它区块照常渲染', (tester) async {
      final adapter = _SwapAdapter(noBanners: true);
      final api = _api(adapter, 'banner-empty.local');
      sizeView(tester);

      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
      await _pumpUntil(tester, find.text('精选服务'));
      await _drain(tester);

      expect(find.byType(HomeBannerCarousel), findsOneWidget);
      expect(tester.getSize(find.byType(HomeBannerCarousel)).height, 0,
          reason: '空态零占位（既有硬要求）：不显示灰块、不占高度');
      expect(find.textContaining('暂无'), findsNothing);
      expect(find.text('投诉客服'), findsOneWidget, reason: '页面其它区块照常渲染（三宫格入口仍在）');
      expect(tester.takeException(), isNull);
    });
  });
}
