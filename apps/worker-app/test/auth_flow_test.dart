import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worker_app/pages/about_privacy_page.dart';
import 'package:worker_app/pages/forgot_password_page.dart';
import 'package:worker_app/pages/login_page.dart';

/// 工作端登录页改版回归（方案 B「品牌主视觉」，与老板端同款视觉；**只有登录**）
///
/// 覆盖负责人点名的四件事：
/// 1. **没有注册入口**（回归：账号由管理员创建分配）；
/// 2. **协议勾选**：未勾选 → 提交被拦（按钮禁用 + 中文提示、不发请求）；勾选后可提交（假 API 断言）；
/// 3. **忘记密码**点击出中文提示且不发请求；
/// 4. **品牌头/小山标**存在（`find.byType(AppBrandHeader)`）+ 页脚「工作账号由管理员创建分配」。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  testWidgets('回归：工作端登录页没有注册入口，页脚仍是「工作账号由管理员创建分配」', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    expect(find.textContaining('注册'), findsNothing, reason: '工作端不得出现任何注册入口/文案');
    expect(find.textContaining('没有账号'), findsNothing);
    expect(find.text('工作账号由管理员创建分配'), findsWidgets, reason: '页脚保留既有文案');
    expect(find.text('祁连山电竞内部'), findsOneWidget, reason: '品牌区副文案');
  });

  testWidgets('品牌头与小山标存在（AppBrandHeader + AppQishanMark，176 实色）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    expect(find.byType(AppBrandHeader), findsOneWidget);
    expect(find.byType(AppQishanMark), findsOneWidget);
    final header = tester.widget<AppBrandHeader>(find.byType(AppBrandHeader));
    expect(header.color, AppColors.primary, reason: '#2563EB 实色，禁渐变');
    expect(tester.getSize(find.byType(AppBrandHeader)).height, 176);
    expect(find.byKey(const Key('auth-submit')), findsOneWidget);
  });

  testWidgets('协议未勾选：主按钮禁用 + 点一下给中文提示，且**不发任何请求**', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    await tester.enterText(find.byType(TextField).at(0), 'worker01');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pump();

    expect(find.text('请先阅读并勾选《用户协议》与《隐私政策》'), findsOneWidget);
    expect(adapter.requests, isEmpty, reason: '未勾选协议不得发请求');
    final submit = tester.widget<AppAuthButton>(find.byKey(const Key('auth-submit')));
    expect(submit.onPressed, isNull, reason: '未勾选时主按钮为禁用灰态');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('勾选协议后可提交：/auth/login 真的发出去了（role=worker）', (tester) async {
    final adapter = FakeApiRecorder(
      loginBody: {
        'code': 0,
        'message': 'ok',
        'data': {'accessToken': 'access-token', 'refreshToken': 'refresh-token'},
      },
    );
    await pumpLogin(tester, adapter);

    await tester.enterText(find.byType(TextField).at(0), 'worker01');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.byKey(AppAgreementRow.checkBoxKey));
    await tester.pump();

    await tester.tap(find.byKey(const Key('auth-submit')));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(adapter.requests, contains('/auth/login'));
    final body = adapter.bodyFor('/auth/login');
    expect(body['username'], 'worker01');
    expect(body['role'], 'worker', reason: '工作端登录角色恒为 worker（接口契约不变）');
  });

  testWidgets('忘记密码：入口在，点击**打开找回密码页**（2026-10-05 改为真流程，不再提示暂未开放）', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    expect(find.text('忘记密码'), findsOneWidget);
    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();

    expect(find.byType(ForgotPasswordPage), findsOneWidget, reason: '工作端也要能自助找回（邮箱验证码）');
    expect(find.text('暂未开放自助找回，请联系客服'), findsNothing, reason: '旧的占位提示必须消失');
    expect(adapter.requests, isEmpty, reason: '只是打开页面，不得自动发任何请求');

    Navigator.of(tester.element(find.byType(ForgotPasswordPage))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('协议两个书名号内文字可点 → 打开既有阅读页', (tester) async {
    final adapter = FakeApiRecorder();
    await pumpLogin(tester, adapter);

    await tester.tapOnText(find.textRange.ofSubstring('《用户协议》'));
    await tester.pumpAndSettle();
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
}

Future<void> pumpLogin(WidgetTester tester, FakeApiRecorder adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  await tester.pumpWidget(MaterialApp(home: LoginPage(api: ApiClient(dio: dio))));
  await tester.pumpAndSettle();
}

/// 记录请求的假 API（公开类型：公开函数 pumpLogin 会用到）
class FakeApiRecorder implements HttpClientAdapter {
  FakeApiRecorder({this.loginBody = const {'code': 0, 'message': 'ok', 'data': null}});

  /// 登录响应体（默认无 token：只关心"请求有没有发出去"的用例用它）
  final Map<String, dynamic> loginBody;

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
    final body = options.path.contains('/auth/login') ? loginBody : const {'code': 0, 'message': 'ok', 'data': null};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}
