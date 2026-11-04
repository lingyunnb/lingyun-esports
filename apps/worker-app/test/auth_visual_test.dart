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
import 'package:worker_app/pages/login_page.dart';
import 'package:worker_app/widgets/fish_glass.dart';

/// 工作端登录页出图（负责人对照设计稿 `site/design/auth/p-b-login.png` 验收用）
///
/// 产出：`apps/worker-app/build/auth_worker_login.png`（随后复制到 apps/boss-app/build/
/// 与老板端两张图一起交验收）。包含与 main.dart 同款的全局玻璃背景，用来证明登录页压住了光斑。
///
/// 注意：`flutter test` 不会加载 pubspec 里的字体资源，`Icons.*` 与中文都会渲染成 **Ahem 方块**，
/// 所以出图前手工把字体挂进字体表（只为让 PNG 可读，不改 App 的任何字体设置）：
///  - 工作端 `main.dart` 用 `fontFamily: 'MiSans'`，但**未随包提供**该字体（真机由系统兜底中文），
///    故这里把系统黑体挂在 `MiSans` 名下，出图即真机效果。
///  - `MaterialIcons`：Material 图标字体（输入框前置图标、密码眼睛、勾选对勾）。
void main() {
  const captureKey = Key('capture');
  const appFontFamily = 'MiSans';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFont(appFontFamily, const [
      '../boss-app/assets/fonts/MiSans-Normal.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]);
    await _loadMaterialIcons();
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  Future<void> capture(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('工作端登录页出图（同款视觉、只有登录、页脚保留管理员创建文案）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'))
      ..httpClientAdapter = _Adapter();
    await tester.pumpWidget(RepaintBoundary(
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
          home: LoginPage(api: ApiClient(dio: dio)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AppBrandHeader), findsOneWidget);
    expect(find.text('工作账号由管理员创建分配'), findsWidgets);
    expect(find.textContaining('注册'), findsNothing);
    expect(tester.takeException(), isNull);
    await capture(tester, 'auth_worker_login');
  });
}

/// 把一个字体文件挂进 [family]（取第一个存在的候选路径）。
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

/// 补挂 Material 图标字体（测试环境默认不带，`Icons.*` 会渲染成方块）。
///
/// 路径从 `Platform.resolvedExecutable` 反推：测试跑在
/// `<flutter>/bin/cache/artifacts/engine/<platform>/flutter_tester(.exe)`，
/// 上溯 3 级即 `cache/`，图标字体在 `cache/artifacts/material_fonts/`。
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

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(
      jsonEncode({'code': 0, 'message': 'ok', 'data': null}),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}
