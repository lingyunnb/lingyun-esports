/// 液态玻璃悬浮底栏（负责人 2026-10-18）
///
/// 从 `AppBottomNav.build` 的玻璃分支拆出来的独立 StatefulWidget。拆出来只有一个原因：
/// **横滑跟手**需要一个"拖动中的滑块位置"状态，而 `AppBottomNav` 是公共无状态组件，
/// 不该为了一个外观选项改变自身生命周期（它同时被工作端引用）。
///
/// ## 三个非显然的设计决定
///
/// ### ① 特效必须裁在胶囊里（`ClipRRect`）
/// `GlassGlow` 的光晕按 `glowRadius × layer 最短边` 算半径，会画到胶囊**外面**；
/// `LiquidGlass` 的折射采样 likewise 会取到边界外的像素。不裁就会出现
/// "底栏四周散着一圈毛玻璃雾"的脏边 —— 负责人明确要求"特效不要扩散到导航栏外"。
/// 裁剪不影响命中测试（`ClipRRect` 只作用绘制），所以 `GlassGlow` 的触摸照常。
///
/// ### ② 横滑时滑块跟手、松手吸附
/// 负责人：「用户从服务滑到我的，特效要跟住」。做法：
/// - 拖动中 `_dragLeft` 非空 → 用**无动画**的 `Positioned`，滑块跟手指走；
/// - 松手 → 按最近的格吸附，并触发那一格的 `onSelect`；
/// - 吸附后 `_dragLeft` 归空 → 切回 `AnimatedPositioned`，点击切换仍有 380ms 滑动。
///
/// ### ③ 底色不能再"灰"
/// 上一版本体白 32% / 滑块 50%，在白底页面上几乎和页面融为一体（用户："太不明显"）。
/// 现在：本体白 **62%**、滑块白 **92%**，并给本体加 24dp 投影 ——
/// 投影是这里的关键：**透的玻璃靠投影才能看出"它浮着"**，光提亮会失去玻璃感。
library;

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

class GlassNavBar extends StatefulWidget {
  const GlassNavBar({
    required this.height,
    required this.bottomInset,
    required this.itemCount,
    required this.currentIndex,
    required this.orderCreateIndex,
    required this.onSelect,
    required this.child,
  });

  final double height;
  final double bottomInset;
  final int itemCount;
  final int currentIndex;

  /// 「下单」那一位：它不是页面分支（点击是 push 选择服务页）。
  /// 拖动吸附时要**跳过**它 —— 滑过它不该触发下单。
  final int orderCreateIndex;

  final ValueChanged<int> onSelect;
  final Widget child;

  @override
  State<GlassNavBar> createState() => GlassNavBarState();
}

class GlassNavBarState extends State<GlassNavBar> {
  /// 拖动中的滑块左边缘（null = 没在拖）
  double? _dragLeft;

  /// 每格宽度（`LayoutBuilder` 实测后写回，拖动时需要它换算目标格）
  double _cellW = 0;

  /// 手指相对**滑块左边缘**的偏移（拖动起点抓取用）
  ///
  /// 没有它的话，滑块会"跳"到手指下方才开始跟 —— 按在滑块右半边和左半边起步
  /// 手感完全不同。抓住这个偏移后，真正的语义是"我按住滑块的哪一点，它就绕着
  /// 那一点跟手"，与 iOS 拖动控件一致。
  double _grabOffset = 0;

  static const double _radius = 28;

  void _onDragStart(DragStartDetails d) {
    if (_cellW <= 0) return;
    final sliderLeft = widget.currentIndex * _cellW;
    _grabOffset = d.localPosition.dx - sliderLeft;
    setState(() => _dragLeft = sliderLeft);
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_cellW <= 0) return;
    final maxLeft = _cellW * (widget.itemCount - 1);
    // 跟手 = 用「手指绝对位置 - 抓取偏移」，而不是累加 delta。
    // 累加 delta 会随事件丢帧漂移；绝对位置每次都对得上手指。
    final target = d.localPosition.dx - _grabOffset;
    setState(() => _dragLeft = target.clamp(0.0, maxLeft));
  }

  void _onDragEnd(DragEndDetails _) {
    final left = _dragLeft;
    if (left == null || _cellW <= 0) return;
    // 松手：让 AnimatedPositioned 接着把滑块吸到目标格（easeOutBack = 轻微过冲回弹）
    setState(() => _dragLeft = null);

    var idx = (left / _cellW).round().clamp(0, widget.itemCount - 1);
    // 吸附到「下单」位时让开一格：横滑不该把人带进下单页
    if (idx == widget.orderCreateIndex) {
      idx = idx > widget.currentIndex ? idx - 1 : idx + 1;
      idx = idx.clamp(0, widget.itemCount - 1);
    }
    if (idx != widget.currentIndex) widget.onSelect(idx);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, widget.bottomInset + 8),
      child: GestureDetector(
        // 横滑跟手：竖滑/点击照常穿透给内部（drag 只在横向赢竞技场）。
        // behavior 必须显式 opaque：默认 deferToChild 时，胶囊里的空白缝隙收不到拖动。
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: ClipRRect(
          // ① 把所有特效裁在胶囊内
          borderRadius: BorderRadius.circular(_radius),
          child: GlassGlowLayer(
            child: GlassGlow(
              // 点按光晕：按在底栏上亮一圈柔光（触摸才出现）
              glowColor: const Color(0x40FFFFFF),
              glowRadius: 0.9,
              child: LiquidGlassLayer(
                settings: const LiquidGlassSettings(
                  // 参数拉满（见 git log：预设会锁死 dispersion=0，永远看不到彩虹边）
                  refractionHeight: 42,
                  refractionAmount: 130,
                  refractionFitsShape: true,
                  backdropShrink: 0,
                  frost: 0,
                  dispersion: 1,
                  highlight: 1,
                  contourStrength: 1,
                  contourDirectionality: 0.77,
                  bevelShadowStrength: 0.22,
                  tintAmount: 0,
                ),
                child: SizedBox(
                  height: widget.height,
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final cell = box.maxWidth / widget.itemCount;
                      _cellW = cell;

                      // ── 滑动细节特效（负责人 2026-10-21：「滑动效果的细节特效没做」）
                      //
                      // ① 拉伸：拖动中滑块随"离开落点的距离"变宽，像一块被手指拖着的
                      //    液体；松手那一刻宽度收回标准值。上限 26dp，超过就会顶到邻格。
                      // ② 回弹：松手后用 `easeOutBack` 而不是 `easeOutCubic` —— 后者是
                      //    纯减速（像电梯停靠），前者会**轻微过冲再回来**，才像"吸附"。
                      final dragDist = _dragLeft == null
                          ? 0.0
                          : (_dragLeft! - widget.currentIndex * cell).abs();
                      final stretch = (dragDist * 0.3).clamp(0.0, 26.0);
                      // 拉伸时左右各让一半，保证中心点不偏
                      final left =
                          (_dragLeft ?? widget.currentIndex * cell) + 6 - stretch / 2;
                      final w = cell - 12 + stretch;

                      Widget slider = LiquidGlass.grouped(
                        shape: LiquidRoundedSuperellipse(borderRadius: 20),
                        appearance: LiquidGlassAppearance(
                          tint: Colors.white.withValues(alpha: 0.92),
                        ),
                        child: const SizedBox.expand(),
                      );
                      final Widget positionedSlider = _dragLeft != null
                          ? Positioned(left: left, top: 6, bottom: 6, width: w, child: slider)
                          : AnimatedPositioned(
                              duration: const Duration(milliseconds: 420),
                              // 过冲回弹：数值越大越"弹"，1.2 足够看出弹性又不夸张
                              curve: Curves.easeOutBack,
                              left: left,
                              top: 6,
                              bottom: 6,
                              width: w,
                              child: slider,
                            );

                      return Stack(
                        children: [
                          // ② 玻璃层：本体 + 滑块（在 blend 距离内融成一块）
                          Positioned.fill(
                            child: LiquidGlassBlendGroup(
                              blend: 26,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: LiquidGlass.grouped(
                                      shape: LiquidRoundedSuperellipse(
                                        borderRadius: _radius,
                                      ),
                                      appearance: LiquidGlassAppearance(
                                        // 白 62%：比上一版 32% 明显得多，
                                        // 但还没到"实色不透明"，玻璃感仍保留
                                        tint: Colors.white.withValues(alpha: 0.62),
                                      ),
                                      // 投影 = 让"透的玻璃"看起来浮着（关键）
                                      // 不靠外部 Container 的 boxShadow：那会被
                                      // ClipRRect 一起裁掉，白画。
                                      shadows: const [
                                        BoxShadow(
                                          color: Color(0x2B0F2440),
                                          blurRadius: 24,
                                          offset: Offset(0, 10),
                                        ),
                                      ],
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                  positionedSlider,
                                ],
                              ),
                            ),
                          ),
                          // ③ 内容层（图标 + 文字压最上面）
                          Positioned.fill(child: widget.child),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
