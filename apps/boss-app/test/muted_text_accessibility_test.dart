import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:boss_app/pages/complaint_page.dart';
import 'package:boss_app/pages/leaderboard_page.dart';
import 'package:boss_app/pages/refund_page.dart';
import 'package:boss_app/pages/wallet_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可访问性回归：**说明文字用 `mutedText`，图标/发丝线/占位符仍用 `textTertiary`**
///
/// 背景（实测缺陷）：`AppColors.textTertiary = #94A3B8` 与白底对比度仅 **2.56:1**，
/// 连大字号的 3:1 下限都不到 —— 它本来是**图标/分隔/装饰**色，却被全站当成
/// 「副标题 / 说明条 / 事实行」的正文色用。core 为此新增
/// `AppColors.mutedText = #5B6B80`（白底 **5.44:1**，达 WCAG AA 正文 4.5:1）。
///
/// 本文件固化三条规则（与本次替换的逐处判定同一套口径）：
/// 1. **文字 + 白底/浅色底** → `mutedText`（副标题、说明条、事实行、计数 counter）
/// 2. **图标 / 发丝线 / 分隔线 / 禁用态 / 输入提示(hint)** → 保持 `textTertiary`（装饰层，无须 4.5:1）
/// 3. **落在深色底上的文字** → 不动（本文件用状态灰/头像首字反例断言边界）
///
/// 另附 **WCAG 对比度实算**（公式写进测试，不引用任何外部数字表）。
void main() {
  final complaintFixtures = <String, Map<String, dynamic>>{
    '/user/orders': _envelope({
      'list': [
        {'id': '682', 'orderNo': 'ORDMUTCDDG01232', 'productName': '传奇段位上分陪练', 'status': 'pending_confirm'},
        {'id': '683', 'orderNo': 'ORDMUTCDDG01999', 'productName': '三角洲烽火地带护航', 'status': 'completed'},
      ],
      'total': 2,
      'page': 1,
      'pageSize': 20,
    }),
    '/user/complaints/targets/workers': _envelope([
      {'workerId': '106', 'nickname': '演示工作端', 'workerNo': 'W0106', 'lastOrderNo': 'ORDMUTCDDG01232', 'orderCount': 2},
      {'workerId': '107', 'nickname': '北岭', 'workerNo': 'W0107', 'lastOrderNo': 'ORDMUTCDDG01999', 'orderCount': 1},
    ]),
    '/user/complaints': _envelope({'list': const [], 'total': 0, 'page': 1, 'pageSize': 30}),
  };

  final refundFixtures = <String, Map<String, dynamic>>{
    '/user/refunds/orders': _envelope({
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
    }),
    '/user/refunds': _envelope({'list': const [], 'total': 0, 'page': 1, 'pageSize': 30}),
  };

  final leaderboardFixtures = <String, Map<String, dynamic>>{
    '/divisions': _envelope([
      {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'platformLabel': '手游'},
      {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'platformLabel': '手游'},
      {'id': '3', 'gameId': '36', 'name': '三角洲行动 · 端游', 'platformLabel': '端游'},
    ]),
    '/public/leaderboard': _envelope({
      'period': '2026-W40',
      'divisionId': null,
      'list': [
        {'rank': 1, 'nickname': '小云', 'workerNo': 'W001', 'completedOrders': 12, 'amount': 12480},
        {'rank': 2, 'nickname': '雪山', 'workerNo': 'W002', 'completedOrders': 9, 'amount': 9860},
        {'rank': 3, 'nickname': '兔神', 'workerNo': 'W003', 'completedOrders': 7, 'amount': 7240},
        {'rank': 4, 'nickname': '鸦鸦', 'workerNo': 'W004', 'completedOrders': 5, 'amount': 5930},
      ],
    }),
  };

  final walletFixtures = <String, Map<String, dynamic>>{
    '/user/wallet': _envelope({'balance': 3616.55}),
    '/user/wallet/transactions': _envelope({
      'list': [
        {'amount': -16.5, 'changeType': 'order_pay', 'reason': '下单消费', 'balanceAfter': 85383.5, 'createdAt': '2026-09-23T15:12:54.000Z'},
        {'amount': 11.55, 'changeType': 'order_settlement', 'reason': '订单结算', 'balanceAfter': 3616.55, 'createdAt': '2026-09-23T15:30:00.000Z'},
      ],
      'total': 2,
      'page': 1,
      'pageSize': 20,
    }),
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiCache.instance.clear();
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    RealtimeClient.shared.debugDisabled = false;
  });

  // -------------------------------------------------------------------------
  // ③ 对比度：WCAG 2.1 相对亮度公式实算（不查表、不引用外部数字）
  // -------------------------------------------------------------------------

  group('WCAG 对比度（实算）', () {
    test('mutedText 对白底 ≥ 4.5:1（WCAG AA 正文）', () {
      final ratio = _contrastRatio(AppColors.mutedText, AppColors.bgCard);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: 'mutedText vs 白卡 = ${ratio.toStringAsFixed(2)}:1');
    });

    test('mutedText 对页面底 #F5F7FB ≥ 4.5:1', () {
      final ratio = _contrastRatio(AppColors.mutedText, AppColors.bgPage);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: 'mutedText vs 页底 = ${ratio.toStringAsFixed(2)}:1');
    });

    test('textTertiary 不达标 —— 证明正文不能用它（替换的必要性）', () {
      final onWhite = _contrastRatio(AppColors.textTertiary, AppColors.bgCard);
      final onPage = _contrastRatio(AppColors.textTertiary, AppColors.bgPage);
      expect(onWhite, lessThan(3.0), reason: 'textTertiary vs 白 = ${onWhite.toStringAsFixed(2)}:1（低于 3:1 下限）');
      expect(onPage, lessThan(3.0), reason: 'textTertiary vs 页底 = ${onPage.toStringAsFixed(2)}:1');
      expect(onWhite, lessThan(_contrastRatio(AppColors.mutedText, AppColors.bgCard)));
    });

    test('两个 token 是同一冷灰系的深浅两档（不是换了一种颜色）', () {
      // rgb(148,163,184) vs rgb(91,107,128)：三通道同向收窄 → 仍是"更深的同一种灰"
      expect(AppColors.mutedText.r, lessThan(AppColors.textTertiary.r));
      expect(AppColors.mutedText.g, lessThan(AppColors.textTertiary.g));
      expect(AppColors.mutedText.b, lessThan(AppColors.textTertiary.b));
      expect((AppColors.textTertiary.r - AppColors.mutedText.r).abs(), lessThan(0.35));
    });

    test('对比度实算明细（原始数字留证：白底 / 页底 #F5F7FB）', () {
      String r(Color a, Color b) => _contrastRatio(a, b).toStringAsFixed(2);
      // ignore: avoid_print
      print('WCAG 实算 | mutedText  #5B6B80 vs 白 #FFFFFF  = ${r(AppColors.mutedText, AppColors.bgCard)}:1');
      // ignore: avoid_print
      print('WCAG 实算 | mutedText  #5B6B80 vs 页 #F5F7FB  = ${r(AppColors.mutedText, AppColors.bgPage)}:1');
      // ignore: avoid_print
      print('WCAG 实算 | textTertiary #94A3B8 vs 白 #FFFFFF = ${r(AppColors.textTertiary, AppColors.bgCard)}:1');
      // ignore: avoid_print
      print('WCAG 实算 | textTertiary #94A3B8 vs 页 #F5F7FB = ${r(AppColors.textTertiary, AppColors.bgPage)}:1');
      expect(_contrastRatio(AppColors.mutedText, AppColors.bgCard), greaterThanOrEqualTo(4.5));
      expect(_contrastRatio(AppColors.mutedText, AppColors.bgPage), greaterThanOrEqualTo(4.5));
    });

    test('既有 token 值未被改动；主题门面 T.mutedText 与 AppColors 同源', () {
      // ⚠️ 2026-10-14 品牌升级后的**真实取值**（本条断言曾被批量同步脚本误改，见下）：
      // - `textTertiary` 是**旧 token**，本轮**刻意逐值保留** `#94A3B8`（图标/发丝线/禁用态仍在用），
      //   改它会把全站图标与分隔线一起漂移；core 侧 `theme_tokens_test.dart` 也断言它未变。
      // - 品牌升级里改值的是**另一个** token：`statusMuted` → `#8A99AB`（见下方边界用例）。
      // 因此这里断言原值，而不是把预期值跟着 `statusMuted` 一起改（那是把两个 token 混为一谈）。
      expect(AppColors.textTertiary, const Color(0xFF94A3B8), reason: '旧 token 保留原值（图标/分隔/禁用态仍在用）');
      expect(AppColors.mutedText, const Color(0xFF4A5A6E));
      expect(T.mutedText, AppColors.mutedText, reason: '主题页面走 T.mutedText，取色与 AppColors 完全一致');
      expect(T.textTertiary, AppColors.textTertiary, reason: 'T.textTertiary 读取的是同一个 token，未被改值');
      expect(kClassicTokens.bgPage, AppColors.bgPage);
      expect(kClassicTokens.textTertiary, AppColors.textTertiary);
    });
  });

  // -------------------------------------------------------------------------
  // ① 核心页面：说明文字 == mutedText
  // -------------------------------------------------------------------------

  group('核心页面说明文字 → mutedText', () {
    testWidgets('投诉页：副标题 / 计数 / 底部提示 / 打手候选说明 / 客服说明', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: _api(complaintFixtures))));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(_colorOf(tester, '客服核实后会在站内通知里回复'), AppColors.mutedText);
      expect(_colorOf(tester, '恶意投诉会被记录；截图仅你本人与客服可见。'), AppColors.mutedText);

      // counter（"0/500"）是要读的信息 → mutedText；hint 是占位符 → 保持 textTertiary
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration?.counterStyle?.color, AppColors.mutedText);
      expect(field.decoration?.hintStyle?.color, AppColors.textTertiary);

      await tester.tap(find.text('打手'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(_colorOf(tester, '只列出接过你订单的打手（共 2 位）'), AppColors.mutedText);

      await tester.tap(find.text('客服'));
      await tester.pumpAndSettle();
      const serviceHint = '客服投诉由值班客服认领处理，不需要选择具体对象。';
      expect(_colorOf(tester, serviceHint), AppColors.mutedText);
      expect(_colorOf(tester, serviceHint), isNot(AppColors.textTertiary), reason: '替换前这里是 #94A3B8（2.56:1）');
    });

    testWidgets('退款页：副标题 / 订单事实行 / 弹层说明', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(home: RefundPage(api: _api(refundFixtures))));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(_colorOf(tester, '客服会尽快审核'), AppColors.mutedText);
      expect(
        _colorOfWhere(tester, (s) => s.startsWith('ORDMUTCE54B1201 · 下单')),
        AppColors.mutedText,
        reason: '订单号 + 下单时间事实行',
      );

      await tester.tap(find.widgetWithText(AppButton, '申请退款').first);
      await tester.pumpAndSettle();
      expect(_colorOfWhere(tester, (s) => s.startsWith('ORDMUTCDFCC9826 · 可退')), AppColors.mutedText);
      expect(_colorOf(tester, '审核通过后余额原路退回；审核结果会在站内通知里告诉你。'), AppColors.mutedText);

      final remark = tester.widget<TextField>(find.byType(TextField));
      expect(remark.decoration?.hintStyle?.color, AppColors.textTertiary, reason: '占位符属装饰层，保持不动');
      expect(remark.decoration?.counterStyle?.color, AppColors.mutedText, reason: '计数是要读的信息');
    });

    testWidgets('榜单页：页头副标题 / 表头三列 / 吸底说明 / 第 4 名数字', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(home: LeaderboardPage(api: _api(leaderboardFixtures))));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(_colorOf(tester, '按已完成订单金额 · 每日 03:00 更新'), AppColors.mutedText);
      expect(_colorOf(tester, '名次'), AppColors.mutedText);
      expect(_colorOf(tester, '陪玩'), AppColors.mutedText);
      expect(_colorOf(tester, '接单金额（¥）'), AppColors.mutedText);
      expect(_colorOf(tester, '每周一 03:00 重新统计 · 完成订单即可上榜'), AppColors.mutedText);
      expect(_colorOf(tester, '4'), AppColors.mutedText, reason: '第 4 名起的名次数字是文字，不是徽章底色');
    });

    testWidgets('钱包页：流水说明行（reason / 余额快照）', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(home: WalletPage(api: _api(walletFixtures))));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(_colorOf(tester, '余额 ¥85,383.50'), AppColors.mutedText);
      final mutedRows = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.style?.fontSize == 12 && t.style?.color == AppColors.mutedText);
      expect(mutedRows, isNotEmpty, reason: '流水下的"说明行"（reason / 余额快照）必须是 mutedText');
      final balances = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.data != null && t.data!.startsWith('余额 '))
          .toList();
      expect(balances.length, 2, reason: '两条流水各有一行余额快照');
      for (final b in balances) {
        expect(b.style?.color, AppColors.mutedText);
      }
    });
  });

  // -------------------------------------------------------------------------
  // ② 图标 / 分隔线 / 禁用态 / 装饰色：保持 textTertiary 或原样
  // -------------------------------------------------------------------------

  group('图标与分隔线保持 textTertiary', () {
    testWidgets('投诉页：上传位相机图标、下拉 chevron 仍是图标色', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(home: ComplaintPage(api: _api(complaintFixtures))));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(tester.widget<Icon>(find.byIcon(AppIcon.camera)).color, AppColors.textTertiary,
          reason: '图标是装饰层，不参与正文对比度');
      for (final icon in tester.widgetList<Icon>(find.byIcon(AppIcon.chevronDown))) {
        expect(icon.color, AppColors.textTertiary);
      }
    });

    testWidgets('榜单页：时钟图标 + 发丝线；且 ≤12.5sp 的说明文字无 textTertiary 漏网', (tester) async {
      _tall(tester);
      await tester.pumpWidget(MaterialApp(home: LeaderboardPage(api: _api(leaderboardFixtures))));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(tester.widget<Icon>(find.byIcon(AppIcon.clock)).color, AppColors.textTertiary);

      final dividers = tester.widgetList<Divider>(find.byType(Divider)).toList();
      expect(dividers, isNotEmpty, reason: '4 行榜单之间有 3 条发丝线');
      for (final d in dividers) {
        expect(d.color, T.divider);
      }

      // 漏网检查：本页 ≤12.5sp 的说明文字一律不得再用 textTertiary。
      // （头像首字 14.28sp 是装饰色 rankColor，刻意排除在"文字"之外）
      final leaked = tester.widgetList<Text>(find.byType(Text)).where((t) {
        final size = t.style?.fontSize;
        return size != null && size <= 12.5 && t.style?.color == AppColors.textTertiary;
      }).toList();
      expect(leaked.map((t) => t.data).toList(), isEmpty, reason: '说明文字还有漏网的 textTertiary');
    });

    testWidgets('禁用态与状态灰不等于"说明文字"（边界断言）', (tester) async {
      // ⚠️ 2026-10-14 品牌升级后原假设**已不成立**：旧稿「状态灰 = textTertiary」，
      // 升级把**状态灰**挪到了独立 token `statusMuted` = `#8A99AB`，
      // 而 `textTertiary` 作为旧装饰色**逐值保留** `#94A3B8` —— 两者不再相等。
      // 断言因此改写成「各自真实值 + 仍然都不等于说明文字(mutedText)」，
      // 而不是放宽成"相等即可"（那是把两个语义不同的 token 又粘回去）。
      expect(AppColors.statusMuted, const Color(0xFF8A99AB), reason: '状态灰（未解锁/已结束）本轮改值');
      expect(AppColors.textTertiary, const Color(0xFF94A3B8), reason: '装饰灰（图标/发丝线/禁用态）本轮未改值');
      expect(AppColors.statusMuted, isNot(AppColors.textTertiary), reason: '两个 token 自 2026-10-14 起不再同值');
      expect(AppColors.statusMuted, isNot(AppColors.mutedText), reason: '状态灰 ≠ 说明文字色');
      expect(AppColors.textTertiary, isNot(AppColors.mutedText), reason: '装饰灰 ≠ 说明文字色');

      // 对比度界：**状态/装饰灰本来就不需要 4.5:1**（WCAG 只对"文字"要求），
      // 把两者一并改深会混淆"少一档的灰"与"不可用"。
      expect(_contrastRatio(AppColors.textTertiary, AppColors.bgCard), lessThan(3.0),
          reason: '装饰灰保持低对比（不到 3:1），说明文字才有 4.5:1 要求');
      expect(_contrastRatio(AppColors.mutedText, AppColors.bgCard), greaterThanOrEqualTo(4.5),
          reason: '说明文字必须达 AA 正文');
    });
  });
}

// ---------------------------------------------------------------------------
// 断言辅助
// ---------------------------------------------------------------------------

/// 出图/断言用高画布：ListView 惰性构建，600px 视口会让底部说明条根本不进树
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

/// 按精确文案取 `Text` 的颜色（找不到/多个都会立刻失败，避免假绿）
Color? _colorOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style?.color;

/// 按前缀/子串取唯一 `Text` 的颜色（时间戳等随本地时区变化的行）
Color? _colorOfWhere(WidgetTester tester, bool Function(String) match) {
  final hits = tester
      .widgetList<Text>(find.byType(Text))
      .where((t) => t.data != null && match(t.data!))
      .toList();
  expect(hits.length, 1, reason: '期望唯一命中，实际 ${hits.length} 条');
  return hits.single.style?.color;
}

/// WCAG 2.1 相对亮度：通道 ≤ 0.03928 走线性段，否则 ((c+0.055)/1.055)^2.4
double _relativeLuminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.1 对比度：(L_亮 + 0.05) / (L_暗 + 0.05)
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
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
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'no fixture', 'data': null}), 404, headers: {
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
