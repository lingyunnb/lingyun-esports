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

/// 老板端「商品名 / 副标题不被截断」出图（负责人 2026-10-05 报障「好多都没显示全」）
///
/// 产出（PNG 落在 apps/boss-app/build/）：
/// - `truncation_order_create.png` —— **确认订单页**：45 字最长商品名 3 行完整显示
/// - `truncation_product_list.png` —— **选择服务（商品列表）**：趣味单副标题 2 行
///
/// ## 数据来源：**全部注入**（2026-10-06 改；这是本文件最重要的一条纪律）
///
/// 本文件原先"现抓线上 3100 的真实响应"当 fixture。**已废弃**，原因是它会随运营数据变红：
/// 当天负责人删掉 2 件商品、改了名字之后，`categoryId=80`（趣味单）在库里被清空 →
/// 出图用例直接挂（报「没抓到趣味单商品」），而这条失败**与被测的截断逻辑毫无关系**，
/// 是噪声不是回归信号。
///
/// 所以：**任何测试都不许依赖线上目录数据**（负责人 2026-10-06 要求）。
/// 本文件的商品/分类/分部/下单表单都是下面 [shotFixture] 里写死的合成 fixture，
/// 字段形状**逐字段对齐真实响应**（字段名写错页面就渲染不出来，用例立刻红）——
/// 这样它既能证明"45 字名字 / 长副标题不被截断"，又能**离线复跑、永不随运营漂移**。
///
/// 三处测试环境适配（与既有出图测试 product_badge_visual_test.dart 完全一致，不改 App 代码）：
/// 1) fixture 里 `coverMediaId`/`coverUrl` 一律为 null → 画面走商品图占位态，
///    不再需要磁盘图片缓存与 `precacheImage`（截断证据在文字上，与图无关）；
/// 2) 假时钟下真实 IO 不推进 → 出图前用 `runAsync` 放一段真实时间（`settleWithRealIo`）；
/// 3) `Image.file` 只建 widget 不解码则 PNG 里是空白 → 已随第 1 条一并消除。
///
/// **注入数据的字面量（文件作用域）**：`main()` 里的用例与下面的 [shotFixture] 必须用
/// **同一份**常量 —— 否则"断言的名字"和"喂给页面的名字"会各写一遍，改一处忘一处。
///
/// - [shotLongName]：报障截图里那条 45 字长名字（"…不出保888w[老…" 被截成 1 行的那条）。
///   ⚠️ 长度被断言卡住（`runes.length >= 40`）：名字太短就测不出截断，出图也证明不了任何事
///   （首版手写时少了 8 个字，直接红在长度断言上）。
/// - [shotHotName] / [shotWildName] / [shotHotSubtitle]：趣味单两条 + 那条被截成 1 行的副标题。
const String shotLongName = '36.6博弈宝冠单不出保888w老板指定三人护航全程跟枪不卡保底不出不退不换不鸽打完再结';
const String shotHotName = '人机爆红单15.88';
const String shotWildName = '野区爆红单15.88';
const String shotHotSubtitle = '老板指定三个人机爆20w，不出不退不卡保底，全程跟枪报点，急单勿拍';

/// 中文：`flutter test` 自带字体没有中文字形，这里挂系统黑体（`FontLoader`），只为 PNG 可读。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'TruncationCJK';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
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
    AppToast.dismiss();
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
  });

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

  // ---------------- 出图 ①：确认订单页（报障截图 1 的现场）----------------

  testWidgets('出图 ①：确认订单页 —— 45 字最长商品名 3 行完整显示', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final fixture = shotFixture();
    final detail = (fixture['/public/products/901']!['data'] as Map).cast<String, dynamic>();
    final name = '${detail['name']}';
    // 注入数据自检：这条必须是报障截图里的那条长名字（否则这张图证明不了任何事）
    expect(name.startsWith('36.6博弈宝冠单'), isTrue, reason: '出图必须是报障现场那条 45 字长名字，实际：$name');
    expect(name.runes.length, greaterThanOrEqualTo(40), reason: '名字要足够长才测得出截断');

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: OrderCreatePage(api: _api(fixture), divisionId: '1', product: detail),
      ),
    ));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    // 画面自检：商品名完整（没被省略号吃掉）+ 价格/提交按钮都在
    final para = tester.renderObject<RenderParagraph>(find.descendant(of: find.text(name), matching: find.byType(RichText)));
    expect(para.didExceedMaxLines, isFalse, reason: '确认订单页商品名必须完整显示（报障原文被截成「…不出保888w[老…」）');
    expect(find.text('提交订单'), findsOneWidget);
    expect(find.textContaining('366'), findsWidgets, reason: '价格仍在画面里');

    await capture(tester, 'truncation_order_create.png');
  });

  // ---------------- 出图 ②：选择服务（商品列表，报障截图 2 的现场）----------------

  testWidgets('出图 ②：选择服务 —— 趣味单副标题 2 行（含人机爆红单 158.8 单价）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final fixture = shotFixture();
    final list = ((fixture['/public/products']!['data'] as Map?)?['list'] as List?) ?? const [];
    expect(list.length, greaterThanOrEqualTo(2), reason: '注入的趣味单必须有两条（人机 / 野区）');

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: ProductListPage(api: _api(fixture)),
      ),
    ));
    await settleWithRealIo(tester);
    expect(tester.takeException(), isNull);

    // 画面自检：两条爆红单都在，副标题各自排到 2 行（旧实现 1 行）
    expect(find.text(shotHotName), findsOneWidget);
    expect(find.text(shotWildName), findsOneWidget);
    final subtitle = '${(list.first as Map)['subtitle']}';
    expect(subtitle.isNotEmpty, isTrue, reason: '趣味单必须有副标题，否则证明不了副标题放宽');
    final subPara = tester.renderObject<RenderParagraph>(find.descendant(of: find.text(subtitle), matching: find.byType(RichText)));
    expect(subPara.size.height, greaterThan(20), reason: '副标题高度 ≈ 2 行（1 行 ≈ 15dp）');
    // 单价必须是清单口径的 158.8（不是被测试脚本改出来的 100）
    expect(find.textContaining('158.8'), findsWidgets, reason: '人机爆红单单价应为 158.8 积分（清单口径）');

    await capture(tester, 'truncation_product_list.png');
  });
}

/// **注入的整套 fixture**（形状逐字段对齐真实响应；与线上目录数据**完全无关**）
Map<String, Map<String, dynamic>> shotFixture() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  Map<String, dynamic> product({
    required String id,
    required String name,
    required String subtitle,
    required num price,
    String? badge,
  }) =>
      {
        'id': id,
        'name': name,
        'subtitle': subtitle,
        'listName': null,
        'badgeText': badge,
        'weeklyLimit': 0,
        'weeklyLimitByQuantity': 0,
        'gameId': '35',
        'divisionId': '1',
        'categoryId': '80',
        'price': price,
        'priceUnit': '单',
        'estimateDurationMin': 30,
        'serviceStatus': 1,
        'salesCount': 7,
        'coverMediaId': null,
        'coverUrl': null,
        'media': const [],
        'description': '$name（积分 $price，按单计价）。',
        'detail': null,
        'serviceFlow': null,
        'serviceRules': null,
        'attention': null,
        'orderNotice': null,
        'status': 1,
      };

  final hot = product(id: '901', name: shotHotName, subtitle: shotHotSubtitle, price: 158.8);
  final wild = product(id: '902', name: shotWildName, subtitle: '野区三图连打，出紫装不加价，打完再确认收货', price: 158.8);

  /// 详情页那条 45 字长名字（出图 ① 的主角）：其余字段与列表项同源，价格 366
  final detail = {
    ...product(id: '901', name: shotLongName, subtitle: '', price: 366, badge: '董事长推荐'),
    'detail': null,
    'effectiveOrderNotice': '第一条须知：请确认游戏分区与游戏 ID 填写正确。\n'
        '第二条须知：下单即按标价扣积分，1 件为 1 单。\n'
        '第三条须知：未接单可随时取消，积分全额退回。\n'
        '第四条须知：请勿把账号密码告知护航员。',
    'orderNoticeInherited': true,
    'orderPendingTakeTimeoutHours': 24,
    'divisionPlatformLabel': '手游',
  };

  return {
    '/divisions': envelope([
      {
        'id': '1',
        'code': 'peace_mobile',
        'gameId': '35',
        'gameName': '和平精英',
        'platform': 'mobile',
        'platformLabel': '手游',
        'name': '和平精英 · 手游',
        'shortName': '和平精英',
        'onlineDesc': '打手全天在线',
        'priceNote': '',
        'themeColor': '#16A34A',
        'subTitle': '',
        'sortOrder': 10,
        'underConstruction': false,
        'noticeText': '',
        'onlineCount': 3,
        'iconMediaId': null,
        'coverMediaId': null,
      },
    ]),
    '/public/categories': envelope([
      {'id': '80', 'gameId': '35', 'name': '趣味单'},
      {'id': '79', 'gameId': '35', 'name': '博弈单'},
    ]),
    '/public/products': envelope({
      'list': [hot, wild],
      'total': 2,
      'page': 1,
      'pageSize': 50,
    }),
    '/public/products/901': envelope(detail),
    '/public/order-form': envelope({
      'zoneLabel': '选择区服',
      'zoneOptions': [
        {'label': '微信', 'value': 'wechat'},
        {'label': 'QQ', 'value': 'qq'},
      ],
      'fields': const [],
      'workerLabel': '选择护航员',
      'workerRandomLabel': '随机安排',
      'workerDesignatedLabel': '指定护航员',
      'feeTitle': '商品费用',
      'feeUnitLabel': '单价',
      'totalLabel': '合计',
      'submitText': '提交订单',
      'notice': '',
    }),
    '/public/players': envelope({'list': const [], 'total': 0}),
    // 未登录：限购提示不出现（限购/徽标不在本组图要证明的范围内，另有专门出图）
    '/user/orders/weekly-quota': {'code': 401, 'message': '未登录', 'data': null},
  };
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
