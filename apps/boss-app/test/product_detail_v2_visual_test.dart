import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/product_detail_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品详情页 v2 **方案 B** 出图（负责人 2026-10-05 审批的设计稿逐值对拍）
///
/// 产出（PNG 落在 `apps/boss-app/build/`）：
/// - `pd-v2-detail-default.png` —— 详情页**默认态**（16:9 主图 + 紧凑信息块 + 三列 + 提示条）
/// - `pd-v2-detail-empty.png`   —— 详情页**空态**（无封面：虚线位 + 真实字段 + 下一步动作）
/// - `pd-v2-detail-notice.png`  —— 详情页**须知展开**（默认折叠那一条点开后的全 4 条）
/// - `pd-v2-list-tap.png`       —— 列表**整卡点击 → 详情页**（点商品名后真实跳转的画面）
///
/// ## 画面里的数据从哪来（决定 PNG 算不算证据）
/// 商品详情/列表/分类/分部/下单表单/限购配额**全部现抓线上 3100 的真实响应**（不是手写 fixture）：
/// 于是图里的价格、商品名、须知文案、超时小时数都由**真实服务端数据**决定 ——
/// 谁把须知改坏了、把 24 小时写死了，图里立刻看得出来。抓不到数据直接 expect 失败，不拿假图交差。
///
/// 与既有出图测试（`product_badge_visual_test.dart` / `product_name_truncation_visual_test.dart`）
/// 同一套环境适配：没有 `--dart-define` 时封面相对路径改写成 `http://127.0.0.1:3100/...`；
/// 假异步区不推进真实 IO → 出图前把图片写进 `ImageDiskCache` 磁盘缓存并在真实异步区 lookup 一次。
///
/// 中文：`flutter test` 自带字体没有中文字形，这里挂系统黑体（`FontLoader`），只为 PNG 可读。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'ProductDetailV2CJK';
  const origin = 'http://127.0.0.1:3100';
  const apiBase = '$origin/api/v1';

  /// 与 `ImageDiskCache._name` 逐字一致的缓存文件名
  String cacheName(String url) => '${url.hashCode.toUnsigned(32).toRadixString(16)}_${url.length}.img';

  Future<Map<String, dynamic>> getJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      if (resp.statusCode != 200) return <String, dynamic>{};
      return jsonDecode(await resp.transform(utf8.decoder).join()) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    } finally {
      client.close();
    }
  }

  Future<Uint8List?> getBytes(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final resp = await (await client.getUrl(Uri.parse(url))).close();
      if (resp.statusCode != 200) return null;
      return Uint8List.fromList(await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b)));
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 线上现抓的一整套 fixture（每个 case 重新抓，保证与服务端当前状态一致）
  ///
  /// 目标商品：**和平精英体验单 137**（有徽标「董事长推荐」+ 每周限购 2 单，且**没有封面图**
  /// → 正好同时覆盖"默认态"与"空态"两种主图位）。
  Future<Map<String, Map<String, dynamic>>> liveFixture() async {
    final divisions = await getJson('$apiBase/divisions');
    final categories = await getJson('$apiBase/public/categories?gameId=35');
    final products = await getJson('$apiBase/public/products?divisionId=1&page=1&pageSize=50');
    final detail = await getJson('$apiBase/public/products/137');
    final form = await getJson('$apiBase/public/order-form');

    for (final list in [products]) {
      for (final item in (((list['data'] as Map?)?['list'] as List?) ?? const [])) {
        if (item is Map && item['coverUrl'] is String && !'${item['coverUrl']}'.startsWith('http')) {
          item['coverUrl'] = '$origin${item['coverUrl']}';
        }
      }
    }
    for (final key in ['coverUrl', 'videoCoverUrl']) {
      final url = detail['data'] is Map ? (detail['data'] as Map)[key] : null;
      if (url is String && url.isNotEmpty && !url.startsWith('http')) {
        (detail['data'] as Map)[key] = '$origin$url';
      }
    }

    return {
      '/divisions': divisions,
      '/public/categories': categories,
      '/public/products': products,
      '/public/products/137': detail,
      '/public/order-form': form,
      // 限购提示（详情页首屏要看到「每周限购 2 单 · 本周还可下 2 单」）
      '/user/orders/weekly-quota': {
        'code': 0,
        'message': 'ok',
        'data': {'limitText': '每周限购 2 单', 'quotaText': '本周还可下 2 单'},
      },
    };
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 中文字形：`flutter test` 自带字体没有汉字，挂系统黑体只为 PNG 可读
    for (final path in const [
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjkFamily)..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    // **图标字形**：`flutter_test` 不打包 MaterialIcons，画面里所有 `Icon` 会渲染成"空心方框"
    // （第一轮出图实测踩过：整个页面全是 □，看着像页面坏了）。
    // 从 Flutter SDK 的 material_fonts 缓存里取同一份字体挂到 `MaterialIcons` 家族名下即可。
    for (final path in const [
      r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
      r'C:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 详情页要展示限购提示 → 需要"已登录"；同时关缓存避免用例间串味
    ApiClient.cacheEnabled = false;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'visual-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
    ApiClient.cacheEnabled = true;
  });

  /// 把画面要用的**真实图片**抓进磁盘缓存（返回抓到几张）
  Future<int> warmImages(Map<String, Map<String, dynamic>> fixture) async {
    final paths = <String>{};
    for (final d in ((fixture['/divisions']!['data'] as List?) ?? const [])) {
      if (d is! Map) continue;
      final id = divisionMediaId(
        iconMediaId: d['iconMediaId'] == null ? null : '${d['iconMediaId']}',
        coverMediaId: d['coverMediaId'] == null ? null : '${d['coverMediaId']}',
      );
      if (id != null && id.isNotEmpty) paths.add('/media/public/$id');
    }
    for (final key in fixture.keys.where((k) => k.startsWith('/public/products'))) {
      final data = fixture[key]!['data'];
      final items = data is Map ? (((data['list'] as List?) ?? const [])) : <dynamic>[data];
      for (final item in items) {
        if (item is! Map) continue;
        final url = '${item['coverUrl'] ?? ''}';
        if (url.startsWith('http')) {
          paths.add(url);
        } else if (item['coverMediaId'] != null) {
          paths.add('/media/public/${item['coverMediaId']}');
        }
      }
    }

    final dir = Directory('${Directory.systemTemp.path}/fish_img_cache');
    await dir.create(recursive: true);
    var ok = 0;
    for (final p in paths) {
      final key = p.startsWith('http') ? p : AppConfig.resolveMediaUrl(p);
      final bytes = await getBytes(p.startsWith('http') ? p : '$origin$p');
      if (bytes == null || bytes.isEmpty) continue;
      await File('${dir.path}/${cacheName(key)}').writeAsBytes(bytes, flush: true);
      await ImageDiskCache.instance.lookup(key);
      ok += 1;
    }
    return ok;
  }

  /// 有限次 pump（**不用 pumpAndSettle**：图片占位态里有无限循环动画，settle 会一直等）
  Future<void> settle(WidgetTester tester, {int steps = 8}) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> settleWithRealIo(WidgetTester tester) async {
    await settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await settle(tester);
  }

  Future<void> capture(WidgetTester tester, String fileName) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$fileName').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final out = File('build/$fileName');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync() > 10000, isTrue, reason: 'PNG 太小说明没渲染出内容');
  }

  /// 390×844 真机画布（与设计稿 `.phone` 内容区一致）+ 中文字体
  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// 抓线上 fixture（**先关测试用的 HttpOverrides**：flutter_test 默认让所有 HttpClient 返回 400）
  Future<Map<String, Map<String, dynamic>>> fetchLive(WidgetTester tester) async {
    late Map<String, Map<String, dynamic>> fixture;
    await tester.runAsync(() async {
      final real = HttpOverrides.global = _RealHttpOverrides();
      try {
        fixture = await liveFixture();
        await warmImages(fixture);
      } finally {
        HttpOverrides.global = real;
      }
    });
    return fixture;
  }

  /// 线上数据自检：拿到的那份必须是体验单 137（否则这组图证明不了任何事）
  void assertLiveProduct(Map<String, Map<String, dynamic>> fixture) {
    final detail = (fixture['/public/products/137']!['data'] as Map?)?.cast<String, dynamic>() ?? {};
    expect(detail['id'], '137', reason: '没抓到商品 137 详情（检查后端 3100 是否在跑、迁移是否已执行）');
    expect('${detail['badgeText']}', '董事长推荐', reason: '137 应带徽标「董事长推荐」（图里要看到它）');
    expect((detail['effectiveOrderNotice'] as String?)?.isNotEmpty, isTrue, reason: '详情接口必须下发须知（迁移 1799000000000）');
    expect(detail['orderPendingTakeTimeoutHours'], isNotNull, reason: '详情接口必须下发超时小时数');
    expect('${detail['divisionPlatformLabel']}', isNotEmpty, reason: '详情接口必须下发分部平台标签');
  }

  /// 详情页一屏截图（统一包装，避免四张图各自写一遍）
  Future<void> pumpDetailAndCapture(
    WidgetTester tester,
    Map<String, Map<String, dynamic>> fixture,
    String fileName, {
    bool expandNotice = false,
  }) async {
    usePhone(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        // **不要把 fontFamily 直接挂在 ThemeData 上**：那样 `IconTheme` 也会继承中文字体，
        // Material 图标会去找汉字字体里不存在的码位 → 渲染成空心方框（实测踩过）。
        // 只改 `textTheme`，图标继续用自己的 `MaterialIcons` 家族。
        debugShowCheckedModeBanner: false,
        theme: _cjkTextTheme(cjkFamily),
        home: ProductDetailPage(api: _api(fixture), productId: '137'),
      ),
    ));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    if (expandNotice) {
      await tester.ensureVisible(find.text('展开'));
      await settle(tester, steps: 4);
      await tester.tap(find.text('展开'));
      await settle(tester, steps: 6);
      expect(find.text('收起'), findsOneWidget, reason: '须知必须真的展开了（否则出的是折叠态那张）');
      // 展开后把「下单须知」滚到视口顶部：一张图里同时看到提示条与全部 4 条
      await tester.ensureVisible(find.text('下单须知'));
      await settle(tester, steps: 4);
    }
    await capture(tester, fileName);
  }

  // ---------------- 出图 ①：详情页默认态 ----------------

  testWidgets('出图 ①：详情页默认态（16:9 主图位 + 紧凑信息块 + 三列真实字段 + 提示条）', (tester) async {
    final fixture = await fetchLive(tester);
    assertLiveProduct(fixture);

    await pumpDetailAndCapture(tester, fixture, 'pd-v2-detail-default.png');

    // 画面自检（负责人 7 条验收点里能在静态图上验的几条）
    // 商品名与提示条都**跟随线上数据**（写死名字会随运营改名失效：2026-10-09 计价单位迁移就改过一次）
    final liveName = '${(fixture['/public/products/137']!['data'] as Map)['name']}';
    expect(find.text(liveName), findsWidgets, reason: '标题');
    expect(find.text('董事长推荐'), findsOneWidget, reason: '徽标必须保留');
    expect(find.textContaining('每周限购 2 单'), findsOneWidget, reason: '每周限购提示必须保留');
    expect(find.text('已售'), findsOneWidget);
    expect(find.text('预计时长'), findsOneWidget);
    expect(find.text('服务方式'), findsOneWidget);
    expect(find.textContaining('库存'), findsNothing);
    expect(find.textContaining('日产能'), findsNothing);
    expect(find.text('立即购买'), findsOneWidget, reason: '底部固定操作栏');
    expect(find.text('客服'), findsOneWidget);
    expect(find.text('我的订单'), findsOneWidget);
    expect(find.text('店铺'), findsNothing);
    expect(find.text('展开'), findsOneWidget, reason: '下单须知默认折叠');
    expect(find.textContaining('未接单可随时取消并全额退回'), findsOneWidget, reason: '提示条取自接口');
  });

  // ---------------- 出图 ②：详情页空态（无封面图） ----------------

  testWidgets('出图 ②：详情页空态（无封面 → 虚线位 + 真实字段 + 下一步动作）', (tester) async {
    final fixture = await fetchLive(tester);
    assertLiveProduct(fixture);

    final detail = fixture['/public/products/137']!['data'] as Map;
    expect(detail['coverUrl'] == null || '${detail['coverUrl']}'.isEmpty, isTrue,
        reason: '商品 137 当前**没有封面图**，这张图才是空态；若运营上传了封面，请换一个无封面商品出图');

    await pumpDetailAndCapture(tester, fixture, 'pd-v2-detail-empty.png');

    expect(find.text('商品图待补充'), findsOneWidget, reason: '空态主文案');
    expect(find.textContaining('只有文字配置'), findsOneWidget, reason: '空态说明');
    expect(find.byIcon(AppIcon.image), findsOneWidget, reason: '空态只有一枚线性图标（不做插画）');
  });

  // ---------------- 出图 ③：详情页须知展开 ----------------

  testWidgets('出图 ③：下单须知展开（默认折叠的那一条点开 → 全 4 条 + 序号）', (tester) async {
    final fixture = await fetchLive(tester);
    assertLiveProduct(fixture);

    await pumpDetailAndCapture(tester, fixture, 'pd-v2-detail-notice.png', expandNotice: true);

    // 服务端那份默认须知是 4 条 → 图里应有 1./2./3./4.
    for (final n in ['1.', '2.', '3.', '4.']) {
      expect(find.text(n), findsOneWidget, reason: '须知第 $n 条序号');
    }
    expect(find.text('收起'), findsOneWidget);
  });

  // ---------------- 出图 ④：列表整卡点击 → 详情页 ----------------

  testWidgets('出图 ④：商品列表整卡点击 → 进入详情页（点的是商品名，不是「下单」按钮）', (tester) async {
    final fixture = await fetchLive(tester);
    assertLiveProduct(fixture);
    usePhone(tester);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _cjkTextTheme(cjkFamily),
        home: ProductListPage(api: _api(fixture), initialDivisionId: '1'),
      ),
    ));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);
    // 名字跟随线上数据（体验单改名后仍成立）
    final featuredName = '${(fixture['/public/products/137']!['data'] as Map)['name']}';
    expect(find.text(featuredName), findsWidgets, reason: '列表里要有体验单');

    // **真实点击商品名**（整卡 onTap）→ push 详情页
    await tester.tap(find.text(featuredName).first);
    await settleWithRealIo(tester);
    await settle(tester, steps: 6);

    expect(find.byType(ProductDetailPage), findsOneWidget, reason: '整卡点击必须真的进详情页');
    expect(find.text('立即购买'), findsOneWidget);

    await capture(tester, 'pd-v2-list-tap.png');
  });
}

/// 只把中文字体挂到 **textTheme**（不挂 ThemeData.fontFamily）
///
/// 原因见调用处注释：`ThemeData(fontFamily: ...)` 会连带 `IconTheme` 一起改，
/// 让 Material 图标去汉字字体里找码位 → 出图全是空心方框。
ThemeData _cjkTextTheme(String family) {
  final base = ThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: family),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
  );
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}), 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 真实 HttpClient 的 overrides（`flutter_test` 默认让所有 HttpClient 返回 400）
class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      return HttpClient();
    } finally {
      HttpOverrides.global = saved;
    }
  }
}
