import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';

/// 液态玻璃环境背景（仅玻璃主题启用）：柔和渐变底 + 两团径向渐变光斑。
/// 纯静态（无动画控制器、无 ImageFiltered 模糊）：
/// - 光斑用径向渐变绘制（软边效果等价于模糊，但零 GPU 模糊开销）
/// - 不参与页面滚动层绘制，性能安全；低透明色不干扰文字阅读
/// 初始主题：直接透传 child，零开销。
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        if (!ThemeController.instance.isGlass) return child;
        return Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFF2F5FB), Color(0xFFE9EFF8), Color(0xFFF4F2FA)],
                  ),
                ),
              ),
            ),
            // 左上：品牌蓝光斑
            Positioned(
              left: -90,
              top: -70,
              child: const _GlowBlob(size: 320, color: Color(0x245B6CFF)),
            ),
            // 右下：淡金光斑（呼应黑金会员体系）
            Positioned(
              right: -110,
              bottom: 40,
              child: const _GlowBlob(size: 300, color: Color(0x1DE8C27A)),
            ),
            child,
          ],
        );
      },
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0.0)],
        ),
      ),
    );
  }
}
