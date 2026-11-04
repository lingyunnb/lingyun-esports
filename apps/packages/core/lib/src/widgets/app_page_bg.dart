import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 页面底（负责人 2026-10-17 定案「白色 + 另一种浅色，主题还是白」；2026-10-18 补图案层）
///
/// ## 它是什么
///
/// 全站页面**第一层背景**，自下而上两层：
///
/// 1. **渐变**（[wash]）：左上纯白 → 中段近白 → 右下极浅品牌蓝，45 度斜向铺满。
///    唯一职责是"整页不是一块死白"，让白卡与白页底之间多一层极低对比的空气感。
/// 2. **等高线**（[contourCount] 条缓曲线，[contourWidth] 线宽，[contourOpacity] 一档透明度）：
///    给"光秃秃的一条渐变"补一层极克制的质感。**整页铺满**，且**永远在所有内容之下**
///    —— 卡片是不透明白面，压在上面就自然把图案挡住，一个字都读不到它。
///
/// ## 为什么选等高线（三选一里挑的那一套）
///
/// 备选是圆点阵（14 网格上的实心点）与 45 度斜细纹。取舍理由：
///
/// - **贴合品牌**：片名就是「祁连山」，等高线是地形线 —— 它给的是"高度/走向"这一层极淡的
///   雪山气质，而不是一块与内容无关的装饰。圆点最稳，但稳在没有信息。
/// - **没有方向性压力**：斜细纹自带"流动"的走向，快速划过一屏卡片时会读成"背景在动"；
///   等高线只有几根极缓的曲线，走向不指向任何交互元素，也不与卡片边缘比平行。
/// - **不形成色块**：图案只有**线**、没有填充、也不闭合（每条都穿出页边）——
///   所以它不会变成一块"彩色光斑"或"雾"，这是负责人明确否掉过的东西。
/// - **刻意不匀**：几条线的间距与折点位置逐条不同（见 [paint] 里的三条推导式），
///   避免读成"壁纸条纹"；均匀重复一排又一排才是"机器味"（docs/21 §二）。
///
/// ## 红线（越一条就算这一层白做）
///
/// 1. **只铺页面底**（`Scaffold` 的 `body` 外层 / 打手态 tab 的内容区）。
/// 2. **卡片、按钮、标签、主视觉区一律实色**：图案与渐变都不许出现在任何一个可点、可读的内容块上
///    —— 本仓的"反 AI 味"就是靠这条守住的（docs/21：「渐变做主视觉」是禁项）。
/// 3. **图案必须排在内容之前**（`Stack` 第一层）：既画在下面，也不会抢走任何一次点击。
/// 4. **不引入波纹 / 光斑 / 噪点颗粒 / 第二层渐变色块**：这一层从头到尾**只有一种颜色**
///    （[contourColor]）、**只有描边**（无填充），且只有 5 条（不是一排排重复花纹）。
/// 5. **浓度 ≤ 5%**（[contourOpacity] = 4.5%）：页底一抢戏，纯白卡片就浮不起来。
/// 6. **最深处不深于 [AppColors.bgWashBottom]**；全站**只有本文件**允许出现 `LinearGradient`
///    这一种渐变家族（其余渐变家族与着色器创建一律仍禁，源码级红线在
///    `apps/boss-app/test/page_deco_services_orders_test.dart` 的 ④ 组）。
///
/// ## 为什么图案用 `CustomPainter` 而不是图案库 / SVG
///
/// 一个底纹不值得为它引运行时（`flutter_svg` / 图表库都不必要）：Canvas 上几条 Bézier 就是
/// 这套线条 —— 零依赖、零资源包、参数可逐值复算。同理这里也没有用着色器
/// （本仓在真机上踩过着色器白屏，见 `apps/boss-app/lib/widgets/fish_glass.dart` 的历史注释）。
class AppPageBg extends StatelessWidget {
  const AppPageBg({super.key, required this.child});

  /// 页面内容（通常是 `Scaffold` 的 `body`，或打手态 tab 的内容区）
  final Widget child;

  /// 页底渐变本体：三档 + 45 度斜向
  ///
  /// - 方向 `topLeft → bottomRight`：比正上正下耐看（上下渐变会让"整页被上下切成两段"），
  ///   斜向只让右下角着一层色，读起来像自然光，而不是像一条色带。
  /// - 止点 `0.00 / 0.45 / 1.00`：中点压在 45%（不是 50%）—— 上半屏是内容最密的地方，
  ///   让它多留一点白；色从中段开始缓缓压上来。
  /// - 三档色值全部取自色板（[AppColors.bgWashTop] / [AppColors.bgWashMid] /
  ///   [AppColors.bgWashBottom]），本文件**不写字面量色值**。
  static const LinearGradient wash = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[
      AppColors.bgWashTop,
      AppColors.bgWashMid,
      AppColors.bgWashBottom,
    ],
    stops: <double>[0.0, 0.45, 1.0],
  );

  /// 等高线的条数 = 三张比例表的长度（5 条）
  ///
  /// 为什么是 5：一屏 844dp 下平均每 100dp 才一条，退开半米几乎看不出，凑近才成"地形"；
  /// 8 条以上就开始像"横纹背景"，2–3 条又会读成"两条画坏的横线"。
  static int get contourCount => contourBases.length;

  /// 每条线的**基准高度**（占页高的比例）—— **刻意不等距**：0.19 / 0.12 / 0.18 / 0.15
  ///
  /// 等距 = 壁纸条纹；间距有疏有密才读成地形（近坡线密、远坡线疏）。
  static const List<double> contourBases = <double>[0.14, 0.33, 0.45, 0.63, 0.78];

  /// 每条线的**上凸幅度**（占页高的比例）—— 越往下的线越平（远处地形被压扁）
  static const List<double> contourBulges = <double>[0.080, 0.066, 0.052, 0.044, 0.036];

  /// 每条线**折点的横向位置**（占页宽的比例）—— 逐条左移，线与线在中段自然收放
  static const List<double> contourKnuckles = <double>[0.46, 0.40, 0.34, 0.28, 0.22];

  /// 线宽（0.6dp 细线）
  ///
  /// 比发丝线（1px）更细：图案要能"消失"到内容后面，粗半档就会和卡片描边抢同一条视觉分量。
  static const double contourWidth = 0.6;

  /// 图案透明度（4.5%：任务口径 3–5% 的一档）
  ///
  /// 浓淡只由这一个数字控制 —— 不靠"更深的图案色 + 更低透明度"这种双变量，
  /// 那样调一次就得同时改两处，也没法一眼比较两档。
  static const double contourOpacity = 0.045;

  /// 图案颜色：品牌主色 [AppColors.primary]
  ///
  /// 为什么不新开一个色板 token：页底渐变本身就往品牌蓝偏（[AppColors.bgWashBottom]），
  /// 图案用**同一支蓝**再压到 4.5% 才是"同一层空气"；换成第二个颜色，
  /// 立刻会读成"贴上去的纹理"（负责人否过的那种彩色装饰）。
  static const Color contourColor = AppColors.primary;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: wash),
      child: Stack(
        // passthrough：内容收到的约束与"只有一层 `DecoratedBox`"时**逐字相同** ——
        // 加图案层不许改变任何一页的布局（那些页的滚动高度 / 出图用例都盯着这一点）。
        fit: StackFit.passthrough,
        // 老实现不裁剪子节点，这里也不裁剪：不给溢出兜出一个"以前看得见、现在被切掉"的差。
        clipBehavior: Clip.none,
        children: <Widget>[
          // 图案层：`Positioned.fill` 铺满整页；排在 child **之前** → 画在下面、也接不到手势
          // （`CustomPaint` 没有子节点时 `hitTestSelf` 为 false，天然不吃点击）。
          Positioned.fill(
            child: const CustomPaint(painter: _PageContourPainter()),
          ),
          child,
        ],
      ),
    );
  }
}

/// 等高线的画法：**一种颜色、一层透明度、只有描边、只有 5 条**
///
/// 三张比例表（基准高度 / 上凸幅度 / 折点横位）逐条取不同值，是这套图案
/// "像地形而不像壁纸"的全部来源：均匀等距 = 条纹，逐条不同 = 地形。
/// 参数全部取 [AppPageBg] 的常量，透明度也在这里收口
/// （不靠调用方传半透明色，否则"浓度"会散到调用处）。
class _PageContourPainter extends CustomPainter {
  const _PageContourPainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double w = size.width;
    final double h = size.height;
    final Paint paint = Paint()
      ..color = AppPageBg.contourColor.withValues(alpha: AppPageBg.contourOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppPageBg.contourWidth;
    // 两侧各多画一点：曲线从页边外侧进出，页面上不出现"线的端头"
    final double bleed = AppPageBg.contourWidth * 8;
    for (int i = 0; i < AppPageBg.contourCount; i++) {
      final double baseY = h * AppPageBg.contourBases[i];
      final double bulge = h * AppPageBg.contourBulges[i];
      final double knuckle = w * AppPageBg.contourKnuckles[i];
      final Path path = Path()
        ..moveTo(-bleed, baseY)
        // 前段：从页边缓升到折点（一条线只有这一处"脊"，不是一个接一个的重复波峰）
        ..cubicTo(
          knuckle * 0.46, baseY - bulge * 1.30, // 控制点 1：把曲线先压住，起手更平
          knuckle * 0.82, baseY - bulge, // 控制点 2：与终点同高 → 脊顶切线水平（不出折角）
          knuckle, baseY - bulge,
        )
        // 后段：过脊顶后缓缓回落，从右页边外侧出画（回落幅度约为上凸的三成，落笔比抬笔更平）
        ..cubicTo(
          knuckle + (w - knuckle) * 0.34, baseY - bulge,
          w - bleed, baseY - bulge * 0.22,
          w + bleed, baseY - bulge * 0.30,
        );
      canvas.drawPath(path, paint);
    }
  }

  /// 画的东西全是常量 + 由尺寸推出的曲线 → 重建出新的 painter 实例也不需要重绘
  @override
  bool shouldRepaint(covariant _PageContourPainter oldDelegate) => false;
}
