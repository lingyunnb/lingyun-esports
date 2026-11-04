import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/email_bind_page.dart';
import 'package:boss_app/pages/settings_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老板端「设置页邮箱行 + 绑定/换绑页」（负责人 2026-10-10 邮箱能力）
///
/// 契约取自服务端源码（**只读**）：
/// - `GET  /user/email`      → `{bound, email(脱敏), verified, verifiedAt}`（设置页唯一数据源）
/// - `POST /auth/email/code` → `{email, scene:'bind'}` → `{ok, message}`
/// - `POST /user/email/bind` → `{email, emailCode, password}` → `{ok, email(脱敏), emailVerified, rebound, message}`
///
/// 用例对照需求逐条：
/// ① 发码成功 → 60 秒倒计时且按钮禁用；② 倒计时中重复点无效；③ 邮箱格式非法 → 本地拦截不发请求；
/// ④ 验证码错误 → 服务端中文 + 不跳转；⑤ 密码错误 → 中文 + 不跳转；⑥ 绑定成功 → 回设置页并刷新为脱敏邮箱；
/// ⑦ 换绑成功 → 「更换后原邮箱将不再用于登录」提示已展示过；⑧ 未绑定 / 已绑定两态渲染。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: 'boss-token');
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    AppToast.dismiss();
  });

  // ------------------------------------------------------------ ⑧ 两态渲染

  testWidgets('⑧ 未绑定态：显示「邮箱」「未绑定」「绑定」，无「已验证」', (tester) async {
    final api = FakeApi(); // 默认未绑定
    await pumpSettings(tester, api);

    expect(find.byKey(const Key('settings-email-row')), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget, reason: '邮箱行标题');
    expect(find.text('未绑定'), findsOneWidget);
    expect(find.text('绑定'), findsOneWidget, reason: '未绑定时右侧动作是「绑定」');
    expect(find.text('更换'), findsNothing);
    expect(find.text('已验证'), findsNothing, reason: '未绑定不许出现「已验证」标记');

    expect(api.paths, contains('/user/email'), reason: '状态必须来自服务端接口，不许本地猜');
    expect(api.methodOf('/user/email'), 'GET');
    expect(api.authOf('/user/email'), 'Bearer boss-token', reason: '主体只从 JWT 取：必须带登录令牌');
  });

  testWidgets('⑧ 已绑定态：显示**脱敏**邮箱 +「已验证」+「更换」', (tester) async {
    final api = FakeApi(
      status: const {
        'code': 0,
        'message': 'ok',
        'data': {'bound': true, 'email': 'ab***@qq.com', 'verified': true, 'verifiedAt': '2026-10-10T00:00:00.000Z'},
      },
    );
    await pumpSettings(tester, api);

    expect(find.text('ab***@qq.com'), findsOneWidget, reason: '服务端只下发脱敏邮箱，页面逐字展示');
    expect(find.text('已验证'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    expect(find.text('未绑定'), findsNothing);
    expect(find.text('绑定'), findsNothing, reason: '已绑定时右侧动作是「更换」而不是「绑定」');
  });

  testWidgets('⑧ 状态取不到时不猜两态：显示「获取失败，点击重试」，无「绑定/更换」', (tester) async {
    final api = FakeApi(
      status: const {'code': 500, 'message': '服务器开小差了', 'data': null},
      statusHttp: 500,
    );
    await pumpSettings(tester, api);

    expect(find.text('获取失败，点击重试'), findsOneWidget);
    expect(find.text('未绑定'), findsNothing, reason: '状态未知时**不许**显示「未绑定」（那是猜的）');
    expect(find.text('绑定'), findsNothing);
    expect(find.text('更换'), findsNothing);

    // 点一下 = 重试取状态（不进绑定页）
    api.status = const {
      'code': 0,
      'message': 'ok',
      'data': {'bound': false, 'email': null, 'verified': false},
    };
    api.statusHttp = 200;
    await tester.tap(find.byKey(const Key('settings-email-row')));
    await tester.pumpAndSettle();
    expect(find.text('未绑定'), findsOneWidget, reason: '重试成功后恢复正常两态');
    expect(find.byType(EmailBindPage), findsNothing, reason: '状态未知时点击只重试，不猜着进页面');
  });

  // ------------------------------------------------- ① 发码倒计时 / ② 防重复

  testWidgets('① 发码成功 → 60 秒倒计时且按钮禁用（scene=bind）；② 倒计时中重复点无效', (tester) async {
    final api = FakeApi();
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await tester.enterText(find.byKey(const Key('email-bind-email-field')), 'new_mail@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pump(); // 发出请求
    await tester.pump(const Duration(milliseconds: 50)); // 响应回来 → 进入倒计时

    expect(api.paths, contains('/auth/email/code'));
    expect(api.methodOf('/auth/email/code'), 'POST');
    expect(
      api.bodyOf('/auth/email/code'),
      {'email': 'new_mail@qq.com', 'scene': 'bind'},
      reason: '绑定场景取码必须是 scene=bind（与注册/找回/登录各自独立计码）',
    );
    expect(find.text('60s 后重发'), findsOneWidget, reason: '取码成功立刻进入 60 秒倒计时');
    expect(
      tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed,
      isNull,
      reason: '倒计时期间按钮必须禁用',
    );

    // ② 倒计时中重复点：不发第二个请求
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey), warnIfMissed: false);
    await tester.pump();
    expect(api.countOf('/auth/email/code'), 1, reason: '倒计时中不得重复发码');

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('59s 后重发'), findsOneWidget, reason: '每秒递减');
    await tester.pump(const Duration(seconds: 60)); // 排空倒计时定时器
  });

  testWidgets('取码失败（限流 429）→ 中文原文 + **不进入倒计时**（按钮仍可点）', (tester) async {
    final api = FakeApi(
      sendCode: const {'code': 429, 'message': '请求过于频繁，请 42 秒后再试', 'data': null},
      sendCodeHttp: 429,
    );
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await tester.enterText(find.byKey(const Key('email-bind-email-field')), 'new_mail@qq.com');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();

    expect(find.text('请求过于频繁，请 42 秒后再试'), findsWidgets, reason: '服务端中文原文，不吞错');
    expect(find.text('获取验证码'), findsOneWidget, reason: '失败不启动倒计时：按钮文案回到可点态');
    expect(tester.widget<TextButton>(find.byKey(AppAuthCodeButton.buttonKey)).onPressed, isNotNull,
        reason: '没发出去的码不该把用户按死 60 秒');
    expect(api.countOf('/auth/email/code'), 1);
  });

  // --------------------------------------------------------- ③ 本地格式拦截

  testWidgets('③ 邮箱格式非法 → 取码与提交**都不发请求**，只标中文红字', (tester) async {
    final api = FakeApi();
    await pumpSettings(tester, api);
    await openBindPage(tester);
    api.clear(); // 只看进绑定页之后的请求

    await tester.enterText(find.byKey(const Key('email-bind-email-field')), 'not-an-email');
    await tester.tap(find.byKey(AppAuthCodeButton.buttonKey));
    await tester.pumpAndSettle();
    expect(find.text('邮箱格式不正确'), findsWidgets);
    expect(api.paths, isEmpty, reason: '格式不合法时一个请求都不许发（含取码）');

    // 提交同样被本地拦下
    await tester.enterText(find.byKey(const Key('email-bind-code-field')), '123456');
    await tester.enterText(find.byKey(const Key('email-bind-password-field')), 'pass1234');
    await submit(tester);
    await tester.pumpAndSettle();
    expect(find.text('邮箱格式不正确'), findsWidgets);
    expect(api.paths, isEmpty, reason: '格式不合法时提交也不发请求');
    expect(find.byType(EmailBindPage), findsOneWidget, reason: '留在原页');
  });

  // ------------------------------------------------- ④ 验证码错误 / ⑤ 密码错误

  testWidgets('④ 验证码错误 → 展示服务端中文原文 + **不跳转**', (tester) async {
    final api = FakeApi(
      bind: const {'code': 400, 'message': '验证码错误', 'data': null},
      bindHttp: 400,
    );
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await fillForm(tester);
    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text('验证码错误'), findsWidgets, reason: '服务端中文原文（不是客户端自造文案）');
    expect(find.byType(EmailBindPage), findsOneWidget, reason: '失败必须留在绑定页，不能跳转');
    expect(api.countOf('/user/email/bind'), 1);
    // 设置页那一行仍是「未绑定」（失败不得改动本地状态）—— 它在被覆盖的下一页，故 skipOffstage: false
    expect(find.text('未绑定', skipOffstage: false), findsOneWidget);
  });

  testWidgets('④ 验证码过期 → 「验证码已过期，请重新获取」原样展示', (tester) async {
    final api = FakeApi(
      bind: const {'code': 400, 'message': '验证码已过期，请重新获取', 'data': null},
      bindHttp: 400,
    );
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await fillForm(tester);
    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text('验证码已过期，请重新获取'), findsWidgets);
    expect(find.byType(EmailBindPage), findsOneWidget);
  });

  testWidgets('⑤ 密码错误 → 展示「密码错误」+ **不跳转**', (tester) async {
    final api = FakeApi(
      bind: const {'code': 400, 'message': '密码错误', 'data': null},
      bindHttp: 400,
    );
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await fillForm(tester);
    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text('密码错误'), findsWidgets);
    expect(find.byType(EmailBindPage), findsOneWidget, reason: '密码错误必须留在原页');
    expect(find.text('未绑定', skipOffstage: false), findsOneWidget, reason: '失败不得改动设置页那一行');
  });

  testWidgets('邮箱已被其他账号绑定（409）→ 中文原文 + 不跳转', (tester) async {
    final api = FakeApi(
      bind: const {'code': 409, 'message': '该邮箱已被其他账号绑定', 'data': null},
      bindHttp: 409,
    );
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await fillForm(tester);
    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text('该邮箱已被其他账号绑定'), findsWidgets);
    expect(find.byType(EmailBindPage), findsOneWidget);
  });

  // ------------------------------------------------------ ⑥ 绑定成功 + 刷新

  testWidgets('⑥ 绑定成功 → 回设置页 + 刷新为脱敏邮箱 + 成功提示；请求体三要素齐全且防连点', (tester) async {
    final api = FakeApi();
    await pumpSettings(tester, api);
    await openBindPage(tester);

    await fillForm(tester);
    // 防连点：同一帧内连点两次（第一次已把请求发出、按钮还没被转圈取代）
    api.bindDelay = const Duration(milliseconds: 120);
    await tester.ensureVisible(find.byKey(const Key('email-bind-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('email-bind-submit')));
    await tester.tap(find.byKey(const Key('email-bind-submit')));
    await tester.pump();
    expect(
      find.byKey(const Key('email-bind-submit')),
      findsNothing,
      reason: '请求在途时提交按钮换成转圈 → 界面上根本没有第二下可点（防连点第二道闸）',
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(api.countOf('/user/email/bind'), 1, reason: '防连点：只发一次绑定请求');
    expect(api.methodOf('/user/email/bind'), 'POST');
    expect(
      api.bodyOf('/user/email/bind'),
      {'email': 'new_mail@qq.com', 'emailCode': '246810', 'password': 'pass1234'},
      reason: '契约：email + emailCode + password 三要素（服务端 BindEmailDto 全部必填）',
    );
    expect(api.authOf('/user/email/bind'), 'Bearer boss-token');

    expect(find.byType(EmailBindPage), findsNothing, reason: '成功后回到设置页');
    expect(find.text('ab***@qq.com'), findsOneWidget, reason: '刷新为服务端返回的**脱敏**邮箱');
    expect(find.text('未绑定'), findsNothing);
    expect(find.text('邮箱绑定成功'), findsOneWidget, reason: '成功提示（服务端文案）');
    expect(api.countOf('/user/email'), 2, reason: '返回后再拉一次状态兜底（进页面 1 次 + 成功后 1 次）');
    await tester.pump(const Duration(seconds: 3)); // 排空 toast
  });

  // ------------------------------------------------------------ ⑦ 换绑

  testWidgets('⑦ 换绑：页面明确提示「更换后原邮箱将不再用于登录」；成功后显示新脱敏邮箱', (tester) async {
    final api = FakeApi(
      status: const {
        'code': 0,
        'message': 'ok',
        'data': {'bound': true, 'email': 'ab***@qq.com', 'verified': true, 'verifiedAt': null},
      },
      bind: const {
        'code': 0,
        'message': 'ok',
        'data': {
          'ok': true,
          'email': 'cd***@qq.com',
          'emailVerified': true,
          'rebound': true,
          'message': '邮箱换绑成功',
        },
      },
    );
    await pumpSettings(tester, api);
    expect(find.text('ab***@qq.com'), findsOneWidget);

    // 换绑态入口是「更换」
    await tester.tap(find.byKey(const Key('settings-email-row')));
    await tester.pumpAndSettle();
    expect(find.text('更换邮箱'), findsOneWidget, reason: '换绑态标题');
    // **换绑的硬要求**：进页面即明确提示旧邮箱的去向（提交前就已展示，本用例据此断言"已展示过"）
    expect(find.text(kEmailRebindNotice), findsOneWidget,
        reason: '换绑页必须明确提示「$kEmailRebindNotice」');

    await fillForm(tester, email: 'rebind_mail@qq.com');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(api.bodyOf('/user/email/bind')['email'], 'rebind_mail@qq.com');
    expect(api.bodyOf('/user/email/bind')['emailCode'], '246810');
    expect(find.byType(EmailBindPage), findsNothing, reason: '成功后回设置页');
    expect(find.text('cd***@qq.com'), findsOneWidget, reason: '设置页已刷新为新脱敏邮箱');
    expect(find.text('ab***@qq.com'), findsNothing, reason: '旧邮箱不再出现在设置页');
    expect(find.text('邮箱换绑成功'), findsOneWidget, reason: '换绑成功提示（服务端按 bind/rebind 区分文案）');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('⑦ 换绑页文案不含「解绑」类误导：只做覆盖，不做移除', (tester) async {
    final api = FakeApi(
      status: const {
        'code': 0,
        'message': 'ok',
        'data': {'bound': true, 'email': 'ab***@qq.com', 'verified': true, 'verifiedAt': null},
      },
    );
    await pumpSettings(tester, api);
    await tester.tap(find.byKey(const Key('settings-email-row')));
    await tester.pumpAndSettle();

    expect(find.textContaining('解绑'), findsNothing, reason: '本轮服务端不提供解绑，界面也不得出现该入口');
    expect(find.text('确认更换'), findsOneWidget);
    expect(kEmailRebindNotice, contains('不再用于登录'));
  });

  // ------------------------------------------------------ 绑定也要求当前密码

  testWidgets('契约：**首次绑定同样必填当前密码**（服务端 BindEmailDto.password 无 @IsOptional）', (tester) async {
    final api = FakeApi();
    await pumpSettings(tester, api);
    await openBindPage(tester);
    api.clear();

    expect(find.text('当前密码'), findsOneWidget, reason: '绑定态也有「当前密码」格');
    await tester.enterText(find.byKey(const Key('email-bind-email-field')), 'new_mail@qq.com');
    await tester.enterText(find.byKey(const Key('email-bind-code-field')), '246810');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text('请输入当前密码'), findsWidgets);
    expect(api.paths, isEmpty, reason: '本地拦截：缺当前密码时不发绑定请求');
  });
}

// ------------------------------------------------------------------ 工具

/// 打开绑定页（从未绑定态的邮箱行进入）
Future<void> openBindPage(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('settings-email-row')));
  await tester.pumpAndSettle();
  expect(find.byType(EmailBindPage), findsOneWidget);
}

/// 填一份合法表单（邮箱 / 6 位验证码 / 当前密码）
Future<void> fillForm(WidgetTester tester, {String email = 'new_mail@qq.com'}) async {
  await tester.enterText(find.byKey(const Key('email-bind-email-field')), email);
  await tester.enterText(find.byKey(const Key('email-bind-code-field')), '246810');
  await tester.enterText(find.byKey(const Key('email-bind-password-field')), 'pass1234');
  await tester.pump();
}

Future<void> submit(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('email-bind-submit')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('email-bind-submit')));
}

Future<void> pumpSettings(WidgetTester tester, FakeApi api) async {
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: SettingsPage(api: ApiClient(dio: _dio(api)))));
  await tester.pumpAndSettle();
}

Dio _dio(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter;

/// 记录请求的假 API（按路径分派；字段可中途改，模拟"第一次失败、第二次成功"）
class FakeApi implements HttpClientAdapter {
  FakeApi({
    this.status = const {
      'code': 0,
      'message': 'ok',
      'data': {'bound': false, 'email': null, 'verified': false, 'verifiedAt': null},
    },
    this.statusHttp = 200,
    this.sendCode = const {
      'code': 0,
      'message': 'ok',
      'data': {'ok': true, 'message': '验证码已发送至邮箱，请注意查收（10 分钟内有效）'},
    },
    this.sendCodeHttp = 200,
    this.bind = const {
      'code': 0,
      'message': 'ok',
      'data': {
        'ok': true,
        'email': 'ab***@qq.com',
        'emailVerified': true,
        'rebound': false,
        'message': '邮箱绑定成功',
      },
    },
    this.bindHttp = 200,
  });

  Map<String, dynamic> status;
  int statusHttp;
  Map<String, dynamic> sendCode;
  int sendCodeHttp;
  Map<String, dynamic> bind;
  int bindHttp;

  /// 绑定请求的人为延迟（防连点用例需要"在途"窗口）
  Duration bindDelay = Duration.zero;

  final List<String> paths = [];
  final List<String> _methods = [];
  final List<Map<String, dynamic>> _bodies = [];
  final List<String?> _auth = [];

  int countOf(String path) => paths.where((p) => p == path).length;

  /// 清掉已记录请求（用于"只看某一动作之后的请求"的断言）
  void clear() {
    paths.clear();
    _methods.clear();
    _bodies.clear();
    _auth.clear();
  }

  String methodOf(String path) {
    final i = paths.indexOf(path);
    return i < 0 ? '' : _methods[i];
  }

  Map<String, dynamic> bodyOf(String path) {
    final i = paths.indexOf(path);
    return i < 0 ? const {} : _bodies[i];
  }

  String? authOf(String path) {
    final i = paths.indexOf(path);
    return i < 0 ? null : _auth[i];
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    _methods.add(options.method);
    _bodies.add(options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{});
    _auth.add(options.headers['Authorization'] as String?);

    var code = 200;
    Map<String, dynamic> body = const {'code': 0, 'message': 'ok', 'data': null};
    // 注意 `/user/email/bind` 与 `/user/email` 是不同路径，必须精确匹配
    if (options.path == '/user/email') {
      code = statusHttp;
      body = status;
    } else if (options.path == '/auth/email/code') {
      code = sendCodeHttp;
      body = sendCode;
    } else if (options.path == '/user/email/bind') {
      if (bindDelay > Duration.zero) await Future<void>.delayed(bindDelay);
      code = bindHttp;
      body = bind;
      // 假服务端也要有"绑定真的写进去了"的效果：否则设置页返回后**重新拉状态**会拿到旧的未绑定值，
      // 「成功 → 回设置页刷新为脱敏邮箱」这条链路就测不出来（服务端 EmailBindingService.bind 会写 email + email_verified_at）
      if (bindHttp == 200) {
        final data = (bind['data'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
        status = {
          'code': 0,
          'message': 'ok',
          'data': {
            'bound': true,
            'email': data['email'],
            'verified': true,
            'verifiedAt': '2026-10-10T00:00:00.000Z',
          },
        };
        statusHttp = 200;
      }
    }
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
