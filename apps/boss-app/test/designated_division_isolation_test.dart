import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端「指定护航员」· **分部严格隔离**（负责人 2026-10-04 硬要求）
///
/// 规则原文：老板点某分部下单时，选择器里只能出现**该分部有接单权限**的打手 ——
/// 「不能出现老板点三角洲手游却看到端游的人，其他同理」。
///
/// 服务端已按 `worker_division_permission` 过滤（`/public/players?divisionId=`），
/// 客户端必须做到：
/// 1) 每次选人都带上**当前商品的分部 id**（分部不同 → 请求参数不同 → SWR 缓存键不同，绝不串分部）
/// 2) 只渲染服务端返回的那一份名单（手游分部的假数据里没有端游打手，断言他绝不出现）
/// 3) 该分部暂时没人可指定时，给明确空态（「该分部暂无可指定的护航员」）
void main() {
  /// 两个分部的商品（divisionId 决定"点的是哪个游戏分部"）
  final productMobile = {
    'id': '201',
    'name': '手游护航单',
    'subtitle': '',
    'gameId': '36',
    'categoryId': '51',
    'divisionId': '2',
    'price': 88,
    'priceUnit': '单',
    'salesCount': 12,
    'coverMediaId': null,
    'coverUrl': null,
  };
  final productPc = {...productMobile, 'id': '202', 'name': '端游护航单', 'divisionId': '3', 'price': 99};

  /// 打手名单：A 只接手游、B 只接端游、C 两个都接（服务端按分部返回的子集）
  final playersMobile = [
    {'workerId': '11', 'nickname': '手游打手A', 'intro': '只接三角洲手游', 'avatarMediaId': null, 'divisionId': '2'},
    {'workerId': '13', 'nickname': '双分部打手C', 'intro': '手游端游都接', 'avatarMediaId': null, 'divisionId': '2'},
  ];
  final playersPc = [
    {'workerId': '12', 'nickname': '端游打手B', 'intro': '只接三角洲端游', 'avatarMediaId': null, 'divisionId': '3'},
    {'workerId': '13', 'nickname': '双分部打手C', 'intro': '手游端游都接', 'avatarMediaId': null, 'divisionId': '3'},
  ];

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 公开 GET 会进 ApiCache：cases 共用同一个 baseUrl，不清缓存会命中上一个 case 的 fixture
    ApiCache.instance.clear();
  });

  Future<void> pumpCreate(WidgetTester tester, _PlayersAdapter adapter, Map<String, dynamic> product) async {
    await tester.pumpWidget(MaterialApp(
      // 每次 pump 用不同 key：同一个测试里连开两个分部的下单页时，避免 Flutter 复用上一个 State
      // （复用会让"已指定：X"残留、第二次找不到「指定护航员」按钮）
      home: OrderCreatePage(
        key: ValueKey('create-${product['id']}'),
        api: _api(adapter),
        divisionId: '${product['divisionId']}',
        product: product,
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> openPicker(WidgetTester tester) async {
    // 护航员卡在页面下方（真机也是滚动列表）
    await tester.drag(find.byType(ListView).first, const Offset(0, -420));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    await tester.tap(find.text('指定护航员'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  }

  testWidgets('点「三角洲手游」商品：只列手游分部的打手，绝不出现端游人', (tester) async {
    final adapter = _PlayersAdapter(playersByDivision: {'2': playersMobile, '3': playersPc});
    await pumpCreate(tester, adapter, productMobile);
    await openPicker(tester);

    expect(adapter.playersQueries, contains('2'), reason: '选人必须带上当前商品的分部 id');
    expect(find.text('手游打手A'), findsOneWidget);
    expect(find.text('双分部打手C'), findsOneWidget);
    expect(find.text('端游打手B'), findsNothing,
        reason: '老板点的是手游分部 → 只接端游的人绝不能出现在选择器里');
  });

  testWidgets('点「三角洲端游」商品：只列端游分部的打手，绝不出现手游人（反向同理）', (tester) async {
    final adapter = _PlayersAdapter(playersByDivision: {'2': playersMobile, '3': playersPc});
    await pumpCreate(tester, adapter, productPc);
    await openPicker(tester);

    expect(adapter.playersQueries, contains('3'));
    expect(find.text('端游打手B'), findsOneWidget);
    expect(find.text('双分部打手C'), findsOneWidget);
    expect(find.text('手游打手A'), findsNothing,
        reason: '老板点的是端游分部 → 只接手游的人绝不能出现');
  });

  testWidgets('同一页面连开两个分部：缓存键含 divisionId，名单不串（点端游不会拿到手游的人）', (tester) async {
    // 同一个 ApiClient / 同一个 ApiCache 实例，先看手游再看端游
    // （两次 pump 用不同 key：否则 Flutter 复用同一个 State，"已指定：X" 会残留、第二次点不到「指定护航员」）
    final adapter = _PlayersAdapter(playersByDivision: {'2': playersMobile, '3': playersPc});
    final api = _api(adapter);

    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(key: const ValueKey('create-mobile'), api: api, divisionId: '2', product: productMobile),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await openPicker(tester);
    expect(find.text('手游打手A'), findsOneWidget);
    await tester.tap(find.text('双分部打手C'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('已指定：双分部打手C'), findsOneWidget, reason: '选定后回填到护航员卡');

    // 换端游商品（不同分部）→ 名单必须换成端游那一份
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(key: const ValueKey('create-pc'), api: api, divisionId: '3', product: productPc),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await openPicker(tester);

    expect(find.text('端游打手B'), findsOneWidget);
    expect(find.text('手游打手A'), findsNothing, reason: 'divisionId 参与缓存键 → 不会命中手游分部的旧名单');
    expect(adapter.playersQueries, ['2', '3']);
  });

  testWidgets('该分部暂无可指定护航员：明确空态文案（不是"暂无在线护航员"含糊提示）', (tester) async {
    final adapter = _PlayersAdapter(playersByDivision: {'2': const [], '3': playersPc});
    await pumpCreate(tester, adapter, productMobile);
    await openPicker(tester);

    expect(find.text('该分部暂无可指定的护航员'), findsOneWidget);
  });
}

ApiClient _api(_PlayersAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 假数据源：`/public/players?divisionId=N` 只返回该分部有接单权限的打手（服务端行为的模拟）
class _PlayersAdapter implements HttpClientAdapter {
  _PlayersAdapter({required this.playersByDivision});

  final Map<String, List<dynamic>> playersByDivision;

  /// 每次「指定护航员」请求实际带的 divisionId（按顺序）
  final List<String> playersQueries = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    // 注意：/divisions 的 data 是**数组**，/public/order-form 的 data 是对象，
    // /public/players 的 data 是 {list,total,...} —— 形状必须与服务端一致（页面按形状解析）
    late final Map<String, dynamic> envelope;
    if (options.path.startsWith('/public/players')) {
      final div = '${options.queryParameters['divisionId'] ?? ''}';
      playersQueries.add(div);
      final list = playersByDivision[div] ?? const <dynamic>[];
      envelope = _envelope({'list': list, 'total': list.length, 'page': 1, 'pageSize': 50});
    } else if (options.path.startsWith('/divisions')) {
      envelope = _envelope(divisionsFixture);
    } else if (options.path.startsWith('/public/order-form')) {
      envelope = _envelope(orderFormFixture);
    } else {
      envelope = _envelope(const {'list': [], 'total': 0});
    }
    return ResponseBody.fromString(jsonEncode(envelope), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  static Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  @override
  void close({bool force = false}) {}

  // 顶层常量（供 fetch 使用；避免闭包捕获顺序问题）
  static final List<dynamic> divisionsFixture = [
    {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'themeColor': '#2563EB', 'iconMediaId': null},
    {'id': '3', 'gameId': '36', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'platformLabel': '端游', 'themeColor': '#7C3AED', 'iconMediaId': null},
  ];
  static final Map<String, dynamic> orderFormFixture = {
    'zoneLabel': '选择区服',
    'zoneOptions': [
      {'label': 'QQ', 'value': 'qq'},
    ],
    'fields': [
      {'key': 'gamePlayerId', 'label': '游戏ID', 'placeholder': '填 ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 64},
    ],
    'workerLabel': '选择护航员',
    'workerRandomLabel': '随机安排',
    'workerDesignatedLabel': '指定护航员',
    'feeTitle': '商品费用',
    'feeUnitLabel': '单价',
    'totalLabel': '合计',
    'submitText': '提交订单',
  };
}
