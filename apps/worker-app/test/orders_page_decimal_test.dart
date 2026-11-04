import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/orders_page.dart';

/// 工作端订单页 · 小数金额回归（2026-09-23 负责人价目表 5.5 积分）
///
/// 修复前：`json['totalAmount'] as int?` 遇到服务端返回的 5.5 → TypeError → 整页崩溃。
/// 本测试用**生产库真实响应夹具**渲染真实页面，断言 5.5 正常展示且页面无异常。
void main() {
  final fixture = jsonDecode(
    File('../packages/core/test/fixtures/live_orders.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final hall = fixture['orderHall'] as List<dynamic>;
  final mine = fixture['workerOrders'] as List<dynamic>;

  testWidgets('接单大厅：5.5 积分订单正常渲染（不再崩溃）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api({'/worker/order-hall': hall}))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final decimal = hall.cast<Map<String, dynamic>>().firstWhere((o) => parsePoints(o['totalAmount']) == 5.5);
    expect(find.textContaining(decimal['orderNo'] as String), findsOneWidget);
    expect(find.text('5.5 积分'), findsWidgets); // 展示规范：不是 5.50，也不能是 6
  });

  testWidgets('我的订单：含小数结算的订单正常渲染', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api({'/worker/orders': mine, '/worker/order-hall': hall}))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的订单'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('积分'), findsWidgets);
    for (final raw in mine.cast<Map<String, dynamic>>()) {
      expect(find.text('${fmtPoints(parsePoints(raw['totalAmount']))} 积分'), findsWidgets);
      break; // 只校验首屏可见项，列表按需构建
    }
  });
}

/// 按路径前缀返回夹具数据的 Dio（不联网）
ApiClient _api(Map<String, List<dynamic>> byPath) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _FixtureAdapter(byPath);
  return ApiClient(dio: dio);
}

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.byPath);

  final Map<String, List<dynamic>> byPath;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = byPath.keys.firstWhere(options.path.startsWith, orElse: () => '');
    final list = key.isEmpty ? const <dynamic>[] : byPath[key]!;
    final body = jsonEncode({
      'code': 0,
      'message': 'ok',
      'data': {'list': list, 'total': list.length, 'page': 1, 'pageSize': 50},
    });
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
