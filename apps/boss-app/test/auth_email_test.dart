import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/forgot_password_page.dart';
import 'package:boss_app/pages/login_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端「邮箱验证码」全链路（负责人 2026-10-05）：
/// ① 注册加邮箱+验证码；② 忘记密码真流程。
///
/// 对照需求逐条覆盖：
/// 1. 邮箱格式错误 → **不发请求** + 中文提示（行内红字）；
/// 2. 点「获取验证码」→ 请求发出（`POST /auth/email/code`，scene=register）
///    且按钮进入 **60 秒倒计时**并禁用（`60s 后重发` → 下一秒 `59s 后重发`）；
/// 3. 提交注册 → 请求体含 `email` + `emailCode`；
/// 4. 后端返回「验证码错误」（**无 fields[]** 的纯中文业务错误）→ 落在**验证码字段的行内红字**；
/// 5. 忘记密码全流程：发码（scene=reset）→ 提交 → 成功提示 → 返回登录页 + 密码框已清空；
/// 6. 未绑定邮箱时提示文案是「若该邮箱已绑定…」（**不得**暴露邮箱是否存在）；
/// 7. 回归：不填邮箱的旧注册路径请求体不变（在 core 侧断言，见
///    `apps/packages/core/test/email_auth_test.dart`）；此处补一条"必填开关打开时注册页不填邮箱被本地拦下"。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  // ------------------------------------------------------------ 注册：字段

  testWidgets('注册模式：新增「邮箱」+「验证码」两格，验证码格内右侧是「获取验证码」', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);

    expect(find.byKey(const Key('register-email-field')), findsOneWidget);
    expect(find.byKey(const Key('register-code-field')), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget, reason: '验证码格标签');
    expect(find.byKey(AppAuthCodeButton.buttonKey), findsOneWidget, reason: '验证码格右侧的「获取验证码」按钮');
    expect(find.text('获取验证码'), findsOneWidget);
    expect(find.text('昵称（可选）'), findsOneWidget, reason: '昵称仍在（可选字段放最后）');

    // 邮箱格是 email 键盘；验证码格只收数字（digitsOnly）且限 6 位
    final emailField = tester.widget<TextField>(find.descendant(
      of: find.byKey(const Key('register-email-field')),
      matching: find.byType(TextField),
    ));
    expect(emailField.keyboardType, TextInputType.emailAddress);

    final codeFinder = find.descendant(
      of: find.byKey(const Key('register-code-field')),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(codeFinder).keyboardType, TextInputType.number);
    expect(tester.widget<TextField>(codeFinder).maxLength, kEmailCodeLength);

    // 数字过滤：输入字母被吞掉，只留数字（上限 6 位）
    await tester.enterText(find.byKey(const Key('register-code-field')), 'abc123456789');
    await tester.pump();
    expect(
      tester.widget<TextField>(codeFinder).controller!.text,
      '123456',
      reason: '验证码只保留 6 位数字',
    );
  });

  // ------------------------------------------------- 注册：邮箱格式本地拦截

  testWidgets('邮箱格式错误 → **不发任何请求** + 行内中文提示「邮箱格式不正确」', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);
    await agree(tester);

    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.enterText(find.byKey(const Key('register-email-field')), 'not-an-email');
    await tester.enterText(find.byKey(const Key('register-code-field')), '123456');
    await submitRegister(tester);
    await tester.pumpAndSettle();

    expect(find.text('邮箱格式不正确'), findsWidgets, reason: '行内红字 + 汇总条');
    expect(adapter.requests, isEmpty, reason: '本地校验不过：一个请求都不许发（含取码与注册）');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('不填邮箱（必填开关打开）→ 本地拦下、不发请求；不填验证码 → 也本地拦下', (tester) async {
    expect(
      kRegisterEmailRequired,
      isTrue,
      reason: '本端默认要求注册填邮箱：邮箱是唯一的找回密码通道。若因邮件通道故障需要放开注册，'
          '把 core 的 kRegisterEmailRequired 改成 false 即可（页面与接口一行都不用动）',
    );

    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);
    await agree(tester);

    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await submitRegister(tester);
    await tester.pumpAndSettle();

    expect(find.text('请输入邮箱'), findsWidgets);
    expect(adapter.requests, isEmpty);

    // 填了邮箱但不填验证码 → 同样本地拦下（后端在传了 email 时强制验码）
    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await submitRegister(tester);
    await tester.pumpAndSettle();
    expect(find.text('请输入验证码'), findsWidgets);
    expect(adapter.requests, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('取码：邮箱为空/不合法 → 一个请求都不发（只标红）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);

    // 空邮箱
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('请输入邮箱'), findsWidgets);
    expect(adapter.requests, isEmpty);

    // 非法邮箱
    await tester.enterText(find.byKey(const Key('register-email-field')), 'qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('邮箱格式不正确'), findsWidgets);
    expect(adapter.requests, isEmpty, reason: '邮箱格式不合法时不得发取码请求');
    await tester.pump(const Duration(seconds: 1));
  });

  // ------------------------------------------------------- 注册：取码倒计时

  testWidgets('点获取验证码 → 请求发出 + 按钮进入 60 秒倒计时且禁用（60s → 59s）', (tester) async {
    final adapter = FakeApiRecorder(emailCodeBody: _okSendBody);
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);

    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump(); // 发出请求
    await tester.pump(const Duration(milliseconds: 50)); // 响应回来 → 进入倒计时

    expect(adapter.requests, contains('/auth/email/code'), reason: '取码请求必须发出去');
    expect(adapter.methodFor('/auth/email/code'), 'POST');
    expect(
      adapter.bodyFor('/auth/email/code'),
      {'email': '3989032755@qq.com', 'scene': 'register'},
      reason: '场景必须是 register（与找回密码的 reset 分开计码）',
    );

    expect(find.text('60s 后重发'), findsOneWidget, reason: '成功后立刻进入 60 秒倒计时');
    expect(
      tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed,
      isNull,
      reason: '倒计时期间按钮必须禁用（点不动、发不出第二个请求）',
    );

    // 倒计时期间再点：不再发请求
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey), warnIfMissed: false);
    await tester.pump();
    expect(adapter.countOf('/auth/email/code'), 1, reason: '倒计时期间不得重复发码');

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('59s 后重发'), findsOneWidget, reason: '每秒递减');

    await tester.pump(const Duration(seconds: 59));
    expect(find.text('获取验证码'), findsOneWidget, reason: '60 秒后按钮恢复可点');
    expect(tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('取码成功提示：注册场景明说「验证码已发送至邮箱」', (tester) async {
    final adapter = FakeApiRecorder(emailCodeBody: _okSendBody);
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);

    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text(emailCodeSentHint(EmailCodeScene.register)), findsOneWidget);
    // 排空 toast 定时器 + 倒计时
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('取码失败（邮件发送失败）→ **不进入倒计时**，按钮仍可点 + 红字落验证码字段', (tester) async {
    final adapter = FakeApiRecorder(
      emailCodeStatus: 400,
      emailCodeBody: const {'code': 400, 'message': '邮件发送失败，请稍后重试', 'data': null},
    );
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);

    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('邮件发送失败，请稍后重试'), findsWidgets, reason: '中文错误落到验证码字段行内红字');
    expect(find.text('获取验证码'), findsOneWidget, reason: '失败不得启动倒计时（否则按钮把用户按死 60 秒）');
    expect(tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed, isNotNull);

    // 修好后可以立刻重试
    adapter.emailCodeStatus = 200;
    adapter.emailCodeBody = _okSendBody;
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('60s 后重发'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('限流 429「请求过于频繁，请 42 秒后再试」→ 中文红字落在验证码字段（不再只剩浮层）', (tester) async {
    final adapter = FakeApiRecorder(
      emailCodeStatus: 429,
      emailCodeBody: const {'code': 429, 'message': '请求过于频繁，请 42 秒后再试', 'data': null},
    );
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);

    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('请求过于频繁，请 42 秒后再试'), findsWidgets);
    expect(find.byType(AppFieldError), findsWidgets, reason: '必须是行内红字（AppFieldError），不是只在浮层');
    expect(
      summaryText(tester),
      contains('邮箱验证码还需修改'),
      reason: '汇总条用中文标签指路：${summaryText(tester)}',
    );
    await tester.pump(const Duration(seconds: 3));
  });

  // --------------------------------------------------------- 注册：提交体

  testWidgets('提交注册 → 请求体含 email + emailCode（且不带 role 等越权字段）', (tester) async {
    final adapter = FakeApiRecorder(emailCodeBody: _okSendBody);
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);
    await agree(tester);

    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tester.enterText(find.byKey(const Key('register-code-field')), '135790');
    await submitRegister(tester);
    await tester.pumpAndSettle();

    expect(adapter.requests, contains('/auth/register'));
    final body = adapter.bodyFor('/auth/register');
    expect(body['email'], '3989032755@qq.com');
    expect(body['emailCode'], '135790');
    expect(body['username'], 'qilian_yao');
    expect(body['password'], 'password123');
    expect(body.containsKey('role'), isFalse, reason: '注册角色由后端定（不得由客户端指定）');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('后端返回「验证码错误」（无 fields[]）→ 落在**验证码字段**的行内红字', (tester) async {
    final adapter = FakeApiRecorder(
      registerStatus: 400,
      registerBody: const {'code': 400, 'message': '验证码错误', 'data': null},
    );
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);
    await agree(tester);

    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tester.enterText(find.byKey(const Key('register-code-field')), '000000');
    await submitRegister(tester);
    await tester.pumpAndSettle();

    expect(find.text('验证码错误'), findsWidgets, reason: '行内红字 + 汇总条');
    // 「验证码错误」必须挂在验证码格下方（不是顶部浮层、也不是账号/密码格）
    expect(
      tester.getTopLeft(find.text('验证码错误').first).dy,
      greaterThan(tester.getTopLeft(find.byKey(const Key('register-code-field'))).dy),
      reason: '红字在验证码输入框**下方**',
    );
    // 行内红字确实是 AppFieldError（验证码那一条有文案，其余 4 格组件在但无文案）
    expect(find.byType(AppFieldError), findsNWidgets(5));
    expect(summaryText(tester), contains('邮箱验证码还需修改'));
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('后端返回「验证码已过期」/「该邮箱已被注册」分别落验证码格与邮箱格', (tester) async {
    final adapter = FakeApiRecorder(
      registerStatus: 400,
      registerBody: const {'code': 400, 'message': '验证码已过期，请重新获取', 'data': null},
    );
    await pumpLogin(tester, adapter);
    await switchToRegister(tester);
    await agree(tester);
    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.enterText(find.byKey(const Key('register-email-field')), '3989032755@qq.com');
    await tester.enterText(find.byKey(const Key('register-code-field')), '111111');
    await submitRegister(tester);
    await tester.pumpAndSettle();
    expect(find.text('验证码已过期，请重新获取'), findsWidgets);
    expect(summaryText(tester), contains('邮箱验证码还需修改'));
    await tester.pump(const Duration(seconds: 3));

    // 邮箱占用：错误落邮箱格
    adapter.registerBody = const {'code': 409, 'message': '该邮箱已被注册', 'data': null};
    adapter.registerStatus = 409;
    await submitRegister(tester);
    await tester.pumpAndSettle();
    expect(find.text('该邮箱已被注册'), findsWidgets);
    expect(summaryText(tester), contains('邮箱还需修改'), reason: '汇总条应指向邮箱：${summaryText(tester)}');
    await tester.pump(const Duration(seconds: 3));
  });

  // --------------------------------------------------------- 忘记密码流程

  testWidgets('忘记密码：打开找回页 → 标题/邮箱/验证码/两个密码格/重置按钮齐全', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    expect(find.text('找回密码'), findsWidgets, reason: '品牌区标题');
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('验证码'), findsOneWidget);
    expect(find.text('新密码'), findsOneWidget);
    expect(find.text('确认新密码'), findsOneWidget);
    expect(find.byKey(const Key('forgot-submit')), findsOneWidget);
    expect(find.byKey(AppAuthCodeButton.buttonKey), findsOneWidget);
    expect(find.byType(AppQishanMark), findsOneWidget, reason: '沿用方案 B 品牌主视觉');
    expect(adapter.requests, isEmpty, reason: '打开页面不发请求');
  });

  testWidgets('忘记密码全流程：发码（scene=reset）→ 提交 → 成功提示 → 返回登录页 + 密码框已清空', (tester) async {
    final adapter = FakeApiRecorder(emailCodeBody: _okSendBody, forgotPasswordBody: _okResetBody);
    await pumpLogin(tester, adapter);

    // 先在登录页填一个密码（验证"重置成功后密码框被清空"）
    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'oldpassword');
    await tester.pump();

    await openForgot(tester);

    // ① 发码
    await tester.enterText(find.byType(TextField).at(0), '3989032755@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(adapter.methodFor('/auth/email/code'), 'POST');
    expect(
      adapter.bodyFor('/auth/email/code'),
      {'email': '3989032755@qq.com', 'scene': 'reset'},
      reason: '找回密码场景必须是 reset',
    );
    expect(find.text('60s 后重发'), findsOneWidget, reason: '找回密码也要 60 秒倒计时');
    // 防枚举文案（工作端未绑定邮箱时后端同样返回成功）
    expect(find.text(emailCodeSentHint(EmailCodeScene.reset)), findsOneWidget);
    expect(emailCodeSentHint(EmailCodeScene.reset), contains('若该邮箱已绑定'));

    // ② 填验证码 + 两次新密码 → 提交
    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword1');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();

    expect(adapter.requests, contains('/auth/password/reset'));
    expect(
      adapter.bodyFor('/auth/password/reset'),
      {
        'email': '3989032755@qq.com',
        'emailCode': '246810',
        'newPassword': 'newpassword1',
      },
      reason: '请求体键名与后端 ResetPasswordDto 逐字段一致',
    );

    // ③ 回到登录页 + 中文成功提示 + 密码框已清空
    expect(find.byType(ForgotPasswordPage), findsNothing, reason: '成功后必须回到登录页');
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('密码已重置，请用新密码登录'), findsOneWidget, reason: '成功提示在登录页弹出');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      isEmpty,
      reason: '返回登录页后密码框必须被清空（用户要用新密码重新输入）',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'qilian_yao',
      reason: '账号保留（只是清空密码）',
    );

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('忘记密码：两次密码不一致 / 密码太短 → 本地行内红字，不发请求', (tester) async {
    final adapter = FakeApiRecorder(emailCodeBody: _okSendBody);
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    await tester.enterText(find.byType(TextField).at(0), '3989032755@qq.com');
    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.enterText(find.byType(TextField).at(2), '1234567'); // 7 位：少于 8
    await tester.enterText(find.byType(TextField).at(3), '1234567');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();
    expect(find.text('密码至少 8 位'), findsWidgets);
    expect(adapter.requests, isEmpty);

    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword2');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();
    expect(find.text('两次输入的密码不一致'), findsWidgets);
    expect(adapter.requests, isEmpty, reason: '本地校验不过不得发请求');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('忘记密码：邮箱格式错误 → 不发请求 + 行内「邮箱格式不正确」', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    await tester.enterText(find.byType(TextField).at(0), 'not-an-email');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('邮箱格式不正确'), findsWidgets);
    expect(adapter.requests, isEmpty, reason: '格式不合法不发取码请求');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('忘记密码：后端返回「验证码已过期」→ 验证码格行内红字（不暴露邮箱是否存在）', (tester) async {
    final adapter = FakeApiRecorder(
      emailCodeBody: _okSendBody,
      forgotPasswordStatus: 400,
      forgotPasswordBody: const {'code': 400, 'message': '验证码已过期，请重新获取', 'data': null},
    );
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    await tester.enterText(find.byType(TextField).at(0), 'unregistered@qq.com');
    await tester.enterText(find.byType(TextField).at(1), '246810');
    await tester.enterText(find.byType(TextField).at(2), 'newpassword1');
    await tester.enterText(find.byType(TextField).at(3), 'newpassword1');
    await tapAt(tester, find.byKey(const Key('forgot-submit')));
    await tester.pumpAndSettle();

    expect(find.text('验证码已过期，请重新获取'), findsWidgets, reason: '未注册邮箱也走通用文案（后端防枚举）');
    expect(find.textContaining('邮箱不存在'), findsNothing);
    expect(find.textContaining('未注册'), findsNothing, reason: '界面**不得**暴露邮箱是否存在');
    expect(find.byType(ForgotPasswordPage), findsOneWidget, reason: '失败必须留在原页');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('防枚举：找回页固定文案与取码提示都不得出现「不存在/未注册」式断言', (tester) async {
    final adapter = FakeApiRecorder(emailCodeBody: _okSendBody);
    await pumpLogin(tester, adapter);
    await openForgot(tester);

    for (final leak in const ['邮箱不存在', '未注册', '该邮箱没有']) {
      expect(find.textContaining(leak), findsNothing, reason: '防枚举：页面不得出现「$leak」');
    }

    // 未绑定邮箱的后端响应与成功完全一致 → 界面照常提示「若该邮箱已绑定…」
    await tester.enterText(find.byType(TextField).at(0), 'never-bound@qq.com');
    await tapAt(tester, find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(emailCodeSentHint(EmailCodeScene.reset)), findsOneWidget);
    expect(emailCodeSentHint(EmailCodeScene.reset), contains('若该邮箱已绑定'));
    expect(find.textContaining('未注册'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 60));
  });
}

// ------------------------------------------------------------------ 工具

const Map<String, dynamic> _okSendBody = {
  'code': 0,
  'message': 'ok',
  'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
};

const Map<String, dynamic> _okResetBody = {
  'code': 0,
  'message': 'ok',
  'data': {'ok': true, 'message': '密码已重置，请使用新密码登录'},
};

Future<void> pumpLogin(WidgetTester tester, FakeApiRecorder adapter) async {
  // 真实手机视口（默认 800×600 太矮：注册模式 5 格 + 协议 + 按钮会超出屏幕，
  // 布局断言仍成立，但点击会因控件在视口外而落空 —— 出图测试亦为 390×844）
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: fakeDio(adapter)))));
  await tester.pumpAndSettle();
}

/// 点之前先滚到可见（真实手机上用户也是先滑一下；`SingleChildScrollView` 内有效）
Future<void> tapAt(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
}

Future<void> switchToRegister(WidgetTester tester) async {
  await tapAt(tester, find.byKey(const Key('auth-switch-mode')));
  await tester.pumpAndSettle();
}

Future<void> agree(WidgetTester tester) async {
  await tapAt(tester, find.byKey(AppAgreementRow.checkBoxKey));
  await tester.pump();
}

Future<void> submitRegister(WidgetTester tester) async {
  await tapAt(tester, find.byKey(const Key('auth-submit')));
}

Future<void> openForgot(WidgetTester tester) async {
  await tapAt(tester, find.text('忘记密码'));
  await tester.pumpAndSettle();
}

/// 汇总条文本（按钮上方 AppFormErrorSummary 渲染的文案）
String summaryText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: find.byType(AppFormErrorSummary), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join(' | ');

Dio fakeDio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter;

/// 记录请求的假 API（按路径分派响应；字段可中途修改以模拟"第一次失败、第二次成功"）
class FakeApiRecorder implements HttpClientAdapter {
  FakeApiRecorder({
    this.emailCodeStatus = 200,
    this.emailCodeBody = _okSendBody,
    this.registerStatus = 200,
    this.registerBody = const {
      'code': 0,
      'message': 'ok',
      'data': {'id': 'u1', 'username': 'qilian_yao', 'uid': '10001', 'nickname': '老板'},
    },
    this.forgotPasswordStatus = 200,
    this.forgotPasswordBody = _okResetBody,
  });

  int emailCodeStatus;
  Map<String, dynamic> emailCodeBody;
  int registerStatus;
  Map<String, dynamic> registerBody;
  int forgotPasswordStatus;
  Map<String, dynamic> forgotPasswordBody;

  final List<String> requests = [];
  final List<String> methods = [];
  final List<Map<String, dynamic>> bodies = [];

  int countOf(String path) => requests.where((p) => p == path).length;

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
    } else if (options.path.contains('/auth/register')) {
      status = registerStatus;
      body = registerBody;
    } else if (options.path.contains('/auth/password/reset')) {
      status = forgotPasswordStatus;
      body = forgotPasswordBody;
    }
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
