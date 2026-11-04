import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品徽标 + 每周限购（负责人 2026-10-05：体验单置顶 + 「董事长推荐」+ 一账号一周 2 单）
///
/// 本文件覆盖两条**客户端硬约束**（服务端强制逻辑另有后端实测）：
/// 1) **徽标非空才渲染**：只有 `badgeText` 非空的商品才有徽标与琥珀金描边，其它商品一个像素不变；
/// 2) **限购文案来自服务端**：`/user/orders/weekly-quota` 说什么就显示什么，
///    服务端改成 3 单/改成"额度已用完"页面立刻跟着变；服务端 400 的中文原样弹出
///    （客户端**不硬编码**任何限购规则文案）。
void main() {
  Map<String, dynamic> envelope(Object? data, {int code = 0, String message = 'ok'}) =>
      {'code': code, 'message': message, 'data': data};

  final divisions = [
    {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'platformLabel': '手游', 'themeColor': '#16A34A', 'iconMediaId': null},
  ];
  final categories = [
    {'id': '78', 'gameId': '35', 'name': '常规单'},
  ];

  /// 与线上一致：**体验单排第一**（服务端 sortOrder 最小），只有它挂徽标与每周限购
  Map<String, dynamic> product(String id, String name, {String? badge, num weekly = 300, int? weeklyLimit}) => {
        'id': id,
        'name': name,
        'subtitle': '',
        'gameId': '35',
        'categoryId': '78',
        'divisionId': '1',
        'price': weekly,
        'priceUnit': '单',
        'salesCount': 4,
        'coverMediaId': null,
        'coverUrl': null,
        'badgeText': badge,
        'weeklyLimit': weeklyLimit,
      };

  final featured = product('137', '9.9新人体验单保200w不卡保底', badge: '董事长推荐', weekly: 99, weeklyLimit: 2);
  final normalA = product('147', '人机爆红单15.88', weekly: 100);
  final normalB = product('146', '野区爆红单15.88', weekly: 158.8);

  final orderForm = {
    'zoneLabel': '选择区服',
    'zoneOptions': [
      {'label': 'QQ区', 'value': 'qq'},
      {'label': '微信区', 'value': 'wechat'},
    ],
    'fields': [
      {'key': 'gamePlayerId', 'label': '游戏ID', 'placeholder': '请输入游戏ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 32},
    ],
    'workerLabel': '选择护航员',
    'workerRandomLabel': '随机安排',
    'workerDesignatedLabel': '指定护航员',
    'feeTitle': '商品费用',
    'feeUnitLabel': '单价',
    'totalLabel': '合计',
    'submitText': '提交订单',
  };

  /// 服务端每周限购配额（真实接口返回的形状；文案由服务端拼好，客户端只展示）
  Map<String, dynamic> quota({int weeklyLimit = 2, int orderedCount = 1, int? remaining = 1, String? limitText, String? quotaText}) => {
        'productId': '137',
        'weeklyLimit': weeklyLimit,
        'orderedCount': orderedCount,
        'remaining': remaining,
        'limitText': limitText ?? (weeklyLimit > 0 ? '每周限购 $weeklyLimit 单' : ''),
        'quotaText': quotaText ?? (weeklyLimit > 0 && (remaining ?? 0) > 0 ? '本周还可下 $remaining 单' : (weeklyLimit > 0 ? '本周额度已用完，下周再来' : '')),
      };

  Map<String, Map<String, dynamic>> fixture({
    Map<String, dynamic>? quotaData,
    Map<String, dynamic>? orderError,
  }) =>
      {
        '/divisions': envelope(divisions),
        '/public/categories': envelope(categories),
        '/public/products': envelope({'list': [featured, normalA, normalB], 'total': 3}),
        '/public/order-form': envelope(orderForm),
        '/user/orders/weekly-quota': orderError ?? envelope(quotaData ?? quota()),
        '/public/players': envelope({'list': const [], 'total': 0}),
      };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
  });

  // ---------------- ① 列表：徽标非空才渲染 ----------------

  testWidgets('商品列表：只有挂了徽标的商品渲染徽标，其它商品一个都不渲染', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('9.9新人体验单保200w不卡保底'), findsOneWidget);
    expect(find.text('董事长推荐'), findsOneWidget, reason: '只有体验单挂了徽标');
    expect(find.byType(ProductBadge), findsOneWidget, reason: '3 个商品里只有 1 个有徽标');

    // 徽标在卡片**左上角**（商品名之上）：置顶 + 徽标一起构成"一眼看到"
    final badgeY = tester.getTopLeft(find.byType(ProductBadge)).dy;
    final nameY = tester.getTopLeft(find.text('9.9新人体验单保200w不卡保底')).dy;
    expect(badgeY, lessThan(nameY), reason: '徽标应在商品名上方（左上角小片）');
  });

  testWidgets('商品列表：徽标商品换 1px 琥珀金描边，普通商品仍是全站发丝线', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final cards = tester.widgetList<AppCard>(find.byType(AppCard)).toList();
    expect(cards.length, 3);

    final featuredBorder = cards[0].border! as Border;
    expect(featuredBorder.top.color, AppColors.gold, reason: '置顶推荐卡 = 琥珀金描边（实色，不用渐变/阴影堆叠）');
    expect(featuredBorder.top.width, 1);

    for (final card in cards.skip(1)) {
      final border = card.border! as Border;
      expect(border.top.color, T.divider, reason: '普通商品卡不受影响');
    }
  });

  testWidgets('商品列表：置顶生效 —— 体验单是第一条（第一条即带徽标那张卡）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final firstCardTop = tester.getTopLeft(find.byType(AppCard).first).dy;
    final featuredTop = tester.getTopLeft(find.text('9.9新人体验单保200w不卡保底')).dy;
    final normalTop = tester.getTopLeft(find.text('人机爆红单15.88')).dy;
    expect(featuredTop, lessThan(normalTop), reason: '接口第一条就是体验单 → 渲染也在最上面');
    expect(featuredTop - firstCardTop, lessThan(40), reason: '体验单就在第一张卡里');
  });

  // ---------------- ② 下单页：限购文案来自服务端 ----------------

  testWidgets('下单页：限购提示用服务端文案（每周限购 2 单 · 本周还可下 1 单）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(fixture()), divisionId: '1', product: featured),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('董事长推荐'), findsOneWidget, reason: '下单页商品卡也展示徽标（与列表一致）');
    expect(find.text('每周限购 2 单 · 本周还可下 1 单'), findsOneWidget);
  });

  testWidgets('下单页：服务端改成 3 单 → 页面跟着变（证明客户端没有硬编码 2 单）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(
        api: _api(fixture(quotaData: quota(weeklyLimit: 3, orderedCount: 0, remaining: 3))),
        divisionId: '1',
        product: featured,
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('每周限购 3 单 · 本周还可下 3 单'), findsOneWidget);
    expect(find.textContaining('限购 2 单'), findsNothing, reason: '客户端不得自己拼规则文案');
  });

  testWidgets('下单页：额度用完 → 服务端文案原样展示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(
        api: _api(fixture(quotaData: quota(orderedCount: 2, remaining: 0))),
        divisionId: '1',
        product: featured,
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('每周限购 2 单 · 本周额度已用完，下周再来'), findsOneWidget);
  });

  testWidgets('下单页：服务端说不限购（文案为空）→ 一个字都不显示', (tester) async {
    final unlimited = product('146', '野区爆红单15.88', weekly: 158.8);
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(
        api: _api(fixture(quotaData: quota(weeklyLimit: 0, orderedCount: 0, remaining: null))),
        divisionId: '1',
        product: unlimited,
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('限购'), findsNothing);
    expect(find.textContaining('本周'), findsNothing);
    expect(find.byType(ProductBadge), findsNothing, reason: '没有徽标的商品不渲染徽标');
  });

  testWidgets('下单页：服务端 400 的中文拦截文案原样弹出（客户端不硬编码拦截规则）', (tester) async {
    const serverMessage = '该商品每位用户每周限购 2 单，你本周已下单 2 单，请下周再来';
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(
      fixture(quotaData: quota(orderedCount: 2, remaining: 0)),
      postError: {'code': 400, 'message': serverMessage, 'data': null},
    );
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: ApiClient(dio: dio), divisionId: '1', product: featured),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.enterText(find.byType(TextField).first, '1234567890');
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交订单'));
    await tester.pump(); // 发起请求
    await tester.pump(const Duration(milliseconds: 400)); // 浮层进场

    expect(find.text(serverMessage), findsOneWidget, reason: '拦截文案必须逐字来自服务端');
    expect(find.textContaining('积分'), findsNothing, reason: '旧单位不得再出现');
    // 客户端**不得**用自造文案顶替服务端拦截语（本夹具没有余额接口 → 不显示任何余额提示）
    expect(find.textContaining('余额不足'), findsNothing);

    // 浮层 2 秒后自动消失（AppToast 内部 Timer）—— 推到它结束，避免测试结束时留下 pending timer
    await tester.pump(const Duration(seconds: 3));
  });
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, {this.postError});
  final Map<String, Map<String, dynamic>> raw;

  /// POST 请求统一返回的错误体（null = 正常返回 fixture）
  final Map<String, dynamic>? postError;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST' && postError != null) {
      return ResponseBody.fromString(jsonEncode(postError), (postError!['code'] as int?) ?? 400, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
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
