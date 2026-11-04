import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品徽标 + 每周限购提示（负责人 2026-10-05）
///
/// 组件级硬约束：
/// 1) **徽标非空才渲染**（后台清空徽标文案 → 卡片上不能留空壳、也不能留金色描边）
/// 2) **限购文案全部来自服务端**：组件只负责把 `limitText` / `quotaText` 原样显示，
///    服务端没给（不限购 / 未登录）就一个字都不显示 —— 客户端不硬编码「每周限购 2 单」这类规则
/// 3) 「突出明显」的取值可控：有徽标 = 1px 琥珀金描边，无徽标 = 全站发丝线
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  group('ProductBadge', () {
    testWidgets('有徽标文案 → 渲染实色底白字小片（圆角 5，无渐变）', (tester) async {
      await tester.pumpWidget(wrap(const ProductBadge('董事长推荐')));

      expect(find.text('董事长推荐'), findsOneWidget);
      final box = tester.widget<Container>(
        find.ancestor(of: find.text('董事长推荐'), matching: find.byType(Container)).first,
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, AppColors.gold, reason: '实色琥珀金底（docs/21：禁用渐变做主视觉）');
      expect(decoration.gradient, isNull);
      expect((decoration.borderRadius! as BorderRadius).topLeft.x, 5, reason: '圆角走小控件档 4–6');
      final text = tester.widget<Text>(find.text('董事长推荐'));
      expect(text.style!.color, Colors.white);
      expect(text.style!.fontSize, 10, reason: '字号必须小于商品名(13.5)/价格(15)，徽标不抢主次');
    });

    testWidgets('空 / null / 全空白 → 一律不渲染', (tester) async {
      for (final value in <String?>[null, '', '   ']) {
        await tester.pumpWidget(wrap(ProductBadge(value)));
        expect(find.byType(Text), findsNothing, reason: 'badgeText=$value 时不能有残留空壳');
        expect(ProductBadge.shows(value), isFalse);
      }
      expect(ProductBadge.shows('董事长推荐'), isTrue);
    });
  });

  group('productCardBorder', () {
    test('有徽标 → 1px 琥珀金；无徽标 → 全站发丝线（颜色/宽度都可断言）', () {
      final golden = productCardBorder('董事长推荐') as Border;
      expect(golden.top.color, AppColors.gold);
      expect(golden.top.width, 1);

      for (final value in <String?>[null, '', '  ']) {
        final hairline = productCardBorder(value) as Border;
        expect(hairline.top.color, T.divider, reason: '普通商品卡片描边必须与全站一致');
      }
    });
  });

  group('WeeklyLimitNote', () {
    testWidgets('服务端文案原样展示（客户端不拼规则、不算剩余）', (tester) async {
      await tester.pumpWidget(wrap(const WeeklyLimitNote(limitText: '每周限购 2 单', quotaText: '本周还可下 1 单')));
      expect(find.text('每周限购 2 单 · 本周还可下 1 单'), findsOneWidget);
    });

    testWidgets('换一份服务端文案 → 页面跟着变（证明没有客户端硬编码）', (tester) async {
      await tester.pumpWidget(wrap(const WeeklyLimitNote(limitText: '每周限购 3 单', quotaText: '本周还可下 3 单')));
      expect(find.text('每周限购 3 单 · 本周还可下 3 单'), findsOneWidget);
      expect(find.textContaining('限购 2 单'), findsNothing);
    });

    testWidgets('只有额度文案（规则文案为空）也能显示，反之亦然', (tester) async {
      await tester.pumpWidget(wrap(const WeeklyLimitNote(quotaText: '本周额度已用完，下周再来')));
      expect(find.text('本周额度已用完，下周再来'), findsOneWidget);

      await tester.pumpWidget(wrap(const WeeklyLimitNote(limitText: '每周限购 2 单')));
      expect(find.text('每周限购 2 单'), findsOneWidget);
    });

    testWidgets('服务端没给文案（不限购）→ 一个字都不显示', (tester) async {
      for (final pair in <(String?, String?)>[(null, null), ('', ''), ('  ', '')]) {
        await tester.pumpWidget(wrap(WeeklyLimitNote(limitText: pair.$1, quotaText: pair.$2)));
        expect(find.textContaining('限购'), findsNothing);
        expect(find.textContaining('本周'), findsNothing);
      }
    });
  });
}
