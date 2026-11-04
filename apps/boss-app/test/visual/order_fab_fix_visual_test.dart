import 'dart:io';
import 'dart:ui' as ui;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「快速下单」浮标修复 —— ③ 出图（像素证据）
///
/// 产出（全部落在 `apps/boss-app/build/`，统一 `fab_fix_` 前缀）：
/// 1. `fab_fix_1_default.png`             默认：128 × 44 胶囊
/// 2. `fab_fix_2_collapsing.png`          收起中：约 86dp 宽的中间态
/// 3. `fab_fix_3_collapsed.png`           完全收起：44 × 44 圆
/// 4. `fab_fix_4_scroll_a.png`            连续滚动中·第 1 帧
/// 5. `fab_fix_5_scroll_b.png`            连续滚动中·第 2 帧
/// 6. `fab_fix_6_with_nav.png`            与底栏凸起「祁小山」同屏
/// 7. `fab_fix_7_zoom_icon.png`           **放大 3× 的图标区域特写**（证明没有多余那层）
/// 8. `fab_fix_8_snow_compare.png`        雪山标：修前（同色雪顶叠两层）vs 修后
///
/// 说明：中文字形靠 `FontLoader` 挂系统黑体（`flutter test` 自带字体没有 CJK 字形，
/// 不挂会渲染成豆腐块）；同时挂 MaterialIcons 让底栏图标正常（出图才和真机一致）。
void main() {
  const cjk = 'FabFixCJK';
  const pageKey = Key('fab-fix-page');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    // Material 图标（底栏「服务/订单/消息/我的」）
    final icons = File(
        'C:/dev/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });

  tearDown(() => AppOrderFab.debugPressed = false);

  /// 出图。
  ///
  /// ⚠️ 必须放进 `tester.runAsync`：`toImage()` 要等光栅线程回帧，
  /// 而 `flutter_test` 默认假时钟 —— 不放进去这个 await 永远不会完成
  /// （表现为 `flutter test` 卡住不推进，实测踩过）。
  Future<void> shoot(WidgetTester tester, Key key, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget caption(String n, String t, String d) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 5),
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

  /// 单状态页：标注 + 冷灰蓝舞台（浮标摆在舞台右下角，与真机同款位置关系）
  Widget fabPage({
    required String n,
    required String t,
    required String d,
    required Widget skin,
    double viewH = 170,
    double stageW = 390,
  }) =>
      RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, scaffoldBackgroundColor: Colors.white),
          home: Scaffold(
            body: SizedBox(
              width: stageW,
              child: Stack(
                children: [
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 42,
                    height: viewH - 42 - 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6F9),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFE5E9F0)),
                      ),
                      child: const Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('…… 页面内容 ……', style: TextStyle(fontSize: 10, color: Color(0xFF8A99AB))),
                        ),
                      ),
                    ),
                  ),
                  Positioned(left: 0, right: 0, top: 0, child: caption(n, t, d)),
                  // 浮标皮肤本体（AppOrderFab 自带 Positioned，不能再被 Positioned 包）
                  Positioned(right: 24, bottom: 8 + 8, child: skin),
                ],
              ),
            ),
          ),
        ),
      );

  // =====================================================================
  // 1–3：默认 / 收起中 / 完全收起
  // =====================================================================
  testWidgets('出图 1：默认（128 × 44 胶囊）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 170 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(fabPage(
      n: '1',
      t: '默认（静止）',
      d: '128 × 44 胶囊 r22 · 白底 #FFFFFF + 发丝线 #E2E8F0 · 雪山标 18dp +「快速下单」13dp w700 主色',
      skin: const AppOrderFabSkin(onTap: _noop, expanded: true),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, AppOrderFab.expandedWidth);
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_fix_1_default.png');
  });

  testWidgets('出图 2：收起中（中间态，可见宽度在 44 与 128 之间）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 170 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // 先展开，再切收起，只推进 1/3 时长 → 稳定停在中间态
    await tester.pumpWidget(fabPage(
      n: '2',
      t: '收起中（中间态）',
      d: '可见宽度 128 → 44 之间 · 切边必须沿胶囊轮廓（r22 圆角裁切）· 文字被裁掉但不得出现"竖直方角硬边 + 半截字"',
      skin: const AppOrderFabSkin(onTap: _noop, expanded: true),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(fabPage(
      n: '2',
      t: '收起中（中间态）',
      d: '可见宽度 128 → 44 之间 · 切边必须沿胶囊轮廓（r22 圆角裁切）· 文字被裁掉但不得出现"竖直方角硬边 + 半截字"',
      skin: const AppOrderFabSkin(onTap: _noop, expanded: false),
    ));
    await tester.pump(const Duration(milliseconds: 60));

    final w = tester.getSize(find.byKey(AppOrderFab.clipKey)).width;
    expect(w, greaterThan(AppOrderFab.collapsedWidth + 5));
    expect(w, lessThan(AppOrderFab.expandedWidth - 5));
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_fix_2_collapsing.png');
    await tester.pumpAndSettle();
  });

  testWidgets('出图 3：完全收起（44 × 44 圆）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 170 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(fabPage(
      n: '3',
      t: '完全收起（滚动中）',
      d: '只收宽度 128 → 44，右缘与底边不动 · 只留雪山标 19dp · 阴影降到 0 3 10 / 10% · 热区 48 × 48 不变',
      skin: const AppOrderFabSkin(onTap: _noop, expanded: false),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, AppOrderFab.collapsedWidth);
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_fix_3_collapsed.png');
  });

  // =====================================================================
  // 4–5：连续滚动中两帧（收起动画被中途要求折返）
  // =====================================================================
  for (final spec in <({int idx, int dirMs, String title})>[
    (idx: 4, dirMs: 40, title: '连续滚动中·第 1 帧（下滚收起途中）'),
    (idx: 5, dirMs: 110, title: '连续滚动中·第 2 帧（立即上滚折返途中）'),
  ]) {
    testWidgets('出图 ${spec.idx}：${spec.title}', (tester) async {
      tester.view.physicalSize = const Size(390 * 2, 170 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      Widget page(bool expanded) => fabPage(
            n: '${spec.idx}',
            t: spec.title,
            d: '下滚 → 立即上滚（180ms 动画半途反悔）· 折返过程宽度必须单调、不得越界、不得出现半截字或残影',
            skin: AppOrderFabSkin(onTap: _noop, expanded: expanded),
          );

      await tester.pumpWidget(page(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 下滚 → 收起
      await tester.pumpWidget(page(false));
      await tester.pump(const Duration(milliseconds: 40));
      if (spec.idx == 5) {
        // 动画没走完就上滚 → 折返
        await tester.pumpWidget(page(true));
      }
      await tester.pump(Duration(milliseconds: spec.dirMs));

      final w = tester.getSize(find.byKey(AppOrderFab.clipKey)).width;
      expect(w, greaterThanOrEqualTo(AppOrderFab.collapsedWidth - 1e-6));
      expect(w, lessThanOrEqualTo(AppOrderFab.expandedWidth + 1e-6));
      expect(tester.takeException(), isNull);
      await shoot(tester, pageKey, 'fab_fix_${spec.idx}_scroll_${spec.idx == 4 ? 'a' : 'b'}.png');
      await tester.pumpAndSettle();
    });
  }

  // =====================================================================
  // 6：与底栏凸起「祁小山」同屏
  // =====================================================================
  testWidgets('出图 6：与底栏凸起「祁小山」同屏', (tester) async {
    const viewH = 240.0;
    tester.view.physicalSize = const Size(390 * 2, viewH * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, scaffoldBackgroundColor: Colors.white),
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 12,
                  right: 12,
                  top: 42,
                  height: viewH - 42 - 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4F6F9),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE5E9F0)),
                    ),
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
                  child: caption('6', '与底栏同屏',
                      '浮标底边落在凸起顶边之上、横向让开「祁小山」· 真机 390 × 844 下的精确净距（横向 24dp / 纵向 16dp、两矩形不相交）由 app_order_fab_test.dart 断言'),
                ),
                const Positioned(right: 24, bottom: 8 + 8, child: AppOrderFabSkin(onTap: _noop, expanded: true)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AppBottomNav), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shoot(tester, pageKey, 'fab_fix_6_with_nav.png');
  });

  // =====================================================================
  // 7：放大 3× 的图标区域特写（证明"没有多余那一层"）
  // =====================================================================
  testWidgets('出图 7：图标区域放大 3× 特写', (tester) async {
    // 只截「浮标 + 一圈底色」，再用 pixelRatio 3 放大 → 特写
    tester.view.physicalSize = const Size(390 * 2, 90 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: const Scaffold(
            backgroundColor: Color(0xFFF4F6F9),
            body: Stack(children: [AppOrderFab(onTap: _noop, expanded: true)]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 3× 特写：像素级放大后，圆角/描边/雪山标边缘是否干净一目了然
    await shoot(tester, pageKey, 'fab_fix_7_zoom_icon.png', ratio: 3);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // 8：雪山标 —— 修前（同色雪顶叠两层）vs 修后
  // =====================================================================
  testWidgets('出图 8：雪山标修前 vs 修后（浅底放大 6×）', (tester) async {
    const bg = Color(0xFFF4F6F9);
    const ink = Color(0xFF1D5FA8);
    tester.view.physicalSize = const Size(300 * 2, 90 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    // 左边 = 修前画法（雪顶与主线同色，**额外叠一层描边**）；
    // 右 = 修后形态（不传 snowColor → 只画一条折线）。
    // 修后两者逐像素相同（见 mountain_mark_layer_test.dart 的墨量断言）。
    await tester.pumpWidget(
      RepaintBoundary(
        key: pageKey,
        child: Directionality(
          textDirection: TextDirection.ltr,
          // 这一格没有 MaterialApp，`DefaultTextStyle` 得自己给 ——
          // 否则中文会落到 flutter_test 的兜底字体上渲染成豆腐块（实测踩过）。
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: cjk, fontSize: 11, color: Color(0xFF14202E)),
            child: ColoredBox(
              color: bg,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    const _MarkCell(
                        label: '修前', sub: '雪顶同色叠一层', mark: AppMountainMark(size: 26, color: ink, snowColor: ink)),
                    const SizedBox(width: 8),
                    const _MarkCell(label: '修后', sub: '只画一条折线', mark: AppMountainMark(size: 26, color: ink)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await shoot(tester, pageKey, 'fab_fix_8_snow_compare.png', ratio: 6);
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
void _noopI(int _) {}

class _MarkCell extends StatelessWidget {
  const _MarkCell({required this.label, required this.sub, required this.mark});
  final String label;
  final String sub;
  final Widget mark;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF14202E))),
          Text(sub, style: const TextStyle(fontSize: 8.5, color: Color(0xFF4A5A6E), height: 1.3)),
        ],
      );
}
