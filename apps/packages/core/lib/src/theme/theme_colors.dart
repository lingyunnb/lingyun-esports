import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'theme_controller.dart';

/// 主题色门面（T = Theme）：页面取色统一走这里，随主题实时切换。
/// 初始主题下所有取值与既有 AppColors 完全一致（视觉零变化）；
/// 已适配主题的页面/组件在液态玻璃主题下自动获得玻璃配色。
/// 注意：门面是 getter，不能用于 const 表达式；静态不变的值（如品牌纯色）继续用 AppColors。
class T {
  T._();

  static Color get primary => ThemeController.instance.tokens.primary;
  static Color get primarySecondary => ThemeController.instance.tokens.primarySecondary;
  static Color get bgPage => ThemeController.instance.tokens.bgPage;
  static Color get bgCard => ThemeController.instance.tokens.bgCard;
  static Color get scaffoldColor => ThemeController.instance.tokens.scaffold;
  static Color get bgCardSolid => ThemeController.instance.tokens.bgCardSolid;
  static Color get textPrimary => ThemeController.instance.tokens.textPrimary;
  static Color get textSecondary => ThemeController.instance.tokens.textSecondary;
  static Color get textTertiary => ThemeController.instance.tokens.textTertiary;

  /// 白/浅底上的**说明文字/副标题**（对比度 5.44:1，达 WCAG AA 正文）
  ///
  /// 与 [gold] / [ice] / [primarySoft] 同属**品牌扩展色**：两套主题共用同一取值
  /// （classic 与 glass 的页面底色都是浅色，说明文字不需要随材质变化）。
  /// 用途边界：**文字**；图标 / 发丝线 / 禁用态 / 输入提示仍走 [textTertiary]。
  static Color get mutedText => AppColors.mutedText;
  static Color get divider => ThemeController.instance.tokens.divider;
  static Color get success => ThemeController.instance.tokens.success;
  static Color get warning => ThemeController.instance.tokens.warning;
  static Color get error => ThemeController.instance.tokens.error;
  static double get radiusCard => ThemeController.instance.tokens.radiusCard;
  static double get radiusControl => ThemeController.instance.tokens.radiusControl;
  static double get radiusDialog => ThemeController.instance.tokens.radiusDialog;
  static bool get isGlass => ThemeController.instance.isGlass;

  /// 是否启用品牌渐变（主按钮/横幅/头像/浮标）
  static bool get gradientEnabled => ThemeController.instance.tokens.gradientEnabled;

  // ---- 品牌扩展色（docs/21：价格用琥珀金、浅底/冰蓝统一走这里）----
  static Color get gold => AppColors.gold;

  /// **[小字金]** —— `<19px` 或字重 `< w700` 的一切"金"字 / 金图标（单位、次要金额、标签）
  ///
  /// 两档金的分工（2026-10-16 负责人拍板）：
  /// - [gold] `#F59E0B`：**大号金额**（≥19px 且 w700+），白底 2.15:1 是 F 的设计意图，保留；
  /// - [goldText] `#935F06`：**小字**，白底 5.41:1 / `#EFF6FF` 4.97:1 / `#FEF3C7` 4.86:1。
  ///
  /// [AppMoney] / [AppPrice] 已**按字号自动选档**，调用点传不传色都不会踩坑；
  /// 源码级红线见 `core/test/money_gold_guard_test.dart`。
  static Color get goldText => AppColors.goldText;

  static Color get goldSoft => AppColors.goldSoft;
  static Color get ice => AppColors.ice;
  static Color get primarySoft => AppColors.primarySoft;

  /// 品牌渐变（青蓝）；gradientEnabled=false 时退化为纯主色，保证视觉可用
  static LinearGradient get brandGradient => AppColors.brandGradient;

  /// 页面顶部冰蓝渐隐
  static LinearGradient get iceFade => AppColors.iceFade;

  /// 深色权益卡渐变
  static LinearGradient get deepGradient => AppColors.deepGradient;
}
