import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 邮箱验证码 / 找回密码的 **core 层**规则、请求体与错误映射（负责人 2026-10-05）
///
/// 覆盖（两端共用，故在 core 侧固化）：
/// 1. 邮箱/验证码/新密码的**本地校验**（不合法 → 页面不发请求的判定依据）；
/// 2. 防枚举文案口径（`emailCodeSentHint(reset)` 不得暴露邮箱是否存在）；
/// 3. 后端中文错误 → 表单字段的**映射**（服务端这些错误没有 `fields[]`，
///    没有这层映射就落不到行内红字 —— 见 `AuthErrorField` 注释）；
/// 4. `AuthStore.register` 的**向后兼容**（不传 email 时请求体与旧版逐字节一致）；
/// 5. `sendEmailCode` / `resetPassword` 的路径与请求体（与后端 DTO 逐字段对齐）；
/// 6. 60 秒重发倒计时状态机（`EmailCodeCountdown`）。
void main() {
  setUpAll(() => ApiClient.cacheEnabled = false);

  // ---------------------------------------------------------------- 本地校验

  test('邮箱格式：合法取值通过，非法取值一律拦下（用于"不发请求"的本地拦截）', () {
    for (final ok in const [
      'a@qq.com',
      'user@qq.com',
      'user.name+tag@qq.com',
      '3989032755@qq.com',
      'first.last@sub.mail.example.com',
      'x_1-2@my-domain.cn',
    ]) {
      expect(isEmailFormatValid(ok), isTrue, reason: '$ok 应判为合法');
      expect(emailFormatError(ok), isNull, reason: '$ok 合法时不应有提示');
    }
    for (final bad in const [
      '',
      '   ',
      'qq.com',
      'user@',
      '@qq.com',
      'user@qq',
      'user@qq.c',
      'user qq@qq.com',
      'user@@qq.com',
      'user@.com',
      'user@qq..com',
    ]) {
      expect(isEmailFormatValid(bad), isFalse, reason: '「$bad」应判为非法');
      expect(emailFormatError(bad), isNotNull, reason: '「$bad」必须有中文提示');
    }
    expect(isEmailFormatValid('  a@b.com  '), isTrue, reason: '首尾空白应被 trim（用户从通讯录粘贴常见）');
    expect(emailFormatError(''), '请输入邮箱');
    expect(emailFormatError('qq.com'), '邮箱格式不正确');
    expect(emailFormatError('${'a' * 200}@qq.com'), contains('最多'), reason: '与服务端 @Length(1,120) 对齐');
  });

  test('验证码/新密码本地校验：6 位数字 + 8-64 位（与注册同规则）', () {
    expect(isEmailCodeFormatValid('123456'), isTrue);
    expect(emailCodeFormatError('123456'), isNull);
    for (final bad in const ['', '12345', '1234567', '12345a', 'abcdef']) {
      expect(isEmailCodeFormatValid(bad), isFalse, reason: '「$bad」不是 6 位数字');
      expect(emailCodeFormatError(bad), isNotNull);
    }
    expect(emailCodeFormatError(''), '请输入验证码');
    expect(emailCodeFormatError('12345'), '验证码为 6 位数字');

    expect(newPasswordFormatError('password123'), isNull);
    expect(newPasswordFormatError(''), '请输入新密码');
    expect(newPasswordFormatError('1234567'), '密码至少 8 位');
    expect(newPasswordFormatError('a' * 65), contains('最多'));
    expect(newPasswordFormatError('a' * 64), isNull, reason: '64 位是上限内');
    expect(kPasswordMinLength, 8);
    expect(kPasswordMaxLength, 64);
  });

  // ------------------------------------------------------------ 防枚举文案

  test('取码成功提示：找回密码场景必须防枚举（含"若该邮箱已绑定"，不得暴露邮箱是否存在）', () {
    final reset = emailCodeSentHint(EmailCodeScene.reset);
    expect(reset, contains('若该邮箱已绑定'));
    for (final leak in const ['不存在', '未注册', '未绑定账号不会', '该邮箱没有']) {
      expect(reset.contains(leak), isFalse, reason: '防枚举文案不得出现「$leak」：$reset');
    }
    expect(emailCodeSentHint(EmailCodeScene.register), contains('验证码已发送至邮箱'));
    expect(
      emailCodeSentHint(EmailCodeScene.register),
      isNot(emailCodeSentHint(EmailCodeScene.reset)),
      reason: '注册场景可以明说已发送（后端在注册场景本就会告知邮箱占用）',
    );
  });

  // ------------------------------------------------------------ 错误 → 字段

  test('后端中文错误 → 表单字段：验证码类落 emailCode，身份类落 email，密码类落新密码', () {
    expect(AuthErrorField.ofMessage('验证码错误'), AuthErrorField.emailCode);
    expect(AuthErrorField.ofMessage('验证码已过期，请重新获取'), AuthErrorField.emailCode);
    expect(AuthErrorField.ofMessage('验证码错误次数过多，请重新获取'), AuthErrorField.emailCode,
        reason: '长文案优先：不得被「验证码错误」提前吞掉');
    expect(AuthErrorField.ofMessage('请填写邮箱验证码'), AuthErrorField.emailCode);
    expect(AuthErrorField.ofMessage('邮件发送失败，请稍后重试'), AuthErrorField.emailCode);
    expect(AuthErrorField.ofMessage('请求过于频繁，请 42 秒后再试'), AuthErrorField.emailCode);
    expect(AuthErrorField.ofMessage('该邮箱今日获取验证码次数过多，请 1 小时后再试'), AuthErrorField.emailCode);
    expect(AuthErrorField.ofMessage('当前网络获取验证码次数过多，请 1 小时后再试'), AuthErrorField.emailCode);

    expect(AuthErrorField.ofMessage('该邮箱已被注册'), AuthErrorField.email);
    expect(AuthErrorField.ofMessage('该邮箱已被注册，请直接登录或使用找回密码'), AuthErrorField.email);
    expect(AuthErrorField.ofMessage('邮箱格式不正确'), AuthErrorField.email);

    expect(AuthErrorField.ofMessage('新密码须为 8-64 位'), AuthErrorField.newPassword);

    expect(AuthErrorField.ofMessage('账号或密码错误'), isNull, reason: '定位不到字段 → 调用方走浮层');
    expect(AuthErrorField.ofMessage(''), isNull);
  });

  test('字段标签：邮箱/邮箱验证码有中文标签（否则汇总条会出现半英文字段名）', () {
    expect(labelOfField('email'), '邮箱');
    expect(labelOfField('emailCode'), '邮箱验证码');
  });

  test('bindAuthApiException：结构化 fields[] 优先；无 fields 时按中文文案落字段；都定位不到才返回 false', () {
    // ① 结构化 fields[]（服务端 DTO 校验）→ 用服务端给的字段
    final structured = ApiException(400, '参数有误', 'r1', errorCode: 'VALIDATION_FAILED', fields: const [
      FieldError(field: 'emailCode', label: '邮箱验证码', message: '须为 6 位数字'),
    ]);
    final a = FormErrors();
    expect(bindAuthApiException(a, structured), isTrue);
    expect(a.messageOf('emailCode'), '须为 6 位数字');
    expect(a.messageOf('email'), isNull);

    // ② 无 fields 的中文业务错误（AuthService 的 BadRequestException）→ 客户端映射
    final plain = ApiException(400, '验证码错误', 'r2');
    final b = FormErrors();
    expect(bindAuthApiException(b, plain), isTrue, reason: '没有这层映射就落不到行内红字');
    expect(b.messageOf('emailCode'), '验证码错误');
    expect(b.summaryLines.join('|'), contains('邮箱验证码还需修改'), reason: '汇总条用中文标签指路');

    // ③ 定位不到（网络/账号密码错误）→ false，由调用方弹浮层
    final c = FormErrors();
    expect(bindAuthApiException(c, const ApiException(401, '账号或密码错误', 'r3')), isFalse);
    expect(c.isEmpty, isTrue, reason: '没定位到字段不应留下半截错误状态');

    // ④ 429 限流文案
    final d = FormErrors();
    expect(bindAuthApiException(d, const ApiException(429, '请求过于频繁，请 42 秒后再试', 'r4')), isTrue);
    expect(d.messageOf('emailCode'), contains('42 秒'));
  });

  // ------------------------------------------------------- AuthStore 请求体

  test('回归：register 不传 email/emailCode → 请求体与旧版逐字节一致（老注册路径不变）', () async {
    final adapter = _Recorder();
    await AuthStore.instance.register(
      username: 'qilian_yao',
      password: 'password123',
      nickname: '老板',
      api: _api(adapter),
    );

    expect(adapter.paths, ['/auth/register']);
    final body = adapter.bodies.single;
    expect(body.keys.toSet(), {'username', 'password', 'nickname'}, reason: '不得凭空多出 email/emailCode 键');
    expect(body['username'], 'qilian_yao');
    expect(body['nickname'], '老板');
  });

  test('register 传 email+emailCode → 请求体含两个键（trim 过）', () async {
    final adapter = _Recorder();
    await AuthStore.instance.register(
      username: 'qilian_yao',
      password: 'password123',
      email: '  3989032755@qq.com ',
      emailCode: ' 123456 ',
      api: _api(adapter),
    );

    final body = adapter.bodies.single;
    expect(body['email'], '3989032755@qq.com');
    expect(body['emailCode'], '123456');
    expect(body.containsKey('nickname'), isFalse, reason: 'nickname 不传就不带（既有行为）');
  });

  test('register 空白 email 视同不传（不会被当成"要绑邮箱"而少带 emailCode）', () async {
    final adapter = _Recorder();
    await AuthStore.instance.register(
      username: 'qilian_yao',
      password: 'password123',
      email: '   ',
      api: _api(adapter),
    );
    expect(adapter.bodies.single.keys.toSet(), {'username', 'password'});
  });

  test('sendEmailCode → POST /auth/email/code，请求体 {email, scene}（scene 值必须是 register/reset）', () async {
    final adapter = _Recorder(body: {
      'code': 0,
      'message': 'ok',
      'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
    });
    final r = await AuthStore.instance.sendEmailCode(
      email: '3989032755@qq.com',
      scene: EmailCodeScene.register,
      api: _api(adapter),
    );

    expect(adapter.paths, ['/auth/email/code']);
    expect(adapter.methods.single, 'POST');
    expect(adapter.bodies.single, {'email': '3989032755@qq.com', 'scene': 'register'});
    expect(r.ok, isTrue);
    expect(r.message, contains('验证码已发送'));
    expect(EmailCodeScene.reset, 'reset', reason: '与后端 DTO 的 IsIn([register, reset]) 逐字一致');
  });

  test('取码响应 data 为 null 时不炸（容错：只关心"发没发出去"的调用方）', () async {
    final adapter = _Recorder(body: {'code': 0, 'message': 'ok', 'data': null});
    final r = await AuthStore.instance.sendEmailCode(
      email: 'a@qq.com',
      scene: EmailCodeScene.reset,
      api: _api(adapter),
    );
    expect(r.ok, isTrue);
    expect(r.message, isEmpty);
  });

  test('resetPassword → POST /auth/password/reset，请求体 {email, emailCode, newPassword}', () async {
    final adapter = _Recorder(body: {
      'code': 0,
      'message': 'ok',
      'data': {'ok': true, 'message': '密码已重置，请使用新密码登录'},
    });
    final r = await AuthStore.instance.resetPassword(
      email: ' 3989032755@qq.com ',
      code: ' 654321 ',
      newPassword: 'newpassword1',
      api: _api(adapter),
    );

    expect(adapter.paths, ['/auth/password/reset']);
    expect(adapter.methods.single, 'POST');
    expect(adapter.bodies.single, {
      'email': '3989032755@qq.com',
      'emailCode': '654321',
      'newPassword': 'newpassword1',
    }, reason: '键名与后端 ResetPasswordDto 逐字段一致');
    expect(r.ok, isTrue);
    expect(r.message, contains('密码已重置'));
  });

  test('服务端 400 中文错误原样抛出为 ApiException（页面据此落行内红字）', () async {
    final adapter = _Recorder(
      status: 400,
      body: {'code': 400, 'message': '验证码已过期，请重新获取', 'data': null},
    );
    await expectLater(
      AuthStore.instance.resetPassword(
        email: 'a@qq.com',
        code: '123456',
        newPassword: 'newpassword1',
        api: _api(adapter),
      ),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 400)
          .having((e) => e.message, 'message', '验证码已过期，请重新获取')
          .having((e) => e.fields, 'fields', isEmpty)),
    );
  });

  // ------------------------------------------------------------- 倒计时

  test('倒计时状态机：sending 期间不可点；取码失败不进入倒计时（endSend 后恢复可点）', () {
    final cd = EmailCodeCountdown();
    addTearDown(cd.dispose);

    expect(cd.canSend, isTrue, reason: '初始可点');
    expect(cd.counting, isFalse);
    expect(cd.left, 0);

    cd.beginSend();
    expect(cd.sending, isTrue);
    expect(cd.canSend, isFalse, reason: '请求中不得重复点（防连点重复发信）');
    cd.endSend();
    expect(cd.sending, isFalse);
    expect(cd.counting, isFalse, reason: '失败不启动倒计时 —— 否则按钮会在"其实没发出去"时把用户按死 60 秒');
    expect(cd.canSend, isTrue);

    expect(AppAuthCodeButton.labelOf(sending: false, left: 0), '获取验证码');
    expect(AppAuthCodeButton.labelOf(sending: false, left: 60), '60s 后重发');
    expect(AppAuthCodeButton.labelOf(sending: true, left: 0), '发送中…');
  });

  testWidgets('倒计时：成功后 60 → 59 → … → 0 秒恢复可点（按钮文案随之变化）', (tester) async {
    final cd = EmailCodeCountdown();
    addTearDown(cd.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: ListenableBuilder(
            listenable: cd,
            builder: (_, _) => Text(AppAuthCodeButton.labelOf(sending: cd.sending, left: cd.left)),
          ),
        ),
      ),
    ));

    expect(find.text('获取验证码'), findsOneWidget);

    cd.start();
    await tester.pump();
    expect(cd.resendSeconds, 60, reason: '默认 60 秒，与后端 MAIL_CODE_RESEND_SECONDS 一致');
    expect(cd.left, 60);
    expect(cd.canSend, isFalse);
    expect(find.text('60s 后重发'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(cd.left, 59);
    expect(find.text('59s 后重发'), findsOneWidget);

    await tester.pump(const Duration(seconds: 59));
    expect(cd.left, 0);
    expect(cd.canSend, isTrue);
    expect(find.text('获取验证码'), findsOneWidget, reason: '归零后必须能再次获取');

    cd.reset();
    await tester.pump();
    expect(cd.left, 0);
  });

  testWidgets('倒计时定时器在 dispose 时被取消（不泄漏定时器）', (tester) async {
    final cd = EmailCodeCountdown();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(listenable: cd, builder: (_, _) => const Text('x')),
      ),
    ));
    cd.start();
    await tester.pump(const Duration(seconds: 2));
    cd.dispose();
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}

ApiClient _api(HttpClientAdapter adapter) =>
    ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter);

/// 记录路径/方法/请求体的假适配器（core 侧断言"请求体到底带了什么"）
class _Recorder implements HttpClientAdapter {
  _Recorder({this.status = 200, this.body = const {'code': 0, 'message': 'ok', 'data': null}});

  final int status;
  final Map<String, dynamic> body;

  final List<String> paths = [];
  final List<String> methods = [];
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    methods.add(options.method);
    bodies.add(options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{});
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
