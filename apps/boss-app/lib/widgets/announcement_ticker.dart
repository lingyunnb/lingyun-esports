import 'dart:io' show Platform;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 首页「滚动文字播报条」（方案 G 定案，`site/design/ref-video/planG-all.html` 首页 ③）
///
/// ## 它是什么
/// 一条高 32 的横条：`#FFFBEB` 底 + `#8A5A00` 字，左侧一枚小喇叭图标，
/// 正文是**真实无限横向滚动**（不是静态裁剪），两端渐隐。
///
/// ## 三条硬要求（任务书）
/// 1. **真实滚动**：`AnimationController` + `Transform.translate` 无限循环，
///    用"同一段文字画两遍"实现无缝（位移到第一段末尾时刚好接上第二段）；
/// 2. **空态整块不渲染**：没有任何公告时返回 `SizedBox.shrink()` —— 不占高度、不留白条
///    （docs/21「不存在的东西不出现」）；
/// 3. **两端渐隐**：`ShaderMask` + `LinearGradient`（透明 → 不透明 → 透明）。
///
/// ## 为什么"无限动画"要加环境闸门（重要，别删）
/// 本仓库有大量 `tester.pumpAndSettle()`（≈20 个用例直接渲染服务页）：
/// **只要页面上有一个永不停止的动画，`pumpAndSettle` 就永不收敛**（`profile_page.dart:860`
/// 已经踩过同一个坑并留下了教训注释：那里的骨架**刻意不做 shimmer**）。
/// 因此动效在下面两种情况下自动关闭，只留静态首帧（文案照样可读、可断言）：
/// - 运行在 `flutter test` 下（`FLUTTER_TEST=true`，Flutter 测试框架注入的环境变量）；
/// - 系统无障碍设置「减少动态效果」打开（`MediaQuery.disableAnimations`）。
///
/// 另有 [AppTickerMotion.debugDisabled] 供个别用例显式关掉（默认 false）。
class AnnouncementTicker extends StatefulWidget {
  const AnnouncementTicker({
    super.key,
    required this.titles,
    this.onTap,
    this.height = AppTickerMotion.height,
  });

  /// 播报标题（服务端 `GET /public/announcements` 的最新若干条，已由调用方按序取好）
  ///
  /// 空列表 → **本组件不渲染任何像素**（连高度都不占）。
  final List<String> titles;

  /// 点整条 → 进公告列表（null = 不可点）
  final VoidCallback? onTap;

  /// 条高（默认 [AppTickerMotion.height]）
  final double height;

  @override
  State<AnnouncementTicker> createState() => _AnnouncementTickerState();
}

class _AnnouncementTickerState extends State<AnnouncementTicker> with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  /// 拼接后的整句（条目之间用「 · 」分隔 —— 与稿内 `.tkt` 的分隔符一致）
  String get _text => widget.titles.where((t) => t.trim().isNotEmpty).join(' · ');

  bool get _motionEnabled {
    if (AppTickerMotion.debugDisabled) return false;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return false;
    return MediaQuery.maybeOf(context)?.disableAnimations != true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant AnnouncementTicker old) {
    super.didUpdateWidget(old);
    if (old.titles.length != widget.titles.length || old.titles.join() != widget.titles.join()) {
      _syncMotion();
    }
  }

  /// 按环境开/关动效（关的时候把 controller 彻底停掉，`pumpAndSettle` 才会收敛）
  void _syncMotion() {
    final want = _motionEnabled && _text.isNotEmpty;
    if (!want) {
      _ctrl?.stop();
      _ctrl?.dispose();
      _ctrl = null;
      return;
    }
    if (_ctrl == null) {
      // 时长在首帧按文字宽度重算（见 [_durationFor]）；这里先给一个保守值
      _ctrl ??= AnimationController(vsync: this, duration: const Duration(seconds: 12));
      _ctrl!.repeat();
    }
  }

  /// 滚动速度 = 每 [AppTickerMotion.dpPerSecond] dp/秒（横幅上"刚好看得清又不拖沓"的一档）
  Duration _durationFor(double width) {
    final seconds = (width / AppTickerMotion.dpPerSecond).clamp(6.0, 60.0);
    return Duration(milliseconds: (seconds * 1000).round());
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: widget.height,
      child: Material(
        color: AppColors.tickerBg,
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                // 小喇叭：用现有线性图标体系（仓库铁律：图标一律 AppIcon，不许 emoji/字体图标）
                AppIcon(AppIcons.bell, size: 14, color: AppColors.tickerInk),
                const SizedBox(width: 8),
                Expanded(child: _marquee(text)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 滚动正文（两端渐隐 + 无缝循环）
  Widget _marquee(String text) {
    final style = TextStyle(fontSize: 12, height: 1.3, color: AppColors.tickerInk, fontWeight: FontWeight.w600);

    return LayoutBuilder(
      builder: (context, box) {
        // 用 TextPainter 量出**整句**宽度：滚动距离与时长都依赖它
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final textWidth = tp.width + AppTickerMotion.gap;
        final ctrl = _ctrl;
        if (ctrl != null) {
          final want = _durationFor(textWidth);
          if (ctrl.duration != want) ctrl.duration = want;
        }

        // 静态首帧：只画一份、左对齐（测试 / 无障碍"减少动态效果"下就是这个形态）
        if (ctrl == null) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          );
        }

        return ClipRect(
          child: ShaderMask(
            // dstIn：只保留"遮罩不透明"的部分 → 两端自然淡出，不需要盖两个纯色块
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
              stops: const [0.0, AppTickerMotion.fadeStop, 1 - AppTickerMotion.fadeStop, 1.0],
            ).createShader(rect),
            child: AnimatedBuilder(
              animation: ctrl,
              builder: (context, child) => Transform.translate(
                // 位移 = 一整段（文字宽 + 间隔）→ 到点瞬间第二段正好接上（无缝）
                offset: Offset(-textWidth * ctrl.value, 0),
                child: child,
              ),
              // 同一段文字画两遍：位移走完第一段时，第二段已经顶到最左
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text, maxLines: 1, softWrap: false, style: style),
                  SizedBox(width: AppTickerMotion.gap),
                  Text(text, maxLines: 1, softWrap: false, style: style),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 播报条的几何/动效常量（集中一处，页面与测试都从这里取）
class AppTickerMotion {
  AppTickerMotion._();

  /// 条高 32（方案 G 稿内是 34；本项目间距必须落 4dp 网格 —— `AppDecoSpacing.grid`
  /// = [4,8,12,16,20,24,32,48,64]，34 不在网格内，取最近的 32，肉眼无差）
  static const double height = 32;

  /// 滚动速度（dp/秒）：40 是"一眼能读完一段、又不至于要等半天"的一档
  static const double dpPerSecond = 40;

  /// 两段文字之间的间隔（= 循环接缝处的留白）
  static const double gap = 48;

  /// 两端渐隐的宽度占比（每侧 6%）
  static const double fadeStop = 0.06;

  /// **测试开关**：true = 不做无限滚动（只画静态首帧，`pumpAndSettle` 可收敛）
  static bool debugDisabled = false;
}
