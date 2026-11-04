import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/leaderboard_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 排行榜 **方案 A（去横幅 · 信息归位）** 出图（真机尺寸 390 × 844，中文 + Material 图标都挂上）
///
/// 产出（`docs/验收素材/2026-10-13-排行榜重设计/`，**不入 git**）：
/// 1. `leaderboard_1_first_screen.png` 首屏（页头 + 周期分段 + 分部胶囊 + 表头 + 前若干名）
/// 2. `leaderboard_2_full_page.png`    滚动后完整页（整页展开，20 名 + 吸底规则条一屏看完）
/// 3. `leaderboard_3_loading.png`      骨架加载态（6 行灰块，请求未回来时的真实形态）
///
/// ⚠️ `flutter test` 自带字体没有 CJK 字形，不挂系统黑体会变豆腐块；图标同理要挂 `MaterialIcons`
/// —— 两条都是本项目既有出图脚本（`test/visual/profile_redesign_visual_test.dart`）的既有做法。
/// 夹具前 10 名的金额与设计稿 `site/design/leaderboard-redesign/A.html` 的 A-1 / A-2 逐值一致；
/// 11–20 名是按同一口径续写的拟真尾部（接口最多回 100 名，真实榜单不止 10 行）。
void main() {
  const cjk = 'LeaderboardRedesignCJK';
  const pageKey = Key('leaderboard-redesign-page');
  late final Directory outDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiCache.instance.clear();
    outDir = Directory('${resolveRepoRoot()}/docs/验收素材/2026-10-13-排行榜重设计')..createSync(recursive: true);
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(iconPath);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  /// 出图（`toImage` 必须放进 `runAsync`：假时钟下它不会自己回帧）
  Future<void> shoot(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pageKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${outDir.path}/$name')..writeAsBytesSync(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('SHOT $name -> ${file.absolute.path} (${bytes.lengthInBytes} bytes)');
      image.dispose();
    });
  }

  Widget stage(Widget page) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: page,
        ),
      );

  void screen(WidgetTester tester, {double height = 844}) {
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// 有界推进（不用 pumpAndSettle：页面里有骨架/刷新指示器的可能，避免卡在动画上）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    // 每个用例都从"零缓存"开始：否则用例 1 的公开榜单会被用例 3 从 ApiCache 命中，
    // 挂起型假服务器就永远收不到请求 → 拍不到骨架加载态
    ApiClient.cacheEnabled = false;
    ApiCache.instance.clear();
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
  });

  LeaderboardPage page(HttpClientAdapter adapter) =>
      LeaderboardPage(api: ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = adapter));

  testWidgets('出图 1：首屏（页头副标题 + 周期分段 + 分部胶囊 + 表头 + 榜首）', (tester) async {
    screen(tester);
    await tester.pumpWidget(stage(page(_Router())));
    await settle(tester);

    expect(find.text('接单榜'), findsOneWidget, reason: '榜名全页只出现 1 次');
    expect(find.text('按已完成订单金额 · 每日 03:00 更新'), findsOneWidget);
    expect(find.text('周榜'), findsOneWidget);
    expect(find.text('月榜'), findsOneWidget);
    expect(find.text('林岸'), findsOneWidget);
    expect(find.text('¥4,286.50'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await shoot(tester, 'leaderboard_1_first_screen.png');
  });

  testWidgets('出图 2：滚动后完整页（整页展开：20 名 + 吸底规则条，一屏看完全部）', (tester) async {
    // 20 名是真实规模（接口最多回 100 名，docs/21 要求假数据拟真）：390×844 装不下 → 本页确实要滚动，
    // 「整页展开」即滚到底之后的全部内容（= 设计稿 A-2 的画法）
    screen(tester, height: 1460);
    await tester.pumpWidget(stage(page(_Router())));
    await settle(tester);

    expect(find.text('林岸'), findsOneWidget, reason: '第 1 名在整页长图里');
    expect(find.text('苏皖'), findsOneWidget, reason: '整页长图必须一屏装到第 20 名');
    expect(find.text('¥76.40'), findsOneWidget);
    expect(find.text('去下单 ›'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await shoot(tester, 'leaderboard_2_full_page.png');
  });

  testWidgets('出图 3：骨架加载态（请求未回来：6 行灰块，无假数据）', (tester) async {
    screen(tester);
    final hang = _HangRouter();
    await tester.pumpWidget(stage(page(hang)));
    await settle(tester);

    // 真实加载态：只有灰块，没有任何选手名（不拿假数据充数）
    expect(find.text('林岸'), findsNothing);
    expect(find.text('名次'), findsOneWidget, reason: '表头在加载态也在（骨架与真实行同高）');
    expect(find.text('接单榜'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await shoot(tester, 'leaderboard_3_loading.png');

    // 收尾：把挂起的请求放掉，避免测试结束时留下未完成的请求
    hang.release();
    await settle(tester);
  });
}

/// 假服务器：`/divisions` + `/public/leaderboard`（20 名；前 10 名的值与设计稿 A.html 逐值一致）
class _Router implements HttpClientAdapter {
  static const List<Map<String, dynamic>> _rows = [
    {'rank': 1, 'nickname': '林岸', 'workerNo': 'W0101', 'completedOrders': 38, 'amount': 4286.50},
    {'rank': 2, 'nickname': '周慕白', 'workerNo': 'W0102', 'completedOrders': 34, 'amount': 3914.00},
    {'rank': 3, 'nickname': '陈屿', 'workerNo': 'W0103', 'completedOrders': 29, 'amount': 3207.40},
    {'rank': 4, 'nickname': '苏挽', 'workerNo': 'W0104', 'completedOrders': 25, 'amount': 2686.00},
    {'rank': 5, 'nickname': '许砚清', 'workerNo': 'W0105', 'completedOrders': 21, 'amount': 2143.50},
    {'rank': 6, 'nickname': '沈澈', 'workerNo': 'W0106', 'completedOrders': 18, 'amount': 1872.00},
    {'rank': 7, 'nickname': '叶知秋', 'workerNo': 'W0107', 'completedOrders': 15, 'amount': 1506.80},
    {'rank': 8, 'nickname': '程野', 'workerNo': 'W0108', 'completedOrders': 12, 'amount': 1268.50},
    {'rank': 9, 'nickname': '汪一鸣', 'workerNo': 'W0109', 'completedOrders': 9, 'amount': 986.00},
    {'rank': 10, 'nickname': '罗砚', 'workerNo': 'W0110', 'completedOrders': 7, 'amount': 744.20},
    // 11–20：金榜尾部（非整数、长短不一，docs/21「假数据拟真」）
    {'rank': 11, 'nickname': '顾南', 'workerNo': 'W0111', 'completedOrders': 6, 'amount': 684.50},
    {'rank': 12, 'nickname': '温言', 'workerNo': 'W0112', 'completedOrders': 6, 'amount': 612.00},
    {'rank': 13, 'nickname': '白鹭', 'workerNo': 'W0113', 'completedOrders': 5, 'amount': 536.80},
    {'rank': 14, 'nickname': '江野', 'workerNo': 'W0114', 'completedOrders': 5, 'amount': 458.00},
    {'rank': 15, 'nickname': '陆行舟', 'workerNo': 'W0115', 'completedOrders': 4, 'amount': 372.40},
    {'rank': 16, 'nickname': '秦舟', 'workerNo': 'W0116', 'completedOrders': 4, 'amount': 305.00},
    {'rank': 17, 'nickname': '唐砚', 'workerNo': 'W0117', 'completedOrders': 3, 'amount': 248.60},
    {'rank': 18, 'nickname': '何澈', 'workerNo': 'W0118', 'completedOrders': 2, 'amount': 196.00},
    {'rank': 19, 'nickname': '邵川', 'workerNo': 'W0119', 'completedOrders': 2, 'amount': 128.50},
    {'rank': 20, 'nickname': '苏皖', 'workerNo': 'W0120', 'completedOrders': 1, 'amount': 76.40},
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.path.startsWith('/divisions')) {
      return _body(_envelope([
        {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'platformLabel': '手游'},
        {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'platformLabel': '手游'},
        {'id': '3', 'gameId': '36', 'name': '三角洲行动 · 端游', 'platformLabel': '端游'},
      ]));
    }
    if (options.path.startsWith('/public/leaderboard')) {
      return _body(_envelope({'period': '2026-W41', 'divisionId': null, 'list': _rows}));
    }
    return _body(_envelope({'list': <dynamic>[], 'total': 0}));
  }

  static Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  static ResponseBody _body(Object body, {int status = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// 挂起型假服务器：请求**永不完成**（`release()` 才放行）—— 用于拍真实骨架加载态
class _HangRouter implements HttpClientAdapter {
  final List<({String path, Completer<ResponseBody> c})> _pending = [];

  void release() {
    for (final p in _pending) {
      if (p.c.isCompleted) continue;
      // 按路径给**形状正确**的响应：`/divisions` 是列表、榜单是 {list,total}
      final data = p.path.startsWith('/divisions') ? <dynamic>[] : {'list': <dynamic>[], 'total': 0};
      p.c.complete(_Router._body(_Router._envelope(data)));
    }
    _pending.clear();
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    final c = Completer<ResponseBody>();
    _pending.add((path: options.path, c: c));
    return c.future;
  }

  @override
  void close({bool force = false}) {}
}
