import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/complaint_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 投诉页（负责人 2026-10-04 顶部导航「投诉」）
///
/// 覆盖：
/// 1) 表单：对象三选一（订单/打手/客服）+ 类型四选一 + 描述 + 截图位
/// 2) 提交：客服对象无需目标 id；请求体携带 targetType/type/content/mediaIds（投诉人由服务端取 JWT）
/// 3) 描述过短拦下不发请求
/// 4) 我的投诉：状态与处理结果展示
/// 5) **2026-10-05 任务②**：订单候选只含可投诉状态；已取消的单不显示（请求口径 + 候选集合双向断言）
/// 6) **2026-10-05 任务③**：打手候选只来自 `/user/complaints/targets/workers`（接过我单的人），
///    选定订单后按 `?orderId=` 收敛为该单接单人；服务端 400 中文原文照实呈现
void main() {
  /// 订单候选（服务端已按可投诉状态过滤后的结果）：
  /// - `682` pending_confirm 待用户确认 → 可投诉
  /// - `683` completed 已完成 → 可投诉
  /// - `684` canceled 已取消 → **服务端不该下发**（fixture 里刻意留着，用于证明页面不渲染它）
  final myOrders = {
    'list': [
      {'id': '682', 'orderNo': 'ORDMUTCDDG01232', 'productName': '传奇段位上分陪练', 'status': 'pending_confirm'},
      {'id': '683', 'orderNo': 'ORDMUTCDDG01999', 'productName': '三角洲烽火地带护航', 'status': 'completed'},
      {'id': '684', 'orderNo': 'ORDMUTCDDG02000', 'productName': '和平精英娱乐陪玩', 'status': 'canceled'},
    ],
    'total': 3,
    'page': 1,
    'pageSize': 20,
  };

  /// 打手候选（`GET /user/complaints/targets/workers`，服务端只回"接过我单"的打手）：
  /// - `all`：通用投诉（不带 orderId）→ 曾接过我单的打手
  /// - `682`：针对订单 682 投诉（带 orderId=682）→ 只回该单接单人
  /// - `not_mine`：**没接过我单**的打手（109）。服务端永不下发；页面若改回"全部打手"就会命中它
  final myWorkers = <String, dynamic>{
    'all': [
      {'workerId': '106', 'nickname': '演示工作端', 'workerNo': 'W0106', 'lastOrderNo': 'ORDMUTCDDG01232', 'orderCount': 2},
      {'workerId': '107', 'nickname': '北岭', 'workerNo': 'W0107', 'lastOrderNo': 'ORDMUTCDDG01999', 'orderCount': 1},
    ],
    '682': [
      {'workerId': '106', 'nickname': '演示工作端', 'workerNo': 'W0106', 'lastOrderNo': 'ORDMUTCDDG01232', 'orderCount': 2},
    ],
    'not_mine': [
      {'workerId': '109', 'nickname': '没接过我单的人', 'workerNo': 'W0109', 'lastOrderNo': '', 'orderCount': 0},
    ],
  };

  final complaints = {
    'list': [
      {
        'id': '5',
        'complaintNo': 'CMUTCE38S74137661',
        'targetType': 'order',
        'targetId': '682',
        'targetName': 'ORDMUTCDDG01232',
        'type': 'attitude',
        'content': '打手全程不说话，态度很差，还中途挂机了十几分钟。',
        'mediaIds': ['143'],
        'status': 'handled',
        'handleRemark': '已核实：打手中途挂机，扣减服务分并警告',
        'handledAt': '2026-10-04T04:50:12.135Z',
        'createdAt': '2026-10-04T04:50:12.077Z',
      },
      {
        'id': '6',
        'complaintNo': 'CMUTCE3B692117456',
        'targetType': 'service',
        'targetId': '',
        'targetName': '在线客服',
        'type': 'other',
        'content': '客服回复太慢，问了三次才回一句。',
        'mediaIds': [],
        'status': 'rejected',
        'handleRemark': '客服记录显示 3 分钟内已回复，不构成投诉',
        'handledAt': '2026-10-04T04:50:12.173Z',
        'createdAt': '2026-10-04T04:50:12.163Z',
      },
    ],
    'total': 2,
    'page': 1,
    'pageSize': 30,
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
  });

  testWidgets('投诉表单：对象/类型/描述/截图位齐全，对象名来自服务端', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: _api(_fixture(myOrders, myWorkers, complaints)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('投诉'), findsWidgets);
    expect(find.text('投诉对象'), findsOneWidget);
    for (final t in ['订单', '打手', '客服']) {
      expect(find.text(t), findsWidgets);
    }
    expect(find.text('投诉类型'), findsOneWidget);
    for (final t in ['服务态度', '未按约定', '恶意拖延', '其它']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(find.text('问题描述'), findsOneWidget);
    expect(find.text('截图（可选，最多 6 张）'), findsOneWidget);
    expect(find.text('选择订单'), findsOneWidget);
    expect(find.text('提交投诉'), findsWidgets);
  });

  // ==================== 负责人 2026-10-05 任务②：投诉页不显示已取消的单 ====================

  testWidgets('② 订单候选只拉可投诉状态；已取消的单不出现在候选里', (tester) async {
    final adapter = _Adapter(_fixture(myOrders, myWorkers, complaints));
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: _dio(adapter)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 请求口径：`status` 必须是"可投诉状态"的逗号分隔串（服务端按此过滤；canceled 不在其中）
    final ordersReq = adapter.requests.lastWhere((r) => r.path.startsWith('/user/orders'));
    expect(ordersReq.query['status'], complaintableOrderStatusQuery());
    expect(ordersReq.query['status'], isNot(contains('canceled')));

    // 候选集合（用户能点到的就是这些）：682 待确认 / 683 已完成 在列；
    // 684 已取消（fixture 刻意混进来）**一个字都不许出现**
    expect(_orderItemValues(tester), ['682', '683']);
    final labels = _orderItemLabels(tester);
    expect(labels.any((t) => t.contains('ORDMUTCDDG02000')), isFalse);
    expect(labels.any((t) => t.contains('和平精英娱乐陪玩')), isFalse);
    expect(labels.any((t) => t.contains('ORDMUTCDDG01232')), isTrue);
    expect(labels.any((t) => t.contains('ORDMUTCDDG01999')), isTrue);
  });

  testWidgets('② 提交被服务端拒（已取消单不可投诉）：页面显示中文原文', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final raw = _fixture(myOrders, myWorkers, complaints);
    // 服务端权威拒绝：HTTP 400 + code 400 + 中文文案（与后端 ORDER_NOT_COMPLAINTABLE_MESSAGE 逐字一致）
    raw['POST /user/complaints'] = {
      'code': 400,
      'message': '该订单当前状态不可投诉（已取消/待接单/异常处理的订单不能投诉）',
      'data': null,
    };
    final adapter = _Adapter(raw);
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: _dio(adapter)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('客服'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '打手全程挂机，要求处理。');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 服务端拒绝文案原样呈现，且落在**按钮上方的表单汇总条**（不自动消失，随表单一起可见）
    expect(find.textContaining('该订单当前状态不可投诉'), findsWidgets);
    // 被拒后仍停在"提交投诉"表单，不会误切到"我的投诉"
    expect(find.text('投诉对象'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  // ==================== 负责人 2026-10-05 任务③：只能选"接过我单"的打手 ====================

  testWidgets('③ 打手候选只来自「我的关联打手」接口，不含没接过我单的打手', (tester) async {
    final adapter = _Adapter(_fixture(myOrders, myWorkers, complaints));
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: _dio(adapter)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 接口口径：走新的目标任务接口，且**不再**请求"全部在岗打手"（原 /public/players）
    expect(adapter.requests.any((r) => r.path.startsWith('/user/complaints/targets/workers')), isTrue);
    expect(adapter.requests.any((r) => r.path.startsWith('/public/players')), isFalse);

    await tester.tap(find.text('打手'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 未选订单 = 通用投诉 → 全量关联打手，不带 orderId
    final workersReq = adapter.requests.lastWhere((r) => r.path.startsWith('/user/complaints/targets/workers'));
    expect(workersReq.query.containsKey('orderId'), isFalse);

    // 直接断言下拉控件自己的 items（= 用户能点到的集合，比 overlay 断言更硬）
    expect(_workerItemValues(tester), ['106', '107']);
    expect(_workerItemLabels(tester), ['演示工作端 · W0106', '北岭 · W0107']);
    expect(_workerItemLabels(tester).any((t) => t.contains('没接过我单的人')), isFalse);
    expect(_workerItemLabels(tester).any((t) => t.contains('W0109')), isFalse);
  });

  testWidgets('③ 选定订单后打手收敛为该单接单人，选定后能提交成功', (tester) async {
    // 同下：表单比默认 800×600 视口长，提交按钮会被 ListView 回收
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Map<String, dynamic>? posted;
    final raw = _fixture(myOrders, myWorkers, complaints);
    raw['POST /user/complaints'] = {'code': 0, 'message': 'ok', 'data': {'id': '9'}};
    final adapter = _Adapter(raw, onPost: (path, body) {
      if (path.startsWith('/user/complaints')) posted = body;
    });
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: _dio(adapter)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 选订单 682（该单只关联打手 106）—— 走下拉控件自己的 onChanged（真实用户路径）
    _orderDropdown(tester).onChanged!('682');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 收敛请求必须带 orderId（服务端按此只回该单接单人）
    final narrowed = adapter.requests.lastWhere((r) => r.path.startsWith('/user/complaints/targets/workers'));
    expect(narrowed.query['orderId'], '682');

    await tester.tap(find.text('打手'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(_workerItemValues(tester), ['106']);
    expect(_workerItemLabels(tester), ['演示工作端 · W0106']);
    expect(_workerItemLabels(tester).any((t) => t.contains('北岭')), isFalse, reason: '北岭没接过这一单，不可选');

    _workerDropdown(tester).onChanged!('106');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '打手中途挂机 15 分钟，未按约定完成。');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(posted, isNotNull);
    expect(posted!['targetType'], 'worker');
    expect(posted!['targetId'], '106', reason: '提交的是该订单接单打手的 worker.id');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('③ 提交被服务端拒（未接过我单的打手）：页面显示中文原文', (tester) async {
    // 表单比默认 800×600 视口长：给一块足够高的"真机竖屏+滚动后"画布，
    // 免得提交按钮被 ListView 回收（`ensureVisible` 找不到元素 → Bad state: No element）
    await tester.binding.setSurfaceSize(const Size(390, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final raw = _fixture(myOrders, myWorkers, complaints);
    raw['POST /user/complaints'] = {
      'code': 400,
      'message': '该打手没有接过你的订单，无法投诉',
      'data': null,
    };
    final adapter = _Adapter(raw);
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: _dio(adapter)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('打手'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // 用户在下拉里选了一位关联打手（列表本身只含关联打手），服务端仍按权威判定拒绝
    _workerDropdown(tester).onChanged!('106');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '这个人服务态度很差，我要投诉。');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('该打手没有接过你的订单'), findsWidgets);
    await tester.pump(const Duration(seconds: 3));  });

  testWidgets('提交投诉（客服对象）：请求体带 targetType/type/content/mediaIds', (tester) async {
    Map<String, dynamic>? posted;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(myOrders, myWorkers, complaints), onPost: (path, body) {
      if (path.contains('/user/complaints')) posted = body;
    });
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('客服'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恶意拖延'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '客服回复太慢，问了三次才回一句。');
    await tester.pumpAndSettle();

    // 提交按钮在表单底部，测试视口(800x600)需先滚动到可见
    await tester.ensureVisible(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3)); // 冲掉成功提示的定时器

    expect(posted, isNotNull);
    expect(posted!['targetType'], 'service');
    expect(posted!['type'], 'delay');
    expect(posted!['content'], '客服回复太慢，问了三次才回一句。');
    expect(posted!['mediaIds'], isEmpty);
    expect(posted!.containsKey('userId'), isFalse, reason: '投诉人只能由服务端从 JWT 取');
  });

  testWidgets('描述过短：拦下不发请求', (tester) async {
    var posted = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(myOrders, myWorkers, complaints), onPost: (path, body) {
      if (path.contains('/user/complaints')) posted = true;
    });
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('客服'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '差');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, '提交投诉'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));

    expect(posted, isFalse);
  });

  testWidgets('我的投诉：显示状态与处理结果', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: _api(_fixture(myOrders, myWorkers, complaints)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('我的投诉'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('投诉订单 · 服务态度'), findsOneWidget);
    expect(find.text('投诉客服 · 其它'), findsOneWidget);
    expect(find.text('已处理'), findsOneWidget);
    expect(find.text('未通过'), findsOneWidget);
    expect(find.textContaining('处理结果：已核实：打手中途挂机'), findsOneWidget);
  });
}

/// 页面上「投诉对象 = 订单」时那个下拉控件
DropdownButton<String> _orderDropdown(WidgetTester tester) =>
    tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>).first);

/// 页面上打手下拉控件（投诉对象 = 打手时才存在）
DropdownButton<String> _workerDropdown(WidgetTester tester) =>
    tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>).first);

/// 下拉候选的 value 列表（= 可提交的 targetId 集合）
List<String> _orderItemValues(WidgetTester tester) => _orderDropdown(tester).items!.map((i) => i.value!).toList();

List<String> _workerItemValues(WidgetTester tester) => _workerDropdown(tester).items!.map((i) => i.value!).toList();

/// 下拉候选项的可见文本（= 用户看到的名字）
List<String> _orderItemLabels(WidgetTester tester) =>
    _orderDropdown(tester).items!.map((i) => ((i.child as Text).data) ?? '').toList();

List<String> _workerItemLabels(WidgetTester tester) =>
    _workerDropdown(tester).items!.map((i) => ((i.child as Text).data) ?? '').toList();

Dio _dio(_Adapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Map<String, dynamic> _fixture(
  Map<String, dynamic> orders,
  Map<String, dynamic> workers,
  Map<String, dynamic> complaints,
) {
  final workersForOrder = ((workers['682'] as List?) ?? const []);
  final workersAll = ((workers['all'] as List?) ?? const []);
  return {
    '/user/orders': {'code': 0, 'message': 'ok', 'data': orders},
    // 目标任务接口按请求是否带 orderId 分流（模拟服务端 workerTargets(userId, orderId)）
    'WORKERS': {'all': workersAll, 'order': workersForOrder},
    '/user/complaints': {'code': 0, 'message': 'ok', 'data': complaints},
  };
}

ApiClient _api(Map<String, dynamic> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

/// 一次请求的记录（路径 + 查询参数，用于校验页面发出去的口径）
class _Req {
  _Req(this.path, this.query);

  final String path;
  final Map<String, dynamic> query;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, {this.onPost});

  final Map<String, dynamic> raw;
  final void Function(String path, Map<String, dynamic> body)? onPost;
  final List<_Req> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(_Req(options.path, Map<String, dynamic>.from(options.queryParameters)));
    // POST 走独立的 'POST <path>' 键（同一路径 GET/POST 语义不同，如 /user/complaints）
    if (options.method == 'POST') {
      onPost?.call(options.path, (options.data as Map?)?.cast<String, dynamic>() ?? const {});
      final key = 'POST ${options.path}';
      if (raw.containsKey(key)) return _body(raw[key]);
    }
    // 目标任务接口必须先判定：它也以 /user/complaints 为前缀，走下面的前缀匹配会命中"我的投诉"数据
    if (options.path.startsWith('/user/complaints/targets/workers')) {
      final byOrder = raw['WORKERS'] as Map<String, dynamic>;
      final wantOrder = '${options.queryParameters['orderId'] ?? ''}';
      final list = wantOrder.isEmpty ? byOrder['all'] : byOrder['order'];
      return _body({'code': 0, 'message': 'ok', 'data': list});
    }
    final keys = raw.keys
        .where((k) => !k.startsWith('POST ') && k != 'WORKERS' && options.path.startsWith(k))
        .toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (keys.isEmpty) return _body({'code': 404, 'message': 'Not Found', 'data': null});
    final body = raw[keys.first];
    // 模拟服务端 `?status=a,b,c` 多状态过滤（`OrderService.userOrders`）：
    // 投诉页传"可投诉状态"→ canceled 的单不会下发。**必须真的过滤**，否则 fixture 比线上宽松，
    // "已取消的单不显示"这条用例就测不到东西。
    final status = '${options.queryParameters['status'] ?? ''}';
    if (status.isNotEmpty && body is Map && body['data'] is Map && (body['data'] as Map)['list'] is List) {
      final want = status.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      final data = Map<String, dynamic>.from(body['data'] as Map);
      final list = (data['list'] as List).where((e) => e is Map && want.contains('${e['status']}')).toList();
      return _body({'code': 0, 'message': 'ok', 'data': {...data, 'list': list, 'total': list.length}});
    }
    return _body(body);
  }

  /// 回响应体：**HTTP 状态码按 body.code 还原**（服务端 AllExceptionsFilter 就是这么回的）。
  ///
  /// ⚠️ 这是本 fixture 唯一的坑：若一律回 200，Dio 不会抛错 → 页面把 `{code:400}` 当成功
  /// （弹"提交成功"并切到"我的投诉"），400 类用例会假绿。
  ResponseBody _body(Object? data) {
    final code = (data is Map && data['code'] is int) ? data['code'] as int : 0;
    final httpStatus = code >= 400 ? code : 200;
    return ResponseBody.fromString(
      jsonEncode(data),
      httpStatus,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
