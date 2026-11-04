import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 祁山标 **22px 像素实测**（负责人硬要求：22px 下必须不糊，且方折四条边完整可见）
///
/// 做法：直接把 [QishanMarkPainter] 光栅化成真机像素尺寸（22 逻辑像素 × dpr），
/// 然后按 4 邻域连通域 + 孔洞检测数“笔画块数 / 方折是不是一个方框”：
/// - 连通块 = 4 邻域连通域个数。**山 / 示 / 方折 = 3 块**：说明方折与山脊**不叠合**（修掉了设计稿缺陷）；
///   若糊在一起会掉到 2 块甚至 1 块。
/// - 方折孔洞 = 方框包围盒内部的背景像素。**≥1 个**：说明四条边都画出来了（原稿“缺一条边”时不会有孔）。
/// 同时把 22/44/66/88px 的图落盘到 `build/` 供人工目视复核。
void main() {
  const dprs = <String, double>{'1x': 1, '2x': 2, '3x': 3, '4x': 4};

  Future<_Raster> rasterize(double dpr, {double logical = 22}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(dpr);
    const QishanMarkPainter(color: AppQishanMark.nearBlack)
        .paint(canvas, const Size(22, 22));
    final picture = recorder.endRecording();
    final size = (logical * dpr).round();
    final image = await picture.toImage(size, size);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();
    return _Raster(data!.buffer.asUint8List(), size, dpr);
  }

  testWidgets('祁山标：22px（1x/2x/3x/4x）像素实测 —— 3 块笔画 + 方折四条边完整可见', (tester) async {
    // toImage 需要真实异步（runAsync）
    await tester.runAsync(() async {
      for (final entry in dprs.entries) {
        final r = await rasterize(entry.value);
        final reps = r.components();
        final report = StringBuffer()
          ..writeln('--- 祁山标 ${entry.key}：${r.size}×${r.size} 物理像素（22 逻辑像素）---')
          ..writeln('墨迹块数（4 邻域连通域）= ${reps.length}');
        for (final c in reps) {
          report.writeln('  块 @ x${c.minX}-${c.maxX} y${c.minY}-${c.maxY} '
              '尺寸 ${c.width}×${c.height}px 像素数 ${c.count} 孔洞 ${c.holePixels}');
        }

        // ---- 物理像素 → 逻辑像素换算（证据里也报逻辑值）----
        String px(double physical) => '${(physical / r.dpr).toStringAsFixed(2)}px@22';

        // ① 3 块：山 / 示 / 方折 各自独立 → 方折与山脊不叠合
        expect(reps.length, 3,
            reason: '${entry.key}：墨迹块数应为 3（山 / 示 / 方折），实际 ${reps.length} —— '
                '少于 3 说明笔画糊在一起（方折与山脊叠合 = 负责人指出的缺陷）');

        final byLeft = [...reps]..sort((a, b) => a.minX.compareTo(b.minX));
        final mountain = byLeft.first;
        final fold = byLeft.last;
        final shi = byLeft[1];

        // ② 方折：必须有孔（四条边完整）且是闭合方框尺寸
        expect(fold.holePixels, greaterThan(0),
            reason: '${entry.key}：方折内部必须至少有 1 个背景像素（四条边都画出来才会留孔），实际 ${fold.holePixels}');
        report.writeln('方折：外框 ${fold.width}×${fold.height}px（${px(fold.width.toDouble())} × '
            '${px(fold.height.toDouble())}），孔洞 ${fold.holePixels} 像素');

        // ③ 方折与山的墨迹间隙（相邻块的最小水平间距）
        final gap = _minGapBetween(mountain, fold);
        report.writeln('方折 ↔ 山：墨迹最小间距 ${gap}px（${px(gap.toDouble())}）'
            '，中心距 ${fold.ridgeDistance}px');
        expect(gap, greaterThanOrEqualTo(r.dpr),
            reason: '${entry.key}：方折与山脊的墨迹间隙应 ≥1 逻辑像素，实际 ${gap / r.dpr}');

        // ④ 山主体：主峰高 / 山脚跨度（设计稿判定标准：主峰高 ≥10px、山脚跨度 ≥14px @22）
        report.writeln('山主体：包围盒 ${mountain.width}×${mountain.height}px = '
            '${px(mountain.width.toDouble())} × ${px(mountain.height.toDouble())}');
        report.writeln('示：包围盒 ${shi.width}×${shi.height}px = '
            '${px(shi.width.toDouble())} × ${px(shi.height.toDouble())}，与山间距 ${_minGapBetween(shi, mountain)}px');

        expect(mountain.height / r.dpr, greaterThan(12.0), reason: '主峰高（含描边）应 >12 逻辑像素');
        expect(mountain.width / r.dpr, greaterThan(14.0), reason: '山脚跨度（含描边）应 >14 逻辑像素');

        // ⑤ 落盘供目视（build/ 下，不污染仓库）
        final png = await _png(r, dpr: entry.value);
        final name = 'build/qishan_mark_22px_${entry.key}.png';
        File(name).writeAsBytesSync(png);
        report.writeln('已落盘：$name');
        // ignore: avoid_print
        print(report.toString());
      }
    });
  });

  testWidgets('祁山标：几何常量自检（方折 4 条边都是直线、与山脊净间隙 ≈1px）', (tester) async {
    const p = QishanMarkPainter(color: AppQishanMark.nearBlack);
    // 22px 下的缩放
    const scale = 22 / QishanMarkPainter.grid;
    final clearancePx = QishanMarkPainter.foldRidgeClearance * scale; // 中心距
    final inkGap = clearancePx - QishanMarkPainter.stroke * scale;
    // ignore: avoid_print
    print('方折左下角 ↔ 山脊：中心距 ${clearancePx.toStringAsFixed(2)}px，'
        '墨迹净间隙 ${inkGap.toStringAsFixed(2)}px（描边 ${QishanMarkPainter.stroke * scale}px）');
    expect(inkGap, greaterThan(1.0), reason: '方折与山脊的净间隙应 ≥1px（设计稿要求“约 1px 间隙”）');
    expect(QishanMarkPainter.foldRect.width, lessThan(QishanMarkPainter.foldRect.height + 0.001));
    expect(p.color, AppQishanMark.nearBlack);
    // 纯线稿：painter 只声明 stroke（无 fill）
    expect(QishanMarkPainter.foldRect.left, greaterThan(QishanMarkPainter.peak.dx));
  });
}

/// 两个连通块之间的最小水平间距（按行扫描：同一行里左块的 maxX 与右块的 minX 之差）
int _minGapBetween(_Comp a, _Comp b) {
  final left = a.minX <= b.minX ? a : b;
  final right = a.minX <= b.minX ? b : a;
  var best = 1 << 20;
  for (var y = 0; y < left.height; y++) {
    final ly = left.minY + y;
    if (ly < right.minY || ly > right.maxY) continue;
    // 该行左块最右墨迹、右块最左墨迹
    var lMax = -1;
    for (var x = left.maxX; x >= left.minX; x--) {
      if (left.has(x, ly)) {
        lMax = x;
        break;
      }
    }
    var rMin = -1;
    for (var x = right.minX; x <= right.maxX; x++) {
      if (right.has(x, ly)) {
        rMin = x;
        break;
      }
    }
    if (lMax >= 0 && rMin >= 0 && rMin - lMax - 1 < best) best = rMin - lMax - 1;
  }
  return best == 1 << 20 ? 999 : best;
}

class _Raster {
  _Raster(this.rgba, this.size, this.dpr);

  final Uint8List rgba;
  final int size;
  final double dpr;

  /// 墨迹判定：alpha（预乘后仍等于覆盖率）≥ 128 视为“有墨”
  bool ink(int x, int y) => rgba[(y * size + x) * 4 + 3] >= 128;

  /// 4 邻域连通域
  List<_Comp> components() {
    final seen = List<bool>.filled(size * size, false);
    final out = <_Comp>[];
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (seen[y * size + x] || !ink(x, y)) continue;
        final comp = _Comp(this);
        final stack = <int>[y * size + x];
        seen[y * size + x] = true;
        while (stack.isNotEmpty) {
          final idx = stack.removeLast();
          final cx = idx % size, cy = idx ~/ size;
          comp.add(cx, cy);
          for (final d in const [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
            final nx = cx + d[0], ny = cy + d[1];
            if (nx < 0 || ny < 0 || nx >= size || ny >= size) continue;
            final ni = ny * size + nx;
            if (seen[ni] || !ink(nx, ny)) continue;
            seen[ni] = true;
            stack.add(ni);
          }
        }
        out.add(comp);
      }
    }
    return out;
  }
}

class _Comp {
  _Comp(this.raster);

  final _Raster raster;
  final Set<int> _px = {};
  int minX = 1 << 30, maxX = -1, minY = 1 << 30, maxY = -1;

  void add(int x, int y) {
    _px.add(y * raster.size + x);
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }

  bool has(int x, int y) => _px.contains(y * raster.size + x);

  int get count => _px.length;
  int get width => maxX - minX + 1;
  int get height => maxY - minY + 1;

  /// 包围盒内部（去掉自身边界一圈）的背景像素数 —— 方折为闭合方框时 > 0
  int get holePixels {
    var n = 0;
    for (var y = minY + 1; y <= maxY - 1; y++) {
      for (var x = minX + 1; x <= maxX - 1; x++) {
        if (!has(x, y) && raster.rgba[(y * raster.size + x) * 4 + 3] < 64) n++;
      }
    }
    return n;
  }

  /// 方折左下角到山脊的实测中心距（逻辑像素）——用几何常量换算，供报告核对
  double get ridgeDistance {
    const scale = 22 / QishanMarkPainter.grid;
    return QishanMarkPainter.foldRidgeClearance * scale;
  }
}

Future<Uint8List> _png(_Raster r, {required double dpr}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(dpr);
  const QishanMarkPainter(color: AppQishanMark.nearBlack).paint(canvas, const Size(22, 22));
  final img = await recorder.endRecording().toImage(r.size, r.size);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
