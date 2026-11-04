import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品列表排序回归（负责人 2026-10-04：价格/销量排序无作用）
///
/// 根因：后台预取分类时把**原始顺序**写入列表缓存，命中缓存后不再排序 → 排序看起来失效。
/// 修法：排序统一在读取时应用（`_applySort`），读缓存与读网络都经过它。
/// 本测试确保：点销量/价格后，列表顺序**确实变化**。
void main() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  final divisions = [
    {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'themeColor': '#16A34A', 'iconMediaId': null},
  ];
  final categories = [
    {'id': '44', 'gameId': '35', 'name': '段位上分'},
  ];
  // 故意给三种排序互不相同的顺序：价格升 = 乙丙甲；价格降 = 甲丙乙；销量 = 丙乙甲
  final products = [
    {'id': '1', 'name': '甲商品', 'price': 300, 'priceUnit': '局', 'salesCount': 5, 'coverMediaId': null, 'coverUrl': null, 'categoryId': '44', 'divisionId': '1'},
    {'id': '2', 'name': '乙商品', 'price': 100, 'priceUnit': '局', 'salesCount': 10, 'coverMediaId': null, 'coverUrl': null, 'categoryId': '44', 'divisionId': '1'},
    {'id': '3', 'name': '丙商品', 'price': 200, 'priceUnit': '局', 'salesCount': 99, 'coverMediaId': null, 'coverUrl': null, 'categoryId': '44', 'divisionId': '1'},
  ];

  Map<String, Map<String, dynamic>> fixture() => {
        '/divisions': envelope(divisions),
        '/public/categories': envelope(categories),
        '/public/products': envelope({'list': products, 'total': 3}),
        '/public/order-form': envelope(const {}),
      };

  setUp(() {
    ApiClient.cacheEnabled = false; // 单测关闭接口缓存，聚焦列表层排序逻辑
  });

  /// 取当前列表里商品名的显示顺序
  List<String> visibleOrder(WidgetTester tester) {
    const names = ['甲商品', '乙商品', '丙商品'];
    final found = <(double, String)>[];
    for (final n in names) {
      final f = find.text(n);
      if (f.evaluate().isEmpty) continue;
      found.add((tester.getTopLeft(f.first).dy, n));
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return found.map((e) => e.$2).toList();
  }

  testWidgets('销量排序：按销量从高到低重排（丙 99 → 乙 10 → 甲 5）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('销量'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));

    expect(visibleOrder(tester), ['丙商品', '乙商品', '甲商品']);
  });

  testWidgets('价格排序：第一次升序（乙 100 → 丙 200 → 甲 300），再点转降序', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.textContaining('价格'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(visibleOrder(tester), ['乙商品', '丙商品', '甲商品'], reason: '升序：100 → 200 → 300');

    await tester.tap(find.textContaining('价格'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(visibleOrder(tester), ['甲商品', '丙商品', '乙商品'], reason: '降序：300 → 200 → 100');
  });

  testWidgets('回归：预取缓存命中后排序仍然生效（原 bug 场景）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 先切销量（触发一次加载 + 缓存写入），再切回综合，再切价格 → 每一步都必须重排
    await tester.tap(find.text('销量'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(visibleOrder(tester), ['丙商品', '乙商品', '甲商品']);

    await tester.tap(find.textContaining('价格'));
    await tester.pumpAndSettle(const Duration(milliseconds: 600));
    expect(visibleOrder(tester), ['乙商品', '丙商品', '甲商品'], reason: '切到价格升序必须重排（不能沿用销量顺序）');
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
