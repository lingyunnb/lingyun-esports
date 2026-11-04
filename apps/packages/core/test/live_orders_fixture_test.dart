import 'dart:convert';
import 'dart:io';

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用**生产库真实响应**（夹具由 scripts/tmp/dump-live-payloads.mjs 生成）跑一遍双端订单解析路径。
///
/// 这是 2026-09-23 小数金额崩溃的回归验证：夹具里含 5.5 积分订单（钻皮·刀），
/// 修复前 `OrderBrief` 的前身（`json['totalAmount'] as int?`）会在这里抛 TypeError。
/// 夹具过期后重新执行 dump 脚本即可刷新。
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  final file = File('test/fixtures/live_orders.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  final lists = <String, List<dynamic>>{
    '老板端 /user/orders': data['userOrders'] as List<dynamic>,
    '工作端 /worker/orders': data['workerOrders'] as List<dynamic>,
    '工作端 /worker/order-hall': data['orderHall'] as List<dynamic>,
  };

  test('夹具确实含小数订单（用例有效性前提）', () {
    final all = lists.values.expand((l) => l).cast<Map<String, dynamic>>();
    final decimals = all.where((o) => parsePoints(o['totalAmount']) != parsePoints(o['totalAmount']).roundToDouble());
    expect(decimals, isNotEmpty, reason: '夹具里没有小数订单，请重新运行 dump 脚本');
    expect(decimals.any((o) => parsePoints(o['totalAmount']) == 5.5), isTrue, reason: '缺少 5.5 积分订单');
  });

  for (final entry in lists.entries) {
    test('${entry.key}：${entry.value.length} 条真实订单全部解析成功且金额展示规范', () {
      for (final raw in entry.value.cast<Map<String, dynamic>>()) {
        final o = OrderBrief.fromJson(raw); // 与 App 页面完全相同的解析路径
        final text = o.amountText;
        final value = parsePoints(raw['totalAmount']);
        expect(o.id.isNotEmpty, isTrue);
        expect(o.orderNo.isNotEmpty, isTrue);
        expect(o.totalAmount, value);
        // 展示规范：整数金额不带小数点；小数金额最多两位
        if (value == value.roundToDouble()) {
          expect(text.contains('.'), isFalse, reason: '整数金额不该带小数点: $text（订单 ${o.orderNo}）');
        } else {
          final decimals = text.contains('.') ? text.split('.')[1].length : 0;
          expect(decimals, lessThanOrEqualTo(2), reason: '小数位超过 2 位: $text（订单 ${o.orderNo}）');
        }
      }
    });
  }

  test('打手收益（my-stats 与 my-wallet）金额解析与展示', () {
    final stats = data['workerStats'] as Map<String, dynamic>?;
    if (stats != null && stats['totalAmount'] != null) {
      expect(fmtPoints(parsePoints(stats['totalAmount'])), isNot(contains('.0')));
    }
    final wallet = data['workerWallet'] as Map<String, dynamic>;
    expect(parsePoints(wallet['balance']), 3616.55);
    expect(parsePoints(wallet['totalIncome']), 3616.55);
    expect(fmtPoints(parsePoints(wallet['balance'])), '3616.55');
    expect(parsePoints(wallet['settlementCount']), isA<double>());
  });

  test('榜单有效金额展示（小数安全）', () {
    final board = data['leaderboard'] as Map<String, dynamic>?;
    for (final row in ((board?['list'] ?? []) as List<dynamic>).cast<Map<String, dynamic>>()) {
      expect(fmtPoints(parsePoints(row['effectiveAmount'])), isNot(contains('.0')));
    }
  });
}
