import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/login_page.dart';
import 'package:boss_app/pages/settings_page.dart';
import 'package:boss_app/widgets/fish_glass.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';

/// 邮箱能力出图（负责人 2026-10-10 验收对照用）
///
/// 产出（`apps/boss-app/build/`，由本批脚本复制到 `docs/验收素材/2026-10-10-邮箱/`）：
/// - `email_1_settings_unbound.png`  设置页邮箱行 · **未绑定**
/// - `email_2_settings_bound.png`    设置页邮箱行 · **已绑定（脱敏 + 已验证）**
/// - `email_3_bind_countdown.png`    绑定页 · 含**倒计时中**状态（`60s 后重发`）
/// - `email_4_login_modes.png`       登录页两种方式对照（账号密码 / 邮箱验证码）
/// - `email_5_bind_error.png`        校验失败中文提示（服务端原文落行内红字 + 汇总条）
///
/// 不是 golden 比对，而是：① 渲染烟雾测试（溢出/异常会在这里抛出来）；
/// ② 给负责人看真实像素的证据文件。字体处理与 `auth_email_visual_test.dart` 完全一致：
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
    AuthStore.debugStorageDisabled = true;
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: 'shot-token');
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    AppToast.dismiss();
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

  // ---------------------------------------------------- ①② 设置页两态

  testWidgets('① 设置页邮箱行 · 未绑定', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(SettingsPage(api: ApiClient(dio: _fakeDio(_Adapter())))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('未绑定'), findsOneWidget);
    expect(find.text('绑定'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'email_1_settings_unbound');
  });

  testWidgets('② 设置页邮箱行 · 已绑定（脱敏 + 已验证 + 更换）', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(SettingsPage(api: ApiClient(dio: _fakeDio(_Adapter(bound: true))))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('ab***@qq.com'), findsOneWidget);
    expect(find.text('已验证'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'email_2_settings_bound');
  });

  // ---------------------------------------------------- ③ 绑定页倒计时中

  testWidgets('③ 绑定页（含倒计时中状态）', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(SettingsPage(api: ApiClient(dio: _fakeDio(_Adapter())))),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-email-row')));
    await tester.pumpAndSettle();
    expect(find.text('绑定邮箱'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('email-bind-email-field')), 'player_9527@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('60s 后重发'), findsOneWidget, reason: '图要展示"倒计时中"的按钮态');

    // 关掉取码成功的浮层提示（图要干净）+ 等按钮配色过渡走完（抄 auth_email_visual_test 的踩坑注记）
    AppToast.dismiss();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      DefaultTextStyle.of(tester.element(find.text('60s 后重发'))).style.color,
      AppColors.textTertiary,
      reason: '倒计时中按钮必须是禁用灰（PNG 里的颜色是终态）',
    );
    await tester.enterText(find.byKey(const Key('email-bind-code-field')), '246810');
    FocusManager.instance.primaryFocus?.unfocus();
    // 【**不要用 pumpAndSettle**】倒计时每秒 notifyListeners → 每次都排一帧，
    // pumpAndSettle 会一直把假时钟推到倒计时结束（截图就变成"可点态"了）。有界 pump 即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('60s 后重发'), findsOneWidget, reason: '截图时倒计时仍在进行');

    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'email_3_bind_countdown');
    await tester.pump(const Duration(seconds: 60)); // 排空倒计时
  });

  // ---------------------------------------------------- ④ 登录页两种方式

  testWidgets('④ 登录页两种方式对照（账号密码 / 邮箱验证码）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final dio = _fakeDio(_Adapter());

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, fontFamily: _appFontFamily),
        home: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: Row(
            children: [
              Expanded(child: shell(LoginPage(api: ApiClient(dio: dio)))),
              Container(width: 1, color: const Color(0xFFE5E9F0)),
              Expanded(child: shell(LoginPage(api: ApiClient(dio: dio)))),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 右半边切到邮箱验证码：同一棵树上两份 LoginPage，按文本定位第 2 个切换按钮
    final emailTabs = find.byKey(const Key('login-mode-email'));
    expect(emailTabs, findsNWidgets(2));
    await tester.tap(emailTabs.at(1));
    await tester.pumpAndSettle();

    // 右半边填一行邮箱 + 取码（展示倒计时），左半边保持默认账号密码
    final emailFields = find.byKey(const Key('login-email-field'));
    expect(emailFields, findsOneWidget, reason: '只有右半边处于邮箱验证码方式');
    await tester.enterText(emailFields, 'player_9527@qq.com');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(find.text('账号密码'), findsNWidgets(2));
    expect(find.text('邮箱验证码'), findsNWidgets(2));
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'email_4_login_modes');
  });

  // ---------------------------------------------------- ⑤ 校验失败中文提示

  testWidgets('⑤ 校验失败中文提示（服务端原文：该邮箱已被其他账号绑定）', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: shell(SettingsPage(api: ApiClient(dio: _fakeDio(_Adapter(bindTaken: true))))),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-email-row')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('email-bind-email-field')), 'taken_mail@qq.com');
    await tester.enterText(find.byKey(const Key('email-bind-code-field')), '246810');
    await tester.enterText(find.byKey(const Key('email-bind-password-field')), 'pass1234');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('email-bind-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('email-bind-submit')));
    await tester.pumpAndSettle();

    expect(find.text('该邮箱已被其他账号绑定'), findsWidgets, reason: '服务端中文原文必须原样出现在行内红字/汇总条');
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    await capture(tester, 'email_5_bind_error');
  });
}

/// 与 main.dart 同构的壳（MiuixSystemTheme → MaterialApp → FishGlassBackdrop），
/// 与既有登录/找回密码出图保持一致，方便并排比对。
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

/// 固定响应（测试环境不联网）
Dio _fakeDio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter;

/// 假数据注入：未绑定 / 已绑定 / 取码成功 / 绑定成功 / 邮箱已被占用
class _Adapter implements HttpClientAdapter {
  _Adapter({this.bound = false, this.bindTaken = false});

  final bool bound;
  final bool bindTaken;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    var code = 200;
    Map<String, dynamic> body = const {'code': 0, 'message': 'ok', 'data': null};
    if (options.path == '/user/email') {
      body = {
        'code': 0,
        'message': 'ok',
        'data': {
          'bound': bound,
          'email': bound ? 'ab***@qq.com' : null,
          'verified': bound,
          'verifiedAt': bound ? '2026-10-10T00:00:00.000Z' : null,
        },
      };
    } else if (options.path == '/auth/email/code') {
      body = const {
        'code': 0,
        'message': 'ok',
        'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
      };
    } else if (options.path == '/user/email/bind') {
      if (bindTaken) {
        code = 409;
        body = const {'code': 409, 'message': '该邮箱已被其他账号绑定', 'data': null};
      } else {
        body = const {
          'code': 0,
          'message': 'ok',
          'data': {
            'ok': true,
            'email': 'pl***@qq.com',
            'emailVerified': true,
            'rebound': false,
            'message': '邮箱绑定成功',
          },
        };
      }
    }
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
