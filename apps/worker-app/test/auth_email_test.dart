import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/forgot_password_page.dart';
import 'package:worker_app/pages/login_page.dart';

/// 工作端「找回密码」全链路（负责人 2026-10-05）
///
/// 工作账号**没有注册入口**（管理员创建），所以本端只覆盖找回密码：
/// 1. 登录页「忘记密码」→ 打开找回页（真流程）；
/// 2. 发码：`POST /auth/email/code`，**scene=reset**，按钮 60 秒倒计时禁用；
/// 3. 提交：`POST /auth/password/reset`（email + emailCode + newPassword）→ 成功提示 → 回登录页；
/// 4. **防枚举**：未绑定邮箱时后端也返回成功 → 界面一律「若该邮箱已绑定，验证码已发送」，
///    **不得**出现「邮箱不存在/未注册」；
/// 5. 邮箱/验证码/密码的本地校验（不合法不发请求）+ 后端中文错误落行内红字。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  testWidgets('工作端也走同一份找回页（品牌头 + 邮箱/验证码/两个密码格/重置按钮）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    expect(find.byType(ForgotPasswordPage), findsOneWidget);
    expect(find.text('找回密码'), findsWidgets);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);
    expect(find.text('新密码'), findsOneWidget);
    expect(find.text('确认新密码'), findsOneWidget);
    expect(find.byKey(const Key('forgot-submit')), findsOneWidget);
    expect(find.byKey(AppAuthCodeButton.buttonKey), findsOneWidget);
    expect(find.byType(AppQishanMark), findsOneWidget, reason: '与登录页同款方案 B 品牌主视觉');
    // 工作端脚注说明"需已绑定邮箱"，但**不得**断言邮箱是否存在
    expect(find.textContaining('需已绑定邮箱'), findsOneWidget);
    expect(adapter.requests, isEmpty, reason: '只打开页面不发请求');
  });

  testWidgets('工作端找回全流程：发码（scene=reset，60 秒倒计时）→ 提交 → 成功提示 → 回登录页清空密码', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    // 登录页先填个密码，验证重置成功后密码框被清空
    await tester.enterText(find.byType(TextField).at(0), 'worker01');
    await tester.enterText(find.byType(TextField).at(1), 'oldpassword');
    await tester.pump();

    await openForgot(tester);

    // ① 发码
    await tester.enterText(find.byType(TextField).at(0), 'worker01@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.methodFor('/auth/email/code'), 'POST');
    expect(
      adapter.bodyFor('/auth/email/code'),
      {'email': 'worker01@qq.com', 'scene': 'reset'},
      reason: '工作端找回密码场景同样是 reset',
    );
    expect(find.text('60s 后重发'), findsOneWidget, reason: '工作端也有 60 秒倒计时');
    expect(tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed, isNull,
        reason: '倒计时期间禁用');
    expect(find.text(emailCodeSentHint(EmailCodeScene.reset)), findsOneWidget);
    expect(emailCodeSentHint(EmailCodeScene.reset), contains('若该邮箱已绑定'),
        reason: '未绑定邮箱的账号收不到信，文案必须防枚举');

    // ② 提交新密码
    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword1');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();

    expect(adapter.requests, contains('/auth/password/reset'));
    expect(adapter.methodFor('/auth/password/reset'), 'POST');
    expect(adapter.bodyFor('/auth/password/reset'), {
      'email': 'worker01@qq.com',
      'emailCode': '246810',
      'newPassword': 'newpassword1',
    });

    // ③ 回登录页 + 成功提示 + 密码框清空（账号保留）
    expect(find.byType(ForgotPasswordPage), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('密码已重置，请用新密码登录'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text, 'worker01');

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('防枚举：未绑定邮箱也是「若该邮箱已绑定」；页面不得出现「不存在/未注册」', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    // 后端对未绑定邮箱返回与成功完全一致的响应（防枚举设计）
    await tester.enterText(find.byType(TextField).at(0), 'never-bound@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(emailCodeSentHint(EmailCodeScene.reset)), findsOneWidget);
    for (final leak in const ['邮箱不存在', '未注册', '该邮箱没有']) {
      expect(find.textContaining(leak), findsNothing, reason: '防枚举：不得出现「$leak」');
    }
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('找回密码：邮箱格式错误 → 不发请求 + 行内中文提示', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    await tester.enterText(find.byType(TextField).at(0), 'worker01@qq');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();

    expect(find.text('邮箱格式不正确'), findsWidgets, reason: '行内红字 + 汇总条');
    expect(adapter.requests, isEmpty, reason: '邮箱格式不合法一律不发请求');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('找回密码：验证码 6 位数字 + 两次新密码一致（本地校验不过不发请求）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    await tester.enterText(find.byType(TextField).at(0), 'worker01@qq.com');
    await tester.enterText(find.byType(TextField).at(1), '12345'); // 5 位
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword1');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();
    expect(find.text('验证码为 6 位数字'), findsWidgets);
    expect(adapter.requests, isEmpty);

    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword2');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();
    expect(find.text('两次输入的密码不一致'), findsWidgets);
    expect(adapter.requests, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('找回密码：后端「验证码错误」→ 验证码字段行内红字（无 fields[] 也要能定位）', (tester) async {
    final adapter = FakeApiRecorder(
      emailCodeBody: _okSendBody,
      resetStatus: 400,
      resetBody: const {'code': 400, 'message': '验证码错误', 'data': null},
    );
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    await tester.enterText(find.byType(TextField).at(0), 'worker01@qq.com');
    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword1');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();

    expect(find.text('验证码错误'), findsWidgets);
    expect(find.byType(AppFieldError), findsWidgets, reason: '必须落行内红字');
    expect(summaryText(tester), contains('邮箱验证码还需修改'), reason: summaryText(tester));
    expect(find.byType(ForgotPasswordPage), findsOneWidget, reason: '失败留在原页');
    await tester.pump(const Duration(seconds: 3));
  });
}

// ------------------------------------------------------------------ 工具

const Map<String, dynamic> _okSendBody = {
  'code': 0,
  'message': 'ok',
  'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
};

Future<void> pumpLogin(WidgetTester tester, FakeApiRecorder adapter) async {
  // 真实手机视口（默认 800×600 太矮，找回页 4 格 + 按钮会超出视口导致点击落空）
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: fakeDio(adapter)))));
  await tester.pumpAndSettle();
}

Future<void> tapAt(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> openForgot(WidgetTester tester) async {
  await tapAt(tester, find.text('忘记密码'));
  await tester.pumpAndSettle();
}

String summaryText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byType(AppFormErrorSummary), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join(' | ');

Dio fakeDio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter;

/// 记录请求的假 API（工作端只用到取码与重置密码两个接口）
class FakeApiRecorder implements HttpClientAdapter {
  FakeApiRecorder({
    this.emailCodeStatus = 200,
    this.emailCodeBody = _okSendBody,
    this.resetStatus = 200,
    this.resetBody = const {
      'code': 0,
      'message': 'ok',
      'data': {'ok': true, 'message': '密码已重置，请使用新密码登录'},
    },
  });

  final int emailCodeStatus;
  final Map<String, dynamic> emailCodeBody;
  final int resetStatus;
  final Map<String, dynamic> resetBody;

  final List<String> requests = [];
  final List<String> methods = [];
  final List<Map<String, dynamic>> bodies = [];

  String methodFor(String path) {
    final i = requests.indexOf(path);
    return i < 0 ? '' : methods[i];
  }

  Map<String, dynamic> bodyFor(String path) {
    final i = requests.indexOf(path);
    return i < 0 ? const {} : bodies[i];
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.path);
    methods.add(options.method);
    bodies.add(options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{});

    var status = 200;
    Map<String, dynamic> body = const {'code': 0, 'message': 'ok', 'data': null};
    if (options.path.contains('/auth/email/code')) {
      status = emailCodeStatus;
      body = emailCodeBody;
    } else if (options.path.contains('/auth/password/reset')) {
      status = resetStatus;
      body = resetBody;
    }
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
