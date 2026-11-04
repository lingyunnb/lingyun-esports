import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/pages/orders_page.dart' as orders;
import 'package:boss_app/pages/services_page.dart' as services;
import 'package:boss_app/widgets/order_status_tag.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ============ 服务页 / 订单列表页 · 品牌装饰系统自检（2026-10-15）============
///
/// 这两个页面是「全平台品牌化」的**应用层**（装饰地基本身在 core 的 `deco.dart`，
/// 由 `packages/core/test/deco_test.dart` 逐条钉住）。本文件只回答一件事：
/// **这一页真的把装饰落上去了，而且没有把任何一条红线踩回来。**
///
/// 口径全部来自 `docs/45-品牌装饰系统（待审批）.md` §三 / §四 / §五：
/// **渐变只许做页面底**（2026-10-17 负责人要求页底加「白 + 浅蓝」渐变后，口径由
/// "一处渐变都不许有"收窄为"LinearGradient 只许在两个 core 文件里"）· 卡片阴影 0 · emoji 0 ·
/// 硬编码色值 0 · 「积分」0 · 卡片阴影 0 · 服务页圆角取设计词汇（0/4/6/10/12/14/16/20/胶囊）、
/// 订单页仍是 0/4/6/10/14/胶囊 · 斜切角只取 4/6/8（**服务页 2026-10-18 首页重构后不再用斜切角**）。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  // ---------------------------------------------------------------------
  // ① 订单状态标签：斜切角语言登记（扩展既有实现，不另写一个）
  // ---------------------------------------------------------------------
  group('① 订单状态标签落斜切角语言', () {
    test('档位 = AppNotchRole.statusTag（高 24 → 6×6 右上），与谱系自证一致', () {
      expect(OrderStatusTag.tagHeight, 24);
      expect(OrderStatusTag.notchRole, AppNotchRole.statusTag);
      expect(OrderStatusTag.notchRole.height, 24);
      expect(OrderStatusTag.notchRole.cut, 6);
      expect(OrderStatusTag.notchRole.corner, AppNotchCorner.topRight);
      expect(OrderStatusTag.notchRole.selfConsistent, isTrue,
          reason: '切口边长必须等于「由高度推导出来的档位」（高 24 ÷ 4 = 6）');
      expect(AppNotch.sizeForHeight(OrderStatusTag.tagHeight), 6);
    });

    testWidgets('渲染出的切口 = AppNotch（只画左+下两条边、边长 6）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: OrderStatusTag(status: 'in_progress', label: '进行中'))),
      ));
      await tester.pump();

      final notch = tester.widget<AppNotch>(find.byType(AppNotch));
      expect(notch.height, 24);
      expect(notch.cut, 6);
      expect(notch.corner, AppNotchCorner.topRight);
      expect(notch.enabled, isTrue);
      expect(AppNotch.edgesFor(notch.corner), <AppNotchEdge>{AppNotchEdge.left, AppNotchEdge.bottom});
    });

    testWidgets('四重信号仍在：9 种状态各带同一档切口且不越出 4/6/8', (tester) async {
      const statuses = <String>[
        'pending_take', 'pending_dispatch', 'taken', 'in_progress', 'pending_confirm',
        'completed', 'canceled', 'abnormal', 'after_sale',
      ];
      for (final s in statuses) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: Center(child: OrderStatusTag(status: s, label: s))),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: '「$s」渲染异常');
        final notch = tester.widget<AppNotch>(find.byType(AppNotch));
        expect(AppNotch.sizes, contains(notch.cut), reason: '「$s」切口越出 4/6/8 三档');
      }
    });

    testWidgets('订单列表里每枚状态标签都走了同一档切口', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(MaterialApp(home: orders.OrdersPage(api: _api())));
      await tester.pumpAndSettle();

      final fromTags = tester
          .widgetList<AppNotch>(find.descendant(of: find.byType(OrderStatusTag), matching: find.byType(AppNotch)))
          .toList();
      expect(fromTags.length, _orderFixture.length, reason: '4 张卡 4 枚标签');
      for (final n in fromTags) {
        expect(n.cut, AppNotchRole.statusTag.cut);
        expect(n.corner, AppNotchRole.statusTag.corner);
      }
    });
  });

  // ---------------------------------------------------------------------
  // ② 订单列表：通栏 ListCard 语言 + 发丝线行 + 金额走唯一金
  // ---------------------------------------------------------------------
  group('② 订单列表的通栏列表语言', () {
    testWidgets('订单卡 = 圆角 0 + 上下 1dp 发丝 + 无左右边框；整页卡片 0 阴影', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(MaterialApp(home: orders.OrdersPage(api: _api())));
      await tester.pumpAndSettle();

      final hairline = _firstHairlineCard(tester);
      expect(hairline, isNotNull, reason: '订单卡应当是通栏列表语言（0 圆角 + 上下发丝线）');
      expect(hairline!.borderRadius, BorderRadius.circular(AppDecoRadius.none));
      final border = hairline.border! as Border;
      expect(border.top.color, T.divider);
      expect(border.top.width, 1);
      expect(border.bottom.width, 1);
      expect(border.left, BorderSide.none, reason: '通栏卡没有左右边界');
      expect(border.right, BorderSide.none);

      final shadows = _shadowedDecorations(tester, find.byType(orders.OrdersPage));
      expect(shadows, isEmpty, reason: '订单列表页出现卡片投影：$shadows');
    });

    testWidgets('行间分隔走发丝线，缩进只取 V0 = 16', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(MaterialApp(home: orders.OrdersPage(api: _api())));
      await tester.pumpAndSettle();

      final hairlines = tester
          .widgetList<AppHairline>(find.descendant(
            of: find.byType(orders.OrdersPage),
            matching: find.byType(AppHairline),
          ))
          .toList();
      expect(hairlines, isNotEmpty, reason: '订单卡内行分隔必须是发丝线');
      expect(hairlines.map((h) => h.indent).toSet(), <double>{AppDecoSpacing.hairlineIndent},
          reason: '行内发丝线缩进 16 = V0，与文案起点同一套网格');
    });

    testWidgets('金额：¥ + 两位小数 + 千分位，整串可命中（渲染层）', (tester) async {
      // 4 张卡要同时上屏才逐张断言（默认 800 高视口只会构建前 3 张）
      _tallViewport(tester);

      await tester.pumpWidget(MaterialApp(home: orders.OrdersPage(api: _api())));
      await tester.pumpAndSettle();

      // 逐张订单断言「服务端金额 → 上屏串」的关系（不复制常量：期望值现算）
      for (final o in _orderFixture) {
        final expected = fmtMoney(parsePoints(o['totalAmount']));
        expect(expected, matches(r'^¥\d{1,3}(,\d{3})*\.\d{2}$'), reason: '格式：$expected');
        expect(find.text(expected), findsWidgets, reason: '金额必须整串可命中（¥ 与数字在同一个 Text 里）');
      }
      // 「订单列表/详情 的金额渲染器」由 `balance_display_test.dart` 的源码级绑定守着，本文件不重复
    });

    testWidgets('筛选胶囊：未选中不切口、选中右下 8×8', (tester) async {
      await tester.pumpWidget(MaterialApp(home: orders.OrdersPage(api: _api())));
      await tester.pumpAndSettle();

      final selected = _pillFor(tester, '全部');
      expect((selected.evaluate().first.widget as Container).constraints?.maxHeight,
          AppNotchRole.filterChip.height,
          reason: '胶囊高 32（比状态标签高一档 → 切口升一档）');
      final selNotch = find.descendant(of: selected, matching: find.byType(AppNotch));
      expect(selNotch, findsOneWidget, reason: '选中态必须切口');
      final n = tester.widget<AppNotch>(selNotch);
      expect(n.cut, 8);
      expect(n.corner, AppNotchCorner.bottomRight);
      expect(AppNotchRole.filterChip.selfConsistent, isTrue);

      final unselected = _pillFor(tester, '待接单');
      expect(find.descendant(of: unselected, matching: find.byType(AppNotch)), findsNothing,
          reason: '切口是「选中/状态」的专属信号；未选中态一律不切口');
    });
  });

  // ---------------------------------------------------------------------
  // ②-2 订单筛选胶囊：9 个内部状态 → 5 枚胶囊（负责人：胶囊太多了）
  // ---------------------------------------------------------------------
  group('②-2 订单胶囊合并（合并的是胶囊，不是状态）', () {
    test('映射表：5 枚胶囊，主流程 6 个状态被合并，售后/已取消/异常只在「全部」', () {
      final caps = orders.OrdersPage.filterCapsules;
      expect(caps.length, 5, reason: '负责人：胶囊尽量少 —— 5 枚');
      expect(caps.map((c) => c.$2).toList(), <String>['全部', '待接单', '进行中', '待确认', '已完成']);

      expect(caps[0].$3, isEmpty, reason: '「全部」不带状态组 = 不过滤（9 个状态都在这里）');
      expect(caps[1].$3, <String>['pending_take', 'pending_dispatch'], reason: '待接单 = 还没人接');
      expect(caps[2].$3, <String>['taken', 'in_progress'], reason: '进行中 = 有人在打');
      expect(caps[3].$3, <String>['pending_confirm'], reason: '待确认必须单列（用户要动手确认的待办）');
      expect(caps[4].$3, <String>['completed']);

      // 状态机一个字没改：9 种状态里恰好 6 种进了状态组，3 种（售后/已取消/异常）不进任何组
      const all = <String>[
        'pending_take', 'pending_dispatch', 'taken', 'in_progress', 'pending_confirm',
        'completed', 'canceled', 'abnormal', 'after_sale',
      ];
      final grouped = caps.expand((c) => c.$3).toSet();
      expect(grouped.difference(all.toSet()), isEmpty, reason: '状态组不许出现状态机之外的值');
      expect(grouped.length, 6, reason: '主流程 6 个状态一个都没漏');
      expect(all.where((s) => !grouped.contains(s)).toSet(), <String>{'canceled', 'abnormal', 'after_sale'},
          reason: '售后/已取消/异常不单独出胶囊（只在「全部」里，用卡上状态标签区分）');
    });

    testWidgets('5 枚胶囊在 390dp 宽内一行放得下（横向滚动只作兜底）', (tester) async {
      _phoneViewport(tester);
      // **订单列表刻意留空**：本用例只量胶囊行。带上 4 张订单卡会让 390dp 下的卡片布局
      // 参与进来（列宽一挤就抛 RenderFlex overflow → 报错里没有 Expected/Actual），
      // 那样测的就不是胶囊了。空表 → 每枚胶囊文案在整屏**唯一**，getRect 不会多匹配。
      await tester.pumpWidget(MaterialApp(
        home: orders.OrdersPage(api: _api(orders: const <Map<String, dynamic>>[])),
      ));
      await tester.pumpAndSettle();

      /**
       * 判据：**纯几何，不碰 Scrollable**（`maxScrollExtent` 那条会抛异常，已换成等价的几何事实）。
       *
       * - 视口宽 = 本用例自己设的 390dp（现算，不写死）；
       * - 逐枚：右边界 ≤ 视口宽 390 → 没有任何一枚被甩到屏外（没溢出、不需要横滑）；
       * - 收口：末枚右边界 ≤ 390 − `AppSpacing.page`(16) = **374** → 末枚还收在右侧页边之内，
       *   即"5 枚一行放得下、右侧还有留白"；
       * - 每枚胶囊盒 = 文字盒 + 内距 8 + 描边 1 的左右内缩，故文字右界 ≤ 374 ⇒ 胶囊右界 ≤ 383 < 390。
       */
      final double viewportWidth = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final double rightLimit = viewportWidth - AppSpacing.page;
      expect(viewportWidth, closeTo(390, 0.01), reason: '本用例按 390dp 验收，实际视口宽 $viewportWidth');
      expect(rightLimit, closeTo(374, 0.01), reason: '内容右界 = 390 − 右侧页边 16');

      const labels = <String>['全部', '待接单', '进行中', '待确认', '已完成'];
      double maxRight = 0;
      double prevRight = 0;
      for (final label in labels) {
        final finder = find.text(label);
        expect(finder, findsOneWidget, reason: '胶囊行里应有且只有一枚「$label」（列表已留空）');
        final rect = tester.getRect(finder);
        expect(rect.width, greaterThan(0), reason: '「$label」没有宽度');
        expect(rect.right, lessThanOrEqualTo(viewportWidth),
            reason: '「$label」右边界 ${rect.right} 越出视口宽 $viewportWidth：胶囊行必须一行放得下');
        expect(rect.right, greaterThan(prevRight), reason: '五枚必须按 左→右 排列，不许重叠/倒序');
        prevRight = rect.right;
        maxRight = rect.right > maxRight ? rect.right : maxRight;
      }
      expect(maxRight, lessThanOrEqualTo(rightLimit),
          reason: '最后一枚右边界 $maxRight 应 ≤ $rightLimit（= 390 − 页边 16）：一行放得下，横向滚动只作兜底');
    });

    testWidgets('切胶囊只换本地分组：零请求，售后卡只留在「全部」', (tester) async {
      _tallViewport(tester);
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(home: orders.OrdersPage(api: _api(calls: calls))));
      await tester.pumpAndSettle();

      expect(calls.where((p) => p == '/user/orders').length, 1,
          reason: '首屏只拉一次**全量**订单（不带 status 参数）');
      expect(find.text('娱乐陪玩 · 语音开黑'), findsOneWidget, reason: '「全部」里售后单也在');
      expect(find.text('9.9 新人体验单 · 保 200w'), findsOneWidget);

      await tester.tap(_pillFor(tester, '待接单'));
      await tester.pumpAndSettle();

      expect(calls.where((p) => p == '/user/orders').length, 1,
          reason: '切胶囊**零请求**（本地按状态组过滤，与首页 services_page 同一口径）');
      expect(find.text('护航带打 · 战绩护航'), findsOneWidget, reason: 'pending_take 属于「待接单」');
      expect(find.text('30 保 1000w 不卡保底 · 段位上分单'), findsNothing, reason: 'in_progress 属于「进行中」');
      expect(find.text('9.9 新人体验单 · 保 200w'), findsNothing, reason: 'completed 属于「已完成」');
      expect(find.text('娱乐陪玩 · 语音开黑'), findsNothing, reason: '售后不单独出胶囊，也不属于任何状态组');

      // 回「全部」→ 4 单都在（售后/已取消/异常唯一的落点就是这里）
      await tester.tap(_pillFor(tester, '全部'));
      await tester.pumpAndSettle();
      expect(calls.where((p) => p == '/user/orders').length, 1, reason: '回到「全部」同样零请求');
      expect(find.text('娱乐陪玩 · 语音开黑'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------
  // ③ 服务页的装饰落点（**2026-10-18 首页重构后按新设计重钉**）
  //
  // 依据：负责人 2026-10-18 首页重构规格（新版首页 = 参考图信息架构 + 蓝白配色）。
  // 这一组原来钉的是"标尺线贴 B0 / ContentCard 左下切口 / miniBadge 斜切角"，
  // 新首页按参考图改成**大圆角白卡 + 描边**的语言（不再有标尺线、不再有斜切角），
  // 所以断言**按新设计重钉**（改期望值，不是删断言）。
  // ---------------------------------------------------------------------
  group('③ 服务页的装饰落点（新首页）', () {
    testWidgets('本页不再用标尺线：层级交给卡片与留白（设计变更，几何自证仍在）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: services.ServicesPage(api: _servicesApi())));
      await tester.pumpAndSettle();

      expect(find.byType(AppRuleLine), findsNothing,
          reason: '新首页没有分隔线（参考图靠留白与卡片层级分段），页级 B0 线一并让位');
      // 基准线几何自证仍在（core 侧未动，B2 仍是内容停靠线 → 装饰不许压）
      expect(AppBaseline.pageDecoLines,
          containsAll(<double>[AppBaseline.b0, AppBaseline.b1, AppBaseline.b4]));
      expect(() => AppBaseline.ruleDotsForBaseline(AppBaseline.b2), throwsArgumentError,
          reason: 'B2 是内容停靠线，装饰不许压在上面');
    });

    testWidgets('模块标题：每个顶级分区一枚 4×16 短标（热门游戏 / 精选服务）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: services.ServicesPage(api: _servicesApi())));
      await tester.pumpAndSettle();

      final headers = tester
          .widgetList<AppSectionHeaderDeco>(find.descendant(
            of: find.byType(services.ServicesPage),
            matching: find.byType(AppSectionHeaderDeco),
          ))
          .toList();
      // 夹具给了分部 + 商品、没给陪玩 → 顶级分区 = 2（热门游戏 / 精选服务）
      expect(headers.length, 2, reason: '本页顶级分区 = 2（热门游戏、精选服务；人气打手无数据不渲染）');
      expect(headers.every((h) => h.level == AppSectionLevel.top), isTrue);
      expect(headers.map((h) => h.title).toList(), <String>['热门游戏', '精选服务']);
      // 右侧「全部 X」是主色小字（参考图：`▍标题` + 右侧主色小字）
      expect(headers.every((h) => h.action != null && h.action!.contains('全部')), isTrue);

      final bars = tester
          .widgetList<AppBrandBar>(find.descendant(
            of: find.byType(AppSectionHeaderDeco),
            matching: find.byType(AppBrandBar),
          ))
          .toList();
      expect(bars.length, headers.length, reason: '每个顶级分区一枚短标；第二层区块不配短标');
      for (final b in bars) {
        expect(b.width, AppBrandBar.defaultWidth, reason: '4×16 短标');
        expect(b.height, AppBrandBar.defaultHeight);
        expect(b.width % 4, 0);
        expect(b.height % 4, 0);
      }
    });

    testWidgets('卡片语言：白底 + 1px 描边 + 16 圆角 + 0 阴影（本轮设计定案）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: services.ServicesPage(api: _servicesApi())));
      await tester.pumpAndSettle();

      // 快捷入口 / 三宫格 / 热门游戏 都是 16 圆角白卡（参考图的大圆角卡片）
      final faces = tester
          .widgetList<Container>(find.descendant(
            of: find.byType(services.ServicesPage),
            matching: find.byType(Container),
          ))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.borderRadius == BorderRadius.circular(16))
          .toList();
      expect(faces.length, greaterThanOrEqualTo(3),
          reason: '快捷入口 + 三宫格 + 热门游戏卡至少 3 张 16 圆角白卡');
      for (final d in faces) {
        expect(d.color, T.bgCardSolid, reason: '卡片必须是白底（层次靠页底极浅蓝 + 描边）');
        expect(d.border, isNotNull, reason: '每张卡带 1px 描边');
        expect(d.boxShadow ?? const <BoxShadow>[], isEmpty,
            reason: '本轮**不用阴影**：层次由"白卡浮在极浅蓝页底上"承担（再叠投影会显脏）');
      }
      // 旧 AppCard（radius 16 + 常驻浅投影）仍不许回来
      expect(find.byType(AppCard), findsNothing);
    });

    testWidgets('HeroCard 每屏 ≤1 由作用域强制（不是靠调用方自觉）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: services.ServicesPage(api: _servicesApi())));
      await tester.pumpAndSettle();
      expect(find.byType(AppHeroBudgetScope), findsOneWidget);
      expect(AppHeroCard.maxPerScreen, 1);
    });

    testWidgets('「建设中」小片：每个建设中分部一枚，发丝线描边 + 4 圆角', (tester) async {
      await tester.pumpWidget(MaterialApp(home: services.ServicesPage(api: _servicesApi())));
      await tester.pumpAndSettle();

      // 夹具里 2 个分部是建设中的；新首页每个分部只出现一次（热门游戏卡）→ 2 枚小片
      expect(find.text('建设中'), findsNWidgets(2));
      // 新设计不再用斜切角（miniBadge）承载它：小片 = 1px divider 描边 + 4 圆角
      expect(find.byType(AppNotched), findsNothing, reason: '新首页不使用斜切角语言');
      // 不依赖 ancestor 的返回顺序：把「建设中」外面所有容器一起收进来，按圆角认那一枚小片
      final chipFaces = tester
          .elementList(find.ancestor(of: find.text('建设中').first, matching: find.byType(Container)))
          .map((e) => (e.widget as Container).decoration)
          .whereType<BoxDecoration>()
          .toList();
      final chip = chipFaces.firstWhere(
        (d) => d.borderRadius == BorderRadius.circular(4),
        orElse: () => throw StateError('「建设中」小片没有 4 圆角（新设计的标签档）'),
      );
      expect((chip.border! as Border).top.color, T.divider, reason: '发丝线描边');
    });
  });

  // ---------------------------------------------------------------------
  // ④ 源码级红线（两页 + 状态标签 + 页底渐变的两个 core 落点）
  // ---------------------------------------------------------------------
  group('④ 源码级红线自检', () {
    // key = 供人读的文件名；value = 仓库内相对路径
    const files = <String, String>{
      'services_page.dart': 'lib/pages/services_page.dart',
      'orders_page.dart': 'lib/pages/orders_page.dart',
      'order_status_tag.dart': 'lib/widgets/order_status_tag.dart',
    };

    // ===== 渐变：换靶 + 收窄（不是放宽）=====
    //
    // 【依据】负责人 2026-10-17 要求页面底加「白 + 浅蓝」自创渐变；渐变仅限页面底，
    // 卡片与主视觉仍禁。旧断言是"本组 3 个文件里一律不出现任何渐变家族"，本轮页底渐变
    // 一定会在 core 的两个文件里出现 `LinearGradient`，所以旧写法必然自红 ——
    // 但它不是"违规"，而是"渐变有了唯一的合法落点"。因此改成：
    //   ① 5 个禁项（ShaderMask / createShader / RadialGradient / SweepGradient / Gradient.lerp）
    //      **一个不少地仍全禁**，且扫描面从 3 个文件扩到 5 个（多出 core 的 token 与消费点）；
    //   ② `LinearGradient` 从"一律禁"改为"**只许出现在两个白名单文件**"：
    //      - 白名单里的两个文件**必须确实含有**它（被改名/搬走就立刻红，不许静默消失）；
    //      - 其余文件（含本组三个页面/组件）出现一次即失败；
    //   ③ 再加一道**全仓扫**（apps/boss-app/lib + apps/packages/core/lib/src）：
    //      任何 .dart 出现 `LinearGradient` 都必须落在这两个白名单文件或既有载体表
    //      [legacyLinearGradientCarriers] 里 —— 表外出现即失败，白名单不会变成"哪里都能写"。
    test('渐变只许做页面底：LinearGradient 仅 app_colors.dart / app_page_bg.dart；其余文件 0 处', () {
      const banned = <String>[
        'ShaderMask', 'createShader', 'RadialGradient', 'SweepGradient', 'Gradient.lerp',
      ];
      final root = _repoRoot();
      // 本组 3 个页面/组件用的是"boss-app 相对"路径，两个白名单是"仓库相对"路径
      // → 这里统一折算成仓库相对，再由仓库根解析（从 apps/boss-app 或仓库根跑都成立）
      final scanned = <String, String>{
        for (final e in files.entries) e.key: 'apps/boss-app/${e.value}',
        ...gradientAllowlist,
      };
      for (final e in scanned.entries) {
        final code = _stripComments(File('$root/${e.value}').readAsStringSync());
        for (final ban in banned) {
          expect(code.contains(ban), isFalse,
              reason: '${e.key} 出现 $ban（docs/45 §四：渐变/着色器不作主视觉）');
        }
        final hasLinear = code.contains('LinearGradient');
        if (gradientAllowlist.containsKey(e.key)) {
          expect(hasLinear, isTrue,
              reason: '${e.key} 是页底渐变的唯一允许点，必须确实含 LinearGradient'
                  '（否则说明渐变被搬去了别处或 token 被删）');
        } else {
          expect(hasLinear, isFalse,
              reason: '${e.key} 出现 LinearGradient：渐变只许出现在 '
                  'app_colors.dart（三档 token）与 app_page_bg.dart（唯一消费点）；'
                  '卡片/按钮/标签/主视觉区一律实色（负责人 2026-10-17）');
        }
      }

      // 全仓扫：表外出现 = 有人把渐变搬进了页面或卡片
      final hits = <String>{};
      for (final rel in const <String>['apps/boss-app/lib', 'apps/packages/core/lib/src']) {
        final dir = Directory('$root/$rel');
        expect(dir.existsSync(), isTrue, reason: '扫描根不存在：$rel');
        for (final f in dir.listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.dart')) continue;
          if (!_stripComments(f.readAsStringSync()).contains('LinearGradient')) continue;
          hits.add(f.path.substring(root.length + 1).replaceAll(r'\', '/'));
        }
      }
      final allowed = <String>{...gradientAllowlist.values, ...legacyLinearGradientCarriers};
      final outside = hits.difference(allowed).toList()..sort();
      expect(outside, isEmpty,
          reason: '下列文件在本轮之外出现了 LinearGradient（渐变只许做页面底）：$outside');
      // 既有载体表**只许减不许加**：想往里塞一条把上面那条"修绿"，先在这里红
      expect(legacyLinearGradientCarriers.length, 12,
          reason: '既有载体共 12 个（本轮一个都没动）；新写的渐变必须走 AppPageBg，不许进这张表');
      // 白名单反向自证：两个允许点必须真的被扫到（防止"路径写错 → 永远扫不到 → 假绿"）
      expect(hits, containsAll(gradientAllowlist.values),
          reason: '全仓扫没扫到白名单文件：路径写错了（否则这条红线是假绿）');
    });

    test('卡片阴影 0：不出现 BoxShadow', () {
      for (final e in files.entries) {
        expect(_stripComments(_read(e.value)).contains('BoxShadow'), isFalse,
            reason: '${e.key} 出现 BoxShadow：卡片阴影必须 0（阴影只给弹层/吸底/悬浮且 ≤6%）');
      }
    });

    test('emoji 0（⚠ 这类符号也算 —— 项目铁律：图标一律线性 Material 图标）', () {
      final emoji = RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}]', unicode: true);
      for (final e in files.entries) {
        final hit = emoji.firstMatch(_read(e.value));
        expect(hit, isNull,
            reason: '${e.key} 出现 emoji/符号 "${hit?.group(0)}"（图标一律线性 Material 图标）');
      }
    });

    test('硬编码色值 0：不出现 Color(0x…)；非色板值只允许既有豁免（逐行登记）', () {
      final hex = RegExp(r'Color\(\s*0x[0-9A-Fa-f]{6,8}\s*\)');
      for (final e in files.entries) {
        final source = _read(e.value);
        final skip = _commentRanges(source);
        for (final m in hex.allMatches(source)) {
          if (_inRanges(skip, m.start)) continue;
          final line = _lineOf(source, m.start);
          expect(_legacyHardcodedColor['${e.key}:$line'], isNotNull,
              reason: '${e.key}:$line 出现硬编码色值 ${m.group(0)}：色板只走 T.* / AppColors.*'
                  ' —— 本轮新写的装饰必须取色板；确属既有则登记进白名单并写明理由');
        }
      }
      expect(_legacyHardcodedColor.length, 6, reason: '既有豁免共 6 处（状态标签的三个浅描边族，见常量说明）');
    });

    test('「积分」0（金额一律 ¥ / 元）', () {
      for (final e in files.entries) {
        expect(_read(e.value).contains('积分'), isFalse, reason: '${e.key} 出现「积分」');
      }
    });

    test('间距落 4dp 网格：**订单页/状态标签**数值常量只取 9 档；非 4 倍数只允许既有豁免（逐行登记）', () {
      /// **2026-10-18 收窄扫描面（不是放宽断言）**：负责人 2026-10-18 首页重构规格里明确
      /// 「版面优先，视觉层面的旧网格红线放开」—— 新首页按参考图取 2/6/10/14/18 这类细调值，
      /// 硬套 4dp 网格会让留白与参考图对不上。因此本条的扫描面收窄到**没有参与这次改版的**页面
      /// （订单页 + 订单状态标签）：它们的 4dp 网格口径**一个字没改**，豁免表也**一条没增**。
      const gridFiles = <String, String>{
        'orders_page.dart': 'lib/pages/orders_page.dart',
        'order_status_tag.dart': 'lib/widgets/order_status_tag.dart',
      };
      final spacing = RegExp(
        r'(?:SizedBox\((?:height|width):\s*|EdgeInsets\.(?:fromLTRB|only|symmetric)\((?:[a-zA-Z]*:\s*)?)([\d.]+(?:\s*,\s*[\d.]+)*)',
      );
      for (final e in gridFiles.entries) {
        final source = _read(e.value);
        final skip = _commentRanges(source);
        for (final m in spacing.allMatches(source)) {
          if (_inRanges(skip, m.start)) continue; // 注释里的示例不算
          final line = _lineOf(source, m.start);
          for (final raw in m.group(1)!.split(',')) {
            final v = double.tryParse(raw.trim());
            if (v == null || v == 0) continue;
            if (AppDecoSpacing.grid.contains(v)) continue;
            expect(_legacyOffGridSpacing['${e.key}:$line'], isNotNull,
                reason: '${e.key}:$line 出现越格间距 $v（4dp 网格：${AppDecoSpacing.grid}）'
                    ' —— 本轮新写的装饰必须落格；确属既有则登记进白名单并写明理由');
          }
        }
      }
      // 白名单是"逐行"的：改了行号就会失败 → 逼后来者重新核对，不会变成永久豁免
      // 2026-10-18：services 侧 5 条已失效登记清零 → 表长 16 → 11（services 0 + orders 11，见常量说明）
      expect(_legacyOffGridSpacing.length, 11, reason: '既有豁免共 11 处（services 0 + orders 11，见常量说明）');
    });

    test('圆角只取设计词汇（服务页 0/4/6/10/12/14/16/20/胶囊；订单页 0/4/6/10/14/胶囊）', () {
      /// **2026-10-18 重钉**：负责人 2026-10-18 首页重构规格要求"参考图那种大圆角（16/20）直接用"，
      /// 所以服务页的**允许集合扩到设计词汇**（仍是白名单式硬检查：出现 13/15/17 这类随手值照样红），
      /// 而订单页的集合**一个值都没加**（它没参与这次改版）。
      const designRadius = <double>[
        AppDecoRadius.none,
        AppDecoRadius.tag,
        AppDecoRadius.small,
        AppDecoRadius.control,
        12,
        AppDecoRadius.card,
        16,
        20,
        AppDecoRadius.capsule,
      ];
      final radius = RegExp(r'Border(?:Radius)?\.circular\(([\d.]+)\)');
      for (final e in files.entries) {
        final allowed = e.key == 'services_page.dart' ? designRadius : AppDecoRadius.values;
        final source = _read(e.value);
        final skip = _commentRanges(source);
        for (final m in radius.allMatches(source)) {
          if (_inRanges(skip, m.start)) continue;
          final line = _lineOf(source, m.start);
          final v = double.parse(m.group(1)!);
          if (allowed.contains(v)) continue;
          expect(_legacyOffGridRadius['${e.key}:$line'], isNotNull,
              reason: '${e.key}:$line 出现圆角 $v：只允许 $allowed；确属既有请登记并写明理由');
        }
      }
      expect(_legacyOffGridRadius.length, 0, reason: '越档圆角已清零（新首页的 16/20 已进允许集合）');
    });

    test('金色只有两个落点：页面不许直接取 T.gold / AppColors.gold（既有豁免逐行登记）', () {
      final gold = RegExp(r'(?:T|AppColors)\.gold\b');
      for (final e in files.entries) {
        final source = _read(e.value);
        final skip = _commentRanges(source);
        for (final m in gold.allMatches(source)) {
          if (_inRanges(skip, m.start)) continue;
          final line = _lineOf(source, m.start);
          expect(_legacyGoldUsage['${e.key}:$line'], isNotNull,
              reason: '${e.key}:$line 直接取金色：金额走 AppPrice/AppMoney（内部取唯一金），等级走 L-SLOT');
        }
      }
      expect(_legacyGoldUsage.length, 1, reason: '既有豁免共 1 处（订单卡金额行；官方馆评分已改判小字金 goldText）');
    });
  });
}

// ===========================================================================
// 夹具与工具
// ===========================================================================

/// 订单夹具：4 单覆盖 待接单 / 进行中 / 已完成 / 售后 四个状态档（金额一律小数、非整数）
final List<Map<String, dynamic>> _orderFixture = <Map<String, dynamic>>[
  <String, dynamic>{
    'id': '1', 'orderNo': 'ORD202610150031', 'productName': '30 保 1000w 不卡保底 · 段位上分单',
    'totalAmount': 30.0, 'status': 'in_progress', 'statusName': '进行中',
    'createdAt': '2026-10-15T01:00:00.000Z', 'quantity': 1, 'priceUnit': '局',
    'workerNickname': '青柠不加冰',
  },
  <String, dynamic>{
    'id': '2', 'orderNo': 'ORD202610140088', 'productName': '护航带打 · 战绩护航',
    'totalAmount': 115.52, 'status': 'pending_take', 'statusName': '待接单',
    'createdAt': '2026-10-14T01:00:00.000Z', 'quantity': 1, 'priceUnit': '局',
  },
  <String, dynamic>{
    'id': '3', 'orderNo': 'ORD202610120417', 'productName': '9.9 新人体验单 · 保 200w',
    'totalAmount': 9.9, 'status': 'completed', 'statusName': '已完成',
    'createdAt': '2026-10-12T01:00:00.000Z', 'quantity': 1, 'priceUnit': '局',
    'workerNickname': '黑桃老K',
  },
  <String, dynamic>{
    'id': '4', 'orderNo': 'ORD202610090156', 'productName': '娱乐陪玩 · 语音开黑',
    'totalAmount': 57.76, 'status': 'after_sale', 'statusName': '售后',
    'createdAt': '2026-10-09T01:00:00.000Z', 'quantity': 1, 'priceUnit': '小时',
  },
];

/// [calls] 非空时记录每次请求的路径（订单胶囊用例据此断言"切胶囊零请求"）
/// [orders] 覆盖 `/user/orders` 的列表；**传空表 = 页面只渲染胶囊行**（宽度用例专用）
ApiClient _api({List<String>? calls, List<Map<String, dynamic>>? orders}) => _apiFor(<String, Map<String, dynamic>>{
      '/user/orders': <String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
      '/divisions': <String, dynamic>{'code': 0, 'message': 'ok', 'data': <dynamic>[]},
    }, calls: calls, orders: orders);

/// 服务页夹具：3 个分部（两个建设中）+ 1 条商品 + 无宣传图/公告/陪玩 + 充值入口未配置
///
/// 2026-10-18 首页重构后：商品喂给「精选服务」（否则该模块整块不渲染，标题数就少一个），
/// 陪玩不给 → 「人气打手」整块不渲染（顺带证明"接口没数据就不出现"）。
ApiClient _servicesApi() => _apiFor(<String, Map<String, dynamic>>{
      '/public/products': <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'list': <dynamic>[
            <String, dynamic>{
              'id': '101', 'name': '和平精英上分单', 'price': 30, 'priceUnit': '局',
              'salesCount': 12, 'divisionId': '1', 'gameId': '35',
            },
          ],
          'total': 1, 'page': 1, 'pageSize': 50,
        },
      },
      '/divisions/grouped': <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <dynamic>[
          <String, dynamic>{
            'gameId': '35', 'gameName': '和平精英', 'platformCount': 1,
            'divisions': <dynamic>[
              <String, dynamic>{
                'id': '1', 'code': 'peace_mobile', 'gameName': '和平精英', 'platform': 'mobile',
                'platformLabel': '手游', 'name': '和平精英 · 手游', 'shortName': '和平精英',
                'onlineDesc': '平均 3 分钟内接单', 'themeColor': '#1D5FA8', 'onlineCount': 12,
              },
            ],
          },
          <String, dynamic>{
            'gameId': '36', 'gameName': '三角洲行动', 'platformCount': 2,
            'divisions': <dynamic>[
              <String, dynamic>{
                'id': '2', 'code': 'delta_mobile', 'gameName': '三角洲行动', 'platform': 'mobile',
                'platformLabel': '手游', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动',
                'onlineDesc': '平均 5 分钟内接单', 'themeColor': '#0E7C7B', 'onlineCount': 8,
                'underConstruction': true,
              },
              <String, dynamic>{
                'id': '3', 'code': 'delta_pc', 'gameName': '三角洲行动', 'platform': 'pc',
                'platformLabel': '端游', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动',
                'onlineDesc': '平均 6 分钟内接单', 'themeColor': '#3F6B8F', 'onlineCount': 4,
                'underConstruction': true,
              },
            ],
          },
        ],
      },
      '/public/clubs': <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <dynamic>[
          <String, dynamic>{
            'id': '1', 'name': '祁连山电竞 · 官方自营', 'subTitle': '官方自营',
            'description': '全段位上分与护航', 'coverMediaId': null, 'orderCount': 11, 'rating': null,
          },
        ],
      },
      '/public/site': <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'clubTitle': '关于俱乐部',
          'clubParagraphs': <String>['专注陪练与上分服务。'],
        },
      },
      '/public/banners': <String, dynamic>{'code': 0, 'message': 'ok', 'data': <dynamic>[]},
      '/public/recharge/config': <String, dynamic>{'code': 0, 'message': 'ok', 'data': null},
    });

ApiClient _apiFor(Map<String, Map<String, dynamic>> raw, {List<String>? calls, List<Map<String, dynamic>>? orders}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw, calls, orders ?? _orderFixture);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, [this.calls, List<Map<String, dynamic>>? orders]) : orders = orders ?? _orderFixture;
  final Map<String, Map<String, dynamic>> raw;

  /// 请求路径流水（`null` = 不记录）
  final List<String>? calls;

  /// `/user/orders` 下发的列表（默认 4 单夹具；胶囊宽度用例传空表 → 页面只渲染胶囊行）
  final List<Map<String, dynamic>> orders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls?.add(options.path);
    final matches = raw.keys.where(options.path.startsWith).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    final Map<String, dynamic> body = key.isEmpty
        ? <String, dynamic>{'code': 404, 'message': 'Not Found', 'data': null}
        : key == '/user/orders'
            ? <String, dynamic>{
                'code': 0,
                'message': 'ok',
                'data': <String, dynamic>{
                  'list': orders,
                  'total': orders.length,
                  'page': 1,
                  'pageSize': 50,
                },
              }
            : raw[key]!;
    return ResponseBody.fromString(jsonEncode(body), 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 加高视口：默认 800 高只构建前 3 张订单卡，逐张断言会被「离屏未构建」误伤
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 负责人给的验收宽度 **390dp**（常见国产机逻辑宽）+ 足够高 → 5 枚胶囊必须一行放得下
void _phoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 读源码（测试工作目录 = apps/boss-app；兼容从仓库根跑）
String _read(String relative) {
  final candidates = <String>[
    relative, // 从 apps/boss-app 跑
    'apps/boss-app/$relative', // 从仓库根跑
    '../$relative',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) return f.readAsStringSync();
  }
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/apps/boss-app/$relative');
    if (f.existsSync()) return f.readAsStringSync();
    dir = dir.parent;
  }
  throw StateError('找不到源码文件：$relative（cwd=${Directory.current.path}）');
}

/// 仓库根（从当前工作目录往上找，直到同时看到 `apps` 与 `docs`）
///
/// 与 `page_deco_players_profile_test.dart` 同一套探测写法：本文件既有用例按
/// "apps/boss-app 相对路径"读源码，而 ④ 组的页底渐变红线要跨到 `apps/packages/core`，
/// 只有拿到仓库根才能用一套"仓库相对路径"同时覆盖两端。
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

/// 剥注释：注释里写禁项名字不算违规（与 `packages/core/test/deco_test.dart` 同一口径）
String _stripComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// 1-based 行号
int _lineOf(String source, int offset) => '\n'.allMatches(source.substring(0, offset)).length + 1;

/// 注释区间的 [start, end) 列表 —— 注释里写示例数值不算违规
List<List<int>> _commentRanges(String source) {
  final out = <List<int>>[];
  for (final m in RegExp(r'/\*.*?\*/', dotAll: true).allMatches(source)) {
    out.add(<int>[m.start, m.end]);
  }
  for (final m in RegExp(r'//[^\n]*').allMatches(source)) {
    out.add(<int>[m.start, m.end]);
  }
  return out;
}

bool _inRanges(List<List<int>> ranges, int offset) =>
    ranges.any((r) => offset >= r[0] && offset < r[1]);

/// ===== 既有豁免白名单（逐行登记；本轮**新写**的东西一律不许进这张表）=====
///
/// 三张表都是"行号 + 理由"。为什么按行号而不是按值：后来的人若把这行挪走或改掉，
/// 对照就会失效并立刻失败 —— 逼他重新核对，白名单不会变成永久豁免。
///
/// ⚠️ 这些是 **`services_page.dart` 里早于 2026-10-15 的取值**，本轮"只加装饰、只换卡片"
/// 一处都没动；本轮新写的装饰（标尺线 / 短标 / 卡片 / 切口 / 胶囊）全部落 4dp 网格。

/// 【间距】`services_page.dart` 内 **0** 处（原 5 处已清零）+ `orders_page.dart` 内 **11** 处
///
/// **2026-10-17 行号重登（方案 G 首页重构）**：本任务按负责人定案把首页整块重写
/// （顶栏字标 + 16:9 轮播 + 三宫格 + 播报条 + 分类 Tab + 筛选胶囊 + 双列商品卡），
/// 旧的分部卡 / 半宽卡 / 欢迎语整块删除 → 旧表里那些行号**已不存在**。
///
/// **2026-10-18 services 侧清零（负责人 2026-10-17 页底渐变批次的顺手收拾）**：
/// `services_page.dart` 在 2026-10-18 首页重构后**已没有任何越格间距**（复算 `off-grid = 0`），
/// 原来那 5 条登记（1122 / 1269 / 1305 / 1315 / 1408）所指的行早已不构成匹配，
/// 属于"永久豁免"的残留 → 按本表"只许减不许加"的口径**全部删除**，表长随之 16 → **11**
/// （services 0 + orders 11）。
/// ⚠️ 删的是**已失效的登记**，不是断言：间距扫描本身一条都没放宽 ——
/// 将来 services 再出现越格间距会立刻红（那时请按行号登记，不要改这条口径）。
const Map<String, String> _legacyOffGridSpacing = <String, String>{
  // ---- orders_page.dart（订单列表 + 订单详情弹层）----
  // 注：订单**列表**本轮只换了卡片语言（通栏直角 + 发丝线），卡内间距沿用既有 10/6；
  // 订单**详情**弹层本轮按"不要动详情页"整块未改。
  //
  // **2026-10-17 行号重登（方案 G「交易链路」视觉重构）**：方案 G 只改视觉、不动逻辑，
  // 但订单详情弹层被重排为「状态时间轴 / 打手信息卡 / 费用明细 / 底部操作条」，
  // 使 orders_page.dart 的既有行号整体后移（+1 ~ +185）。按本表上方既定工作流逐条重登，
  // **取值与理由一个字没改**（10 / 6 / 96 / 80 都是原来的既有取值）。
  // 原 15 处 → 现 **11 处**：少掉的 4 处是本轮把详情弹层的分区间距归到 4dp 网格、
  // 且 `_kv` 的标签列宽改成换行书写（`SizedBox(\n width: 96,`），不再构成越格，故从表里摘除。
  //
  // **2026-10 行号二次重登（订单筛选胶囊 8 枚 → 5 枚）**：只在上方加了"胶囊分组表 + 两个本地
  // 过滤 getter"（`filterCapsules` / `_activeStatuses` / `_visibleOrders`），下面的卡片与详情弹层
  // **一行没改** → 行号整体再后移（前半段 +36、后半段 +47）。取值与理由继续一个字没改，
  // 条数仍是 **11**（本轮新写的胶囊分组结构全部落 4dp 网格，一处也没进这张表）。
  // **2026-10-17 页底渐变批次（负责人要求）**：在 `services_page.dart` 与 `orders_page.dart` 的
  // `Scaffold` 头部各插入 **2 行注释**（说明页底改由 `AppPageBg` 画）→ 两个文件的行号整体 +2。
  // 此后 `orders_page.dart` 又被「订单胶囊宽度」那一路继续改动（插入点之后的行号再 +6），
  // 所以下面 7 条按**当前文件**重新核对过一遍：
  //   402 / 447 / 512 / 710（插入点之前，不变）
  //   817(80) · 849(10) · 873(10) · 913(10) · 927(6) · 933(10) · 981(6)（插入点之后，已重登）
  // **取值与理由一个字未改**（10 / 6 / 96 / 80 都是原来的既有取值）。
  'orders_page.dart:402': '既有 10：订单详情弹层「费用明细」分区间距',
  'orders_page.dart:447': '既有 10：订单详情弹层内间距',
  'orders_page.dart:512': '既有 10：订单详情弹层内间距',
  'orders_page.dart:710': '既有 96：订单详情弹层左侧标签列宽（标签列宽，不是间距）',
  'orders_page.dart:817': '既有 80：订单空态上下留白',
  'orders_page.dart:849': '既有 10：订单卡之间的间距（本轮沿用，未改）',
  'orders_page.dart:873': '既有 10：订单卡表头底距（本轮沿用，未改）',
  'orders_page.dart:913': '既有 10：订单卡图标与商品名间距（本轮沿用，未改）',
  'orders_page.dart:927': '既有 6：订单卡内微调（本轮沿用，未改）',
  'orders_page.dart:933': '既有 10：订单卡商品名与元信息间距（本轮沿用，未改）',
  'orders_page.dart:981': '既有 6：订单卡金额与数量文案间距（本轮沿用，未改）',
};

/// 【圆角】既有 0 处越档圆角 —— 方案 G 重构把唯一那处（官方馆封面 72dp 图块圆角 12）
/// 收口到色板分档：现在用 `AppDecoRadius.control`（10），与「官方馆卡」同档。
/// 这张表**保持为空**：它曾经登记过 1 处；若将来又出现越档圆角，请重新登记并写明理由。
const Map<String, String> _legacyOffGridRadius = <String, String>{};

/// 【硬编码色值】既有 6 处 —— `order_status_tag.dart` 的**三个状态浅描边族**（amber / celadon / red）
/// 加一个"中性灰面板底"，全部定义在具名私有常量里（`_warnBorder` 等），不再是散落的裸色值。
///
/// **为什么本轮不收口（如实上报，不粉饰）**：这四个色值在 `AppColors` 里没有对应 token，
/// 且**实测无法由现有 token 推导**（`Color.lerp` 试遍全部 token 组合都差 3–100+ 个通道，
/// 最差的中性底会从 `#F0F2F5` 变成 `#E2CDBF`）—— 而 `order_status_tag_test.dart`
/// **把 `#F0F2F5` 直接写进了断言**，用户上屏颜色也会跟着变。
/// 所以本轮：① 不改色、② 不放宽断言、③ 把这 6 处逐行登记并交给主控。
/// 收口路径：在 `app_colors.dart`（共享组件，本轮禁改）补 5 个浅描边 token → 这里换名即可，**零逻辑改动**。
const Map<String, String> _legacyHardcodedColor = <String, String>{
  'order_status_tag.dart:78': '既有：待处理档描边 #E6CFAE（AppColors 无对应 token）',
  'order_status_tag.dart:81': '既有：完成档描边 #BCD9D7（同上）',
  'order_status_tag.dart:84': '既有：中性终态底 #F0F2F5（被 order_status_tag_test.dart 逐值断言）',
  'order_status_tag.dart:87': '既有：中性终态描边 #D8DEE6（同上）',
  'order_status_tag.dart:90': '既有：异常档描边 #E7C6C2（同上）',
  'order_status_tag.dart:93': '既有：售后档描边 #D8A9A3（同上）',
};

/// 【金】既有 2 处直接取金（官方馆卡的评分星与评分值）
///
/// `docs/45 §三` 写的是"金只给 ① 金额 ② 等级"。官方馆评分属**既有实现**，
/// 本轮按最小修改不动它；此处如实登记，供主控决定是否收口（要收口只改 services_page 的评分行）。
///
/// **2026-10-16 行号重登**：两处取值与理由都没变（评分星 / 评分值），行号随新增代码后移。
///
/// **2026-10 行号二次重登（订单胶囊 8 → 5）**：这条登记的是**订单卡金额行**的 `AppPrice`
/// （金额的唯一落点）；胶囊精简使全文件行号后移，指针重新落到那行 `AppPrice(` 上。
/// 金额渲染器本身**一行没改**（`balance_display_test` 的源码级绑定仍在守）。
const Map<String, String> _legacyGoldUsage = <String, String>{
  'orders_page.dart:975': '既有：订单卡金额行的 AppPrice 取金（金额落点，合规；此处为"直接取色"的既有写法）',
};

/// 【页底渐变】`LinearGradient` 的**唯一两个允许点**（负责人 2026-10-17 定案）
///
/// - `app_colors.dart`：三档 token（`bgWashTop` / `bgWashMid` / `bgWashBottom`）与既有品牌渐变的定义地
/// - `app_page_bg.dart`：`AppPageBg` —— 全站**唯一**的页底渐变消费点（`DecoratedBox` + `LinearGradient`）
///
/// 为什么只放这两处：渐变 = 页面底这一层"空气感"，一旦允许第三个文件写 `LinearGradient`，
/// 下一步就会有人把它贴到卡片/按钮/主视觉上 —— 那正是 docs/21 的头号禁项。
/// 这两个文件**必须**含有 `LinearGradient`（删了/搬走了也算红，见 ④ 组的断言）。
const Map<String, String> gradientAllowlist = <String, String>{
  'app_colors.dart': 'apps/packages/core/lib/src/theme/app_colors.dart',
  'app_page_bg.dart': 'apps/packages/core/lib/src/widgets/app_page_bg.dart',
};

/// 【页底渐变 · 既有载体】本轮之前就已经在用 `LinearGradient` 的 12 个文件（**逐条登记理由**）
///
/// 它们是"渐变只做小面积"时代的存量用法（品牌渐变 token 的消费点、骨架条渐变、
/// 头像兜底底、更新阻断页的整屏底…），**本轮一行未改**（红线：不许碰既有公共组件）。
/// 全仓扫的作用是把"新写的渐变"挡在这张表之外：表外出现即失败，表内也**只许减不许加**。
const Set<String> legacyLinearGradientCarriers = <String>{
  // 会员页：权益卡的品牌渐变底（存量）
  'apps/boss-app/lib/pages/membership_page.dart',
  // 钱包页：余额卡的品牌渐变底（存量）
  'apps/boss-app/lib/pages/wallet_page.dart',
  // 播报条：两端渐隐遮罩（存量；同时是 ShaderMask/createShader 的既有载体，不在本组扫描面内）
  'apps/boss-app/lib/widgets/announcement_ticker.dart',
  // 骨架屏：骨架条的品牌渐变扫光（存量）
  'apps/boss-app/lib/widgets/skeleton.dart',
  // 功能区色相 → 双色实底渐变的推导（存量用户：AppIconTile / AppTabGlyph）
  'apps/packages/core/lib/src/theme/feature_hues.dart',
  // 主题 token：玻璃主题的卡片高光/品牌渐变 token 定义（存量）
  'apps/packages/core/lib/src/theme/theme_colors.dart',
  // 更新阻断页：整屏品牌渐变底（存量，止于"阻断"这一张单独页面）
  'apps/packages/core/lib/src/update/update_block_page.dart',
  // 头像：无图时的品牌渐变兜底（存量；新代码已改用实色首字）
  'apps/packages/core/lib/src/widgets/app_avatar.dart',
  // Toast：顶部高光细线（存量）
  'apps/packages/core/lib/src/widgets/app_toast.dart',
  // 玻璃底：玻璃主题的渐变光斑层（存量）
  'apps/packages/core/lib/src/widgets/glass_backdrop.dart',
  // 玻璃面：卡片顶部 1px 高光（存量）
  'apps/packages/core/lib/src/widgets/glass_surface.dart',
  // 首页宣传图：底部文字遮罩渐变（存量）
  'apps/packages/core/lib/src/widgets/home_banner_carousel.dart',
};

/// 为什么不只判"上边 1dp 且无左边"：页面顶部还有别的"只有上边一条线"的容器
/// （吸顶栏之类），那种会先被命中 → 断言会对着一个不相干的容器说话。
BoxDecoration? _firstHairlineCard(WidgetTester tester) {
  for (final w in tester.widgetList<Container>(find.byType(Container))) {
    final d = w.decoration;
    if (d is! BoxDecoration) continue;
    final b = d.border;
    if (b is! Border) continue;
    final hairlineTopBottom = b.top.width == 1 && b.bottom.width == 1;
    final noSides = b.left == BorderSide.none && b.right == BorderSide.none;
    final square = d.borderRadius == BorderRadius.zero;
    if (hairlineTopBottom && noSides && square) return d;
  }
  return null;
}

/// 收集某子树里所有带阴影的 BoxDecoration（卡片阴影必须 0）
List<BoxDecoration> _shadowedDecorations(WidgetTester tester, Finder root) {
  final out = <BoxDecoration>[];
  void scan(Decoration? d) {
    if (d is BoxDecoration && (d.boxShadow?.isNotEmpty ?? false)) out.add(d);
  }

  for (final e in tester.elementList(find.descendant(of: root, matching: find.byType(Container)))) {
    scan((e.widget as Container).decoration);
  }
  for (final e in tester.elementList(find.descendant(of: root, matching: find.byType(DecoratedBox)))) {
    scan((e.widget as DecoratedBox).decoration);
  }
  return out;
}

/// 取一枚筛选胶囊（= 包着标签、且同时带描边与圆角的那层 Container）
Finder _pillFor(WidgetTester tester, String label) {
  for (final e in find.ancestor(of: find.text(label), matching: find.byType(Container)).evaluate()) {
    final d = (e.widget as Container).decoration;
    if (d is BoxDecoration && d.border is Border && d.borderRadius is BorderRadius) {
      return find.byWidget(e.widget);
    }
  }
  throw StateError('找不到筛选胶囊「$label」');
}
