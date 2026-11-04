/// 打手态 · **客服大厅**（负责人 2026-10-08：「有人申请客服 → 有客服权限的人用打手端主动接，
/// 就像接单大厅那样」）。
///
/// 本文件把任务书的 ①–⑬ 号验收逐条钉死，其中**负向用例与正向用例同等重要**：
///   - ②「无客服权限 → 仍然只有 3 项」是"不许留空位/占位"的**唯一**防线，
///     也是"老板态与存量打手态一行不改"的回归网；
///   - ③「权限刚被撤销 → 中文说明 + 没有接入按钮」防的是"留一个点了必然失败的按钮"；
///   - ⑩「连点两次只发一次请求」防的是**抢占式**下最容易出的双请求。
///
/// 字段名以**服务端已落地的实现**为准（`server/src/modules/chat/chat.service.ts#csHall` /
/// `#claimCsConversation`，2026-10-08 核实）：
///   `{conversationId, userNickname, userUid, preview, waitedSeconds, waitedText, msgCount}`。
/// 任务书早期给的另一套（`bossNickname/summary/waitSeconds/messageCount`）客户端也认
/// （见 `CsHallItem.fromJson`），本文件两头都测。
///
/// 变异验证（报告里贴红/绿）：
///   - 去掉权限门控（无条件 4 项）→ ② 必须红；
///   - 去掉"claim 失败后刷新列表" → ⑨ 必须红。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录"打到了哪些请求"的假服务器（按 "METHOD /path" 路由；[hold] 时挂住不回，用来断言
/// "缓存先上屏、网络后到"）
class _FakeServer implements HttpClientAdapter {
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};
  final List<String> requests = <String>[];

  /// true = 所有响应挂起，直到 [release] 被调用（断言"缓存秒开"用）
  bool paused = false;
  Completer<void>? _gate;

  void ok(String key, Object? data) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}), status: 200);

  /// 失败：服务端中文原文 + 业务码（403 = 无客服权限；409 = 已被其他客服接入）
  void fail(String key, {int code = 500, String message = '服务端暂时不可用'}) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': code, 'message': message, 'data': null}), status: code);

  int calls(String key) => requests.where((String r) => r == key).length;

  int get total => requests.length;

  void hold() {
    paused = true;
    _gate = Completer<void>();
  }

  void release() {
    paused = false;
    if (_gate != null && !_gate!.isCompleted) _gate!.complete();
    _gate = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    if (paused && _gate != null) await _gate!.future;
    final ({String body, int status})? resp = route[key];
    if (resp == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      resp.body,
      resp.status,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 极简事件总线：把 `RealtimeClient.shared.on` 截下来，让测试**能真的投递服务端事件**
/// （`debugDisabled = true` 时没有 socket，没有这个钩子就永远触发不到 `cs:new` / `cs:claimed`）
class _Bus {
  final Map<String, List<void Function(dynamic)>> _h = <String, List<void Function(dynamic)>>{};

  void Function() register(String event, void Function(dynamic data) handler) {
    (_h[event] ??= <void Function(dynamic)>[]).add(handler);
    return () => _h[event]?.remove(handler);
  }

  int subscribers(String event) => (_h[event] ?? const <void Function(dynamic)>[]).length;

  void fire(String event, dynamic data) {
    for (final void Function(dynamic) h in List<void Function(dynamic)>.of(_h[event] ?? const [])) {
      h(data);
    }
  }

  void clear() => _h.clear();
}

const String kHall = 'GET /worker/cs/hall';
const String kClaim = 'POST /worker/cs/hall/c1/claim';

/// 等待时长那个 Text 的 key（生产同源：`IdentityWorkerCsHallPageState.csHallWaitKey`）
Key csHallWaitKey(String conversationId) => IdentityWorkerCsHallPageState.csHallWaitKey(conversationId);

/// 摆好"打手态 + 客服权限"（权限标志就是服务端 `/auth/me` 的 `worker.canServeCustomer`）
void _loginAsWorker({required bool canServeCustomer}) {
  AuthStore.instance.debugSetIdentity(
    identity: AppIdentity.worker,
    companionToken: 'companion-worker-token',
    workerMe: AuthMe.fromJson(<String, dynamic>{
      'id': 'w1',
      'nickname': '打手甲',
      'uid': 'W0001',
      'worker': <String, dynamic>{
        'workerNo': 'W20260118',
        'canTakeOrder': true,
        'canServeCustomer': canServeCustomer,
      },
    }),
  );
}

void main() {
  late _FakeServer server;
  late Dio dio;
  late _Bus bus;

  /// **每个测试一个独立的 apiBase**：`ApiClient._inflight` 是**静态**表（键含 apiBase），
  /// 若某个用例在"请求还在飞"时结束，同键的后续用例会拿到那个永不完成的 future
  /// （表现为"一个请求都没发、页面一直转圈"）。换地址就等于换键，这类串扰从根上不可能发生。
  int seq = 0;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    final String base = 'http://cs-hall-${seq++}.local';
    server = _FakeServer();
    dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = server;
    bus = _Bus();
    RealtimeClient.shared.debugOnOverride = bus.register;
    RealtimeClient.shared.debugResetCounters();
    // 打手态会话（companion）：本页所有请求都带它
    AuthStore.instance.debugSetSession(accessToken: 'boss-primary');
    _loginAsWorker(canServeCustomer: true);
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiClient.debugDefaultDio = null;
    RealtimeClient.shared.debugOnOverride = null;
    bus.clear();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: null);
  });

  /// 一条待接入咨询 —— **按服务端已落地的真实字段名**（`chat.service.ts#csHall`）
  Map<String, dynamic> item({
    required String id,
    String nickname = '林老板',
    String uid = 'B88231',
    String summary = '想问问王者荣耀星耀段位陪练怎么收费',
    int waitSeconds = 90,
    String? waitText,
    int messageCount = 1,
  }) =>
      <String, dynamic>{
        'conversationId': id,
        'userNickname': nickname,
        'userUid': uid,
        'preview': summary,
        'waitedSeconds': waitSeconds,
        if (waitText != null) 'waitedText': waitText,
        'msgCount': messageCount,
      };

  Map<String, dynamic> hallBody(List<Map<String, dynamic>> list, {int? waitingTotal, int online = 2}) =>
      <String, dynamic>{
        'list': list,
        'total': waitingTotal ?? list.length,
        'page': 1,
        'pageSize': 20,
        'waitingTotal': waitingTotal ?? list.length,
        'onlineCsCount': online,
      };

  Widget bare(Widget child) => MaterialApp(home: child);

  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (int i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 把已经在飞的 toast / 轻提示计时器排干（否则测试结束会报 `!timersPending`）
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await settle(tester, times: 4);
  }

  Widget page({IdentityWorkerChatOpener? openChat, VoidCallback? onSwitchBack, void Function(String)? onClaimed}) =>
      MaterialApp(
        home: Scaffold(
          body: IdentityWorkerCsHallPage(
            api: ApiClient(dio: dio),
            openChat: openChat,
            onSwitchBack: onSwitchBack,
            onClaimed: onClaimed,
          ),
        ),
      );

  Future<void> pumpHall(
    WidgetTester tester, {
    IdentityWorkerChatOpener? openChat,
    void Function(String)? onClaimed,
  }) async {
    await tester.pumpWidget(page(openChat: openChat, onClaimed: onClaimed));
    await settle(tester);
  }

  // ==========================================================================
  // ① 权限门控（有客服权限 → 4 项，新增项就是「客服」）
  // ==========================================================================
  group('① 有客服权限 → 底部 4 项，新增项是「客服」', () {
    test('常量层：4 项 + 顺序 接单/消息/客服/我的（新增的那一项恰好是「客服」）', () {
      expect(IdentityWorkerMeta.navItemCountFor(canServeCustomer: true), 4);
      expect(IdentityWorkerMeta.navLabelsFor(canServeCustomer: true), ['接单', '消息', '客服', '我的']);
      // 口径说明：任务书「底部第 4 项『客服』」指的是**新增出来的第 4 个入口**；
      // 同一条需求里给出的顺序是「接单 / 消息 / 客服 / 我的」（「我的」永远收尾），本实现以顺序为准。
      final Set<String> added = IdentityWorkerMeta.navLabelsFor(canServeCustomer: true)
          .toSet()
          .difference(IdentityWorkerMeta.navLabels.toSet());
      expect(added, {'客服'}, reason: '有权限相对无权限**只多一项**，且那一项就是「客服」');
    });

    testWidgets('渲染层：底部导航真的渲染 4 项，且第 3 项文案是「客服」', (tester) async {
      await tester.pumpWidget(
        bare(
          IdentityWorkerShellScaffold(
            body: const SizedBox.shrink(),
            currentIndex: 0,
            onTap: (_) {},
            canServeCustomer: true,
          ),
        ),
      );
      final AppPlainBottomNav nav = tester.widget<AppPlainBottomNav>(find.byType(AppPlainBottomNav));
      expect(nav.items.length, 4, reason: '生产同源的 navItemsFor(true) 必须给 4 项');
      expect(nav.items.map((e) => e.label).toList(), ['接单', '消息', '客服', '我的']);
      expect(find.text('客服'), findsOneWidget);
      // 4 项等分：每个 tab 宽度相同（Expanded），不出现"留空位"
      final double w0 = tester.getSize(find.byType(InkWell).at(0)).width;
      final double w2 = tester.getSize(find.byType(InkWell).at(2)).width;
      expect(w2, closeTo(w0, 0.5), reason: '4 项等分');
      expect(tester.takeException(), isNull);
    });
  });

  // ==========================================================================
  // ② **负向**：无客服权限 → 仍然 3 项，逐项与改动前一致
  // ==========================================================================
  group('② 负向 · 无客服权限 → 仍然 3 项（不留空位/占位）', () {
    test('常量层：3 项 + 顺序与改动前逐项一致', () {
      expect(IdentityWorkerMeta.navItemCountFor(canServeCustomer: false), 3);
      expect(IdentityWorkerMeta.navItemCount, 3, reason: '无权限基线常量本身必须还是 3');
      expect(IdentityWorkerMeta.navLabelsFor(canServeCustomer: false), ['接单', '消息', '我的']);
      expect(IdentityWorkerMeta.navLabelsFor(canServeCustomer: false), IdentityWorkerMeta.navLabels);
    });

    test('常量层：无权限列表里**根本没有**「客服」这一项（不是灰掉、不是占位）', () {
      final List<String> labels = IdentityWorkerMeta.navLabelsFor(canServeCustomer: false);
      expect(labels.contains('客服'), isFalse);
      expect(IdentityWorkerShell.navItems.length, 3);
      expect(IdentityWorkerShell.navItems[2].label, '我的', reason: '「我的」仍收尾在第 3 位');
    });

    testWidgets('渲染层：底部导航只有 3 项、没有「客服」、也没有任何空位', (tester) async {
      await tester.pumpWidget(
        bare(
          IdentityWorkerShellScaffold(
            body: const SizedBox.shrink(),
            currentIndex: 0,
            onTap: (_) {},
          ),
        ),
      );
      final AppPlainBottomNav nav = tester.widget<AppPlainBottomNav>(find.byType(AppPlainBottomNav));
      expect(nav.items.length, 3);
      expect(nav.items.map((e) => e.label).toList(), ['接单', '消息', '我的']);
      expect(find.text('客服'), findsNothing, reason: '无权限时一个字都不许出现');
      // 三项等分：宽度 == 屏宽/3（若偷偷留了空位就会窄一截）
      final double w = tester.getSize(find.byType(InkWell).at(0)).width;
      final double full = tester.getSize(find.byType(AppPlainBottomNav)).width;
      expect(w, closeTo(full / 3, 0.5), reason: '等分三项 —— 留空位会让每项变窄');
      expect(tester.takeException(), isNull);
    });

    test('门控来源 = AuthStore.canServeCustomer（`/auth/me` 的 worker.canServeCustomer）', () {
      _loginAsWorker(canServeCustomer: false);
      expect(AuthStore.instance.canServeCustomer, isFalse);
      _loginAsWorker(canServeCustomer: true);
      expect(AuthStore.instance.canServeCustomer, isTrue);
      // 老板态（`/auth/me` 里没有 worker 段）→ 天然 false → 老板态底部导航一行不改
      AuthStore.instance.debugClearIdentity();
      AuthStore.instance.debugSetSession(
        accessToken: 'boss-primary',
        me: AuthMe.fromJson(<String, dynamic>{'id': 'b1', 'nickname': '老板', 'role': 'user'}),
      );
      expect(AuthStore.instance.canServeCustomer, isFalse);
    });
  });

  // ==========================================================================
  // ③ 权限刚被撤销（服务端中文 403）→ 说明态 + 没有接入按钮
  // ==========================================================================
  group('③ 权限刚被撤销 → 中文说明 + 不显示「接入」按钮', () {
    testWidgets('GET hall 回 403「无客服权限」→ 显示中文说明且**一个接入按钮都没有**', (tester) async {
      server.fail(kHall, code: 403, message: '无客服权限');
      await pumpHall(tester);

      expect(find.text('你没有客服权限'), findsOneWidget);
      expect(find.textContaining('客服权限由平台单独开通'), findsOneWidget, reason: '给一个下一步，不是干巴巴一句拒绝');
      expect(find.text(IdentityWorkerCsHallPage.claimLabel), findsNothing, reason: '不许留一个点了必然失败的按钮');
      expect(find.textContaining('当前没有等待接入的咨询'), findsNothing, reason: '不是空态，是权限态');
      expect(tester.takeException(), isNull);
    });

    testWidgets('403 但服务端给了别的原文 → 原文优先，仍然没有接入按钮', (tester) async {
      server.fail(kHall, code: 403, message: '客服权限已被收回');
      await pumpHall(tester);

      expect(find.textContaining('客服权限已被收回'), findsWidgets);
      expect(find.text(IdentityWorkerCsHallPage.claimLabel), findsNothing);
    });

    testWidgets('**负向**：普通 500 走"报错 + 重试"，**不**被误判成权限态', (tester) async {
      server.fail(kHall, code: 500, message: '服务端暂时不可用');
      await pumpHall(tester);

      expect(find.textContaining('服务端暂时不可用'), findsWidgets);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('你没有客服权限'), findsNothing);
    });
  });

  // ==========================================================================
  // ④⑤⑥⑦ 列表 / 颜色 / 空态 / 失败态
  // ==========================================================================
  group('④ 列表渲染昵称 / 中文ID / 摘要 / 等待时长', () {
    testWidgets('三要素都在，等待时长用服务端原文（等待 8 分钟）', (tester) async {
      server.ok(
        kHall,
        hallBody([
          item(id: 'c1', nickname: '林老板', uid: 'B88231', summary: '星耀段位陪练怎么收费', waitSeconds: 480),
          item(id: 'c2', nickname: '周老板', uid: 'B90117', summary: '【图片】', waitSeconds: 30, messageCount: 2),
        ]),
      );
      await pumpHall(tester);

      expect(find.text('林老板'), findsOneWidget);
      expect(find.text('B88231'), findsOneWidget, reason: '服务端给了中文 ID 就显示');
      expect(find.text('星耀段位陪练怎么收费'), findsOneWidget);
      expect(find.text('等待 8 分钟'), findsOneWidget);
      expect(find.text('周老板'), findsOneWidget);
      expect(find.text('刚刚提交'), findsOneWidget,
          reason: '服务端 humanWait 的「刚刚」要补成「刚刚提交」，不能出现「等待 刚刚」');
      expect(find.textContaining('等待 刚刚'), findsNothing);
      expect(find.text('2 条消息'), findsOneWidget);
    });

    testWidgets('服务端不下发 waitedText 时，客户端自己格式化（与 humanWait 同口径）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1', waitSeconds: 3750)])); // 62 分钟
      await pumpHall(tester);
      expect(find.text('等待 1 小时 2 分钟'), findsOneWidget);
    });

    test('格式化逐档对齐服务端 humanWait', () {
      expect(CsHallItem.formatWait(0), '刚刚');
      expect(CsHallItem.formatWait(59), '刚刚');
      expect(CsHallItem.formatWait(60), '1 分钟');
      expect(CsHallItem.formatWait(3599), '59 分钟');
      expect(CsHallItem.formatWait(3600), '1 小时 0 分钟');
      expect(CsHallItem.formatWait(86400), '1 天 0 小时');
      expect(CsHallItem.formatWait(-5), '刚刚', reason: '负数不许炸');
    });

    test('任务书早期的另一套字段名（bossNickname/summary/waitSeconds/messageCount）也认得', () {
      final CsHallItem it = CsHallItem.fromJson(<String, dynamic>{
        'conversationId': 'c9',
        'bossNickname': '任务书口径老板',
        'bossDisplayId': 'B10001',
        'summary': '任务书口径的摘要',
        'waitSeconds': 700,
        'waitText': '11 分钟',
        'messageCount': 4,
      });
      expect(it.bossNickname, '任务书口径老板');
      expect(it.bossDisplayId, 'B10001');
      expect(it.summary, '任务书口径的摘要');
      expect(it.waitSeconds, 700);
      expect(it.messageCount, 4);
      expect(it.waitLabel, '等待 11 分钟');
    });
  });

  group('⑤ 等待超过 5 分钟 → 小字金 #935F06（颜色 token 断言）', () {
    testWidgets('第 1 条 301 秒（>5 分钟）用 goldText，第 2 条 300 秒（=5 分钟）仍用灰', (tester) async {
      expect(AppColors.goldText, const Color(0xFF935F06), reason: '11.5px 属小字档 → 用两档金里的小字金');
      server.ok(
        kHall,
        hallBody([
          item(id: 'c1', nickname: '超时老板', waitSeconds: 301),
          item(id: 'c2', nickname: '卡线老板', waitSeconds: 300),
        ]),
      );
      await pumpHall(tester);

      final TextStyle long = tester.widget<Text>(find.byKey(csHallWaitKey('c1'))).style!;
      final TextStyle edge = tester.widget<Text>(find.byKey(csHallWaitKey('c2'))).style!;
      expect(long.color, AppColors.goldText, reason: '>5 分钟必须小字金（11.5px 白底 5.41:1）');
      expect(long.color, const Color(0xFF935F06));
      expect(long.fontWeight, FontWeight.w600, reason: '小字金同时加粗一档（颜色之外的第二重强调）');
      expect(edge.color, isNot(AppColors.goldText), reason: '=300 秒不算超时（阈值 300，取严格大于）');
      expect(edge.color, AppColors.mutedText);
    });

    test('阈值常量 = 300 秒（5 分钟），与需求一致', () {
      expect(IdentityWorkerCsHallPage.longWaitSeconds, 300);
      expect(
        const CsHallItem(
          conversationId: 'x',
          bossNickname: 'n',
          bossDisplayId: '',
          summary: '',
          waitSeconds: 300,
          waitText: '',
          messageCount: 0,
        ).isLongWait,
        isFalse,
      );
      expect(
        const CsHallItem(
          conversationId: 'x',
          bossNickname: 'n',
          bossDisplayId: '',
          summary: '',
          waitSeconds: 301,
          waitText: '',
          messageCount: 0,
        ).isLongWait,
        isTrue,
      );
    });
  });

  group('⑥ 空态', () {
    testWidgets('空列表 → 「当前没有等待接入的咨询」（语气与接单大厅一致）', (tester) async {
      server.ok(kHall, hallBody(const <Map<String, dynamic>>[], online: 0));
      await pumpHall(tester);

      expect(find.text(IdentityWorkerCsHallPage.emptyTitle), findsOneWidget);
      expect(find.textContaining('老板发起咨询后会实时出现在这里'), findsOneWidget);
      expect(find.text(IdentityWorkerCsHallPage.claimLabel), findsNothing);
      // N=0 也显示统计行，只是弱化
      expect(find.text('待接入 '), findsOneWidget, reason: 'N=0 时统计行照旧显示（隐藏会让人以为这行坏了）');
      expect(find.text('0'), findsWidgets);
    });
  });

  group('⑦ 失败态：中文原因 + 重试（**不允许无限转圈**）', () {
    testWidgets('500 → 中文原文 + 「重试」；且**没有**整页常驻转圈', (tester) async {
      server.fail(kHall, code: 500, message: '服务端暂时不可用');
      await pumpHall(tester);

      expect(find.text('服务端暂时不可用'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '失败必须落地成可读的字，不是一直转圈');
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「重试」→ 服务端恢复 → 列表出现（错误态消失）', (tester) async {
      server.fail(kHall, code: 500, message: '服务端暂时不可用');
      await pumpHall(tester);
      expect(find.text('重试'), findsOneWidget);

      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));
      await tester.tap(find.text('重试'));
      await settle(tester);

      expect(find.text('服务端暂时不可用'), findsNothing);
      expect(find.text('林老板'), findsOneWidget);
    });
  });

  // ==========================================================================
  // ⑧⑨⑩ 抢占
  // ==========================================================================
  group('⑧ 点「接入」→ 调 claim → 成功进入会话', () {
    testWidgets('请求打到 POST .../claim，并进入该会话详情（openChat 拿到同一个会话 id）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1')]));
      server.ok(kClaim, <String, dynamic>{
        'ok': true,
        'conversationId': 'c1',
        'alreadyClaimed': false,
        'workerUserId': 'w1',
        'workerNo': 'W20260118',
      });

      final List<IdentityWorkerChatTarget> opened = <IdentityWorkerChatTarget>[];
      await pumpHall(tester, openChat: (BuildContext ctx, IdentityWorkerChatTarget t) async => opened.add(t));

      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel));
      await settle(tester);

      expect(server.calls(kClaim), 1, reason: '点一次就发一次 claim');
      expect(opened.length, 1);
      expect(opened.single.conversationId, 'c1');
      expect(opened.single.csConversation, isTrue);
      expect(opened.single.peerNickname, '林老板', reason: '客服视角要以老板昵称为会话标题');
      // 【2026-10-11 遗留缺陷修复】大厅接入 = 我是**当事客服** → 侧别必须是 worker 侧，
      // 且路径里带会话 id（聊天页的「结束咨询」就是从这条路径推出 `/worker/.../<id>/close`）
      expect(opened.single.csServing, isTrue, reason: '接入成功即当事客服 → worker 侧');
      expect(opened.single.sendPath, '/worker/cs/conversations/c1/messages',
          reason: '侧别 + 会话 id 一起交给聊天页（同时服务多条也精确关这一条）');
    });

    testWidgets('**幂等**：自己重复点（`alreadyClaimed:true`，仍是 HTTP 200）→ 不弹红字、直接进会话', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1')]));
      server.ok(kClaim, <String, dynamic>{
        'ok': true,
        'conversationId': 'c1',
        'alreadyClaimed': true, // 服务端：我早就接过这条，幂等成功
        'workerUserId': 'w1',
        'workerNo': 'W20260118',
      });
      final List<IdentityWorkerChatTarget> opened = <IdentityWorkerChatTarget>[];
      await pumpHall(tester, openChat: (BuildContext ctx, IdentityWorkerChatTarget t) async => opened.add(t));

      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel));
      await settle(tester);

      expect(opened.length, 1, reason: 'alreadyClaimed 也是成功，照常进会话');
      expect(tester.takeException(), isNull);
    });

    testWidgets('接入成功后该条从大厅消失（本地即时移除 + 回源确认）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));
      server.ok(kClaim, <String, dynamic>{'ok': true, 'alreadyClaimed': false});
      await pumpHall(tester, openChat: (_, __) async {});
      expect(find.text('林老板'), findsOneWidget);

      // 服务端此刻已经把它从池子里拿掉（别人再也不会在大厅看到它）
      server.ok(kHall, hallBody(const <Map<String, dynamic>>[]));
      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel));
      await settle(tester);

      expect(find.text('林老板'), findsNothing, reason: '接走的咨询不该继续挂在大厅上');
    });
  });

  group('⑨ 抢慢了：claim 中文拒绝 → 中文提示 + 列表刷新 + 该条消失', () {
    testWidgets('409「该咨询已被其他客服接入」→ toast 原文 + 重拉大厅（该条被刷新掉）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));
      server.fail(kClaim, code: 409, message: '该咨询已被其他客服接入');

      await pumpHall(tester, openChat: (_, __) async {});
      final int hallBefore = server.calls(kHall);

      // 被抢走后池子里就没有它了（服务端真相）
      server.ok(kHall, hallBody(const <Map<String, dynamic>>[]));
      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel));
      await tester.pump(); // 让 toast 上屏
      await settle(tester);

      // ① 中文原因来自服务端原文
      expect(find.text('该咨询已被其他客服接入'), findsWidgets, reason: '失败原因必须是服务端中文原文');
      // ② **列表立刻刷新**（本用例的核心：不刷新的话那条还挂在屏上）
      expect(server.calls(kHall), greaterThan(hallBefore), reason: 'claim 失败后必须刷新列表');
      // ③ 刷新后那一条真的消失了
      expect(find.text('林老板'), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('失败后不进会话详情（openChat 一次都不该被调用）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1')]));
      server.fail(kClaim, code: 409, message: '该咨询已被其他客服接入');
      int opened = 0;
      await pumpHall(tester, openChat: (_, __) async => opened += 1);

      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel));
      await settle(tester);
      expect(opened, 0);
      await drainTimers(tester);
    });
  });

  group('⑩ 防连点：连点两次只发一次请求', () {
    testWidgets('同一帧内连点两次 → claim 只发 1 次', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1')]));
      server.ok(kClaim, <String, dynamic>{'ok': true, 'alreadyClaimed': false});
      await pumpHall(tester, openChat: (_, __) async {});

      final Finder btn = find.text(IdentityWorkerCsHallPage.claimLabel);
      await tester.tap(btn);
      await tester.tap(btn); // 不 pump：按钮还没重建，走的是"同一条正在接入中"的守卫
      await settle(tester);

      expect(server.calls(kClaim), 1, reason: '连点两次只发一次（抢占式下双请求 = 双倍并发压力）');
    });

    testWidgets('点一次 → pump 让按钮进入 loading → 再点：仍然只发 1 次', (tester) async {
      server.hold(); // 挂住，模拟慢网络
      server.ok(kHall, hallBody([item(id: 'c1')]));
      server.ok(kClaim, <String, dynamic>{'ok': true, 'alreadyClaimed': false});
      await tester.pumpWidget(page(openChat: (_, __) async {}));
      server.release();
      await settle(tester);

      server.hold();
      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel));
      await tester.pump(); // 按钮此刻应已 busy
      expect(find.byType(CircularProgressIndicator), findsWidgets, reason: '接入中按钮要转圈');
      await tester.tap(find.text(IdentityWorkerCsHallPage.claimLabel), warnIfMissed: false);
      server.release();
      await settle(tester);

      expect(server.calls(kClaim), 1);
    });
  });

  // ==========================================================================
  // ⑪⑫ 实时
  // ==========================================================================
  group('⑪ 实时 cs:new → 列表刷新（计数断言）', () {
    testWidgets('收到 cs:new → /worker/cs/hall 请求数 +1，且新咨询出现在屏上', (tester) async {
      server.ok(kHall, hallBody(const <Map<String, dynamic>>[]));
      await pumpHall(tester);
      expect(bus.subscribers('cs:new'), greaterThan(0), reason: '页面必须订阅 cs:new');
      expect(find.text(IdentityWorkerCsHallPage.emptyTitle), findsOneWidget);
      final int before = server.calls(kHall);

      server.ok(kHall, hallBody([item(id: 'c7', nickname: '新来的老板')]));
      // 真实载荷：{conversationId, reason, userNickname}；reason ∈ created / first-message / released
      bus.fire('cs:new', <String, dynamic>{
        'conversationId': 'c7',
        'reason': 'created',
        'userNickname': '新来的老板',
      });
      await settle(tester);

      expect(server.calls(kHall), greaterThan(before), reason: 'cs:new 必须触发回源（不许吃 SWR 缓存）');
      expect(find.text('新来的老板'), findsOneWidget);
      expect(find.text(IdentityWorkerCsHallPage.emptyTitle), findsNothing, reason: '有新咨询后空态必须让位');
    });
  });

  group('⑫ 实时 cs:claimed → 该条移除 + 一行轻提示（不弹窗）', () {
    testWidgets('收到 cs:claimed → 该条淡出移除 + 顶部一行「已被 客服XX 接入」', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板'), item(id: 'c2', nickname: '周老板')]));
      await pumpHall(tester);
      expect(bus.subscribers('cs:claimed'), greaterThan(0), reason: '页面必须订阅 cs:claimed');
      expect(find.text('林老板'), findsOneWidget);

      // 服务端此刻已把 c1 从池子里拿掉
      server.ok(kHall, hallBody([item(id: 'c2', nickname: '周老板')]));
      // 真实载荷（网关逐人推）：{conversationId, byUserId, byNickname, byWorkerNo}
      bus.fire('cs:claimed', <String, dynamic>{
        'conversationId': 'c1',
        'byUserId': 'w2',
        'byNickname': '打手乙',
        'byWorkerNo': 'W20260222',
      });
      await tester.pump(); // 淡出开始 + 轻提示上屏
      expect(find.text('已被 客服打手乙 接入'), findsOneWidget, reason: '一行轻提示，说清是谁接走的');
      expect(find.byType(Dialog), findsNothing, reason: '**不弹窗打断**');
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await settle(tester, times: 12);

      expect(find.text('林老板'), findsNothing, reason: '被抢走的条目必须从列表消失');
      expect(find.text('周老板'), findsOneWidget, reason: '别人的那条不受影响');
    });

    testWidgets('服务端没给昵称时给中性文案（不编造人名）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));
      await pumpHall(tester);
      server.ok(kHall, hallBody(const <Map<String, dynamic>>[]));
      bus.fire('cs:claimed', <String, dynamic>{'conversationId': 'c1'});
      await tester.pump();
      expect(find.text('该咨询已被其他客服接入'), findsOneWidget);
      await settle(tester, times: 12);
    });

    testWidgets('轻提示会自动消失（4s），不长期占着版面', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1')]));
      await pumpHall(tester);
      bus.fire('cs:claimed', <String, dynamic>{'conversationId': 'c1', 'byNickname': '打手乙'});
      await tester.pump();
      expect(find.text('已被 客服打手乙 接入'), findsOneWidget);

      await tester.pump(IdentityWorkerCsHallPage.noticeDuration + const Duration(milliseconds: 50));
      expect(find.text('已被 客服打手乙 接入'), findsNothing);
      await settle(tester, times: 6);
    });
  });

  // ==========================================================================
  // ⑬ SWR
  // ==========================================================================
  group('⑬ SWR：进入用缓存秒开 / 下拉强制回源 / 切页返回不重复请求', () {
    testWidgets('缓存里有数据 → 第一帧就上屏（网络还没回来），随后被回源结果覆盖', (tester) async {
      // 先把"上一次的响应"塞进缓存（键与生产同一份 keyOf）
      final ApiClient probe = ApiClient(dio: dio);
      ApiCache.instance.put(
        probe.cacheKeyOf('/worker/cs/hall', <String, dynamic>{
          'page': 1,
          'pageSize': IdentityWorkerCsHallPage.pageSize,
        }),
        <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': hallBody([item(id: 'cold', nickname: '缓存里的老板')]),
        },
      );
      // 网络挂住：这一刻屏上的内容**只能**来自缓存
      server.hold();
      server.ok(kHall, hallBody([item(id: 'fresh', nickname: '服务端最新的老板')]));

      await tester.pumpWidget(page());
      await tester.pump();

      expect(find.text('缓存里的老板'), findsOneWidget, reason: '进页面必须先亮缓存（0 等待），而不是先转圈');
      expect(find.byType(RefreshIndicator), findsOneWidget,
          reason: '有缓存就走**内容分支**（RefreshIndicator 所在分支），而不是整页转圈分支');

      server.release();
      await settle(tester);
      expect(find.text('服务端最新的老板'), findsOneWidget, reason: '随后一定回源覆盖（缓存不是结论）');
      expect(find.text('缓存里的老板'), findsNothing);
    });

    testWidgets('下拉刷新 → 强制回源（请求数 +1）', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));
      await pumpHall(tester);
      final int before = server.calls(kHall);

      final Offset center = tester.getCenter(find.byType(RefreshIndicator));
      final TestGesture g = await tester.startGesture(center);
      for (int i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, 32));
        await tester.pump(const Duration(milliseconds: 32));
      }
      await g.up();
      await tester.pump();
      await settle(tester, times: 16);

      expect(server.calls(kHall), greaterThan(before), reason: '下拉 = 用户明确要最新的 → 必须回源');
    });

    testWidgets('页头刷新按钮 → 强制回源', (tester) async {
      server.ok(kHall, hallBody([item(id: 'c1')]));
      await pumpHall(tester);
      final int before = server.calls(kHall);

      await tester.tap(find.byTooltip('刷新'));
      await settle(tester);
      expect(server.calls(kHall), greaterThan(before));
    });

    testWidgets('**切页返回不重复请求**：真实 shell 里 客服 → 接单 → 客服，hall 请求数不变', (tester) async {
      // 让 shell 的另外两页别报错（它们的内容与本用例无关）
      server.ok('GET /worker/order-hall', <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});
      server.ok('GET /worker/division-permissions', <String, dynamic>{'list': <Map<String, dynamic>>[]});
      server.ok('GET /divisions', <Map<String, dynamic>>[]);
      server.ok('GET /public/announcements', <Map<String, dynamic>>[]);
      server.ok('GET /worker/cs/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[]});
      server.ok('GET /user/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[]});
      server.ok('GET /worker/my-wallet', <String, dynamic>{'balance': 0});
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));

      await tester.pumpWidget(
        MaterialApp(
          home: IdentityWorkerShell(
            api: ApiClient(dio: dio),
            canServeCustomer: true,
            openChat: (_, __) async {},
          ),
        ),
      );
      await settle(tester, times: 14);
      final int afterMount = server.calls(kHall);
      expect(afterMount, 1, reason: 'shell 挂载时客服页进一次（IndexedStack 里所有页都在树上）');

      // 切到「客服」
      await tester.tap(find.text('客服').last);
      await settle(tester, times: 6);
      expect(find.text('林老板'), findsOneWidget);
      expect(server.calls(kHall), afterMount, reason: '切到客服页不该再打一次（数据已经在）');

      // 切走再切回：IndexedStack 保留 State → initState 不重跑 → 不重复请求
      await tester.tap(find.text('接单').last);
      await settle(tester, times: 6);
      await tester.tap(find.text('客服').last);
      await settle(tester, times: 6);

      expect(server.calls(kHall), afterMount, reason: '切走再回来**不重复请求**（SWR + IndexedStack 保状态）');
      expect(find.text('林老板'), findsOneWidget, reason: '回来时列表还在（不是白屏）');
    });

    testWidgets('真实 shell：有权限 → 底部 4 项；切到「客服」真的进大厅页', (tester) async {
      server.ok('GET /worker/order-hall', <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});
      server.ok('GET /worker/division-permissions', <String, dynamic>{'list': <Map<String, dynamic>>[]});
      server.ok('GET /divisions', <Map<String, dynamic>>[]);
      server.ok('GET /public/announcements', <Map<String, dynamic>>[]);
      server.ok('GET /worker/cs/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[]});
      server.ok('GET /user/conversations', <String, dynamic>{'list': <Map<String, dynamic>>[]});
      server.ok('GET /worker/my-wallet', <String, dynamic>{'balance': 0});
      server.ok(kHall, hallBody([item(id: 'c1', nickname: '林老板')]));

      await tester.pumpWidget(
        MaterialApp(
          home: IdentityWorkerShell(
            api: ApiClient(dio: dio),
            canServeCustomer: true,
            openChat: (_, __) async {},
          ),
        ),
      );
      await settle(tester, times: 14);
      expect(
        tester.widget<AppPlainBottomNav>(find.byType(AppPlainBottomNav)).items.map((e) => e.label).toList(),
        ['接单', '消息', '客服', '我的'],
      );

      await tester.tap(find.text('客服').last);
      await settle(tester, times: 6);
      expect(find.text(IdentityWorkerCsHallPage.title), findsOneWidget, reason: '点「客服」进的是客服大厅');
      expect(find.text('接单大厅'), findsNothing, reason: '不是接单大厅');
    });
  });
}
