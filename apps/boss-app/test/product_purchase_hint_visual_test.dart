import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「购买提示」小字出图（负责人 2026-10-05）
///
/// 产出（PNG 落在 apps/boss-app/build/）：
/// - `product_list_purchase_hint.png` —— **选择服务页整页**：底部常驻那一行小字（真库文案）
/// - `product_list_purchase_hint_scrolled.png` —— 商品列表**滚到底**：提示条与最后一张商品卡
///   同时入画（证明它是贴底常驻、不遮挡列表内容，且与卡片之间有发丝线分隔）
///
/// ## 画面里的数据从哪来（决定 PNG 算不算证据）
/// 分部/分类/商品/**购买提示文案**全部现抓线上 3100 的真实响应（不是手写 fixture）：
/// PNG 里那行字就是**服务端 system_setting.purchase_points_hint 的当前值** —— 迁移写库的
/// 默认文案（负责人原文，订正「人名币」→「人民币」）或运营改过的值，抓不到直接 expect 失败。
///
/// 三处测试环境适配（与既有出图测试 product_list_name_visual_test.dart 完全一致，不改 App 代码）：
/// 1) 没有 --dart-define 时 `AppConfig.apiBase` 是模拟器别名 10.0.2.2 → 封面相对路径改写成
///    `http://127.0.0.1:3100/...`（只换主机，图片字节仍是服务端真实返回）；
/// 2) 假异步区不推进真实 IO → 出图前把图片写进 `ImageDiskCache` 的磁盘缓存目录并在真实异步区 lookup 一次；
/// 3) `Image.file` 只建 widget 不解码则 PNG 里是空白 → 先 `precacheImage` 预解码。
///
/// 中文：`flutter test` 自带字体没有中文字形，这里挂系统黑体（`FontLoader`），只为 PNG 可读。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'PurchaseHintVisualCJK';
  const origin = 'http://127.0.0.1:3100';
  const apiBase = '$origin/api/v1';
  const divisionId = '1';

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

  /// 线上现抓的 fixture（每个用例重新抓，保证与服务端当前状态一致）
  Future<Map<String, Map<String, dynamic>>> liveFixture() async {
    final divisions = await getJson('$apiBase/divisions');
    final categories = await getJson('$apiBase/public/categories?gameId=35');
    final products = await getJson('$apiBase/public/products?divisionId=$divisionId&page=1&pageSize=50');
    final hint = await getJson('$apiBase/public/purchase-hint');
    final form = await getJson('$apiBase/public/order-form');

    for (final item in (((products['data'] as Map?)?['list'] as List?) ?? const [])) {
      if (item is Map && item['coverUrl'] is String && !'${item['coverUrl']}'.startsWith('http')) {
        item['coverUrl'] = '$origin${item['coverUrl']}';
      }
    }

    return {
      '/divisions': divisions,
      '/public/categories': categories,
      '/public/products': products,
      // 购买提示：**真·服务端当前文案**（本组图要证明的就是它）
      '/public/purchase-hint': hint,
      '/public/order-form': form,
      '/user/orders/weekly-quota': {'code': 401, 'message': '未登录', 'data': null},
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
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
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
    for (final item in (((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [])) {
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

  Future<void> pumpPhone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(theme: ThemeData(fontFamily: cjkFamily), home: child),
    ));
  }

  // ---------------- 出图 ①：选择服务页整页（底部常驻那行小字）----------------

  testWidgets('出图 ①：选择服务页 —— 底部常驻「购买提示」小字（真库文案，2 行内不截断）', (tester) async {
    late Map<String, Map<String, dynamic>> fixture;
    await tester.runAsync(() async {
      // `flutter_test` 默认让所有 HttpClient 返回 400 → 抓线上数据前必须换回真 HttpClient
      final real = HttpOverrides.global = _RealHttpOverrides();
      try {
        fixture = await liveFixture();
        await warmImages(fixture);
      } finally {
        HttpOverrides.global = real;
      }
    });

    final text = '${((fixture['/public/purchase-hint']!['data'] as Map?)?['text'] ?? '')}'.trim();
    expect(text.isNotEmpty, isTrue, reason: '线上购买提示为空 —— 检查迁移 1800000000000 是否已跑 / 后端 3100 是否在跑');
    expect(text.contains('余额'), isTrue, reason: '口径 2026-10-09：购买提示必须说「余额」，实际："$text"');
    expect(text.contains('积分'), isFalse, reason: '旧单位不得再出现，实际："$text"');
    expect(text.contains('不可提现'), isTrue, reason: '合规口径必须写明不可提现，实际："$text"');

    await pumpPhone(tester, ProductListPage(api: _api(fixture), initialDivisionId: divisionId));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    final finder = find.descendant(of: find.byKey(purchaseHintBarKey), matching: find.text(text));
    expect(finder, findsOneWidget, reason: '选择服务页必须显示服务端下发的那行小字');

    // 与行为测试同一口径的兜底自查：2 行内、没有被省略号切掉
    final t = tester.widget<Text>(finder);
    expect(t.maxLines, 2);
    expect(t.overflow, isNot(TextOverflow.ellipsis));
    final para = tester.renderObject<RenderParagraph>(find.descendant(of: finder, matching: find.byType(RichText)));
    // ignore: avoid_print
    print('DBG hint size=${para.size} lines=${(para.size.height / (11.5 * 1.45)).toStringAsFixed(1)} '
        'exceeded=${para.didExceedMaxLines}');
    expect(para.didExceedMaxLines, isFalse, reason: '正式文案 2 行内完整显示（PNG 里能看到完整句子）');

    await capture(tester, 'product_list_purchase_hint.png');
  });

  // ---------------- 出图 ②：列表滚到底 —— 提示条与商品卡同时入画 ----------------

  testWidgets('出图 ②：列表滚到底 —— 提示条贴底常驻、不遮挡商品卡（发丝线分隔）', (tester) async {
    late Map<String, Map<String, dynamic>> fixture;
    await tester.runAsync(() async {
      // 同上：换回真 HttpClient 才能抓线上数据
      final real = HttpOverrides.global = _RealHttpOverrides();
      try {
        fixture = await liveFixture();
        await warmImages(fixture);
      } finally {
        HttpOverrides.global = real;
      }
    });

    final text = '${((fixture['/public/purchase-hint']!['data'] as Map?)?['text'] ?? '')}'.trim();
    expect(text.isNotEmpty, isTrue, reason: '线上购买提示为空');

    await pumpPhone(tester, ProductListPage(api: _api(fixture), initialDivisionId: divisionId));
    await settleWithRealIo(tester);

    // 商品列表 = 页面里第 3 个 ListView（① 专区胶囊行 ② 左侧分类栏 ③ 商品列表）
    final listFinder = find.byType(ListView).last;
    expect(listFinder, findsOneWidget);
    await tester.drag(listFinder, const Offset(0, -260));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    // 提示条仍在（贴底常驻，不随列表滚动消失）
    expect(find.byKey(purchaseHintBarKey), findsOneWidget, reason: '滚动后提示条依然常驻底部');
    expect(find.text(text), findsOneWidget);
    // 提示条**位于商品列表下沿之下**（不覆盖列表）：条顶 >= 列表底
    final barTop = tester.getTopLeft(find.byKey(purchaseHintBarKey)).dy;
    final listBottom = tester.getBottomLeft(listFinder).dy;
    // ignore: avoid_print
    print('DBG barTop=$barTop listBottom=$listBottom');
    expect(barTop, greaterThanOrEqualTo(listBottom - 0.5), reason: '提示条在列表区域下方（不是浮在商品卡上）');

    await capture(tester, 'product_list_purchase_hint_scrolled.png');
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
