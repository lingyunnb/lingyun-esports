import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:boss_app/pages/recharge_page.dart';
import 'package:boss_app/pages/wallet_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 余额口径出图（负责人 2026-10-09：计价单位「积分」→「余额」，1 元 = 1 元）
///
/// 出 5 张（`apps/boss-app/build/`，随后拷进 `docs/验收素材/2026-10-09-余额口径/`）：
/// 1. `balance_1_wallet.png`       我的余额（钱包页：标题/数值/流水全 ¥）
/// 2. `balance_2_product_card.png` 商品卡（¥8.80 两位小数）
/// 3. `balance_3_order_create.png` 下单页（合计 ¥10.00 + 余额不足，还差 ¥1.20）
/// 4. `balance_4_recharge_amounts.png` 充值页 Step 1（档位 ¥6.00 …）
/// 5. `balance_5_recharge_arrival.png` 充值页 Step 2（付款 ¥6.00 → 到账 ¥6.00，1:1）
///
/// 全部**注入假数据**（假服务器 + 注入的收款码图片），不依赖线上环境；且每一步都断言
/// 「屏上没有旧单位「积分」」——出图同时是负向回归。
void main() {
  const cjk = 'CJK';
  const pageKey = Key('balance-page');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(iconPath);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'balance-visual-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
  });

  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pageKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget stage(Widget page) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: page,
        ),
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester, {int steps = 20}) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settleImages(WidgetTester tester) async {
    // 图片解码是真异步（假时钟不推进）：给足真实时间再画帧，否则出图里是空框
    for (var i = 0; i < 14; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 160)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<Uint8List> qrPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 320.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
    final dark = Paint()..color = const Color(0xFF14202E);
    const n = 22;
    const cell = size / (n + 6);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final on = ((x * 7 + y * 13) % 5 == 0) || ((x * 3 + y * 11) % 7 == 2);
        if (!on) continue;
        canvas.drawRect(Rect.fromLTWH((x + 3) * cell, (y + 3) * cell, cell, cell), dark);
      }
    }
    canvas.drawRect(const Rect.fromLTWH(0, 0, size, 4), dark);
    canvas.drawRect(const Rect.fromLTWH(0, size - 4, size, 4), dark);
    return (await recorder.endRecording().toImage(size.toInt(), size.toInt()))
        .toByteData(format: ui.ImageByteFormat.png)
        .then((b) => b!.buffer.asUint8List());
  }

  // =====================================================================================
  // 出图 1：我的余额（钱包页）
  // =====================================================================================
  testWidgets('出图 1：我的余额（钱包页标题/当前余额/流水全 ¥，且无「积分」）', (tester) async {
    phone(tester);
    final wallet = {
      'code': 0,
      'message': 'ok',
      'data': {'balance': 99999.9},
    };
    final txns = {
      'code': 0,
      'message': 'ok',
      'data': {
        'list': [
          {'amount': -16.5, 'changeType': 'order_pay', 'reason': '钻皮·刀 1 局', 'balanceAfter': 99983.4, 'createdAt': '2026-10-09T11:12:54.000Z'},
          {'amount': 11.55, 'changeType': 'order_settlement', 'reason': '订单结算', 'balanceAfter': 99999.9, 'createdAt': '2026-10-09T11:30:00.000Z'},
          {'amount': 128, 'changeType': 'grant', 'reason': '充值申请已发放', 'balanceAfter': 100127.9, 'createdAt': '2026-10-09T12:00:00.000Z'},
        ],
        'total': 3,
        'page': 1,
        'pageSize': 20,
      },
    };
    await tester.pumpWidget(stage(WalletPage(api: _api({'/user/wallet': wallet, '/user/wallet/transactions': txns}))));
    await settle(tester);

    expect(find.text('我的余额'), findsOneWidget);
    expect(find.text('¥99,999.90'), findsOneWidget);
    expect(find.textContaining('积分'), findsNothing);
    await shoot(tester, 'balance_1_wallet.png');
  });

  // =====================================================================================
  // 出图 2：商品卡 ¥8.80
  // =====================================================================================
  testWidgets('出图 2：商品卡价格 ¥8.80（¥ + 两位小数，无 ≈ N 元 换算）', (tester) async {
    phone(tester);
    await tester.pumpWidget(stage(ProductListPage(api: _api(_productFixture()))));
    await settle(tester);
    await settleImages(tester);

    expect(find.text('¥8.80'), findsWidgets, reason: '商品卡价格必须 ¥ + 两位小数');
    expect(find.textContaining('≈'), findsNothing, reason: '二次换算已去除');
    expect(find.textContaining('积分'), findsNothing);
    await shoot(tester, 'balance_2_product_card.png');
  });

  // =====================================================================================
  // 出图 3：下单页（合计 + 余额不足差额）
  // =====================================================================================
  testWidgets('出图 3：下单页合计 ¥10.00 + 「余额不足，还差 ¥1.20」', (tester) async {
    phone(tester);
    final product = {'id': '101', 'name': '传奇段位上分陪练', 'price': 10, 'priceUnit': '局', 'divisionId': '1'};
    await tester.pumpWidget(stage(OrderCreatePage(
      api: _api(_orderFixture(balance: 8.8)),
      divisionId: '1',
      product: product,
    )));
    await settle(tester, steps: 30);

    expect(find.text('¥10.00'), findsWidgets);
    expect(find.text('余额不足，还差 ¥1.20'), findsOneWidget);
    expect(find.textContaining('积分'), findsNothing);
    await shoot(tester, 'balance_3_order_create.png');
  });

  // =====================================================================================
  // 出图 4/5：充值页（档位 ¥6.00；1:1 到账预览）
  // =====================================================================================
  testWidgets('出图 4：充值页 Step 1 档位一律 ¥6.00（十档网格）', (tester) async {
    phone(tester);
    final router = _RechargeRouter();
    await tester.pumpWidget(stage(RechargePage(api: _api(router.routes))));
    await settle(tester, steps: 30);

    expect(find.text('选择充值金额'), findsOneWidget);
    expect(find.text('¥6.00'), findsOneWidget);
    expect(find.text('¥648.00'), findsOneWidget);
    expect(find.textContaining('积分'), findsNothing);
    await shoot(tester, 'balance_4_recharge_amounts.png');
  });

  testWidgets('出图 5：充值页 Step 2 —— 付款 ¥6.00 → 到账 ¥6.00（1:1）', (tester) async {
    phone(tester);
    final router = _RechargeRouter();
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr!));
    await tester.pumpWidget(stage(RechargePage(api: _api(router.routes))));
    await settle(tester, steps: 30);

    await tester.tap(find.text('¥6.00'));
    await settle(tester, steps: 8);
    await tester.tap(find.text('下一步'));
    await settle(tester, steps: 20);
    await settleImages(tester);

    expect(find.text('应付金额'), findsOneWidget);
    expect(find.text('到账余额'), findsOneWidget);
    expect(find.text('付款 ¥6.00 → 到账 ¥6.00'), findsOneWidget);
    expect(find.textContaining('积分'), findsNothing);
    // 收款码是真图（假数据注入：URL 与 seed 的键必须一致，否则出图里会是一个空框）
    expect(
      find.byType(Image),
      findsWidgets,
      reason: '收款码 URL=${AppConfig.resolveMediaUrl('/media/public/11')}',
    );
    await shoot(tester, 'balance_5_recharge_arrival.png');
  });
}

// =========================================================================================
// 假数据
// =========================================================================================

Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

Map<String, Map<String, dynamic>> _productFixture() => {
      '/divisions': _envelope(const [
        {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'platformLabel': '手游', 'themeColor': '#16A34A', 'iconMediaId': null},
        {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'themeColor': '#2563EB', 'iconMediaId': null},
      ]),
      '/public/categories': _envelope(const [
        {'id': '44', 'gameId': '35', 'name': '段位上分'},
        {'id': '45', 'gameId': '35', 'name': '护航保底'},
      ]),
      '/public/products': _envelope(const {
        'list': [
          {
            'id': '201',
            'name': '9.9新人体验单（保 200w 不卡保底）',
            'subtitle': '首次下单专享',
            'gameId': '35',
            'categoryId': '44',
            'divisionId': '1',
            'price': 8.8,
            'priceUnit': '局',
            'salesCount': 2847,
            'badgeText': '董事长推荐',
            'coverMediaId': null,
            'coverUrl': null,
          },
          {
            'id': '202',
            'name': '传奇段位上分陪练',
            'subtitle': '全段位可接',
            'gameId': '35',
            'categoryId': '45',
            'divisionId': '1',
            'price': 158.8,
            'priceUnit': '局',
            'salesCount': 132,
            'coverMediaId': null,
            'coverUrl': null,
          },
        ],
        'total': 2,
      }),
      '/public/order-form': _envelope(const {
        'zoneLabel': '选择区服',
        'zoneOptions': [
          {'label': '微信', 'value': 'wechat'},
          {'label': 'QQ', 'value': 'qq'},
        ],
        'fields': [
          {'key': 'gamePlayerId', 'label': '游戏昵称或游戏ID', 'placeholder': '请输入游戏昵称或者游戏ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 64},
        ],
        'totalLabel': '合计',
        'submitText': '提交订单',
      }),
      '/user/orders/weekly-quota': _envelope(const {'limitText': '每周限购 5 单', 'quotaText': '本周已下 2 单，还剩 3 单'}),
    };

Map<String, Map<String, dynamic>> _orderFixture({required num balance}) => {
      ..._productFixture(),
      '/user/wallet': _envelope({'balance': balance}),
    };

/// 充值页假服务器（十档 + 一张收款码）
class _RechargeRouter {
  final String qrUrl = AppConfig.resolveMediaUrl('/media/public/11');

  Map<String, Map<String, dynamic>> get routes => {
        '/public/recharge/config': _envelope(const {
          'amountOptions': [6, 10, 20, 38, 68, 98, 128, 198, 328, 648],
          'customEnabled': true,
          'minYuan': 6,
          'maxYuan': 10000,
          // 历史比例字段仍在（接口形状不变），但**不得**参与展示（1:1 口径）
          'pointsPerYuan': 10,
          'pendingLimitPerUser': 3,
          'noticeText': '扫码付款后上传截图提交申请；客服核对收款记录后发放余额，请勿重复提交。',
          'qrCodes': [
            {'id': '11', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/11'},
          ],
        }),
        '/user/recharge/requests': _envelope(const {'list': [], 'total': 0, 'pendingCount': 0}),
        '/public/order-form': _envelope(const {
          'zoneLabel': '选择区服',
          'zoneOptions': [
            {'label': '微信', 'value': 'wechat'},
          ],
          'fields': <Map<String, dynamic>>[],
        }),
      };
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _FixtureAdapter(raw);
  return ApiClient(dio: dio);
}

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.raw);

  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'no fixture', 'data': null}), 404, headers: {
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
