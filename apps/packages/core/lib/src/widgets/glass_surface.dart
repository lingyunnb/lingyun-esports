import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';

/// 玻璃表面（主题系统统一表面组件，页面替代硬编码白卡）：
/// - 初始主题：实色卡片，classicRadius/classicMargin 精确复刻原样式（默认直角白块，零视觉变化）
/// - 液态玻璃主题：半透明玻璃 + 边缘高光 + 顶部高光 + 柔和投影；blur=true 时叠加背景模糊
/// 性能守卫：列表中默认 blur=false（大量模糊会掉帧），仅页头/导航/弹窗类大表面开 blur。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = false,
    this.color,
    this.radius = 0,
    this.borderColor,
    this.glassRadius,
    this.padding,
    this.margin,
    this.glassMargin,
    this.shadow = false,
    this.onTap,
  });

  final Widget child;
  final bool blur;

  /// 初始主题底色
  final Color? color;

  /// 初始主题圆角（默认 0 = 原状直角）
  final double radius;

  /// 初始主题描边色（复刻原卡片 border；玻璃主题用自己的高光描边）
  final Color? borderColor;

  /// 玻璃主题圆角（默认主题 Token 卡片圆角）
  final double? glassRadius;

  final EdgeInsetsGeometry? padding;

  /// 两模式通用外边距
  final EdgeInsetsGeometry? margin;

  /// 仅玻璃主题的外边距（卡片悬浮感，初始主题忽略）
  final EdgeInsetsGeometry? glassMargin;

  /// 初始主题投影开关（默认关，保持与原白卡一致）；玻璃主题始终带柔和投影
  final bool shadow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final t = ThemeController.instance.tokens;
        Widget surface;
        if (!t.isGlass) {
          surface = Container(
            padding: padding,
            decoration: BoxDecoration(
              color: color ?? t.bgCard,
              borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
              border: borderColor != null ? Border.all(color: borderColor!) : null,
              boxShadow: shadow
                  ? [BoxShadow(color: t.textPrimary.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))]
                  : null,
            ),
            // 内层透明 Material：ListTile/InkWell 的 ink 需要最近 Material 祖先（装饰容器会遮挡）
            child: Material(type: MaterialType.transparency, child: child),
          );
        } else {
          final gr = BorderRadius.circular(glassRadius ?? t.radiusCard);
          // 结构要点（修复"轮廓套框"与"文字被裁"）：
          // 1) padding 作用于内容层（不作用于装饰层）→ 内容完整、不被裁切边界挤压
          // 2) 背景模糊层用 Positioned.fill 置于 Stack 最底层（不参与尺寸计算，模糊的是卡片背后的页面）
          // 3) 内容为唯一非定位子项 → 撑开 Stack 尺寸（List 无界高度下不会塌缩为 0）
          // 4) 顶部高光贴在卡片真实上边缘（不受 padding 影响），不再形成内部"错位轮廓线"
          surface = Container(
            decoration: BoxDecoration(
              color: t.glassCardTint,
              borderRadius: gr,
              border: Border.all(color: t.glassBorder, width: 1),
              boxShadow: [BoxShadow(color: t.glassShadowColor, blurRadius: 18, offset: const Offset(0, 8))],
            ),
            child: ClipRRect(
              borderRadius: gr,
              child: Stack(
                children: [
                  if (blur)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: t.glassBlurSigma, sigmaY: t.glassBlurSigma),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  Padding(
                    padding: padding ?? EdgeInsets.zero,
                    child: Material(type: MaterialType.transparency, child: child),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: IgnorePointer(
                      child: Container(
                        height: 1.2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              t.glassHighlight.withValues(alpha: 0.75),
                              t.glassHighlight.withValues(alpha: 0.0),
                            ],
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
        // 始终包透明 Material：内部 ListTile/InkWell 的 ink 效果需要最近的 Material 祖先
        //（否则被装饰容器遮挡会触发 debug 断言；视觉上零变化）
        Widget result = Material(
          type: MaterialType.transparency,
          child: onTap != null
              ? InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(radius > 0 ? radius : (glassRadius ?? 12)),
                  child: surface,
                )
              : surface,
        );
        return Container(
          margin: t.isGlass ? (glassMargin ?? margin) : margin,
          child: result,
        );
      },
    );
  }
}
