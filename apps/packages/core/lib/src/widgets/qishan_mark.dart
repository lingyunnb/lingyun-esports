import 'package:flutter/material.dart';

/// 祁小山图标（AI 咨询入口 + 会话页头像，**纯自绘**，不新增依赖）
///
/// ## 为什么必须自绘
/// `AppIcon` 是一组 `IconData`（Material 字体图标），**拼不出「山 + 阝方折 + 示」这三组笔形**；
/// 设计稿 `site/design/ai-entry-v3.html` 也写明了实现代价：新增一个 `CustomPainter`，
/// 与 `AppMountainMark`（`app_ui.dart` 的 `_MountainPainter`）同一做法。
///
/// ## 定稿依据
/// 负责人选定 **候选 ③-2「山主体 + 阝方折」**，并明确要求修掉一处缺陷：
/// > 原设计里方折的上边与山脊叠在一起，缺了「方」的一条边。
///
/// 本实现的做法（与设计稿的差异全部集中在这里，逐条可验证）：
/// 1. **方折 = 闭合方框**：`_foldRect` 四条边各自成线、首尾相接，22px 下能数出四条边 + 一个孔洞
///    （原稿只有「山脊延长出的上边 + 右侧竖笔」两条边，读不成「方」）。
/// 2. **方折整体右上偏移，不与山脊相交**：方框左下角到山脊直线的垂直距离 = 3.31 网格单位
///    （22px 下 3.04px），减去两条描边的墨宽 1.65px → **墨迹间隙 1.39px**，
///    满足「与山脊留出约 1px 间隙」，且描边永不叠合（22px 下也不会糊成一坨）。
/// 3. **阝 = 方折 + 竖笔**：方框即方折；方框左竖边同时承担「阝」的长竖笔（下沿与示的竖笔同高）。
/// 4. **示 = 一竖 + 一小横**：小横（`_barLeft`→`_barRight`）与竖笔（`_stemTop`→`_stemBottom`）相交成「⊥」，
///    竖笔落在山脚基线上，与左右山脊各留 ≥1.4px 墨迹间隙。
/// 5. **单峰大山为主体**：山脚跨度 15.4 网格单位（22px 下 14.1px）、主峰高 14.4 单位（13.2px），
///    比旁边的方折（4.5×4.5 单位）大一个量级 —— 主体是山，不是方框。
///
/// ## 描边与配色（照设计稿硬参数）
/// - 描边 **1.8 网格单位**（24 网格画布；22px 下 = 1.65px，与旁边 22px Material outlined 图标等重）
/// - **纯线稿零填充**：没有任何 `PaintingStyle.fill`，只有 stroke
/// - 默认证色 = 近黑 `#0F172A`（压在白按钮上；主色蓝是底栏「选中态」语义色，不能用）
/// - 圆头圆角（`StrokeCap.round` / `StrokeJoin.miter` 用于方折的直角，保证「方折」是方角）
///
/// 用法：`AppQishanMark(size: 22, color: AppColors.textPrimary)`；
/// 会话页头像：`AppQishanMark(size: 15, color: AppQishanMark.avatarInk)`（`avatarBg` 圆底内）
/// —— **2026-10-16 方案 F：AI 位取紫**（原 #3A5A99/#DFE7F4 属旧蓝族）
class AppQishanMark extends StatelessWidget {
  const AppQishanMark({
    super.key,
    this.size = 22,
    this.color = AppQishanMark.nearBlack,
    this.strokeWidth = QishanMarkPainter.stroke,
  });

  /// 近黑（设计稿 `#0F172A`）—— 压在白按钮上的线稿色
  ///
  /// ⚠️ **2026-10-14 品牌升级审计**：这里是**局部一次性线稿色**，刻意保留字面量：
  /// - 换成 `AppColors.textPrimary`（`#14202E`）会把"字标线稿色"和"正文色"绑在一起，
  ///   正文色以后按可读性调一次，雪山标就跟着变一次（线稿色属于图形语言，不属文本层级）；
  /// - 它**不做大面积填色**，也不参与"品牌主色"（主色是 `AppColors.primary`）。
  static const Color nearBlack = Color(0xFF0F172A);

  /// 会话页头像用的低饱和同色系线色
  ///
  /// **2026-10-16 方案 F：AI 位一律取紫** —— `#6D28D9`（F 稿紫深档）而非 `accentAi` `#8B5CF6`：
  /// 线稿压在 [avatarBg] 浅紫底上要能看清，实测对比度 **6.48:1**（≥ WCAG AA 4.5:1），
  /// 而 `#8B5CF6` 只有 3.86:1。**只改颜色，笔画与坐标一个字没动。**
  static const Color avatarInk = Color(0xFF6D28D9);

  /// 会话页头像底色（F 紫浅底，与 [AppColors.accentAiSoft] 同值）
  ///
  /// **2026-10-16 方案 F**：原 `#DFE7F4` 是旧蓝族浅底，与"AI=紫"不一致。
  static const Color avatarBg = Color(0xFFF5F3FF);

  final double size;
  final Color color;

  /// 描边宽度（网格单位；默认 1.8）
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: QishanMarkPainter(color: color, strokeWidth: strokeWidth)),
      );
}

/// 祁山标绘制器：24 网格 → 任意尺寸等比缩放（布局全部用网格单位，改尺寸不改形）
///
/// 公开是为了让测试能直接光栅化它做像素实测（连通块 / 方折孔洞 / 关键几何）。
class QishanMarkPainter extends CustomPainter {
  const QishanMarkPainter({required this.color, this.strokeWidth = stroke});

  /// 设计稿网格（Material Symbols 同规格：24 画布 / 20 活动区）
  static const double grid = 24;

  /// 描边宽度（网格单位，设计稿 1.8）
  static const double stroke = 1.8;

  // ---------------------------------------------------------------------
  // 关键几何（全部网格单位；画布左上角为原点）
  // ---------------------------------------------------------------------

  /// 山：左山脚（基线 y=19.0）
  static const Offset footLeft = Offset(2.7, 19.0);

  /// 山：主峰（略偏左 → 山体不对称，不是等腰三角形；同时把右上角让给方折）
  static const Offset peak = Offset(10.4, 4.2);

  /// 山：右山脚（基线 y=19.0）
  static const Offset footRight = Offset(18.7, 19.0);

  /// 示：小横（左端 → 右端），y 与竖笔同高
  static const Offset barLeft = Offset(9.1, 14.5);
  static const Offset barRight = Offset(12.3, 14.5);

  /// 示：竖笔（上端接小横，下端落在山脚基线）
  static const Offset stemTop = Offset(10.7, 14.5);
  static const Offset stemBottom = Offset(10.7, 19.0);

  /// 阝：方折（**闭合方框，四条边完整可见**；整体右上偏移，与山脊留 1px 墨迹间隙）
  static const Rect foldRect = Rect.fromLTRB(15.9, 2.1, 20.4, 6.6);

  /// 方框左下角到山脊直线的垂直距离（网格单位）—— 22px 下 3.04px，减两条描边墨宽 1.65px = 1.39px 净间隙
  static double get foldRidgeClearance {
    final d = Offset(footRight.dx - peak.dx, footRight.dy - peak.dy);
    final a2b = Offset(foldRect.left - peak.dx, foldRect.bottom - peak.dy);
    final cross = (a2b.dx * d.dy - a2b.dy * d.dx).abs();
    return cross / d.distance;
  }

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // 等比缩放到目标尺寸（正方形；非正方形时按短边，保证不变形）
    final scale = size.shortestSide / grid;
    canvas.save();
    canvas.translate((size.width - grid * scale) / 2, (size.height - grid * scale) / 2);
    canvas.scale(scale);

    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 山：单峰（左山脚 → 主峰 → 右山脚），**只有两笔折线，不做山脚横线**（与下单浮标的双峰+雪顶彻底分开）
    canvas.drawPath(
      Path()
        ..moveTo(footLeft.dx, footLeft.dy)
        ..lineTo(peak.dx, peak.dy)
        ..lineTo(footRight.dx, footRight.dy),
      pen,
    );

    // 示：一小横 + 一竖（竖笔上端接在横上，下端落基线）
    canvas.drawPath(
      Path()
        ..moveTo(barLeft.dx, barLeft.dy)
        ..lineTo(barRight.dx, barRight.dy),
      pen,
    );
    canvas.drawPath(
      Path()
        ..moveTo(stemTop.dx, stemTop.dy)
        ..lineTo(stemBottom.dx, stemBottom.dy),
      pen,
    );

    // 阝方折：闭合方框（四条边各自独立成线 → 22px 下四条边都数得出来，中间留孔）
    // 直角用 miter，保证「方折」是方角而不是圆角
    canvas.drawPath(
      Path()
        ..addRect(foldRect),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.miter,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant QishanMarkPainter old) => old.color != color || old.strokeWidth != strokeWidth;
}
