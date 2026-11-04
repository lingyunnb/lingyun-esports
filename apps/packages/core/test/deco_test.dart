import 'dart:io';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 品牌装饰系统（`docs/45-品牌装饰系统（待审批）.md`）的地基契约。
///
/// 本文件三件事：
/// 1. **形状规则**：斜切角只取 4/6/8、未选中不切口、恰好两条边、L-SLOT 只留几何；
/// 2. **源码红线**：`deco*.dart` 里不得出现软过渡填充 / 路径真裁 / 投影 / 硬编码色值 /
///    emoji / 「积分」—— **先剥注释再扫**（红线写在注释里是规则说明，不算违规）；
/// 3. **自检数字**：间距落格率、字号种类、圆角集合、金色出现位置 —— 对齐 `docs/45 §七` 的口径，
///    跑完会打印一行汇总，供验收报告直接引用。
///
/// ⚠️ 本文件用 `package:fish_core/src/widgets/deco.dart` **直接导入**：装饰地基本轮刻意
/// **不从 `fish_core.dart` 导出**（另外 3 路正在改 core 的导出文件，避免并行改同一行）。
void main() {
  // =====================================================================================
  // 源码工具（剥注释 → 扫红线）
  // =====================================================================================

  /// 包根（从测试进程的工作目录往上找 `lib/src/widgets/app_ui.dart`）
  Directory packageRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      if (File('${dir.path}/lib/src/widgets/app_ui.dart').existsSync()) return dir;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return Directory.current;
  }

  /// 本轮新建的全部装饰源码（`deco.dart` / 将来拆出来的 `deco_*.dart`）
  List<File> decoSources() {
    final widgets = Directory('${packageRoot().path}/lib/src/widgets');
    final files = widgets
        .listSync()
        .whereType<File>()
        .where((f) => RegExp(r'deco(_\w+)?\.dart$').hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: '没找到 lib/src/widgets/deco*.dart');
    return files;
  }

  /// 剥掉注释（行注释 + 块注释）后的**代码正文**；字符串里的 `//` 本文件不存在，故安全。
  String codeOnly(String src) => src
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'//.*'), ''))
      .join('\n');

  String allCode() => decoSources().map((f) => codeOnly(f.readAsStringSync())).join('\n');

  // =====================================================================================
  // ① 斜切角：边长只取 4/6/8 + 未选中不切口
  // =====================================================================================

  group('① 斜切角（刀口）', () {
    double nearest(double height) {
      final target = height / 4;
      var best = 4.0;
      for (final s in <double>[4, 6, 8]) {
        if ((s - target).abs() <= (best - target).abs()) best = s;
      }
      return best;
    }

    test('切口尺寸只有三档：4 / 6 / 8（不许出现第五档）', () {
      expect(AppNotch.sizes, <double>[4, 6, 8]);
    });

    test('高度 → 切口档：全域只落 4/6/8，且等于"高度 ÷ 4 最接近的一档"', () {
      final seen = <double>{};
      for (var h = 1; h <= 200; h++) {
        final s = AppNotch.sizeForHeight(h.toDouble());
        expect(AppNotch.sizes.contains(s), isTrue, reason: 'h=$h → $s 不在 {4,6,8} 内');
        expect(s, nearest(h.toDouble()), reason: 'h=$h 的档位没取到"高度÷4 最接近"的那一档');
        seen.add(s);
      }
      expect(seen, <double>{4, 6, 8}, reason: '三档必须都被用到（否则规则退化成常量）');
    });

    test('锚点：h16→4 · h20→6（并列取大一档，与 L-SLOT 定案一致）· h24→6 · h32→8 · h48→8', () {
      expect(AppNotch.sizeForHeight(16), 4);
      expect(AppNotch.sizeForHeight(20), 6);
      expect(AppNotch.sizeForHeight(24), 6);
      expect(AppNotch.sizeForHeight(32), 8);
      expect(AppNotch.sizeForHeight(48), 8);
      expect(AppNotch.sizeForHeight(64), 8);
    });

    test('斜切角语言谱系（6 档）与自动取档规则逐条一致 —— 表与规则不许各说各话', () {
      for (final role in AppNotchRole.values) {
        expect(role.selfConsistent, isTrue,
            reason: '$role 的 cut=${role.cut} 与 height=${role.height} 推导出的 '
                '${AppNotch.sizeForHeight(role.height)} 不一致');
        expect(AppNotch.sizes.contains(role.cut), isTrue);
      }
      // 谱系定案的角位（6×6 右上＝状态/归属 · 8×8 右下＝选中/进行 · 6×6 左下＝卡片 · 4×4 右上＝最小号）
      expect(AppNotchRole.statusTag.corner, AppNotchCorner.topRight);
      expect(AppNotchRole.statusTag.cut, 6);
      expect(AppNotchRole.sectionTag.corner, AppNotchCorner.topRight);
      expect(AppNotchRole.miniBadge.cut, 4);
      expect(AppNotchRole.filterChip.cut, 8);
      expect(AppNotchRole.filterChip.corner, AppNotchCorner.bottomRight);
      expect(AppNotchRole.contentCard.corner, AppNotchCorner.bottomLeft);
      expect(AppNotchRole.levelSlot.cut, 6);
      // 三档切口在谱系里齐备
      expect(AppNotchRole.values.map((r) => r.cut).toSet(), <double>{4, 6, 8});
    });

    test('未选中态一键关闭：resolveSize(selected: false) = 0', () {
      for (final h in <double>[16, 20, 24, 32, 48]) {
        expect(AppNotch.resolveSize(height: h, selected: false), 0);
        expect(AppNotch.resolveSize(height: h), AppNotch.sizeForHeight(h));
      }
    });

    testWidgets('未选中不切口：enabled=false 的切口尺寸 0×0，启用时 = 6×6（h24）', (t) async {
      await t.pumpWidget(const MaterialApp(home: Center(child: AppNotch(height: 24))));
      expect(t.getSize(find.byType(AppNotch)), const Size(6, 6));

      await t.pumpWidget(
        const MaterialApp(home: Center(child: AppNotch(height: 24, enabled: false))),
      );
      expect(t.getSize(find.byType(AppNotch)), const Size(0, 0), reason: '未选中态必须完全不切口');
    });

    testWidgets('AppNotched(enabled: false) 连切口组件都不建（一键关闭到节点级）', (t) async {
      await t.pumpWidget(const MaterialApp(home: AppNotched(height: 24, corner: AppNotchCorner.bottomLeft, enabled: false, child: SizedBox(width: 40, height: 24))));
      expect(find.byType(AppNotch), findsNothing);

      await t.pumpWidget(const MaterialApp(home: AppNotched(height: 24, corner: AppNotchCorner.bottomLeft, child: SizedBox(width: 40, height: 24))));
      expect(find.byType(AppNotch), findsOneWidget);
    });

    testWidgets('恰好两条边，且只画"朝向元素内部"的两条（四个角位逐条钉住）', (t) async {
      for (final corner in AppNotchCorner.values) {
        await t.pumpWidget(
          MaterialApp(
            home: Center(
              child: AppNotch(
                height: 24,
                corner: corner,
                baseColor: Colors.white,
                borderColor: AppColors.hairline,
              ),
            ),
          ),
        );
        final patch = t.widget<Container>(
          find.descendant(of: find.byType(AppNotch), matching: find.byType(Container)).first,
        );
        final border = (patch.decoration! as BoxDecoration).border! as Border;
        final drawn = <AppNotchEdge>{
          if (border.top.width > 0) AppNotchEdge.top,
          if (border.right.width > 0) AppNotchEdge.right,
          if (border.bottom.width > 0) AppNotchEdge.bottom,
          if (border.left.width > 0) AppNotchEdge.left,
        };
        expect(drawn.length, 2, reason: '$corner 必须只画两条边');
        expect(drawn, AppNotch.edgesFor(corner), reason: '$corner 的两条边朝向不对');
      }
    });
  });

  // =====================================================================================
  // ② 细网格：硬边纹理，不是软过渡
  // =====================================================================================

  group('② 细网格', () {
    const forbidden = <String>[
      'Gradient',
      'createShader',
      'ClipPath',
      'BoxShadow',
      'boxShadow',
      'BackdropFilter',
      'ImageFilter',
    ];

    test('硬红线：deco*.dart 源码里不出现渐变家族类 / 着色器 / 路径真裁 / 投影', () {
      for (final f in decoSources()) {
        final src = f.readAsStringSync();
        for (final token in forbidden) {
          expect(src.contains(token), isFalse, reason: '${f.path} 出现了禁忌标识 $token');
        }
      }
    });

    test('硬红线（代码正文口径）：剥掉注释后同样干净（注释说明规则，代码不许违规）', () {
      final code = allCode();
      final lines = code.split('\n');
      var gradient = 0;
      for (final line in lines) {
        if (RegExp(r'Gradient|createShader|ClipPath|Shadow').hasMatch(line)) gradient++;
      }
      expect(gradient, 0, reason: '代码正文里仍有 $gradient 处禁忌用法');
    });

    test('细网格常量：1px 线 / 5% / 间距 8dp（落 4dp 网格）', () {
      expect(AppFineGrid.lineWidth, 1);
      expect(AppFineGridPainter.lineWidth, 1);
      expect(AppFineGrid.defaultOpacity, 0.05);
      expect(AppFineGrid.defaultStep, 8);
      expect(AppFineGrid.defaultStep % 4, 0);
    });

    testWidgets('细网格渲染 = CustomPaint + 纯色线条 painter（无 shader、无软过渡）', (t) async {
      await t.pumpWidget(
        const MaterialApp(home: Center(child: SizedBox(width: 32, height: 32, child: AppFineGrid()))),
      );
      final paint = t.widget<CustomPaint>(
        find.descendant(of: find.byType(AppFineGrid), matching: find.byType(CustomPaint)).first,
      );
      final painter = paint.painter! as AppFineGridPainter;
      expect(painter.step, 8);
      expect(painter.opacity, 0.05);
      expect(painter.color, AppColors.brandInk); // 与设计稿 rgba(15,36,64,.05) 同源
    });
  });

  // =====================================================================================
  // ③ 4dp 网格 / 圆角 / 切口三套词汇
  // =====================================================================================

  group('③ 4dp 网格', () {
    /// 装饰的**间距与尺寸**常量（切口 4/6/8 与圆角 4/6/10/14 是独立词汇，单列见下）
    Map<String, double> spacingConstants() => <String, double>{
      'Baseline.statusBar': AppBaseline.statusBar,
      'Baseline.pageHeader': AppBaseline.pageHeader,
      'Baseline.brandBand': AppBaseline.brandBand,
      'Baseline.blockGap': AppBaseline.blockGap,
      'Baseline.contentBlock': AppBaseline.contentBlock,
      'Baseline.pageBottom': AppBaseline.pageBottom,
      'Baseline.v0': AppBaseline.v0,
      'Baseline.b0': AppBaseline.b0,
      'Baseline.b1': AppBaseline.b1,
      'Baseline.b2': AppBaseline.b2,
      'Baseline.b3': AppBaseline.b3,
      'Baseline.b4': AppBaseline.b4,
      'DecoSpacing.ruleToContent': AppDecoSpacing.ruleToContent,
      'DecoSpacing.lineToContent': AppDecoSpacing.lineToContent,
      'DecoSpacing.blockGap': AppDecoSpacing.blockGap,
      'DecoSpacing.pageEdge': AppDecoSpacing.pageEdge,
      'DecoSpacing.tickToTitle': AppDecoSpacing.tickToTitle,
      'DecoSpacing.emptyVertical': AppDecoSpacing.emptyVertical,
      'DecoSpacing.cardPadding': AppDecoSpacing.cardPadding,
      'DecoSpacing.hairlineIndent': AppDecoSpacing.hairlineIndent,
      'BrandBar.width': AppBrandBar.defaultWidth,
      'BrandBar.height': AppBrandBar.defaultHeight,
      'LevelSlot.height': AppLevelSlot.slotHeight,
      'LevelSlot.maxWidth': AppLevelSlot.slotMaxWidth,
      'LevelSlot.gap': AppLevelSlot.gap,
      'LevelSlot.nameRowHeight': AppLevelSlot.nameRowHeight,
      'FineGrid.step': AppFineGrid.defaultStep,
      'Empty.frameSize': AppEmptyDeco.frameSize,
      'Empty.iconSize': AppEmptyDeco.iconSize,
      'Empty.ruleWidth': AppEmptyDeco.defaultRuleWidth,
      'Hero.markSize': AppHeroCard.markSize,
      'Hero.markInset': AppHeroCard.markInset,
      'Money.unitSize': AppMoney.unitSize,
      'Stat.unitSize': AppStat.unitSize,
      'Skeleton.barHeight': AppSkeletonShape.bar.height,
    };

    test('间距落格率 100%：装饰的每个间距/尺寸都是 4 的倍数', () {
      final entries = spacingConstants();
      final offGrid = <String>[];
      for (final e in entries.entries) {
        if (e.value % 4 != 0) offGrid.add('${e.key} = ${e.value}');
      }
      final rate = (entries.length - offGrid.length) / entries.length * 100;
      // ignore: avoid_print
      print('[自检] 间距落格率 = $rate%（${entries.length} 个装饰间距/尺寸，越格 ${offGrid.length} 处）');
      expect(offGrid, isEmpty, reason: '越格：$offGrid');
      expect(rate, 100);
    });

    test('允许的间距刻度只有 9 档（4/8/12/16/20/24/32/48/64）', () {
      expect(AppDecoSpacing.grid, <double>[4, 8, 12, 16, 20, 24, 32, 48, 64]);
    });

    test('源码里不许有裸数字间距：SizedBox / EdgeInsets 的尺寸一律走命名常量', () {
      final offenders = <String>[];
      for (final line in allCode().split('\n')) {
        if (!RegExp(r'\b(SizedBox|EdgeInsets)\b').hasMatch(line)) continue;
        if (RegExp(r'(?<![A-Za-z_.])\d+(\.\d+)?').hasMatch(line)) offenders.add(line.trim());
      }
      expect(offenders, isEmpty, reason: '把数字提成常量（4dp 网格只在 token 层维护）：$offenders');
    });

    test('基准线 5 横 2 纵与推导式一致；装饰只准贴 B0 / B1 / B4', () {
      expect(AppBaseline.b0, 104);
      expect(AppBaseline.b1, 168);
      expect(AppBaseline.b2, 188);
      expect(AppBaseline.b3, 288);
      expect(AppBaseline.b4, 788);
      expect(AppBaseline.b0, AppBaseline.statusBar + AppBaseline.pageHeader);
      expect(AppBaseline.b2, AppBaseline.b1 + AppBaseline.blockGap);
      expect(AppBaseline.b4, AppBaseline.screenHeight - AppBaseline.pageBottom);
      expect(AppBaseline.pageDecoLines, <double>[104, 168, 788]);
      expect(AppBaseline.v0, 16);
      expect(AppBaseline.v1, 374);
    });

    test('标尺线端点按基准线取：B0 无左端点 / B3 左右齐备 / B4 带左端点；B2 拒绝', () {
      expect(AppBaseline.ruleDotsForBaseline(AppBaseline.b0), AppRuleLineDots.rightOnly);
      expect(AppBaseline.ruleDotsForBaseline(AppBaseline.b3), AppRuleLineDots.both);
      expect(AppBaseline.ruleDotsForBaseline(AppBaseline.b4), AppRuleLineDots.leftOnly);
      expect(() => AppBaseline.ruleDotsForBaseline(200), throwsArgumentError);
      expect(() => AppBaseline.ruleDotsForBaseline(AppBaseline.b2), throwsArgumentError);
    });

    test('标尺线与发丝线是两个组件（语义不同，不合）', () {
      expect(AppRuleLine.dotSize, 3); // 3×3 端点：设计稿为对齐像素取 3（4dp 网格的明文例外）
      expect(AppRuleLine.lineWidth, 1);
      expect(AppRuleLineDots.values.length, 3, reason: '只允许页级/区块间/页底三种端点配置');
    });

    test('圆角集合 ⊆ {0(通栏直角), 4, 6, 10, 14, 胶囊}', () {
      expect(AppDecoRadius.values, <double>[0, 4, 6, 10, 14, AppDecoRadius.capsule]);
      // 三档卡片的圆角：Hero/Content = 14（--r-card），List = 0（通栏直角）
      expect(AppDecoRadius.card, 14);
      expect(AppDecoRadius.none, 0);
    });

    test('切口边长是独立词汇 {4,6,8}，与 4dp 间距网格、圆角词汇互不混用', () {
      expect(AppNotch.sizes, <double>[4, 6, 8]);
      expect(AppDecoRadius.values.contains(8), isFalse,
          reason: '圆角词汇里没有 8 —— 切口（4/6/8）与圆角（0/4/6/10/14/胶囊）不同源，混用即"不成体系"');
    });

    testWidgets('渲染出的圆角只出现允许集合内的值', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppHeroBudgetScope(
              child: ListView(
                children: <Widget>[
                  AppContentCard(title: '段位上分 · 保底结算', child: AppMoney(36.6)),
                  AppListCard(rows: <Widget>[AppListRow(child: const Text('和平精英 · 手游'))]),
                ],
              ),
            ),
          ),
        ),
      );
      final radii = <double>{};
      for (final w in t.widgetList<Container>(find.byType(Container))) {
        final d = w.decoration;
        if (d is BoxDecoration && d.borderRadius is BorderRadius) {
          final br = d.borderRadius! as BorderRadius;
          radii.addAll(<double>[br.topLeft.x, br.topRight.x, br.bottomLeft.x, br.bottomRight.x]);
        }
      }
      for (final r in radii) {
        expect(AppDecoRadius.values.contains(r), isTrue, reason: '渲染出的圆角 $r 不在允许集合内');
      }
      // ignore: avoid_print
      print('[自检] 渲染圆角集合 = $radii ⊆ ${AppDecoRadius.values}');
    });

    test('字号种类 ⊆ {10.5, 11, 12, 13, 15, 18, 22}（docs/45 §七 口径）', () {
      final allowed = <double>{10.5, 11, 12, 13, 15, 18, 22};
      final sizes = <double>{};
      for (final m in RegExp(r'fontSize:\s*([0-9.]+)').allMatches(allCode())) {
        sizes.add(double.parse(m.group(1)!));
      }
      sizes.addAll(AppFigureSize.values.map((s) => s.value));
      expect(AppFigureSize.values.map((s) => s.value).toSet(), <double>{15, 18, 22});
      for (final s in sizes) {
        expect(allowed.contains(s), isTrue, reason: '字号 $s 不在 7 档之内');
      }
      // ignore: avoid_print
      print('[自检] 字号种类 = ${sizes.length} 档：${(sizes.toList()..sort())}');
    });
  });

  // =====================================================================================
  // ④ L-SLOT 尺寸恒为 72×20
  // =====================================================================================

  group('④ L-SLOT（等级预留位）', () {
    test('规格常量钉死：高 20 × 最长 72 · 距名字 8 · 名字行高 24 · 切口 6（防以后被人改）', () {
      expect(AppLevelSlot.slotHeight, 20);
      expect(AppLevelSlot.slotMaxWidth, 72);
      expect(AppLevelSlot.gap, 8);
      expect(AppLevelSlot.nameRowHeight, 24);
      expect(AppLevelSlot.notchCut, 6);
      expect(AppLevelSlot.labelSize, 11);
      expect(AppLevelSlot.notchCorner, AppNotchCorner.topRight);
      // 名称定了以后直接落：高 20 → 自动取档也是 6×6（不需要重新排版）
      expect(AppNotch.sizeForHeight(AppLevelSlot.slotHeight), AppLevelSlot.notchCut);
    });

    testWidgets('默认"只留几何不画形态"：行内占位高 20、宽 0', (t) async {
      await t.pumpWidget(const MaterialApp(home: Center(child: AppLevelSlot())));
      expect(t.getSize(find.byType(AppLevelSlot)), const Size(0, 20));
      // 什么都不画：组件内部没有文字、没有任何自绘
      final inside = find.descendant(of: find.byType(AppLevelSlot), matching: find.byType(Text));
      final insidePaint = find.descendant(of: find.byType(AppLevelSlot), matching: find.byType(CustomPaint));
      expect(inside, findsNothing);
      expect(insidePaint, findsNothing);
    });

    testWidgets('出图核对开关下 = 72×20（尺寸恒定，供出图量距）', (t) async {
      await t.pumpWidget(const MaterialApp(home: Center(child: AppLevelSlot(debugOutline: true))));
      expect(t.getSize(find.byType(AppLevelSlot)), const Size(72, 20));
      expect(find.text('L-SLOT'), findsOneWidget);
    });

    testWidgets('名字行：行高 24 · 名字与 L-SLOT 同一行垂直居中 · 间距恰好 8dp', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: AppNameRow(name: '青柠不加冰', debugLevelSlot: true),
            ),
          ),
        ),
      );
      expect(t.getSize(find.byType(AppNameRow)).height, AppLevelSlot.nameRowHeight);
      final name = t.getRect(find.text('青柠不加冰'));
      final slot = t.getRect(find.byType(AppLevelSlot));
      expect(slot.left - name.right, AppLevelSlot.gap);
      expect(slot.center.dy, closeTo(name.center.dy, 0.01), reason: '必须同行垂直居中');
      expect(slot.height, AppLevelSlot.slotHeight);
    });
  });

  // =====================================================================================
  // ⑤ 金额与数字：复用既有 fmtMoney
  // =====================================================================================

  group('⑤ 金额格式化（复用 fmtMoney）', () {
    test('金额串就是 fmtMoney 的产物（唯一出口，没有第二套实现）', () {
      for (final v in <num>[0, 0.5, 8.8, 36.6, 1234.5, 99999.9, -5]) {
        expect(AppMoney.text(v), fmtMoney(v));
      }
      expect(AppMoney.text(1234.5), '¥1,234.50');
      expect(AppMoney.text(8.8), '¥8.80');
    });

    test('代码正文里没有自己拼 ¥ / 没有第二个金额格式化实现', () {
      final code = allCode();
      expect(RegExp(r"'[^']*¥").hasMatch(code), isFalse, reason: '页面不得自己拼 ¥');
      expect(RegExp(r'toStringAsFixed\(2\)').hasMatch(code), isFalse);
      expect(code.contains('fmtMoney'), isTrue, reason: '必须复用既有 fmtMoney');
    });

    testWidgets('整串可命中：¥ + 两位小数 + 千分位在同一个 Text 里', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppMoney(1234.5))));
      expect(find.text('¥1,234.50'), findsOneWidget);
      expect(find.text('¥'), findsNothing, reason: '¥ 不许拆成独立小号 Text');

      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppMoney(-5))));
      expect(find.text('-¥5.00'), findsOneWidget);
    });

    testWidgets('金额按字号取金档（15/18→goldText、22→gold）+ 等宽数字 + w700；单位 12sp 异色', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppMoney(36.6, unit: '起'))));
      final money = t.widget<Text>(find.text('¥36.60'));
      final unit = t.widget<Text>(find.text('起'));
      // 默认档 md = 18px < 19 → 属"小字金"（白底 5.41:1）；22px 档才是 F 的大字金
      expect(money.style!.color, AppColors.goldText);
      expect(money.style!.fontWeight, FontWeight.w700);
      expect(money.style!.fontSize, AppFigureSize.md.value);
      expect(money.style!.fontFeatures!.first.feature, 'tnum');
      expect(unit.style!.fontSize, AppMoney.unitSize);
      expect(unit.style!.color, AppColors.textPlaceholder);
      expect(unit.style!.color, isNot(money.style!.color), reason: '单位必须与金额异色');

      // 三档字号各渲染一次，字号就是 15 / 18 / 22；金的档位随字号变
      for (final size in AppFigureSize.values) {
        await t.pumpWidget(MaterialApp(home: Scaffold(body: AppMoney(8.8, size: size))));
        final w = t.widget<Text>(find.text('¥8.80'));
        expect(w.style!.fontSize, size.value);
        expect(w.style!.color,
            size.value >= AppPrice.largeMoneySize ? AppColors.gold : AppColors.goldText,
            reason: '${size.value}px 的金档位');
      }
    });

    testWidgets('统计数字一律 #14202E（禁金）+ 千分位 + 12sp 单位', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppStat(2847, unit: '单', label: '本月已完成'))));
      final value = t.widget<Text>(find.text('2,847'));
      expect(value.style!.color, T.textPrimary);
      expect(value.style!.color, isNot(AppColors.gold));
      expect(value.style!.fontFeatures!.first.feature, 'tnum');
      expect(t.widget<Text>(find.text('单')).style!.color, AppColors.textPlaceholder);
      expect(t.widget<Text>(find.text('本月已完成')).style!.fontSize, 11);
      expect(AppStat.thousands(98.4), '98.4');
      expect(AppStat.thousands(1286), '1,286');
    });
  });

  // =====================================================================================
  // ⑥ HeroCard「每屏 ≤1」
  // =====================================================================================

  group('⑥ HeroCard 每屏 ≤1', () {
    test('上限常量 = 1', () {
      expect(AppHeroCard.maxPerScreen, 1);
      expect(AppHeroCard.inkMarkText, '祁');
    });

    testWidgets('装上预算作用域：第 2 张自动降级为 ContentCard 外观（网格与字标块消失）', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppHeroBudgetScope(
              child: Column(
                children: const <Widget>[
                  AppHeroCard(child: Text('A')),
                  AppHeroCard(child: Text('B')),
                ],
              ),
            ),
          ),
        ),
      );
      // 第 1 张：细网格 1 处 + 墨蓝字标块 1 处（字标块自带右上 6×6）；第 2 张：都不许有
      expect(find.byType(AppFineGrid), findsOneWidget);
      expect(find.text(AppHeroCard.inkMarkText), findsOneWidget);
      // 降级那张走 ContentCard 外观（左下 6×6 切口）→ 全树切口恰好 2 处：字标块右上 + 降级卡左下
      final notches = t.widgetList<AppNotch>(find.byType(AppNotch)).toList();
      expect(notches.length, 2);
      expect(notches.where((n) => n.corner == AppNotchCorner.topRight).length, 1,
          reason: '只有第 1 张的字标块有右上切口');
      expect(notches.where((n) => n.corner == AppNotchCorner.bottomLeft).length, 1,
          reason: '降级那张改走 ContentCard 的左下切口');
      expect(notches.where((n) => n.cut == 6).length, 2, reason: '两处都是 6×6（由高度推导）');
      // 品牌锚 #0F2440 只在唯一那张 hero 的字标块上出现（第 2 张降级后连它也没有）
      final ink = t
          .widgetList<AppNotch>(find.byType(AppNotch))
          .where((n) => n.baseColor == AppColors.brandInk)
          .toList();
      expect(ink.length, 1, reason: '品牌锚每屏 ≤1 处');
      expect(find.text(AppHeroCard.inkMarkText), findsOneWidget);
    });

    testWidgets('不装作用域 = 不降级（既有页面零改动的保证）', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(children: <Widget>[AppHeroCard(child: Text('A')), AppHeroCard(child: Text('B'))]),
          ),
        ),
      );
      expect(find.byType(AppFineGrid), findsNWidgets(2));
      expect(find.text(AppHeroCard.inkMarkText), findsNWidgets(2));
    });
  });

  // =====================================================================================
  // ⑦ 三档卡片 + 区块标题：各自唯一特征，不互相串
  // =====================================================================================

  group('⑦ 三档卡片与区块标题', () {
    BoxDecoration firstRoundedBox(WidgetTester t, Finder root) {
      for (final w in t.widgetList<Container>(find.descendant(of: root, matching: find.byType(Container)))) {
        final d = w.decoration;
        if (d is BoxDecoration && d.borderRadius is BorderRadius && d.color != null) return d;
      }
      fail('没找到带圆角的容器');
    }

    testWidgets('HeroCard = 细网格 + 24dp 墨蓝字标块；没有切口', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppHeroCard(child: Text('祁连山电竞')))));
      expect(find.byType(AppFineGrid), findsOneWidget);
      expect(find.byType(AppNotch), findsOneWidget); // 字标块自身右上的那一处
      expect(t.getSize(find.byType(AppFineGrid)), isNot(Size.zero));
      expect(firstRoundedBox(t, find.byType(AppHeroCard)).borderRadius, BorderRadius.circular(14));
      expect(AppHeroCard.markSize, 24);
    });

    testWidgets('ContentCard = 14 圆角 + 左下 6×6 切口；无网格、无字标块', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppContentCard(title: '段位上分 · 保底结算', child: Text('未达保底按差额补单'))),
        ),
      );
      expect(find.byType(AppFineGrid), findsNothing, reason: '细网格只给品牌区与空态，卡片里 0 处');
      expect(find.text(AppHeroCard.inkMarkText), findsNothing);
      expect(firstRoundedBox(t, find.byType(AppContentCard)).borderRadius, BorderRadius.circular(14));
      // 切口恰好一处，且落在左下 6×6
      expect(find.byType(AppNotch), findsOneWidget);
      final card = t.getRect(find.byType(AppContentCard));
      final notch = t.getRect(find.byType(AppNotch));
      expect(notch.width, 6);
      expect(notch.height, 6);
      expect(notch.left, closeTo(card.left, 0.01));
      expect(notch.bottom, closeTo(card.bottom, 0.01));
      // 标题前的 4×16 品牌短标
      expect(find.byType(AppBrandBar), findsOneWidget);
      final tick = t.getSize(find.byType(AppBrandBar));
      expect(tick, const Size(4, 16));
    });

    testWidgets('ListCard = 通栏 0 圆角 + 发丝线行；无网格、无切口', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppListCard(
              rows: <Widget>[AppListRow(child: Text('和平精英 · 手游')), AppListRow(child: Text('三角洲行动 · 手游'))],
            ),
          ),
        ),
      );
      expect(find.byType(AppFineGrid), findsNothing);
      expect(find.byType(AppNotch), findsNothing, reason: '序列表格不需要"角"的语义');
      final root = t.widget<Container>(find.descendant(of: find.byType(AppListCard), matching: find.byType(Container)).first);
      final d = root.decoration! as BoxDecoration;
      expect(d.borderRadius, isNull, reason: '通栏 = 直角');
      expect(find.byType(AppHairline), findsOneWidget, reason: '两行之间恰好一条发丝线');
      expect(t.widget<AppHairline>(find.byType(AppHairline)).indent, AppDecoSpacing.hairlineIndent);
      expect(AppListCard.rowHeights, <double>[48, 56, 64]);
      // 行高 56 × 2 + 行间发丝 1 + 上下描边 1×2（Container 把 decoration 的 border 计入内距）
      expect(t.getSize(find.byType(AppListCard)).height, AppListCard.defaultRowHeight * 2 + 1 + 2);
    });

    testWidgets('区块标题：顶级 = 4×16 短标 + 标尺线；第二层 = 只有标尺线', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppSectionHeaderDeco(title: '选择分部', subtitle: '按游戏 · 平台划分', action: '共 3 个'))));
      expect(find.byType(AppBrandBar), findsOneWidget);
      expect(find.byType(AppRuleLine), findsOneWidget);
      expect(t.getSize(find.byType(AppBrandBar)), const Size(4, 16));
      expect(t.widget<Text>(find.text('选择分部')).style!.fontSize, 15);
      expect(t.widget<Text>(find.text('共 3 个')).style!.fontSize, 12);

      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppSectionHeaderDeco(title: '最近评价', subtitle: '128 条', level: AppSectionLevel.secondary))));
      expect(find.byType(AppBrandBar), findsNothing, reason: '短标数量 = 顶级分区数，第二层不配');
      expect(find.byType(AppRuleLine), findsOneWidget);
      expect(t.widget<Text>(find.text('最近评价')).style!.fontSize, 13);
    });
  });

  // =====================================================================================
  // ⑧ 空态 / 骨架：不靠插画
  // =====================================================================================

  group('⑧ 空态与骨架', () {
    testWidgets('空态 = 5% 细网格 + 48×48 线框图标（带切口）+ 标尺线 + 一句下一步动作', (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppEmptyDeco(title: '这个分部还没有订单', hint: '换个分部看看，或去服务页下单', action: '去服务页'),
          ),
        ),
      );
      expect(find.byType(AppFineGrid), findsOneWidget);
      expect(find.byType(AppRuleLine), findsOneWidget);
      expect(find.byIcon(Icons.receipt_long_outlined), findsOneWidget);
      expect(find.text('换个分部看看，或去服务页下单'), findsOneWidget);
      expect(find.text('去服务页'), findsOneWidget);
      // 空态里不许有 emoji（图标一律走 Material 线性图标）
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        expect(RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true).hasMatch(w.data ?? ''), isFalse);
      }
      // 图标框 48×48，切口由高度推导（48÷4=12 → 封顶 8）
      final frame = t.getRect(find.byType(AppNotch));
      expect(frame.width, AppNotch.sizeForHeight(AppEmptyDeco.frameSize));
      expect(AppNotch.sizeForHeight(AppEmptyDeco.frameSize), 8);
    });

    testWidgets('骨架块保留真内容圆角（卡 14 / 通栏 0 / 图标 6 / 条 4），静态模式可 settle', (t) async {
      expect(AppSkeletonShape.card.radius, AppDecoRadius.card);
      expect(AppSkeletonShape.banner.radius, AppDecoRadius.none);
      expect(AppSkeletonShape.block.radius, AppDecoRadius.small);
      expect(AppSkeletonShape.bar.radius, AppDecoRadius.tag);

      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppSkeletonBlock(width: 120, shape: AppSkeletonShape.card, animate: false)),
        ),
      );
      await t.pumpAndSettle();
      final clip = t
          .widgetList<ClipRRect>(find.byType(ClipRRect))
          .firstWhere((c) => c.borderRadius == BorderRadius.circular(AppDecoRadius.card));
      expect(clip.borderRadius, BorderRadius.circular(14));
      // 静态模式（animate: false）= 纯灰块，没有亮带 painter
      final bands = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<AppSkeletonBandPainter>();
      expect(bands, isEmpty);
    });

    testWidgets('骨架亮带：40% 宽 / 白 55% / 1.2s（硬边矩形位移，不是软过渡）', (t) async {
      expect(AppSkeletonBlock.bandWidthRatio, 0.40);
      expect(AppSkeletonBlock.bandOpacity, 0.55);
      expect(AppSkeletonBlock.period, const Duration(milliseconds: 1200));

      await t.pumpWidget(const MaterialApp(home: Scaffold(body: AppSkeletonBlock(width: 120, shape: AppSkeletonShape.card))));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 300));
      final band = t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<AppSkeletonBandPainter>()
          .toList();
      expect(band, isNotEmpty);
      expect(band.first.progress, greaterThan(0));
      // 卸载，释放 Ticker（测试结束不许留着活动 Ticker）
      await t.pumpWidget(const SizedBox());
      await t.pump();
    });
  });

  // =====================================================================================
  // ⑨ 自检汇总（对齐 docs/45 §七 口径）
  // =====================================================================================

  group('⑨ 自检数字', () {
    test('软过渡 0 · 真裁 0 · 阴影 0 · emoji 0 · 「积分」0 · 硬编码色值 0', () {
      var gradient = 0;
      var clip = 0;
      var shadow = 0;
      var emoji = 0;
      var jifen = 0;
      var hexColor = 0;

      final emojiRe = RegExp(
        r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{1F1E6}-\u{1F1FF}]',
        unicode: true,
      );

      for (final f in decoSources()) {
        final src = f.readAsStringSync();
        final code = codeOnly(src);
        for (final line in code.split('\n')) {
          if (RegExp(r'Gradient|createShader|ShaderMask').hasMatch(line)) gradient++;
          if (line.contains('ClipPath')) clip++;
          if (RegExp(r'BoxShadow|boxShadow|elevation:\s*[1-9]').hasMatch(line)) shadow++;
          if (line.contains('积分')) jifen++;
          if (RegExp(r'Color\(0x').hasMatch(line)) hexColor++;
        }
        // emoji 只在**代码正文**里算（注释里的 ⚠ 是文档标记，不是 UI 内容）；
        // 真正要守的是"用户看到的东西里 0 个 emoji"，另有一条整屏合成的运行时断言
        emoji += emojiRe.allMatches(code).length;
      }

      // ignore: avoid_print
      print('[自检] 软渐变 $gradient · 真裁 $clip · 阴影 $shadow · emoji $emoji · 「积分」$jifen · 硬编码色值 $hexColor');
      expect(gradient, 0);
      expect(clip, 0);
      expect(shadow, 0);
      expect(emoji, 0);
      expect(jifen, 0);
      expect(hexColor, 0);
    });

    test('金色只出现在【金额】与【等级位】两处：色板只引用 AppColors.gold / T.gold', () {
      final goldLines = allCode()
          .split('\n')
          .where((l) => l.contains('gold'))
          .map((l) => l.trim())
          .toList();
      for (final line in goldLines) {
        expect(
          line.contains('T.gold') || line.contains('AppColors.gold'),
          isTrue,
          reason: '金的引用只能来自 token：$line',
        );
      }
      // 禁止出现"更亮的金"（引入即等于出现第二个金）
      expect(allCode().contains('D4A017'), isFalse);
      expect(AppColors.gold, const Color(0xFFF59E0B));
    });

    testWidgets('整屏合成：金色文字只落在金额与等级容器内', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppHeroBudgetScope(
              child: ListView(
                children: <Widget>[
                  const AppSectionHeaderDeco(title: '选择分部', subtitle: '按游戏 · 平台划分', action: '共 3 个'),
                  const AppContentCard(
                    title: '段位上分 · 保底结算',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        AppMoney(36.6, unit: '起'),
                        AppStat(2847, unit: '单', label: '本月已完成'),
                      ],
                    ),
                  ),
                  AppListCard(
                    rows: <Widget>[
                      AppListRow(child: const AppNameRow(name: '青柠不加冰', debugLevelSlot: true)),
                      AppListRow(child: const Text('三角洲行动 · 手游')),
                    ],
                  ),
                  const AppEmptyDeco(title: '这个分部还没有订单', hint: '换个分部看看，或去服务页下单'),
                  const AppSkeletonBlock(width: 120, shape: AppSkeletonShape.card, animate: false),
                ],
              ),
            ),
          ),
        ),
      );

      final goldTexts = <String>[];
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        // 两档金都算"金"（2026-10-16：<19px 用小字金 goldText，≥19px 用 gold）
        final c = w.style?.color;
        if (c == AppColors.gold || c == AppColors.goldText) goldTexts.add(w.data ?? '');
      }
      // ignore: avoid_print
      print('[自检] 金色文字 = $goldTexts');
      for (final s in goldTexts) {
        final isMoney = s.startsWith('¥') || s.startsWith('-¥');
        final isLevel = s == 'L-SLOT'; // 等级位的出图核对框（生产不渲染）
        expect(isMoney || isLevel, isTrue, reason: '金色文字「$s」不在金额/等级容器内 = 违规');
      }
      expect(goldTexts.where((s) => s.startsWith('¥')).length, 1);

      // 整屏合成里 emoji = 0（用户可见文案口径，比源码扫描更接近验收）
      final emojiRe = RegExp(
        r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]',
        unicode: true,
      );
      var rendered = 0;
      for (final w in t.widgetList<Text>(find.byType(Text))) {
        rendered++;
        expect(emojiRe.hasMatch(w.data ?? ''), isFalse, reason: '用户可见文案里出现 emoji：${w.data}');
      }
      // ignore: avoid_print
      print('[自检] 整屏合成：文本 $rendered 处 · emoji 0 · 金色文字 ${goldTexts.length} 处（全部在金额/等级容器内）');
    });

    test('圆角与字体的"手挑值"为 0：本文件里找不到裸的 BorderRadius.circular(数字)', () {
      expect(RegExp(r'BorderRadius\.circular\(\s*\d').hasMatch(allCode()), isFalse,
          reason: '圆角必须走 AppDecoRadius.* 命名常量');
    });
  });
}
