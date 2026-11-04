import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/wallet_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 余额口径（负责人 2026-10-09）：**计价单位由「积分」改为「余额」，1 元 = 1 元**
///
/// 本文件钉住四件事（替换原 `points_yuan_price_test.dart` 的「≈ N 元 二次换算」那套断言）：
/// ② 钱包页标题是「余额」，且整屏**不含"积分"**；
/// ③ 商品卡价格走 `fmtMoney`（`¥8.80`：¥ + 两位小数 + 千分位）；
/// ④ 下单页余额不足时给出**正确差额**（余额 ¥8.80 / 合计 ¥10.00 → 还差 ¥1.20）；
/// ⑤ **全局负向**：金额语境页面/源码里不再出现「积分」（含 `find.textContaining('积分')` 断言）。
///
/// ①（格式化函数本体：0 / 0.5 / 8.8 / 1234.5 / 99999.9）在 core 的 `money_format_test.dart`。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'balance-test-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
  });

  // =====================================================================================
  // ② 钱包页 = 余额
  // =====================================================================================
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
        {'amount': 99999.9, 'changeType': 'grant', 'reason': '平台发放', 'balanceAfter': 103616.45, 'createdAt': '2026-09-23T16:00:00.000Z'},
      ],
      'total': 3,
      'page': 1,
      'pageSize': 20,
    },
  };

  testWidgets('② 钱包页标题为「余额」，且整屏不含「积分」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WalletPage(api: _api({'/user/wallet': wallet, '/user/wallet/transactions': txns})),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('我的余额'), findsOneWidget);
    expect(find.text('当前余额'), findsOneWidget);
    expect(find.text('余额流水'), findsOneWidget);
    // 合规说明必须保留（仅平台内消费、不可提现、不可转让）
    expect(find.textContaining('不可提现'), findsOneWidget);
    expect(find.textContaining('不可转让'), findsOneWidget);
    expect(find.textContaining('积分'), findsNothing, reason: '钱包页不得再出现旧单位字样');
  });

  testWidgets('②b 钱包页金额一律 ¥ + 两位小数 + 千分位；负数（扣款）负号在 ¥ 前', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WalletPage(api: _api({'/user/wallet': wallet, '/user/wallet/transactions': txns})),
    ));
    await tester.pumpAndSettle();

    expect(find.text('¥3,616.55'), findsOneWidget); // 余额主卡（千分位 + 两位小数）
    expect(find.text('-¥16.50'), findsOneWidget); // 扣款
    expect(find.text('+¥11.55'), findsOneWidget); // 入账
    expect(find.text('+¥99,999.90'), findsOneWidget); // 大额：千分位
    expect(find.text('余额 ¥85,383.50'), findsOneWidget); // 流水后余额快照
  });

  // =====================================================================================
  // ③ 商品卡：¥ + 两位小数（金额格式只有一份实现 → 源码级绑定 + 组件渲染两层断言）
  // =====================================================================================
  test('③ 商品卡/详情/订单/榜单/充值：金额一律经 fmtMoney（源码级绑定，防有人改回裸数字）', () {
    final root = resolveRepoRoot();
    String src(String rel) => File('$root/apps/boss-app/$rel').readAsStringSync();
    const cases = <({String where, String file, List<String> mustContain, List<String> mustNotContain})>[
      (
        where: '商品列表卡价格行',
        file: 'lib/pages/product_list_page.dart',
        mustContain: ['AppPrice(value: fmtMoney(p.price)', 'fmtMoney('],
        mustNotContain: ['AppPriceYuan', 'fmtPoints(p.price)'],
      ),
      (
        where: '商品详情页价格区',
        file: 'lib/pages/product_detail_page.dart',
        mustContain: ["fmtMoney(parsePoints(p['price']))"],
        mustNotContain: ['AppPriceYuan', '≈ '],
      ),
      (
        where: '确认订单页吸底合计',
        file: 'lib/pages/order_create_page.dart',
        mustContain: ['AppPrice(value: fmtMoney(_total)', '余额不足，还差 '],
        mustNotContain: ['AppPriceYuan'],
      ),
      (
        where: '订单列表/详情',
        file: 'lib/pages/orders_page.dart',
        mustContain: ['AppPrice(value: fmtMoney(o.totalAmount)', "fmtMoney(parsePoints(d['totalAmount']))"],
        mustNotContain: ["unit: '积分'", '积分'],
      ),
      (
        where: '排行榜数值（金额）',
        file: 'lib/pages/leaderboard_page.dart',
        mustContain: ['amount: fmtMoney(amt)', '接单金额（¥）'],
        mustNotContain: ['积分'],
      ),
      (
        where: '充值页选项与到账预览',
        file: 'lib/pages/recharge_page.dart',
        mustContain: ['RechargeRules.formatYuan(v)', 'RechargeCopy.previewLine(amount)'],
        mustNotContain: ['AppPriceYuan', 'PointsYuan', '积分'],
      ),
    ];
    for (final c in cases) {
      final text = src(c.file);
      for (final needle in c.mustContain) {
        expect(text.contains(needle), isTrue, reason: '${c.where}（${c.file}）缺少：$needle');
      }
      for (final banned in c.mustNotContain) {
        // 允许出现在注释里（注释会被下面的规范化剥掉）
        final code = _stripComments(text);
        expect(code.contains(banned), isFalse, reason: '${c.where}（${c.file}）不得再出现：$banned');
      }
    }
  });

  testWidgets('③b AppPrice 渲染整串 ¥8.80（¥ 与数字同一串，便于整串命中）', (tester) async {
    // size 15 < 大字门槛 19 → 走"小字金"（2026-10-16 两档金：<19px 一律 goldText）
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: AppPrice(value: fmtMoney(8.8), size: 15, color: AppColors.gold))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('¥8.80'), findsOneWidget);
    final t = tester.widget<Text>(find.text('¥8.80'));
    expect(t.style?.fontSize, 15);
    expect(t.style?.color, AppColors.goldText,
        reason: '显式传 gold 也会被 AppPrice 按字号降档 → 上屏必须是小字金');
  });

  // =====================================================================================
  // ④ 下单页：合计 ¥ + 余额不足差额
  // =====================================================================================
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  Map<String, Map<String, dynamic>> orderFixture({required num price, required num balance}) => {
        '/divisions': envelope(const [
          {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'platformLabel': '手游', 'iconMediaId': null},
        ]),
        '/public/order-form': envelope(const {
          'zoneLabel': '选择区服',
          'zoneOptions': [
            {'label': '微信', 'value': 'wechat'},
          ],
          'fields': [
            {'key': 'gamePlayerId', 'label': '游戏ID', 'placeholder': '请输入游戏ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 64},
          ],
          'totalLabel': '合计',
          'submitText': '提交订单',
        }),
        '/user/orders/weekly-quota': envelope(const {'limitText': '', 'quotaText': ''}),
        '/user/wallet': envelope({'balance': balance}),
      };

  testWidgets('④ 下单页：合计 ¥10.00，余额 ¥8.80 → 「余额不足，还差 ¥1.20」', (tester) async {
    final product = {'id': '101', 'name': '传奇段位上分陪练', 'price': 10, 'priceUnit': '局', 'divisionId': '1'};
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(orderFixture(price: 10, balance: 8.8)), divisionId: '1', product: product),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.text('¥10.00'), findsWidgets, reason: '合计与单价都走 fmtMoney');
    expect(find.text('余额不足，还差 ¥1.20'), findsOneWidget);
    expect(find.textContaining('积分'), findsNothing, reason: '金额语境页面不得出现旧单位');
    // 只是提示：按钮仍可点（客户端数据不可信，扣款裁决在服务端）
    expect(find.text('提交订单'), findsOneWidget);
  });

  testWidgets('④b 下单页：余额充足时不报差额，只显示余额（¥ 两位小数）', (tester) async {
    final product = {'id': '101', 'name': '传奇段位上分陪练', 'price': 10, 'priceUnit': '局', 'divisionId': '1'};
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(orderFixture(price: 10, balance: 1234.5)), divisionId: '1', product: product),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('余额 ¥1,234.50'), findsOneWidget);
    expect(find.textContaining('余额不足'), findsNothing);
    expect(find.textContaining('积分'), findsNothing);
  });

  testWidgets('④c 下单页：余额接口缺 balance 字段时**不猜**（不显示 ¥0.00 / 不误报不足）', (tester) async {
    final product = {'id': '101', 'name': '传奇段位上分陪练', 'price': 10, 'priceUnit': '局', 'divisionId': '1'};
    final fx = orderFixture(price: 10, balance: 0);
    fx['/user/wallet'] = envelope(const {'noBalanceField': true});
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(fx), divisionId: '1', product: product),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('余额'), findsNothing, reason: '拿不到余额就什么都不说');
    expect(find.textContaining('余额不足'), findsNothing);
  });

  // =====================================================================================
  // ⑤ 全局负向：源码级「积分」清扫（只放行两处判定词表）
  // =====================================================================================
  test('⑤ 全局负向：老板端 lib + core/src 的用户可见代码里不再有「积分」字样', () {
    // 放行清单（**只有两处，且都不是用户可见文案**）：
    // ① 打手态"老板端专属词"黑名单（判定词表：确认打手态不出现老板端元素）
    // ② 充值合规禁用词表（判定词表：确认充值链路不出现旧单位）
    const allowed = <String>[
      "'积分卡'",
      "'我的积分卡'",
      "'积分商城'",
      "'积分',",
    ];
    final root = resolveRepoRoot();
    final roots = [
      Directory('$root/apps/boss-app/lib'),
      Directory('$root/apps/packages/core/lib/src'),
    ];
    final violations = <String>[];
    for (final root in roots) {
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final code = _stripComments(f.readAsStringSync());
        for (final line in code.split('\n')) {
          if (!line.contains('积分')) continue;
          if (allowed.any(line.contains)) continue;
          violations.add('${f.path}: ${line.trim()}');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '金额/文案里不得再出现旧单位「积分」（命中 ${violations.length} 处）：\n${violations.join('\n')}',
    );
  });
}

/// 剥掉行注释（`//`；不含 `://`）—— 注释里允许保留历史沿革说明
String _stripComments(String src) {
  final out = <String>[];
  for (final raw in src.split('\n')) {
    final m = RegExp(r'(^|\s)//').firstMatch(raw);
    if (m == null) {
      out.add(raw);
    } else {
      final cut = raw[m.start] == '/' ? m.start : m.start + 1;
      out.add(raw.substring(0, cut));
    }
  }
  return out.join('\n');
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
