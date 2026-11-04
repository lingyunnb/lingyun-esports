import 'dart:ui';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// FISH 老板端 · 液态玻璃统一骨架（flutter_miuix 风格，负责人 2026-09-25 大改）
///
/// 液态玻璃的关键：**磨砂表面必须衬在彩色背景上才可见**。
/// - [FishGlassBackdrop]：全局 HyperOS 式渐变光斑背景（明/暗两套），套在 MaterialApp.builder
/// - [FishGlassPage]：主页面骨架 = 光斑背景 + miuix 真磨砂顶栏（内容滚动时实时模糊背后内容）
/// - [FishGlassCard]：统一玻璃卡 —— 液态玻璃主题 = liquid_glass_widgets 满血特效（用户自选），
///   初始主题 = 简洁半透明白卡

/// 全局渐变光斑背景（HyperOS 壁纸感：柔和色块 + 光晕；随系统明暗切换。
/// 液态玻璃主题下光斑加强 —— 玻璃需要彩色背景衬托；初始主题下光斑极轻）
class FishGlassBackdrop extends StatelessWidget {
  const FishGlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    // 浅色：清透蓝紫粉；深色：深邃蓝紫（HyperOS 深色壁纸感）
    final colors = dark
        ? const [Color(0xFF0E1226), Color(0xFF1B1440), Color(0xFF251647)]
        : const [Color(0xFFEAF0FF), Color(0xFFF3EFFF), Color(0xFFFDF0F6)];
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final glass = ThemeController.instance.isGlass;
        // 液态玻璃主题：光斑饱和拉满（满血玻璃）；初始主题：极轻背景
        final blobs = dark
            ? [
                (Color(0xFF5B6CFF), glass ? 0.30 : 0.10, -0.32, -0.42, 380.0),
                (Color(0xFF9B6EFF), glass ? 0.24 : 0.08, 0.5, 0.15, 320.0),
                (Color(0xFF3FBFD9), glass ? 0.18 : 0.05, 0.75, 0.85, 300.0),
              ]
            : [
                (Color(0xFF8FA5FF), glass ? 0.32 : 0.10, -0.3, -0.38, 400.0),
                (Color(0xFFC3A6FF), glass ? 0.28 : 0.09, 0.55, 0.1, 360.0),
                (Color(0xFFFFB7D0), glass ? 0.22 : 0.07, 0.8, 0.9, 320.0),
              ];
        return Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                ),
              ),
            ),
            for (final b in blobs)
              Positioned(
                left: size.width * b.$3,
                top: size.height * b.$4,
                child: IgnorePointer(
                  child: Container(
                    width: b.$5,
                    height: b.$5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [b.$1.withValues(alpha: b.$2), b.$1.withValues(alpha: 0)]),
                    ),
                  ),
                ),
              ),
            child,
          ],
        );
      },
    );
  }
}

/// 主页面骨架：光斑背景 + miuix 真磨砂顶栏（[blurredTopBar] 为 true 时使用玻璃顶栏，
/// 内容滚动经过顶栏下方时实时模糊 —— 液态玻璃的招牌效果）
class FishGlassPage extends StatelessWidget {
  const FishGlassPage({
    super.key,
    required this.title,
    this.subtitle = '',
    this.actions = const [],
    this.bottom,
    this.floatingActionButton,
    this.blurredTopBar = false,
    required this.body,
  });

  final String title;

  /// 顶栏副标题（如聊天页的状态说明；仅 [blurredTopBar] 分支展示）
  final String subtitle;
  final List<Widget> actions;

  /// 顶栏下方附加内容（如 TabBar）
  final PreferredSizeWidget? bottom;

  /// 悬浮按钮（如社区发布）
  final Widget? floatingActionButton;

  /// true = MiuixGlassTopAppBar（真液态玻璃：滚动内容在顶栏下实时模糊+发光描边）
  final bool blurredTopBar;

  final Widget body;

  @override
  Widget build(BuildContext context) {
    // 2026-10-04 主题统一（负责人：所有 UI 复刻设计稿）：页壳改为
    // 冷灰蓝底 + 白底顶栏 + 发丝线 + 20pt 加粗标题，不再用玻璃磨砂
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight((bottom?.preferredSize.height ?? 0) + 58),
        child: Container(
          color: T.bgCardSolid,
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      if (Navigator.of(context).canPop())
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: Icon(AppIcon.arrowLeft, size: 20, color: T.textPrimary),
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
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                ?bottom,
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: floatingActionButton,
      body: body,
    );
    // ignore: dead_code
    // 以下为旧玻璃页头实现（保留备查，不再执行）
    // 玻璃顶栏 + 内容分列（不用 MiuixScaffold：其 content padding 不含玻璃顶栏高度，会遮挡首行内容与点击）
    // ignore: dead_code
    return FishGlassBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Column(
              children: [
                MiuixGlassTopAppBar(
                  title: title,
                  subtitle: subtitle,
                  // 顶栏下延光带设 0：避免覆盖首行内容导致点击被拦截
                  bandOverhang: 0,
                  navigationIcon: Navigator.of(context).canPop()
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Center(
                            child: MiuixIconButton(
                              onPressed: () => Navigator.of(context).maybePop(),
                              child: const Icon(Icons.arrow_back),
                            ),
                          ),
                        )
                      : null,
                  actions: actions,
                ),
                Expanded(
                  // 透明 Material：内容里的 ChoiceChip/TextField 等需要 Material 祖先（视觉零影响）
                  child: Material(type: MaterialType.transparency, child: body),
                ),
              ],
            ),
            if (floatingActionButton != null)
              Positioned(
                right: 16,
                bottom: 16,
                child: floatingActionButton!,
              ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃胶囊底部导航（2026-09-25 复刻 iOS 26 液态玻璃 TabBar 的效果，
/// 但用标准 Flutter 绘制 —— 第三方着色器方案在部分真机渲染白屏/蓝色块，不可用）。
/// 效果：悬浮胶囊 + 背景实时模糊 + 白色药丸指示器平滑滑动 + 选中图标放大上浮。
class FishGlassTabBar extends StatelessWidget {
  const FishGlassTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.strongGlass = true,
  });

  final List<FishTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// 液态玻璃主题 = 强磨砂；初始主题 = 轻磨砂实底
  final bool strongGlass;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final count = items.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            // 满血磨砂：强玻璃 28，初始主题 8
            filter: ImageFilter.blur(sigmaX: strongGlass ? 28 : 8, sigmaY: strongGlass ? 28 : 8),
            child: Container(
              height: 62,
              decoration: BoxDecoration(
                // 玻璃底：强玻璃更透（光斑透出），初始主题偏实
                color: (dark ? const Color(0xFF11162B) : Colors.white).withValues(alpha: strongGlass ? 0.5 : 0.9),
                borderRadius: BorderRadius.circular(28),
                // 高光描边（玻璃边缘亮线）
                border: Border.all(color: Colors.white.withValues(alpha: strongGlass ? 0.6 : 0.3), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: (dark ? Colors.black : const Color(0xFF27314B)).withValues(alpha: strongGlass ? 0.2 : 0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 9),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // 顶部玻璃高光带（模拟玻璃反光，满血特效）
                  if (strongGlass)
                    Positioned(
                      top: 0,
                      left: 12,
                      right: 12,
                      child: Container(
                        height: 18,
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.only(topLeft: Radius.circular(28), topRight: Radius.circular(28)),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(alpha: 0.32),
                              Colors.white.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  LayoutBuilder(
                    builder: (context, c) {
                      final tabW = c.maxWidth / count;
                      return Stack(
                        children: [
                          // 白色药丸指示器（弹簧滑动，液态玻璃 TabBar 招牌动效）
                          AnimatedPositioned(
                            duration: const Duration(milliseconds: 280),
                            curve: Curves.easeOutBack,
                            left: tabW * selectedIndex + 6,
                            top: 7,
                            width: tabW - 12,
                            height: 48,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: dark ? 0.18 : 0.94),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.25 : 0.9), width: 1),
                                boxShadow: dark
                                    ? null
                                    : [
                                        // 药丸落影（玻璃质感）
                                        BoxShadow(color: const Color(0xFF27314B).withValues(alpha: 0.14), blurRadius: 12, offset: const Offset(0, 4)),
                                      ],
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              for (var i = 0; i < count; i++)
                                Expanded(
                                  child: _tab(context, items[i], i == selectedIndex, dark),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, FishTabItem item, bool selected, bool dark) {
    final active = selected ? AppColors.primary : (dark ? Colors.white.withValues(alpha: 0.6) : AppColors.textTertiary);
    return InkWell(
      onTap: () => onSelected(items.indexOf(item)),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        scale: selected ? 1.12 : 1.0,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          offset: selected ? const Offset(0, -0.04) : Offset.zero,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(selected ? item.activeIcon : item.icon, size: 23, color: active),
              const SizedBox(height: 2),
              Text(
                item.label,
                style: TextStyle(fontSize: 10.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: active),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 玻璃导航项（与老板端/工作端共用）
class FishTabItem {
  const FishTabItem({required this.icon, required this.activeIcon, required this.label});

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 统一的玻璃卡（全 App 卡片入口统一走这里，参数与 MiuixCard 兼容）
/// 2026-09-25 真机修正：liquid_glass_widgets 的着色器在部分真机上渲染空白/色块（不可用），
/// 弃用 shader 方案，改回 BackdropFilter 磨砂 + 半透明白卡 —— 任何设备稳定显示。
///
/// 液态玻璃主题 = 磨砂玻璃卡；初始主题 = 素净半透明白卡（2026-10-04：主题选择入口已删除，统一走初始主题）
class FishGlassCard extends StatelessWidget {
  const FishGlassCard({super.key, required this.child, this.insideMargin = const EdgeInsets.all(AppSpacing.lg)});

  final Widget child;
  final EdgeInsetsGeometry insideMargin;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final glass = ThemeController.instance.isGlass;
        final card = Container(
          padding: insideMargin,
          decoration: BoxDecoration(
            color: dark ? const Color(0xE6202740) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: T.divider, width: 1),
            boxShadow: [
              BoxShadow(
                color: (dark ? Colors.black : const Color(0xFF27314B)).withValues(alpha: glass ? 0.12 : 0.06),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: child,
        );
        if (!glass) return card;
        // 液态玻璃主题：卡片背后内容实磨砂（+高光描边，玻璃质感）
        final glassCard = Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: const Color(0xFF27314B).withValues(alpha: 0.14), blurRadius: 22, offset: const Offset(0, 8)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1),
                ),
                child: card,
              ),
            ),
          ),
        );
        return glassCard;
      },
    );
  }
}
