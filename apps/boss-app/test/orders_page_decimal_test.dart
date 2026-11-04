import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/pages/orders_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端订单页 · 小数金额回归（2026-09-23 负责人价目表 5.5；口径 2026-10-09 = 余额 ¥）
///
/// 修复前：`json['totalAmount'] as int?` 遇到服务端返回的 5.5 → TypeError → 整页崩溃
///（生产库真实数据 50 条里有 2 条小数订单，必然触发）。本测试用真实响应夹具渲染真实页面。
void main() {
  final fixture = jsonDecode(
    File('../packages/core/test/fixtures/live_orders.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final orders = fixture['userOrders'] as List<dynamic>;

  setUp(() {
    // 【2026-10-04 性能专项】公开/列表 GET 现在会真正进 ApiCache。本文件多个 case 共用
    // `baseUrl = http://fixture.local` 且请求同一批订单路径，不清缓存会让后一个 case
    // 命中前一个 case 的**详情响应**（例如"无 settlement 字段"的 case 拿到有 settlement 的旧响应）。
    ApiCache.instance.clear();
  });

  testWidgets('订单列表：含 5.5 余额订单时正常渲染（不再崩溃）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api({'/user/orders': orders}))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final decimals = orders.cast<Map<String, dynamic>>().where((o) => parsePoints(o['totalAmount']) == 5.5);
    expect(decimals, isNotEmpty, reason: '夹具应含 5.5 余额订单');
    // 金额展示：¥ + 固定两位小数（整数金额也补 .00），旧单位「积分」彻底消失
    expect(find.text('¥5.50'), findsWidgets);
    expect(find.textContaining('积分'), findsNothing, reason: '订单页不再出现旧单位');
  });

  testWidgets('订单详情弹层：快照单价/商品费用/结算金额均为小数安全且带 ¥', (tester) async {
    // 结构取自生产库实测（GET /user/orders/396）。
    //
    // 【2026-10-04 抽成可配置】抽成比例已改为后台可配（默认 25% = 打手 75%），
    // 服务端在 `settlement` 里下发 `workerPercentage` / `platformPercentage`。
    // 这里**故意用 75/25 而不是历史写死的 70/30**：如果客户端又把比例写回代码里，
    // 下面两条断言就会失败 —— 这正是本用例要守住的回归点。
    // 金额仍按"服务端分账放第一位"的口径：金额守恒（3.85 + 1.65 = 5.5）。
    final detail = {
      'code': 0,
      'message': 'ok',
      'data': {
        'id': '396',
        'orderNo': 'ORDMUE8SIVK2535',
        'totalAmount': 5.5,
        'statusName': '待接单',
        'createdAt': '2026-09-23T15:12:54.417Z',
        'snapshot': {
          'productName': '钻皮·刀',
          'gameName': '使命召唤手游',
          'categoryName': '肝皮业务',
          'unitPrice': 5.5,
          'priceUnit': '局',
          'quantity': 1,
          'totalAmount': 5.5,
        },
        'workerInfo': null,
        'settlement': {
          'settlementNo': 'STLMUE8SIVK2535',
          'orderAmount': 5.5,
          'workerAmount': 3.85,
          'workerPercentage': 75,
          'platformAmount': 1.65,
          'platformPercentage': 25,
        },
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: OrdersPage(api: _api({'/user/orders': orders}, raw: {'/user/orders/396': detail})),
    ));
    await tester.pumpAndSettle();

    // 点订单卡片打开详情弹层（老板端交互：点卡片查看）
    await tester.tap(find.text('订单 ORDMUE8SIVK2535'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 详情改版：标题换成「状态头部 + 分区卡」，断言关键分区存在
    expect(find.text('服务信息'), findsWidgets);
    expect(find.text('下单信息'), findsWidgets);
    expect(find.text('¥5.50/局 × 1'), findsOneWidget); // 快照单价（小数，¥ 两位小数）
    expect(find.text('¥3.85'), findsOneWidget); // 打手收益（小数）
    expect(find.text('¥1.65'), findsOneWidget); // 平台抽成（小数）
    expect(find.textContaining('积分'), findsNothing, reason: '订单详情不再出现旧单位');
    // 比例必须**跟随接口下发值**（75/25），不得写死 70/30
    expect(find.text('护航员收益 (75%)'), findsOneWidget);
    expect(find.text('平台服务费 (25%)'), findsOneWidget);
    expect(find.textContaining('(70%)'), findsNothing, reason: '客户端不得再写死 70%');
    expect(find.textContaining('(30%)'), findsNothing, reason: '客户端不得再写死 30%');
  });

  testWidgets('结算比例取不到时只显示金额，不显示百分比（不猜、不回退 70/30）', (tester) async {
    // 用夹具里真实存在的订单号，保证列表里点得到那张卡（否则 tap 找不到目标）
    final first = orders.first as Map<String, dynamic>;
    final oid = '${first['id']}';
    final ono = '${first['orderNo']}';
    final detail = {
      'code': 0,
      'message': 'ok',
      'data': {
        'id': oid,
        'orderNo': ono,
        'totalAmount': 10,
        'statusName': '已完成',
        'snapshot': null,
        'workerInfo': null,
        // 服务端未下发比例（老数据 / 字段缺失）→ 标签只留文字
        'settlement': {'settlementNo': 'STLNOFIELDS', 'workerAmount': 7.5, 'platformAmount': 2.5},
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: OrdersPage(api: _api({'/user/orders': orders}, raw: {'/user/orders/$oid': detail})),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('订单 $ono'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('护航员收益'), findsOneWidget, reason: '无比例 → 标签不带括号百分比');
    expect(find.text('平台服务费'), findsOneWidget);
    expect(find.textContaining('(70%)'), findsNothing);
    expect(find.textContaining('(75%)'), findsNothing, reason: '取不到就什么都不显示，不猜');
  });

  testWidgets('确认结算弹窗的比例同样跟随接口下发值（不再写死 70/30）', (tester) async {
    // 抽成改成后台可配后，"确认结算"预览也必须读服务端比例。
    // 这里服务端下发 75/25，弹窗文案必须出现 75%/25%，且**绝不出现** 70%/30%。
    const pending = [
      {
        'id': '395',
        'orderNo': 'ORDPENDINGCONFIRM',
        'quantity': 1,
        'unitPrice': 10,
        'totalAmount': 10,
        'status': 'pending_confirm',
        'statusName': '待确认',
        'createdAt': '2026-09-23T15:12:54.417Z',
      },
    ];
    final detail = {
      'code': 0,
      'message': 'ok',
      'data': {
        'id': '395',
        'orderNo': 'ORDPENDINGCONFIRM',
        'totalAmount': 10,
        'statusName': '待确认',
        'snapshot': null,
        'workerInfo': null,
        'settlement': {'workerPercentage': 75, 'platformPercentage': 25},
      },
    };
    await tester.pumpWidget(MaterialApp(
      home: OrdersPage(api: _api({'/user/orders': pending}, raw: {'/user/orders/395': detail})),
    ));
    await tester.pumpAndSettle();

    // 打开详情弹层 → 点「确认完成」触发确认弹窗
    // 注意 1：卡片上也有一个「确认完成」，弹层里的那个在 widget 树中靠后 → 取 .last
    // 注意 2：详情弹层内容较长，默认 800px 测试视口下底部操作行会被挤出屏幕，
    //        必须先 ensureVisible（否则 tap 命中不到，表现为"点了没反应"）
    await tester.tap(find.text('订单 ORDPENDINGCONFIRM'));
    await tester.pumpAndSettle();
    final confirmBtn = find.text('确认完成').last;
    await tester.ensureVisible(confirmBtn);
    await tester.pumpAndSettle();
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('打手获得'), findsOneWidget);
    expect(find.textContaining('（75%）'), findsOneWidget, reason: '比例必须来自接口（75%）');
    expect(find.textContaining('（25%）'), findsOneWidget, reason: '比例必须来自接口（25%）');
    expect(find.textContaining('70%'), findsNothing, reason: '客户端不得再写死 70%');
    expect(find.textContaining('30%'), findsNothing, reason: '客户端不得再写死 30%');
  });
}

ApiClient _api(Map<String, List<dynamic>> byPath, {Map<String, Map<String, dynamic>> raw = const {}}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _FixtureAdapter(byPath, raw);
  return ApiClient(dio: dio);
}

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.byPath, this.raw);

  final Map<String, List<dynamic>> byPath;

  /// 精确路径 → 完整响应体（详情类接口）
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (raw.containsKey(options.path)) {
      return ResponseBody.fromString(jsonEncode(raw[options.path]), 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
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
