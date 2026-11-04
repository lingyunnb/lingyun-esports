import 'dart:async';

import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/pages/home_shell.dart';
import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/services/ai_cold_start.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ai_fakes.dart';

/// **AI 变成 shell 内的一个分支**（负责人 2026-10-04：「选到 AI 那里下面导航栏要正常显示」）
///
/// 旧实现：中间凸起按钮 `Navigator.push` 一层 AI 页 → **底栏整个被盖住**。
/// 新实现：AI 是 `HomeShell` 的 `IndexedStack` 里的第 5 个分支 → 底栏常驻；
/// 中间凸起位与其余四项同规则有选中态（选中主色 / 未选中 #94A3B8）。
///
/// 会话生命周期（同一天改版的第二条需求）：**轮换只在冷启动发生一次**。
/// - 同一次运行内：切走再切回，刚才那段对话还在，**不发 reset**
/// - App 大退后重新打开（进程重启）：冷启动初始化发一次 `POST /user/ai/reset` → 会话为空
///
/// 覆盖：
/// ① 点中间凸起 → 底栏仍在 + AI 页在树上 + 没有 push（Navigator 栈没多一层）+ 中间位选中态
/// ② 同一次运行内：进 AI → 提问 → 切到「服务」→ 切回 AI：**消息仍在**、没有 reset、没有重新拉历史
/// ③ 冷启动：reset 恰好 1 次 → 会话为空（大退后为空）；同一次运行内再挂载 shell 也不会再发
/// ④ 找陪玩「问祁小山」→ 切 AI 分支（底栏可见），不是 push
/// ⑤ AI 页不出现返回箭头（tab 不需要返回）
/// ⑥ 系统返回键在 AI 分支 → 回上一个 tab（不退出 App）
void main() {
  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
    AiSessionTrace.debugReset();
    // 每个用例都是一次"新的进程"（大退后重新打开）
    AiColdStart.debugResetRun();
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
    AiSessionTrace.debugReset();
    AiColdStart.debugResetRun();
  });

  /// 底栏内的元素（首页/消息页里也可能有同名文案或同一个祁山标，必须限定在底栏里找）
  Finder inNav(Finder matching) => find.descendant(of: find.byType(AppBottomNav), matching: matching);
  Finder centerButton() => inNav(find.byType(AppQishanMark));
  Finder navLabel(String label) => inNav(find.text(label));

  int navIndex(WidgetTester tester) => tester.widget<AppBottomNav>(find.byType(AppBottomNav)).currentIndex;

  /// 主框架根部的 PopScope 是否允许弹栈（`PopScope<T>` 带泛型 → 不能用 find.byType 精确匹配）
  bool shellCanPop(WidgetTester tester) =>
      (tester.widgetList(find.byWidgetPredicate((w) => w is PopScope)).first as PopScope).canPop;

  /// 主框架里消息页带无限加载动画 → **不能用 pumpAndSettle**（不收敛）；
  /// 固定推几帧让路由动画、HTTP 失败与 600ms 重试定时器都跑完
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    required FakeAiSource source,
    FakeAiRealtime? bus,
  }) async {
    // 真机竖屏尺寸：800×600 的默认测试窗口下，快捷入口面板会挤到溢出（与本用例无关的既有布局）
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: HomeShell(aiSource: source, aiRealtime: bus ?? FakeAiRealtime()),
    ));
    await drain(tester);
  }

  Future<void> enterAi(WidgetTester tester) async {
    await tester.tap(centerButton());
    await drain(tester);
  }

  /// 模拟系统返回键（Android 物理/手势返回）：平台通道 `flutter/navigation` 的 popRoute
  Future<void> pressSystemBack(WidgetTester tester) async {
    unawaited(tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute')),
      (_) {},
    ));
    await drain(tester);
  }

  // -------------------------------------------------------------------------

  testWidgets('① 中间凸起 → AI 是 shell 内分支：底栏仍在树上，AI 页也在树上（不是 push 覆盖）', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A');
    await pumpShell(tester, source: source);

    // 没进过 AI 分支 → 懒挂载（冷启动不为它拉历史）
    expect(find.byType(AiChatPage), findsNothing);
    expect(navIndex(tester), 0);

    await enterAi(tester);

    expect(find.byType(AiChatPage), findsOneWidget, reason: 'AI 页在树上');
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '负责人要求：AI 页激活时底栏仍然显示');
    expect(find.text(kAiIntroTitle), findsOneWidget, reason: 'AI 页内容也在树上（空态开场白）');
    expect(navIndex(tester), AppBottomNav.aiNavIndex, reason: '中间凸起位 = AI 分支（选中态）');
    expect(
      tester.state<NavigatorState>(find.byType(Navigator).first).canPop(),
      isFalse,
      reason: '不再 push 覆盖：Navigator 栈里没有多一层',
    );
    expect(source.messageCalls.length, 1, reason: '首次进 AI 分支才拉历史');

    // 中间位选中态：祁山标与标签都用主色（与其余四项同规则；未选中 = 近黑 / #94A3B8）
    final mark = tester.widget<AppQishanMark>(centerButton());
    expect(mark.color, T.primary, reason: 'AI 分支激活 → 中间凸起位的图标用主色');
    final label = tester.widget<Text>(navLabel('祁小山'));
    expect(label.style!.color, T.primary);
    expect(label.style!.fontWeight, FontWeight.w700);

    // 切回「服务」→ 中间位回到未选中态
    await tester.tap(navLabel('服务'));
    await drain(tester);
    expect(tester.widget<AppQishanMark>(centerButton()).color, isNot(T.primary));
    expect(tester.widget<Text>(navLabel('祁小山')).style!.color, isNot(T.primary));
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '底栏一直在');
  });

  testWidgets('② 同一次运行内：切到别的 tab 再切回 AI —— 消息仍在、不发 reset、不重新拉历史', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A');
    final bus = FakeAiRealtime();
    await pumpShell(tester, source: source, bus: bus);
    await enterAi(tester);
    expect(source.resetCalls.length, 1, reason: '只有冷启动那一次 reset');

    // 提问 → 流式回答（WS 顺序照真实契约：chunk 追加 → done 覆盖为准）
    await tester.enterText(find.byKey(const Key('ai-input')), '这单怎么退');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await drain(tester);
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '先看订单'});
    await tester.pump();
    bus.fire('ai:done', {'conversationId': 'c-1', 'messageId': 'ai-1', 'content': '先看订单状态，再点申请退款'});
    await drain(tester);

    expect(find.text('这单怎么退'), findsOneWidget);
    expect(find.text('先看订单状态，再点申请退款'), findsOneWidget);

    // 切到「服务」→ 再切回 AI
    await tester.tap(navLabel('服务'));
    await drain(tester);
    expect(navIndex(tester), 0, reason: '四个方格点击照常切换');
    await enterAi(tester);

    expect(find.text('这单怎么退'), findsOneWidget, reason: '同一次运行内切回来必须还能看到刚才的对话');
    expect(find.text('先看订单状态，再点申请退款'), findsOneWidget);
    expect(source.resetCalls.length, 1, reason: '离开/回来都不轮换会话（轮换只在冷启动）');
    expect(source.messageCalls.length, 1, reason: '页面常驻：切回来不重新拉历史，消息由 AI 页自己持有');
    expect(tester.takeException(), isNull);
  });

  testWidgets('③ 冷启动：reset 恰好 1 次 → 会话为空；同一次运行内再挂载 shell 不再发；下一次冷启动才再发', (tester) async {
    // 上一轮运行留在服务端的会话（本机也记得它 = 上次已展示过）
    final source = FakeAiSource(
      sessionId: 'sess-old',
      rotateOnReset: true,
      history: [
        AiMessage(
          id: 'old1',
          fromMe: true,
          content: '大退前的提问',
          at: DateTime(2026, 10, 4, 21, 0),
          seq: 1,
          sessionId: 'sess-old',
        ),
      ],
    );

    await pumpShell(tester, source: source);
    expect(source.resetCalls.length, 1, reason: '冷启动初始化：POST /user/ai/reset 一次');

    await enterAi(tester);
    expect(source.sessionId, 'sess-r1', reason: '服务端已轮换到新 session');
    expect(find.textContaining('大退前的提问'), findsNothing, reason: '大退后重新打开 → AI 会话是空的');
    expect(find.text(kAiIntroTitle), findsOneWidget, reason: '空态：开场白 + 快捷问题');
    expect(find.byKey(const Key('ai-presets')), findsOneWidget);

    // 同一次运行内：切来切去、甚至把 shell 重新挂载一次，都不会再发 reset（进程内一次性标记）
    await tester.tap(navLabel('消息'));
    await drain(tester);
    await enterAi(tester);
    expect(source.resetCalls.length, 1, reason: 'tab 切换不是冷启动');
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await drain(tester);
    await pumpShell(tester, source: source);
    expect(source.resetCalls.length, 1, reason: '同一次运行内重新挂载 shell 也不再轮换');

    // 下一次"大退后重新打开"= 进程重启 → 再发一次
    AiColdStart.debugResetRun();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await drain(tester);
    await pumpShell(tester, source: source);
    expect(source.resetCalls.length, 2, reason: '新的冷启动才再轮换一次');
  });

  testWidgets('④ 找陪玩「问祁小山」：切到 AI 分支（底栏显示），不是 push 覆盖', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A');
    await pumpShell(tester, source: source);

    // 入口 = 服务页**顶部导航第一项**「选择陪玩」（2026-10-15 定案：底栏凸起按钮长按弹出的
    // 快捷面板里那条「找陪玩」已整个移除，入口由顶部导航单一承担）。
    // 这条同时充当"新入口能从真 shell 一路进到找陪玩页"的端到端回归。
    await tester.tap(find.text('选择陪玩'));
    await drain(tester);

    expect(find.byType(PlayersPage), findsOneWidget);
    expect(find.byType(AppBottomNav), findsNothing, reason: '找陪玩本身是 push 的页 → 底栏此时被盖住（进入前状态）');

    // 「有疑问？问祁小山」→ 通知 shell 切 AI 分支 + 自己退出（不再 push 一层 AI 页）
    await tester.tap(find.byKey(const Key('players-ask-qishan')));
    await drain(tester);

    expect(find.byType(PlayersPage), findsNothing, reason: '找陪玩页已退出');
    expect(find.byType(AiChatPage), findsOneWidget);
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '从找陪玩进来时底栏也必须显示');
    expect(navIndex(tester), AppBottomNav.aiNavIndex);
    expect(
      tester.state<NavigatorState>(find.byType(Navigator).first).canPop(),
      isFalse,
      reason: '不是 push：AI 页在 shell 分支里',
    );
  });

  testWidgets('⑤ AI 页不出现返回箭头（tab 不需要返回；页头仍是 祁山标 + 祁小山 + 副标题）', (tester) async {
    final source = FakeAiSource(sessionId: 'sess-A');
    await pumpShell(tester, source: source);
    await enterAi(tester);

    expect(
      find.descendant(of: find.byType(AiChatPage), matching: find.byIcon(AppIcon.arrowLeft)),
      findsNothing,
      reason: 'AI 是底栏分支，不需要返回箭头',
    );
    // 页头三件套照旧
    expect(find.text('祁小山'), findsWidgets, reason: '页头名字（底栏标签同名，故用 findsWidgets）');
    expect(find.text(kAiHeaderSubtitle), findsOneWidget, reason: '副标题「平台规则与订单问题，随时问」');
    expect(
      find.descendant(of: find.byType(AiChatPage), matching: find.byType(AppQishanMark)),
      findsWidgets,
      reason: '页头头像 = 祁山标',
    );
  });

  testWidgets('⑥ 系统返回键：AI 分支 → 回上一个 tab（不退出 App）；其余分支不拦', (tester) async {
    // 记录"退出 App"这种系统调用：SystemNavigator.pop → flutter/platform 的 SystemNavigator.pop
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final source = FakeAiSource(sessionId: 'sess-A');
    await pumpShell(tester, source: source);

    // 先在「订单」tab（返回键要回到它，而不是服务页）
    await tester.tap(navLabel('订单'));
    await drain(tester);
    expect(navIndex(tester), AppBottomNav.ordersNavIndex);

    await enterAi(tester);
    expect(navIndex(tester), AppBottomNav.aiNavIndex);
    expect(shellCanPop(tester), isFalse, reason: 'AI 分支要拦返回键（回上一个 tab，不是退出 App）');

    await pressSystemBack(tester);
    expect(navIndex(tester), AppBottomNav.ordersNavIndex, reason: '系统返回键 → 回上一个 tab（订单）');
    expect(platformCalls, isNot(contains('SystemNavigator.pop')), reason: '没有退出 App');
    expect(find.byType(AppBottomNav), findsOneWidget);

    // 回到「上一个 tab」后不再拦（再按返回 = 系统默认：退出 App）
    expect(shellCanPop(tester), isTrue);
    await pressSystemBack(tester);
    expect(platformCalls, contains('SystemNavigator.pop'), reason: '其余分支维持系统默认（不拦）');
    expect(navIndex(tester), AppBottomNav.ordersNavIndex, reason: '不在 AI 分支 → 不切 tab');

    // 而 AI 分支里那段对话没有被清掉（切回来还在，且仍在同一分支）
    await enterAi(tester);
    expect(navIndex(tester), AppBottomNav.aiNavIndex);
    expect(find.byType(AiChatPage), findsOneWidget);
  });
}
