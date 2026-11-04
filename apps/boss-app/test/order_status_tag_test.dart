import 'package:boss_app/widgets/order_status_tag.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 订单状态标签 —— **「不只靠颜色」的硬验收**
///
/// 为什么这个测试是本次改动的核心门：
/// 2026-10-15 之前的实现只认 4 种状态，`pending_dispatch / taken / in_progress /
/// abnormal / after_sale` 全落到「主色」分支 ——
/// **「异常」和「售后」被画成了跟「进行中」一模一样的颜色**。
/// 那是"状态只靠颜色"里最危险的一种：**把需要人处理的事画成了正常的事**。
/// 所以这里不测"颜色对不对"（那种断言只能证明复制了常量），
/// 而测**去色后是否仍可两两区分** —— 这才是 `docs/21` 要的性质。
void main() {
  /// server/src/modules/order/order.entity.ts 的 OrderStatus 全部 9 种
  const statuses = <String>[
    'pending_take', 'pending_dispatch', 'taken', 'in_progress', 'pending_confirm',
    'completed', 'canceled', 'abnormal', 'after_sale',
  ];

  group('① 覆盖：9 种状态一个不漏', () {
    test('每种状态都能拿到视觉档（不会掉进兜底）', () {
      for (final s in statuses) {
        final st = orderStatusStyleFor(s);
        // 兜底档的图标是 circle_outlined —— 真实状态不该用它
        expect(st.icon, isNot(Icons.circle_outlined),
            reason: '「$s」掉进了兜底档，说明映射漏了这一种');
      }
    });

    test('兜底档必须中性灰，不得冒充"正常"（主色）也不得冒充"报警"（红）', () {
      final st = orderStatusStyleFor('some_future_status');
      expect(st.bg, const Color(0xFFF0F2F5), reason: '未知状态应当中性，不能画成主色"正常态"');
      expect(st.fg, AppColors.textSecondary);
    });
  });

  group('② 四信号：图标 / 形状 / 字重 / 颜色', () {
    test('图标 9 种**各不相同**（去色后第一重信号）', () {
      final icons = statuses.map((s) => orderStatusStyleFor(s).icon).toList();
      expect(icons.toSet().length, statuses.length,
          reason: '有状态共用图标 → 去色后无法区分。实际：$icons');
    });

    test('字重至少 3 档（600 / 700 / 800，去色后第二重信号）', () {
      final weights = statuses.map((s) => orderStatusStyleFor(s).weight).toSet();
      expect(weights.length, greaterThanOrEqualTo(3), reason: '字重档不足 → 去色后区分度不够');
      expect(weights, containsAll(<FontWeight>[
        FontWeight.w600, FontWeight.w700, FontWeight.w800,
      ]));
    });

    test('形状至少 3 种组合（实色 / 浅底 / 描边加粗，去色后第三重信号）', () {
      final shapes = statuses.map((s) {
        final st = orderStatusStyleFor(s);
        // 「实色档」的判据是**白字压在有饱和度的底上**（bg 与 fg 不同是必然的：
        // 实色档 = 品牌底 + 白字），所以不能用 bg == fg 判断。
        final isSolid = st.fg == Colors.white;
        return '$isSolid|${st.borderWidth}';
      }).toSet();
      expect(shapes.length, greaterThanOrEqualTo(3), reason: '形状档不足：$shapes');
    });

    test('**核心**：9 种状态在「图标+字重+描边宽+底色+前景色」上两两不等（去色也能分辨）', () {
      final sigs = <String, String>{};
      for (final s in statuses) {
        final st = orderStatusStyleFor(s);
        // 去色后的可见差异：图标 + 字重 + 描边宽 +（底/前景的相对关系）
        final solid = st.fg == Colors.white ? 'solid' : 'tint';
        sigs[s] = '${st.icon.codePoint}|${st.weight.value}|${st.borderWidth}|$solid|${st.bg.toARGB32()}';
      }
      final seen = <String, String>{};
      for (final e in sigs.entries) {
        if (seen.containsKey(e.value)) {
          fail('「${e.key}」与「${seen[e.value]}」四条信号完全相同 → 去色后无法区分');
        }
        seen[e.value] = e.key;
      }
      expect(seen.length, statuses.length);
    });

    test('只有"进行档"用实色底（全页唯一实色，一眼看出哪单在跑）', () {
      final solid = statuses.where((s) => orderStatusStyleFor(s).fg == Colors.white).toList();
      expect(solid.toSet(), {'taken', 'in_progress'}, reason: '实色档应当只有进行中的两种');
    });

    test('售后档比异常档**更重一档**（描边 2dp vs 1dp）', () {
      expect(orderStatusStyleFor('after_sale').borderWidth, 2);
      expect(orderStatusStyleFor('abnormal').borderWidth, 1);
    });

    test('「已取消」是中性灰，不是红色（正常终态不该报警）', () {
      final st = orderStatusStyleFor('canceled');
      // 取设计稿 `s-off` 的 `--g2`（= AppColors.textSecondary #4A5A6E），不是更浅的 statusMuted
      expect(st.fg, AppColors.textSecondary, reason: '旧实现给了 error 红 → 整页像在报警');
      expect(st.fg, isNot(AppColors.error));
    });
  });

  group('③ 规格：对齐设计稿 .stag', () {
    testWidgets('高 24 / 内距 0·8 / 圆角 4 / 图标 12', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: OrderStatusTag(status: 'in_progress', label: '进行中'))),
      ));
      await tester.pump();

      final box = tester.widget<Container>(find.descendant(
        of: find.byType(OrderStatusTag),
        matching: find.byType(Container),
      ).first);
      expect(box.constraints?.maxHeight ?? 24, 24);
      expect(box.padding, const EdgeInsets.symmetric(horizontal: 8));
      final deco = box.decoration! as BoxDecoration;
      expect(deco.borderRadius, BorderRadius.circular(4));

      expect(find.byIcon(Icons.bolt), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.bolt));
      expect(icon.size, 12);

      expect(find.text('进行中'), findsOneWidget);
    });

    testWidgets('文案用服务端下发的 statusName（不自己映射中文）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: OrderStatusTag(status: 'completed', label: '服务端给的名字'))),
      ));
      await tester.pump();
      expect(find.text('服务端给的名字'), findsOneWidget);
    });

    testWidgets('9 种状态都能正常渲染（不抛异常、不溢出）', (tester) async {
      for (final s in statuses) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Center(child: OrderStatusTag(status: s, label: s))),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '「$s」渲染抛异常');
        expect(find.text(s), findsOneWidget);
      }
    });
  });
}
