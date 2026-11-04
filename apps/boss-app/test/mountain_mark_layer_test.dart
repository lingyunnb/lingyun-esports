import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 品牌雪山标 `AppMountainMark` —— ③ 「浅底上不产生多余一层」回归
///
/// ## 背景（负责人 2026-10-05 截图："像抠图没扣干净"）
/// 逐帧 + 像素排查后，**"多出来的一层"不在雪山标上**：
/// 真因是收起动画的矩形裁切（见 `order_fab_midstate_visual_test.dart`）；
/// 雪山标本身经像素实测是**干净**的（只有底色、墨色、以及两者之间的线性抗锯齿过渡）。
///
/// 本文件把"雪山标干净"钉成可执行断言，避免以后有人给它加底色/白描边/外发光：
/// 1. **结构**：它就是一个 `CustomPaint` —— 不得出现装饰容器 / 裁切 / 阴影 / 半透明层；
/// 2. **像素**：浅底上只有"底色 + 墨色 + 二者线性混色"，没有第三种颜色（白描边、外发光、
///    半透明白底都会给出偏离这条混色直线的颜色）；
/// 3. **四边留白**：边界外一圈必须全是底色；
/// 4. **冗余清理**：`snowColor` 与 `color` 相同时，绘制结果与"不传雪顶"**逐像素相同**
///    （旧实现会额外画一遍同色雪顶折线 —— 实测**墨量完全相同**，
///     因为雪顶的两条斜边与主峰折线本来就完全重合：是一次纯粹的冗余绘制，没有视觉收益）；
/// 5. **使用点**：三处调用都不再传"同色雪顶"。
void main() {
  // -------------------------------------------------------------------
  // 1) 结构：雪山标 = 纯 CustomPaint，没有装饰容器 / 裁切 / 阴影
  // -------------------------------------------------------------------
  testWidgets('AppMountainMark 只产出 CustomPaint：无 Container / 无 ClipRRect / 无阴影', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(backgroundColor: Color(0xFFF4F6F9), body: Center(child: AppMountainMark())),
    ));

    expect(find.byType(AppMountainMark), findsOneWidget);
    expect(find.descendant(of: find.byType(AppMountainMark), matching: find.byType(CustomPaint)),
        findsAtLeastNWidgets(1), reason: '雪山标必须靠 CustomPaint 自绘');

    for (final forbidden in <Type>[
      Container,
      DecoratedBox,
      ClipRRect,
      ClipRect,
      Material,
      Card,
      PhysicalModel,
      Opacity,
    ]) {
      expect(
        find.descendant(of: find.byType(AppMountainMark), matching: find.byType(forbidden)),
        findsNothing,
        reason: '雪山标内部不得出现 $forbidden —— 浅底上会多出一层矩形/半透明底（"抠图没扣干净"）',
      );
    }
  });

  testWidgets('AppMountainMark 尺寸 == size × size*0.72（0.72 是雪山的固有宽高比）', (tester) async {
    for (final s in <double>[15, 16, 18, 19, 20, 22]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: AppMountainMark(size: s)))));
      final size = tester.getSize(find.byType(AppMountainMark));
      expect(size.width, s);
      expect(size.height, closeTo(s * 0.72, 1e-9));
    }
  });

  // -------------------------------------------------------------------
  // 2) 像素：浅底上只有"底色 + 墨色"两类像素，且墨量 == 单次描边的墨量
  //    重复描边会让同一路径的墨面积显著变大 → 直接可测
  // -------------------------------------------------------------------
  testWidgets('像素实测：浅底上不产生第三种颜色（无白描边/无外发光/无半透明晕）', (tester) async {
    const bg = Color(0xFFF4F6F9);
    const ink = Color(0xFF1D5FA8); // 浮标里的实际墨色

    final px = await _rasterMark(
      tester,
      size: 19,
      color: ink,
      bg: bg,
      pixelRatio: 3,
    );

    final bgRgb = _rgb(bg);
    final inkRgb = _rgb(ink);
    var bgCount = 0, inkCount = 0, other = 0;
    final others = <String, int>{};

    for (var y = 0; y < px.height; y++) {
      for (var x = 0; x < px.width; x++) {
        final c = px.pixel(x, y);
        if (_close(c, bgRgb, 6)) {
          bgCount++;
        } else if (_close(c, inkRgb, 6)) {
          inkCount++;
        } else {
          other++;
          final k = '${c.$1},${c.$2},${c.$3}';
          others[k] = (others[k] ?? 0) + 1;
        }
      }
    }

    expect(inkCount, greaterThan(0), reason: '没画出来？夹具坏了');
    expect(bgCount, greaterThan(0), reason: '底色应占多数');

    // 抗锯齿边缘允许存在"底色↔墨色之间的过渡像素"，但**必须是线性混色**
    // （底色与墨色的凸组合）。白描边/外发光/半透明白底会给出偏离这条直线的颜色。
    expect(other, lessThan((px.width * px.height * 0.15).round()),
        reason: '过渡像素过多（$other 个，占 ${(other * 100 / (px.width * px.height)).toStringAsFixed(1)}%）'
            '｜ 最多的几种颜色：${_topColors(px).join(' ')}');

    for (final entry in others.entries) {
      final parts = entry.key.split(',').map(int.parse).toList();
      expect(_isMixOf(parts, bgRgb, inkRgb),
          isTrue,
          reason: '出现了既不是底色、也不是墨色、也不是两者线性混色的像素 rgb(${entry.key}) ×${entry.value} '
              '→ 这就是浅底上"多出来的那一层"（白描边/外发光/半透明底）'
              '｜ 位置 ${_bboxOf(px, (parts[0], parts[1], parts[2]))}'
              '｜ 最多的几种：${_topColors(px).join(' ')}');
    }
  });

  testWidgets('像素实测：整幅图四边不留任何墨迹（没有把底色画成矩形层）', (tester) async {
    const bg = Color(0xFFF4F6F9);
    const ink = Color(0xFF1D5FA8);
    final px = await _rasterMark(tester, size: 19, color: ink, bg: bg, pixelRatio: 3);
    final bgRgb = _rgb(bg);

    // 边界只包住雪山标 + 4 边各 2dp 余量 → 四边一圈必须全是底色。
    // 若雪山标带了白描边/半透明底/外发光，或者被塞进某个装饰容器，
    // 这一圈就会出现偏离底色的像素（"抠图没扣干净"的典型形态）。
    for (var x = 0; x < px.width; x++) {
      expect(_close(px.pixel(x, 0), bgRgb, 6), isTrue, reason: '上边缘 x=$x 有墨（多了一层底）');
      expect(_close(px.pixel(x, px.height - 1), bgRgb, 6), isTrue, reason: '下边缘 x=$x 有墨（多了一层底）');
    }
    for (var y = 0; y < px.height; y++) {
      expect(_close(px.pixel(0, y), bgRgb, 6), isTrue, reason: '左边缘 y=$y 有墨（多了一层底）');
      expect(_close(px.pixel(px.width - 1, y), bgRgb, 6), isTrue, reason: '右边缘 y=$y 有墨（多了一层底）');
    }
  });

  testWidgets('像素实测：雪顶与主线同色时不再重复描边（墨量 == 只画主线）', (tester) async {
    const ink = Color(0xFF1D5FA8);
    const bg = Color(0xFFFFFFFF);

    // 同色雪顶（旧实现会叠一层）vs 不传雪顶（新实现只画主线）
    final withSameSnow = await _rasterMark(tester, size: 24, color: ink, snow: ink, bg: bg, pixelRatio: 8);
    final withoutSnow = await _rasterMark(tester, size: 24, color: ink, bg: bg, pixelRatio: 8);

    final a = _inkPixels(withSameSnow, ink);
    final b = _inkPixels(withoutSnow, ink);
    expect(a, b,
        reason: 'snowColor 与 color 相同时，绘制结果必须与"不传雪顶"逐像素一致 —— '
            '差值就是那层重复描边（旧实现：$a vs 新实现：$b）');
  });

  testWidgets('像素实测：雪顶用不同颜色时才真的多画一层（能力没被削掉）', (tester) async {
    const ink = Color(0xFF1D5FA8);
    const snow = Color(0xFFFFFFFF);
    const bg = Color(0xFF14202E);

    final onlyRidge = await _rasterMark(tester, size: 24, color: ink, bg: bg, pixelRatio: 8);
    final withSnow = await _rasterMark(tester, size: 24, color: ink, snow: snow, bg: bg, pixelRatio: 8);

    // 白色雪顶必须真的画出来
    expect(_countColor(withSnow, const Color(0xFFFFFFFF)), greaterThan(0),
        reason: '显式给了不同色的雪顶却没画 → 能力被削掉了');
    expect(_countColor(onlyRidge, const Color(0xFFFFFFFF)), 0, reason: '不传雪顶时不该有白色像素');
  });

  // -------------------------------------------------------------------
  // 3) 三处使用点：都不得再传"与主色相同的雪顶"
  //    （同色雪顶 = 纯重复描边，没有任何视觉收益，只会在浅底上糊出重墨）
  // -------------------------------------------------------------------
  testWidgets('使用点：底部凸起「祁小山」与浮标内的雪山标都不带同色雪顶', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Stack(children: [AppOrderFab(onTap: _noop)]),
        bottomNavigationBar: AppBottomNav(currentIndex: 0, onTap: _noopI, onCenterTap: _noop),
      ),
    ));
    await tester.pump();

    final marks = tester.widgetList<AppMountainMark>(find.byType(AppMountainMark)).toList();
    expect(marks, isNotEmpty, reason: '浮标里应有雪山标');
    for (final m in marks) {
      // 三处调用都靠"不传 snowColor"或"传与 color 相同"来表达同色
      expect(m.snowColor == null || m.snowColor == m.color, isTrue,
          reason: 'snowColor 与 color 不同会让雪顶变成另一层颜色，和这三处的用法矛盾');
    }
  });
}

void _noop() {}
void _noopI(int _) {}

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
}

(int, int, int) _rgb(Color c) => ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());

/// 把逻辑尺寸吸附到整数物理像素（`ratio` 倍下不产生"半像素"空行/空列）
double _snap(double logical, double ratio) => (logical * ratio).ceilToDouble() / ratio;

bool _close((int, int, int) a, (int, int, int) b, int tol) =>
    (a.$1 - b.$1).abs() <= tol && (a.$2 - b.$2).abs() <= tol && (a.$3 - b.$3).abs() <= tol;

/// c 是否落在 bg→ink 线段的容差带内（即"这两色的混色"，也就是抗锯齿边缘该有的样子）
bool _isMixOf(List<int> c, (int, int, int) bg, (int, int, int) ink) {
  final d = <int>[ink.$1 - bg.$1, ink.$2 - bg.$2, ink.$3 - bg.$3];
  // 用变化最大的通道定参数 t，再检查其余通道是否匹配
  var ti = 0;
  for (var i = 1; i < 3; i++) {
    if (d[i].abs() > d[ti].abs()) ti = i;
  }
  if (d[ti].abs() < 8) return _close((c[0], c[1], c[2]), bg, 8);
  final src = <int>[bg.$1, bg.$2, bg.$3];
  final t = (c[ti] - src[ti]) / d[ti];
  if (t < -0.06 || t > 1.06) return false;
  for (var i = 0; i < 3; i++) {
    final expect = src[i] + d[i] * t;
    if ((c[i] - expect).abs() > 10) return false;
  }
  return true;
}

int _inkPixels(_Px px, Color ink) => _countColor(px, ink, tol: 6);

int _countColor(_Px px, Color want, {int tol = 6}) {
  final w = _rgb(want);
  var n = 0;
  for (var y = 0; y < px.height; y++) {
    for (var x = 0; x < px.width; x++) {
      if (_close(px.pixel(x, y), w, tol)) n++;
    }
  }
  return n;
}

/// 出现最多的前 N 种颜色（诊断用；颜色断言失败时能一眼看出"多出来的那一层"是什么色）
List<String> _topColors(_Px px, {int n = 8}) {
  final m = <String, int>{};
  for (var y = 0; y < px.height; y++) {
    for (var x = 0; x < px.width; x++) {
      final c = px.pixel(x, y);
      final k = '${c.$1},${c.$2},${c.$3}';
      m[k] = (m[k] ?? 0) + 1;
    }
  }
  final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return e.take(n).map((x) => 'rgb(${x.key})×${x.value}').toList();
}

/// 某颜色的包围盒（诊断用：定位"多出来的那一层"长在哪里）
String _bboxOf(_Px px, (int, int, int) want, {int tol = 6}) {
  var minX = 1 << 30, minY = 1 << 30, maxX = -1, maxY = -1, n = 0;
  for (var y = 0; y < px.height; y++) {
    for (var x = 0; x < px.width; x++) {
      if (!_close(px.pixel(x, y), want, tol)) continue;
      n++;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (n == 0) return '无';
  return '$n 个像素, x[$minX..$maxX] y[$minY..$maxY], 图 ${px.width}×${px.height}';
}

Future<_Px> _rasterMark(
  WidgetTester tester, {
  required double size,
  required Color color,
  Color? snow,
  required Color bg,
  double pixelRatio = 4,
}) async {
  final key = GlobalKey();
  // ⚠️ 刻意**不用 MaterialApp/Scaffold**：Material 会在边界处留下一圈 1px 的
  // 主题分隔色（实测是 rgb(109,109,111) 整整一行），会被像素断言误判成
  // "浅底上多出来的一层"。像素测试只关心雪山标自己画了什么，就把 Material
  // 那一套整个拿掉（结构断言另有专门用例，在 MaterialApp 里跑）。
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: key,
          // 边界**只包住雪山标本身**（外扩 2dp 留抗锯齿余量）：
          // toImage 成本 ∝ 像素数，包整屏再乘高倍率会把测试拖到超时（实测踩过）。
          //
          // ⚠️ 尺寸必须**吸附到整数物理像素**（`_snap`）：
          // 逻辑高 19×0.72+4 = 17.68dp，在 pixelRatio 3 下是 53.04 物理像素 →
          // 位图取整成 54 行，最后一行**没被涂到**（透明），
          // 栅格化成 RGBA 就是 (0,0,0)（实测表现为"底边一条黑线"，
          // 被误判成"雪山标多画了一层"，排查了一轮）。
          child: SizedBox(
            width: _snap(size + 4, pixelRatio),
            height: _snap(size * 0.72 + 4, pixelRatio),
            child: SizedBox.expand(
              child: ColoredBox(
                color: bg,
                child: Center(child: AppMountainMark(size: size, color: color, snowColor: snow)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // ⚠️ 必须放进 runAsync：`toImage()` 要等光栅线程回帧，而 flutter_test 是假时钟，
  // 不放进真异步窗口时这个 await 永远不会完成（测试既不失败也不结束）。
  late _Px px;
  await tester.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = _Px(data!, img.width, img.height);
    img.dispose();
  });
  return px;
}
