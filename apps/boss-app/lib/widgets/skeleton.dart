import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'fish_glass.dart';

/// 骨架屏（2026-09-25 负责人要求：加载中显示骨架屏，而不是大面积空白）
/// 微光扫过的灰块占位，形状与真实内容一致，避免"空白 → 内容"的突兀跳动。
class FishSkeleton extends StatefulWidget {
  const FishSkeleton({super.key, required this.width, required this.height, this.radius = 8, this.margin});

  final double width;
  final double height;
  final double radius;
  final EdgeInsetsGeometry? margin;

  @override
  State<FishSkeleton> createState() => _FishSkeletonState();
}

class _FishSkeletonState extends State<FishSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? Colors.white.withValues(alpha: 0.06) : AppColors.placeholderBg;
    // 2026-10-14 品牌升级：微光高光走 token `AppColors.bgPage`（2026-10-16 方案 F 后 = 白）
    final highlight = dark ? Colors.white.withValues(alpha: 0.13) : AppColors.bgPage;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value;
        return Container(
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + t * 2 - 0.6, 0),
              end: Alignment(-1 + t * 2 + 0.6, 0),
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// 商品列表骨架（形状与真实商品卡一致：图 + 标题 + 描述 + 价格行）
class FishProductSkeleton extends StatelessWidget {
  const FishProductSkeleton({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FishGlassCard(
              insideMargin: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const FishSkeleton(width: 72, height: 72, radius: 12),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const FishSkeleton(width: 140, height: 15),
                        const SizedBox(height: 8),
                        const FishSkeleton(width: 100, height: 12),
                        const SizedBox(height: 12),
                        Row(
                          children: const [
                            FishSkeleton(width: 54, height: 16),
                            SizedBox(width: 10),
                            FishSkeleton(width: 44, height: 11),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const FishSkeleton(width: 52, height: 30, radius: 16),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
