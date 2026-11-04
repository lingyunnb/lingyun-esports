import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
// `StringCodec`（模拟回前台的生命周期平台消息）来自 services；
// `Uint8List` 也由它一并提供 → **不要**再单独 import 'dart:typed_data'（analyze 会报 unnecessary_import）
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 封禁秒踢 · 客户端侧（core）：**收到封禁码 → 清令牌 + 不可关闭提示（含原因与解封时间）**
///
/// 负责人原话（2026-10-16）：「我设置封禁的号为啥没有直接被踢下线，重新划掉 app 后台还能用。
/// 要求做到的效果：**即使 app 正在被使用，只要点了封禁直接踢下线，显示踢下线原因是被封，要秒踢**」。
///
/// 本文件锁死四件事（对应验收单 ①③④）：
/// ① 封禁 401（`errorCode=ACCOUNT_BANNED`）→ 清本地令牌（`loggedIn=false` → RootGate 回登录页）
///    + **原样保留**服务端那句「账号已被封禁：<原因>（解封时间：…）」+ 标记"这是封禁"；
/// ② 非封禁的 401 **不会**被误判成封禁（历史行为一字未改）；
/// ③ 封禁提示**不可关闭**、标题与按钮与普通"登录失效"不同（只有「退出」与「重新登录」）；
/// ④ 切回前台（`didChangeAppLifecycleState(resumed)`）会发**一个**轻量校验 `GET /auth/me`
///    （未登录时不发；不做任何全量刷新）。
void main() {
  late _FakeAdapter server;

  setUpAll(() {
    // 测试环境：不落安全存储（flutter_secure_storage 无平台实现）
    AuthStore.debugStorageDisabled = true;
    // 不建真 WS
    RealtimeClient.shared.debugDisabled = true;
    // 关闭接口缓存：避免同一 fixture 第二次命中缓存影响"发了几次请求"的断言
    ApiClient.cacheEnabled = false;
    // 让 AuthStore 单例内部那个 `ApiClient()` 也走假通道（必须在单例首次被触碰之前设置）
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://ban-kick.local'));
  });

  setUp(() {
    server = _FakeAdapter();
    ApiClient.debugDefaultDio!.httpClientAdapter = server;
    AuthStore.instance.clearAuthFailure();
    AuthStore.instance.debugSetSession(accessToken: 'PRIMARY-TOKEN');
  });

  tearDown(() {
    AuthStore.instance.clearAuthFailure();
    AuthStore.instance.debugSetSession();
  });

  // =====================================================================================
  // ① 封禁 401 → 清令牌 + 封禁原文
  // =====================================================================================

  test('① 封禁 401：清本地令牌（→ 回登录页）+ 一字不改地保留封禁原文', () async {
    server.banned = true;

    await expectLater(AuthStore.instance.fetchMe(), throwsA(isA<ApiException>()));
    // 钩子是同步派发的，但它内部的落地动作（清令牌 / 记文案 / 打标记）要过若干 await ——
    // 等事件队列排空再断言，否则断言到的是"还没跑完的中间态"。
    await pumpEventQueue();

    expect(AuthStore.instance.loggedIn, isFalse, reason: '封禁必须清掉本地令牌（RootGate 据此回登录页）');
    expect(AuthStore.instance.accessToken, isNull);
    expect(AuthStore.instance.authFailureIsBanned, isTrue, reason: '必须能被程序化识别成"封禁"而不是普通失效');
    expect(
      AuthStore.instance.authFailureMessage,
      '账号已被封禁：违规代练（解封时间：2026-11-01 12:00）',
      reason: '服务端原文（含原因与解封时间）必须原样交给 UI，客户端不得改写/截断',
    );
    expect(AuthStore.instance.authFailureMessage, isNot(contains('登录已失效')),
        reason: '绝不能退化成那句看不出"被封"的通用文案');
  });

  test('① 封禁原文里没有原因时也照样展示（服务端省略原因段是它的口径）', () async {
    server.banned = true;
    server.bannedMessage = '账号已被封禁（永久）';

    await expectLater(AuthStore.instance.fetchMe(), throwsA(isA<ApiException>()));
    // 钩子是同步派发的，但它内部的落地动作（清令牌 / 记文案 / 打标记）要过若干 await ——
    // 等事件队列排空再断言，否则断言到的是"还没跑完的中间态"。
    await pumpEventQueue();

    expect(AuthStore.instance.authFailureIsBanned, isTrue);
    expect(AuthStore.instance.authFailureMessage, '账号已被封禁（永久）');
  });

  // =====================================================================================
  // ② 不误判（历史行为不变）
  // =====================================================================================

  test('② 非封禁的 401（无 errorCode）不会被误判成封禁，也不动会话', () async {
    server.plain401 = true;

    await expectLater(AuthStore.instance.fetchMe(), throwsA(isA<ApiException>()));
    // 钩子是同步派发的，但它内部的落地动作（清令牌 / 记文案 / 打标记）要过若干 await ——
    // 等事件队列排空再断言，否则断言到的是"还没跑完的中间态"。
    await pumpEventQueue();

    expect(AuthStore.instance.authFailureIsBanned, isFalse);
    expect(AuthStore.instance.authFailureMessage, isNull, reason: '普通"登录已失效"不弹封禁提示');
    expect(AuthStore.instance.loggedIn, isTrue, reason: 'primary 的普通 401 处理链一字未改（不许顺手放宽/收紧）');
  });

  test('② "账号已在其他设备登录"仍走旧的踢出链路（标题与按钮都不是封禁版）', () async {
    server.replaced = true;

    await expectLater(AuthStore.instance.fetchMe(), throwsA(isA<ApiException>()));
    // 钩子是同步派发的，但它内部的落地动作（清令牌 / 记文案 / 打标记）要过若干 await ——
    // 等事件队列排空再断言，否则断言到的是"还没跑完的中间态"。
    await pumpEventQueue();

    expect(AuthStore.instance.authFailureIsBanned, isFalse, reason: '被顶下线 ≠ 被封禁');
    expect(AuthStore.instance.authFailureMessage, '账号已在其他设备登录');
  });

  // =====================================================================================
  // ③ 不可关闭的封禁提示（Widget 层）
  // =====================================================================================

  testWidgets('③ 封禁提示：不可关闭 + 标题「账号已被封禁」+ 只有「退出」与「重新登录」', (tester) async {
    server.banned = true;
    /**
     * 触发一次**真实**的 401（服务端 `errorCode=ACCOUNT_BANNED` 走完整链路）。
     *
     * ⚠️ 两个坑（本文件各踩过一次，别再改回去）：
     * 1. **不在测试体里 `await` 它**：testWidgets 的测试体跑在 FakeAsync 里，微任务要等 `pump`
     *    才被 flush → 直接 await 一个 HTTP future 会互相等，表现为"测试吊死"；
     *    让它自己跑、靠下面的 `_settle` 推进假时钟即可（与 ④ 的路径完全一致）。
     * 2. 不吞异常会被判成未捕获错误：`fetchMe` 必然抛 401，这里显式吞掉。
     */
    unawaited(AuthStore.instance.fetchMe().catchError((_) {}));

    await tester.pumpWidget(MaterialApp(home: _rootGateStub()));
    await _settle(tester);

    expect(find.text('登录页'), findsOneWidget, reason: '清令牌后 RootGate 必须切回登录页');
    expect(find.text('账号已被封禁'), findsOneWidget);
    expect(find.textContaining('违规代练'), findsOneWidget, reason: '提示里必须有封禁原因');
    expect(find.textContaining('2026-11-01 12:00'), findsOneWidget, reason: '提示里必须有解封时间');
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);

    // 点遮罩（对话框之外）不应关闭（barrierDismissible: false）
    await tester.tapAt(const Offset(5, 5));
    await _settle(tester);
    expect(find.text('账号已被封禁'), findsOneWidget, reason: '封禁提示不可关闭');

    // 「重新登录」关闭 → 标记被清理（用户可重新登录/换号）
    await tester.tap(find.text('重新登录'));
    await _settle(tester);
    expect(find.text('账号已被封禁'), findsNothing);
    expect(AuthStore.instance.authFailureMessage, isNull);
  });

  testWidgets('③ 普通踢出提示的标题/按钮保持历史形态（不是封禁版）', (tester) async {
    server.replaced = true;
    unawaited(AuthStore.instance.fetchMe().catchError((_) {}));

    await tester.pumpWidget(MaterialApp(home: _rootGateStub()));
    await _settle(tester);

    expect(find.text('登录状态变更'), findsOneWidget);
    expect(find.text('账号已在其他设备登录'), findsOneWidget);
    expect(find.text('退出'), findsNothing, reason: '「退出」只属于封禁版提示');
  });

  // =====================================================================================
  // ④ 切回前台的轻量校验
  // =====================================================================================

  testWidgets('④ 切回前台：发且只发一个 GET /auth/me（不做全量刷新）', (tester) async {
    server.reset();

    await tester.pumpWidget(const MaterialApp(
      home: SessionKickListener(child: Text('主框架')),
    ));
    await tester.pump();
    expect(server.calls, 0, reason: '只是挂载组件不该发请求');

    await _resumeForeground(tester);

    expect(server.paths, ['/auth/me'], reason: '回前台只允许一个轻量校验请求（跨境 RTT 下不许全量刷新）');
    expect(server.auths.single, 'Bearer PRIMARY-TOKEN', reason: '用当前 primary 令牌校验');
  });

  testWidgets('④ 未登录（本地无令牌）时切回前台不发任何请求', (tester) async {
    AuthStore.instance.debugSetSession();
    server.reset();

    await tester.pumpWidget(const MaterialApp(
      home: SessionKickListener(child: Text('登录页')),
    ));
    await _resumeForeground(tester);

    expect(server.calls, 0);
  });

  testWidgets('④ 切回前台发现已被封：清令牌 + 弹封禁提示（"划掉后台还能用"的直接修复）', (tester) async {
    server.banned = true;

    await tester.pumpWidget(MaterialApp(home: _rootGateStub()));
    await tester.pump();
    expect(find.text('主框架'), findsOneWidget, reason: '切回前台之前还停在主框架（正是负责人看到的现象）');

    await _resumeForeground(tester);

    expect(find.text('登录页'), findsOneWidget);
    expect(find.text('账号已被封禁'), findsOneWidget);
    expect(find.textContaining('违规代练'), findsOneWidget);
  });
}

/// 模拟"App 从后台切回前台"：走 `flutter/lifecycle` 平台通道（框架自身的做法），
/// 不直接调 `@protected` 的 `handleAppLifecycleStateChanged`。
///
/// 先发 `inactive` 再发 `resumed`：保证无论测试初始生命周期状态如何，
/// `inactive → resumed` 这条边都必然产生一次 `didChangeAppLifecycleState(resumed)`。
Future<void> _resumeForeground(WidgetTester tester) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage('AppLifecycleState.inactive'),
    (_) {},
  );
  await messenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage('AppLifecycleState.resumed'),
    (_) {},
  );
  await _settle(tester);
}

/// **逐帧推进**（本文件**刻意不用 `pumpAndSettle`**）：有 `showDialog` 与生命周期回调时，
/// 只要有一处持续调度帧，`pumpAndSettle` 会一路泵到 10 分钟超时才报错 —— 表现就是"测试吊死"。
/// 这里固定推 8 帧 × 50ms（= 假时钟 400ms），足够走完对话框的进出场动画与几个 await 链，
/// 且**任何情况下都会返回**。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 复刻 `RootGate` 的那一行分支（`SessionKickListener(child: auth.loggedIn ? 主框架 : 登录页)`）
/// **加上 RootGate 自己的 `AnimatedBuilder`** —— 少了它就只能断言"那一帧的 child"，
/// 证不出"清令牌之后界面真的切到登录页"（child 是构造期固定的 widget，必须由外层重建）。
Widget _rootGateStub() => AnimatedBuilder(
      animation: AuthStore.instance,
      builder: (_, __) => SessionKickListener(
        child: AuthStore.instance.loggedIn ? const Text('主框架') : const Text('登录页'),
      ),
    );

final class _FakeAdapter implements HttpClientAdapter {
  bool banned = false;
  bool replaced = false;
  bool plain401 = false;
  String bannedMessage = '账号已被封禁：违规代练（解封时间：2026-11-01 12:00）';

  final List<String> paths = [];
  final List<String> auths = [];
  int get calls => paths.length;

  /// 清掉已记录的请求（断言"发了几次"之前调用）
  void reset() {
    paths.clear();
    auths.clear();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    auths.add(options.headers['Authorization'] as String? ?? '');
    if (banned && options.path == '/auth/me') {
      return _json({
        'code': 401,
        'message': bannedMessage,
        'data': null,
        'errorCode': 'ACCOUNT_BANNED',
      }, 401);
    }
    if (replaced && options.path == '/auth/me') {
      return _json({'code': 401, 'message': '账号已在其他设备登录', 'data': null}, 401);
    }
    if (plain401 && options.path == '/auth/me') {
      return _json({'code': 401, 'message': '登录已失效，请重新登录', 'data': null}, 401);
    }
    return _json({
      'code': 0,
      'message': 'ok',
      'data': {'id': '1', 'username': 'u', 'uid': 'u1', 'nickname': 'n', 'role': 'user'},
    }, 200);
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
