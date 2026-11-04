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

/// 商品列表「4 行上限 + 列表短名」出图（负责人 2026-10-05 任务①②）
///
/// 产出（PNG 落在 apps/boss-app/build/）：
/// - `product_list_4lines.png` —— **选择服务**列表：45 字博弈单名排 **4 行**（改动前 3 行）
/// - `product_list_shortname.png` —— 给 44.6博弈鹰雕单（49 字）配短名后：**列表显示短名**（1 行）
/// - `product_detail_fullname.png` —— 同一条商品的**商品详情页仍显示完整名**（短名不越界）
///
/// ## 画面里的数据从哪来（决定 PNG 算不算证据）
/// 商品/分部/分类/商品详情**全部现抓线上 3100 的真实响应**（不是手写 fixture）：
/// PNG 里的商品名、价格、短名都由**真实服务端数据**决定；抓不到数据直接 expect 失败，不拿假图交差。
///
/// 三处测试环境适配（与既有出图测试 product_badge_visual_test.dart / product_name_truncation_visual_test.dart 一致，不改 App 代码）：
/// 1) 没有 --dart-define 时 `AppConfig.apiBase` 是模拟器别名 10.0.2.2 → 封面相对路径改写成
///    `http://127.0.0.1:3100/...`（只换主机，图片字节仍是服务端真实返回）；
/// 2) 假异步区不推进真实 IO → 出图前把图片写进 `ImageDiskCache` 的磁盘缓存目录并在真实异步区 lookup 一次；
/// 3) `Image.file` 只建 widget 不解码则 PNG 里是空白 → 先 `precacheImage` 预解码。
///
/// 中文：`flutter test` 自带字体没有中文字形，这里挂系统黑体（`FontLoader`），只为 PNG 可读。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'ListNameCJK';
  const origin = 'http://127.0.0.1:3100';
  const apiBase = '$origin/api/v1';
  const divisionId = '1';
  const gameId = '35';
  /// 博弈单分类（两条超长名商品都在这里）
  const categoryId = '79';

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

  /// 线上现抓的 fixture（每个 case 重新抓，保证与服务端当前状态一致）
  ///
  /// 分类只给「博弈单（79）」：页面默认选中第一个分类 → 一进来就是这两条超长名商品，
  /// 出图画面稳定可复现。
  Future<Map<String, Map<String, dynamic>>> liveFixture() async {
    final divisions = await getJson('$apiBase/divisions');
    final products = await getJson('$apiBase/public/products?divisionId=$divisionId&categoryId=$categoryId&page=1&pageSize=50');
    final form = await getJson('$apiBase/public/order-form');

    final list = ((products['data'] as Map?)?['list'] as List?) ?? const [];
    Map longest = const <String, dynamic>{};
    for (final item in list) {
      if (item is! Map) continue;
      if ('${item['id']}' == '145') {
        longest = item;
        break;
      }
      if (longest.isEmpty || '${item['name']}'.runes.length > '${longest['name']}'.runes.length) longest = item;
    }
    final longestId = '${longest['id'] ?? ''}';
    final detail = longestId.isEmpty ? <String, dynamic>{} : await getJson('$apiBase/public/products/$longestId');

    for (final item in list) {
      if (item is Map && item['coverUrl'] is String && !'${item['coverUrl']}'.startsWith('http')) {
        item['coverUrl'] = '$origin${item['coverUrl']}';
      }
    }
    if (detail['coverUrl'] is String && !'${detail['coverUrl']}'.startsWith('http')) {
      detail['coverUrl'] = '$origin${detail['coverUrl']}';
    }

    return {
      '/divisions': divisions,
      '/public/categories': {
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': categoryId, 'gameId': gameId, 'name': '博弈单'},
        ],
      },
      '/public/products': products,
      if (longestId.isNotEmpty) '/public/products/$longestId': detail,
      '/public/order-form': form,
      // 未登录：限购提示不出现（限购不在本组图要证明的范围内，另有专门出图）
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
    AuthStore.instance.debugSetSession(accessToken: 'visual-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
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

  Future<void> pumpPhone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(theme: ThemeData(fontFamily: cjkFamily), home: child),
    ));
  }

  RenderParagraph paragraphOf(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.descendant(of: find.text(text), matching: find.byType(RichText)));

  /// 详情页商品名会出现两次（AppBar 标题 + 正文卡片）→ 取**正文里面积最大**的那个
  /// （正文卡是真正承载完整名的地方；AppBar 标题本来就按单行省略设计）
  RenderParagraph bodyParagraphOf(WidgetTester tester, String text) {
    final paras = tester
        .renderObjectList<RenderParagraph>(find.descendant(of: find.text(text), matching: find.byType(RichText)))
        .toList()
      ..sort((a, b) => (b.size.width * b.size.height).compareTo(a.size.width * a.size.height));
    expect(paras, isNotEmpty, reason: '详情页必须渲染商品名');
    return paras.first;
  }

  int visibleLinesOf(RenderParagraph para, double fontSize, double heightFactor) =>
      (para.size.height / (fontSize * heightFactor)).round();

  // ---------------- 出图 ①：列表 4 行上限（超长名商品：4 行，改动前 3 行）----------------

  testWidgets('出图 ①：商品列表 —— 45 字超长商品名排 4 行（改动前 3 行）', (tester) async {
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

    final list = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    expect(list.length, greaterThanOrEqualTo(2), reason: '没抓到博弈单商品（检查后端 3100 是否在跑）');
    // 线上数据自检：必须抓到报障现场那条 45 字长名字
    Map? target;
    for (final item in list) {
      if (item is Map && '${item['name']}'.startsWith('36.6博弈宝冠单')) {
        target = item;
        break;
      }
    }
    expect(target, isNotNull, reason: '出图必须是报障现场那条 45 字长名字（36.6博弈宝冠单…）');
    final name = '${target!['name']}';
    expect(name.runes.length, greaterThanOrEqualTo(40), reason: '名字要足够长才测得出截断，实际 ${name.runes.length} 字');

    // 这张图证明**行数上限**（3 → 4）：把博弈单两条的 listName 都摘掉（= 管理端留空的 31 条商品的实际形态），
    // 于是列表卡渲染完整名 → 45 / 49 字都正好把 4 行用满。其余数据仍全部来自线上。
    for (final item in list) {
      if (item is Map) item['listName'] = null;
    }

    await pumpPhone(tester, ProductListPage(api: _api(fixture), initialDivisionId: divisionId));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    final nameText = tester.widget<Text>(find.text(name));
    expect(nameText.maxLines, 4, reason: '列表商品名上限 4 行（本次改动 3 → 4）');
    final para = paragraphOf(tester, name);
    expect(visibleLinesOf(para, 13.5, 1.35), 4, reason: '45 字长名字把 4 行用满（3 行上限时这里只有 3 行）');
    // 价格跟随线上数据（口径 2026-10-09：¥ + 两位小数；写死 '366' 会随价格折算失效）
    expect(find.textContaining(fmtMoney(parsePoints(target['price']))), findsWidgets,
        reason: '价格仍在画面里（卡片高度自适应，没有被名字压掉）');

    await capture(tester, 'product_list_4lines.png');
  });

  // ---------------- 出图 ②：列表短名（列表 1 行）----------------

  testWidgets('出图 ②：配了短名的商品 —— 列表显示短名（49 字完整名收成 1 行）', (tester) async {
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

    final list = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    Map? shorted;
    for (final item in list) {
      if (item is Map && '${item['listName'] ?? ''}'.isNotEmpty) {
        shorted = item;
        break;
      }
    }
    expect(shorted, isNotNull, reason: '线上应有一条配了短名的商品（迁移 1797000000000 给 144/145 配了短名）');
    final fullName = '${shorted!['name']}';
    final shortName = '${shorted['listName']}';
    expect(fullName.runes.length, greaterThan(40), reason: '完整名要够长才看得出短名的价值');
    expect(shortName, isNot(fullName));

    await pumpPhone(tester, ProductListPage(api: _api(fixture), initialDivisionId: divisionId));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    // 列表卡：显示短名；完整名一个都不在列表里（列表只显示短名）
    expect(find.text(shortName), findsWidgets, reason: '列表必须显示管理端配的短名');
    expect(find.text(fullName), findsNothing, reason: '列表卡显示短名 → 完整名不该同时出现');
    final para = paragraphOf(tester, shortName);
    expect(para.didExceedMaxLines, isFalse, reason: '短名在窄卡里完整显示（1~2 行）');
    expect(visibleLinesOf(para, 13.5, 1.35), lessThanOrEqualTo(2));

    await capture(tester, 'product_list_shortname.png');
  });

  // ---------------- 出图 ③：详情页仍是完整名（短名不越界）----------------

  testWidgets('出图 ③：同一条商品的详情页 —— 仍显示完整商品名（短名只在列表生效）', (tester) async {
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

    final detailKey = fixture.keys.firstWhere((k) => k.startsWith('/public/products/'), orElse: () => '');
    expect(detailKey.isNotEmpty, isTrue, reason: '没抓到商品详情（检查后端 3100 是否在跑）');
    final detail = (fixture[detailKey]!['data'] as Map).cast<String, dynamic>();
    final fullName = '${detail['name']}';
    final shortName = '${detail['listName'] ?? ''}';
    expect(shortName.isNotEmpty, isTrue, reason: '这条商品在库里有短名（144/145），详情页仍必须显示完整名');
    expect(fullName.runes.length, greaterThan(40));

    await pumpPhone(tester, ProductDetailPage(api: _api(fixture), productId: '${detail['id']}'));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    expect(find.text(fullName), findsWidgets, reason: '详情页显示完整商品名');
    expect(find.text(shortName), findsNothing, reason: '详情页不能用短名顶替完整名');
    // 详情页名字区域更宽（无左侧分类栏）→ 完整名不省略
    final para = bodyParagraphOf(tester, fullName);
    // ignore: avoid_print
    print('DBG detail fullName size=${para.size} lines@18px=${(para.size.height / (18 * 1.3)).toStringAsFixed(1)} '
        'exceeded=${para.didExceedMaxLines}');
    expect(para.didExceedMaxLines, isFalse, reason: '详情页宽度足够：完整名不省略（短名只解决窄卡列表）');

    await capture(tester, 'product_detail_fullname.png');
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
