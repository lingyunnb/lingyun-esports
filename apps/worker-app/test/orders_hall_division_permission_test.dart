import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/orders_page.dart';

/// 工作端接单大厅 · **分部接单权限隔离**（负责人 2026-10-04）
///
/// 背景：接单权限从「全局开关」下沉到「打手 × 分部」（和平 / 三角洲手游 / 三角洲端游）。
/// 服务端按权限过滤大厅与抢单，客户端要做的三件事：
///
/// 1) 分部筛选胶囊**只列有接单权限的分部**（没权限的分部根本不出现，杜绝点进去一片空白）
/// 2) 大厅只渲染服务端按权限过滤后的单 —— 只接手游的打手**不可能**看到端游的单
/// 3) 无权限分部：服务端返回 `divisionDenied + message` → 页面显示中文提示
///    （「你暂无该分部的接单权限，请联系管理员」），而不是空白或整页报错
void main() {
  /// 手游打手 A 的权限：三角洲手游 = 有，端游 = 无（服务端实时查库的结果）
  /// 注意这是**响应体的 data**（适配器负责再包一层 code/message/data）
  final permissionsOneMobile = {
    'list': [
      {'divisionId': '2', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
      {'divisionId': '3', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': false},
    ],
    'permittedCount': 1,
  };

  /// 完全没授权的打手
  final permissionsNone = {
    'list': [
      {'divisionId': '2', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': false},
      {'divisionId': '3', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': false},
    ],
    'permittedCount': 0,
  };

  final hallMobile = [
    {'id': '501', 'orderNo': 'ORDM1', 'quantity': 1, 'totalAmount': 88, 'status': 'pending_take', 'statusName': '待接单', 'createdAt': '2026-10-04T20:00:00Z', 'productName': '手游陪练单', 'priceUnit': '单', 'divisionId': '2'},
  ];
  final hallPc = [
    {'id': '502', 'orderNo': 'ORDP1', 'quantity': 1, 'totalAmount': 99, 'status': 'pending_take', 'statusName': '待接单', 'createdAt': '2026-10-04T20:01:00Z', 'productName': '端游陪练单', 'priceUnit': '单', 'divisionId': '3'},
  ];

  testWidgets('分部胶囊只列有接单权限的分部（端游无权限 → 不出现）', (tester) async {
    final adapter = _HallAdapter(permissions: permissionsOneMobile, hall: hallMobile, hallPc: hallPc);
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(adapter))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('全部分部'), findsOneWidget);
    expect(find.text('三角洲行动 · 手游'), findsOneWidget, reason: '有权限的分部出现在筛选胶囊里');
    expect(find.text('三角洲行动 · 端游'), findsNothing,
        reason: '没有端游接单权限 → 端游分部不该出现在胶囊里（点了也是空）');
  });

  testWidgets('大厅只显示有权限分部的单：手游打手看不到端游的单', (tester) async {
    final adapter = _HallAdapter(permissions: permissionsOneMobile, hall: hallMobile, hallPc: hallPc);
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(adapter))));
    await tester.pumpAndSettle();

    expect(find.text('手游陪练单 × 1'), findsOneWidget);
    expect(find.text('端游陪练单 × 1'), findsNothing,
        reason: '服务端按分部权限过滤：只接手游的打手拿不到端游的单');
    // 未指定分部时 = 该打手的全部可用分部（不带 divisionId 请求）
    expect(adapter.hallQueries.first, isEmpty);
  });

  testWidgets('点分部胶囊：带上 divisionId 实时回源（绕过缓存）', (tester) async {
    final adapter = _HallAdapter(permissions: permissionsOneMobile, hall: hallMobile, hallPc: hallPc);
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(adapter))));
    await tester.pumpAndSettle();

    await tester.tap(find.text('三角洲行动 · 手游'));
    await tester.pumpAndSettle();

    expect(adapter.hallQueries.length, greaterThanOrEqualTo(2));
    expect(adapter.hallQueries.last, '2', reason: '选中手游分部 → 请求带 divisionId=2');
    expect(find.text('手游陪练单 × 1'), findsOneWidget);
  });

  testWidgets('无任何分部权限：服务端下发 divisionDenied → 显示中文空态提示（不是空白）', (tester) async {
    final adapter = _HallAdapter(
      permissions: permissionsNone,
      hall: const [],
      hallPc: hallPc,
      hallDeniedMessage: '你暂无任何分部的接单权限，请联系管理员',
      // 没有任何分部权限时，服务端对"不传 divisionId"的大厅查询也会返回 divisionDenied
      denyAll: true,
    );
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(adapter))));
    await tester.pumpAndSettle();

    expect(find.text('你暂无任何分部的接单权限，请联系管理员'), findsOneWidget);
    expect(find.text('全部分部'), findsNothing, reason: '没有任何分部权限 → 不显示分部筛选胶囊');
  });

  testWidgets('指定无权限分部（服务端拒绝）：显示「暂无该分部接单权限」提示', (tester) async {
    // 打手有手游权限（胶囊里只有手游），但服务端对 divisionId=2 也返回拒绝时，
    // 页面必须原样显示服务端的中文 message（客户端不自己编文案）
    final adapter = _HallAdapter(
      permissions: permissionsOneMobile,
      hall: const [],
      hallPc: hallPc,
      hallDeniedMessage: '你暂无该分部的接单权限，请联系管理员',
      denyAll: true,
    );
    await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(adapter))));
    await tester.pumpAndSettle();

    expect(find.text('你暂无该分部的接单权限，请联系管理员'), findsOneWidget);
  });
}

ApiClient _api(_HallAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 假数据源：按分部返回不同的护航员/订单，模拟"服务端已按分部接单权限过滤"
class _HallAdapter implements HttpClientAdapter {
  _HallAdapter({
    required this.permissions,
    required this.hall,
    required this.hallPc,
    this.hallDeniedMessage,
    this.denyAll = false,
  });

  final Map<String, dynamic> permissions;
  final List<dynamic> hall;
  final List<dynamic> hallPc;
  final String? hallDeniedMessage;
  final bool denyAll;

  /// 大厅每次请求带的 divisionId（'' = 未指定）
  final List<String> hallQueries = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Map<String, dynamic> body;
    if (options.path.startsWith('/worker/division-permissions')) {
      body = permissions;
    } else if (options.path.startsWith('/worker/order-hall')) {
      final div = '${options.queryParameters['divisionId'] ?? ''}';
      hallQueries.add(div);
      // divisionId=3（端游）无权限 → 服务端返回空 + 提示；denyAll 用于模拟"该分部也拒绝"
      final denied = denyAll || (div.isNotEmpty && div != '2');
      body = denied
          ? {
              'list': const [],
              'total': 0,
              'page': 1,
              'pageSize': 50,
              'divisionDenied': true,
              'message': hallDeniedMessage ?? '你暂无该分部的接单权限，请联系管理员',
            }
          : {'list': div == '3' ? hallPc : hall, 'total': (div == '3' ? hallPc : hall).length, 'page': 1, 'pageSize': 50};
    } else if (options.path.startsWith('/worker/orders')) {
      body = {'list': const [], 'total': 0, 'page': 1, 'pageSize': 50};
    } else {
      body = const {'list': [], 'total': 0};
    }
    return ResponseBody.fromString(jsonEncode({'code': 0, 'message': 'ok', 'data': body}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
