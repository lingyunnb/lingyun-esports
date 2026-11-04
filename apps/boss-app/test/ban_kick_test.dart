import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/login_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 封禁秒踢 · **老板端**（负责人 2026-10-16：「只要点了封禁直接踢下线，显示踢下线原因是被封，要秒踢」）。
///
/// 本文件只锁老板端这一层的两件事（core 侧的状态契约由 `fish_core` 的
/// `account_ban_kick_test.dart` 覆盖，这里不重复）：
/// ① 服务端 401（`errorCode=ACCOUNT_BANNED`）到达老板端后，`RootGate` 的那一行分支
///    （`auth.loggedIn ? HomeShell : LoginPage`）**真的切到 `LoginPage`**（用户回到登录页）；
/// ② 同时弹出**不可关闭**的封禁提示，标题「账号已被封禁」、正文含**原因与解封时间**、
///    只有「退出」与「重新登录」两个出口。
///
/// 为什么用 `ApiClient.debugDefaultDio`：`AuthStore.fetchMe()` 走的是 AuthStore 内部那个
/// `ApiClient()`（页面注入不进去）—— 这正是该调试钩子存在的理由。
void main() {
  late _BanAdapter server;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false;
    // 必须在任何 AuthStore 静态访问之前设好：单例内部的 ApiClient 在构造时就固化了 Dio
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://boss-ban.local'));
  });

  setUp(() {
    server = _BanAdapter();
    ApiClient.debugDefaultDio!.httpClientAdapter = server;
    AuthStore.instance.clearAuthFailure();
    AuthStore.instance.debugSetSession(accessToken: 'BOSS-PRIMARY');
  });

  tearDown(() {
    AuthStore.instance.clearAuthFailure();
    AuthStore.instance.debugSetSession();
  });

  /// 复刻 `RootGate` 的判定分支（真 `LoginPage`，不是占位文本）：
  /// `RootGate.build` 里就这一句 `auth.loggedIn ? const HomeShell() : const LoginPage()`，
  /// 外层的 `AnimatedBuilder` 同样是 `RootGate` 的实现（少了它 child 不会随登录态重建）。
  Widget rootGateStub() => AnimatedBuilder(
        animation: AuthStore.instance,
        builder: (_, _) => SessionKickListener(
          child: AuthStore.instance.loggedIn ? const Text('主框架') : const LoginPage(),
        ),
      );

  testWidgets('① 封禁 401 → 清本地令牌 → RootGate 切到登录页', (tester) async {
    server.banned = true;
    // ⚠️ 不在测试体里 await 这个 HTTP future：testWidgets 跑在 FakeAsync 里，直接 await 会互等吊死；
    // 让它自己跑、靠 _settle 推进假时钟（核心包那边踩过两次，别再改回去）
    unawaited(AuthStore.instance.fetchMe().catchError((_) {}));

    await tester.pumpWidget(MaterialApp(home: rootGateStub()));
    await _settle(tester);

    expect(AuthStore.instance.loggedIn, isFalse, reason: '封禁必须清掉本地令牌');
    expect(find.byType(LoginPage), findsOneWidget, reason: 'RootGate 必须切回登录页');
    expect(find.text('主框架'), findsNothing);
  });

  testWidgets('② 封禁提示不可关闭，且写明原因与解封时间（只留「退出」/「重新登录」）', (tester) async {
    server.banned = true;
    unawaited(AuthStore.instance.fetchMe().catchError((_) {}));

    await tester.pumpWidget(MaterialApp(home: rootGateStub()));
    await _settle(tester);

    expect(find.text('账号已被封禁'), findsOneWidget, reason: '标题必须点明"被封"，而不是「登录状态变更」');
    expect(find.textContaining('违规代练'), findsOneWidget, reason: '必须显示封禁原因');
    expect(find.textContaining('2026-11-01 12:00'), findsOneWidget, reason: '必须显示解封时间');
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);

    // 点遮罩（对话框之外）不关闭：用户必须先看到"为什么被封"
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);
    expect(find.text('账号已被封禁'), findsOneWidget, reason: 'barrierDismissible=false，遮罩不可关闭');

    // 「重新登录」→ 关闭提示（人已经在登录页，可直接重新登录/换号）
    await tester.tap(find.text('重新登录'));
    await _settle(tester);
    expect(find.text('账号已被封禁'), findsNothing);
    expect(AuthStore.instance.authFailureMessage, isNull);
  });

  testWidgets('③ 回归：非封禁的普通踢出仍是旧形态（不误判、不多按钮）', (tester) async {
    server.replaced = true;
    unawaited(AuthStore.instance.fetchMe().catchError((_) {}));

    await tester.pumpWidget(MaterialApp(home: rootGateStub()));
    await _settle(tester);

    expect(find.text('登录状态变更'), findsOneWidget);
    expect(find.text('账号已在其他设备登录'), findsOneWidget);
    expect(find.text('退出'), findsNothing);
  });
}

/// **逐帧推进**：本文件有 `showDialog`，且核心包那边见过 `pumpAndSettle` 一路泵到 10 分钟超时
/// （表现为"测试吊死"）→ 统一用**有界** pump（8 × 50ms 假时钟），任何情况下都会返回。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 假通道：`/auth/me` 按开关返回封禁 401 / 被顶 401；其余路径一律 200 空 data
/// （登录页等组件可能顺手拉一点配置，不该因为假通道缺路由而炸）。
class _BanAdapter implements HttpClientAdapter {
  bool banned = false;
  bool replaced = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/auth/me') {
      if (banned) {
        return _json({
          'code': 401,
          'message': '账号已被封禁：违规代练（解封时间：2026-11-01 12:00）',
          'data': null,
          'errorCode': 'ACCOUNT_BANNED',
        }, 401);
      }
      if (replaced) {
        return _json({'code': 401, 'message': '账号已在其他设备登录', 'data': null}, 401);
      }
    }
    return _json({'code': 0, 'message': 'ok', 'data': const <String, dynamic>{}}, 200);
  }

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Map<String, dynamic> body, int status) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}
