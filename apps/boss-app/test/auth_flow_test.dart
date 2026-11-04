import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/about_privacy_page.dart';
import 'package:boss_app/pages/forgot_password_page.dart';
import 'package:boss_app/pages/login_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 登录/注册改版（方案 B「品牌主视觉」，负责人 2026-10-05 已审批）功能回归
///
/// 覆盖四件负责人点名的事（外加既有行为回归）：
/// 1. **协议未勾选** → 提交被拦（主按钮禁用灰态；点一下只出中文提示，**不发请求**）；
/// 2. **勾选后可提交** → 用假 API 断言 `/auth/login` 真的发出去了；
/// 3. **忘记密码入口**存在且点击出中文提示（「暂未开放自助找回，请联系客服」，**不发起假请求**）；
/// 4. **品牌头/小山标**存在（`find.byType(AppBrandHeader)` + `AppQishanMark`）；
/// 5. 既有行为不回归：注册切换、行内红字、封禁弹窗、账号/密码提示文案。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  testWidgets('协议未勾选：主按钮灰态禁用，点了给中文提示且**不发任何请求**', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    // 输入合法的账号密码（拦的是协议，不是空值校验）
    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pump();

    expect(find.text('请先阅读并勾选《用户协议》与《隐私政策》'), findsOneWidget, reason: '未勾选时要给中文提示');
    expect(adapter.requests, isEmpty, reason: '未勾选协议不得发出任何请求（纯前端约束）');

    // 按钮状态：禁用（onPressed == null → 灰态 #E9EDF4，点不出请求）
    final submit = tester.widget<AppAuthButton>(find.byKey(const Key('auth-submit')));
    expect(submit.onPressed, isNull, reason: '未勾选时主按钮必须是禁用态（onPressed == null）');

    await tester.pump(const Duration(seconds: 3)); // 提示 2 秒自动消失，排空定时器
  });

  testWidgets('勾选协议后可提交：/auth/login 真的发出去了（假 API 记录请求）', (tester) async {
    final adapter = FakeApiRecorder(
      loginBody: {
        'code': 0,
        'message': 'ok',
        'data': {
          'accessToken': 'access-token',
          'refreshToken': 'refresh-token',
        },
      },
      meBody: {
        'code': 0,
        'message': 'ok',
        'data': {'id': 'u1', 'username': 'qilian_yao', 'uid': '10001', 'nickname': '祁连山老板', 'role': 'user'},
      },
    );
    await pumpLogin(tester, adapter);

    await tester.enterText(find.byType(TextField).at(0), 'qilian_yao');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();

    final submit = tester.widget<AppAuthButton>(find.byKey(const Key('auth-submit')));
    expect(submit.onPressed, isNotNull, reason: '勾选后主按钮必须可点');

    await tester.tap(find.byKey(const Key('auth-submit')));
    // 用有界 pump 而不是 pumpAndSettle：登录成功后 AuthStore 通知会触发重建，
    // 期间可能仍有动画（进度圈/主题过渡），pumpAndSettle 会等不收敛
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(adapter.requests, contains('/auth/login'), reason: '勾选后必须真的提交登录请求');
    final body = adapter.bodyFor('/auth/login');
    expect(body['username'], 'qilian_yao');
    expect(body['role'], 'user', reason: '老板端登录角色恒为 user（接口契约不变）');
    // 注意：登录成功后的 /auth/me 走 AuthStore 内部客户端（测试注入只作用于登录那一次调用），
    // 因此这里只断言「登录请求确实发出去了」——正是负责人要求的第 ② 条
  });

  testWidgets('忘记密码：入口在，点击**打开找回密码页**（2026-10-05 改为真流程，不再提示暂未开放）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    expect(find.text('忘记密码'), findsOneWidget, reason: '设计稿 b-login.html 的 .rowline 左位');
    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();

    expect(find.byType(ForgotPasswordPage), findsOneWidget, reason: '点入口应进入找回密码页（真流程）');
    expect(find.text('暂未开放自助找回，请联系客服'), findsNothing, reason: '旧的占位提示必须消失');
    expect(adapter.requests, isEmpty, reason: '只是打开页面，不得自动发任何请求');

    // 返回登录页（页面左上角返回）
    Navigator.of(tester.element(find.byType(ForgotPasswordPage))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ForgotPasswordPage), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('品牌头与小山标存在（find.byType(AppBrandHeader) + 实色 #2563EB、无渐变）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    expect(find.byType(AppBrandHeader), findsOneWidget);
    expect(find.byType(AppQishanMark), findsOneWidget, reason: '品牌区小山标');
    expect(find.text('祁连山电竞'), findsOneWidget, reason: '品牌行（小山标右侧）');
    expect(find.text('登录'), findsNWidgets(2), reason: '品牌区标题 + 主按钮');

    // 品牌区：纯实色底、不透明、176 高
    final header = tester.widget<AppBrandHeader>(find.byType(AppBrandHeader));
    expect(header.color, AppColors.primary, reason: '#2563EB 实色，禁止渐变');
    expect(header.height, 176);
    expect(tester.getSize(find.byType(AppBrandHeader)).height, 176);
  });

  testWidgets('协议文案两个书名号内文字可点 → 打开既有阅读页（不新造内容页）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    expect(find.text('我已阅读并同意《用户协议》与《隐私政策》'), findsOneWidget);
    // 书名号内文字是独立 span：用 tapOnText 精确点在《用户协议》/《隐私政策》上
    await tester.tapOnText(find.textRange.ofSubstring('《用户协议》'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPrivacyPage), findsOneWidget, reason: '打开既有阅读页 AboutPrivacyPage');
    expect(tester.widget<AboutPrivacyPage>(find.byType(AboutPrivacyPage)).kind, 'about');
    Navigator.of(tester.element(find.byType(AboutPrivacyPage))).pop();
    await tester.pumpAndSettle();

    await tester.tapOnText(find.textRange.ofSubstring('《隐私政策》'));
    await tester.pumpAndSettle();
    expect(tester.widget<AboutPrivacyPage>(find.byType(AboutPrivacyPage)).kind, 'privacy');
    Navigator.of(tester.element(find.byType(AboutPrivacyPage))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('回归：勾选状态不持久化（切到注册再切回来，仍为未勾选）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    expect(checked(tester), isTrue);

    await tester.tap(find.byKey(const Key('auth-switch-mode'))); // → 注册
    await tester.pumpAndSettle();
    expect(find.text('昵称（可选）'), findsOneWidget);
    expect(checked(tester), isTrue, reason: '同一次停留内切模式不重置勾选');

    // 重新进页面（重建 State）→ 必须回到未勾选
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpLogin(tester, adapter);
    expect(checked(tester), isFalse, reason: '每次进页面默认未勾选（不做持久化）');
  });

  testWidgets('回归：注册模式仍有昵称字段与注册按钮（登录↔注册切换逻辑未动）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    await tester.tap(find.byKey(const Key('auth-switch-mode')));
    await tester.pumpAndSettle();

    expect(find.text('创建账号'), findsOneWidget, reason: '品牌区标题随模式切换');
    expect(find.text('昵称（可选）'), findsOneWidget);
    expect(find.text('注册'), findsOneWidget);
    // 2026-10-05 邮箱通道：注册模式新增「邮箱」「验证码」两格 → 账号/密码/邮箱/验证码/昵称 = 5
    expect(find.byType(TextField), findsNWidgets(5));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('回归：服务端字段错误仍是输入框下方红字 + 汇总条', (tester) async {
    final adapter = FakeApiRecorder(
      loginStatus: 400,
      loginBody: {
        'code': 400,
        'message': '账号至少 3 个字符；密码至少 8 个字符',
        'data': null,
        'errorCode': 'VALIDATION_FAILED',
        'fields': [
          {'field': 'username', 'label': '账号', 'message': '至少 3 个字符'},
          {'field': 'password', 'label': '密码', 'message': '至少 8 个字符'},
        ],
      },
    );
    await pumpLogin(tester, adapter);

    await tester.enterText(find.byType(TextField).at(0), 'ab');
    await tester.enterText(find.byType(TextField).at(1), '1234567');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('至少 3 个字符'), findsWidgets);
    expect(find.text('至少 8 个字符'), findsWidgets);
    expect(find.byType(AppFieldError), findsWidgets, reason: '保持既有行内红字组件');
    expect(find.byType(AppFormErrorSummary), findsOneWidget, reason: '保持既有顶部汇总条组件');
    expect(find.text('账号、密码还需修改'), findsOneWidget, reason: '汇总条指路文案');
    // 顶部汇总条确实在输入框上方（设计稿 b-err-top.html）
    expect(
      tester.getTopLeft(find.byType(AppFormErrorSummary)).dy < tester.getTopLeft(find.byType(AppAuthField).first).dy,
      isTrue,
      reason: '汇总条在卡片顶部（字段之上）',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('回归：账号封禁仍是弹窗（不改成 toast）', (tester) async {
    final adapter = FakeApiRecorder(
      loginStatus: 403,
      loginBody: {
        'code': 403,
        'message': '账号已被封禁，解封时间 2026-11-01 00:00',
        'data': null,
        'errorCode': 'ACCOUNT_BANNED',
      },
    );
    await pumpLogin(tester, adapter);

    await tester.enterText(find.byType(TextField).at(0), 'banned_user');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('账号已被封禁'), findsOneWidget);
    expect(find.textContaining('2026-11-01'), findsOneWidget);
  });

  testWidgets('回归：空账号/空密码仍是本地行内红字', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.text('请输入账号'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    expect(adapter.requests, isEmpty, reason: '本地校验不过不发请求');
    await tester.pump(const Duration(seconds: 1));
  });
}

Future<void> pumpLogin(WidgetTester tester, FakeApiRecorder adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: dio))));
  await tester.pumpAndSettle();
}

/// 协议方框当前勾选状态（读 Semantics.checked，避免依赖私有 State）
bool checked(WidgetTester tester) {
  for (final w in find.ancestor(of: find.byKey(AppAgreementRow.checkBoxKey), matching: find.byType(Semantics)).evaluate()) {
    final s = w.widget;
    if (s is Semantics && s.properties.checked != null) return s.properties.checked!;
  }
  return false;
}

/// 记录请求的假 API（公开类型：公开函数 pumpLogin 会用到）；任何未登记的路径都返回 200 空数据
class FakeApiRecorder implements HttpClientAdapter {
  FakeApiRecorder({
    this.loginStatus = 200,
    this.loginBody = const {'code': 0, 'message': 'ok', 'data': null},
    this.meBody = const {'code': 0, 'message': 'ok', 'data': null},
  });

  final int loginStatus;
  final Map<String, dynamic> loginBody;
  final Map<String, dynamic> meBody;

  /// 按顺序记录请求路径（断言"有没有发请求"用）
  final List<String> requests = [];
  final List<Map<String, dynamic>> bodies = [];

  Map<String, dynamic> bodyFor(String path) {
    final i = requests.indexOf(path);
    return i < 0 ? const {} : bodies[i];
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.path);
    bodies.add((options.data is Map) ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{});
    final isLogin = options.path.contains('/auth/login');
    final status = isLogin ? loginStatus : 200;
    final body = isLogin ? loginBody : meBody;
    return ResponseBody.fromString(jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
