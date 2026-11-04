import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fish_core/src/icons/app_icon.dart';
import 'package:fish_core/src/icons/app_icons_data.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 让 `dart:ui` 类型在本文件里可用短名（可读性）
typedef PictureRecorder = ui.PictureRecorder;
typedef ImageByteFormat = ui.ImageByteFormat;

/// 对一枚图标的**指令序列**做段级采样（每段 [per] 点），返回全部采样点。
///
/// 为什么不用 `PathMetric.getTangentForOffset`：`minus` 这类纯水平线会退化成零高矩形，
/// 引擎对退化路径的 metric 返回不可靠；而段级采样直接验证贝塞尔本身，更贴合要证明的事
/// （「A/a 圆弧确实被正确展开了」）。
List<Offset> sampleSegs(List<IcoSeg> segs, {int per = 200}) {
  final pts = <Offset>[];
  var cur = Offset.zero;
  var start = Offset.zero;
  for (final s in segs) {
    switch (s) {
      case IcoMoveTo():
        cur = Offset(s.x, s.y);
        start = cur;
        pts.add(cur);
      case IcoLineTo():
        final to = Offset(s.x, s.y);
        for (var k = 0; k <= per; k++) {
          pts.add(Offset.lerp(cur, to, k / per)!);
        }
        cur = to;
      case IcoCubicTo():
        final p0 = cur;
        final p1 = Offset(s.x1, s.y1);
        final p2 = Offset(s.x2, s.y2);
        final p3 = Offset(s.x3, s.y3);
        for (var k = 0; k <= per; k++) {
          final t = k / per;
          final mt = 1 - t;
          pts.add(p0 * (mt * mt * mt) + p1 * (3 * mt * mt * t) + p2 * (3 * mt * t * t) + p3 * (t * t * t));
        }
        cur = p3;
      case IcoQuadTo():
        final p0 = cur;
        final p1 = Offset(s.x1, s.y1);
        final p2 = Offset(s.x2, s.y2);
        for (var k = 0; k <= per; k++) {
          final t = k / per;
          final mt = 1 - t;
          pts.add(p0 * (mt * mt) + p1 * (2 * mt * t) + p2 * (t * t));
        }
        cur = p2;
      case IcoClose():
        cur = start;
    }
  }
  return pts;
}

/// 采样点的包围盒（比引擎 `getBounds()` 更可靠：退化路径也给出真实范围）
({double minX, double minY, double maxX, double maxY})? sampledBounds(List<IcoSeg> segs) {
  final pts = sampleSegs(segs, per: 400);
  if (pts.isEmpty) return null;
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final p in pts) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
}

/// 图标集几何回归（方案 F「潮玩」图标集）
///
/// 基准数据 [kAppIconData] 与 `test/data/app_icons_geometry.json` 全部由生成器
/// `scripts/tmp/gen-app-icons.mjs` 产出；本测试是**独立的第二实现**：不读生成器的中间结论，
/// 而是从 Dart 侧真正构造 `Path` 再量包围盒，逐条比对生成器的断言。
void main() {
  /// 生成器产出的几何基准（同一次生成的快照）
  final geo = jsonDecode(
    File('test/data/app_icons_geometry.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final geoIcons = (geo['icons'] as List).cast<Map<String, dynamic>>();
  final geoByName = {for (final g in geoIcons) g['name'] as String: g};

  group('图标集完整性', () {
    test('枚举条数与数据表一致，且 JSON 基准也是同一份', () {
      expect(AppIcons.values.length, greaterThanOrEqualTo(96), reason: '方案 F 要求 >=96 个图标');
      expect(kAppIconData.length, AppIcons.values.length, reason: '数据表必须与枚举一一对应');
      expect(geoIcons.length, AppIcons.values.length, reason: '几何基准必须与枚举一一对应');
      expect(geo['iconCount'], AppIcons.values.length);
    });

    test('数据表顺序与枚举 index 严格对齐（不得错位）', () {
      for (final icon in AppIcons.values) {
        expect(
          kAppIconData[icon.index].icon,
          icon,
          reason: '${icon.name} 的 index=${icon.index} 上放的是 ${kAppIconData[icon.index].icon.name}',
        );
      }
    });

    test('每个枚举值都有非空 Path，且包围盒落在 0..24', () {
      for (final icon in AppIcons.values) {
        final data = appIconDataOf(icon);

        // ① 路径非空：以「总弧长 > 0」判定。
        //    注意 `minus` 是纯水平线，`getBounds()` 会返回**空矩形**（引擎对零高路径的优化），
        //    所以空矩形不能当作「路径为空」，也不能拿它做窗口校验。
        final path = data.path;
        var totalLen = 0.0;
        for (final m in path.computeMetrics()) {
          totalLen += m.length;
        }
        expect(totalLen, greaterThan(0), reason: '${icon.name}（${data.asset}）的 Path 没有任何长度');
        expect(data.segCount, greaterThan(0), reason: '${icon.name} 没有任何绘制指令');

        // ② 包围盒窗口：Dart 侧实测包围盒 == 生成器算出的包围盒（见下一条测试），
        //    这里对非退化路径直接校验 getBounds()，退化路径（宽或高为 0）跳过（上方已验长度）。
        final b = path.getBounds();
        if (!b.isEmpty && b.width > 0 && b.height > 0) {
          const eps = 0.05; // 画布 0.2%：上游素材偶有 1e-5~3e-3 像素的控制点越界
          expect(b.left, greaterThanOrEqualTo(-eps), reason: '${icon.name} 左边界越出 viewBox：${b.left}');
          expect(b.top, greaterThanOrEqualTo(-eps), reason: '${icon.name} 上边界越出 viewBox：${b.top}');
          expect(b.right, lessThanOrEqualTo(24 + eps), reason: '${icon.name} 右边界越出 viewBox：${b.right}');
          expect(b.bottom, lessThanOrEqualTo(24 + eps), reason: '${icon.name} 下边界越出 viewBox：${b.bottom}');
        }

        // ③ 采样点也必须落在 0..24（比包围盒更严：逐点验，也能抓住包围盒被引擎放宽的情况）
        const eps2 = 0.05;
        for (final p in sampleSegs(data.segs, per: 24)) {
          expect(p.dx, inInclusiveRange(-eps2, 24 + eps2), reason: '${icon.name} 采样点 x 越界：${p.dx}');
          expect(p.dy, inInclusiveRange(-eps2, 24 + eps2), reason: '${icon.name} 采样点 y 越界：${p.dy}');
        }
      }
    });

    test('逐条：Dart 实测包围盒 == 生成器算出的包围盒', () {
      for (final icon in AppIcons.values) {
        final data = appIconDataOf(icon);
        final g = geoByName[icon.name]!;
        final gb = (g['bounds'] as Map).cast<String, dynamic>();
        final sb = sampledBounds(data.segs)!;
        // 生成器用「贝塞尔导数求极值」算精确包围盒；这里用 400 点/段的采样做**下界**验证：
        // 采样点必须落在生成器的盒子里，且贴得很近（曲线段采样误差 < 0.02）。
        expect(sb.minX, greaterThanOrEqualTo((gb['minX'] as num).toDouble() - 1e-6), reason: '${icon.name} minX 越出生成器盒子');
        expect(sb.minY, greaterThanOrEqualTo((gb['minY'] as num).toDouble() - 1e-6), reason: '${icon.name} minY 越出生成器盒子');
        expect(sb.maxX, lessThanOrEqualTo((gb['maxX'] as num).toDouble() + 1e-6), reason: '${icon.name} maxX 越出生成器盒子');
        expect(sb.maxY, lessThanOrEqualTo((gb['maxY'] as num).toDouble() + 1e-6), reason: '${icon.name} maxY 越出生成器盒子');
        // 下界必须贴紧（否则说明生成器把盒子算大了，会掩盖真实越界）
        expect(sb.maxX, closeTo((gb['maxX'] as num).toDouble(), 0.02), reason: '${icon.name} maxX 未贴紧');
        expect(sb.maxY, closeTo((gb['maxY'] as num).toDouble(), 0.02), reason: '${icon.name} maxY 未贴紧');
        expect(sb.minX, closeTo((gb['minX'] as num).toDouble(), 0.02), reason: '${icon.name} minX 未贴紧');
        expect(sb.minY, closeTo((gb['minY'] as num).toDouble(), 0.02), reason: '${icon.name} minY 未贴紧');

        // 非退化路径再与引擎 getBounds() 对照（退化路径引擎返回空矩形，跳过）。
        //
        // ⚠️ 断言口径修正（2026-10-16）：原先写的是"引擎 == 采样，容差 0.02"，**方法论上不成立** ——
        //    采样（400 点/段）永远抓不到曲线极值（极值落在两个采样点之间），所以采样值系统性地**偏内**。
        //    实测反例：`servicesActive` 引擎 top = 1.9127、采样 = 2.0021（差 0.089）。
        //    正确关系是**包含**：引擎算的是精确几何，其包围盒必然**包住全部采样点**。
        //    再补一条"不得大得离谱"的上界，防止生成器把盒子算大到掩盖真实越界。
        final b = data.path.getBounds();
        if (!b.isEmpty && b.width > 0 && b.height > 0) {
          expect(b.left, lessThanOrEqualTo(sb.minX + 1e-6), reason: '${icon.name} 引擎 left 未包住采样');
          expect(b.top, lessThanOrEqualTo(sb.minY + 1e-6), reason: '${icon.name} 引擎 top 未包住采样');
          expect(b.right, greaterThanOrEqualTo(sb.maxX - 1e-6), reason: '${icon.name} 引擎 right 未包住采样');
          expect(b.bottom, greaterThanOrEqualTo(sb.maxY - 1e-6), reason: '${icon.name} 引擎 bottom 未包住采样');
          // 上界（口径修正 2026-10-16）：**不能用小容差**。圆弧转三次贝塞尔时，控制点必然落在
          // 曲线外侧（圆内接弧的等价控制点在圆外），而引擎 `getBounds()` 会把控制点算进包围盒，
          // 因此"引擎盒子 ⊇ 真实曲线"是**数学必然**，外扩量级可达 1 个以上。
          // 实测最大值：`messages`（lu-message-circle 末尾那条 a10 10 大圆弧）外扩 **1.12**；
          // `servicesActive` 外扩 0.089。故上界取 1.5（覆盖控制点外扩，同时仍能抓住"生成器把盒子算爆"）。
          expect(b.left, closeTo(sb.minX, 1.5), reason: '${icon.name} 引擎 left 外扩异常（>1.5，疑似生成器把盒子算错）');
          expect(b.top, closeTo(sb.minY, 1.5), reason: '${icon.name} 引擎 top 外扩异常（>1.5）');
          expect(b.right, closeTo(sb.maxX, 1.5), reason: '${icon.name} 引擎 right 外扩异常（>1.5）');
          expect(b.bottom, closeTo(sb.maxY, 1.5), reason: '${icon.name} 引擎 bottom 外扩异常（>1.5）');
        }
      }
    });

    test('描边式图标的 strokeWidth 来自数据表（不是硬编码在 painter 里）', () {
      final strokeIcons =
          AppIcons.values.where((i) => appIconDataOf(i).mode == AppIconPaintMode.stroke).toList();
      final fillIcons =
          AppIcons.values.where((i) => appIconDataOf(i).mode == AppIconPaintMode.fill).toList();

      expect(strokeIcons.length, greaterThan(80), reason: 'lucide 描边式应占绝大多数');
      expect(fillIcons.length, greaterThan(0), reason: 'tabler 实心变体也要有');

      for (final icon in strokeIcons) {
        final g = geoByName[icon.name]!;
        expect(
          appIconDataOf(icon).strokeWidth,
          (g['strokeWidth'] as num).toDouble(),
          reason: '${icon.name} 的 strokeWidth 必须与素材一致',
        );
        expect(appIconDataOf(icon).strokeWidth, 2.0,
            reason: '${icon.name}（${appIconDataOf(icon).asset}）应为 2');
        expect(g['linecap'] as String, 'round', reason: '${icon.name} 必须保留圆头');
        expect(g['linejoin'] as String, 'round', reason: '${icon.name} 必须保留圆角');
      }
      for (final icon in fillIcons) {
        expect(appIconDataOf(icon).strokeWidth, 0.0, reason: '${icon.name} 是实心变体，不该有描边宽度');
      }
    });

    test('每枚图标的素材文件都存在且可回溯', () {
      for (final icon in AppIcons.values) {
        final asset = appIconDataOf(icon).asset;
        expect(asset, endsWith('.svg'), reason: '${icon.name} 的素材名应是 SVG');
        final f = File('../../site/design/color-graphics/assets/$asset');
        // 只在 monorepo 布局下（core 包位于 apps/packages/core）做实体校验
        if (f.existsSync()) {
          expect(f.lengthSync(), greaterThan(100), reason: '$asset 内容异常');
        }
      }
    });
  });

  group('圆弧几何自检（A/a 转三次贝塞尔）', () {
    test('生成器的 9 组圆弧用例全部在上界之内（1.75e-3 · r）', () {
      final check = (geo['arcSelfCheck'] as Map).cast<String, dynamic>();
      final cases = (check['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases.length, 9,
          reason: '9 组：90 度 / largeArc / 180 度 / 圆角矩形角 / 椭圆+旋转 / 大半径小弧 / 零半径 / 同点 / 半径过小');
      for (final c in cases) {
        expect(c['ok'], isTrue, reason: '${c['tag']} 超界：${c['relError']} > ${check['relativeErrorBound']}');
      }
      expect(
        (check['maxRelativeError'] as num).toDouble(),
        lessThanOrEqualTo((check['relativeErrorBound'] as num).toDouble()),
      );
      // 端点必须精确还原（生成器在半径未被放大时把段终点钉死到声明的端点）
      expect((check['endpointMaxError'] as num).toDouble(), lessThan(1e-9));
    });

    test('含圆弧的图标确实产生了曲线段（没被当成直线）', () {
      for (final icon in [AppIcons.clock, AppIcons.mine, AppIcons.refresh]) {
        final data = appIconDataOf(icon);
        expect(data.arcCount, greaterThan(0), reason: '${icon.name} 应当含圆弧');
        expect(
          data.segs.whereType<IcoCubicTo>().length,
          greaterThanOrEqualTo(4),
          reason: '${icon.name} 的圆弧应展开成多段三次贝塞尔',
        );
      }
    });

    test('lu-clock 的圆：几何等价于圆心 (12,12) 半径 10 的圆', () {
      final data = appIconDataOf(AppIcons.clock);
      final b = data.path.getBounds();
      expect(b.left, closeTo(2.0, 0.01));
      expect(b.top, closeTo(2.0, 0.01));
      expect(b.right, closeTo(22.0, 0.01));
      expect(b.bottom, closeTo(22.0, 0.01));

      // 圆由 `<circle cx=12 cy=12 r=10>` 展开：**第一段**（M + 4 段 90 度弧）上每一点
      // 到圆心的距离都应为 10（±0.01）。取前 5 条指令（1 个 M + 4 个 C）即可覆盖整个圆。
      final circleSegs = data.segs.take(5).toList();
      final pts = sampleSegs(circleSegs, per: 60);
      expect(pts.length, greaterThan(200), reason: '圆应有足够采样点');
      for (final p in pts) {
        expect((p - const Offset(12, 12)).distance, closeTo(10.0, 0.01), reason: '$p 不在圆上');
      }
    });

    test('lu-users 的圆（cx9 cy7 r4）落点正确', () {
      // users 的第 4 条指令是 `<circle cx=9 cy=7 r=4>`（M + 4 段 C + close）
      final segs = appIconDataOf(AppIcons.mine).segs;
      final circleSegs = segs.sublist(segs.length - 6);
      final pts = sampleSegs(circleSegs, per: 60);
      for (final p in pts) {
        expect((p - const Offset(9, 7)).distance, closeTo(4.0, 0.01), reason: '$p 不在 (9,7) r=4 的圆上');
      }
      // 该圆的最左点 (5,7) 必须精确出现（A 圆弧端点的还原精度）
      var found = false;
      for (final p in pts) {
        if ((p - const Offset(5, 7)).distance < 1e-6) found = true;
      }
      expect(found, isTrue, reason: '圆的最左点 (5,7) 应精确落在弧端点上');
    });

    test('实心变体与描边变体是不同的几何（不是同一份拷贝）', () {
      expect(appIconDataOf(AppIcons.star).mode, AppIconPaintMode.stroke);
      expect(appIconDataOf(AppIcons.tbStar).mode, AppIconPaintMode.fill);
      expect(appIconDataOf(AppIcons.star).asset, 'lu-star.svg');
      expect(appIconDataOf(AppIcons.tbStar).asset, 'tb-star.svg');
      expect(appIconDataOf(AppIcons.star).segs, isNot(same(appIconDataOf(AppIcons.tbStar).segs)));
    });
  });

  group('AppIcon 组件（painter 参数来自数据表）', () {
    testWidgets('渲染为 CustomPaint，颜色与尺寸由外部传入', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: AppIcon(AppIcons.search, size: 18, color: Color(0xFF123456))),
        ),
      );
      final paint = tester.widget<CustomPaint>(find.byType(CustomPaint).first);
      final painter = paint.painter! as AppIconPainter;
      expect(painter.icon, AppIcons.search);
      expect(painter.color, const Color(0xFF123456));
      expect(painter.strokeWidth, isNull, reason: '未显式覆盖时应走数据表原值');
      expect(tester.getSize(find.byType(AppIcon)), const Size(18, 18));
    });

    testWidgets('默认尺寸 20（设计稿的 19-20dp 显示档）', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: AppIcon(AppIcons.plus, color: Color(0xFF000000))),
        ),
      );
      expect(tester.getSize(find.byType(AppIcon)), const Size(20, 20));
    });

    testWidgets('strokeWidth 可显式覆盖，shouldRepaint 对每一维变化都敏感', (tester) async {
      const a = AppIconPainter(icon: AppIcons.check, color: Color(0xFF000000));
      const b = AppIconPainter(icon: AppIcons.check, color: Color(0xFF000000), strokeWidth: 1.5);
      const c = AppIconPainter(icon: AppIcons.check, color: Color(0xFFFFFFFF), strokeWidth: 1.5);
      const d = AppIconPainter(icon: AppIcons.close, color: Color(0xFFFFFFFF), strokeWidth: 1.5);
      expect(a.shouldRepaint(b), isTrue, reason: 'strokeWidth 变了要重画');
      expect(b.shouldRepaint(c), isTrue, reason: '颜色变了要重画');
      expect(c.shouldRepaint(d), isTrue, reason: '图标变了要重画');
      expect(a.shouldRepaint(const AppIconPainter(icon: AppIcons.check, color: Color(0xFF000000))), isFalse);
    });

    testWidgets('painter 真的画出墨迹（像素级，含空白反证）', (tester) async {
      Future<int> inkedOf(AppIcons? icon) async {
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 24, 24));
        canvas.drawRect(const Rect.fromLTWH(0, 0, 24, 24), Paint()..color = const Color(0xFFFFFFFF));
        if (icon != null) {
          AppIconPainter(icon: icon, color: const Color(0xFF000000)).paint(canvas, const Size(24, 24));
        }
        final image = await recorder.endRecording().toImage(24, 24);
        final d = (await image.toByteData(format: ImageByteFormat.rawRgba))!.buffer.asUint8List();
        var n = 0;
        for (var i = 0; i < d.length; i += 4) {
          if (d[i] < 200 || d[i + 1] < 200 || d[i + 2] < 200) n++;
        }
        return n;
      }

      // ⚠️【2026-10-16 卡死真因 · 必须包 runAsync】
      // `PictureRecorder.endRecording().toImage()` 与 `image.toByteData()` 是**真实异步 GPU/光栅操作**，
      // 它们依赖引擎的真实事件循环；而 `flutter test` 的同步 tester 时钟**不推进真实异步**，
      // 于是 await 永不返回 → 整个测试文件挂死（本机实测：flutter test 400 秒零输出，
      // 并残留 flutter_tester 进程占住测试锁，把同时在跑的另一路也一起拖死）。
      // 包进 `tester.runAsync` 后走真实事件循环，正常返回。
      await tester.runAsync(() async {
        expect(await inkedOf(null), 0, reason: '空白背景必须全白（反证下面的统计有效）');
        final inked = await inkedOf(AppIcons.check);
        expect(inked, greaterThan(20), reason: 'check 在 24x24 上应有可见墨迹（实际 $inked px）');
        expect(inked, lessThan(24 * 24), reason: '不该涂满整块画布');
      });
    });

    testWidgets('14 枚刁钻图标画出来都不是空白（防「解析成功但画不出」）', (tester) async {
      const samples = [
        AppIcons.search,
        AppIcons.clock,
        AppIcons.mine,
        AppIcons.refresh,
        AppIcons.shield,
        AppIcons.swords,
        AppIcons.bolt, // lu-zap：坐标省略分隔符的最刁钻素材
        AppIcons.mountainSnow,
        AppIcons.target,
        AppIcons.settings,
        AppIcons.tbStar,
        AppIcons.qr,
        AppIcons.empty,
        AppIcons.chevronDown,
      ];
      // 同前：像素读取必须走真实事件循环（见上一条的完整说明）
      await tester.runAsync(() async {
        for (final icon in samples) {
          final recorder = PictureRecorder();
          final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 48, 48));
          AppIconPainter(icon: icon, color: const Color(0xFF000000)).paint(canvas, const Size(48, 48));
          final image = await recorder.endRecording().toImage(48, 48);
          final d = (await image.toByteData(format: ImageByteFormat.rawRgba))!.buffer.asUint8List();
          var inked = 0;
          for (var i = 3; i < d.length; i += 4) {
            if (d[i] > 0) inked++;
          }
          expect(inked, greaterThan(10), reason: '${icon.name} 在 48x48 上没有画出任何像素');
        }
      });
    });
  });
}
