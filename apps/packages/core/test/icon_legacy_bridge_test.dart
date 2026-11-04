import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/icons/app_icons_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 方案 F 图标迁移的**收口层契约**（2026-10-16）
///
/// 这一套用例守的是三件事，任何一条被破坏，迁移期「图标真的换了」与
/// 「既有断言一条不放宽」二者就会有一个落空：
///
/// 1. **映射表齐全**：`kLegacyIconMap` 每条都要有非空目标，且目标本身能画出墨迹
///    （防「映射到一枚空 path」这种反静默失败）；
/// 2. **渲染换新**：走 `AppIcon.of(旧 IconData)` 的调用点，画出来的必须是新几何
///    （`AppIconPainter` 的 icon = 映射表里的目标）；
/// 3. **旧 finder 不失效**：镜像 `Icon` 必须仍能被 `find.byIcon` 命中，
///    且 `size` / `color` / 矩形与迁移前**逐值相同**（全仓 53 处 finder 依赖它）。
void main() {
  group('映射表（旧 IconData → 新 AppIcons）', () {
    test('每条都有目标，且目标都在枚举里（非空、非 null）', () {
      expect(kLegacyIconMap, isNotEmpty, reason: '迁移表不许为空');
      for (final entry in kLegacyIconMap.entries) {
        expect(entry.value, isA<AppIcons>(), reason: '${entry.key} 的目标类型不对');
        expect(
          AppIcons.values.contains(entry.value),
          isTrue,
          reason: '${entry.key} → ${entry.value.name} 不在 AppIcons 枚举里',
        );
      }
    });

    test('每个目标都能画出非空路径（防「映射到空图标」）', () {
      for (final target in kLegacyIconMap.values.toSet()) {
        final data = appIconDataOf(target);
        final metrics = data.path.computeMetrics().toList();
        final total = metrics.fold<double>(0, (a, m) => a + m.length);
        expect(total, greaterThan(0), reason: '${target.name} 的 path 长度为 0');
      }
    });

    test('70 条旧语义别名（AppIcon.x）**逐条**在映射表里（含 Fill 变体）', () {
      // 这 70 条是存量调用点直接写的名字；漏一条 = 那一处会掉进 Material 回退
      const legacyAliases = <String, IconData>{
        'services': AppIcon.services,
        'servicesFill': AppIcon.servicesFill,
        'orders': AppIcon.orders,
        'ordersFill': AppIcon.ordersFill,
        'messages': AppIcon.messages,
        'messagesFill': AppIcon.messagesFill,
        'mine': AppIcon.mine,
        'mineFill': AppIcon.mineFill,
        'home': AppIcon.home,
        'homeFill': AppIcon.homeFill,
        'search': AppIcon.search,
        'bell': AppIcon.bell,
        'chevronRight': AppIcon.chevronRight,
        'chevronDown': AppIcon.chevronDown,
        'arrowRight': AppIcon.arrowRight,
        'arrowLeft': AppIcon.arrowLeft,
        'close': AppIcon.close,
        'plus': AppIcon.plus,
        'minus': AppIcon.minus,
        'check': AppIcon.check,
        'dots': AppIcon.dots,
        'refresh': AppIcon.refresh,
        'filter': AppIcon.filter,
        'edit': AppIcon.edit,
        'rank': AppIcon.rank,
        'players': AppIcon.players,
        'headset': AppIcon.headset,
        'coin': AppIcon.coin,
        'gift': AppIcon.gift,
        'star': AppIcon.star,
        'starFill': AppIcon.starFill,
        'shield': AppIcon.shield,
        'clock': AppIcon.clock,
        'bolt': AppIcon.bolt,
        'image': AppIcon.image,
        'camera': AppIcon.camera,
        'heart': AppIcon.heart,
        'heartFill': AppIcon.heartFill,
        'comment': AppIcon.comment,
        'share': AppIcon.share,
        'qr': AppIcon.qr,
        'empty': AppIcon.empty,
        'phone': AppIcon.phone,
        'location': AppIcon.location,
        'lock': AppIcon.lock,
        'logout': AppIcon.logout,
        'fire': AppIcon.fire,
        'trophy': AppIcon.trophy,
        'crown': AppIcon.crown,
        'wallet': AppIcon.wallet,
        'chart': AppIcon.chart,
        'users': AppIcon.users,
        'ticket': AppIcon.ticket,
        'clipboard': AppIcon.clipboard,
        'upload': AppIcon.upload,
        'trash': AppIcon.trash,
        'ban': AppIcon.ban,
        'keyIcon': AppIcon.keyIcon,
        'settings': AppIcon.settings,
        'info': AppIcon.info,
        'help': AppIcon.help,
        'cloud': AppIcon.cloud,
        'server': AppIcon.server,
        'db': AppIcon.db,
        'safe': AppIcon.safe,
        'record': AppIcon.record,
        'category': AppIcon.category,
        'mail': AppIcon.mail,
        'mailVerified': AppIcon.mailVerified,
        'complaint': AppIcon.complaint,
        'tip': AppIcon.tip,
        'refund': AppIcon.refund,
      };
      for (final e in legacyAliases.entries) {
        expect(
          kLegacyIconMap.containsKey(e.value),
          isTrue,
          reason: 'AppIcon.${e.key} 没有映射目标 —— 它会掉进 Material 回退',
        );
      }
    });

    test('解析函数：命中返回目标，未登记返回 null（不静默顶替）', () {
      expect(lookupLegacyIcon(AppIcon.check), AppIcons.check);
      expect(lookupLegacyIcon(AppIcon.coin), AppIcons.coins);
      expect(
        lookupLegacyIcon(const IconData(0x1F600, fontFamily: 'MaterialIcons')),
        isNull,
        reason: '未登记必须显式返回 null，由调用方决定回退方式',
      );
      expect(
        resolveLegacyIconOr(const IconData(0x1F600, fontFamily: 'MaterialIcons')),
        AppIcons.info,
        reason: '兜底档默认 info（语义中性），绝不空白',
      );
    });
  });

  group('迁移入口 AppIcon.of：画新几何 + 镜像旧 IconData', () {
    testWidgets('旧 finder 仍命中；size / color / 矩形逐值不变', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: AppIcon.of(AppIcon.check, size: 20, color: Color(0xFF112233))),
          ),
        ),
      );
      final f = find.byIcon(AppIcon.check);
      expect(f, findsOneWidget, reason: '迁移不许让 find.byIcon 失效');
      final icon = tester.widget<Icon>(f);
      expect(icon.size, 20);
      expect(icon.color, const Color(0xFF112233));
      expect(tester.getSize(f), const Size(20, 20));

      // 画出来的是**新几何**（不是 Material 字形）
      final painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((p) => p.painter is AppIconPainter)
          .toList();
      expect(painters.length, 1);
      expect((painters.first.painter! as AppIconPainter).icon, AppIcons.check);
    });

    testWidgets('镜像不可见（Opacity 0）—— 不产生像素，也不摘出 finder 遍历', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: AppIcon.of(AppIcon.empty, size: 24, color: Color(0xFF000000))),
          ),
        ),
      );
      final opacities = tester.widgetList<Opacity>(find.byType(Opacity)).toList();
      expect(opacities, isNotEmpty);
      for (final o in opacities) {
        expect(o.opacity, 0.0);
      }
      // findsOneWidget：既没被 skipOffstage 摘掉，也没渲染出第二枚可见图标
      expect(find.byIcon(AppIcon.empty), findsOneWidget);
      expect(find.byType(Icon), findsOneWidget, reason: 'Icon 计数与迁移前一致（1:1 镜像）');
    });

    testWidgets('size 不传时与 Flutter 的 Icon 同源（继承 IconTheme，默认 24）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppIcon.of(AppIcon.search))),
        ),
      );
      final icon = tester.widget<Icon>(find.byIcon(AppIcon.search));
      expect(icon.size, isNull, reason: '与 Icon 一样：size 属性沿用「不传即继承」语义');
      expect(tester.getSize(find.byIcon(AppIcon.search)), const Size(24, 24));
    });

    testWidgets('未登记 IconData → 显式 Material 回退（可见，不是空白/问号）', (tester) async {
      const unknown = IconData(0xe999, fontFamily: 'MaterialIcons');
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: AppIcon.of(unknown, size: 18)))),
      );
      expect(find.byIcon(unknown), findsOneWidget);
      expect(
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).where((p) => p.painter is AppIconPainter),
        isEmpty,
        reason: '未登记 → 保留 Material，不画新几何',
      );
    });

    testWidgets('新入口 AppIcon(AppIcons.x) 默认 20，且不产生镜像', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppIcon(AppIcons.search, color: Color(0xFF000000)))),
        ),
      );
      expect(tester.getSize(find.byType(AppIcon)), const Size(20, 20));
      expect(find.byType(Icon), findsNothing, reason: '新入口是纯自绘，不该有镜像 Icon');
    });
  });
}
