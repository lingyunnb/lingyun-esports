import 'dart:ui';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// FISH 老板端 · 页面壳（原名「液态玻璃」，类名保留、**玻璃绘制已下线**）
///
/// 负责人 2026-10-07 定案（B 方案：只去"看得见的玻璃"）：
/// 冷启动时那层「紫/粉/蓝洗过的液态玻璃渐变光斑底」在内容上来之前先糊一屏，看着像卡住 —— 去掉。
///
/// 现在的形态（**只改绘制内容，不改类名/构造签名/布局**）：
/// - [FishGlassBackdrop]：全局底色 = **实色**冷灰蓝 `AppColors.bgPage`（不再是 HyperOS 式光斑 + 线性渐变）
/// - [FishGlassPage]：页面骨架 = 实色底 + 白底顶栏 + 发丝线（[FishGlassPage.blurredTopBar] 语义保留）
/// - [FishGlassCard]：统一卡片（白底 + 发丝线 + 圆角 16）
///
/// 为什么**不改名也不删**：`FishGlass*` 是公开 API，老板端近 20 个页面 + 多个测试都在 import 它，
/// 改名会牵动所有调用点；本轮的目标恰恰是"一行调用点都不用改"。

/// 全局底色层（**实色**，套在 MaterialApp.builder）
///
/// 历史：这里曾画「浅色线性渐变 + 三处径向光斑」（液态玻璃需要彩色背景衬托磨砂）。
/// 现在渐变与光斑**全部移除** —— 玻璃主题也不再显示彩色光斑（负责人口径：
/// 设置里的主题选择保留，但玻璃主题不再有光斑）。
class FishGlassBackdrop extends StatelessWidget {
  const FishGlassBackdrop({super.key, required this.child});

  final Widget child;

  /// 全局底色（实色）= 设计 token 的冷灰蓝底纹
  ///
  /// 为什么**直接取 [AppColors.bgPage]** 而不是 `T.scaffoldColor`：玻璃主题
  /// (`kGlassTokens`) 的 `scaffold` 是 `Colors.transparent`（那是为"让光斑透出来"设计的），
  /// 光斑移除后透明底会直接露出引擎黑底。底纹必须与主题无关、恒为实色
  /// （docs/14 / docs/21：冷灰蓝底纹，值随 [AppColors.bgPage]，2026-10-14 起为 `#F4F6F9`）。
  static const Color baseColor = AppColors.bgPage;

  /// 实色底那一层的 Key（测试与出图据此断言"底色是实色、且底下没有第二层绘制"）
  static const Key solidLayerKey = Key('fish-glass-backdrop-solid');

  @override
  Widget build(BuildContext context) => ColoredBox(key: solidLayerKey, color: baseColor, child: child);
}

/// 主页面骨架：实色底 + 白底顶栏 + 发丝线（2026-10-04 起就是这套；本轮再把"光斑"字样去掉）
///
/// [blurredTopBar] **语义保留**（true = 走磨砂顶栏分支），但玻璃绘制/光斑已下线 ——
/// 近 20 个页面仍按原参数调用本类，**调用点一行未改**。
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
    // 2026-10-04 主题统一（负责人：所有 UI 复刻设计稿）：
    // 页壳不再用玻璃磨砂，统一为设计稿的「冷灰蓝底 + 白底顶栏 + 发丝线 + 20pt 加粗标题」
    final header = PreferredSize(
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
                                style: TextStyle(fontSize: 10.5, color: T.mutedText)),
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
    );

    return Scaffold(
      backgroundColor: T.scaffoldColor,
      appBar: header,
      floatingActionButton: floatingActionButton,
      body: body,
    );
  }

  // ignore: unused_element
  Widget _legacyBuild(BuildContext context) {
    if (!blurredTopBar) {
      return FishGlassBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(title),
            actions: actions,
            bottom: bottom,
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0x990E1226)
                : const Color(0x99FFFFFF),
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          floatingActionButton: floatingActionButton,
          body: body,
        ),
      );
    }
    return _legacyGlassBuild(context);
  }

  Widget _legacyGlassBuild(BuildContext context) {
    // 玻璃顶栏 + 内容分列（不用 MiuixScaffold：其 content padding 不含玻璃顶栏高度，会遮挡首行内容与点击）
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
                              child: const AppIcon.of(AppIconsLegacy.arrow_back),
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
              child: LayoutBuilder(
                builder: (context, c) {
                  final tabW = c.maxWidth / count;
                  return Stack(
                    children: [
                      // 白色药丸指示器（弹簧滑动）
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
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.25 : 0.9), width: 1),
                            boxShadow: dark
                                ? null
                                : [
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
      borderRadius: BorderRadius.circular(20),
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
              AppIcon.of(selected ? item.activeIcon : item.icon, size: 23, color: active),
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
            // 2026-10-04 主题统一：卡片对齐设计稿（白底 + 灰发丝线 + 圆角 16 + 轻阴影）
            color: dark ? const Color(0xE6202740) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: dark ? Colors.white24 : T.divider, width: 1),
            boxShadow: [
              BoxShadow(
                // 卡片投影的"墨色"用品牌锚 `AppColors.brandInk`（#0F2440），不再写死旧近黑 #0F172A
                color: (dark ? Colors.black : AppColors.brandInk).withValues(alpha: 0.05),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: child,
        );
        if (!glass) return card;
        // 液态玻璃主题：卡片背后内容实磨砂（+高光描边，玻璃质感）
        final glassCard = Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(color: const Color(0xFF27314B).withValues(alpha: 0.14), blurRadius: 22, offset: const Offset(0, 8)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
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
