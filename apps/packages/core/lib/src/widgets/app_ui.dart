import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';

/// ============ 祁连山电竞 · 通用组件（最终设计稿 I 系列）============
///
/// 设计约定（docs/21 + 最终稿）：
/// - 卡片：白底 + 冷描边 + 轻阴影，圆角 16
/// - 标签：浅底 + 同色描边 + 同色字（`AppTag`），禁止 emoji
/// - 渐变：只用于强调场景（主按钮 / 榜单横幅 / 头像 / 下单浮标）
/// - 价格：琥珀金（`AppPrice`）
/// - 分区标题：左标题 + 右侧动作，不做居中对称

/// 自绘页头（设计稿 I 系列：白底 + 返回 + 20pt 加粗标题 + 底部发丝线）
///
/// 二级页统一走这里，替代旧的玻璃/磨砂页壳；配合 `AppMotionRoute` 做同级页前进转场。
/// 用法：`Scaffold(backgroundColor: T.scaffoldColor, body: Column(children: [AppPageHeader(title: '设置'), Expanded(child: ...)]))`
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle = '',
    this.actions = const [],
    this.onBack,
    this.showBack = true,
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;

  /// 自定义返回行为（默认 maybePop）
  final VoidCallback? onBack;
  final bool showBack;

  /// 页头**内容行**高 56（不含底部发丝线）
  static const double contentHeight = 56;

  /// 页头底部发丝线高 1
  static const double hairlineHeight = 1;

  /// 页头**整条**高 57（56 内容 + 1 发丝线）
  ///
  /// 存在理由：把页头搬进滚动区（`SliverPersistentHeader` 这类 sliver）时必须给死
  /// `minExtent == maxExtent`，那个数字**必须与页头实现同源**，否则"页头 56、sliver 给 60"
  /// 会立刻露出 4dp 的空白或溢出一像素。所以这里把两段都登记成一个数，谁要装页头谁引用它
  /// （当前唯一调用点：`worker_profile_page.dart` 的随滚顶栏，负责人 2026-10-18）。
  static const double barHeight = contentHeight + hairlineHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: T.bgCardSolid,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: contentHeight,
              child: Row(
                children: [
                  if (showBack)
                    IconButton(
                      onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                      icon: AppIcon.of(AppIcon.arrowLeft, size: 20, color: T.textPrimary),
                      tooltip: '返回',
                    )
                  else
                    const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: T.textPrimary)),
                        if (subtitle.isNotEmpty)
                          Text(subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5, color: T.textTertiary)),
                      ],
                    ),
                  ),
                  ...actions,
                  const SizedBox(width: 8),
                ],
              ),
            ),
            // 发丝线（列表与内容分界，docs/21：不用阴影铺卡片）
            Container(height: hairlineHeight, color: T.divider),
          ],
        ),
      ),
    );
  }
}

/// 发丝线分隔（AppCard 内行间隔，左缩进对齐文案起点）
class AppHairline extends StatelessWidget {
  const AppHairline({super.key, this.indent = 0, this.endIndent = 0});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, margin: EdgeInsets.only(left: indent, right: endIndent), color: T.divider);
}

/// 标准卡片（白底 + 描边 + 轻阴影）
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 16,
    this.onTap,
    this.margin,
    this.color,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? margin;
  final Color? color;

  /// 自定义描边（负责人 2026-10-05）：默认 null = 全站发丝线；
  /// 置顶推荐商品传 1px 琥珀金描边（见 `productCardBorder`），其余卡片行为零变化。
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? T.bgCardSolid,
        borderRadius: BorderRadius.circular(radius),
        border: border ?? Border.all(color: T.divider),
        boxShadow: const [
          BoxShadow(color: Color(0x0A0F172A), blurRadius: 14, offset: Offset(0, 4)),
        ],
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: box),
    );
  }
}

/// 彩色标签胶囊（浅底 + 同色描边 + 同色字）
class AppTag extends StatelessWidget {
  const AppTag(this.text, {super.key, required this.color, this.solid = false, this.icon});

  final String text;
  final Color color;

  /// 实心（用于「官方」这类需要突出的标）
  final bool solid;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final bg = solid ? color : AppColors.categorySoft(color);
    final border = solid ? color : AppColors.categoryBorder(color);
    final fg = solid ? Colors.white : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[AppIcon.of(icon, size: 10, color: fg), const SizedBox(width: 3)],
          Text(text, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: fg, height: 1.3)),
        ],
      ),
    );
  }
}

/// 价格（橙金 · **按字号自动选档**）
///
/// [value] **必须**是 `fmtMoney` 的产物（`¥8.80` / `¥1,234.50`）—— 金额格式只有那一份实现，
/// 页面不拼 `¥`、不管小数位（负责人 2026-10-09 口径：计价单位 = 余额，1 元 = 1 元）。
/// [unit] 只在**非金额**后缀时传（如商品计价单位 `/局`、`/小时`，渲染成小号跟在数字右侧）；
/// 金额语境一律留空 → 整串同字号渲染，`find.text('¥8.80')` 可整串命中。
///
/// ## 两档金（2026-10-16 负责人拍板）
/// `#F59E0B` 白底只有 2.15:1 —— **小字**（<19px）白天在手机上读不清。
/// 因此本组件**在内部按 [size] 自动选档**（调用点无需关心；就是传了 `T.gold` 也安全）：
/// - `size ≥ [largeMoneySize]`（19）→ [AppColors.gold] `#F59E0B`（F 的大字金，白底 2.15:1 有意保留）；
/// - `size < 19` → [AppColors.goldText] `#935F06`（同一支橙金深一档，白底 **5.41:1**）；
/// - **单位**（`size × 0.55`，永远是"小字"）→ 一律 [AppColors.goldText]。
///
/// 好处："小字用深金"这件事收口在**一处**，而不是散在每个页面里 —— 于是连
/// **禁止改动的 `product_list_page.dart`（`size: 15`）也自动拿到可读的深金**，文件零改动。
class AppPrice extends StatelessWidget {
  const AppPrice({
    super.key,
    required this.value,
    this.unit = '',
    this.size = 19,
    this.color,
  });

  /// 大号金额门槛：`≥` 此值用 [AppColors.gold]，否则用 [AppColors.goldText]
  /// （= WCAG 大字门槛 18.66px 的取整，与 F 的"大字金"一致）
  static const double largeMoneySize = 19;

  final String value;
  final String unit;
  final double size;
  final Color? color;

  /// 按字号把"金"落到正确档位；**非金的自定义色原样保留**（如错误红压价）
  static Color moneyInk({required double size, Color? explicit}) {
    final base = explicit ?? AppColors.gold;
    // gold / accentMoney / T.gold 三者同值 → 比一次就够
    final isGold = base == AppColors.gold || base == AppColors.accentMoney;
    if (!isGold) return base;
    return size >= largeMoneySize ? AppColors.gold : AppColors.goldText;
  }

  @override
  Widget build(BuildContext context) {
    final c = moneyInk(size: size, explicit: color);
    if (unit.isEmpty) {
      return Text(value, style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: c, height: 1.1));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: c, height: 1.1)),
        const SizedBox(width: 3),
        // 单位永远是"小字"（size×0.55）→ 一律深金；不再叠 0.8 alpha（叠了对比度还要再降一档）
        Text(unit,
            style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w700, color: AppColors.goldText)),
      ],
    );
  }
}

/// 主按钮（品牌渐变）/ 次按钮（描边）
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.gradient = true,
    this.icon,
    this.height = 46,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool gradient;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final radius = BorderRadius.circular(12);
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[AppIcon.of(icon, size: 17, color: gradient ? Colors.white : T.textPrimary), const SizedBox(width: 6)],
        Text(
          label,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: gradient ? Colors.white : T.textPrimary,
          ),
        ),
      ],
    );
    return Opacity(
      opacity: disabled ? .5 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              gradient: gradient ? T.brandGradient : null,
              color: gradient ? null : T.bgCardSolid,
              borderRadius: radius,
              border: gradient ? null : Border.all(color: T.divider),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 分区标题（左标题 + 右侧动作，绝不居中）
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 8),
  });

  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: T.textPrimary)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(subtitle!, style: TextStyle(fontSize: 10.5, color: T.textTertiary), overflow: TextOverflow.ellipsis),
            ),
          ] else
            const Spacer(),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.primary)),
            ),
        ],
      ),
    );
  }
}

/// 分段切换（负责人 2026-10-04：打赏/退款/投诉三页的「列表 / 记录」切换）
///
/// 视觉（docs/21）：**实色主色**选中（不用渐变）、圆角分档（外 6 / 内 5）、发丝线描边、
/// 组内紧（段与段之间无间隙）、不做彩色标签堆砌 —— 只有"当前在哪一段"一个信息。
class AppSegmented extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.items,
    required this.current,
    required this.onChanged,
    this.padding = const EdgeInsets.fromLTRB(16, 10, 16, 6),
  });

  final List<String> items;
  final int current;
  final ValueChanged<int> onChanged;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Container(
        height: 34,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.divider),
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == current ? T.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      items[i],
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: i == current ? FontWeight.w700 : FontWeight.w400,
                        color: i == current ? Colors.white : T.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 空态（图标 + 文案 + 可选动作）
class AppEmpty extends StatelessWidget {
  const AppEmpty({super.key, required this.icon, required this.text, this.action, this.onAction});

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          AppIcon.of(icon, size: 42, color: T.textTertiary.withValues(alpha: .6)),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(fontSize: 13, color: T.textTertiary)),
          if (action != null) ...[
            const SizedBox(height: 14),
            AppButton(label: action!, onPressed: onAction, gradient: false, expand: false, height: 38),
          ],
        ],
      ),
    );
  }
}

/// 品牌雪山标（下单按钮/加载页用，纯绘制，无图片依赖）
///
/// ## 雪顶不是"另一层描边"
/// 设计稿（`site/design/order-fab/e-collapse-pill.html` 的 `.fab .mk`）里，雪山标就是
/// **一个 path**：双峰折线 + 两段雪顶折角，同色、同层、一笔画完。
///
/// 旧实现把雪顶当成**独立的一次同色描边**重画了一遍。雪顶的两条斜边与主峰折线
/// 本来就完全重合（`(0.19,0.44)→(0.30,0.18)→(0.41,0.44)` 走的就是主峰那两条边），
/// 所以那是一次**纯粹的冗余绘制**：像素实测（15/18/19/26dp 四个尺寸、8 倍栅格化）
/// 与"只画折线"**逐像素完全一致、墨量差 0 像素** —— 它既不产生更重的墨，
/// 也不产生暗边/光晕，**不是**"浅底上多一层"的成因（那个成因在收起动画的裁切，见 app_nav.dart）。
///
/// 现在：`snowColor` 不传（= null）时**只画主路径**，去掉这次重复绘制；
/// 需要让雪顶用**不同颜色**时才额外画一层（那时它才真正可见）。
class AppMountainMark extends StatelessWidget {
  const AppMountainMark({super.key, this.size = 20, this.color = Colors.white, this.snowColor});

  final double size;
  final Color color;

  /// 雪顶颜色；**null = 与主线同色 → 不再叠一层**（推荐，也是设计稿的画法）
  final Color? snowColor;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size * 0.72),
        painter: _MountainPainter(color: color, snow: snowColor),
      );
}

class _MountainPainter extends CustomPainter {
  _MountainPainter({required this.color, required this.snow});

  final Color color;
  final Color? snow;

  /// 主轴折线（双峰）—— 唯一必须画的路径
  Path _ridge(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(0, h)
      ..lineTo(w * 0.30, h * 0.18)
      ..lineTo(w * 0.46, h * 0.62)
      ..lineTo(w * 0.66, h * 0.30)
      ..lineTo(w, h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = (w * 0.11).clamp(1.6, 3.0);
    final p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 主峰折线（双峰）
    canvas.drawPath(_ridge(size), p);

    // 雪顶：**只有与主线不同色时才画**
    // （同色时它与主峰折线完全重合 → 纯重复绘制，墨量与"只画折线"逐像素一致，无视觉收益）
    final snowPaint = snow;
    if (snowPaint == null || snowPaint == color) return;

    final sp = Paint()
      ..color = snowPaint
      ..strokeWidth = stroke * 0.92
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final s1 = Path()
      ..moveTo(w * 0.19, h * 0.44)
      ..lineTo(w * 0.30, h * 0.18)
      ..lineTo(w * 0.41, h * 0.44);
    canvas.drawPath(s1, sp);
    final s2 = Path()
      ..moveTo(w * 0.58, h * 0.46)
      ..lineTo(w * 0.66, h * 0.30)
      ..lineTo(w * 0.74, h * 0.46);
    canvas.drawPath(s2, sp);
  }

  @override
  bool shouldRepaint(covariant _MountainPainter old) => old.color != color || old.snow != snow;
}
