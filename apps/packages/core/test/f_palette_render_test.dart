import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// **渲染出来的颜色必须符合方案 F 调色板**（不是"token 里写了 F 值"就算数）
///
/// 这条用例专门对着负责人那句反馈「改色改到哪去了」：断言的是**真正挂到 Widget 上的颜色**
/// （`BoxDecoration.gradient` / `BoxShadow` / `Icon.color` / painter 颜色），
/// 任何一处没接上 F 的色值都会在这里挂掉，而不是靠"看一眼觉得变了"。
///
/// ⚠️ 全程只读 widget 属性，**不做像素读取**（不 `toImage`/`toByteData`）——
/// 读像素在 `flutter test` 里必须包 `tester.runAsync`，否则会**永久挂死**并占住测试锁
/// （2026-10-16 已踩过；本文件因此刻意不碰像素）。
void main() {
  BoxDecoration decoOf(WidgetTester tester, Finder f) =>
      tester.widget<Container>(f).decoration! as BoxDecoration;

  /// 组件内部那唯一一个 `Container`（= 双色实底的方块本体）
  Finder boxOf(Type type, [int index = 0]) =>
      find.descendant(of: find.byType(type), matching: find.byType(Container)).at(index);

  testWidgets('AppIconTile（资金）＝ planF 橙金双色 + 白色镂空字形', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: AppIconTile(icon: AppIcon.wallet, size: 32))),
      ),
    );

    final box = decoOf(tester, boxOf(AppIconTile));
    final gradient = box.gradient! as LinearGradient;
    // planF 实测配对：资金 `#F59E0B → #FB923C`
    expect(gradient.colors, const [Color(0xFFF59E0B), Color(0xFFFB923C)]);
    expect(gradient.begin, Alignment.topLeft);
    expect(gradient.end, Alignment.bottomRight);
    expect(box.borderRadius, BorderRadius.circular(32 * 0.34));
    expect(box.boxShadow, isNull, reason: '彩色阴影只给底栏选中态与 C 位，列表方块不加');

    // 字形＝白色镂空（镜像 Icon 与 painter 都必须是白）
    expect(tester.widget<Icon>(find.byIcon(AppIcon.wallet)).color, Colors.white);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<AppIconPainter>()
        .single;
    expect(painter.color, Colors.white);
    expect(painter.icon, AppIcons.wallet, reason: '钱包图标的旧 IconData 要解析成新几何（资金区 = wallet）');
  });

  testWidgets('AppTabGlyph 选中态 ＝ 品牌渐变 + 彩色柔和阴影；未选中 ＝ 浅底冷灰', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              children: [
                AppTabGlyph(icon: AppIcon.services, selected: true),
                AppTabGlyph(icon: AppIcon.orders, selected: false),
              ],
            ),
          ),
        ),
      ),
    );

    // 选中态：品牌渐变（#2563EB → #06B6D4）+ 主色 35% 柔和阴影（planF `.it.on .nib`）
    final on = decoOf(tester, boxOf(AppTabGlyph));
    expect((on.gradient! as LinearGradient).colors, const [Color(0xFF2563EB), Color(0xFF06B6D4)]);
    final shadows = on.boxShadow;
    expect(shadows, isNotNull, reason: 'planF：选中 nib 有 box-shadow 0 5px 11px rgba(...,.35)');
    expect(shadows!.single.blurRadius, 11);
    expect(shadows.single.offset.dy, 5);
    expect(shadows.single.color.a, closeTo(.35, 0.001));
    expect(shadows.single.color.r, closeTo(AppColors.primary.r, 0.001), reason: '阴影 = 主色半透明（不是纯黑）');

    // 未选中态：浅底 + 冷灰图标（planF `.nib` 未选中档）
    final off = decoOf(tester, boxOf(AppTabGlyph, 1));
    expect(off.gradient, isNull);
    expect(off.color, AppColors.placeholderBg);
    expect(off.boxShadow, isNull);
  });

  testWidgets('AI（祁小山）方块 ＝ planF 紫→蓝（负责人点名的 accentAi）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: AppIconTile(icon: AppIcon.info, size: 26, feature: AppFeature.ai)),
        ),
      ),
    );
    final box = decoOf(tester, boxOf(AppIconTile));
    expect((box.gradient! as LinearGradient).colors, const [Color(0xFF8B5CF6), Color(0xFF2563EB)]);
  });

  testWidgets('功能色相真的落到图标上：投诉＝安全绿、打赏＝资金橙金（走同一条 featureOfIcon）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon.of(AppIcon.complaint, size: 15, color: featureHue(featureOfIcon(AppIcon.complaint))),
                AppIcon.of(AppIcon.tip, size: 15, color: featureHue(featureOfIcon(AppIcon.tip))),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      tester.widget<Icon>(find.byIcon(AppIcon.complaint)).color,
      const Color(0xFF10B981),
      reason: '投诉 = 安全绿（F 实测值）',
    );
    expect(
      tester.widget<Icon>(find.byIcon(AppIcon.tip)).color,
      const Color(0xFFF59E0B),
      reason: '打赏 = 资金橙金（F 实测值）',
    );
  });
}
