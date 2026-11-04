import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「快速下单」浮标 —— ② 收起/展开**中间态无残影** + 状态机幂等 回归
///
/// ## 背景（负责人 2026-10-05 录屏 + 截图）
/// 收起过程中胶囊右端出现**一条竖直方角硬边**，并从一个汉字中间把「快速下单」劈开；
/// 肉眼看就是"多了一层像抠图没扣干净的东西"。
/// **根因**：可见窗口用矩形 `ClipRect` 裁，而胶囊本身是 r=22 圆角；
/// 中间态（128 > w > 44）的切边是**直线**，且落在字形上。
///
/// ## 本文件的四层断言
/// 1. **结构**：裁切遮罩必须是 r=22 圆角裁切（矩形裁切直接失败）；
/// 2. **尺寸**：可见宽度沿收起过程**单调** 128 → 44，无过冲；
/// 3. **像素**：真光栅化，逐帧验证"胶囊右缘之外全干净、右缘内侧有墨"——
///    这是"圆角贴合"与"方角破口"的判别式（矩形裁切时右缘外必然露出白的方角）；
/// 4. **状态机**：下滚 → 立即上滚 → 再下滚，折返不越界、结论幂等。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  // -------------------------------------------------------------------
  // 1) 结构：裁切遮罩必须是圆角，且半径 == 胶囊半径
  // -------------------------------------------------------------------
  testWidgets('可见窗口用 r=22 圆角裁切，且不再有矩形裁切包住它', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Stack(children: [AppOrderFab(onTap: _noop, expanded: true)])),
    ));
    await tester.pump();

    final mask = find.byKey(AppOrderFab.clipMaskKey);
    expect(mask, findsOneWidget, reason: '可见窗口必须有独立裁切遮罩（测试靠它量半径）');

    final clip = tester.widget<ClipRRect>(mask);
    expect(clip.borderRadius, BorderRadius.circular(AppOrderFab.clipRadius));
    // 半径必须正好等于胶囊全圆半径：切边才落在胶囊自己的轮廓上
    expect(AppOrderFab.clipRadius, AppOrderFab.radius);
    expect(AppOrderFab.clipRadius, AppOrderFab.height / 2);

    // 反证：**可见窗口自己那一层**不得再用矩形裁切（tapPadding 那层 ClipRect 在
    // Align 之外，是另一个父级，不算"可见窗口的裁切"，所以这里从渲染树往上走、
    // 一旦遇到 Align 就停 —— 只检查可见窗口 ↔ Align 之间）。
    final clipRender = tester.renderObject(find.byKey(AppOrderFab.clipKey));
    RenderObject? cur = clipRender.parent;
    while (cur != null && cur is! RenderPositionedBox) {
      expect(cur, isNot(isA<RenderClipRect>()),
          reason: '可见窗口与 Align 之间出现了矩形裁切 ${cur.runtimeType}（方角破口的根因）');
      cur = cur.parent;
    }

    // 阴影必须独立成层（否则收起中途左端会完全没有投影）
    expect(find.byKey(AppOrderFab.shadowKey), findsOneWidget);
  });

  // -------------------------------------------------------------------
  // 2) 尺寸：宽度沿收起过程单调，从 128 到 44
  // -------------------------------------------------------------------
  test('visibleWidth：t=0 → 128 / t=1 → 44 / 线性', () {
    expect(AppOrderFab.visibleWidth(0), AppOrderFab.expandedWidth);
    expect(AppOrderFab.visibleWidth(1), AppOrderFab.collapsedWidth);
    expect(AppOrderFab.visibleWidth(.5), (AppOrderFab.expandedWidth + AppOrderFab.collapsedWidth) / 2);
  });

  testWidgets('收起全过程可见宽度单调递减 128 → 44，无过冲', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Stack(children: [AppOrderFab(onTap: _noop, expanded: true)])),
    ));
    await tester.pump();
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, 128);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Stack(children: [AppOrderFab(onTap: _noop, expanded: false)])),
    ));
    final step = AppOrderFab.collapseDuration ~/ 6;
    final widths = <double>[tester.getSize(find.byKey(AppOrderFab.clipKey)).width];
    for (var i = 0; i < 6; i++) {
      await tester.pump(step);
      widths.add(tester.getSize(find.byKey(AppOrderFab.clipKey)).width);
    }
    await tester.pumpAndSettle();
    widths.add(tester.getSize(find.byKey(AppOrderFab.clipKey)).width);

    for (var i = 1; i < widths.length; i++) {
      expect(widths[i], lessThanOrEqualTo(widths[i - 1] + 1e-6),
          reason: '第 $i 段宽度回抽了：$widths —— 收起过程不得变宽（视觉上就是"抽一下"）');
    }
    for (final w in widths) {
      expect(w, greaterThanOrEqualTo(AppOrderFab.collapsedWidth - 1e-6));
      expect(w, lessThanOrEqualTo(AppOrderFab.expandedWidth + 1e-6));
    }
    expect(widths.last, AppOrderFab.collapsedWidth);

    expect(
      widths.any((w) => w > AppOrderFab.collapsedWidth + 1 && w < AppOrderFab.expandedWidth - 1),
      isTrue,
      reason: '没采到中间态，本用例等于没跑（夹具问题）',
    );

    // 数值序列与渲染序列必须一致（页面/出图/测试共用 visibleWidth 这一次插值）
    for (final w in widths) {
      expect(AppOrderFab.visibleWidth(AppOrderFab.progressOf(w)), closeTo(w, 1e-6));
    }
  });

  // -------------------------------------------------------------------
  // 3) 像素层：收起过程逐帧扫描，可见窗口之外不许有墨
  // -------------------------------------------------------------------
  testWidgets('像素实测：收起全程可见窗口外侧不得露出胶囊白底（方角破口判别式）', (tester) async {
    const bg = Color(0xFFF4F6F9); // 服务页底色：白胶囊一旦方角外露立刻可测
    const scale = 2.0; // 栅格化倍率（toImage 成本 ∝ 像素数，2 足够判边界）
    const stageW = 180.0;
    const stageH = 64.0;

    final key = GlobalKey();

    Widget box(bool expanded) => MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: bg,
            body: Center(
              // 边界只包住舞台（180 × 64dp）：toImage 成本 ∝ 像素数，
              // 栅格化整屏会明显拖慢（本文件要跑 9 帧）。
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: stageW,
                  height: stageH,
                  child: Stack(children: [AppOrderFab(onTap: _noop, expanded: expanded)]),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(box(true));
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));

    // 切成收起态，逐帧栅格化
    await tester.pumpWidget(box(false));

    var checked = 0;
    for (var i = 0; i <= 8; i++) {
      // ⚠️ 必须放进 runAsync：`toImage()` 要等光栅线程回帧，而 flutter_test 是假时钟，
      // 不放进真异步窗口时这个 await 永远不会完成（表现为测试既不失败也不结束）。
      late _Px px;
      await tester.runAsync(() async {
        final ui.Image img = await boundary.toImage(pixelRatio: scale);
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        px = _Px(data!, img.width, img.height);
        img.dispose();
      });

      // ⚠️ 坐标口径：栅格化位图的原点 = 舞台 RepaintBoundary 的左上角，
      // 所以"窗口右缘在位图里的 x" = (clipKey 屏幕右缘 − 舞台屏幕左缘) × 倍率。
      // **不能**用 `stageW − right − tapPadding`：那是**胶囊视觉右缘**，
      // 只有收起动画结束（窗口宽度收到 44）时才与窗口右缘重合；
      // 中间态窗口右缘明显更靠左，用错口径会把"窗口外的空白"误判成方角破口（实测踩过）。
      final stageRect = tester.getRect(find.byKey(key));
      final clipRect = tester.getRect(find.byKey(AppOrderFab.clipKey));
      final winW = clipRect.width;
      final winRight = (clipRect.right - stageRect.left) * scale;
      final winLeft = (clipRect.left - stageRect.left) * scale;

      // ① **判别式**：可见窗口右缘那一列上，胶囊白底的**上下两端**必须被削掉（圆角贴合）。
      //
      // 这一条是"方角破口"的直接度量，也是本用例唯一能真正区分两种裁切方式的判据：
      // - 圆角裁切：切边落在胶囊轮廓上 → 窗口右缘那一列的白底是**一段圆弧**（上下收窄）；
      // - 矩形裁切：窗口右缘是一道**竖直直线** → 白底在那一列是**满高**的矩形条；
      //   （窗口宽度 < 胶囊高度 44dp 时才退化成整圆、看不出差别 —— 所以必须在
      //     中间态取样；完全收起那一帧两种实现看起来是一样的。）
      //
      // 先扫出这一列白底的纵向范围，再看它的上下两端是否比中部窄。
      // ① **判别式**：可见窗口的**左右两个边界都必须是圆弧**（= 切边沿胶囊轮廓走）。
      //
      // 为什么这条能区分两种裁切 —— 先把几何摆清楚（很容易想当然，实测踩过）：
      // 窗口是从右端往左收的，窗口**右边界**始终落在胶囊的右圆角**里面**
      // （128dp 胶囊的圆角只占最右 22dp；窗口 44→128dp 时右边界离胶囊右缘 4→88dp，
      //   x 方向越过 22dp 圆心线之后，切出来的就是圆弧而不是直线）。
      // 所以窗口右缘不会露白，**真正会露白的是窗口的上下两条边**：
      // 圆角裁切时上下边在两端沿圆弧收进去（不再横穿胶囊）；矩形裁切时上下边
      // 一直拉满整个窗口宽度 → 就在窗口的左、右两个上/下角留下**方的白角**。
      //
      // 判别式：取窗口右边界那一列，看可见白底的**纵向厚度**。
      // - 圆角裁切：这一列同时被上下两条边的圆角削掉 → 明显比窗口中部薄；
      // - 矩形裁切：上下边不被削 → 这一列的厚度与胶囊全高一致（只差胶囊右圆角）。
      // 两者在"窗口宽 == 高 == 44dp"（完全收起）那一帧才重合，所以必须在中间态取样。
      final edgeX = _rightmostFillColumn(px);
      expect(edgeX >= 0, isTrue, reason: '进度 $i/8：整幅图找不到胶囊白底 —— 夹具坏了');

      final edgeThickness = _fillThickness(px, edgeX);
      final midThickness = _fillThickness(px, (winRight.floor() + winLeft.ceil()) ~/ 2);
      expect(midThickness, greaterThan(0), reason: '进度 $i/8：窗口中部找不到胶囊白底 —— 夹具坏了');
      // 容差 2px：抗锯齿 + 0.5px 取整
      expect(edgeThickness, lessThan(midThickness - 2),
          reason: '进度 $i/8（可见宽 ${winW.toStringAsFixed(1)}dp）：窗口右缘那一列的白底厚度 '
              '$edgeThickness px ≈ 窗口中部的 $midThickness px → 切边是**竖直直线**（矩形裁切），'
              '没有沿胶囊圆角收进去，左右两个上/下角会露出方的白底（方角破口）');

      // ② 窗口右缘之外不得出现白底
      for (var x = edgeX + 1; x < px.width; x++) {
        for (var y = 0; y < px.height; y++) {
          expect(_isCapsuleFill(px, x, y), isFalse,
              reason: '进度 $i/8：窗口右缘外 x=$x y=$y 出现胶囊白底');
        }
      }
      // ③ 窗口左缘之外也不许漏白（左缘是固定锚点）
      for (var x = 0; x < winLeft.floor() - 1 && x < px.width; x++) {
        for (var y = 0; y < px.height; y++) {
          expect(_isCapsuleFill(px, x, y), isFalse,
              reason: '进度 $i/8：窗口左缘外 x=$x 出现胶囊白底（左缘是固定锚，不该漏）');
        }
      }

      // ③ 窗口左缘之外也不许漏白（左缘是固定锚点）
      for (var x = 0; x < winLeft.floor() - 1 && x < px.width; x++) {
        for (var y = 0; y < px.height; y++) {
          expect(_isCapsuleFill(px, x, y), isFalse,
              reason: '进度 $i/8：窗口左缘外 x=$x 出现胶囊白底（左缘是固定锚，不该漏）');
        }
      }
      // ④ 窗口右侧之外整体也不得有白底（含完全收起那一帧）
      for (var x = winRight.ceil() + 1; x < px.width; x++) {
        for (var y = 0; y < px.height; y++) {
          expect(_isCapsuleFill(px, x, y), isFalse,
              reason: '进度 $i/8：窗口右缘外 x=$x y=$y 出现胶囊白底');
        }
      }
      // 窗口左缘之外也不许漏（左侧是固定锚点）
      for (var x = 0; x < winLeft.floor() - 1 && x < px.width; x++) {
        for (var y = 0; y < px.height; y++) {
          expect(_isInk(px, x, y, bg), isFalse,
              reason: '进度 $i/8：窗口左缘外 x=$x 仍有内容（左缘是固定锚，不该漏）');
        }
      }
      checked++;
      await tester.pump(AppOrderFab.collapseDuration ~/ 8);
      await tester.pump(AppOrderFab.collapseDuration ~/ 8);
    }
    await tester.pumpAndSettle();
    expect(checked, 9);
  });

  // -------------------------------------------------------------------
  // 4) 状态机幂等：快速连续滚动不抖、不出现半截文字
  // -------------------------------------------------------------------
  testWidgets('服务页：下滚 → 立即上滚 → 再下滚，折返不越界且结论幂等', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures()))));
    await tester.pumpAndSettle();
    await _selectFirstDivision(tester);
    expect(_maxScrollExtent(tester), greaterThan(200), reason: '夹具要够长，否则滚不动');

    AppOrderFab fab() => tester.widget<AppOrderFab>(find.byType(AppOrderFab));
    expect(fab().expanded, isTrue);

    // ① 下滚 → 收起
    await _flingList(tester, const Offset(0, -80));
    expect(fab().expanded, isFalse, reason: '下滚应收起');

    // ② **收起动画没走完**（180ms 只推进 60ms）就立刻上滚
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width,
        greaterThan(AppOrderFab.collapsedWidth),
        reason: '此处应处于收起中间态');
    await _flingList(tester, const Offset(0, 60));
    expect(fab().expanded, isTrue, reason: '上滚应立即展开（动画半途反悔要能折返）');

    // ③ 折返过程不得越界
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      final w = tester.getSize(find.byKey(AppOrderFab.clipKey)).width;
      expect(w, lessThanOrEqualTo(AppOrderFab.expandedWidth + 1e-6), reason: '折返时宽度超过展开态（过冲）');
      expect(w, greaterThanOrEqualTo(AppOrderFab.collapsedWidth - 1e-6));
    }

    // ④ 再下滚 → 又收起：同一输入序列必须得到同一状态（幂等，不残留上次迟滞量）
    await tester.pumpAndSettle();
    await _flingList(tester, const Offset(0, -80));
    expect(fab().expanded, isFalse, reason: '再下滚仍应收起（状态机幂等）');

    // ⑤ 全程文字节点都在树上：是"被裁掉"而不是被移除 → 不会闪成半截/消失重排
    expect(find.text('快速下单'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('服务页：连续三次下滚后停手，600ms 必回展开态', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures()))));
    await tester.pumpAndSettle();
    await _selectFirstDivision(tester);

    for (var i = 0; i < 3; i++) {
      await _flingList(tester, const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.widget<AppOrderFab>(find.byType(AppOrderFab)).expanded, isFalse);

    await tester.pump(AppOrderFab.expandDelay + const Duration(milliseconds: 40));
    expect(tester.widget<AppOrderFab>(find.byType(AppOrderFab)).expanded, isTrue);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, AppOrderFab.expandedWidth);
  });
}

void _noop() {}

// ---------------------------------------------------------------------------
// 像素工具
// ---------------------------------------------------------------------------

class _Px {
  _Px(this.bytes, this.width, this.height);
  final ByteData bytes;
  final int width;
  final int height;

  (int, int, int) pixel(int x, int y) {
    final i = (y * width + x) * 4;
    return (bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
  }

  /// 该像素的 alpha（0 = 边界盒之外，栅格化后是"空"，不是黑色）
  int alpha(int x, int y) => bytes.getUint8((y * width + x) * 4 + 3);
}

/// 与底色差得够远就算"有内容"（白胶囊/描边/墨色都算）。
///
/// ⚠️ 必须先排除 alpha == 0：`RepaintBoundary` 栅格化出来的是**带透明**的位图，
/// 边界盒之外 alpha=0、RGB 也是 0 → 会被 `(0,0,0)` vs 底色判成"有内容"。
/// 实测就踩过：窗口右缘之外整片"黑"被当成方角破口，其实那只是边界盒外的空白。
bool _isInk(_Px px, int x, int y, Color bg) {
  if (px.alpha(x, y) == 0) return false;
  final c = px.pixel(x, y);
  final br = (bg.r * 255).round(), bgc = (bg.g * 255).round(), bb = (bg.b * 255).round();
  return (c.$1 - br).abs() > 8 || (c.$2 - bgc).abs() > 8 || (c.$3 - bb).abs() > 8;
}

/// 是否"胶囊白底"（不透明 + 接近纯白 #FFFFFF）
///
/// 阴影（8%~10% 黑，最深处 ≈ #EBEFF4）与底色 #F5F7FB 都会被判 false，
/// 因此它是"方正的白底有没有从裁剪窗口漏出来"的**唯一**判据。
bool _isCapsuleFill(_Px px, int x, int y) {
  if (px.alpha(x, y) < 250) return false;
  final c = px.pixel(x, y);
  return c.$1 >= 250 && c.$2 >= 250 && c.$3 >= 250;
}

/// 最右侧"有胶囊白底"的列（坐标口径与 [px] 一致）
int _rightmostFillColumn(_Px px) {
  for (var x = px.width - 1; x >= 0; x--) {
    for (var y = 0; y < px.height; y++) {
      if (_isCapsuleFill(px, x, y)) return x;
    }
  }
  return -1;
}

/// 某一列上白底的纵向厚度（px）
int _fillThickness(_Px px, int x) {
  if (x < 0 || x >= px.width) return 0;
  var n = 0;
  for (var y = 0; y < px.height; y++) {
    if (_isCapsuleFill(px, x, y)) n++;
  }
  return n;
}

// ---------------------------------------------------------------------------
// 服务页夹具（与 app_order_fab_test.dart 同款形状）
// ---------------------------------------------------------------------------

const Offset _listDragStart = Offset(195, 300);

/// **切进第一个具体分部**（首页默认停在「祁连山官方」= 聚合视图，按负责人 2026-10-18 的口径
/// **不渲染商品** → 页面撑不长，滚动触发的 FAB 状态机跑不起来）。
/// 夹具 12 条商品全部挂 `divisionId=1` → 点第一个 Tab 就能全部上屏，**条数一条没少**。
Future<void> _selectFirstDivision(WidgetTester tester) async {
  await tester.tap(find.text('和平精英').first);
  await tester.pumpAndSettle();
}

Future<void> _flingList(WidgetTester tester, Offset delta) async {
  final g = await tester.startGesture(_listDragStart);
  for (var i = 0; i < 4; i++) {
    await g.moveBy(delta / 4);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump();
}

double _maxScrollExtent(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first)
    .position
    .maxScrollExtent;

Map<String, Map<String, dynamic>> _fixtures() => {
      // 首页的"长内容"现在是商品双列列表（2026-10-18：底部官方馆整块删除）。
      // 12 条商品 → 双列 6 行 → maxScrollExtent 远超 200，滚动触发的 FAB 状态机才跑得起来。
      '/public/products': {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            for (var i = 0; i < 12; i++)
              {
                'id': 'p${i + 1}',
                'name': '和平精英上分单 ${i + 1}',
                'price': 30 + i,
                'priceUnit': '局',
                'salesCount': 120 + i,
                'divisionId': '1',
                'gameId': '35',
              },
          ],
          'total': 12,
          'page': 1,
          'pageSize': 50,
        },
      },
      '/divisions/grouped': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'gameId': '35',
            'gameName': '和平精英',
            'platformCount': 1,
            'divisions': [
              for (var i = 0; i < 6; i++)
                {
                  'id': '${i + 1}',
                  'code': 'peace_mobile_$i',
                  'gameId': '35',
                  'gameName': '和平精英',
                  'platform': 'mobile',
                  'platformLabel': '手游',
                  'name': '和平精英 · 手游 $i',
                  'shortName': '和平精英',
                  'onlineDesc': '9:00-次日 2:00',
                  'themeColor': '#2563EB',
                  'sortOrder': 10 + i,
                  'onlineCount': 9,
                },
            ],
          },
        ],
      },
      '/public/site': {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
      '/public/banners': {'code': 0, 'message': 'ok', 'data': const []},
    };

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(
        '{"code":404,"message":"Not Found","data":null}',
        404,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      jsonEncode(raw[key]!),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}
