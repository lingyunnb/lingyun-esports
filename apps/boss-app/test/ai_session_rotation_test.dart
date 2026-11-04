import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/services/ai_cold_start.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ai_fakes.dart';

/// 祁小山 AI 会话生命周期（负责人 2026-10-04 改版：**轮换只在冷启动发生一次**）
///
/// 旧语义（已废弃）：进页面 reset、离开页面 stop+reset → 每次进出都是全新会话。
/// 新语义：`POST /user/ai/reset` 只在**冷启动**（App 大退后重新打开 = 进程重启）调一次
/// （触发点在 `AiColdStart`，见 `ai_branch_test.dart`）；同一次运行内
/// **离开 = 页面不可见**（停生成、收键盘，不 reset、不清消息），**回来 = 刚才那段对话**。
///
/// 覆盖：
/// ① 进页面只拉 config + 历史（**不 reset**），当前 session 的对话照常上屏
/// ② 分支失活（切走）：生成中 → `POST /user/ai/stop`；不 reset、消息保留；迟到的 WS 事件不上屏
/// ③ 分支重新激活（切回）：不重新拉历史、不 reset，消息原样保留
/// ④ push 方式被 pop（dispose）：只 stop，不 reset
/// ⑤ 冷启动兜底：reset 没成功时，本进程**第一次**加载不显示"本机已展示过的 session"（= 大退后为空）
/// ⑥ 兜底只对第一次生效：同一次运行的后续加载保留对话
/// ⑦ 冷启动 reset 成功时不走兜底（当前 session 的历史照常显示）
/// ⑧ 服务端漏过滤时，客户端也只显示当前 session 的消息
/// ⑨ 上一条会话的迟到 WS 事件（session 对不上）不上屏
void main() {
  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
    AiSessionTrace.debugReset();
    AiColdStart.debugResetRun();
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
    AiSessionTrace.debugReset();
    AiColdStart.debugResetRun();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required FakeAiSource source,
    required FakeAiRealtime bus,
    ValueNotifier<bool>? active,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: AiChatPage(source: source, realtime: bus, activeSignal: active),
    ));
    await tester.pumpAndSettle();
  }

  /// 模拟 push 方式被 pop：页面被销毁（dispose 里的 stop 是 fire-and-forget）
  Future<void> closePage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  List<ChatV4Item> itemsOf(WidgetTester tester) =>
      tester.widgetList<ChatV4MessageList>(find.byType(ChatV4MessageList)).single.items;

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('ai-input')), text);
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pumpAndSettle();
  }

  List<AiMessage> sessionMessages() => [
        AiMessage(
          id: 'h1',
          fromMe: true,
          content: '上一次会话：怎么下单',
          at: DateTime(2026, 10, 4, 21, 0),
          seq: 1,
          sessionId: 'sess-A',
        ),
        AiMessage(
          id: 'h2',
          fromMe: false,
          content: '上一次会话：先选分部',
          at: DateTime(2026, 10, 4, 21, 1),
          seq: 2,
          sessionId: 'sess-A',
        ),
      ];

  // -------------------------------------------------------------------------
  // 进入 / 离开：都不再轮换
  // -------------------------------------------------------------------------

  testWidgets('① 进页面：拉 config + 历史，**不 reset**（当前 session 的对话照常显示）', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A', history: sessionMessages());
    await pumpPage(tester, source: source, bus: FakeAiRealtime());

    expect(source.resetCalls, isEmpty, reason: '进入不再轮换会话（轮换只在冷启动）');
    expect(source.messageCalls.length, 1, reason: '进页面拉一次历史');
    expect(itemsOf(tester).length, 2, reason: '当前 session 的对话要显示出来（同一次运行内它还在）');
  });

  testWidgets('② 切走（分支失活）：生成中 → stop；不 reset、消息保留；迟到的 WS 事件不上屏', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A');
    final bus = FakeAiRealtime();
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    await pumpPage(tester, source: source, bus: bus, active: active);

    await typeAndSend(tester, '这单怎么退');
    expect(source.sendCalls.length, 1);
    expect(find.byKey(const Key('ai-stop')), findsOneWidget, reason: '发送后处于生成中');

    // 用户切到别的 tab = 本页分支失活
    active.value = false;
    await tester.pumpAndSettle();

    expect(source.stopCalls.length, 1, reason: '页面不可见 → 打断这次生成（合理）');
    expect(source.stopCalls.single['messageId'], 'ai-1');
    expect(source.resetCalls, isEmpty, reason: '切走**不**轮换会话（旧语义已废弃）');
    expect(find.byKey(const Key('ai-stop')), findsNothing, reason: '本地已收尾：不该留一个早已死掉的「停止」键');

    // 迟到事件：已停止的那条 + 一条没被停止的（只能靠"分支不可见"拦下）
    bus.fire('ai:chunk', {
      'conversationId': 'c-1',
      'messageId': 'ai-1',
      'delta': '停止后迟到的半句',
    });
    bus.fire('ai:done', {
      'conversationId': 'c-1',
      'messageId': 'ai-99',
      'content': '切走后凭空冒出来的回答',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('停止后迟到的半句'), findsNothing);
    expect(find.textContaining('切走后凭空冒出来的回答'), findsNothing, reason: '页面不可见时的事件不上屏');

    // 切回 AI 分支：刚才那条提问还在（对话整段保留）
    active.value = true;
    await tester.pumpAndSettle();
    expect(find.text('这单怎么退'), findsOneWidget, reason: '同一次运行内切回来要能看到刚才的对话');
    expect(source.resetCalls, isEmpty);
    expect(source.messageCalls.length, 1, reason: '切回不重新拉历史（页面自己就是那份状态）');
  });

  testWidgets('③ 分支切换是幂等的：重复通知同一个值不会被当成"重新进入"', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A', history: sessionMessages());
    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    await pumpPage(tester, source: source, bus: FakeAiRealtime(), active: active);
    expect(itemsOf(tester).length, 2);

    // 连点当前 tab / 重复置位 → ValueNotifier 值没变就不通知；即便通知了也不能重来一次
    active.value = true;
    active.notifyListeners();
    await tester.pumpAndSettle();
    expect(itemsOf(tester).length, 2, reason: '消息不能被任何"重新进入"清掉');
    expect(source.messageCalls.length, 1);
    expect(source.resetCalls, isEmpty);
  });

  testWidgets('④ push 方式被 pop（dispose）：生成中只 stop，不 reset', (tester) async {
    final source = FakeAiSource();
    await pumpPage(tester, source: source, bus: FakeAiRealtime());

    await typeAndSend(tester, '怎么下单');
    expect(find.byKey(const Key('ai-stop')), findsOneWidget);

    await closePage(tester);
    expect(source.stopCalls.length, 1, reason: '页面销毁 → 打断上游');
    expect(source.resetCalls, isEmpty, reason: '销毁也不轮换会话（轮换只在冷启动）');
    expect(tester.takeException(), isNull, reason: 'dispose 里的 stop 失败/离线不能抛异常');
  });

  // -------------------------------------------------------------------------
  // 冷启动兜底（reset 只在冷启动发一次；失败时本进程第一次加载不显示旧会话）
  // -------------------------------------------------------------------------

  testWidgets('⑤ 冷启动 reset 失败（离线）：本进程第一次加载按空会话渲染（等价于"大退后为空"）', (tester) async {
    await AiSessionTrace.remember('me', 'sess-A'); // 上一次运行展示过 sess-A（本机记忆）
    // 冷启动初始化：离线 → reset 发不出去（失败静默）
    await AiColdStart.ensureResetOnce(source: FakeAiSource(failReset: true));
    expect(AiColdStart.rotatedThisRun, isFalse);

    final source = FakeAiSource(sessionId: 'sess-A', history: sessionMessages());
    await pumpPage(tester, source: source, bus: FakeAiRealtime());

    expect(find.byType(ChatV4MessageList), findsNothing, reason: 'reset 没成功时不能显示上一次的对话');
    expect(find.textContaining('上一次会话'), findsNothing);
    expect(find.text(kAiIntroTitle), findsOneWidget, reason: '按空会话渲染：开场白 + 快捷问题');
    expect(find.byKey(const Key('ai-presets')), findsOneWidget);
    expect(source.history.length, 2, reason: '数据一条没删（管理端仍可查），只是本页不显示');
  });

  testWidgets('⑥ 兜底只对"本进程第一次加载"生效：同一次运行的第二次加载保留对话', (tester) async {
    await AiSessionTrace.remember('me', 'sess-A');
    await AiColdStart.ensureResetOnce(source: FakeAiSource(failReset: true));

    // 第一次加载：按空会话（兜底）
    await pumpPage(
      tester,
      source: FakeAiSource(sessionId: 'sess-A', history: sessionMessages()),
      bus: FakeAiRealtime(),
    );
    expect(find.byType(ChatV4MessageList), findsNothing);

    // 同一次运行内再打开一次（push 方式：页面重建 → 重新加载历史）：这次必须把对话显示出来
    await closePage(tester); // 先卸载（否则同类型 widget 会复用同一个 State，initState 不会再跑）
    await pumpPage(
      tester,
      source: FakeAiSource(sessionId: 'sess-A', history: sessionMessages()),
      bus: FakeAiRealtime(),
    );
    expect(itemsOf(tester).length, 2, reason: '同一次运行内不再隐藏 —— 对话要保留');
    expect(find.textContaining('上一次会话'), findsWidgets);
  });

  testWidgets('⑦ 冷启动 reset 成功时不走兜底：服务端当前 session 的历史照常显示', (tester) async {
    await AiSessionTrace.remember('me', 'sess-A');
    await AiColdStart.ensureResetOnce(source: FakeAiSource()); // 成功
    expect(AiColdStart.rotatedThisRun, isTrue);

    final source = FakeAiSource(sessionId: 'sess-A', history: sessionMessages());
    await pumpPage(tester, source: source, bus: FakeAiRealtime());
    expect(itemsOf(tester).length, 2, reason: '轮换成功 → 服务端给什么就显示什么（兜底不介入）');
  });

  // -------------------------------------------------------------------------
  // session 过滤兜底
  // -------------------------------------------------------------------------

  testWidgets('⑧ 服务端漏过滤时也只显示当前 session 的消息（旧 session 的消息不上屏）', (tester) async {
    final source = FakeAiSource(
      sessionId: 'sess-new',
      history: [
        AiMessage(
          id: 'old1',
          fromMe: true,
          content: '旧会话的问题',
          at: DateTime(2026, 10, 4, 20, 0),
          seq: 1,
          sessionId: 'sess-old',
        ),
        AiMessage(
          id: 'new1',
          fromMe: true,
          content: '新会话的问题',
          at: DateTime(2026, 10, 4, 21, 0),
          seq: 2,
          sessionId: 'sess-new',
        ),
      ],
    );
    await pumpPage(tester, source: source, bus: FakeAiRealtime());

    final items = itemsOf(tester);
    expect(items.length, 1, reason: '只留当前 session 的消息');
    expect(items.single.text, '新会话的问题');
    expect(find.text('旧会话的问题'), findsNothing);
  });

  testWidgets('⑨ 上一条会话的迟到 WS 事件不上屏（session 对不上即丢弃）', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-new');
    final bus = FakeAiRealtime();
    await pumpPage(tester, source: source, bus: bus);

    bus.fire('ai:chunk', {
      'conversationId': 'c-1',
      'sessionId': 'sess-old',
      'messageId': 'ai-9',
      'delta': '上次会话的回答',
    });
    bus.fire('ai:done', {
      'conversationId': 'c-1',
      'sessionId': 'sess-old',
      'messageId': 'ai-9',
      'content': '上次会话的回答全文',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('上次会话的回答'), findsNothing, reason: '旧 session 的事件不能在页面上冒出来');
    expect(find.byType(ChatV4MessageList), findsNothing);

    // 当前 session 的事件照常渲染
    bus.fire('ai:chunk', {
      'conversationId': 'c-1',
      'sessionId': 'sess-new',
      'messageId': 'ai-10',
      'delta': '当前会话的回答',
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('当前会话的回答'), findsOneWidget);
  });
}
