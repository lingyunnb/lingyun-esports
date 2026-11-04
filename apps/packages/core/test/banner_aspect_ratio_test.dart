/// **宣传图通栏框体：恒 156dp + `BoxFit.fill` 拉伸铺满**（2026-10-16 负责人**二次定案**）
///
/// ## 这份文件改过口径（本文件是"锁定当前口径"，不是新增功能）
/// - **当天第一次**（原版）：负责人「让图显示全」→ 框体改**按图片真实宽高比**定高
///   （1920×1080 → 219.375dp）+ `BoxFit.cover`；本文件当时钉的是 219.375 / 钳制区间。
/// - **当天第二次**（当前版）：负责人复核后原话「图片展示大小**还是原来的**、上传的图片**自动拉伸**，
///   现在改完之后的**太大了**」→ 框体**退回固定 156**（与最初逐字一致），
///   图片由 `cover` 改成 **`fill`（拉伸铺满 → 整张图都看得见、不裁切）**。
///   于是"按比例定高 / 钳制区间"那批用例**不是被删掉，而是被改成锁定新口径**：
///   不论图片是 1920×1080 / 9:16 / 5:1 / 缺字段 / 脏值，**框体一律 156**。
///
/// ## 本文件现在钉死的五件事
/// 1. **任何比例都是 156**：1920×1080（1.78:1）、9:16 竖图、5:1 横条、缺字段、脏值 → 全部 156；
/// 2. **字段保留、只是渲染不用**：`imageWidth/imageHeight` 仍由 `fromJson` 解析（服务端仍在返回），
///    `aspectRatio` 纯值仍可断言（脏值 → `null`）—— 这是将来回退"按比例定高"的缺件；
/// 3. **钳制区间已删除**：`minAspectRatio` / `maxAspectRatio` / `aspectRatioOf()` 不再存在
///    （框体与比例解耦后它们没有任何调用方，见 home_banner_carousel.dart）；
/// 4. **指示器与底部遮罩相对"框体底边"定位**（距底恒 10dp / 遮罩贴底 72dp）；
/// 5. **图片填充方式 = `BoxFit.fill`**，其代价（纵向压扁 ≈28.9%）用数字钉住，不只写在注释里。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 与设计稿同框：390 × 844（**必须改 `tester.view.physicalSize`**，
  /// 只改 `MediaQuery.data.size` 不会改渲染视口，见 `banner_carousel_test.dart`）
  void sizeView(WidgetTester tester, [Size size = const Size(390, 844)]) {
    tester.view.physicalSize = Size(size.width * 3, size.height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Widget host(Widget child) => MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  /// 框体高度（**唯一口径**：恒 156，与图片尺寸无关）
  const double hFrame = 156;

  /// 被本轮推翻的旧值：1920×1080 在 390 宽下按比例应是 219.375dp —— 保留它只作**对照物**
  const double hAspectRatio16x9 = 390 * 1080 / 1920; // 219.375

  double carouselHeight(WidgetTester tester) => tester.getSize(find.byType(HomeBannerCarousel)).height;

  double carouselWidth(WidgetTester tester) => tester.getSize(find.byType(HomeBannerCarousel)).width;

  // -------------------------------------------------------------------
  // ① 任何比例 → 框体恒 156（含线上 1920×1080）
  // -------------------------------------------------------------------
  group('① 任何图片比例：框体一律 156dp（不再是 219.375）', () {
    testWidgets('1920×1080（线上两条宣传图的真实尺寸）→ 框体高 156，且满宽', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '136', title: '欢迎光临祁连山电竞', imageMediaId: '292', imageWidth: 1920, imageHeight: 1080),
      ])));
      await tester.pumpAndSettle();

      expect(carouselWidth(tester), 390, reason: '通栏满宽（左右 0 边距）与高度无关');
      expect(carouselHeight(tester), hFrame, reason: '负责人二次定案：框体尺寸"还是原来的" = 156');
      expect(carouselHeight(tester), HomeBannerCarousel.height);
      expect(carouselHeight(tester), isNot(closeTo(hAspectRatio16x9, 0.01)),
          reason: '对照物：不再是"按比例定高"那版的 219.375（负责人：现在改完之后的太大了）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('框体里没有 AspectRatio（高度不再由任何比例推导）→ 恒 156', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: 'A', imageWidth: 1920, imageHeight: 1080),
      ])));
      await tester.pumpAndSettle();

      expect(find.byType(AspectRatio), findsNothing, reason: '有尺寸也走 SizedBox —— 定高路径只剩一条');
      expect(carouselHeight(tester), hFrame);
      expect(carouselWidth(tester) / carouselHeight(tester), closeTo(2.5, 0.001),
          reason: '框体固有比例 390 : 156 = 2.5 : 1（与图片的 1.78 : 1 不是一回事 → 所以 fill 会变形）');
    });

    testWidgets('9:16 竖图 → 156（不再有"693dp 吃光首屏"的风险）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: '竖图', imageWidth: 1080, imageHeight: 1920),
      ])));
      await tester.pumpAndSettle();

      expect(carouselHeight(tester), hFrame, reason: '竖图也只是被拉伸 —— 框体不为它长高');
      expect(carouselHeight(tester), lessThan(844 / 3), reason: '远小于首屏的 1/3');
      // 空口无凭：把"按比例定高"那版会得到的值摆出来做对照
      expect(390 / (1080 / 1920), closeTo(693.333, 0.01), reason: '对照物：不钳制时它会得到 693dp');
    });

    testWidgets('5:1 超扁横条 → 156（不再有"78dp 压住文案"的风险）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: '横条', imageWidth: 2500, imageHeight: 500),
      ])));
      await tester.pumpAndSettle();

      expect(carouselHeight(tester), hFrame, reason: '超扁图也只是被拉伸 —— 框体不为它压矮');
      expect(hFrame, greaterThan(HomeBannerCarousel.scrimHeight + 22 + 19 * 1.25 - 1),
          reason: '156 本来就容得下"遮罩 72 + 文案底部内边距 22 + 标题行高 23.8"≈118，无需钳制');
      expect(390 / 5, closeTo(78, 0.01), reason: '对照物：按比例定高时它会得到 78dp');
    });

    testWidgets('组里第一张没尺寸、第二张 1920×1080 → 仍是 156（框体不取决于任何一张图）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: '老数据'), // 没尺寸（历史数据）
        HomeBannerItem(id: '2', title: '新图', imageWidth: 1920, imageHeight: 1080),
      ])));
      await tester.pumpAndSettle();
      expect(carouselHeight(tester), hFrame,
          reason: '旧口径会"取第一张有尺寸的图"来定高；现在高度与整个列表的尺寸都无关');
    });
  });

  // -------------------------------------------------------------------
  // ② 缺字段 / 脏值 → 同样 156（与有尺寸时**没有区别**）
  // -------------------------------------------------------------------
  group('② 缺字段 / 脏值：依然 156（与有尺寸时毫无差别）', () {
    testWidgets('两个字段都没有 → 156（与改动前逐字一致）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: 'A', imageMediaId: '1'),
      ])));
      await tester.pumpAndSettle();
      expect(carouselHeight(tester), HomeBannerCarousel.height);
      expect(carouselHeight(tester), 156);
      expect(find.byType(AspectRatio), findsNothing);
    });

    testWidgets('服务端给 null（媒体缺失）→ 156', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: 'A', imageWidth: null, imageHeight: null),
      ])));
      await tester.pumpAndSettle();
      expect(carouselHeight(tester), 156);
    });

    testWidgets('脏值（0 / 负数 / 非数 / 只给一半）→ 156 之外的任何高度都不许出现', (tester) async {
      // 0 高是最危险的一种（算比例会得 Infinity）；负数与非数同理。
      // 现在框体不用尺寸了，脏值连"能影响布局"的机会都没有，但**字段解析口径仍要守住**：
      // 脏值必须被收敛成 null（否则将来回退"按比例定高"时会立刻踩同一个坑）。
      for (final dirty in <Map<String, dynamic>>[
        <String, dynamic>{'imageWidth': 0, 'imageHeight': 1080},
        <String, dynamic>{'imageWidth': 1920, 'imageHeight': 0},
        <String, dynamic>{'imageWidth': -1920, 'imageHeight': 1080},
        <String, dynamic>{'imageWidth': 'abc', 'imageHeight': 'def'},
        <String, dynamic>{'imageWidth': 1920}, // 只给宽
        <String, dynamic>{'imageHeight': 1080}, // 只给高
      ]) {
        final it = HomeBannerItem.fromJson(<String, dynamic>{'id': '1', 'title': 'A', ...dirty});
        expect(it.aspectRatio, isNull, reason: '脏值 $dirty 必须被收敛成"没有尺寸"');
        // 收敛口径：每个字段只能是 `null` 或**正整数**（`0` / 负数 / 非数一律归 null）；
        // "只给一半"那种脏值允许留一个字段（宽 1920 / 高 null），但**成对不可用** → 上面那条已钉住。
        expect(it.imageWidth == null || it.imageWidth! > 0, isTrue, reason: '脏值 $dirty 的宽只能是 null 或正整数');
        expect(it.imageHeight == null || it.imageHeight! > 0, isTrue, reason: '脏值 $dirty 的高只能是 null 或正整数');
        if (dirty['imageWidth'] == 1920) {
          expect(it.imageWidth, 1920, reason: '半张尺寸：能解析的那个字段照样解析出来（只是配不成比例）');
          expect(it.imageHeight, isNull);
        }

        sizeView(tester);
        await tester.pumpWidget(host(HomeBannerCarousel(items: [it])));
        await tester.pumpAndSettle();
        expect(carouselHeight(tester), 156, reason: '脏值 $dirty 下框体仍必须正好 156（不许 0 / 不许 Infinity）');
        expect(tester.takeException(), isNull);
      }
    });
  });

  // -------------------------------------------------------------------
  // ③ 字段保留、钳制删除（本轮的"字段怎么办"逐条钉死）
  // -------------------------------------------------------------------
  group('③ 尺寸字段保留（服务端仍在返回）/ 框体钳制已删除', () {
    testWidgets('fromJson 仍读 imageWidth/imageHeight（渲染不用，解析链路不许断）', (tester) async {
      final it = HomeBannerItem.fromJson(const <String, dynamic>{
        'id': '136',
        'title': '欢迎光临祁连山电竞',
        'imageMediaId': '292',
        'imageWidth': 1920,
        'imageHeight': 1080,
      });
      expect(it.imageWidth, 1920, reason: '字段保留：服务端继续返回 → 客户端继续解析（删字段会连锁改一堆测试）');
      expect(it.imageHeight, 1080);
      expect(it.aspectRatio, closeTo(1920 / 1080, 1e-9));

      // 服务端给字符串（JSON 数字被别的语言序列化成字符串）也要认
      final s = HomeBannerItem.fromJson(const <String, dynamic>{'id': '1', 'imageWidth': '1920', 'imageHeight': '1080'});
      expect(s.imageWidth, 1920);
      expect(s.imageHeight, 1080);
      expect(s.aspectRatio, closeTo(1920 / 1080, 1e-9));
    });

    test('aspectRatio 是"未钳制"的纯值：横图 / 方图 / 超扁图都原样给（钳制那层已不存在）', () {
      double? pure(int? w, int? h) => HomeBannerItem(id: '1', imageWidth: w, imageHeight: h).aspectRatio;
      expect(pure(null, null), isNull);
      expect(pure(1920, 1080), closeTo(1920 / 1080, 1e-9));
      expect(pure(1000, 1000), closeTo(1, 1e-9), reason: '方图 1:1 原样给（旧口径会在这里钳到 16:9）');
      expect(pure(9000, 1000), closeTo(9, 1e-9), reason: '9:1 原样给（旧口径会钳到 3:1）');
      expect(pure(1080, 1920), closeTo(1080 / 1920, 1e-9), reason: '竖图原样给（旧口径会钳到 16:9）');
    });

    test('几何常量本身：高度 156、圆角 0（其它几何常量不许被顺手改掉）', () {
      expect(HomeBannerCarousel.height, 156, reason: '框体恒 156（本轮核心）');
      expect(HomeBannerCarousel.radius, 0,
          reason: '圆角仍是 0（负责人 2026-10-14 定的「把圆角去掉」，本次不许动）');
      expect(HomeBannerCarousel.scrimHeight, 72);
      expect(HomeBannerCarousel.indicatorBottom, 10);
      expect(HomeBannerCarousel.indicatorHeight, 3);
      expect(HomeBannerCarousel.indicatorActiveWidth, 14);
      expect(HomeBannerCarousel.indicatorWidth, 6);
    });
  });

  // -------------------------------------------------------------------
  // ④ 指示器 / 底部遮罩：相对框体底边定位（高度恒 156，锚点不变）
  // -------------------------------------------------------------------
  group('④ 指示器与底部遮罩（相对框体底边 → 恒 156 下依旧成立）', () {
    /// 指示器条：宽高被 BoxConstraints 钉死的那几个 AnimatedContainer（与既有测试同一筛选口径）
    List<AnimatedContainer> indicators(WidgetTester tester) => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .where((c) => c.constraints?.maxHeight == HomeBannerCarousel.indicatorHeight)
        .toList();

    /// 底部遮罩：唯一带 LinearGradient 的 DecoratedBox（图本身的底是纯色/placeholerGradient）
    List<DecoratedBox> scrims(WidgetTester tester) => tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((d) => d.decoration is BoxDecoration && (d.decoration as BoxDecoration).gradient is LinearGradient)
        .toList();

    Future<void> checkAnchors(WidgetTester tester) async {
      final frame = tester.getRect(find.byType(HomeBannerCarousel));

      final dots = indicators(tester);
      expect(dots, isNotEmpty);
      for (final d in dots) {
        final r = tester.getRect(find.byWidget(d));
        expect(frame.bottom - r.bottom, closeTo(HomeBannerCarousel.indicatorBottom, 0.01),
            reason: '指示器距**框体底边**恒 10dp');
      }

      final bars = scrims(tester);
      expect(bars, isNotEmpty, reason: '有文案就有底部遮罩');
      for (final s in bars) {
        final r = tester.getRect(find.byWidget(s));
        expect(r.height, closeTo(HomeBannerCarousel.scrimHeight, 0.01));
        expect(frame.bottom - r.bottom, closeTo(0, 0.01), reason: '遮罩贴框体底边');
      }
    }

    testWidgets('无尺寸的图（156 框体）：指示器距底 10、遮罩贴底 72', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: 'A', subtitle: '副标题'),
        HomeBannerItem(id: '2', title: 'B'),
      ])));
      await tester.pumpAndSettle();
      expect(carouselHeight(tester), 156);
      await checkAnchors(tester);
    });

    testWidgets('1920×1080 的图（同样是 156 框体）：两条锚点断言依然成立', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(
            id: '136',
            title: '欢迎光临祁连山电竞',
            subtitle: '重装上线',
            imageMediaId: '292',
            imageWidth: 1920,
            imageHeight: 1080),
        HomeBannerItem(id: '137', title: '和平补偿制度', imageWidth: 1920, imageHeight: 1080),
      ])));
      await tester.pumpAndSettle();
      expect(carouselHeight(tester), hFrame, reason: '带尺寸与不带尺寸的框体**逐字相同**');
      await checkAnchors(tester);
      // 与旧口径的对照：高度差 63.375dp 是"框体变高"那版的量级，现在它必须为 0
      expect(hAspectRatio16x9 - hFrame, greaterThan(60), reason: '对照物：旧口径确实会让框体高出 63dp');
      expect(carouselHeight(tester), isNot(closeTo(hAspectRatio16x9, 0.01)));
    });

    testWidgets('超扁 5:1 的图（同样是 156 框体）：遮罩仍在框体内部（不被裁掉）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: '横条', subtitle: '副标题', imageWidth: 2500, imageHeight: 500),
        HomeBannerItem(id: '2', title: 'B', imageWidth: 2500, imageHeight: 500),
      ])));
      await tester.pumpAndSettle();
      expect(carouselHeight(tester), hFrame);
      await checkAnchors(tester);
      expect(hFrame, greaterThan(HomeBannerCarousel.scrimHeight),
          reason: '遮罩（72）必须留得下；156 天然满足 —— 这也是钳制可以被删掉的原因');
    });
  });

  // -------------------------------------------------------------------
  // ⑤ 图片填充方式 = 拉伸铺满（fill），换图不转圈开关仍打开
  // -------------------------------------------------------------------
  group('⑤ 图片：BoxFit.fill 拉伸铺满（整张图可见、不裁切）+ 换图不转圈', () {
    testWidgets('CachedNetImage 的 fit = BoxFit.fill，且 keepPreviousOnUrlChange 仍为 true', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '1', title: 'A', imageMediaId: '292', imageWidth: 1920, imageHeight: 1080),
      ])));
      await tester.pumpAndSettle();

      final imgs = tester.widgetList<CachedNetImage>(find.byType(CachedNetImage)).toList();
      expect(imgs, isNotEmpty);
      for (final img in imgs) {
        expect(img.fit, BoxFit.fill,
            reason: '负责人二次定案「上传的图片自动拉伸」：fill = 铺满整框、整张图可见（cover 会上下裁掉 ~29%）');
        expect(img.keepPreviousOnUrlChange, isTrue,
            reason: '换图（mediaId 变）时不许把已加载的图丢掉——那会露出灰块 + 转圈');
      }
    });

    test('fill 的代价（用数字说清）：1.78:1 的图塞进 2.5:1 的框 → 纵向压扁 28.9%', () {
      const frameW = 390.0;
      const frameH = hFrame;
      final scaleX = frameW / 1920; // 0.203125
      final scaleY = frameH / 1080; // 0.144444
      expect(frameW / frameH, closeTo(2.5, 1e-9), reason: '框体 390 : 156 = 2.5 : 1');
      expect(1920 / 1080, closeTo(1.7777, 1e-3), reason: '运营图 1920×1080 = 1.78 : 1');
      expect(scaleY / scaleX, closeTo(0.7111, 1e-3), reason: '纵向缩放只有横向的 71.1%');
      expect(1 - scaleY / scaleX, closeTo(0.2889, 1e-3),
          reason: '纵向被压扁 ≈28.9% —— 图上的文字（如「祁连山电竞 小云本人：3989032757」）会一起被压扁');
      expect((1920 / 1080) / (frameW / frameH), closeTo(0.7111, 1e-3),
          reason: '换个算法（比例之比）得同一个数：1.7778 / 2.5 = 0.7111');
    });

    testWidgets('fill 下图片铺满整个框体（390 × 156，无留边 → 整张图都看得见、不裁切）', (tester) async {
      sizeView(tester);
      await tester.pumpWidget(host(const HomeBannerCarousel(items: [
        HomeBannerItem(id: '136', title: '欢迎光临祁连山电竞', imageMediaId: '292', imageWidth: 1920, imageHeight: 1080),
      ])));
      await tester.pumpAndSettle();

      final imgSize = tester.getSize(find.byType(CachedNetImage).first);
      expect(imgSize.width, 390, reason: '横向铺满（fill/cover 都铺满，区别在是否变形 —— 由上面的 fit 断言钉住）');
      expect(imgSize.height, hFrame, reason: '纵向铺满：不留底色边、不裁切，整张图都在框里');
      expect(tester.takeException(), isNull);
    });
  });
}
