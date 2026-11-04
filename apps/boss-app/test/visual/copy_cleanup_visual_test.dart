import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_detail_page.dart';
import 'package:boss_app/pages/recharge_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「管理端」文案清理 —— **出图取证**（负责人 2026-10-06 任务②）
///
/// 产出（`apps/boss-app/build/`，共 5 张）：
/// 1. `copyfix_1_detail_empty.png`   商品详情页**主图位空态**（原「管理端还没上传商品图」→「商品图待补充」）
/// 2. `copyfix_2_detail_blocks.png`  商品详情页**商品说明/详细介绍**区（原来每块右侧挂着「管理端维护」，现在**不再有这句**）
/// 3. `copyfix_3_order_zone.png`     下单页 → 区服卡（默认态；无选项时是「该商品暂未开放区服选择，请联系客服」）
/// 4. `copyfix_4_recharge_proof.png` 充值页 Step 2 → 付款截图上传区（原「超管照它核对」→「客服核对时以它为准」）
/// 5. `copyfix_5_recharge_submitted.png` 充值**提交成功页**第 1 步说明（原「超管在管理端核对你上传的…」→「客服会核对你上传的…」）
///
/// 画面里的数据来源（决定 PNG 算不算证据）：
/// - 商品详情 / 下单页：**现抓线上 3100 的真实响应**（与 `product_detail_v2_visual_test.dart` 同一套做法）；
///   抓不到直接 expect 失败，不拿假图交差。
/// - 充值页：注入的假接口（`/public/recharge/config` 与提交响应）—— 因为负责人**还没配收款码**，
///   线上 `qrCodes` 是空的，用真接口出不了"扫码付款"这一屏；金额档位/文案仍走真配置结构。
///
/// 中文：`flutter test` 自带字体没有汉字 → 挂系统 `msyh`（黑体兜底），并为 `MaterialIcons` 单独挂字体，
/// 否则图里全是豆腐块与空心方框（仓库既有出图脚本同一做法）。
void main() {
  const captureKey = Key('copyfix-capture');
  const cjk = 'CopyFixCJK';
  const origin = 'http://127.0.0.1:3100';
  const apiBase = '$origin/api/v1';

  // ---------------- 字体 ----------------

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 中文字形：**msyh 放最前**（负责人要求的出图字体），逐级兜底
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    // 图标字形
    for (final path in const [
      r'D:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
      r'C:\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
      r'D:\flutter\bin\cache\dart-sdk\bin\resources\devtools\assets\fonts\MaterialIcons-Regular.otf',
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
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'copyfix-token');
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
    AuthStore.debugStorageDisabled = false;
    ApiClient.cacheEnabled = true;
  });

  // ---------------- 通用舞台 ----------------

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester, {int steps = 10}) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 220)));
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 图片专用：**只 pump 的话图位永远是空白/灰块**（`Image.file` 在测试里是异步解码，
  /// 不给真实时间就画不上屏 → 等于没验收到"图能不能显示"）。
  /// 做法与 `recharge_visual_test.dart` 的 `settleImages` 同一套：
  /// 进 `runAsync` 放真实时间 → 再 pump 一帧把解码结果画上屏。
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final out = File('build/$name');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync() > 10000, isTrue, reason: 'PNG 太小说明没渲染出内容');
  }

  Widget stage(Widget page) => RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          // 中文字体只挂 textTheme（挂 ThemeData.fontFamily 会让图标去汉字字体里找码位 → 空心方框）
          theme: _cjkTheme(cjk),
          home: page,
        ),
      );

  /// 页面里所有可见文本（用来做"不含某词"的断言）
  List<String> allTexts(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').where((s) => s.isNotEmpty).toList();

  // ---------------- 线上真实数据（详情 / 下单页用） ----------------

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

  /// 现抓一整套线上 fixture（每个用例重新抓，保证与 3100 当前状态一致）
  Future<Map<String, Map<String, dynamic>>> liveFixture() async {
    final divisions = await getJson('$apiBase/divisions');
    /**
     * 【2026-10-08 修「业务配置一变、回归就红」】原实现写死 `divisionId=2`。
     *
     * 事实：运行中的库里**分部 2 已经不存在了**（`GET /divisions` 只回分部 1；
     * `GET /public/products?divisionId=2` 回 `total:0`）—— 于是这条用例在
     * `expect(products, isNotEmpty, reason: '分部 2 一件在售商品都没有？')` 上稳定变红，
     * 而它**要验的东西根本不是"分部 2 还在不在"**，而是"区服缺省态那句文案"。
     * 这与 commit `7db9a3c`（公开目录断言改为从 DB 推导）是同一类修复：**别把运营数据当常量**。
     * 因此改成不带分部过滤取在售商品；下面用例用**商品自己的 `divisionId`** 传给下单页。
     */
    final products = await getJson('$apiBase/public/products?page=1&pageSize=50');
    final detail = await getJson('$apiBase/public/products/137');
    final form = await getJson('$apiBase/public/order-form');
    for (final list in [products]) {
      for (final item in (((list['data'] as Map?)?['list'] as List?) ?? const [])) {
        if (item is Map && item['coverUrl'] is String && !'${item['coverUrl']}'.startsWith('http')) {
          item['coverUrl'] = '$origin${item['coverUrl']}';
        }
      }
    }
    final detailData = detail['data'];
    if (detailData is Map) {
      for (final key in ['coverUrl', 'videoCoverUrl']) {
        final url = detailData[key];
        if (url is String && url.isNotEmpty && !url.startsWith('http')) detailData[key] = '$origin$url';
      }
    }
    return {
      '/divisions': divisions,
      '/public/products': products,
      '/public/products/137': detail,
      '/public/order-form': form,
      '/user/orders/weekly-quota': {
        'code': 0,
        'message': 'ok',
        'data': {'limitText': '每周限购 2 单', 'quotaText': '本周还可下 2 单'},
      },
    };
  }

  /// 把画面要用的真实图片抓进磁盘缓存
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

  /// 抓线上数据（先摘掉 flutter_test 的 HttpOverrides —— 它会让所有 HttpClient 返回 400）
  ///
  /// ⚠️ 不能用 `HttpOverrides.global` 读回旧值：当前 Dart SDK 里它是只写属性（只有 setter），
  /// 读会编译失败。这里的做法是**临时置空 → 抓完置回 null**（测试进程结束时自动随 HttpOverrides 复位）。
  Future<Map<String, Map<String, dynamic>>> fetchLive(WidgetTester tester) async {
    late Map<String, Map<String, dynamic>> fixture;
    await tester.runAsync(() async {
      HttpOverrides.global = _RealHttpOverrides();
      try {
        fixture = await liveFixture();
        await warmImages(fixture);
      } finally {
        HttpOverrides.global = null;
      }
    });
    return fixture;
  }

  // ==========================================================================
  // 出图 ① 详情页主图位空态
  // ==========================================================================

  testWidgets('出图①：详情页空态——「商品图待补充」（原「管理端还没上传商品图」）', (tester) async {
    final fixture = await fetchLive(tester);
    final detail = fixture['/public/products/137']!['data'] as Map? ?? const {};
    expect('${detail['id']}', '137', reason: '没抓到商品 137 详情（后端 3100 没跑？）');
    expect('${detail['coverUrl'] ?? ''}'.isEmpty, isTrue,
        reason: '商品 137 必须仍是无封面（否则这张图不是空态）；若运营已上传封面请换一个无封面商品');

    phone(tester);
    await tester.pumpWidget(stage(ProductDetailPage(api: _api(fixture), productId: '137')));
    await settle(tester);

    // 文案断言：新说法在、旧说法（含「管理端」）一律不在
    expect(find.text('商品图待补充'), findsOneWidget);
    expect(find.text('管理端还没上传商品图'), findsNothing);
    for (final t in allTexts(tester)) {
      expect(t.contains('管理端'), isFalse, reason: '详情页可见文案里仍有「管理端」：$t');
      expect(t.contains('后台'), isFalse, reason: '详情页可见文案里仍有「后台」：$t');
    }
    await capture(tester, 'copyfix_1_detail_empty.png');
  });

  // ==========================================================================
  // 出图 ② 详情页「商品说明 / 详细介绍」区（原来每块右侧挂着「管理端维护」）
  // ==========================================================================

  testWidgets('出图②：详情页商品说明区——块标题右侧不再有「管理端维护」', (tester) async {
    final fixture = await fetchLive(tester);
    phone(tester);
    await tester.pumpWidget(stage(ProductDetailPage(api: _api(fixture), productId: '137')));
    await settle(tester);

    // 滚到「商品说明」块（商品 137 有 description）
    final target = find.text('商品说明');
    expect(target, findsOneWidget, reason: '商品 137 应有「商品说明」块（没有的话这张图证明不了删除效果）');
    await tester.ensureVisible(target);
    await settle(tester, steps: 6);
    expect(find.text('管理端维护'), findsNothing, reason: '块副标题必须已删掉');

    // 「维护」在这页不许出现（只有那一句副标题用过它；正文里若真有业务文案再单独放宽）
    for (final t in allTexts(tester)) {
      expect(t.contains('管理端'), isFalse, reason: '可见文案里仍有「管理端」：$t');
      expect(t.contains('维护'), isFalse, reason: '可见文案里仍有「维护」：$t');
    }
    await capture(tester, 'copyfix_2_detail_blocks.png');
  });

  // ==========================================================================
  // 出图 ③ 下单页区服卡（默认态 / 未开放时的新说法）
  // ==========================================================================

  testWidgets('出图③：下单页区服卡——无选项时是「该商品暂未开放区服选择，请联系客服」', (tester) async {
    final fixture = await fetchLive(tester);
    final products = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    expect(products, isNotEmpty, reason: '线上在售商品一件都没有？');
    final product = (products.first as Map).cast<String, dynamic>();
    // 分部 id 取自**商品自己**（不再写死 2，见 liveFixture 里的说明）
    final divisionId = '${product['divisionId'] ?? ''}';

    phone(tester);
    // ⚠️ 线上 `zoneOptions` **当前是有值的**（微信 / QQ），所以直接渲染只会看到两个选项按钮，
    // 看不到"未开放"那句兜底文案。这里按同一个接口结构**只把 zoneOptions 置空**，
    // 目的就是让那句文案真的上屏（负责人要求的"区服缺省态"）——其余字段全部照抄线上。
    final form = (fixture['/public/order-form']!['data'] as Map).cast<String, dynamic>();
    expect((form['zoneOptions'] as List?)?.isNotEmpty, isTrue,
        reason: '线上区服选项应当是有值的（本次出图靠它构造空态）；若服务端已清空，这条断言可去掉');
    final emptyZoneFixture = Map<String, Map<String, dynamic>>.from(fixture)
      ..['/public/order-form'] = {
        'code': 0,
        'message': 'ok',
        'data': {...form, 'zoneOptions': <dynamic>[]},
      };

    await tester.pumpWidget(stage(OrderCreatePage(api: _api(emptyZoneFixture), product: product, divisionId: divisionId)));
    await settle(tester);

    // 区服卡必须在；文案断言：新说法在、旧说法（含「管理端」）一律不在
    expect(find.text('选择区服'), findsOneWidget, reason: '主区服卡（区服卡的默认标题）');
    expect(find.text('该商品暂未开放区服选择，请联系客服'), findsOneWidget, reason: '区服缺省态的新文案');
    expect(find.text('管理端未配置区服选项'), findsNothing);
    for (final t in allTexts(tester)) {
      expect(t.contains('管理端'), isFalse, reason: '下单页可见文案里仍有「管理端」：$t');
    }
    await capture(tester, 'copyfix_3_order_zone.png');
  });

  // ==========================================================================
  // 出图 ④ 充值页 Step 2 付款截图区
  // ==========================================================================

  testWidgets('出图④：充值页付款截图区——「客服核对时以它为准」（原「超管照它核对」）', (tester) async {
    phone(tester);
    final png = await _tinyPng(tester);
    final qr = await _qrPng(tester);
    final router = _Router();
    // 收款码是**真的 PNG**（预置进磁盘缓存）：否则 `CachedImage` 会去网络取，
    // 测试环境里那个请求的计时器会挂到用例结束 → "A Timer is still pending"。
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr));
    await tester.pumpWidget(stage(RechargePage(
      api: _rechargeApi(router),
      picker: () async => PickedProof(bytes: png, name: 'proof.png'),
      uploader: ({required String type, required List<int> bytes, required String filename, required String token}) async =>
          const MediaUploadResult(id: 'proof-media-1', mimeType: 'image/png'),
    )));
    await settle(tester);

    // Step 1 选金额 → 下一步
    await tester.tap(find.text('¥6.00'));
    await settle(tester, steps: 6);
    await tester.tap(find.text('下一步'));
    await settle(tester, steps: 8);

    // 滚到付款截图区（上传前后那句说明都在同一张卡里）
    final hints = find.text('截图要能看清收款方、金额与时间，客服核对时以它为准。');
    for (var i = 0; i < 12 && hints.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -220));
      await settle(tester, steps: 4);
    }
    expect(hints, findsOneWidget, reason: '付款截图区的说明文案');
    for (final t in allTexts(tester)) {
      expect(t.contains('超管'), isFalse, reason: '充值页可见文案里仍有「超管」：$t');
      expect(t.contains('管理端'), isFalse, reason: '充值页可见文案里仍有「管理端」：$t');
    }
    await settleImages(tester); // 收款码是真图片，要给它真实解码时间
    await capture(tester, 'copyfix_4_recharge_proof.png');
  });

  // ==========================================================================
  // 出图 ⑤ 充值提交成功页的「接下来会发生什么」第 1 步
  // ==========================================================================

  testWidgets('出图⑤：充值提交成功页——第 1 步是「客服会核对你上传的付款截图与到账记录」', (tester) async {
    phone(tester);
    final png = await _tinyPng(tester);
    final qr = await _qrPng(tester);
    final router = _Router();
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr));
    await tester.pumpWidget(stage(RechargePage(
      api: _rechargeApi(router),
      picker: () async => PickedProof(bytes: png, name: 'proof.png'),
      uploader: ({required String type, required List<int> bytes, required String filename, required String token}) async =>
          const MediaUploadResult(id: 'proof-media-1', mimeType: 'image/png'),
    )));
    await settle(tester);

    await tester.tap(find.text('¥6.00'));
    await settle(tester, steps: 6);
    await tester.tap(find.text('下一步'));
    await settle(tester, steps: 8);

    // 上传截图（先滚进视口，再点）
    final pick = find.text('选择付款截图');
    for (var i = 0; i < 12 && pick.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -220));
      await settle(tester, steps: 4);
    }
    await tester.ensureVisible(pick);
    await settle(tester, steps: 4);
    await tester.tap(pick);
    await settle(tester, steps: 8);

    final submit = find.text('提交申请');
    for (var i = 0; i < 12 && submit.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -220));
      await settle(tester, steps: 4);
    }
    await tester.ensureVisible(submit);
    await settle(tester, steps: 4);
    await tester.tap(submit);
    await settle(tester, steps: 12);

    expect(find.text(RechargeCopy.submitted), findsOneWidget, reason: '必须真的走到提交成功页');

    final step1 = find.text('客服会核对你上传的付款截图与到账记录');
    for (var i = 0; i < 12 && step1.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -220));
      await settle(tester, steps: 4);
    }
    expect(step1, findsOneWidget, reason: '「接下来会发生什么」第 1 步');
    expect(find.textContaining('超管'), findsNothing, reason: '提交成功页不许再出现「超管」');
    expect(find.textContaining('管理端'), findsNothing, reason: '提交成功页不许再出现「管理端」');
    for (final t in allTexts(tester)) {
      for (final w in RechargeCopy.forbiddenWords) {
        expect(t.contains(w), isFalse, reason: '界面出现「$w」违反合规口径（在「$t」里）');
      }
    }
    await settleImages(tester);
    await capture(tester, 'copyfix_5_recharge_submitted.png');
  });
}

// ============================================================================
// 舞台与假接口
// ============================================================================

/// 只把中文字体挂到 textTheme（不挂 ThemeData.fontFamily —— 否则图标会去汉字字体里找码位）
ThemeData _cjkTheme(String family) {
  final base = ThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: family),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
  );
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _FixtureAdapter(raw);
  return ApiClient(dio: dio);
}

ApiClient _rechargeApi(_Router router) =>
    ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://recharge.local'))..httpClientAdapter = router);

Future<Uint8List> _tinyPng(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = const Color(0xFF1D5FA8));
    final img = await recorder.endRecording().toImage(8, 8);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// 一张**像收款码**的假 PNG（黑白块）：出图时图位不是灰块，且预置进磁盘缓存后不会触发网络请求
Future<Uint8List> _qrPng(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 120, 120), Paint()..color = const Color(0xFFFFFFFF));
    final black = Paint()..color = const Color(0xFF14202E);
    const cell = 12.0;
    // 三个定位角 + 中间随机格子（看起来就是二维码）
    for (final corner in const [Offset(0, 0), Offset(96, 0), Offset(0, 96)]) {
      canvas.drawRect(Rect.fromLTWH(corner.dx, corner.dy, 24, 24), black);
      canvas.drawRect(Rect.fromLTWH(corner.dx + 6, corner.dy + 6, 12, 12), Paint()..color = const Color(0xFFFFFFFF));
      canvas.drawRect(Rect.fromLTWH(corner.dx + 9, corner.dy + 9, 6, 6), black);
    }
    for (var r = 2; r < 9; r++) {
      for (var c = 2; c < 9; c++) {
        if ((r * 7 + c * 3) % 3 == 0) {
          canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell), black);
        }
      }
    }
    final img = await recorder.endRecording().toImage(120, 120);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}), 404,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

/// 充值页假接口：配置（档位/收款码/文案）+ 提交成功
class _Router implements HttpClientAdapter {
  /// 收款码地址（**必须与页面里 `AppConfig.resolveMediaUrl(...)` 同源**：
  /// `ImageDiskCache` 是按"页面实际传给它的那个 URL"做键的，键不一致就命中不了
  /// → 图位会是灰块、而且会去网络取（测试里就是一个挂到用例结束的计时器）
  String get qrUrl => AppConfig.resolveMediaUrl('/media/public/11');

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Map<String, dynamic> body;
    if (options.path.contains('/public/recharge/config')) {
      body = {
        'code': 0,
        'message': 'ok',
        'data': {
          'amountOptions': [6, 10, 20, 38, 68, 98, 128, 198, 328, 648],
          'customEnabled': true,
          'minYuan': 1,
          'maxYuan': 10000,
          'pointsPerYuan': 10,
          'pendingLimitPerUser': 3,
          'noticeText': '付款后请上传截图并提交申请；客服核对收款记录后发放余额。',
          'qrCodes': [
            {'id': '11', 'url': qrUrl, 'label': '微信收款码'},
          ],
        },
      };
    } else if (options.path.contains('/user/recharge/requests')) {
      body = {
        'code': 0,
        'message': 'ok',
        'data': {'id': '9001', 'amountYuan': 6, 'points': 6, 'status': 'pending'},
      };
    } else {
      body = {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}};
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

/// 真实 HttpClient 的 overrides（flutter_test 默认让所有 HttpClient 返回 400）
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
