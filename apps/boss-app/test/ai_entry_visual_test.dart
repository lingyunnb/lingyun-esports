import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/pages/home_shell.dart';
import 'package:boss_app/services/ai_chat_service.dart';
import 'package:boss_app/services/ai_cold_start.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ai_fakes.dart';

/// 出图复核（人眼那一道关）：把真机尺寸的底栏与祁小山会话页渲染成 PNG 落到 `build/`
///
/// 这不是 golden 比对（团队没有 golden 基线，也没必要），而是：
/// ① 渲染烟雾测试（任何布局/溢出异常都会在这里抛出来）；
/// ② 给负责人/评审**看真实像素**的证据文件：`build/ai_entry_nav.png`、`build/ai_chat_*.png`、
///    `build/ai_branch_shell*.png`（AI 作为 shell 分支时**底栏仍在下**的像素证据）。
void main() {
  const captureKey = Key('capture');

  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
    AiSessionTrace.debugReset();
    // 每个用例都是一次"新的进程"：冷启动标记（含正在飞的那次 reset）必须清干净，
    // 否则上一个用例发出的 Future 会被下一个用例 await（跨用例的静态状态）
    AiColdStart.debugResetRun();
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
    AiSessionTrace.debugReset();
    AiColdStart.debugResetRun();
  });

  Future<void> capture(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> phoneSize(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  testWidgets('底栏（白底 + 1px 发丝线 + 祁山标 22px + 「祁小山」）出图', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: const SizedBox.shrink(),
          bottomNavigationBar: AppBottomNav(currentIndex: 0, onTap: (_) {}, onCenterTap: () {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture(tester, 'ai_entry_nav');
  });

  testWidgets('底栏（AI 分支激活 → 中间凸起位选中态：祁山标 + 标签都用主色）出图', (tester) async {
    await phoneSize(tester);
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: const SizedBox.shrink(),
          // currentIndex: 2 = 正在 AI 分支（选中态）
          bottomNavigationBar: AppBottomNav(currentIndex: 2, onTap: (_) {}, onCenterTap: () {}),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture(tester, 'ai_entry_nav_selected');
  });

  testWidgets('主框架 + AI 分支：**底栏仍在下**（空态 / 对话）出图 —— 负责人本次要求的像素证据', (tester) async {
    await phoneSize(tester);
    // 主框架里其它 tab 带无限加载动画 → 不能用 pumpAndSettle，固定推几帧
    Future<void> frames(WidgetTester tester, [int n = 4]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    final source = FakeAiSource(sessionId: 'sess-A');
    final bus = FakeAiRealtime();
    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(home: HomeShell(aiSource: source, aiRealtime: bus)),
    ));
    await frames(tester);

    // 点底栏中间凸起 → 切到 AI 分支（不 push）
    await tester.tap(find.descendant(of: find.byType(AppBottomNav), matching: find.byType(AppQishanMark)));
    await frames(tester);
    expect(find.byType(AiChatPage), findsOneWidget);
    expect(find.byType(AppBottomNav), findsOneWidget, reason: 'AI 页激活时底栏必须在');
    expect(find.text(kAiIntroTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'ai_branch_shell_empty');

    // 问一句 + 流式回答 → 再出一张（对话态，底栏同样在）
    await tester.enterText(find.byKey(const Key('ai-input')), '昨天那单打手一直没上号，能退吗');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await frames(tester);
    bus.fire('ai:done', {
      'conversationId': 'c-1',
      'messageId': 'ai-1',
      'content': '要看订单状态：待接单能随时取消；已接单得和打手协商，或在订单详情里发起申诉。',
    });
    await frames(tester);
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '对话态底栏一样在');
    expect(tester.takeException(), isNull);
    await capture(tester, 'ai_branch_shell_chat');
  });

  testWidgets('祁小山会话页：空态 / 对话（流式+转人工卡）/ 生成中「停止」 出图', (tester) async {
    await phoneSize(tester);

    Future<void> pump({required FakeAiSource source, required FakeAiRealtime bus}) async {
      await tester.pumpWidget(RepaintBoundary(
        key: captureKey,
        // UniqueKey：每次出图都要一个**全新 State**，否则同类型 widget 会复用旧 State（配置不会重拉）
        child: MaterialApp(home: AiChatPage(key: UniqueKey(), source: source, realtime: bus)),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // ① 空态
    final bus = FakeAiRealtime();
    await pump(source: FakeAiSource(), bus: bus);
    expect(find.text(kAiIntroTitle), findsOneWidget);
    await capture(tester, 'ai_chat_empty');

    // ② 对话：我方提问 + 流式回答 + 转人工卡
    await tester.enterText(find.byKey(const Key('ai-input')), '昨天那单打手一直没上号，等了一小时也没动静，能退吗');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pumpAndSettle();
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '要看订单状态：待接单能随时取消；已接单得和打手协商，'});
    await tester.pumpAndSettle();
    await capture(tester, 'ai_chat_streaming');
    bus.fire('ai:chunk', {'conversationId': 'c-1', 'messageId': 'ai-1', 'delta': '或在订单详情里发起申诉。'});
    await tester.pumpAndSettle();
    bus.fire('ai:error', {'conversationId': 'c-1', 'messageId': 'ai-1', 'code': 'UPSTREAM', 'message': '上游超时'});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-handoff-card')), findsOneWidget);
    await capture(tester, 'ai_chat_handoff');

    // ③ 生成中（3 点等待 + 右侧「停止」）
    await tester.enterText(find.byKey(const Key('ai-input')), '那超时了会扣积分吗');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ai-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai-stop')), findsOneWidget);
    await capture(tester, 'ai_chat_generating');

    // ④ 空态（**服务端真实 config**：开场白更长、4 个 chips —— 2026-10-04 联调抓到的原文）
    //    放在最后：换 config 需要全新 State（UniqueKey），不影响上面已经跑完的流式用例
    await pump(
      source: FakeAiSource()
        ..config = const AiChatConfig(
          greeting: '我是祁小山，祁连山电竞的客服。订单、积分、售后的事直接说，我帮你看。',
          presets: ['怎么下单？', '积分怎么用？', '退款规则是什么？', '我要转人工客服'],
        ),
      bus: FakeAiRealtime(),
    );
    expect(find.text('我要转人工客服'), findsOneWidget);
    await capture(tester, 'ai_chat_empty_server_config');
  });
}
