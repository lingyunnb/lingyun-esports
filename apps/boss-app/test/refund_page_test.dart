import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/refund_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 退款页（负责人 2026-10-04 顶部导航「退款」）
///
/// 覆盖：
/// 1) 可申请退款订单列表（未开始/进行中/待确认；已完成不在内 → 走申诉）
/// 2) 申请弹层：原因必选 + 说明可选，提交携带 orderId/reason/idempotencyKey（金额不可传）
/// 3) 未选原因时不发请求
/// 4) 我的申请：状态与处理意见展示
void main() {
  final orders = {
    'list': [
      {
        'orderId': '684',
        'orderNo': 'ORDMUTCDFCC9826',
        'status': 'pending_confirm',
        'totalAmount': 100,
        'productName': '传奇段位上分陪练',
        'createdAt': '2026-10-04T04:49:41.000Z',
      },
      {
        'orderId': '691',
        'orderNo': 'ORDMUTCE54B1201',
        'status': 'taken',
        'totalAmount': 88.5,
        'productName': '护航保底',
        'createdAt': '2026-10-04T04:51:02.000Z',
      },
    ],
    'total': 2,
    'page': 1,
    'pageSize': 30,
  };

  final requests = {
    'list': [
      {
        'id': '2',
        'requestNo': 'RMUTCDFJB8093BB1D',
        'orderId': '685',
        'orderNo': 'ORDMUTCDFH93276',
        'amount': 100,
        'prevStatus': 'pending_confirm',
        'reason': '不想要了',
        'remark': '',
        'status': 'rejected',
        'handlerRemark': '服务已正常进行，不予退款',
        'handledAt': '2026-10-04T04:49:41.369Z',
        'createdAt': '2026-10-04T04:49:41.352Z',
      },
      {
        'id': '1',
        'requestNo': 'RMUTCDFEK890607C0',
        'orderId': '684',
        'orderNo': 'ORDMUTCDFCC9826',
        'amount': 100,
        'prevStatus': 'pending_confirm',
        'reason': '打手未开始服务',
        'remark': '等了 40 分钟',
        'status': 'pending',
        'handlerRemark': '',
        'handledAt': null,
        'createdAt': '2026-10-04T04:49:41.182Z',
      },
    ],
    'total': 2,
    'page': 1,
    'pageSize': 30,
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
  });

  testWidgets('可申请退款订单：渲染订单号/金额/状态（含小数金额）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: RefundPage(api: _api(_fixture(orders, requests)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('退款'), findsWidgets);
    expect(find.text('客服会尽快审核'), findsOneWidget,
        reason: '2026-10-08：去掉写死的「客服 9:00-次日 2:00 在线审核」（客服改为主动接单，无可承诺时段）');
    expect(find.text('传奇段位上分陪练'), findsOneWidget);
    expect(find.text('护航保底'), findsOneWidget);
    expect(find.text('¥88.50'), findsOneWidget, reason: '小数金额不得崩溃（¥ + 两位小数）');
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('已接单'), findsOneWidget);
    expect(find.widgetWithText(AppButton, '申请退款'), findsNWidgets(2));
  });

  testWidgets('申请弹层：选原因 + 填说明 → 提交携带 orderId/reason/idempotencyKey（不传金额）', (tester) async {
    Map<String, dynamic>? posted;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(orders, requests), onPost: (path, body) {
      if (path.contains('/user/refunds')) posted = body;
    });
    await tester.pumpWidget(MaterialApp(home: RefundPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(AppButton, '申请退款').first);
    await tester.pumpAndSettle();

    expect(find.text('申请退款'), findsWidgets);
    expect(find.textContaining('可退 ¥100.00（原路退回）'), findsOneWidget);
    expect(find.text('打手未开始服务'), findsOneWidget);

    await tester.tap(find.text('时间对不上，无法继续'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '约的时间是 21 点，打手一直没上线');
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交退款申请'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3)); // 冲掉成功提示的定时器

    expect(posted, isNotNull, reason: '应发起退款申请');
    expect(posted!['orderId'], '684');
    expect(posted!['reason'], '时间对不上，无法继续');
    expect(posted!.containsKey('amount'), isFalse, reason: '退款金额由服务端按订单快照计算，客户端不得传');
    expect((posted!['idempotencyKey'] as String).length >= 8, isTrue);
  });

  testWidgets('未选退款原因：拦下不发请求', (tester) async {
    var posted = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(orders, requests), onPost: (path, body) {
      if (path.contains('/user/refunds')) posted = true;
    });
    await tester.pumpWidget(MaterialApp(home: RefundPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(AppButton, '申请退款').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交退款申请'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));

    expect(posted, isFalse);
  });

  testWidgets('我的申请：显示待处理/已驳回状态与处理意见', (tester) async {
    await tester.pumpWidget(MaterialApp(home: RefundPage(api: _api(_fixture(orders, requests)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('我的申请'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('已驳回'), findsOneWidget);
    expect(find.textContaining('处理意见：服务已正常进行，不予退款'), findsOneWidget);
    expect(find.textContaining('原因：打手未开始服务（等了 40 分钟）'), findsOneWidget);
  });
}

Map<String, Map<String, dynamic>> _fixture(Map<String, dynamic> orders, Map<String, dynamic> requests) => {
      '/user/refunds/orders': {'code': 0, 'message': 'ok', 'data': orders},
      '/user/refunds': {'code': 0, 'message': 'ok', 'data': requests},
    };

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, {this.onPost});

  final Map<String, Map<String, dynamic>> raw;
  final void Function(String path, Map<String, dynamic> body)? onPost;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') {
      onPost?.call(options.path, (options.data as Map?)?.cast<String, dynamic>() ?? const {});
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
