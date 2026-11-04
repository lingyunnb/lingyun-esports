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

/// 邮箱通道出图（负责人 2026-10-05 对照验收用）
///
/// 产出（`apps/boss-app/build/`）：
/// - `auth_email_register.png`     老板端注册页 · 邮箱 + 验证码 + **倒计时中**（`60s 后重发`）
/// - `auth_email_forgot.png`       找回密码页（登录页「忘记密码」进入的真流程）
/// - `auth_email_code_states.png`  「获取验证码」三态特写（可点 / 发送中 / 倒计时禁用）
///
/// 不是 golden 比对，而是：① 渲染烟雾测试（溢出/异常会在这里抛出来）；
/// ② 给负责人看真实像素的证据文件。字体处理与 `auth_visual_test.dart` 完全一致：
/// `flutter test` 不加载 pubspec 字体资源，先手工把 **MiSans（中文字体）** 与
/// MaterialIcons 挂进字体表，PNG 才是中文而不是 Ahem 方块（不改 App 任何字体设置）。
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

  Future<void> phoneSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  Future<void> capture(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('老板端注册页 · 邮箱+验证码+倒计时出图', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(LoginPage(api: ApiClient(dio: _fakeDio()))),
    ));
    await tester.pumpAndSettle();

    // 切到注册（页脚稳定 Key）
    await tester.tap(find.byKey(const Key('auth-switch-mode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('register-email-field')), findsOneWidget);
    expect(find.byKey(const Key('register-code-field')), findsOneWidget);

    // 填邮箱 → 取码成功 → 进入 60 秒倒计时（这张图要展示"倒计时中"的按钮）
    // 注意：**不要用 ensureVisible** —— 它会把目标滚到视口顶部（品牌区被顶出去），
    // 出图必须保持滚动位为 0（整页在 390×844 内本来就能放下）
    await tester.enterText(find.byKey(const Key('register-email-field')), 'player_9527@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('60s 后重发'), findsOneWidget);

    // 关掉取码成功的浮层提示，避免遮挡品牌区（图要干净）
    AppToast.dismiss();
    // **必须等按钮配色过渡动画走完再截图**：`ButtonStyleButton` 用
    // `AnimatedDefaultTextStyle` 把「可点主色 → 禁用灰」lerp 了 200ms，
    // 抢在中间截图会得到半蓝半灰的假颜色（实测 50ms 时是 (65,115,222)，
    // 既不是主色 #2563EB 也不是禁用灰 #94A3B8 —— 出图自查就是这么发现的）
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      DefaultTextStyle.of(tester.element(find.text('60s 后重发'))).style.color,
      AppColors.textTertiary,
      reason: '倒计时中按钮必须是禁用灰（提示动画已结束，PNG 里的颜色是终态）',
    );

    expect(
      tester.getTopLeft(find.byType(AppBrandHeader)).dy,
      0,
      reason: '品牌区必须完整在画面内（滚动位为 0），否则出图会缺「祁连山电竞」品牌行',
    );
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'auth_email_register');
  });

  testWidgets('找回密码页出图（登录页「忘记密码」进入）', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(LoginPage(api: ApiClient(dio: _fakeDio()))),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();

    expect(find.text('找回密码'), findsWidgets);
    expect(find.byKey(const Key('forgot-submit')), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'player_9527@qq.com');
    await tester.pump();
    // 焦点态下截图会带键盘外的实际渲染，这里先收掉焦点让画面干净
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'auth_email_forgot');
  });

  testWidgets('「获取验证码」三态特写出图（可点 / 发送中 / 倒计时禁用）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 300 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final idle = EmailCodeCountdown();
    final sending = EmailCodeCountdown()..beginSend();
    final counting = EmailCodeCountdown()..start();
    addTearDown(idle.dispose);
    addTearDown(sending.dispose);
    addTearDown(counting.dispose);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: _appFontFamily),
        home: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: Center(
            child: Container(
              width: 342,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppAuthRadius.card),
                border: Border.all(color: const Color(0xFFE5E9F0)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('「获取验证码」三态（邮箱验证码）',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF14202E))),
                  const SizedBox(height: 14),
                  _stateRow('① 可点', AppAuthCodeButton(countdown: idle, onPressed: () {})),
                  const SizedBox(height: 12),
                  _stateRow('② 请求中（禁用）', AppAuthCodeButton(countdown: sending, onPressed: () {})),
                  const SizedBox(height: 12),
                  _stateRow('③ 倒计时中（禁用）', AppAuthCodeButton(countdown: counting, onPressed: () {})),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('获取验证码'), findsOneWidget, reason: '① 可点态');
    expect(find.text('发送中…'), findsOneWidget, reason: '② 请求中');
    expect(find.text('60s 后重发'), findsOneWidget, reason: '③ 倒计时首帧');
    expect(tester.takeException(), isNull);

    await capture(tester, 'auth_email_code_states', ratio: 3);
    counting.reset();
    await tester.pump();
  });
}

/// 与 main.dart 同构的壳（MiuixSystemTheme → MaterialApp → FishGlassBackdrop），
/// 与 `auth_visual_test.dart` 保持一致，方便与既有登录页出图并排比对。
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

Widget _stateRow(String label, Widget button) => Row(
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
        ),
        const SizedBox(width: 8),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: button)),
      ],
    );

const String _appFontFamily = 'MiSans';

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

/// 固定响应（测试环境不联网）：取码/注册都成功
Dio _fakeDio() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter();
  return dio;
}

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = options.path.contains('/auth/email/code')
        ? {
            'code': 0,
            'message': 'ok',
            'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
          }
        : {'code': 0, 'message': 'ok', 'data': null};
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
