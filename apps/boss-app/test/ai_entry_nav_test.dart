import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 底栏中间凸起按钮 = 「祁小山」AI 咨询入口（设计稿 site/design/ai-entry-v3.html 候选 ③-2 定稿）
///
/// 覆盖任务书验收项 ①：**显示「祁小山」且图标为自绘（不是 ＋）**；
/// 以及本次改版的四条视觉硬参数：白底 / 1px 发丝线 / 零实色面积（无渐变）/ 标签样式。
///
/// 2026-10-04 前提变了：AI 由 push 页面改成 **shell 内的一个分支** → 底栏常驻 →
/// 中间位与其余四项同规则**有选中态**（选中主色 / 未选中 #94A3B8）：
/// - 未选中（`currentIndex != 2`）：祁山标近黑 + 标签 #94A3B8/w500 —— 与改版前完全一致（②③ 固化）
/// - 选中（`currentIndex == 2` = 正在 AI 分支）：祁山标与标签都是主色、标签 w700（⑤ 固化）
void main() {
  setUp(() {
    ThemeController.instance.init();
  });

  Future<void> pumpNav(
    WidgetTester tester, {
    int currentIndex = 0,
    VoidCallback? onCenterTap,
    VoidCallback? onCenterLongPress,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: AppBottomNav(
          currentIndex: currentIndex,
          onTap: (_) {},
          onCenterTap: onCenterTap ?? () {},
          onCenterLongPress: onCenterLongPress,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('① 标签是「祁小山」，图标是自绘祁山标（不是 ＋）；六项等宽平铺', (tester) async {
    await pumpNav(tester);

    expect(find.text('祁小山'), findsOneWidget, reason: '祁小山那一格的标签');
    // 自绘：CustomPaint 挂的是 QishanMarkPainter
    expect(find.byType(AppQishanMark), findsOneWidget, reason: '祁小山那一格必须是自绘祁山标');
    final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
    expect(paints.any((p) => p.painter is QishanMarkPainter), isTrue,
        reason: '祁山标必须是 CustomPainter（AppIcon 是 IconData，拼不出这个形）');
    // 旧的「＋」必须彻底消失（图标与语义都不再是加号）
    expect(find.byIcon(AppIcon.plus), findsNothing, reason: '底栏没有＋（下单是独立一格「下单」）');
    // 六项：服务 · 下单 · 订单 · 祁小山 · 消息 · 我的
    for (final label in ['服务', '下单', '订单', '消息', '我的']) {
      expect(find.text(label), findsOneWidget);
    }
    // 等宽：六格宽度逐值相同（取消凸起后是纯 Row + Expanded）
    final widths = <double>[
      for (final label in ['服务', '下单', '订单', '祁小山', '消息', '我的'])
        tester.getSize(find.ancestor(of: find.text(label), matching: find.byType(Expanded)).first).width,
    ];
    for (final w in widths) {
      expect(w, closeTo(widths.first, 0.01), reason: '六项必须等宽：$widths');
    }
  });

  testWidgets('② 祁小山那一格：无方块底 + 22dp 自绘祁山标 + 与其余五项同一套底色规则', (tester) async {
    await pumpNav(tester, onCenterTap: () {});

    // 【负责人 2026-10-17】六项等宽平铺：**中间凸起位取消** → 原来的 ⌀54 白圆 / top:-16 这两条
    // 几何断言随定案一起作废（负责人当面明确"这个规则废了"）。现在要守的是新规则：
    // ① 祁山标 22dp（与其余五项图标等大）；
    // ② 不再有"浅蓝方块底"这套装饰（负责人："颜色非常丑"）——祁山标直接落在白底底栏上；
    // ③ 标签与其余五项**同一基线**（六格等宽等高的 Column，靠同一段代码排出来）。
    final mark = tester.widget<AppQishanMark>(find.byType(AppQishanMark));
    expect(mark.size, 22, reason: '与其余五项 22dp 图标等大');

    // 没有图标方块底：底栏内部不该再有 AppTabGlyph / AppIconTile（原浅蓝方块的载体）
    expect(find.byType(AppTabGlyph), findsNothing, reason: '去掉浅蓝方块底（负责人 2026-10-17）');
    expect(find.byType(AppIconTile), findsNothing, reason: '同上：图标直接落在白底上');

    // 标签与其余五项同一基线
    final yQi = tester.getTopLeft(find.text('祁小山')).dy;
    for (final label in ['服务', '下单', '订单', '消息', '我的']) {
      expect(tester.getTopLeft(find.text(label)).dy, yQi, reason: '「$label」必须与「祁小山」同一条基线');
    }

    // 未选中态：祁山标与标签都取 #94A3B8（与其余五项同规则，不再有"近黑"这一档）
    expect(mark.color, T.textTertiary);
    expect(mark.color, isNot(AppColors.primary), reason: '主色蓝是选中态语义色 → 未选中不能用');
  });

  testWidgets('③ 标签样式：10px / #94A3B8 / w500（未选中态）', (tester) async {
    await pumpNav(tester);
    final label = tester.widget<Text>(find.text('祁小山'));
    expect(label.style!.fontSize, 10);
    expect(label.style!.color, T.textTertiary);
    expect(label.style!.fontWeight, FontWeight.w500);
    expect(label.style!.color, isNot(T.primary));
  });

  testWidgets('⑤ 选中态（currentIndex == 3 = 正在祁小山分支）：图标与标签都用主色，标签 w700', (tester) async {
    await pumpNav(tester, currentIndex: AppBottomNav.aiNavIndex);

    // 祁小山那一格选中 → 与其余五项完全同一套规则（主色 + w700）
    final mark = tester.widget<AppQishanMark>(find.byType(AppQishanMark));
    expect(mark.color, T.primary, reason: '祁小山是底栏分支 → 选中时图标用主色');
    final label = tester.widget<Text>(find.text('祁小山'));
    expect(label.style!.color, T.primary);
    expect(label.style!.fontWeight, FontWeight.w700);
    expect(mark.size, 22);
    expect(label.style!.fontSize, 10);

    // 未选中时回到 #94A3B8（对照组；currentIndex 换到别的格）
    await pumpNav(tester, currentIndex: 0);
    expect(tester.widget<AppQishanMark>(find.byType(AppQishanMark)).color, T.textTertiary);
    expect(tester.widget<Text>(find.text('祁小山')).style!.color, T.textTertiary);
  });

  testWidgets('⑥ 面板项回调会 push 新页面时，面板也必须真的关掉（pop 竞态回归）', (tester) async {
    // 真机竖屏尺寸（默认 800×600 测试窗口下面板会挤到溢出，与本用例断言无关）
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 真实链路：面板项 → 立刻 push 一层新页面。
    // 【2026-10-15 甲方案】原先承载这个场景的是面板第一项「找陪玩」——该项已**整个移除**
    // （入口改由服务页顶部导航承担，见 `services_find_players_entry_test.dart`）。
    // 面板内仍存在且同样会 push 的场景改用「聊天记录」承载，**断言的意图与断言本身一个字没变**：
    // 验证的是"面板项回调 push 新路由时，面板自己必须真的从栈里移除"。
    // 旧实现用 maybePop()（内部 await willPop）→ 顶层路由被随后的 push 换掉 → 这次 pop 被"忘记"，
    // 面板永远留在 Navigator 栈里（它的 ModalBarrier 一直压在主框架上 → 返回后点不动底栏）。
    var tapped = 0;
    late NavigatorState nav;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) {
          nav = Navigator.of(context);
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => AppQuickActionsSheet.show(
                  context,
                  onMessages: () {
                    tapped++;
                    nav.push(MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Center(child: Text('聊天记录页'))),
                    ));
                  },
                  onSupport: () {},
                  onOrder: () {},
                ),
                child: const Text('打开面板'),
              ),
            ),
          );
        },
      ),
    ));
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();
    expect(find.text('快速入口'), findsOneWidget);

    // 面板内容同步核对：只剩「聊天记录 / 联系客服 / 直接去下单」
    expect(find.text('找陪玩'), findsNothing, reason: '甲方案：该项已整个移除');
    expect(find.text('聊天记录'), findsOneWidget);
    expect(find.text('联系客服'), findsOneWidget);
    expect(find.text('直接去下单'), findsOneWidget);

    await tester.tap(find.text('聊天记录'));
    await tester.pumpAndSettle();
    expect(tapped, 1, reason: '回调照常触发');
    expect(find.text('聊天记录页'), findsOneWidget, reason: '新页面正常 push');
    expect(
      find.text('快速入口', skipOffstage: false),
      findsNothing,
      reason: '面板必须真的从栈里移除（不能留一个隐形遮罩压住主框架）',
    );

    // 返回主框架：底栏区域必须能点到（没有残留 barrier 拦截）
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('打开面板'), findsOneWidget, reason: '回到主框架且可交互');
  });

  testWidgets('④ 单击 = 切到 AI 分支；长按 = 快捷入口面板（面板不因改版消失）', (tester) async {
    var tapped = 0;
    var longPressed = 0;
    await pumpNav(tester, onCenterTap: () => tapped++, onCenterLongPress: () => longPressed++);

    await tester.tap(find.text('祁小山'));
    await tester.pump();
    expect(tapped, 1);
    expect(longPressed, 0);

    await tester.longPress(find.byType(AppQishanMark));
    await tester.pump();
    expect(longPressed, 1);
    expect(tapped, 1, reason: '长按不应同时触发单击');
  });
}
