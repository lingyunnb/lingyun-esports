import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/worker_wallet_page.dart';

/// 工作端「我的积分」· 打赏收益（负责人 2026-10-04）
///
/// 覆盖：
/// 1) 打赏收益/笔数独立成格（老板打赏 100% 到手，与 70% 订单结算分开显示）
/// 2) 流水类型中文标签区分「老板打赏」与「订单结算」（type = order_tip_income）
void main() {
  final wallet = {
    'code': 0,
    'message': 'ok',
    'data': {
      'balance': 308,
      'totalIncome': 200,
      'totalGranted': 70,
      'totalSpent': 0,
      'settlementCount': 2,
      'tipIncome': 38,
      'tipCount': 1,
    },
  };

  final txns = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {'amount': 38, 'changeType': 'order_tip_income', 'reason': '收到老板打赏（订单 ORDMUTCDDG01232）', 'balanceAfter': 308, 'createdAt': '2026-10-04T04:49:39.968Z'},
        {'amount': 70, 'changeType': 'order_settlement', 'reason': '订单完成结算 70%', 'balanceAfter': 270, 'createdAt': '2026-10-04T04:20:00.000Z'},
      ],
      'total': 2,
      'page': 1,
      'pageSize': 20,
    },
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true; // 测试不建真实 WS
  });

  testWidgets('我的积分：打赏收益与笔数可见，流水区分「老板打赏」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WorkerWalletPage(api: _api({'/worker/my-wallet': wallet, '/worker/wallet/transactions': txns})),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.text('打赏收益'), findsOneWidget);
    expect(find.text('38'), findsWidgets);
    expect(find.text('打赏笔数'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    // 流水类型标签：打赏与订单结算分开（「订单结算」同时是上方统计格的标签，故为 2 处）
    expect(find.text('老板打赏'), findsOneWidget);
    expect(find.text('订单结算'), findsNWidgets(2));
    expect(find.textContaining('收到老板打赏'), findsOneWidget);
    expect(find.text('+38'), findsOneWidget);
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
