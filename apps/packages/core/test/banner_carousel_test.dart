import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首页宣传图轮播（方案 C 顶部通栏沉浸）—— 任务② 回归测试
///
/// 覆盖四组硬要求：
/// 1. **框体**：满宽 390 × 156（2.5:1）、圆角 10、左右 0 边距
/// 2. **张数分档**：0 张 → 完全不渲染（零占位）/ 1 张 → 无指示器 / 多张 → 可滑动且指示器跟随
/// 3. **linkType 分发**：none / product / division / announcement（+ 空目标、历史值 tab 的兜底）
/// 4. **默认最保守**：自动播放关闭、不循环
void main() {
  /// 与设计稿同框：390 × 844。
  ///
  /// ⚠️ 只改 `MediaQuery.data.size` 是**不够**的：`tester.view.physicalSize` 才是渲染视口，
  /// 不改的话页面仍是默认 800 × 600 → 通栏会渲染成 800 宽，"满宽 390" 就永远断言不到。
  void sizeView(WidgetTester tester, [Size size = const Size(390, 844)]) {
    tester.view.physicalSize = Size(size.width * 3, size.height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Widget host(Widget child, {Size size = const Size(390, 844)}) => MediaQuery(
        data: MediaQueryData(size: size),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  HomeBannerItem item(String id, {String title = '', String linkType = 'none', String linkValue = ''}) =>
      HomeBannerItem(
        id: id,
        title: title,
        linkType: BannerLinkType.parse(linkType),
        linkValue: linkValue,
      );

  /// 指示器条：宽高都被 BoxConstraints 钉死的那几个 AnimatedContainer
  List<AnimatedContainer> indicators(WidgetTester tester) => tester
      .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
      .where((c) => c.constraints?.maxHeight == HomeBannerCarousel.indicatorHeight)
      .toList();

  // -------------------------------------------------------------------
  // 1) 空态：零占位
  // -------------------------------------------------------------------
  group('空态（管理端没配图）', () {
    testWidgets('0 张 -> 整块不渲染，连高度都不占', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [])));
      await tester.pump();

      // 组件本身在树上，但渲染成 0 尺寸（不显示任何占位块）
      final size = tester.getSize(find.byType(HomeBannerCarousel));
      expect(size.height, 0, reason: '零占位：不占高度');
      expect(size.width, 0, reason: '零占位：不占宽度');
      expect(find.byType(PageView), findsNothing, reason: '不应建 PageView');
      expect(find.textContaining('暂无'), findsNothing, reason: '不显示任何"暂无活动"占位文案');
      expect(tester.takeException(), isNull);
    });

    testWidgets('从空态切到有图（管理端刚发布）-> 正常渲染', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [])));
      await tester.pump();
      expect(tester.getSize(find.byType(HomeBannerCarousel)).height, 0);

      await tester.pumpWidget(host(HomeBannerCarousel(items: [item('1', title: '周末双排护航 8 折')])));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(HomeBannerCarousel)).height, HomeBannerCarousel.height);
      expect(find.text('周末双排护航 8 折'), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------
  // 2) 框体尺寸
  // -------------------------------------------------------------------
  group('框体（满宽 + 圆角）', () {
    testWidgets('1 张：满宽 390 x 高 156（约 2.5:1），左右 0 边距', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(items: [item('1', title: 'A')])));
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(HomeBannerCarousel));
      expect(rect.width, 390, reason: '通栏满宽（左右 0 边距）');
      expect(rect.left, 0);
      expect(rect.right, 390);
      expect(rect.height, 156);
      // 390 : 156 = 2.5 : 1
      expect(rect.width / rect.height, closeTo(2.5, 0.001));
      expect(HomeBannerCarousel.radius, 0, reason: '通栏直角（负责人 2026-10-14「把圆角去掉」，由 10 改为 0）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('圆角 0：通栏直角真的作用在图片上（ClipRRect 半径 0）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(items: [item('1', title: 'A')])));
      await tester.pumpAndSettle();
      final clips = tester.widgetList<ClipRRect>(find.byType(ClipRRect)).toList();
      expect(clips.any((c) => c.borderRadius == BorderRadius.circular(0)), isTrue,
          reason: '通栏图不参与卡片的圆角语言，四角必须是直角');
      // 反向断言：不得再出现任何圆角裁剪（防止有人把圆角加回来又不改测试）
      expect(clips.any((c) => c.borderRadius == BorderRadius.circular(10)), isFalse,
          reason: '负责人已明确去掉圆角');
    });
  });

  // -------------------------------------------------------------------
  // 3) 张数分档：指示器
  // -------------------------------------------------------------------
  group('指示器（照稿：图内底部居中细短条）', () {
    testWidgets('1 张 -> 不渲染指示器', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(items: [item('1', title: 'A')])));
      await tester.pumpAndSettle();
      expect(indicators(tester), isEmpty, reason: '单张没有"第几张"的信息量 -> 不显示指示器');
    });

    testWidgets('3 张 -> 指示器 3 条，居中，首条选中（宽 14），其余 6', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(items: [
        item('1', title: 'A'),
        item('2', title: 'B'),
        item('3', title: 'C'),
      ])));
      await tester.pumpAndSettle();

      final dots = indicators(tester);
      expect(dots.length, 3);
      expect(dots.first.constraints!.maxWidth, 14, reason: '首条选中 = 14 宽');
      expect(dots[1].constraints!.maxWidth, 6);

      final rects = dots.map((c) => tester.getRect(find.byWidget(c))).toList();
      // 注意：AnimatedContainer 的 margin（条间距，两侧各 2dp）会算进它的渲染矩形，
      // 所以矩形宽 = 条宽 + 2 × gap。条本身的宽度看 constraints（那才是设计稿的 14 / 6）。
      expect(rects.first.width, closeTo(HomeBannerCarousel.indicatorActiveWidth + 2 * HomeBannerCarousel.indicatorGap, 0.01));
      expect(rects.first.height, closeTo(HomeBannerCarousel.indicatorHeight, 0.01));
      expect(rects[1].width, closeTo(HomeBannerCarousel.indicatorWidth + 2 * HomeBannerCarousel.indicatorGap, 0.01));

      // 居中：整组中点约等于屏幕中点
      final left = rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
      final right = rects.map((r) => r.right).reduce((a, b) => a > b ? a : b);
      expect((left + right) / 2, closeTo(195, 1.0), reason: '通栏满宽 -> 居中是唯一不与两端对齐冲突的位置');
      // 压在图片底部：条底边距图底 10dp
      final bannerBottom = tester.getRect(find.byType(HomeBannerCarousel)).bottom;
      expect(bannerBottom - rects.first.bottom, closeTo(HomeBannerCarousel.indicatorBottom, 0.01));
    });

    testWidgets('多张：横滑可翻页，指示器跟随（选中条转移到当前页）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(items: [
        item('1', title: 'A'),
        item('2', title: 'B'),
        item('3', title: 'C'),
      ])));
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(-340, 0));
      await tester.pumpAndSettle();

      expect(find.text('B'), findsOneWidget, reason: '横滑到第 2 张');
      expect(find.text('A'), findsNothing);

      // 选中条转移到第 2 条：全组按 left 排序后，第 2 条的 left 就是选中条的 left
      final dots = indicators(tester);
      final sorted = dots.map((c) => tester.getRect(find.byWidget(c))).toList()
        ..sort((a, b) => a.left.compareTo(b.left));
      final activeDot = dots.firstWhere((c) => c.constraints!.maxWidth == HomeBannerCarousel.indicatorActiveWidth);
      expect(tester.getRect(find.byWidget(activeDot)).left, closeTo(sorted[1].left, 0.01),
          reason: '选中条 = 第 2 条（指示器跟随翻页）');
    });

    testWidgets('点击某一张时回调携带正确的 item（带 linkType/linkValue）', (tester) async {
      sizeView(tester);
      HomeBannerItem? got;
      await tester.pumpWidget(host(HomeBannerCarousel(
        items: [
          item('1', title: 'A'),
          item('2', title: 'B', linkType: 'product', linkValue: '144'),
        ],
        onTap: (b) => got = b,
      )));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(PageView), const Offset(-340, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(got?.id, '2');
      expect(got?.linkType, BannerLinkType.product);
      expect(got?.linkValue, '144');
    });
  });

  // -------------------------------------------------------------------
  // 4) linkType 分发（纯函数）
  // -------------------------------------------------------------------
  group('linkType 分发', () {
    test('none -> 无跳转', () {
      final a = BannerLinkAction.resolve(item('1', linkType: 'none', linkValue: ''));
      expect(a.isNone, isTrue);
      expect(a.type, BannerLinkType.none);
    });

    test('product -> 商品详情（带商品 id）', () {
      final a = BannerLinkAction.resolve(item('1', linkType: 'product', linkValue: '144'));
      expect(a.type, BannerLinkType.product);
      expect(a.value, '144');
      expect(a.isNone, isFalse);
    });

    test('division -> 分部（带分部 id）', () {
      final a = BannerLinkAction.resolve(item('1', linkType: 'division', linkValue: '3'));
      expect(a.type, BannerLinkType.division);
      expect(a.value, '3');
    });

    test('announcement -> 公告详情（带公告 id）', () {
      final a = BannerLinkAction.resolve(item('1', linkType: 'announcement', linkValue: '77'));
      expect(a.type, BannerLinkType.announcement);
      expect(a.value, '77');
    });

    test('url -> 外链（原样保留地址）', () {
      final a = BannerLinkAction.resolve(item('1', linkType: 'url', linkValue: 'https://example.com/a?b=1'));
      expect(a.type, BannerLinkType.url);
      expect(a.value, 'https://example.com/a?b=1');
    });

    test('选了类型但没填目标 -> 当作无跳转（不带空 id 去 push 必然 404 的页面）', () {
      expect(BannerLinkAction.resolve(item('1', linkType: 'product', linkValue: '')).isNone, isTrue);
      expect(BannerLinkAction.resolve(item('1', linkType: 'product', linkValue: '   ')).isNone, isTrue);
      expect(BannerLinkAction.resolve(item('1', linkType: 'division', linkValue: '')).isNone, isTrue);
      expect(BannerLinkAction.resolve(item('1', linkType: 'announcement', linkValue: '')).isNone, isTrue);
    });

    test('历史值 tab -> 客户端不支持，按无跳转处理（绝不猜一个 tab 出来）', () {
      final a = BannerLinkAction.resolve(item('1', linkType: 'tab', linkValue: 'orders'));
      expect(a.isNone, isTrue);
    });

    test('未知字符串 -> 解析成 none（服务端加了新类型而客户端未升级时不乱跳）', () {
      expect(BannerLinkType.parse('coupon'), BannerLinkType.none);
      expect(BannerLinkType.parse(null), BannerLinkType.none);
      expect(BannerLinkType.parse('  product  '), BannerLinkType.product, reason: '容忍首尾空白');
    });

    test('needsValue：除 none 外都需要目标值（管理端据此启停输入框）', () {
      expect(BannerLinkType.none.needsValue, isFalse);
      for (final t in [
        BannerLinkType.product,
        BannerLinkType.division,
        BannerLinkType.announcement,
        BannerLinkType.url,
      ]) {
        expect(t.needsValue, isTrue);
      }
    });
  });

  // -------------------------------------------------------------------
  // 5) 默认最保守：自动播放关闭 / 不循环
  // -------------------------------------------------------------------
  group('自动播放与循环（默认关闭）', () {
    test('默认参数：autoPlay=false、loop=false', () {
      const w = HomeBannerCarousel(items: []);
      expect(w.autoPlay, isFalse, reason: '视频无法证实自动播放体验 -> 默认关闭，后台可开');
      expect(w.loop, isFalse, reason: '不循环：最重要的那张不该被反复顶到用户面前');
    });

    testWidgets('3 张 + autoPlay=false：等 12 秒也不翻页', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(items: [
        item('1', title: 'A'),
        item('2', title: 'B'),
        item('3', title: 'C'),
      ])));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 12));
      expect(find.text('A'), findsOneWidget, reason: '默认不自动播放');
      expect(find.text('B'), findsNothing);
    });

    testWidgets('3 张 + autoPlay=true：按间隔自动前进，到末张停住（不循环）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(HomeBannerCarousel(
        items: [item('1', title: 'A'), item('2', title: 'B'), item('3', title: 'C')],
        autoPlay: true,
        autoPlayInterval: const Duration(seconds: 2),
      )));
      await tester.pumpAndSettle();

      // 间隔 2s、翻页动画 260ms：跳一步要「走完间隔 + 走完动画」
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('B'), findsOneWidget, reason: '自动前进到第 2 张');

      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('C'), findsOneWidget, reason: '自动前进到第 3 张');

      // 末张 + loop=false -> 停住不再动（再等 3 个间隔也不回第 1 张）
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('C'), findsOneWidget, reason: '到末张停住，不回到第 1 张');
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
    });
  });

  // -------------------------------------------------------------------
  // 6) 数据解析（与后端字段逐字对应）
  // -------------------------------------------------------------------
  group('HomeBannerItem.fromJson', () {
    test('完整字段', () {
      final it = HomeBannerItem.fromJson({
        'id': '9',
        'title': '周末双排护航 8 折',
        'subtitle': '10/05-10/07 全分部可用',
        'imageMediaId': '123',
        'imageUrl': '',
        'linkType': 'announcement',
        'linkValue': '5',
      });
      expect(it.id, '9');
      expect(it.title, '周末双排护航 8 折');
      expect(it.subtitle, '10/05-10/07 全分部可用');
      expect(it.hasImage, isTrue);
      expect(it.mediaUrl, contains('/media/public/123'));
      expect(it.linkType, BannerLinkType.announcement);
      expect(it.linkValue, '5');
    });

    test('imageMediaId 为 null（老数据只有 imageUrl）-> 仍算有图，走 imageUrl', () {
      final it = HomeBannerItem.fromJson({
        'id': '1',
        'title': 'A',
        'imageMediaId': null,
        'imageUrl': 'https://cdn.example.com/a.png',
        'linkType': 'none',
        'linkValue': '',
      });
      expect(it.hasImage, isTrue);
      expect(it.mediaUrl, isEmpty, reason: 'media 通道只认 imageMediaId');
      expect(it.imageUrl, 'https://cdn.example.com/a.png');
    });

    test('两个图片字段都空 -> hasImage=false（页面走兜底图标 + 文案，不白屏）', () {
      final it = HomeBannerItem.fromJson({'id': '1', 'title': 'A', 'imageMediaId': null, 'imageUrl': ''});
      expect(it.hasImage, isFalse);
    });

    test('服务端只回落差字段（缺 subtitle/linkType）-> 解析不抛异常', () {
      final it = HomeBannerItem.fromJson({'id': '1', 'title': 'A'});
      expect(it.subtitle, '');
      expect(it.linkType, BannerLinkType.none);
      expect(it.hasImage, isFalse);
    });
  });
}
