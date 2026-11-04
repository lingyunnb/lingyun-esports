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
import 'package:worker_app/pages/migration_guide_page.dart';
import 'package:worker_app/pages/profile_page.dart';
import 'package:worker_app/widgets/fish_glass.dart';
import 'package:worker_app/widgets/migration_notice.dart';
import 'package:worker_app/widgets/worker_sunset.dart';

/// 工作端退役 · 迁移引导出图（负责人 2026-10-06；口径随 v1.8.2 / 码 60 改为"已停止服务"）
///
/// 产出（`apps/worker-app/build/`）：
/// - `migration_worker_home.png`   首页（含页头下方常驻引导条，现在时口径）
/// - `migration_worker_profile.png`我的页（含打手态说明卡 + 下载入口）
/// - `migration_worker_guide.png`  迁移说明页（5 步绑定 + 两个下载地址）
///
/// **字体坑（既有教训，逐条照做）**：
/// 1. `flutter test` 不加载 pubspec 字体，不挂字体中文全是 Ahem 方块 → 手工挂系统字体；
///    顺序按负责人要求：**中文字体 `msyh` 放最前**（MiSans/黑体只作兜底），否则中文字形缺字；
/// 2. 必须**同时**挂 `MaterialIcons`，否则 `Icons.*` / `AppIcon.*` 全是方块（第二个坑）。
void main() {
  const captureKey = Key('capture');
  const appFontFamily = 'MiSans'; // main.dart 用的字体名（真机由系统兜底中文）

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
    AuthStore.instance.debugSetSession(accessToken: 'shot-token', me: _me());
  });

  tearDown(() {
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
            builder: (context, child) => FishGlassBackdrop(child: child ?? const SizedBox.shrink()),
            home: home,
          ),
        ),
      );

  testWidgets('首页出图：迁移引导条在页头下方（已停止服务口径）、收益与待处理照常', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(shell(HomePage(api: _api())));
    await tester.pumpAndSettle();

    // v1.8.2 / 码 60：立即阻断 → 引导条恒为"已停止服务"口径（与阻断页同一句常量）
    expect(find.text(kMigrationEndedHeadline), findsOneWidget);
    expect(find.textContaining(kWorkerSunsetBlockedNote), findsOneWidget);
    expect(find.text('复制下载地址'), findsOneWidget);
    expect(find.text('我的收益'), findsOneWidget); // 引导条没把原有内容挤出首屏
    expect(tester.takeException(), isNull);
    await capture(tester, 'migration_worker_home');
  });

  testWidgets('我的页出图：打手态说明卡（分步骤 + 已停止服务口径）+ 下载入口', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(shell(ProfilePage(api: _api())));
    await tester.pumpAndSettle();

    expect(find.text(kMigrationWorkerStateEndedTitle), findsOneWidget);
    expect(find.text('复制下载地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'migration_worker_profile');
  });

  testWidgets('说明页出图：5 步绑定 + 两个下载地址（版本来自接口）', (tester) async {
    // 说明页比手机长：出图用加高视口一次拍全（FAQ 也在图里）
    tester.view.physicalSize = const Size(390 * 2, 1560 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(shell(MigrationGuidePage(api: _api())));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前老板端 v1.11.19'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'migration_worker_guide');
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
    '/worker/orders': {
      'list': const [],
      'total': 0,
      'page': 1,
      'pageSize': 100,
    },
    '/public/app-versions/latest': {
      'hasUpdate': true,
      'force': false,
      'latest': {
        'versionCode': 76,
        'versionName': '1.11.19',
        'fileSize': 27368751,
        'downloadUrl': '/api/v1/public/app-versions/download/99',
      },
    },
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
  var dir = File(Platform.resolvedExecutable).parent; // engine/<platform>
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
