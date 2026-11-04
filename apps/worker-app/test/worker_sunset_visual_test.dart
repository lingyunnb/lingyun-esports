import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/home_page.dart';
import 'package:worker_app/pages/worker_sunset_block_page.dart';
import 'package:worker_app/widgets/migration_notice.dart';
import 'package:worker_app/widgets/worker_sunset.dart';

/// 工作端**完全阻断版（v1.8.2 / 码 60）**· 阻断页与引导条出图（负责人 2026-10-06 拍板）
///
/// 产出（`apps/worker-app/build/`）：
/// - `sunset_worker_block.png` 阻断页（**只剩「前往下载」**，没有「暂时继续使用」）
/// - `sunset_worker_home.png`  首页引导条（同一句"已停止服务"，现在时口径）
///
/// 另留两张对照图，钉"**任何时间都是同一页**"（日期由 `now` 注入，与真实日期无关）：
/// - `sunset_worker_block_before.png` 注入旧宽限期内（2026-10-12 23:59）→ 同样没有「暂时继续使用」
/// - `sunset_worker_block_after.png`  注入旧到期日之后（2026-10-20）→ 与上面逐字相同的口径
///
/// **字体坑（既有教训，逐条照做）**：
/// 1. `flutter test` 不加载 pubspec 字体，不挂字体中文全是方块 → 手工挂系统字体，
///    顺序按负责人要求：**中文字体 `msyh` 放最前**（MiSans/黑体只作兜底）；
/// 2. 必须**同时**挂 `MaterialIcons`，否则 `Icons.*` / `AppIcon.*` 全是方块。
void main() {
  const captureKey = Key('capture');
  const appFontFamily = 'MiSans';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFont(appFontFamily, const [
      'C:/Windows/Fonts/msyh.ttc', // ← 中文字体放最前（既有坑 1）
      'C:/Windows/Fonts/msyh.ttf',
      '../boss-app/assets/fonts/MiSans-Normal.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]);
    await _loadMaterialIcons(); // ← 同时挂图标字体（既有坑 2）
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false;
    // 出图只取决于注入的日期：立即阻断下页面本就不再探测服务端时间，这里显式关掉更干净
    WorkerSunsetProbe.enabled = false;
    AuthStore.instance.debugSetSession(accessToken: 'shot-token', me: _me());
    WorkerSunsetGate.instance.debugReset();
  });

  tearDown(() {
    WorkerSunsetProbe.enabled = true;
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugSetSession();
  });

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      Directory('build').createSync(recursive: true);
      File('build/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  void phoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Widget shell(Widget home) => RepaintBoundary(
        key: captureKey,
        child: MiuixSystemTheme(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              scaffoldBackgroundColor: Colors.transparent,
              fontFamily: appFontFamily,
            ),
            home: home,
          ),
        ),
      );

  testWidgets('阻断页出图：已停止服务 + 下载入口 + 5 步 + 只剩「前往下载」', (tester) async {
    // 整页内容（5 步细节都在）一次拍全：阻断页比手机长，用加高视口
    tester.view.physicalSize = const Size(390 * 2, 1250 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(shell(const WorkerSunsetBlockPage()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
    expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
    expect(find.text(kWorkerSunsetServerNote), findsOneWidget);
    expect(find.text(MigrationDownload.siteUrl), findsOneWidget);
    expect(find.text(kWorkerSunsetStepsTitle), findsOneWidget);
    expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget);
    expect(find.text(kWorkerSunsetContinueLabel), findsNothing,
        reason: '完全阻断版：出图里不许有「暂时继续使用」');
    expect(find.byType(AppButton), findsOneWidget, reason: '只剩「前往下载」一个按钮');
    // 文案自查：整页没有未来时、没有日期
    for (final s in tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>()) {
      expect(s, isNot(contains('将于')));
      expect(s, isNot(contains(kWorkerSunsetDateText)));
    }
    expect(tester.takeException(), isNull);
    await capture(tester, 'sunset_worker_block');
  });

  testWidgets('首页引导条出图：同一句"已停止服务"就在页头下方', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(shell(HomePage(api: _api())));
    await tester.pumpAndSettle();

    expect(find.text(kMigrationEndedHeadline), findsOneWidget);
    expect(find.textContaining(kWorkerSunsetBlockedNote), findsOneWidget);
    expect(find.textContaining('将于'), findsNothing, reason: '引导条不许再有未来时');
    expect(find.text('我的收益'), findsOneWidget); // 引导条没把原有内容挤出首屏
    expect(tester.takeException(), isNull);
    await capture(tester, 'sunset_worker_home');
  });

  // ─────────────── 对照出图：任何时间都是同一页（日期注入，与真实日期无关）

  testWidgets('旧宽限期内出图：同样没有「暂时继续使用」（立即阻断，不看日期）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1250 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // v1.8.1 时这里还能继续用（发布日 + 7 天）；本版立即生效 → 同一页
    final DateTime before = DateTime(2026, 10, 12, 23, 59);
    await tester.pumpWidget(shell(WorkerSunsetBlockPage(now: before, networkTime: before)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
    expect(find.text(kWorkerSunsetContinueLabel), findsNothing, reason: '旧宽限期内也不再有「暂时继续使用」');
    expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
    expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'sunset_worker_block_before');
  });

  testWidgets('旧到期日之后出图：与宽限期内逐字相同的口径（无日期、无未来时）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1250 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final DateTime after = DateTime(2026, 10, 20, 10);
    await tester.pumpWidget(shell(WorkerSunsetBlockPage(now: after, networkTime: after)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(kWorkerSunsetEndedHeadline), findsOneWidget);
    expect(find.text(kWorkerSunsetBlockedNote), findsOneWidget);
    expect(find.text(kWorkerSunsetContinueLabel), findsNothing);
    expect(find.text(kWorkerSunsetDownloadLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'sunset_worker_block_after');
  });
}

// ---------------------------------------------------------------- 脚手架

AuthMe _me() => AuthMe.fromJson({
      'id': '77',
      'username': 'worker_demo',
      'uid': '8842019',
      'nickname': '陈默',
      'role': 'worker',
      'level': 2,
      'worker': {
        'workerNo': 'W-1042',
        'canTakeOrder': true,
        'canServeCustomer': false,
        'divisionPermissions': [
          {'divisionId': 1, 'name': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
          {'divisionId': 2, 'name': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
        ],
      },
    });

/// 出图数据全部取自真实接口结构（工号/收益为拟真的非整数，docs/21）
ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter({
    '/worker/my-stats': {'completedOrders': 184, 'totalAmount': 6218.5},
    '/worker/my-wallet': {'balance': 942.5, 'totalIncome': 5130, 'totalSpent': 0},
    '/worker/orders': {'list': const [], 'total': 0, 'page': 1, 'pageSize': 100},
  });
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.responses);

  final Map<String, Map<String, dynamic>> responses;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = responses.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    final body = key.isEmpty
        ? {'code': 404, 'message': 'Not Found', 'data': null}
        : {'code': 0, 'message': 'ok', 'data': responses[key]};
    return ResponseBody.fromString(
      jsonEncode(body),
      key.isEmpty ? 404 : 200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 把一个字体文件挂进 [family]（取第一个存在的候选路径）
Future<void> _loadFont(String family, List<String> candidates) async {
  for (final path in candidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
    await loader.load();
    return;
  }
}

/// 补挂 Material 图标字体（测试环境默认不带，`Icons.*` 会渲染成方块）
Future<void> _loadMaterialIcons() async {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 3; i++) {
    dir = dir.parent;
  }
  for (final name in const ['materialicons-regular.otf', 'MaterialIcons-Regular.otf']) {
    for (final sub in const ['artifacts/material_fonts', 'material_fonts', '']) {
      final f = File('${dir.path}${Platform.pathSeparator}'
          '${sub.isEmpty ? '' : '$sub${Platform.pathSeparator}'}$name');
      if (!f.existsSync()) continue;
      await _loadFont('MaterialIcons', [f.path]);
      return;
    }
  }
}
