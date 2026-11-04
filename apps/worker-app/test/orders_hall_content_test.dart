import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/orders_page.dart';

/// 工作端接单页面 · 单子内容与数量 + 分区/ID 隐私（负责人需求 2026-09-24）
///
/// 1) 大厅卡片展示「商品名 × 数量」——多个老板点同一商品 = 各自一条订单（不合并）
/// 2) 大厅卡片**不显示**游戏分区/游戏ID（服务端不返回，页面也绝不能渲染）
/// 3) 抢单后「我的订单」显示老板游戏分区与ID
void main() {
  // 大厅真实结构（服务端大厅响应：productName/quantity，无 gameZone/gamePlayerId）
  final hall = [
    {'id': '429', 'orderNo': 'ORDA1', 'quantity': 2, 'totalAmount': 300, 'status': 'pending_take', 'statusName': '待接单', 'createdAt': '2026-09-23T16:43:06Z', 'productName': 'DMZ材料单', 'priceUnit': '单'},
    {'id': '430', 'orderNo': 'ORDB2', 'quantity': 3, 'totalAmount': 450, 'status': 'pending_take', 'statusName': '待接单', 'createdAt': '2026-09-23T16:43:07Z', 'productName': 'DMZ材料单', 'priceUnit': '单'},
    {'id': '431', 'orderNo': 'ORDC3', 'quantity': 1, 'totalAmount': 5.5, 'status': 'pending_take', 'statusName': '待接单', 'createdAt': '2026-09-23T16:43:08Z', 'productName': '钻皮·刀', 'priceUnit': '局'},
  ];
  // 我的订单（抢单后：带分区/ID）
  final mine = [
    {'id': '429', 'orderNo': 'ORDA1', 'quantity': 2, 'totalAmount': 300, 'status': 'taken', 'statusName': '已接单', 'createdAt': '2026-09-23T16:43:06Z', 'productName': 'DMZ材料单', 'priceUnit': '单', 'gameZone': 'qq', 'gamePlayerId': '88888888'},
  ];

  testWidgets('大厅：同商品两条订单各自展示（不合并）+ 各自数量', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api({'/worker/order-hall': hall, '/worker/orders': mine}))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('DMZ材料单 × 2'), findsOneWidget); // 老板A的单：数量2
    expect(find.text('DMZ材料单 × 3'), findsOneWidget); // 老板B的单：数量3（绝不合并成一条）
    expect(find.text('钻皮·刀 × 1'), findsOneWidget); // 小数价商品内容也展示
  });

  testWidgets('大厅：绝不显示游戏分区与游戏ID', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api({'/worker/order-hall': hall, '/worker/orders': mine}))));
    await tester.pumpAndSettle();

    expect(find.textContaining('QQ区'), findsNothing);
    expect(find.textContaining('微信区'), findsNothing);
    expect(find.textContaining('88888888'), findsNothing);
    expect(find.textContaining('游戏ID'), findsNothing);
  });

  testWidgets('我的订单：抢单后显示老板游戏分区与ID', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api({'/worker/order-hall': hall, '/worker/orders': mine}))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的订单'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('QQ区 · ID 88888888'), findsOneWidget);
  });
}

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
    final matches = byPath.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
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
