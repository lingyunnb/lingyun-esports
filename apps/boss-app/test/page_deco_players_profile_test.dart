import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/models/review_models.dart';
import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/pages/worker_profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ============ 陪玩列表页 / 打手个人主页 · 品牌装饰系统自检（2026-10-15）============
///
/// 这两页是「全平台品牌化」在**老板端第二、三站**的应用层（装饰地基本身在 core 的
/// `deco.dart`，由 `packages/core/test/deco_test.dart` 逐条钉住；服务页/订单页由
/// `page_deco_services_orders_test.dart` 钉住）。本文件只回答一件事：
/// **这一页真的把装饰落上去了，而且没有把任何一条红线踩回来。**
///
/// 口径全部来自 `docs/45-品牌装饰系统（待审批）.md` §二/§三/§四/§五：
/// 渐变面积 0 · 卡片阴影 0 · emoji 0 · 硬编码色值 0 · 「积分」0 ·
/// 间距落 4dp 网格 · 圆角 ⊆ {0,4,6,10,14,胶囊} · 斜切角只取 4/6/8 ·
/// 短标数 = 顶级分区数 · 未选中态一律不切口 · 统计数字不上金。
///
/// ⚠️ 与 `players_profile_a_test.dart`（A 套的 28 条结构与口径断言）**职责分开**：
/// 那个文件锁"字段与口径"，本文件锁"装饰与红线"。两边都必须绿。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPlayers(WidgetTester tester, _Fixture fx) async {
    useTallViewport(tester);
    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _api(fx))));
    await settle(tester);
  }

  Future<void> pumpProfile(WidgetTester tester, _Fixture fx, {Key? key}) async {
    useTallViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: WorkerProfilePage(key: key, api: _api(fx), workerId: '11', fallbackNickname: '小云'),
    ));
    await settle(tester);
  }

  // =========================================================================
  // ① 列表页 · 基准线装饰（B0 / B4 + 区块标题）
  // =========================================================================
  group('① 陪玩列表页 · 贴基准线的装饰', () {
    testWidgets('页级标尺线贴 B0、页底信号线贴 B4；端点配置由基准线给出（不许手挑）', (tester) async {
      await pumpPlayers(tester, _Fixture.list());

      final rules = tester
          .widgetList<AppRuleLine>(find.descendant(
            of: find.byType(PlayersPage),
            matching: find.byType(AppRuleLine),
          ))
          .toList();
      expect(rules.length, 3, reason: 'B0 页级 1 条 + 区块标题 1 条 + B4 页底 1 条');

      expect(rules.first.dots, AppBaseline.ruleDotsForBaseline(AppBaseline.b0));
      expect(rules.first.dots, AppRuleLineDots.rightOnly, reason: 'B0 页级分隔：无左端点方块');
      expect(rules.last.dots, AppBaseline.ruleDotsForBaseline(AppBaseline.b4));
      expect(rules.last.dots, AppRuleLineDots.leftOnly, reason: 'B4 页底信号线：带左端点方块');
      expect(rules[1].dots, AppRuleLineDots.both, reason: '区块标题下的线：两端齐备');

      expect(AppRuleLine.dotSize, 3, reason: '端点方块 3×3 是设计稿定案值');
      expect(AppBaseline.pageDecoLines,
          containsAll(<double>[AppBaseline.b0, AppBaseline.b1, AppBaseline.b4]));
      expect(() => AppBaseline.ruleDotsForBaseline(AppBaseline.b2), throwsArgumentError,
          reason: 'B2 是内容停靠线，装饰不许压在上面（由代码拒绝，不靠人记）');
    });

    testWidgets('区块标题：4×16 品牌短标 + 8dp + 标题 + 标尺线；短标数 = 顶级分区数', (tester) async {
      await pumpPlayers(tester, _Fixture.list());

      final bars = tester
          .widgetList<AppBrandBar>(find.descendant(
            of: find.byType(PlayersPage),
            matching: find.byType(AppBrandBar),
          ))
          .toList();
      expect(bars.length, 1, reason: '本页顶级分区 = 1（名单）；AI 引导是第二层，不配短标');
      for (final b in bars) {
        expect(b.width, AppBrandBar.defaultWidth, reason: '4×16 短标');
        expect(b.height, AppBrandBar.defaultHeight);
        expect(b.width % 4, 0);
        expect(b.height % 4, 0);
      }
      expect(AppDecoSpacing.tickToTitle, 8, reason: '短标到标题 8dp（组内紧）');
      expect(AppDecoSpacing.ruleToContent, 8, reason: '线到标题 8dp');
      // 计数行的文案锁在既有测试的 Text 键上，行本身照旧 32dp
      expect(tester.widget<Text>(find.byKey(const Key('players-count-row'))).data, '共 2 位陪玩');
    });
  });

  // =========================================================================
  // ② 列表页 · 筛选胶囊（分部宫格）
  // =========================================================================
  group('② 陪玩列表页 · 筛选胶囊的切口', () {
    testWidgets('选中格右下 8×8（由胶囊高 32 推导 = 谱系 filterChip 档）；未选中一律不切口', (tester) async {
      await pumpPlayers(tester, _Fixture.list());

      // 选中态 = 当前分部那一格（首次进页会自动选中第一个分部）
      final selected = find.descendant(
        of: find.byKey(const Key('division-cell-和平精英')),
        matching: find.byType(AppNotch),
      );
      expect(selected, findsOneWidget, reason: '选中态必须切口');
      final n = tester.widget<AppNotch>(selected);
      expect(n.cut, 8);
      expect(n.corner, AppNotchCorner.bottomRight);
      expect(n.corner, AppNotchRole.filterChip.corner, reason: '右下 = 选中"向前"的方向感');
      /**
       * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
       *
       * 原断言是「格高 44」（旧的方块宫格）。参考图 1 的游戏筛选是**一行胶囊**（高 32）
       * → 元素高度换成 32，切口仍由高度推导、仍落在谱系 `filterChip` 档（32 → 8×8）。
       * 断言本质上检验的是"切口只由高度决定、且与谱系登记值一致"，这一点没变。
       */
      expect(n.height, 32, reason: '切口档位只由**元素高度**决定（胶囊高 32）');
      expect(AppNotch.sizes, contains(n.cut), reason: '切口只取 4/6/8');
      // 谱系自证：由高度推导出来的档位，必须等于登记档位的边长
      expect(AppNotch.sizeForHeight(32), AppNotchRole.filterChip.cut,
          reason: '「胶囊高 32 → 8×8」与谱系登记值必须逐值一致，否则就是两套口径');
      expect(AppNotchRole.filterChip.selfConsistent, isTrue);

      final unselected = find.descendant(
        of: find.byKey(const Key('division-cell-all')),
        matching: find.byType(AppNotch),
      );
      expect(unselected, findsNothing, reason: '切口是"选中/状态"的专属信号：未选中态一律不切口');
      expect(AppNotch.resolveSize(height: 32, selected: false), 0);
    });
  });

  // =========================================================================
  // ②-2 列表页 · 顶部入口卡（两张，各占一半宽）
  // =========================================================================
  group('②-2 陪玩列表页 · 入口卡', () {
    testWidgets('只有两张（全部 / 人气陪玩），各占一半宽、中间 8dp，不留第三格空位', (tester) async {
      await pumpPlayers(tester, _Fixture.list());

      /**
       * 【新口径 · 负责人 2026-10-18 真机圈图】「选择陪玩那里明星大神那个删掉」。
       *
       * 第三张原本就是假入口：后端 0 字段 → 只能渲染成「待接入」且不可点。删掉之后
       * **不留第三格空位**（两张 `Expanded` 平分整行）。这条用例把新口径钉死：
       * 谁把第三张加回来、或把两张改成"三分之一宽 + 空一格"，这里立刻红。
       */
      final all = find.byKey(const Key('players-entry-all'));
      final hot = find.byKey(const Key('players-entry-hot'));
      expect(all, findsOneWidget, reason: '第一张：全部（默认排序）');
      expect(hot, findsOneWidget, reason: '第二张：人气陪玩（按接单量降序）');
      expect(find.byKey(const Key('players-entry-star')), findsNothing,
          reason: '「明星大神」入口必须整张删除（它本来就是点不动的假入口）');
      expect(find.text('明星大神'), findsNothing);
      expect(find.textContaining(kFieldPendingText), findsNothing,
          reason: '删掉那张卡后，入口行上不再有任何「待接入」灰字');

      final allRect = tester.getRect(all);
      final hotRect = tester.getRect(hot);
      // 高度与纵向位置：与删除前逐值相同（这次只改"数量与宽度分配"，不改尺寸与样式）
      expect(allRect.height, 64, reason: '入口卡高 64 不许被这次删除改动');
      expect(hotRect.height, 64);
      expect(hotRect.top, closeTo(allRect.top, 0.01), reason: '两张必须同一行');
      // 各占一半宽：等宽 + 中间只隔 8dp + 左右各收 16dp 页边（末枚右缘不许缩进）
      expect(allRect.width, closeTo(hotRect.width, 0.01), reason: '两张必须等宽 = 各占一半');
      expect(hotRect.left - allRect.right, closeTo(8, 0.01), reason: '中间间距 8（4dp 网格）');
      final double viewportWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(allRect.left, closeTo(AppSpacing.page, 0.01), reason: '左页边 16');
      expect(hotRect.right, closeTo(viewportWidth - AppSpacing.page, 0.01),
          reason: '右页边 16 —— 第二张补到页边，不留第三格空位');

      // 两张上的文字各就各位（「全部」同时是分部胶囊的文案，所以必须收窄到卡内找）
      expect(find.descendant(of: all, matching: find.text('全部')), findsOneWidget);
      expect(find.descendant(of: hot, matching: find.text('人气陪玩')), findsOneWidget);
      expect(find.descendant(of: hot, matching: find.text('按接单量')), findsOneWidget,
          reason: '第二张的副标仍在（排序口径没变）');
    });
  });

  // =========================================================================
  // ③ 列表页 · 卡片语言与空态
  // =========================================================================
  group('③ 陪玩列表页 · 卡片与空态', () {
    /**
     * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
     *
     * 原断言是「陪玩卡 = 通栏 0 圆角 + 只留行底发丝（ListCard 档）」。
     * 参考图 1 的陪玩卡是**浮在浅灰页底上的白色圆角卡**（卡白 + 1px 描边 + 圆角 14），
     * 所以这里把"卡片语言"重钉到 ContentCard 档，但**两条红线一条不放宽**：
     * **0 阴影**、**圆角必须落在 AppDecoRadius 词汇表里**、**行高恒定**。
     */
    testWidgets('陪玩卡 = 白底 + 1px strokeSoft + 圆角 14（ContentCard 档，无切口、无阴影）', (tester) async {
      await pumpPlayers(tester, _Fixture.list());

      final card = find.byKey(const Key('player-card-101'));
      expect(card, findsOneWidget);
      final box = tester.widget<Container>(
        find.descendant(of: card, matching: find.byType(Container)).first,
      );
      final d = box.decoration! as BoxDecoration;
      expect(d.color, T.bgCardSolid, reason: '卡白（页底是 #F6F7F9，卡必须与页底分得开）');
      expect(d.borderRadius, BorderRadius.circular(AppDecoRadius.card), reason: '圆角 14（卡片档）');
      expect(AppDecoRadius.values, contains(AppDecoRadius.card));
      final b = d.border! as Border;
      expect(b.top.color, AppColors.strokeSoft, reason: '1px 描边走 AppColors.strokeSoft');
      expect(b.top.width, 1);
      expect(d.boxShadow ?? const <BoxShadow>[], isEmpty, reason: '卡片阴影必须 0');

      // 卡片行高恒定 = PlayersPage.cardHeight（148 → 128：金额位删除后重算；装饰不许把它撑高）
      expect(tester.getSize(card).height, PlayersPage.cardHeight);
    });

    testWidgets('卡片小胶囊：≤3 枚、只在名字下方，形状走分区标签档（右上 6×6）', (tester) async {
      await pumpPlayers(tester, _Fixture.list());

      final capsules = find.byType(PlayerCapsule);
      expect(capsules, findsOneWidget, reason: '只有带 divisionName 的那张卡有副标');
      final notch = tester.widget<AppNotch>(find.descendant(of: capsules, matching: find.byType(AppNotch)));
      expect(notch.cut, 6);
      expect(notch.corner, AppNotchCorner.topRight);
      expect(notch.height, PlayerCapsule.capsuleHeight);
      // 两页的"分部副标"必须是同一个角色、同一档
      expect(PlayerCapsule.notchCorner, AppNotchRole.sectionTag.corner);
      expect(WorkerCapsule.notchCorner, AppNotchRole.sectionTag.corner);
      expect(AppNotch.sizeForHeight(PlayerCapsule.capsuleHeight), AppNotchRole.sectionTag.cut,
          reason: '高 20 → 6×6');
      expect(AppNotchRole.sectionTag.selfConsistent, isTrue);

      // ≤3 的硬上限仍在代码里收口，且位置仍在名字下方（既有 A 套断言继续生效）
      final code = _stripComments(_read(_listSrc));
      expect(code.contains('.take(3)'), isTrue);
      expect(RegExp(r'PlayerCapsule\(label:').allMatches(code).length, 1,
          reason: '整页只有一处胶囊渲染点（名字下方）');
    });

    testWidgets('空态：5% 细网格 + 线框图标 + 标尺线（保留既有 AppEmpty，不靠插画）', (tester) async {
      await pumpPlayers(tester, _Fixture.list(empty: true));

      expect(find.byType(AppEmpty), findsOneWidget, reason: '空态类型仍锁在既有断言上（不换组件）');
      expect(
        find.descendant(of: find.byType(PlayersPage), matching: find.byType(AppFineGrid)),
        findsWidgets,
        reason: '空态必须有一层 5% 细网格打底（"这里还没有内容"的质感底）',
      );
      expect(AppFineGrid.defaultOpacity, 0.05);
      expect(AppFineGrid.defaultStep % 4, 0, reason: '网格间距落 4dp 网格');
      expect(AppFineGrid.lineWidth, 1, reason: '细网格是 1px 硬边线（不是 1dp 描边、不是软过渡）');

      final emptyRule = tester
          .widgetList<AppRuleLine>(find.descendant(of: find.byType(PlayersPage), matching: find.byType(AppRuleLine)))
          .where((r) => r.width == AppEmptyDeco.defaultRuleWidth)
          .toList();
      expect(emptyRule, isNotEmpty, reason: '空态收口用 88 宽的标尺线（`AppEmptyDeco` 同值）');
      expect(emptyRule.first.dots, AppRuleLineDots.both);
    });

    testWidgets('骨架块走 AppSkeletonBlock（静态灰块：不跳版、不挂死 pumpAndSettle）', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(MaterialApp(home: PlayersPage(api: _api(_Fixture.list()))));
      // **不额外推进时钟**：首帧就是骨架态（数据要等下一次 pump 才重建）
      final blocks = tester.widgetList<AppSkeletonBlock>(find.byType(AppSkeletonBlock)).toList();
      expect(blocks, isNotEmpty, reason: '加载中要画骨架');
      expect(blocks.every((b) => b.animate == false), isTrue,
          reason: '静态灰块：本页既有 5 套渲染用例走 pumpAndSettle，无限动画会把它们挂死');
      expect(AppSkeletonBlock.baseColor, AppColors.fieldBg);
      expect(tester.getSize(find.byKey(const Key('players-skeleton-0'))).height, PlayersPage.cardHeight,
          reason: '骨架卡与真卡同高（数据回来零跳版）');
      await settle(tester);
      expect(tester.takeException(), isNull);
      // 数据回来后骨架退场
      expect(find.byKey(const Key('players-skeleton-0')), findsNothing);
      expect(find.byKey(const Key('player-card-101')), findsOneWidget);
    });
  });

  // =========================================================================
  // ④ 主页 · 头部三个装饰全部走 deco.dart 的原子
  // =========================================================================
  group('④ 打手个人主页 · 头部与装饰原子同源', () {
    testWidgets('细网格 / 切口 / 标尺线 = AppFineGrid + AppNotch + AppRuleLine（手写绘制已删）', (tester) async {
      await pumpProfile(tester, _Fixture.profile());

      final field = find.byKey(const Key('worker-profile-header-field'));
      expect(field, findsOneWidget);

      // ① 场：细网格（原子）
      expect(find.descendant(of: field, matching: find.byType(AppFineGrid)), findsOneWidget,
          reason: '头部网格场必须走 AppFineGrid（间距/透明度/线宽只有一份定义）');

      // ③ 切口（原子）：由**场高 176** 推导 → 谱系封顶 8×8
      /**
       * 【口径重钉 · 负责人 2026-10-17 指示照参考图重构】
       *
       * 原断言是「场角 1 枚 + 场内分部副标胶囊 1 枚 = 2」。参考图 2 把「游戏胶囊 + 等级徽章」
       * 挪到了**介绍卡下面**（不在海报里），等级徽章改成**灰底待接入牌子**（不走斜切角）
       * → 海报场内只剩**场角那一枚**切口。断言从"必须是 2"重钉成"必须是 1"，其余逐条不变。
       */
      final notches = tester
          .widgetList<AppNotch>(find.descendant(of: field, matching: find.byType(AppNotch)))
          .toList();
      expect(notches.length, 1, reason: '海报场内只有场角这一枚切口（胶囊与等级牌子都不在场内）');
      expect(notches.every((n) => AppNotch.sizes.contains(n.cut)), isTrue, reason: '切口只取 4/6/8');
      final notch = notches.firstWhere((n) => n.height == WorkerProfilePage.headerHeight);
      expect(notch.cut, 8, reason: 'AppNotch.sizeForHeight(176) = 8（谱系封顶，不做第四档）');
      expect(notch.corner, AppNotchCorner.topRight);

      // ③ 标尺线（原子）：头部与内容的分界，两端 3×3 端点
      final rule = tester.widget<AppRuleLine>(find.descendant(
        of: find.byKey(const Key('worker-profile-ruler')),
        matching: find.byType(AppRuleLine),
      ));
      expect(rule.dots, AppRuleLineDots.both);
      expect(AppRuleLine.dotSize, 3);

      // 源码级：手写的三个绘制类必须已经不存在（不删掉就会变成"第二套装饰"）
      final code = _stripComments(_read(_profileSrc));
      for (final gone in const <String>['_GridPainter', '_CornerCutPainter', '_CornerCutClipper', 'ClipPath']) {
        expect(code.contains(gone), isFalse,
            reason: '头部/主按钮的手写装饰必须换成原子（残留 $gone = 两套实现）');
      }
    });
  });

  // =========================================================================
  // ⑤ 主页 · 数字、判定、卡片与空态
  // =========================================================================
  group('⑤ 打手个人主页 · 数字与判定', () {
    testWidgets('统计数字：等宽（tabular）+ 三档字号 sm(15)，且不上金', (tester) async {
      await pumpProfile(tester, _Fixture.profile());

      final stats = find.byKey(const Key('worker-profile-stats'));
      final rate = tester.widget<Text>(find.descendant(of: stats, matching: find.text('96.5%')));
      expect(rate.style!.fontSize, AppFigureSize.sm.value, reason: '三档字号只取 15/18/22');
      expect(rate.style!.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(rate.style!.color, T.textPrimary, reason: '统计数字 = 正文色 #14202E');
      expect(rate.style!.color, isNot(T.gold), reason: '统计数字禁金（金只给金额与等级位）');

      final orders = tester.widget<Text>(find.descendant(of: stats, matching: find.text('30 次')));
      expect(orders.style!.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(orders.style!.color, isNot(T.gold));

      // 「暂无评价」不是数字 → 退回 13/600（不让一个词冒充比率）
      // 换夹具必须换 Key：不换的话 `WorkerProfilePage` 的 State 会被复用、
      // `initState` 不再跑 → 屏幕上还是上一份详情（这是测试写法问题，不是页面问题）
      await pumpProfile(tester, _Fixture.profileReal(), key: const ValueKey('profile-real'));
      final none = tester.widget<Text>(find.descendant(of: stats, matching: find.text(kNoReviewYet)));
      expect(none.style!.fontSize, 13);
      expect(none.style!.fontWeight, FontWeight.w600);
    });

    testWidgets('评价判定：右上 6×6 切口 + 四重信号（图标 / 形状 / 字重 / 颜色）', (tester) async {
      await pumpProfile(tester, _Fixture.profile());

      final tiles = find.byType(WorkerReviewTile);
      expect(tiles, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        final tile = tiles.at(i);
        final notch = tester.widget<AppNotch>(find.descendant(of: tile, matching: find.byType(AppNotch)));
        expect(notch.cut, 6, reason: '判定小片高 20 → 右上 6×6（与状态标签同角位）');
        expect(notch.corner, AppNotchRole.statusTag.corner);
      }
      // 四重信号：图标（形状）+ 文案 + 字重 w700 + 颜色
      expect(find.byIcon(AppIcon.check), findsOneWidget);
      expect(find.byIcon(AppIcon.complaint), findsOneWidget);
      final good = tester.widget<Text>(find.text('满意'));
      expect(good.style!.fontWeight, FontWeight.w700);
      expect(good.style!.color, reviewVerdictColor(true));
      expect(tester.widget<Text>(find.text('不满意')).style!.color, reviewVerdictColor(false));
      expect(reviewVerdictColor(true), isNot(reviewVerdictColor(false)), reason: '颜色只是第四重信号');
    });

    testWidgets('介绍卡 / 统计卡走 ContentCard 左下 6×6 切口；底部主按钮右上 8×8（不再真裁）', (tester) async {
      await pumpProfile(tester, _Fixture.profile());

      for (final key in const <String>['worker-profile-intro', 'worker-profile-stats']) {
        final notched = find.ancestor(of: find.byKey(Key(key)), matching: find.byType(AppNotched)).first;
        final n = tester.widget<AppNotch>(find.descendant(of: notched, matching: find.byType(AppNotch)));
        expect(n.cut, AppNotchRole.contentCard.cut, reason: 'ContentCard 左下 6×6');
        expect(n.corner, AppNotchRole.contentCard.corner);
        expect(n.corner, AppNotchCorner.bottomLeft);
        expect(AppNotchRole.contentCard.selfConsistent, isTrue);
      }

      final button = find.byKey(const Key('worker-profile-order-button'));
      expect(tester.getSize(button).height, 44, reason: '主按钮高 44 不许被装饰改变');
      final bn = tester.widget<AppNotch>(find.descendant(of: button, matching: find.byType(AppNotch)));
      expect(bn.cut, 8, reason: 'AppNotch.sizeForHeight(44) = 8（原手写的 10dp 属谱系外）');
      expect(bn.corner, AppNotchCorner.topRight);
      expect(find.descendant(of: button, matching: find.byType(ClipPath)), findsNothing,
          reason: 'deco.dart 硬红线：不得出现路径真裁（真裁会切断描边、留缝）');
    });

    testWidgets('0 评价空态走 AppEmptyDeco（细网格 + 线框图标 + 标尺线）；L-SLOT 仍只留几何', (tester) async {
      await pumpProfile(tester, _Fixture.profileReal());

      expect(find.byKey(const Key('worker-profile-reviews-empty')), findsOneWidget);
      expect(find.byType(AppEmptyDeco), findsOneWidget);
      final empty = find.byType(AppEmptyDeco);
      expect(find.descendant(of: empty, matching: find.byType(AppFineGrid)), findsOneWidget);
      final rule = tester.widget<AppRuleLine>(find.descendant(of: empty, matching: find.byType(AppRuleLine)));
      expect(rule.width, AppEmptyDeco.defaultRuleWidth);
      expect(rule.dots, AppRuleLineDots.both);
      expect(AppEmptyDeco.frameSize, 48, reason: '线框图标 48×48（切口由高度推导 = 8×8）');
      expect(AppEmptyDeco.iconSize, 24);

      // L-SLOT：**只留几何、不画形态**（几何取自装饰原子，两页同一份定义）
      expect(tester.getSize(find.byKey(const Key('worker-profile-level-slot'))),
          const Size(WorkerProfilePage.levelSlotMaxWidth, WorkerProfilePage.levelSlotHeight));
      expect(WorkerProfilePage.levelSlotHeight, AppLevelSlot.slotHeight);
      expect(WorkerProfilePage.levelSlotMaxWidth, AppLevelSlot.slotMaxWidth);
      expect(PlayersPage.levelSlotHeight, AppLevelSlot.slotHeight);
      expect(PlayersPage.levelSlotMaxWidth, AppLevelSlot.slotMaxWidth);
      expect(const AppLevelSlot().debugOutline, isFalse, reason: '生产恒 false（虚线框只给出图核对）');
    });

    testWidgets('骨架块走 AppSkeletonBlock（静态）', (tester) async {
      useTallViewport(tester);
      await tester.pumpWidget(MaterialApp(
        home: WorkerProfilePage(api: _api(_Fixture.profile()), workerId: '11'),
      ));
      final blocks = tester.widgetList<AppSkeletonBlock>(find.byType(AppSkeletonBlock)).toList();
      expect(blocks, isNotEmpty, reason: '加载中要画骨架（与真块逐块等高）');
      expect(blocks.every((b) => b.animate == false), isTrue,
          reason: '静态灰块：本页渲染用例走 pumpAndSettle，无限动画会把它们挂死');
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  // =========================================================================
  // ⑥ 源码级红线自检（两页）
  // =========================================================================
  group('⑥ 源码级红线自检', () {
    final files = <String, String>{
      'players_page.dart': _listSrc,
      'worker_profile_page.dart': _profileSrc,
    };

    test('渐变面积 0：不出现任何渐变家族与着色器创建', () {
      const banned = <String>[
        'LinearGradient', 'RadialGradient', 'SweepGradient',
        'ShaderMask', 'createShader', 'Gradient.lerp',
      ];
      for (final e in files.entries) {
        final code = _stripComments(_read(e.value));
        for (final ban in banned) {
          expect(code.contains(ban), isFalse,
              reason: '${e.key} 出现 $ban（docs/45 §四：渐变不作主视觉）');
        }
      }
    });

    test('卡片阴影 0（唯一一处已登记例外：AI 回复气泡的 v4 会话阴影，非卡片）', () {
      for (final e in files.entries) {
        final lines = _stripComments(_read(e.value))
            .split('\n')
            .where((l) => l.contains('boxShadow'))
            .map((l) => l.trim())
            .toList();
        if (e.key == 'worker_profile_page.dart') {
          expect(lines, isEmpty, reason: '打手主页卡片阴影必须 0');
          continue;
        }
        // 陪玩列表页：唯一一处必须落在 `_replyBubble`（与 AI 会话页共用 ChatV4 视觉的
        // 会话气泡，属"浮在内容之上"的一类，不是卡片；本轮不动它 = 不把同一个气泡做成两套）。
        expect(lines, hasLength(1), reason: '列表页出现第二处阴影：$lines');
        expect(lines.single, contains('bubbleShadow'),
            reason: '唯一允许的一处是既有 AI 会话气泡阴影（ChatV4 共用），不是卡片');
      }
    });

    test('emoji 0：两页源码（剥注释 + 含注释）都不含 emoji 类字符', () {
      final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]', unicode: true);
      for (final e in files.entries) {
        // ① 代码面（注释里的记号不算"用 emoji 当图标"，与 `players_profile_a_test.dart`
        //    的 `_stripComments` 口径一致 —— 那条既有断言也必须继续绿）；
        expect(emoji.hasMatch(_stripComments(_read(e.value))), isFalse,
            reason: '${e.key} 的代码里出现 emoji（图标一律线性 Material 图标）');
        // ② 源码面：连注释一起扫也必须是 0（⚠/⛔ 这类记号同样不作为品牌语言的成员）。
        expect(emoji.hasMatch(_read(e.value)), isFalse,
            reason: '${e.key} 源码（含注释）出现 emoji 类字符');
      }
    });

    testWidgets('emoji 0（渲染面）：两页屏幕上渲染出的文字一个 emoji 都没有', (tester) async {
      final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]', unicode: true);
      await pumpPlayers(tester, _Fixture.list());
      expect(_renderedEmoji(tester, emoji), isEmpty, reason: '陪玩列表页渲染面出现 emoji 当图标');
      await pumpProfile(tester, _Fixture.profile(), key: const ValueKey('emoji-profile'));
      expect(_renderedEmoji(tester, emoji), isEmpty, reason: '打手主页渲染面出现 emoji 当图标');
    });

    test('硬编码色值 0：不出现 Color(0x…)', () {
      final hex = RegExp(r'Color\(\s*0x[0-9A-Fa-f]{6,8}\s*\)');
      for (final e in files.entries) {
        final hit = hex.firstMatch(_stripComments(_read(e.value)));
        expect(hit, isNull,
            reason: '${e.key} 出现硬编码色值 ${hit?.group(0)}：色板只走 T.* / AppColors.*');
      }
    });

    test('「积分」0（金额一律 ¥ / 元）', () {
      for (final e in files.entries) {
        expect(_read(e.value).contains('积分'), isFalse, reason: '${e.key} 出现「积分」');
      }
    });

    test('间距落 4dp 网格：只允许一条已登记的 ≤2px 光学微调', () {
      final spacing = RegExp(
        r'(?:SizedBox\((?:height|width):\s*|EdgeInsets\.(?:fromLTRB|only|symmetric)\((?:[a-zA-Z]*:\s*)?)([\d.]+(?:\s*,\s*[\d.]+)*)',
      );
      final offGrid = <String>[];
      for (final e in files.entries) {
        final code = _stripComments(_read(e.value));
        for (final m in spacing.allMatches(code)) {
          final line = code.split('\n')[code.substring(0, m.start).split('\n').length - 1].trim();
          for (final raw in m.group(1)!.split(',')) {
            final v = double.tryParse(raw.trim());
            if (v == null || v == 0) continue;
            if (!AppDecoSpacing.grid.contains(v)) offGrid.add('${e.key}: $v（$line）');
          }
        }
      }
      expect(offGrid, hasLength(1), reason: '越格间距：$offGrid');
      expect(offGrid.single, contains('top: 1'),
          reason: '唯一一处 = 祁山标对 12sp 文字的光学微调（≤2px 档，docs/45 单列这一类）');
      expect(AppDecoSpacing.grid, <double>[4, 8, 12, 16, 20, 24, 32, 48, 64]);
    });

    test('圆角只取 0 / 4 / 6 / 10 / 14 / 胶囊', () {
      final radius = RegExp(r'Border(?:Radius)?\.circular\(([\d.]+)\)');
      for (final e in files.entries) {
        final code = _stripComments(_read(e.value));
        for (final m in radius.allMatches(code)) {
          final v = double.parse(m.group(1)!);
          expect(AppDecoRadius.values, contains(v),
              reason: '${e.key} 出现圆角 $v：只允许 0/4/6/10/14/胶囊（≥16 当卡片即玩具感）');
        }
      }
      expect(AppDecoRadius.none, 0, reason: '通栏列表档用直角');
    });

    test('金色只有两个落点：这两页一处都不许出现', () {
      final gold = RegExp(r'(?:T|AppColors)\.gold\b');
      for (final e in files.entries) {
        final hit = gold.firstMatch(_stripComments(_read(e.value)));
        expect(hit, isNull,
            reason: '${e.key} 直接取金色：金只给金额与等级位，本页两者都没有（统计数字一律 #14202E）');
      }
    });

    test('统计数字用 deco 的字号档（三档 15/18/22），不在这里另挑字号', () {
      expect(AppFigureSize.values.map((s) => s.value), <double>[15, 18, 22]);
      expect(AppMoney.unitSize, 12);
    });
  });
}

// ===========================================================================
// 夹具与工具
// ===========================================================================

const String _listSrc = 'apps/boss-app/lib/pages/players_page.dart';
const String _profileSrc = 'apps/boss-app/lib/pages/worker_profile_page.dart';

class _Fixture {
  _Fixture({this.players, this.profile});

  final Map<String, dynamic>? players;
  final Map<String, dynamic>? profile;

  /// `/divisions`：线上只有 1 个分部（宫格"有几格画几格"）
  List<Map<String, dynamic>> get divisions => const <Map<String, dynamic>>[
        <String, dynamic>{'id': '1', 'name': '和平精英', 'shortName': '和平精英'},
      ];

  /// 名单：一张带分部副标（有胶囊）+ 一张不带（不画空格子）
  factory _Fixture.list({bool empty = false}) => _Fixture(
        players: <String, dynamic>{
          'list': empty
              ? const <dynamic>[]
              : <dynamic>[
                  <String, dynamic>{
                    'workerId': '101',
                    'nickname': '青柠不加冰',
                    'intro': '三角洲行动端游与手游均可，接单后 10 分钟内进房。',
                    'avatarMediaId': null,
                    'divisionId': '1',
                    'divisionName': '和平精英·手游',
                    'completedOrders': 30,
                    'reviewCount': 2,
                    'satisfiedRate': '96.5',
                  },
                  <String, dynamic>{
                    'workerId': '102',
                    'nickname': '黑桃老K',
                    'intro': '',
                    'avatarMediaId': null,
                    'completedOrders': 1284,
                    'reviewCount': 4,
                    'satisfiedRate': '98.2',
                  },
                ],
          'total': empty ? 0 : 2,
          'page': 1,
          'pageSize': 50,
        },
      );

  /// 详情：有介绍有评价（一满意一不满意）；头像 null → 字标兜底
  factory _Fixture.profile() => _Fixture(
        players: _Fixture.list().players,
        profile: <String, dynamic>{
          'id': '11',
          'nickname': '小云',
          'intro': '和平精英 · 手游。晚 9 点到次日 2 点在线，不接急单。',
          'avatarMediaId': null,
          'completedOrders': 30,
          'reviewCount': 2,
          'satisfiedRate': '96.5',
          'divisionName': '和平精英·手游',
          'divisionId': '1',
          'reviews': const <Map<String, dynamic>>[
            <String, dynamic>{
              'satisfied': true,
              'remark': '节奏很稳，全程没掉线',
              'createdAt': '2026-10-15T09:20:00.000Z',
              'nicknameMasked': '老***板',
            },
            <String, dynamic>{
              'satisfied': false,
              'remark': '中间挂机了 15 分钟',
              'createdAt': '2026-10-14T21:05:00.000Z',
              'nicknameMasked': '雪***山',
            },
          ],
        },
      );

  /// 线上真实现状：头像 null / 介绍空 / 0 评价
  factory _Fixture.profileReal() => _Fixture(
        profile: const <String, dynamic>{
          'id': '11',
          'nickname': '小云',
          'intro': '',
          'avatarMediaId': null,
          'completedOrders': 0,
          'reviewCount': 0,
          'satisfiedRate': null,
          'divisionName': null,
          'divisionId': null,
          'reviews': <dynamic>[],
        },
      );
}

ApiClient _api(_Fixture fx) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(fx);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.fx);

  final _Fixture fx;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.path;
    if (path.startsWith('/divisions')) {
      return _body(200, <String, dynamic>{'code': 0, 'message': 'ok', 'data': fx.divisions});
    }
    if (path.startsWith('/public/players')) {
      return _body(200, <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': fx.players ?? const <String, dynamic>{},
      });
    }
    if (path.contains('/reviews')) {
      return _body(200, <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': const <String, dynamic>{'list': <dynamic>[], 'total': 2, 'page': 2, 'pageSize': 10},
      });
    }
    if (path.startsWith('/public/workers/')) {
      final p = fx.profile;
      if (p == null) return _body(500, <String, dynamic>{'code': 500, 'message': '服务器开小差了', 'data': null});
      return _body(200, <String, dynamic>{'code': 0, 'message': 'ok', 'data': p});
    }
    return _body(200, <String, dynamic>{'code': 0, 'message': 'ok', 'data': null});
  }

  static ResponseBody _body(int status, Map<String, dynamic> json) => ResponseBody.fromString(
        jsonEncode(json),
        status,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );

  @override
  void close({bool force = false}) {}
}

/// 读源码（测试工作目录 = apps/boss-app；用 `players_profile_a_test.dart` 同一套仓库根探测）
String _read(String repoRelative) => File('${_repoRoot()}/$repoRelative').readAsStringSync();

/// 仓库根（从测试文件位置往上找，直到看到 `apps` 与 `docs`）
String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/apps').existsSync() && Directory('${dir.path}/docs').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}

/// 剥注释：注释里写禁项名字不算违规（与 `page_deco_services_orders_test.dart` 同一口径）
String _stripComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// 整页渲染出的文字里命中的 emoji（"emoji 当图标"的真实入口是 Text）
List<String> _renderedEmoji(WidgetTester tester, RegExp emoji) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where(emoji.hasMatch)
    .toList();
