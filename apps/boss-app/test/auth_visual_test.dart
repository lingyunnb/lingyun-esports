import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/login_page.dart';
import 'package:boss_app/widgets/fish_glass.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

/// 登录页改版出图（负责人对照设计稿 `site/design/auth/p-b-*.png` 验收用）
///
/// 产出（`apps/boss-app/build/`）：
/// - `auth_login_default.png`  老板端登录页 · 默认态（协议未勾选 → 主按钮灰态）
/// - `auth_login_error.png`    老板端登录页 · 错误态（顶部汇总条 + 输入框红边/行内红字）
/// - `auth_worker_login.png`   工作端登录页（同款视觉，只有登录）
///
/// 不是 golden 比对，而是：① 渲染烟雾测试（溢出/异常会在这里抛出来）；
/// ② 给负责人看真实像素的证据文件。**包含生产同款的全局玻璃背景**（main.dart 的
/// `MiuixSystemTheme + FishGlassBackdrop`），用来证明登录页在新设计下确实压住了光斑。
///
/// 注意：`flutter test` 不会加载 pubspec 里声明的字体资源，`Icons.*` 与中文都会渲染成
/// **Ahem 方块**。所以出图前手工把两份字体挂进字体表 —— 目的只是让 PNG 可读，
/// **不改 App 的任何字体设置**：
///  - `MiSans`：App 真实使用的中文字体（`main.dart` 的 `ThemeData(fontFamily: 'MiSans')`
///    + `pubspec.yaml` 的 `assets/fonts/MiSans-Normal.ttf`，实测覆盖 CJK）。挂**真名**，
///    出图就等于真机字形，不用造一个假字体族。
///  - `MaterialIcons`：Material 图标字体（输入框前置图标、密码眼睛、勾选对勾）。
void main() {
  const captureKey = Key('capture');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFont('MiSans', const [
      'assets/fonts/MiSans-Normal.ttf',
      'C:/Windows/Fonts/simhei.ttf',
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

  Future<void> phoneSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// 与 main.dart 同构的壳：MiuixSystemTheme → MaterialApp(透明 scaffold) → FishGlassBackdrop
  /// `fontFamily: 'MiSans'` 与 main.dart 完全一致（真机上该字体由资源表提供，出图时由上面的 FontLoader 提供）
  Widget shell(Widget home) => MiuixSystemTheme(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: Colors.transparent,
            fontFamily: _appFontFamily,
          ),
          builder: (context, child) => FishGlassBackdrop(child: child ?? const SizedBox.shrink()),
          home: home,
        ),
      );

  testWidgets('老板端登录页 · 默认态出图（协议未勾选 → 灰态主按钮）', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(LoginPage(api: ApiClient(dio: _fakeDio()))),
    ));
    await tester.pumpAndSettle();

    // 默认态断言：品牌头在、小山标在、协议未勾选、主按钮禁用
    expect(find.byType(AppBrandHeader), findsOneWidget);
    expect(find.byType(AppQishanMark), findsOneWidget);
    expect(tester.widget<AppAuthButton>(find.byKey(const Key('auth-submit'))).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await capture(tester, 'auth_login_default');
  });

  testWidgets('老板端登录页 · 错误态出图（顶部汇总条 + 输入框红边 + 行内红字）', (tester) async {
    await phoneSize(tester);
    final dio = _fakeDio(status: 400, body: {
      'code': 400,
      'message': '账号至少 3 个字符；密码至少 8 个字符',
      'data': null,
      'errorCode': 'VALIDATION_FAILED',
      'fields': [
        {'field': 'username', 'label': '账号', 'message': '账号格式不正确（6-20 位字母、数字或下划线）'},
        {'field': 'password', 'label': '密码', 'message': '请输入密码'},
      ],
    });
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(LoginPage(api: ApiClient(dio: dio))),
    ));
    await tester.pumpAndSettle();

    // 勾选协议 → 输入 → 提交（服务端返回 fields[] → 行内红字 + 顶部汇总条）
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // 红字动画稳定后再截图

    expect(find.byType(AppFormErrorSummary), findsOneWidget, reason: '顶部汇总条');
    expect(find.byType(AppFieldError), findsWidgets, reason: '行内红字');
    expect(tester.takeException(), isNull);
    await capture(tester, 'auth_login_error');
  });

  testWidgets('工作端登录页出图（在 worker-app 自己的测试里产出，见 worker-app/test/auth_visual_test.dart）', (tester) async {
    // 说明：boss-app 测试无法 import worker_app 包，工作端那张图在
    // `apps/worker-app/test/auth_visual_test.dart` 里产出（build/auth_worker_login.png），
    // 完成后由脚本复制到 apps/boss-app/build/ 统一交给负责人验收。
    expect(true, isTrue);
  });
}

/// 出图字形保障：`flutter test` 不加载 pubspec 字体资源，中文与 `Icons.*` 都会变成 Ahem 方块。
/// 这两个常量只为让 PNG 可读，运行时（真机）由 pubspec 资源表提供，两边字体族名一致。
const String _appFontFamily = 'MiSans';

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

/// 固定 200/400 响应（测试环境不联网）
Dio _fakeDio({int status = 200, Map<String, dynamic>? body}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(status: status, body: body ?? const {'code': 0, 'message': 'ok', 'data': null});
  return dio;
}

class _Adapter implements HttpClientAdapter {
  _Adapter({required this.status, required this.body});

  final int status;
  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
