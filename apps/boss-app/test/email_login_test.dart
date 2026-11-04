import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/login_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端「邮箱验证码登录」（负责人 2026-10-10 邮箱能力）
///
/// 契约（读服务端源码得出，客户端只读不改）：
/// - `POST /auth/email/code` `{email, scene:'login'}` → `{ok, message}`；
///   **防枚举**：该邮箱未绑定任何账号时后端返回**逐字相同**的成功响应但不发信；
/// - `POST /auth/login` `{email, emailCode, role}`（**不带 username/password**，服务端 `@ValidateIf` 见到
///   email 即走邮箱路径）→ 与密码登录**同一份** `{accessToken, refreshToken, …}`；
///   失败统一中文 400「邮箱或验证码错误」。
///
/// 用例对照需求：
/// ⑨ 登录页方式切换（**默认账号密码**）；⑩ 邮箱码登录成功 → 走**既有落地流程**
/// （断言令牌写入 + 身份态刷新，而不是只看 UI）；⑪ 防枚举：服务端说"已发送"但该邮箱未绑定 →
/// 客户端提示与已绑定**逐字相同**。
///
/// ⑩ 为什么用 `ApiClient.debugDefaultDio`：`AuthStore.fetchMe()`（落地链路第 ③ 步）走的是 AuthStore
/// 内部那个 `ApiClient()`，页面注入的 `api` 传不进去 —— 这正是该调试钩子存在的理由
/// （见 `api_client.dart` 注释：端到端测身份/会话必须让内部客户端也走假通道）。
/// 本文件的假通道**只有一个实例**：页面注入的 Dio 与 debugDefaultDio 共用它，因此
/// `/auth/login`、`/auth/me`、`/auth/email/code` 的请求都记在同一份日志里。
void main() {
  // **必须在任何 AuthStore 静态访问之前**设好：AuthStore 单例内部的 ApiClient 在**构造时**固化 Dio。
  setUpAll(() {
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://login-email.local'))
      ..httpClientAdapter = api;
  });

  setUp(() {
    api.reset();
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    AuthStore.debugOnStorageWrite = null;
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: null);
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    AuthStore.debugOnStorageWrite = null;
    AppToast.dismiss();
  });

  // ------------------------------------------------------------ ⑨ 方式切换

  testWidgets('⑨ 登录页默认仍是「账号密码」；切到「邮箱验证码」后是邮箱 + 验证码两格', (tester) async {
    await pumpLogin(tester);

    // 默认：账号密码（不改变现有用户习惯）
    expect(find.text('账号密码'), findsOneWidget, reason: '方式切换的第一个 tab');
    expect(find.text('邮箱验证码'), findsOneWidget);
    expect(selected(tester, const Key('login-mode-password')), isTrue, reason: '默认选中「账号密码」');
    expect(selected(tester, const Key('login-mode-email')), isFalse);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.byKey(const Key('login-email-field')), findsNothing, reason: '默认不显示邮箱登录格');
    expect(find.byKey(const Key('login-code-field')), findsNothing);

    // 切到邮箱验证码
    await tester.tap(find.byKey(const Key('login-mode-email')));
    await tester.pumpAndSettle();
    expect(selected(tester, const Key('login-mode-email')), isTrue);
    expect(selected(tester, const Key('login-mode-password')), isFalse);
    expect(find.byKey(const Key('login-email-field')), findsOneWidget);
    expect(find.byKey(const Key('login-code-field')), findsOneWidget);
    expect(find.text('账号'), findsNothing, reason: '邮箱码登录不需要账号格');
    expect(find.text('密码'), findsNothing, reason: '邮箱码登录不需要密码格');
    expect(find.byKey(AppAuthCodeButton.buttonKey), findsOneWidget, reason: '验证码格右侧是「获取验证码」');

    // 切回账号密码：邮箱格消失，老流程原样
    await tester.tap(find.byKey(const Key('login-mode-password')));
    await tester.pumpAndSettle();
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.byKey(const Key('login-email-field')), findsNothing);
  });

  testWidgets('⑨ 注册态不显示方式切换（注册仍是账号密码 + 邮箱绑定老流程）', (tester) async {
    await pumpLogin(tester);
    await tester.tap(find.byKey(const Key('auth-switch-mode')));
    await tester.pumpAndSettle();

    expect(find.text('创建账号'), findsWidgets);
    expect(find.text('账号密码'), findsNothing, reason: '注册态没有登录方式切换');
    expect(find.byKey(const Key('register-email-field')), findsOneWidget, reason: '注册的老邮箱格仍在');
    expect(find.byKey(const Key('register-code-field')), findsOneWidget);
  });

  // ---------------------------------------------------- 取码（scene=login）

  testWidgets('邮箱码登录：取码 scene=login + 60 秒倒计时禁用 + 邮箱格式本地拦截', (tester) async {
    await pumpLogin(tester);
    await switchToEmailMode(tester);

    // 邮箱非法 → 不发请求
    await tester.enterText(find.byKey(const Key('login-email-field')), 'not-an-email');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('邮箱格式不正确'), findsWidgets);
    expect(api.paths, isEmpty, reason: '格式不合法 → 一个请求都不发');

    // 合法 → 取码 + 倒计时
    await tester.enterText(find.byKey(const Key('login-email-field')), 'boss_9527@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.bodyOf('/auth/email/code'), {'email': 'boss_9527@qq.com', 'scene': 'login'},
        reason: '场景必须是 login（与注册/找回/绑定各自独立计码）');
    expect(find.text('60s 后重发'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed, isNull,
        reason: '倒计时期间按钮禁用');

    // 倒计时中重复点无效
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey), warnIfMissed: false);
    await tester.pump();
    expect(api.countOf('/auth/email/code'), 1);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 3));
  });

  // ------------------------------------------------------------ ⑩ 落地流程

  testWidgets('⑩ 邮箱码登录成功 → 走**既有落地流程**：令牌写入安全存储 + /auth/me 刷新身份态', (tester) async {
    final writes = <String, String?>{};
    AuthStore.debugOnStorageWrite = (key, value) => writes[key] = value;

    await pumpLogin(tester);
    await switchToEmailMode(tester);

    await tester.enterText(find.byKey(const Key('login-email-field')), 'boss_9527@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byKey(const Key('login-code-field')), '135790');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();

    await tester.tap(find.byKey(const Key('auth-submit')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 请求体：只带 email + emailCode + role（不带 username/password）
    expect(api.paths, contains('/auth/login'));
    expect(
      api.bodyOf('/auth/login'),
      {'email': 'boss_9527@qq.com', 'emailCode': '135790', 'role': 'user'},
      reason: '服务端 DTO：传了 email 即走邮箱码路径，username/password 一并忽略 —— 客户端也不该伪造它们',
    );

    // ① 令牌真的落进了**既有**存储路径（_saveTokens → 安全存储）
    expect(writes['auth_access_token'], 'access-token-email',
        reason: '登录成功必须把 accessToken 写入既有安全存储（不是只弹个 toast）');
    expect(writes['auth_refresh_token'], 'refresh-token-email');
    expect(AuthStore.instance.accessToken, 'access-token-email');
    expect(AuthStore.instance.loggedIn, isTrue, reason: '身份态已建立 → RootGate 会切主框架');

    // ② 身份态刷新：既有的 GET /auth/me 被调用（AuthStore 内部客户端，走 debugDefaultDio）
    expect(api.paths, contains('/auth/me'), reason: '落地流程第 ③ 步：拉 /auth/me 刷新身份态');
    expect(AuthStore.instance.me?.uid, '10086', reason: '老板资料已就位（ID 来自 /auth/me）');
  });

  testWidgets('⑩ 邮箱码登录失败（400「邮箱或验证码错误」）→ 中文原文 + 不落地（令牌不写、不跳转）', (tester) async {
    final writes = <String, String?>{};
    AuthStore.debugOnStorageWrite = (key, value) => writes[key] = value;

    api.login = const {'code': 400, 'message': '邮箱或验证码错误', 'data': null};
    api.loginHttp = 400;
    await pumpLogin(tester);
    await switchToEmailMode(tester);

    await tester.enterText(find.byKey(const Key('login-email-field')), 'boss_9527@qq.com');
    await tester.enterText(find.byKey(const Key('login-code-field')), '000000');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('邮箱或验证码错误'), findsWidgets,
        reason: '服务端中文原文（防枚举：不区分"邮箱没绑账号"与"码不对"）');
    expect(find.byType(LoginPage), findsOneWidget, reason: '失败必须留在登录页');
    expect(writes['auth_access_token'], isNull, reason: '失败不得写令牌');
    expect(AuthStore.instance.loggedIn, isFalse);
  });

  // ------------------------------------------------------------ ⑪ 防枚举

  testWidgets('⑪ 防枚举：服务端「已发送」但该邮箱未绑定 → 客户端提示与已绑定**逐字相同**', (tester) async {
    // ① 已绑定：后端真发信
    api.emailBound = true;
    await pumpLogin(tester);
    await switchToEmailMode(tester);
    await tester.enterText(find.byKey(const Key('login-email-field')), 'boss_9527@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final boundHint = sentHintText(tester);
    final boundBody = api.lastCodeResponse;
    expect(api.mailSent, isTrue, reason: '已绑定 → 后端确实发信');
    expect(boundHint, isNotEmpty, reason: '取码成功必须有提示');
    await tester.pump(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 3));
    expect(sentHintText(tester), isEmpty, reason: '提示已自动消失（否则下面比的是同一块浮层）');

    // ② 未绑定：后端**逐字相同**的成功响应，但事实上没有发信（服务端防枚举策略）
    api.reset();
    api.emailBound = false;
    await pumpLogin(tester);
    await switchToEmailMode(tester);
    await tester.enterText(find.byKey(const Key('login-email-field')), 'never_bound@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final unboundHint = sentHintText(tester);

    expect(api.mailSent, isFalse, reason: '未绑定 → 后端按防枚举策略不发信（响应仍逐字相同）');
    expect(api.lastCodeResponse, boundBody, reason: '两种情况下服务端响应逐字相同（防枚举的前提）');
    expect(unboundHint, boundHint, reason: '客户端提示必须与已绑定**逐字相同**（不得泄露邮箱是否已绑定）');
    expect(unboundHint, emailCodeSentHint(EmailCodeScene.login));
    for (final leak in const ['未注册', '未绑定', '不存在', '该邮箱没有']) {
      expect(find.textContaining(leak), findsNothing, reason: '防枚举：界面不得出现「$leak」式断言');
    }
    await tester.pump(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 3));
  });
}

// ------------------------------------------------------------------ 工具

/// 取当前屏上「验证码已发送…」那条提示的**逐字文本**（AppToast 渲染在 Overlay 里）
String sentHintText(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data ?? '';
    if (data.contains('验证码已发送')) return data;
  }
  return '';
}

/// 读取分段按钮的选中态（Semantics.selected，不依赖颜色/私有 State）
bool selected(WidgetTester tester, Key key) {
  for (final w in find.ancestor(of: find.byKey(key), matching: find.byType(Semantics)).evaluate()) {
    final s = w.widget;
    if (s is Semantics && s.properties.selected != null) return s.properties.selected!;
  }
  return false;
}

Future<void> pumpLogin(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  AuthStore.instance
    ..debugClearIdentity()
    ..debugSetSession(accessToken: null);
  await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: _dio(api)))));
  await tester.pumpAndSettle();
}

Future<void> switchToEmailMode(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('login-mode-email')));
  await tester.pumpAndSettle();
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter;

/// 登录页注入的实例与 AuthStore 内部实例（debugDefaultDio）**共用同一个** [FakeApi]
final FakeApi api = FakeApi.instance;

/// 记录请求的假 API（`/auth/login`、`/auth/me`、`/auth/email/code`）
class FakeApi implements HttpClientAdapter {
  FakeApi._();

  static final FakeApi instance = FakeApi._();

  static const Map<String, dynamic> _defaultLogin = {
    'code': 0,
    'message': 'ok',
    'data': {
      'accessToken': 'access-token-email',
      'refreshToken': 'refresh-token-email',
      'user': {'id': 'u1', 'username': 'boss_9527', 'role': 'user'},
    },
  };

  /// 该邮箱是否已绑定账号（服务端**两种情况下响应逐字相同**，只有"真发信 / 不发信"的差别）
  bool emailBound = true;

  Map<String, dynamic> login = _defaultLogin;
  int loginHttp = 200;

  /// 本轮是否真的"发了信"（防枚举断言用：未绑定 → false）
  bool mailSent = false;

  /// `/auth/email/code` **实际回给客户端的响应体**（请求体在 [_bodies] 里，两者不能混）
  Map<String, dynamic> lastCodeResponse = const {};

  final List<String> paths = [];
  final List<String> _methods = [];
  final List<Map<String, dynamic>> _bodies = [];

  int countOf(String path) => paths.where((p) => p == path).length;

  Map<String, dynamic> bodyOf(String path) {
    final i = paths.indexOf(path);
    return i < 0 ? const {} : _bodies[i];
  }

  void reset() {
    paths.clear();
    _methods.clear();
    _bodies.clear();
    mailSent = false;
    emailBound = true;
    login = _defaultLogin;
    loginHttp = 200;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    _methods.add(options.method);
    _bodies.add(options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{});

    var code = 200;
    Map<String, dynamic> body = const {'code': 0, 'message': 'ok', 'data': null};
    if (options.path == '/auth/email/code') {
      // 防枚举口径：**无论该邮箱有没有绑定账号，响应体逐字相同**
      mailSent = emailBound;
      body = const {
        'code': 0,
        'message': 'ok',
        'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
      };
      lastCodeResponse = body;
    } else if (options.path == '/auth/login') {
      code = loginHttp;
      body = login;
    } else if (options.path == '/auth/me') {
      body = const {
        'code': 0,
        'message': 'ok',
        'data': {
          'id': 'u1',
          'username': 'boss_9527',
          'uid': '10086',
          'nickname': '老板',
          'role': 'user',
          'level': 3,
          'totalSpent': 0,
        },
      };
    }
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
