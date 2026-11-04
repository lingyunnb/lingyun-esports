import 'dart:convert';

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 小数金额（2026-09-23 负责人价目表：钻皮·刀 5.5 积分）在客户端双端的解析/展示契约。
///
/// 回归背景：服务端 DECIMAL 字段经 money.transformer 返回 **JSON 数字**，
/// 小数订单在 /user/orders、/worker/order-hall、/worker/orders 中形如 `"totalAmount":5.5`。
/// 历史写法 `json['totalAmount'] as int? ?? 0` 在 Dart 中对该响应抛 TypeError，
/// 直接导致老板端/工作端订单页整页崩溃 —— 一律改用 parsePoints + fmtPoints。
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  // 真实接口响应片段（curl /worker/order-hall 实测：5.5 积分订单）
  final decimalOrder = jsonDecode('{"id":"396","totalAmount":5.5,"unitPrice":5.5}') as Map<String, dynamic>;
  // 整数金额订单（服务端 Number("16.00")=16 → JSON 整数）
  final intOrder = jsonDecode('{"id":"395","totalAmount":16,"unitPrice":16}') as Map<String, dynamic>;

  test('历史写法 as int 在服务端小数金额上抛 TypeError（双端订单页崩溃根因）', () {
    expect(() => decimalOrder['totalAmount'] as int? ?? 0, throwsA(isA<TypeError>()));
  });

  test('parsePoints 兼容小数/整数/字符串/空值', () {
    expect(parsePoints(decimalOrder['totalAmount']), 5.5);
    expect(parsePoints(intOrder['totalAmount']), 16.0);
    expect(parsePoints(null), 0);
    expect(parsePoints('5.50'), 5.5); // 防御：若某接口漏了 transformer 返回字符串
    expect(parsePoints(0), 0);
  });

  test('fmtPoints 展示：整数不带小数点，小数最多两位并去掉尾零', () {
    expect(fmtPoints(5.5), '5.5');
    expect(fmtPoints(11.55), '11.55');
    expect(fmtPoints(16), '16');
    expect(fmtPoints(16.0), '16');
    expect(fmtPoints(3616.55), '3616.55');
    expect(fmtPoints(100.10), '100.1');
    expect(fmtPoints(0), '0');
  });

  test('fmtPoints(parsePoints(x)) —— 接口字段直接展示不出现 .0 或长尾', () {
    expect(fmtPoints(parsePoints(decimalOrder['totalAmount'])), '5.5');
    expect(fmtPoints(parsePoints(intOrder['totalAmount'])), '16');
  });

  // =====================================================================================
  // fmtMoney —— **金额显示的唯一出口**（2026-10-09 口径：计价单位 = 余额，1 元 = 1 元）
  // =====================================================================================
  group('fmtMoney：¥ + 千分位 + 固定两位小数', () {
    test('负责人给的样例：0 / 0.5 / 8.8 / 1234.5 / 99999.9', () {
      expect(fmtMoney(0), '¥0.00');
      expect(fmtMoney(0.5), '¥0.50');
      expect(fmtMoney(8.8), '¥8.80');
      expect(fmtMoney(1234.5), '¥1,234.50');
      expect(fmtMoney(99999.9), '¥99,999.90');
    });

    test('整数也补两位小数；大额千分位分组；负数（扣款）负号在 ¥ 前', () {
      expect(fmtMoney(6), '¥6.00');
      expect(fmtMoney(16), '¥16.00');
      expect(fmtMoney(100), '¥100.00');
      expect(fmtMoney(1000), '¥1,000.00');
      expect(fmtMoney(1234567.89), '¥1,234,567.89');
      expect(fmtMoney(-5), '-¥5.00');
      expect(fmtMoney(-1234.5), '-¥1,234.50');
    });

    test('两位小数四舍五入；接口返回值（num/字符串/null）都能吃', () {
      expect(fmtMoney(11.555), '¥11.56');
      expect(fmtMoney(11.554), '¥11.55');
      // 极小负数四舍五入到 0 → 不能显示成 -¥0.00
      expect(fmtMoney(-0.001), '¥0.00');
      expect(fmtMoney(parsePoints(decimalOrder['totalAmount'])), '¥5.50');
      expect(fmtMoney(parsePoints(intOrder['totalAmount'])), '¥16.00');
      expect(fmtMoney(parsePoints(null)), '¥0.00');
      expect(fmtMoney(parsePoints('5.50')), '¥5.50');
    });

    test('口径红线：fmtMoney 的产物**自带 ¥**（页面不得再拼一次单位）', () {
      expect(fmtMoney(8.8).startsWith('¥'), isTrue);
      expect(fmtMoney(8.8).contains('积分'), isFalse);
      expect(fmtMoney(8.8).contains('余额'), isFalse);
      // 只保留两位小数（不会出现 .5 / .500）
      expect(RegExp(r'\.\d{2}$').hasMatch(fmtMoney(8.8)), isTrue);
    });

    test('冻结兼容：fmtPoints 仍是旧口径（工作端 App 专用），不与 fmtMoney 混用', () {
      expect(fmtPoints(8.8), '8.8');
      expect(fmtPoints(8.8) == fmtMoney(8.8), isFalse);
    });
  });
}
