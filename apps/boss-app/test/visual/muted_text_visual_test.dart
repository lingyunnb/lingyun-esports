import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:boss_app/pages/complaint_page.dart';
import 'package:boss_app/pages/leaderboard_page.dart';
import 'package:boss_app/pages/refund_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「说明文字对比度」出图（像素证据，390 × 844 @2x）：
/// ① `build/a11y_complaint_after.png`   —— 投诉页（页头副标题 + 底部说明条）
/// ② `build/a11y_refund_after.png`      —— 退款页（页头副标题 + 订单事实行）
/// ③ `build/a11y_leaderboard_after.png` —— 榜单页（页头副标题 + 表头三列 + 吸底说明）
/// ④ `build/a11y_before_after.png`      —— **改前/改后对照**：同一批文案、同一字号、同一底色，
///     仅 `textTertiary`(#94A3B8) → `mutedText`(#5B6B80) 一个变量，并把实算对比度印在图上
///
/// 三个既有坑（照 `test/visual/friend_search_visual_test.dart` 的写法绕开）：
/// 1. 测试环境没有 CJK 字形 → `FontLoader` 挂系统字体（**msyh 放最前**，标点覆盖最广）
/// 2. 测试环境不加载 Material 图标字体 → 一并挂 `materialicons-regular.otf`（否则图标是空方框）
/// 3. `ThemeData(fontFamily:)` 改不动 `textTheme` → 必须 `textTheme.apply(fontFamily:)` 再套一遍
void main() {
  const cjkFamily = 'A11yShotCJK';
  const shotKey = Key('a11y-shot');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      r'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      r'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc', // 标点覆盖最广（`›` U+203A 只有它有）
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjkFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
    }
  });

  setUp(() {
    ApiClient.cacheEnabled = false;
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Widget frame(Widget child) => RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: () {
            final base = ThemeData(fontFamily: cjkFamily, scaffoldBackgroundColor: AppColors.bgPage);
            return base.copyWith(textTheme: base.textTheme.apply(fontFamily: cjkFamily));
          }(),
          home: child,
        ),
      );

  // ---- 夹具（与 muted_text_accessibility_test.dart 同源）----
  final complaintFixtures = <String, Map<String, dynamic>>{
    '/user/orders': _envelope({
      'list': [
        {'id': '682', 'orderNo': 'ORDMUTCDDG01232', 'productName': '传奇段位上分陪练', 'status': 'pending_confirm'},
      ],
      'total': 1,
      'page': 1,
      'pageSize': 20,
    }),
    '/user/complaints/targets/workers': _envelope([
      {'workerId': '106', 'nickname': '演示工作端', 'workerNo': 'W0106', 'lastOrderNo': 'ORDMUTCDDG01232', 'orderCount': 2},
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
    ]),
    '/public/leaderboard': _envelope({
      'period': '2026-W41',
      'divisionId': null,
      'list': [
        {'rank': 1, 'nickname': '小云', 'workerNo': 'W001', 'completedOrders': 12, 'amount': 12480},
        {'rank': 2, 'nickname': '雪山', 'workerNo': 'W002', 'completedOrders': 9, 'amount': 9860},
        {'rank': 3, 'nickname': '兔神', 'workerNo': 'W003', 'completedOrders': 7, 'amount': 7240},
        {'rank': 4, 'nickname': '鸦鸦', 'workerNo': 'W004', 'completedOrders': 5, 'amount': 5930},
      ],
    }),
  };

  testWidgets('出图 ① 投诉页：页头副标题 + 底部说明条（mutedText）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(ComplaintPage(api: _api(complaintFixtures))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 切到「客服」对象：一是把那张"客服投诉无需选对象"的说明条拍进来，
    // 二是 `DropdownButton(style:)` 自带 style 且不带 fontFamily → 在 `flutter test`
    // 里会落回无 CJK 字形的测试字体（渲染成豆腐块）—— 切走后画面里就没有它了
    await tester.tap(find.text('客服'));
    await tester.pumpAndSettle();

    expect(find.text('客服核实后会在站内通知里回复'), findsOneWidget);
    expect(tester.widget<Text>(find.text('客服投诉由值班客服认领处理，不需要选择具体对象。')).style?.color, AppColors.mutedText);
    expect(tester.widget<Text>(find.text('恶意投诉会被记录；截图仅你本人与客服可见。')).style?.color, AppColors.mutedText);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await shoot(tester, 'a11y_complaint_after.png');
  });

  testWidgets('出图 ② 退款页：页头副标题 + 订单事实行（mutedText）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(RefundPage(api: _api(refundFixtures))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('客服会尽快审核'), findsOneWidget);
    expect(find.textContaining('ORDMUTCE54B1201 · 下单'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await shoot(tester, 'a11y_refund_after.png');
  });

  testWidgets('出图 ③ 榜单页：页头副标题 + 表头三列 + 吸底说明（mutedText）', (tester) async {
    phone(tester);
    await tester.pumpWidget(frame(LeaderboardPage(api: _api(leaderboardFixtures))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('按已完成订单金额 · 每日 03:00 更新'), findsOneWidget);
    expect(find.text('名次'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await shoot(tester, 'a11y_leaderboard_after.png');
  });

  testWidgets('出图 ④ 改前/改后对照：同文案同字号同底色，只差灰的深浅', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 520 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(frame(const _BeforeAfterPanel()));
    await tester.pumpAndSettle();
    await shoot(tester, 'a11y_before_after.png');
  });
}

/// 改前/改后对照面板（用**真实的**三页说明文案 + 真实字号 + 真实底色）
///
/// 左列 = 改前 `AppColors.textTertiary`，右列 = 改后 `AppColors.mutedText`；
/// 每行下面把 WCAG 实算对比度印出来 —— 出图本身就是证据，不靠嘴说。
class _BeforeAfterPanel extends StatelessWidget {
  const _BeforeAfterPanel();

  static const _samples = <(String, double)>[
    ('客服核实后会在站内通知里回复', 10.5),
    ('客服会尽快审核', 10.5),
    ('按已完成订单金额统计', 10.5),
    ('恶意投诉会被记录；截图仅你本人与客服可见。', 10.5),
    ('名次 · 陪玩 · 接单金额（积分）', 10.5),
    ('余额 ¥85,383.50', 12),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPage,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('说明文字对比度 · 改前 / 改后',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text(
                '左 #94A3B8 textTertiary（${_ratio(AppColors.textTertiary, AppColors.bgCard)}:1）  ·  '
                '右 #5B6B80 mutedText（${_ratio(AppColors.mutedText, AppColors.bgCard)}:1）',
                style: const TextStyle(fontSize: 11, color: AppColors.mutedText),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _column('改前 textTertiary', AppColors.textTertiary)),
                  const SizedBox(width: 10),
                  Expanded(child: _column('改后 mutedText', AppColors.mutedText)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _column(String label, Color ink) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ink)),
          const SizedBox(height: 6),
          // 白卡
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in _samples)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(s.$1, style: TextStyle(fontSize: s.$2, color: ink, height: 1.5)),
                  ),
              ],
            ),
          ),
        ],
      );

  static String _ratio(Color a, Color b) {
    double lum(Color c) {
      double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    final la = lum(a);
    final lb = lum(b);
    return ((math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)).toStringAsFixed(2);
  }
}

Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

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
