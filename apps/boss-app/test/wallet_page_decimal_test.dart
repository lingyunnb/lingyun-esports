import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/wallet_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 我的余额（钱包页）· 小数金额回归（口径 2026-10-09：余额，1 元 = 1 元，金额一律 ¥ 两位小数）
///
/// 修复前：流水 `json['amount'] as int?` 遇到 -16.50 / +11.55 这类小数流水 → TypeError → 整页崩溃。
/// 夹具取自生产库真实流水（订单 396：用户消费 -16.50、打手结算 +11.55、平台抽成 4.95）。
void main() {
  final wallet = {
    'code': 0,
    'message': 'ok',
    'data': {'balance': 3616.55},
  };
  final txns = {
    'code': 0,
    'message': 'ok',
    'data': {
      'list': [
        {'amount': -16.5, 'changeType': 'order_pay', 'reason': '下单消费', 'balanceAfter': 85383.5, 'createdAt': '2026-09-23T15:12:54.000Z'},
        {'amount': 11.55, 'changeType': 'order_settlement', 'reason': '订单结算', 'balanceAfter': 3616.55, 'createdAt': '2026-09-23T15:30:00.000Z'},
        {'amount': 4.95, 'changeType': 'platform_commission', 'reason': '平台抽成', 'balanceAfter': 874.95, 'createdAt': '2026-09-23T15:30:00.000Z'},
        {'amount': 100, 'changeType': 'grant', 'reason': '管理员发放', 'balanceAfter': 974.95, 'createdAt': '2026-09-23T16:00:00.000Z'},
      ],
      'total': 4,
      'page': 1,
      'pageSize': 20,
    },
  };

  testWidgets('小数流水与余额正常渲染（不再崩溃）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WalletPage(api: _api({'/user/wallet': wallet, '/user/wallet/transactions': txns})),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('¥3,616.55'), findsOneWidget); // 余额：千分位 + 固定两位小数
    expect(find.text('-¥16.50'), findsOneWidget); // 消费小数（两位）
    expect(find.text('+¥11.55'), findsOneWidget); // 结算收益小数（按接口下发比例分账）
    expect(find.text('+¥4.95'), findsOneWidget); // 平台抽成小数
    expect(find.text('+¥100.00'), findsOneWidget); // 整数金额也补两位小数
    expect(find.text('余额 ¥85,383.50'), findsOneWidget); // 流水后余额快照（小数 + 千分位）
  });
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _RawAdapter(raw);
  return ApiClient(dio: dio);
}

class _RawAdapter implements HttpClientAdapter {
  _RawAdapter(this.raw);

  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    // 取最长匹配前缀（/user/wallet/transactions 优先于 /user/wallet）
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    final body = key.isEmpty ? jsonEncode({'code': 404, 'message': 'no fixture', 'data': null}) : jsonEncode(raw[key]);
    return ResponseBody.fromString(body, key.isEmpty ? 404 : 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
