import 'package:flutter/material.dart';
import '../widgets/app_motion.dart';

import 'app_colors.dart';
import 'theme_tokens.dart';

/// 动画时长（docs/15：200~300ms，服务于理解状态变化）
class AppDurations {
  AppDurations._();

  static const Duration fast = Duration(milliseconds: 200);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 300);
}

/// 圆角（docs/14：卡片 12、按钮 8、图片 8）
class AppRadii {
  AppRadii._();

  static const double card = 12;
  static const double control = 8;
}

/// 全局浅色主题：白色、简洁、克制（docs/14 禁止电竞风装饰）
ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      surface: AppColors.bgCard,
    ),
    scaffoldBackgroundColor: AppColors.bgPage,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bgCard,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.bgCard,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.card)),
      margin: EdgeInsets.zero,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
  );
}

/// 全局液态玻璃主题（负责人主题系统需求，仅老板端使用）：
/// 半透明表面 + 圆角放大 + 柔和阴影 + 玻璃化全部 Material 组件（导航/弹窗/输入/按钮/Tab/底表/提示条）
ThemeData buildGlassTheme() {
  const t = kGlassTokens;
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.primary,
      primary: t.primary,
      secondary: t.primarySecondary,
      surface: t.glassCardTint,
      onSurface: t.textPrimary,
      outline: t.divider,
    ),
    // 透明基底：背景光晕层从根部透出（GlassBackdrop）
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
    ),
    cardTheme: CardThemeData(
      color: t.glassCardTint,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: t.glassShadowColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusCard),
        side: BorderSide(color: t.glassBorder),
      ),
      margin: EdgeInsets.zero,
    ),
    // 玻璃悬浮底部导航（底色由 HomeShell 玻璃容器提供，这里保持透明避免叠色）
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      indicatorColor: t.primary.withValues(alpha: 0.16),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? t.primary : t.textSecondary,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? t.primary : t.textTertiary,
        ),
      ),
    ),
    // 玻璃弹窗
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xE6FFFFFF),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: t.glassShadowColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radiusDialog),
        side: BorderSide(color: t.glassBorder),
      ),
      titleTextStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
      contentTextStyle: const TextStyle(fontSize: 14.5, height: 1.5, color: AppColors.textSecondary),
    ),
    // 玻璃底表
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: const Color(0xF2FFFFFF),
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: const Color(0xF2FFFFFF),
      modalBarrierColor: const Color(0x3327314B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        side: BorderSide(color: Color(0x80FFFFFF)),
      ),
    ),
    // 玻璃输入框（圆角填充 + 聚焦主色描边）
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x8FFFFFFF),
      hintStyle: TextStyle(fontSize: 14, color: t.textTertiary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(t.radiusControl), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(t.radiusControl),
        borderSide: BorderSide(color: t.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(t.radiusControl),
        borderSide: BorderSide(color: t.primary, width: 1.3),
      ),
    ),
    // 玻璃提示条（深色玻璃，文字清晰）
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xD91B2233),
      contentTextStyle: const TextStyle(fontSize: 14, color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: t.glassBorder),
      ),
    ),
    // 玻璃 Tab
    tabBarTheme: TabBarThemeData(
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      indicator: BoxDecoration(
        color: t.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
      unselectedLabelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: t.textSecondary),
    ),
    // 玻璃按钮族
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusControl)),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.primary,
        side: BorderSide(color: t.primary.withValues(alpha: 0.45)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radiusControl)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: t.primary),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.primary),
    dividerTheme: DividerThemeData(color: t.divider, thickness: 1, space: 1),
    chipTheme: ChipThemeData(
      backgroundColor: t.glassCardTint,
      side: BorderSide(color: t.glassBorder),
      labelStyle: TextStyle(fontSize: 12, color: t.textSecondary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.textSecondary,
      textColor: t.textPrimary,
    ),
    // 顶级开源过渡动效（Material Motion 共享轴：位移 + 淡入，全平台统一）
    // 素材与规范来源：Material Motion（Google, Apache-2.0）+ flutter/packages animations（BSD-3）
    pageTransitionsTheme: const _AppPageTransitions(),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
  );
}


/// 全局页面转场（Material Motion「共享轴 X」：新页横向 8% 位移 + 淡入，旧页轻微淡出）
///
/// 三端所有 Navigator.push 自动生效，无需逐页改造；时长 300ms / 返回 250ms
/// （Material Motion 结论：短而连续的动效比长动效"更快"）。
class _AppPageTransitions extends PageTransitionsTheme {
  const _AppPageTransitions();

  @override
  Map<TargetPlatform, PageTransitionsBuilder> get builders => const {
        TargetPlatform.android: _SharedAxisBuilder(),
        TargetPlatform.iOS: _SharedAxisBuilder(),
        TargetPlatform.windows: _SharedAxisBuilder(),
        TargetPlatform.macOS: _SharedAxisBuilder(),
        TargetPlatform.linux: _SharedAxisBuilder(),
        TargetPlatform.fuchsia: _SharedAxisBuilder(),
      };
}

class _SharedAxisBuilder extends PageTransitionsBuilder {
  const _SharedAxisBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Motion.emphasized, reverseCurve: Motion.emphasizedAccel);
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero).animate(curved),
      child: FadeTransition(opacity: Tween<double>(begin: 0, end: 1).animate(curved), child: child),
    );
  }
}
