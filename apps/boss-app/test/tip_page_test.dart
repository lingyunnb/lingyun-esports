import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/tip_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打赏页（负责人 2026-10-04 顶部导航「打赏」）
///
/// 口径 2026-10-09：计价单位 = 余额（1 元 = 1 元），预设档位按 ÷10 折算为**元且带小数**
///（服务端 `tip_presets` 实测 0.6 / 1.8 / 3.8 / 8.8）——
/// 页面必须能接住小数（用 int 接会把 0.6 截成 0，档位显示 ¥0.00 且提交必被服务端拒）。
///
/// 覆盖：
/// 1) 可打赏订单列表：订单号/商品/打手昵称/已打赏累计 + 服务端下发的上限
/// 2) 打赏弹层：预设金额来自服务端配置（**含小数**）+ 自定义；提交携带 idempotencyKey
/// 3) 客户端预校验：超过本单剩余可打赏额度时不发请求（服务端仍是最终判定）
/// 4) 我的打赏记录
void main() {
  final orders = {
    'list': [
      {
        'orderId': '682',
        'orderNo': 'ORDMUTCDDG01232',
        'status': 'pending_confirm',
        'totalAmount': 10,
        'productName': '传奇段位上分陪练',
        'workerNickname': '演示工作端',
        'tippedAmount': 3.8,
        'remainingAmount': 96.2,
        'createdAt': '2026-10-04T04:49:38.641Z',
      },
      {
        'orderId': '690',
        'orderNo': 'ORDMUTCE30F8664',
        'status': 'completed',
        'totalAmount': 10,
        'productName': '护航保底',
        'workerNickname': '祁连山·夜班',
        'tippedAmount': 0,
        'remainingAmount': 2.0, // 只够打赏 0.6/1.8（用于预校验用例）
        'createdAt': '2026-10-04T04:49:41.000Z',
      },
    ],
    'total': 2,
    'page': 1,
    'pageSize': 30,
    'config': {
      // 服务端 ÷10 后的真实档位（元、带小数）
      'presets': [0.6, 1.8, 3.8, 8.8],
      'maxPerTip': 50,
      'maxPerOrder': 100,
    },
  };

  final myTips = {
    'list': [
      {'id': '1', 'orderId': '682', 'orderNo': 'ORDMUTCDDG01232', 'amount': 3.8, 'toNickname': '演示工作端', 'remark': '', 'createdAt': '2026-10-04T04:49:39.968Z'},
    ],
    'total': 1,
    'page': 1,
    'pageSize': 30,
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
  });

  testWidgets('可打赏订单：渲染订单号/打手/已打赏累计与剩余额度', (tester) async {
    await tester.pumpWidget(MaterialApp(home: TipPage(api: _api(_fixture(orders, myTips)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('打赏'), findsWidgets);
    expect(find.text('金额 100% 给打手，平台不抽成'), findsOneWidget);
    expect(find.text('传奇段位上分陪练'), findsOneWidget);
    expect(find.textContaining('已打赏 ¥3.80 · 还可打赏 ¥96.20'), findsOneWidget);
    expect(find.textContaining('本单还没打赏过'), findsOneWidget);
    expect(find.text('待确认'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('打赏'), findsWidgets);
  });

  testWidgets('打赏弹层：预设来自服务端配置，提交携带 amount 与 idempotencyKey', (tester) async {
    Map<String, dynamic>? posted;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(orders, myTips), onPost: (path, body) {
      if (path.contains('/user/tips')) posted = body;
    });
    await tester.pumpWidget(MaterialApp(home: TipPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(AppButton, '打赏').first);
    await tester.pumpAndSettle();

    // 预设 ¥0.60/¥1.80/¥3.80/¥8.80 + 自定义（全部来自服务端 config；**小数档位不得被截断**）
    expect(find.text('打赏打手'), findsOneWidget);
    for (final v in ['¥0.60', '¥1.80', '¥3.80', '¥8.80']) {
      expect(find.text(v), findsWidgets);
    }
    expect(find.text('¥0.00'), findsNothing, reason: '0.6 被 toInt 截成 0 的回归点');
    expect(find.text('自定义'), findsOneWidget);
    expect(find.textContaining('本单还可打赏 ¥96.20'), findsOneWidget);

    await tester.tap(find.text('¥8.80').last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('确认打赏'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // 提示浮层 2s 后自动消失，推进时间避免遗留定时器
    await tester.pump(const Duration(seconds: 3));

    expect(posted, isNotNull, reason: '应发起打赏请求');
    expect(posted!['orderId'], '682');
    expect(posted!['amount'], 8.8, reason: '小数余额金额必须原样提交（不得取整/截断）');
    expect((posted!['idempotencyKey'] as String).length >= 8, isTrue, reason: '客户端必须带幂等键');
  });

  testWidgets('打赏弹层：自定义**小数**金额（8.8）可提交，且超过两位小数被本地拦下', (tester) async {
    Map<String, dynamic>? posted;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(orders, myTips), onPost: (path, body) {
      if (path.contains('/user/tips')) posted = body;
    });
    await tester.pumpWidget(MaterialApp(home: TipPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.widgetWithText(AppButton, '打赏').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    // 浮点回归：8.8 * 100 == 880.0000000000001，用等值比较判两位小数会误杀 8.8
    await tester.enterText(find.byType(TextField), '8.8');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('确认打赏'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));

    expect(posted, isNotNull, reason: '8.8 是合法金额（服务端预设档位本身就有 8.8）');
    expect(posted!['amount'], 8.8);

    // 三位小数：本地红字拦下，不发请求
    posted = null;
    await tester.tap(find.widgetWithText(AppButton, '打赏').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1.234');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('确认打赏'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('打赏金额最多保留 2 位小数'), findsOneWidget);
    expect(posted, isNull, reason: '非法金额不得发请求');
  });

  testWidgets('客户端预校验：超过本单剩余额度不发请求（服务端仍是最终判定）', (tester) async {
    var posted = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(_fixture(orders, myTips), onPost: (path, body) {
      if (path.contains('/user/tips')) posted = true;
    });
    await tester.pumpWidget(MaterialApp(home: TipPage(api: ApiClient(dio: dio))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 第 2 单剩余仅 ¥2.00（只够 0.6 / 1.8）
    await tester.tap(find.widgetWithText(AppButton, '打赏').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('¥8.80').last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('确认打赏'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 3));

    expect(posted, isFalse, reason: '超剩余额度不得发起请求');
  });

  testWidgets('我的打赏：记录列表显示收款打手与金额', (tester) async {
    await tester.pumpWidget(MaterialApp(home: TipPage(api: _api(_fixture(orders, myTips)))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('我的打赏'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('打赏给 演示工作端'), findsOneWidget);
    expect(find.text('-¥3.80'), findsOneWidget);
    expect(find.textContaining('ORDMUTCDDG01232'), findsOneWidget);
  });

  testWidgets('接口失败：给出重试入口而不是白屏', (tester) async {
    await tester.pumpWidget(MaterialApp(home: TipPage(api: _api(const {}))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}

Map<String, Map<String, dynamic>> _fixture(Map<String, dynamic> orders, Map<String, dynamic> tips) => {
      '/user/tips/orders': {'code': 0, 'message': 'ok', 'data': orders},
      '/user/tips': {'code': 0, 'message': 'ok', 'data': tips},
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
