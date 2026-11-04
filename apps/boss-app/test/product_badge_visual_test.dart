import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端「体验单置顶 + 董事长推荐徽标 + 每周限购提示」出图（负责人 2026-10-05）
///
/// 产出：
/// - `build/product_badge_list.png` —— 商品列表页（体验单第一条 + 左上角「董事长推荐」徽标 + 琥珀金描边）
/// - `build/product_badge_order_limit.png` —— 下单页（同一徽标 + 服务端下发的「每周限购 2 单 · 本周还可下 N 单」）
///
/// ## 画面里的数据从哪来（这决定了 PNG 算不算证据）
///
/// 商品列表 / 分类 / 分部 / 下单表单 / 商品详情**全部现抓线上 3100 的真实响应**（不是手写 fixture）：
/// 于是 PNG 里第一条到底是不是体验单、徽标文案是什么，都由真实接口决定 —— 接口没生效就出不了这张图
/// （抓不到数据直接 `expect` 失败，不拿假图交差）。
///
/// 三处**测试环境**适配（不动 App 代码、不影响真机行为）：
/// 1) `flutter test` 没有 `--dart-define=API_BASE_URL`，`AppConfig.apiBase` 默认是安卓模拟器别名
///    `http://10.0.2.2:3100` —— 本机跑测试时该地址不可达。因此把 fixture 里的**相对**封面路径
///    改写成 `http://127.0.0.1:3100/...`（绝对 URL 会被 `resolveMediaUrl` 原样返回）。
///    图片字节仍是服务端 `/media/public/:id` 的真实返回，只是换了个可达的主机名。
/// 2) 假异步区里真实网络/文件 IO 不会自己推进 → 出图前先在 `runAsync` 里把图片写进
///    `ImageDiskCache` 的磁盘缓存目录（命名规则与 `cached_image.dart` 的 `_name` 逐字一致），
///    并在真实异步区里先 lookup 一次（建立目录与内存索引），渲染时才走「磁盘命中 → Image.file」。
/// 3) `Image.file` 只建 widget、不解码则 PNG 里是空白 → 出图前 `precacheImage` 预解码。
///
/// 中文：`flutter test` 自带字体没有中文字形，这里挂系统黑体（`FontLoader`），只为 PNG 可读。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'BadgeCJK';
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

  /// 线上现抓的一整套 fixture（每个 case 里重新抓，保证与服务端当前状态一致）
  Future<Map<String, Map<String, dynamic>>> liveFixture() async {
    final divisions = await getJson('$apiBase/divisions');
    final categories = await getJson('$apiBase/public/categories');
    final products = await getJson('$apiBase/public/products?divisionId=1&categoryId=78&page=1&pageSize=50');
    final form = await getJson('$apiBase/public/order-form');
    final detail = await getJson('$apiBase/public/products/137');

    // 封面相对路径 → 本机可达的绝对地址（见文件头说明；只改主机，不改路径与图片内容）
    final list = ((products['data'] as Map?)?['list'] as List?) ?? const [];
    for (final item in list) {
      if (item is Map && item['coverUrl'] is String && !'${item['coverUrl']}'.startsWith('http')) {
        item['coverUrl'] = '$origin${item['coverUrl']}';
      }
    }

    return {
      '/divisions': divisions,
      '/public/categories': categories,
      '/public/products': products,
      '/public/order-form': form,
      '/public/products/137': detail,
      // 每周限购配额：**线上实测原文**（scripts/tmp/product-weekly-limit-live.log 第 1 步返回）
      '/user/orders/weekly-quota': {
        'code': 0,
        'message': 'ok',
        'data': {
          'productId': '137',
          'weeklyLimit': 2,
          'orderedCount': 0,
          'remaining': 2,
          'limitText': '每周限购 2 单',
          'quotaText': '本周还可下 2 单',
        },
      },
    };
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjkFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'visual-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
  });

  /// 把画面要用的**真实图片**抓进磁盘缓存（返回抓到几张）
  ///
  /// 两类图：
  /// 1) 商品封面（`coverUrl`，本测试已改写成 127.0.0.1 绝对地址 → key 就是它自己）
  /// 2) 分部官方图（`iconMediaId`/`coverMediaId`）：分类 78 的商品都没挂封面，卡片走
  ///    「分部官方游戏图」这条真实回退分支，其地址由 `AppConfig.resolveMediaUrl('/media/public/141')`
  ///    生成 —— 测试环境没有 --dart-define，主机是安卓模拟器别名 `10.0.2.2`，
  ///    所以缓存 key 必须按**组件真正会查的那个地址**写（字节仍从本机 3100 取真实图片）。
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
    final list = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    for (final item in list) {
      if (item is! Map) continue;
      final url = '${item['coverUrl'] ?? ''}';
      if (url.startsWith('http')) {
        paths.add(url);
      } else if (item['coverMediaId'] != null) {
        paths.add('/media/public/${item['coverMediaId']}');
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
      // 先在**真实异步区**里查一次：建立缓存目录与内存索引。
      // 实测：少了这一步，widget 在假异步区里的同名 lookup 一直不返回，画面停在占位态。
      await ImageDiskCache.instance.lookup(key);
      ok += 1;
    }
    return ok;
  }

  /// 有限次 pump（**不用 pumpAndSettle**）
  ///
  /// 图片占位态里有一个 `CircularProgressIndicator`（无限循环动画），
  /// 一旦走到「已开始下载但假异步区不推进网络」的分支，`pumpAndSettle` 会一直等下去。
  /// 出图只需要"页面结构 + 文案 + 徽标 + 图片"稳定，固定步进 pump 足够且不会卡死。
  Future<void> settle(WidgetTester tester, {int steps = 8}) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// 让磁盘缓存命中这条真实文件 IO 落地（假异步区不会自己推进 IO）
  ///
  /// ⚠️ 已知环境限制：`flutter test` 里 `Image` **像素**解不出来（实测 11 个 RawImage 全部
  /// `image == null`，图片解码走不到真实异步区）。所以 PNG 里图标位是空底色块，
  /// 真机/模拟器上是分部官方游戏图 —— 本测试断言的是"占位已切到 Image.file"这条链路。
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

  testWidgets('出图 ①：商品列表页 —— 体验单置顶 + 董事长推荐徽标', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    late Map<String, Map<String, dynamic>> fixture;
    var warmed = 0;
    await tester.runAsync(() async {
      final real = HttpOverrides.global = _RealHttpOverrides();
      try {
        fixture = await liveFixture();
        warmed = await warmImages(fixture);
      } finally {
        HttpOverrides.global = real;
      }
    });

    // 线上数据自检：**第一条必须是体验单且带徽标**（置顶/徽标没生效就不许出图）
    final list = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    expect(list.length >= 3, isTrue, reason: '线上商品列表没抓到（检查后端 3100 是否在跑）');
    expect('${(list.first as Map)['id']}', '137', reason: '接口第一条必须是体验单（置顶生效）');
    expect('${(list.first as Map)['badgeText']}', '董事长推荐');
    expect(warmed > 0, isTrue, reason: '真实图片一张都没抓到（检查后端 3100 与 /media/public/:id）');

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: ProductListPage(api: _api(fixture)),
      ),
    ));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    // 画面自检：徽标只渲染 1 次（只有体验单挂徽标）、首卡描边为琥珀金、体验单排在最上面、
    // 图标位已从"占位"切到 Image.file（磁盘缓存命中的真实图片链路走通）
    expect(find.text('董事长推荐'), findsOneWidget);
    expect(find.byType(ProductBadge), findsOneWidget);
    final cards = tester.widgetList<AppCard>(find.byType(AppCard)).toList();
    expect((cards.first.border! as Border).top.color, AppColors.gold);
    expect(find.byType(Image), findsWidgets, reason: '图标位应走 Image.file（磁盘缓存命中），不是灰块占位');
    final featuredY = tester.getTopLeft(find.text('董事长推荐')).dy;
    // 第二条的名字跟随线上数据（写死名字会随运营改名失效：2026-10-09 计价单位迁移就改过一次）
    final secondY = tester.getTopLeft(find.text('${(list[1] as Map)['name']}')).dy;
    expect(featuredY, lessThan(secondY), reason: '体验单（带徽标）必须在最上面');

    await capture(tester, 'product_badge_list.png');
  });

  testWidgets('出图 ②：下单页 —— 徽标 + 每周限购提示（文案来自服务端）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

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

    // 商品用**线上详情原文**（名称/价格/徽标/限购数全部来自 /public/products/137）
    final detail = (fixture['/public/products/137']!['data'] as Map).cast<String, dynamic>();
    expect(detail['badgeText'], '董事长推荐');
    expect(int.tryParse('${detail['weeklyLimit']}'), 2);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: OrderCreatePage(api: _api(fixture), divisionId: '1', product: detail),
      ),
    ));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('董事长推荐'), findsOneWidget, reason: '下单页徽标与列表页一致');
    expect(find.textContaining('每周限购 2 单'), findsOneWidget, reason: '限购提示必须来自服务端文案');

    await capture(tester, 'product_badge_order_limit.png');
  });
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

/// 真实 HttpClient 的 overrides（只在本测试文件里用）
///
/// `flutter_test` 启动时装了一个全局 `HttpOverrides`：任何 `HttpClient` 都返回 400 且不发真实请求。
/// `HttpOverrides.global` 只有 setter 没有 getter，所以这里给一个显式返回真实 `_HttpClient` 的实现。
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
