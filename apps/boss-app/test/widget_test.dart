import 'package:boss_app/pages/ai_chat_page.dart';
import 'package:boss_app/pages/home_shell.dart';
import 'package:boss_app/pages/login_page.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  testWidgets('登录页：账号/密码/登录按钮与注册切换', (tester) async {
    await tester.pumpWidget(const MaterialAppForTest(child: LoginPage()));
    expect(find.text('祁连山电竞'), findsOneWidget);
    // 2026-10-05 改版（方案 B 品牌主视觉）：品牌区大标题也是「登录」→ 按钮 + 标题共两处
    expect(find.text('登录'), findsNWidgets(2), reason: '品牌区标题 + 主按钮');
    expect(find.byKey(const Key('auth-submit')), findsOneWidget);
    expect(find.byType(AppBrandHeader), findsOneWidget);
    // 切换到注册（页脚用稳定 Key：Text 的命中测试噪声与文案无关）
    await tester.tap(find.byKey(const Key('auth-switch-mode')));
    await tester.pumpAndSettle();
    expect(find.text('注册'), findsOneWidget);
    expect(find.text('昵称（可选）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // AppToast/动画定时器排空
  });

  testWidgets('主框架：底部导航渲染 服务/下单/订单/祁小山/消息/我的 并可切换', (tester) async {
    await tester.pumpWidget(const MaterialAppForTest(child: HomeShell()));
    // 【负责人 2026-10-17 六项平铺】底部 = 服务 · **下单** · 订单 · 祁小山 · 消息 · 我的
    // （中间凸起位取消，"祁小山"降为第 4 个普通项，但仍是 shell 内的页面分支）
    for (final label in ['服务', '下单', '订单', '消息', '我的']) {
      expect(find.text(label), findsOneWidget, reason: '底栏六项各出现一次：$label');
    }
    expect(find.text('祁小山'), findsWidgets, reason: '祁小山仍是底栏一项（标签 + 页内标题同名）');
    expect(find.byType(AppQishanMark), findsWidgets, reason: '祁小山那一格用自绘祁山标');
    expect(find.byIcon(AppIcon.plus), findsNothing, reason: '底栏没有＋（下单是独立一格「下单」）');
    // 右下角「快速下单」浮标属于服务页（与底栏「下单」是两个不同入口：浮标不带分部，底栏进选择服务页）
    expect(find.text('快速下单'), findsWidgets);
    await tester.tap(find.text('我的'));
    // 消息页含加载动画（无限动画），用有界 pump 代替 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 300));
    // 未登录状态下"我的"页显示**骨架占位**（2026-10-13 方案 B：原「加载中…」一行文字改为骨架屏）
    expect(find.byKey(const Key('profile-page-skeleton')), findsOneWidget);
    // ApiClient 网络失败自动重试会挂 600ms 重试定时器（测试环境 HTTP 全部 400），收尾前排空
    await tester.pump(const Duration(milliseconds: 700));

    // 导航位索引 ≠ 页面索引：点「消息」（导航位 4）必须进消息页（页面索引 2）
    // 2026-10-04 真机截图发现过此缺陷（点消息进了我的页），此处固化防回归
    await tester.tap(find.text('消息'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('搜索已有会话'), findsOneWidget,
        reason: '点消息应进入消息页（搜索框是消息页的固定标识：'
            '负责人 2026-10-17「去掉上方胶囊、改为单页三分区」后，无数据时不再有分区标题，'
            '原来靠胶囊文案「好友私聊」判定会失效 → 改钉同页更稳的那一处）');
    expect(find.byKey(const Key('profile-page-skeleton')), findsNothing, reason: '不应停留在我的页（骨架已随页面切走）');
    await tester.pump(const Duration(milliseconds: 700));

    // 点「祁小山」→ **切到 shell 内的 AI 分支**（2026-10-04 tab 化：不再 push 覆盖，
    // 负责人要求「选到 AI 那里下面导航栏要正常显示」）
    // 注意：切分支后消息页仍在树上（IndexedStack 常驻）→ 不能用 pumpAndSettle（它的加载动画不收敛）
    await tester.tap(find.text('祁小山').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AiChatPage), findsOneWidget, reason: '「祁小山」必须进祁小山 AI 咨询页');
    expect(find.byType(AppBottomNav), findsOneWidget, reason: 'AI 页激活时底栏仍然显示（这是本次改版的核心）');
    expect(find.text('祁小山'), findsWidgets, reason: 'AI 页页头也是「祁小山」');
    expect(
      tester.widget<AppBottomNav>(find.byType(AppBottomNav)).currentIndex,
      AppBottomNav.aiNavIndex,
      reason: '祁小山 = 导航位 ${AppBottomNav.aiNavIndex}（选中态）',
    );
  });
}

class MaterialAppForTest extends StatelessWidget {
  const MaterialAppForTest({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MaterialApp(home: child),
    );
  }
}
