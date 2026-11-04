import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:boss_app/widgets/division_platform_label.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 平台标识测试（负责人 2026-10-04）
///
/// 需求：老板端「选择服务」（服务/商品列表）区域上方要标明当前分部是**手游**还是**端游**
/// （三角洲行动有手游/端游两个分部；和平精英只有手游）。
///
/// 本测试锁死：
/// 1) 商品列表页：默认分部显示「和平精英 · 手游」；切到端游分部显示「三角洲行动 · 端游」；
///    再切回手游分部显示「三角洲行动 · 手游」（且不再出现「端游」）
/// 2) 标识位于服务列表**上方**（比较与「综合」排序行的纵向位置）
/// 3) 确认订单页：商品挂端游分部时，服务区上方同样显示「三角洲行动 · 端游」
void main() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  final divisions = [
    {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'platformLabel': '手游', 'platform': 'mobile', 'themeColor': '#16A34A'},
    {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'platform': 'mobile', 'themeColor': '#2563EB'},
    {'id': '3', 'gameId': '36', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'platformLabel': '端游', 'platform': 'pc', 'themeColor': '#7C3AED'},
  ];
  final categories = [
    {'id': '44', 'gameId': '35', 'name': '段位上分'},
    {'id': '45', 'gameId': '36', 'name': '护航保底'},
  ];
  final products = [
    {
      'id': '101', 'name': '传奇段位上分陪练', 'subtitle': '全段位可接', 'gameId': '35', 'categoryId': '44',
      'divisionId': '1', 'price': 100, 'priceUnit': '局', 'salesCount': 24811, 'coverMediaId': null, 'coverUrl': null,
    },
  ];
  final pcProducts = [
    {
      'id': '201', 'name': '端游冲刺陪练', 'subtitle': '端游专享', 'gameId': '36', 'categoryId': '45',
      'divisionId': '3', 'price': 88, 'priceUnit': '局', 'salesCount': 36, 'coverMediaId': null, 'coverUrl': null,
    },
  ];
  final orderForm = {
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
  };

  Map<String, Map<String, dynamic>> fixture() => {
        '/divisions': envelope(divisions),
        '/public/categories': envelope(categories),
        '/public/products': envelope({'list': products, 'total': 1}),
        '/public/order-form': envelope(orderForm),
        '/public/players': envelope({'list': const [], 'total': 0}),
      };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
  });

  /// 取平台标识这一行的文案（用稳定 Key 定位，避免与商品卡上的分部标签撞文案）
  String labelText(WidgetTester tester) {
    final finder = find.descendant(of: find.byKey(DivisionPlatformLabel.labelKey), matching: find.byType(Text));
    expect(finder, findsOneWidget, reason: '平台标识应存在且只有一行');
    return tester.widget<Text>(finder).data ?? '';
  }

  testWidgets('商品列表：平台标识随分部切换显示 手游 / 端游', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 初始分部 = 第一个分部（和平精英 · 手游）
    expect(labelText(tester), '和平精英 · 手游');

    // 标识必须在服务列表（排序行）上方
    final labelY = tester.getTopLeft(find.byKey(DivisionPlatformLabel.labelKey)).dy;
    final sortY = tester.getTopLeft(find.text('综合')).dy;
    expect(labelY < sortY, isTrue, reason: '平台标识应在服务列表上方（label=$labelY sort=$sortY）');

    // 切到「三角洲行动 · 端游」（分区胶囊行里『三角洲行动』出现两次：手游在前、端游在后）
    await tester.tap(find.text('三角洲行动').at(1));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(labelText(tester), '三角洲行动 · 端游');

    // 切回「三角洲行动 · 手游」
    await tester.tap(find.text('三角洲行动').at(0));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(labelText(tester), '三角洲行动 · 手游');
  });

  testWidgets('确认订单：商品挂端游分部时，服务区上方显示 三角洲行动 · 端游', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(fixture()), divisionId: '3', product: pcProducts.first),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(labelText(tester), '三角洲行动 · 端游');
    // 位于「选择区服」卡片上方
    final labelY = tester.getTopLeft(find.byKey(DivisionPlatformLabel.labelKey)).dy;
    final zoneY = tester.getTopLeft(find.text('选择区服')).dy;
    expect(labelY < zoneY, isTrue, reason: '平台标识应在服务区上方（label=$labelY zone=$zoneY）');
  });

  testWidgets('确认订单：商品挂手游分部时显示 和平精英 · 手游', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(fixture()), divisionId: '1', product: products.first),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(labelText(tester), '和平精英 · 手游');
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
