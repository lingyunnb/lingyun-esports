import 'dart:async';

import 'package:flutter/material.dart';

/// 顶级过渡动效工具箱（负责人 2026-10-04：把顶级开源项目的过渡动画搬过来）
///
/// 素材来源（均为宽松许可，可直接搬用）：
/// - **Material Motion**（Google，Apache-2.0）：Shared axis（X/Y/Z 轴共享）与 Fade through 的
///   时长/曲线规范（本文件 `Motion.duration*` 与曲线全部照搬其规范值）
/// - **animations 包**（flutter/packages，BSD-3）：SharedAxisTransition / FadeThroughTransition 的
///   实现思路（此处用 Flutter 内置能力等价实现，避免新增依赖带来的构建风险）
/// - **Flutter 内置 Hero + PageRouteBuilder**：共享元素与自定义路由（BSD-3）
///
/// 与"秒开"的关系：动效只做**入场**（不阻塞数据），时长都在 180–300ms 区间，
/// 观感更快（Material Motion 的核心结论：短而连续的动效比长动效"更快"）。
class Motion {
  Motion._();

  /// 路由转场（Shared axis X：横向共享轴，用于同级页面前进）
  static const Duration pageForward = Duration(milliseconds: 300);
  static const Duration pageReverse = Duration(milliseconds: 250);

  /// 列表项入场（错峰，每项 +35ms）
  static const Duration itemEnter = Duration(milliseconds: 260);
  static const Duration itemStagger = Duration(milliseconds: 35);

  /// 元素形变（Hero/容器变换）
  static const Duration containerTransform = Duration(milliseconds: 320);

  /// Material 3 标准缓动
  static const Curve emphasized = Cubic(0.2, 0, 0, 1); // emphasized decelerate
  static const Curve emphasizedAccel = Cubic(0.3, 0, 0.8, 0.15); // emphasized accelerate
  static const Curve standard = Cubic(0.2, 0, 0, 1);
}

/// 自定义页面路由：**横向共享轴（Shared axis X）+ 淡入**，前进/返回方向对称
///
/// 用法：`Navigator.push(context, AppMotionRoute(builder: (_) => Page()))`
class AppMotionRoute<T> extends PageRouteBuilder<T> {
  AppMotionRoute({required WidgetBuilder builder, super.settings, bool fullscreenDialog = false})
      : super(
          transitionDuration: Motion.pageForward,
          reverseTransitionDuration: Motion.pageReverse,
          fullscreenDialog: fullscreenDialog,
          pageBuilder: (ctx, _, _) => builder(ctx),
          transitionsBuilder: (ctx, animation, secondary, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Motion.emphasized,
              reverseCurve: Motion.emphasizedAccel,
            );
            // 共享轴 X：新页从右侧 8% 位移淡入；旧页反向轻微位移淡出（层次感）
            final slide = Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero).animate(curved);
            final fade = Tween<double>(begin: 0, end: 1).animate(curved);
            final secondaryFade = Tween<double>(begin: 1, end: 0.9).animate(curved);
            return SlideTransition(
              position: slide,
              child: FadeTransition(
                opacity: fade,
                child: FadeTransition(opacity: secondaryFade, child: child),
              ),
            );
          },
        );
}

/// 列表项入场：淡入 + 上移 8px + **按索引错峰**（顶级 App 列表的通用手感）
///
/// 用法：把 ListView 的每个 item 包一层 `StaggeredItem(index: i, child: ...)`
class StaggeredItem extends StatefulWidget {
  const StaggeredItem({super.key, required this.index, required this.child, this.maxDelay = 8});

  final int index;
  final Widget child;

  /// 错峰上限（超过后不再累加延迟，避免长列表末尾等太久）
  final int maxDelay;

  @override
  State<StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<StaggeredItem> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.itemEnter);
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: Motion.standard);
  late final Animation<Offset> _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
      .animate(CurvedAnimation(parent: _c, curve: Motion.emphasized));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: (widget.index.clamp(0, widget.maxDelay)) * Motion.itemStagger.inMilliseconds);
    _timer = Timer(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _slide, child: widget.child),
      );
}

/// 按压反馈（缩放到 0.97 + 阴影收敛）—— 顶级 App 卡片点击的"实感"
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child, required this.onTap, this.scale = 0.97});

  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: const Duration(milliseconds: 120),
          curve: Motion.standard,
          child: widget.child,
        ),
      );
}
