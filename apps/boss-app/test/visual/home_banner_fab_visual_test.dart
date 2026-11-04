import 'dart:io';
import 'dart:ui' as ui;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务①②的出图（像素证据）：
/// - `build/fab_state_1_default.png` —— 浮标 ① 默认（128 × 44 胶囊）
/// - `build/fab_state_2_pressed.png` —— 浮标 ② 按下
/// - `build/fab_state_3_collapsed.png` —— 浮标 ③ 滚动中收起（44 × 44 小圆）
/// - `build/fab_state_4_with_nav.png` —— 浮标 ④ 与底栏（含中间凸起祁小山）同屏
/// - `build/home_banner_3states.png` —— 轮播 3 状态（单张 / 多张含指示器 / 空态零占位）
///
/// 中文字形：`flutter test` 自带字体没有 CJK 字形（会渲染成豆腐块），
/// 这里按既有 `FontLoader` 写法挂系统黑体，**只为 PNG 可读**，不改 App 实际字体。
///
/// ## 关键：出图用 [AppOrderFabSkin]（皮肤本体）而不是 [AppOrderFab]
/// `AppOrderFab` 返回 `Positioned` → 只能是 `Stack` 的直接子节点、位置也写死；
/// 出图要在"舞台右下角"摆浮标，把皮肤本体放进 `Positioned` 即可（见组件内的拆分说明）。
/// 皮肤本体与生产用的是**同一份代码**，所以出图就是真实外观。
///
/// 另一个坑：`toImage` 成本与像素数成正比 —— 每页视口压到刚好装下内容、`pixelRatio` 用 2；
/// 按"整页长图"截会把测试拖到超时（实测）。
void main() {
  const cjkFamily = 'FabShotCJK';
  const pageKey = Key('shot-page');
  const bannerKey = Key('banner-shot');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjkFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  tearDown(() {
    AppOrderFab.debugPressed = false;
  });

  /// 出图。
  ///
  /// ⚠️ **必须放进 `tester.runAsync`**（这是本文件唯一"不显然"的地方，也是最容易踩的坑）：
  /// `RenderRepaintBoundary.toImage()` 内部要等 GPU/光栅线程回一帧，
  /// 而 `flutter_test` 默认是**假时钟**；不放进真异步窗口时这个 await **永远不会完成**
  /// → 测试既不失败也不结束（表现为 `flutter test` 卡住不推进，实测踩过一次）。
  /// 既有出图测试（如 `services_official_visual_test.dart`）同样是这个写法。
  Future<void> shoot(WidgetTester tester, Key key, String name) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// 一行「编号 + 标题 + 说明」标注
  Widget caption(String n, String t, String d) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF1D5FA8))),
            const SizedBox(width: 6),
            Text(t, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF14202E))),
            const SizedBox(width: 6),
            Expanded(
              child: Text(d,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9.5, color: Color(0xFF8A99AB), height: 1.35)),
            ),
          ],
        ),
      );

  /// 单状态页：标注 + 冷灰蓝舞台（浮标由 `Positioned` 摆在舞台右下角）
  Widget fabPage({
    required String n,
    required String t,
    required String d,
    required Widget skin,
    double viewH = 150,
  }) =>
      RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjkFamily, scaffoldBackgroundColor: Colors.white),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 12,
                  right: 12,
                  top: 46,
                  height: viewH - 46 - 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F6F9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE5E9F0)),
                    ),
                    child: const Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(top: 7),
                        child: Text('…… 页面内容 ……', style: TextStyle(fontSize: 10, color: Color(0xFF8A99AB))),
                      ),
                    ),
                  ),
                ),
                Positioned(left: 0, right: 0, top: 0, child: caption(n, t, d)),
                // 舞台右缘在 x=378；浮标视觉右缘落在 366（与"距屏幕右边 16dp"同档）
                Positioned(right: 24, bottom: 10 + 8, child: skin),
              ],
            ),
          ),
        ),
      );

  // =====================================================================
  // ① 浮标 4 状态（每状态一页一图，版面最简单、也最不容易踩 Positioned 的坑）
  // =====================================================================
  testWidgets('出图：浮标 ① 默认（128 × 44 胶囊）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 150 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(fabPage(
      n: '1',
      t: '默认（静止）',
      d: '128 × 44 胶囊 r22 · 白底 + 发丝线 #E2E8F0 · 阴影 0 4 14 / 8% · 雪山标 18dp + 「快速下单」13dp w700 主色 · 热区 48 × 136',
      skin: const AppOrderFabSkin(onTap: _noop),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.text('快速下单'), findsOneWidget);
    expect(tester.getSize(find.byKey(AppOrderFab.visualKey)).width, 128);
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_state_1_default.png');
  });

  testWidgets('出图：浮标 ② 按下', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 150 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(fabPage(
      n: '2',
      t: '按下',
      d: '尺寸不变 · 底 #F1F5F9 / 描边 #CBD5E1 · 阴影归零 · 缩放 0.97 · 图标与文字同步加深到 #1D4ED8',
      skin: const AppOrderFabSkin(onTap: _noop),
    ));
    await tester.pump();
    // 真实按住走的是同一个 _pressed 字段 / 同一段皮肤代码
    AppOrderFab.debugPressed = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    expect(tester.getSize(find.byKey(AppOrderFab.visualKey)).width, 128);
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_state_2_pressed.png');

    AppOrderFab.debugPressed = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
  });

  testWidgets('出图：浮标 ③ 滚动中收起（44 × 44 小圆）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 150 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(fabPage(
      n: '3',
      t: '滚动中（收起）',
      d: '只收宽度 128 → 44（右缘与底边不动）· 只留雪山标 19dp · 阴影降到 0 3 10 / 10% · 热区 ≥48dp 不变',
      skin: const AppOrderFabSkin(onTap: _noop, expanded: false),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 可见窗口的**实际渲染宽度**必须收成 44（这是"看得见多少"的唯一真相）
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, AppOrderFab.collapsedWidth,
        reason: '收起完成 → 可见窗口只剩 44dp（右缘固定，向左收）');
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).height, AppOrderFab.height,
        reason: '收起只收宽度，高度不变');
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_state_3_collapsed.png');
  });

  testWidgets('出图：浮标 ④ 与底栏（含中间凸起祁小山）同屏', (tester) async {
    const viewH = 220.0;
    tester.view.physicalSize = const Size(390 * 2, viewH * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjkFamily, scaffoldBackgroundColor: Colors.white),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 12,
                  right: 12,
                  top: 46,
                  height: viewH - 46 - 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F6F9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE5E9F0)),
                    ),
                    // 真实底栏（含中间凸起祁小山）铺在这个舞台的底部
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(
                        children: [
                          const Positioned(
                            top: 8,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Text('…… 页面内容 ……', style: TextStyle(fontSize: 10, color: Color(0xFF8A99AB))),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: AppBottomNav(currentIndex: 0, onTap: _noopI, onCenterTap: _noop),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: caption('4', '与底栏同屏',
                      '浮标底边落在凸起顶边之上、横向让开祁小山（本页版面比真机窄一档）；真机 390 × 844 下的精确净距「横向 24dp / 纵向 16dp、两矩形不相交」由 app_order_fab_test.dart 断言'),
                ),
                // 浮标皮肤本体（不是 AppOrderFab —— 那一个自带 Positioned，不能再被 Positioned 包）
                const Positioned(right: 24, bottom: 10 + 8, child: AppOrderFabSkin(onTap: _noop)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byType(AppBottomNav), findsOneWidget);
    expect(find.byType(AppOrderFabSkin), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_state_4_with_nav.png');
  });

  // =====================================================================
  // ② 轮播 3 状态
  // =====================================================================
  testWidgets('出图：首页宣传图轮播 3 状态', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 620 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    const blue = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF1D5FA8), Color(0xFF1D4ED8)],
    );
    const light = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFEDF2F8), Color(0xFFCBDDFD)],
    );

    final single = <HomeBannerItem>[
      const HomeBannerItem(
        id: '1',
        title: '周末双排护航 8 折',
        subtitle: '10/05-10/07 · 全分部可用',
        placeholderGradient: blue,
      ),
    ];
    final multi = <HomeBannerItem>[
      const HomeBannerItem(id: '1', title: '周末双排护航 8 折', subtitle: '10/05-10/07 · 全分部可用', placeholderGradient: blue),
      const HomeBannerItem(id: '2', title: '新分部开张 前 50 单送 1 小时', subtitle: '端游手游同步接单', placeholderGradient: light),
      const HomeBannerItem(id: '3', title: '官方自营 全段位上分', subtitle: '不满意可申诉', placeholderGradient: blue),
    ];

    Widget section(String n, String t, String d, Widget banner) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF1D5FA8))),
                  const SizedBox(width: 6),
                  Text(t, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF14202E))),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(d,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9.5, color: Color(0xFF8A99AB), height: 1.35)),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              // 顶部导航（照 services_page._topNav 结构：16dp 左右内距 + **0 底距**，通栏直接接上）
              DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE5E9F0))),
                child: Column(
                  children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
                      child: Row(
                        children: const [
                          Text('服务', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                          SizedBox(width: 12),
                          Text('排行榜', style: TextStyle(fontSize: 12, color: Color(0xFF4A5A6E))),
                          SizedBox(width: 12),
                          Text('公告', style: TextStyle(fontSize: 12, color: Color(0xFF4A5A6E))),
                        ],
                      ),
                    ),
                    banner,
                  ],
                ),
              ),
            ],
          ),
        );

    await tester.pumpWidget(
      RepaintBoundary(
        key: bannerKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjkFamily, scaffoldBackgroundColor: Colors.white),
          home: Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                section('1', '单张', '390 × 156（约 2.5:1）· 满宽左右 0 边距 · 通栏直角（圆角 0）· 左对齐文案 + 底部 72dp 文字遮罩 · 1 张不渲染指示器',
                    HomeBannerCarousel(items: single, onTap: _noopB)),
                section('2', '多张（3 张，第 1 张激活）', '指示器：选中 14 × 3 实色白 / 未选中 6 × 3 半透明白 · 居中、距图底 10dp · 可横滑翻页',
                    HomeBannerCarousel(items: multi, onTap: _noopB)),
                section(
                  '3',
                  '空态（管理端没配图）',
                  '零占位：整块 SizedBox.shrink()，不占高度、无灰块、无「暂无活动」—— 下方直接接「投诉 / 打赏 / 退款」',
                  Column(
                    children: [
                      const HomeBannerCarousel(items: []),
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFE3E8EF)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: const [
                            Text('投诉', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            Text('打赏', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            Text('退款', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    // 内容断言：单张与多张各一份、空态 0 尺寸、空态不建 PageView
    expect(find.text('周末双排护航 8 折'), findsNWidgets(2));
    expect(tester.getSize(find.byType(HomeBannerCarousel).at(2)).height, 0, reason: '③ 空态零占位');
    expect(find.byType(PageView), findsNWidgets(2), reason: '空态不建 PageView');
    expect(tester.takeException(), isNull);

    await shoot(tester, bannerKey, 'home_banner_3states.png');

    final out = File('build/home_banner_3states.png');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync() > 8000, isTrue, reason: 'PNG 太小说明没渲染出内容');
  });
}

void _noop() {}
void _noopI(int _) {}
void _noopB(HomeBannerItem _) {}
