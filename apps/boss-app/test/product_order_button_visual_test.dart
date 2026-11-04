import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_detail_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「点下单 → 商品详情页」出图 + 按钮位置零回归取证（负责人 2026-10-05 复报）
///
/// 复报原文：「**点下单也要弹到图二页面**」—— 即选择服务页商品卡**右下角「下单」按钮**
/// 与整卡点击一样进商品详情页，不再直达确认订单页。
///
/// 产出（PNG 落在 `apps/boss-app/build/`）：
/// - `order-button-list.png` —— **选择服务页**：右下「下单」按钮在商品卡右下角（位置/尺寸/文案都没动，
///   本文件用 `tester.getRect` 把它的矩形**数值**也钉住，PNG 只是给人眼看的证据）
/// - `order-button-tap-detail.png` —— **点「下单」之后落到的画面**：商品详情页（底栏「立即购买」）
///
/// ## 画面里的数据从哪来（决定 PNG 算不算证据）
/// 分部/分类/商品列表/商品详情/购买提示**全部现抓线上 3100 的真实响应**（不是手写 fixture）：
/// 图里的商品名、价格、徽标、须知都由**真实服务端数据**决定；抓不到直接 expect 失败，不拿假图交差。
///
/// ## 目标商品是**运行时从线上列表里挑的**（2026-10-11 假红根因，别改回去）
/// 原用例把目标钉成 `137`（当时它是分部 1 的第一件、名字叫「9.9新人体验单保200w不卡保底」），
/// 于是用例隐含了两个会随库漂移的前提：
/// ① 商品 id/名字不变 —— 2026-10-09 该商品被改名为「9.9新人体验单保400w不卡保底（送7套＋aug）」；
/// ② 它一直是列表第一张卡 —— 2026-10-10 新商品 168 排到了它前面。
/// 两个前提同时失效后，`find.text('下单').first` 取到的是**第一张卡**的按钮，而量的是**137 那张卡**的
/// 矩形 → `card.bottom - button.bottom` 变成两张卡之间的距离（实测 **151** = 卡高 123 + 卡间距 10 + 卡内边距 18），
/// 这是**假红**（目录数据漂移），不是 UI 回归。故现在：目标商品动态挑 + 按钮限定在**目标卡内部**取。
///
/// 测试环境适配与既有出图测试（`product_purchase_hint_visual_test.dart` /
/// `product_list_name_visual_test.dart`）完全一致，**App 代码一行不改**：
/// 没有 `--dart-define` 时封面相对路径改写成 `http://127.0.0.1:3100/...`；
/// 出图前把图片写进 `ImageDiskCache` 磁盘缓存并在真实异步区 lookup 一次。
///
/// 中文：`flutter test` 自带字体没有中文字形，这里挂系统黑体（`FontLoader`），只为 PNG 可读。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'OrderButtonVisualCJK';
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
  ///
  /// **列表里每一件商品的详情都抓回来**：目标商品是运行时从列表里挑的（不写死 id），
  /// 挑中哪一件都必须在 fixture 里有它自己的详情，否则详情页会退化成拿到"列表体"。
  Future<Map<String, Map<String, dynamic>>> liveFixture() async {
    final divisions = await getJson('$apiBase/divisions');
    final categories = await getJson('$apiBase/public/categories?gameId=35');
    final products = await getJson('$apiBase/public/products?divisionId=$divisionId&page=1&pageSize=50');
    final hint = await getJson('$apiBase/public/purchase-hint');
    final form = await getJson('$apiBase/public/order-form');

    final list = ((products['data'] as Map?)?['list'] as List?) ?? const [];
    for (final item in list) {
      if (item is Map && item['coverUrl'] is String && !'${item['coverUrl']}'.startsWith('http')) {
        item['coverUrl'] = '$origin${item['coverUrl']}';
      }
    }

    final fixture = <String, Map<String, dynamic>>{
      '/divisions': divisions,
      '/public/categories': categories,
      '/public/products': products,
      '/public/purchase-hint': hint,
      '/public/order-form': form,
      // 未登录态（本组图不摆限购提示，避免和真相抢视线）
      '/user/orders/weekly-quota': {'code': 401, 'message': '未登录', 'data': null},
    };

    for (final item in list) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}';
      if (id.isEmpty) continue;
      final detail = await getJson('$apiBase/public/products/$id');
      final data = detail['data'];
      if (data is! Map || '${data['id']}' != id) continue; // 抓不到 / 拿错件 → 不塞进 fixture
      for (final key in ['coverUrl', 'videoCoverUrl']) {
        final url = data[key];
        if (url is String && url.isNotEmpty && !url.startsWith('http')) data[key] = '$origin$url';
      }
      fixture['/public/products/$id'] = detail;
    }

    return fixture;
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
      final loader = FontLoader(cjkFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    // **图标字形**：`flutter_test` 不打包 MaterialIcons，不挂的话画面里的图标全是空心方框
    for (final path in const [
      r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
      r'C:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
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

  Future<Map<String, Map<String, dynamic>>> fetchLive(WidgetTester tester) async {
    late Map<String, Map<String, dynamic>> fixture;
    await tester.runAsync(() async {
      // `flutter_test` 默认让所有 HttpClient 返回 400 → 抓线上数据前换回真 HttpClient
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

  /// 390×844 真机画布（与详情页设计稿 `.phone` 内容区一致）+ 中文字体
  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpList(WidgetTester tester, Map<String, Map<String, dynamic>> fixture) async {
    usePhone(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        // **不要把 fontFamily 直接挂在 ThemeData 上**：那样 IconTheme 也会继承中文字体，
        // Material 图标会去找汉字字体里不存在的码位 → 渲染成空心方框（实测踩过）。
        debugShowCheckedModeBanner: false,
        theme: _cjkTextTheme(cjkFamily),
        home: ProductListPage(api: _api(fixture), initialDivisionId: divisionId),
      ),
    ));
    await settleWithRealIo(tester);
  }

  /// 目标商品：**从线上列表动态挑**（不写死 id / 商品名 / 序号）
  ///
  /// 取列表里**第一件"卡片真的渲染出来了"的商品**。列表顺序 = 页面顺序：默认综合排序
  /// （`_sort = 'default'`）不重排，服务端给什么顺序就渲染什么顺序。
  ///
  /// 卡片显示名按**列表页的口径**取：`listName` 优先、留空回退完整 `name`
  /// （与 `ProductListPage` 的 `listDisplayName` 同源）—— 直接拿详情里的完整名去找卡，
  /// 一旦这件商品被管理端配了「列表短名」就会找不到（列表卡上根本没有那串完整名）。
  ({Map<String, dynamic> item, Map<String, dynamic> detail, String cardName, String detailName}) pickTarget(
      WidgetTester tester, Map<String, Map<String, dynamic>> fixture) {
    final list = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    expect(list, isNotEmpty, reason: '线上分部 $divisionId 一件商品都没有（检查后端 3100 与商品上架状态）');
    for (final raw in list) {
      if (raw is! Map) continue;
      final item = raw.cast<String, dynamic>();
      final short = '${item['listName'] ?? ''}'.trim();
      final cardName = short.isNotEmpty ? short : '${item['name']}';
      // 名字在页面上找不到 → 这件商品的卡没被渲染（换下一件，不硬撑）
      if (find.text(cardName, skipOffstage: false).evaluate().isEmpty) continue;
      final detail = (fixture['/public/products/${item['id']}']?['data'] as Map?)?.cast<String, dynamic>();
      expect(detail, isNotNull, reason: '商品 ${item['id']} 的详情没抓到（检查后端 3100 是否在跑）');
      expect('${detail!['id']}', '${item['id']}', reason: '详情必须回的是同一件商品');
      return (item: item, detail: detail, cardName: cardName, detailName: '${detail['name']}');
    }
    fail('线上列表里没有任何一件商品的卡片被渲染出来（列表页没出商品 —— 检查后端 3100 与分部 $divisionId 的目录）');
  }

  /// 目标商品在列表页里的**那张卡**（按卡片显示名定位；`skipOffstage: false` 见 `measure` 注释）
  Finder cardFinderOf(String cardName) => find
      .ancestor(of: find.text(cardName, skipOffstage: false), matching: find.byType(AppCard, skipOffstage: false))
      .first;

  /// 那张卡**自己的**右下「下单」按钮
  Finder cardButtonOf(String cardName) =>
      find.descendant(of: cardFinderOf(cardName), matching: find.text('下单'), skipOffstage: false).first;

  /// 目标商品名与它的卡片/按钮矩形（一次性取齐：getRect 每次都要遍历整棵树）
  ///
  /// `skipOffstage: false` 是**必须的**：push 到详情页后，列表页那条路由的入场动画一结束，
  /// 它的 overlay entry 就变成 opaque，Flutter 会让下面这条路由**不再绘制**（`_Theatre` 的
  /// offstage 侧）—— 默认 finder 跳过后台路由，`getRect` 会以"找不到"失败。
  /// 本文件要证明的正是"**按钮本身没动**"，所以必须显式把后台那条路由也找出来量。
  ///
  /// ⚠️ 按钮必须**限定在这张卡内部**取（`find.descendant`）。原来写成 `find.text('下单').first`
  /// 取的是"页面上第一张卡"的按钮 —— 目标商品一旦不在第一位，`card.bottom - button.bottom`
  /// 就变成**两张卡之间的距离**（2026-10-11 实测 151），量到的根本不是按钮与它自己那张卡的关系。
  ({String name, Rect card, Rect button}) measure(WidgetTester tester, String cardName) {
    return (
      name: cardName,
      card: tester.getRect(cardFinderOf(cardName)),
      button: tester.getRect(cardButtonOf(cardName)),
    );
  }

  // ---------------- 出图 ①：选择服务页（按钮在卡右下角，位置不动）----------------

  testWidgets('出图 ①：选择服务页 —— 商品卡右下「下单」按钮（文案/尺寸/位置零回归）', (tester) async {
    final fixture = await fetchLive(tester);
    expect(fixture['/public/products']?['data'], isNotNull, reason: '没抓到商品列表（检查后端 3100 是否在跑）');

    await pumpList(tester, fixture);
    expect(tester.takeException(), isNull);

    final t = pickTarget(tester, fixture);
    final m = measure(tester, t.cardName);
    // ignore: avoid_print
    print('DBG ① id=${t.item['id']} cardName=${t.cardName}\n'
        '        card=${m.card} button=${m.button} gapBelowButton=${m.card.bottom - m.button.bottom}');

    // 按钮在卡片**右下角**：底边贴近卡片下沿、右边贴近卡片右沿（位置语义没变）
    expect(m.button.bottom, lessThanOrEqualTo(m.card.bottom + 0.5), reason: '按钮仍在卡片内（没有溢出/换行）');
    expect(m.card.bottom - m.button.bottom, lessThan(20),
        reason: '按钮贴在卡片底部（实测偏移 ${(m.card.bottom - m.button.bottom).toStringAsFixed(1)}；'
            '商品名撑起的内容列高于 74dp 封面时，底行与卡底只差卡片内边距）——按钮被上方内容挤下去就该在这里红');
    // 右沿留白 = 卡片内边距 10 + 按钮自身内边距 14 = 24 → 断言"视觉上就是贴右"(≤30，不是随手给的大数)
    expect(m.card.right - m.button.right, lessThan(30),
        reason: '按钮贴在卡片右侧（实测 ${m.card.right - m.button.right} = 卡片内边距 10 + 按钮内边距 14）');
    expect(m.button.right, greaterThan(m.card.center.dx), reason: '按钮在卡片右半侧（右下角，不是左下角）');
    expect(m.card.top, greaterThanOrEqualTo(0), reason: '卡片整体在视口内（截图能看到完整一张卡）');
    expect(m.card.bottom, lessThan(tester.view.physicalSize.height / tester.view.devicePixelRatio),
        reason: '卡片下沿在屏内（按钮没有被屏幕裁掉）');
    // 文案仍是「下单」（负责人倾向：用户心智 = 下单入口，详情页再确认；改字会动观感）
    expect(find.text('下单'), findsWidgets, reason: '按钮文案保持「下单」');
    // 列表页不该出现「立即购买」（那是详情页底栏的，出现就说明已经跳过去了）
    expect(find.text('立即购买'), findsNothing);

    await capture(tester, 'order-button-list.png');
  });

  // ---------------- 出图 ②：点「下单」→ 商品详情页 ----------------

  testWidgets('出图 ②：点商品卡右下「下单」→ 落到商品详情页（不是确认订单页），返回后按钮矩形逐值不变', (tester) async {
    final fixture = await fetchLive(tester);
    expect(fixture['/public/products']?['data'], isNotNull, reason: '没抓到商品列表（检查后端 3100 是否在跑）');

    await pumpList(tester, fixture);
    expect(tester.takeException(), isNull);

    final t = pickTarget(tester, fixture);
    final before = measure(tester, t.cardName);

    // **真实点击这张卡自己的右下「下单」**（不是页面上第一颗「下单」——
    //  点错卡就会跳到另一件商品的详情页，那是"点了哪件就进哪件"这条语义被绕过）
    await tester.tap(cardButtonOf(t.cardName));
    await settleWithRealIo(tester);
    await settle(tester, steps: 6);

    // 落点必须是详情页 —— 且**不是**确认订单页
    expect(find.byType(ProductDetailPage), findsOneWidget, reason: '点「下单」必须进商品详情页');
    expect(find.byType(OrderCreatePage), findsNothing, reason: '点「下单」不得直达确认订单页');
    expect(find.text('立即购买'), findsOneWidget, reason: '详情页底栏的「立即购买」才是进确认订单页的入口');
    expect(find.text('下单'), findsNothing, reason: '详情页没有「下单」按钮（列表页的按钮已经不在画面上）');
    // 详情页显示的就是刚才那张卡的商品（按 id 回源）
    expect(find.text(t.detailName), findsWidgets,
        reason: '详情页标题 = 点的那件商品（clicked id=${t.item['id']}）');

    await capture(tester, 'order-button-tap-detail.png');

    // 返回列表页再量一次：**按钮矩形与点击前逐值相等**
    // （不能在详情页盖着的时候量 —— 那时列表那条路由正处在页面切换的位移中，
    //   量到的是"被推走 108dp"的临时坐标，不是按钮的真实位置；实测踩过）
    //
    // 为什么不用 `tester.pageBack()`：它只认英文 tooltip `Back`（本 App 是中文「返回」），
    // 直接 pop 导航栈即可，语义与点返回箭头完全一致（同一层 MaterialPageRoute）。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ProductListPage), findsOneWidget, reason: '返回后应回到商品列表页');

    final after = measure(tester, t.cardName);
    // ignore: avoid_print
    print('DBG ② id=${t.item['id']} before=${before.button} after=${after.button} '
        'cardBefore=${before.card} cardAfter=${after.card}');
    expect(after.button, before.button, reason: '返回列表后按钮矩形与点击前一致（点它不改变它的位置/尺寸）');
    expect(after.card, before.card, reason: '卡片矩形也没变（按钮没有因为改行为而撑动布局）');
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
