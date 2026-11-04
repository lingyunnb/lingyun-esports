import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 主题 Token（负责人需求：统一管理颜色/圆角/玻璃参数，新主题只需新增一份 Token 实例）
/// 初始主题 kClassicTokens 与现有 AppColors 完全一致，保证切换回初始主题视觉零变化。
class ThemeTokens {
  const ThemeTokens({
    required this.primary,
    required this.primarySecondary,
    required this.bgPage,
    required this.bgCard,
    required this.scaffold,
    required this.bgCardSolid,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.divider,
    required this.success,
    required this.warning,
    required this.error,
    required this.radiusCard,
    required this.radiusControl,
    required this.radiusDialog,
    // ---- 玻璃参数（classic 模式不使用，取值无影响） ----
    this.glassEnabled = false,
    this.glassCardTint = const Color(0x99FFFFFF),
    this.glassBorder = const Color(0x66FFFFFF),
    this.glassHighlight = const Color(0xB3FFFFFF),
    this.glassBlurSigma = 14.0,
    this.glassShadowColor = const Color(0x1A27314B),
    this.gradientEnabled = true,
  });

  // 颜色
  final Color primary;
  final Color primarySecondary;
  final Color bgPage;
  final Color bgCard;

  /// Scaffold 底色：classic=bgPage；glass=透明（背景光晕层透出）
  final Color scaffold;

  /// 不透明表面色（列表项等高频场景使用，避免大量模糊，性能守卫）
  final Color bgCardSolid;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color divider;
  final Color success;
  final Color warning;
  final Color error;

  // 圆角
  final double radiusCard;
  final double radiusControl;
  final double radiusDialog;

  // 玻璃
  final bool glassEnabled;

  /// 玻璃卡片底色（半透明白）
  final Color glassCardTint;

  /// 玻璃边缘高光描边
  final Color glassBorder;

  /// 玻璃顶部高光
  final Color glassHighlight;

  /// 背景模糊强度
  final double glassBlurSigma;

  /// 玻璃投影色
  final Color glassShadowColor;

  /// 是否启用品牌渐变（主按钮/横幅/头像/浮标；两套主题都开，玻璃主题同样使用）
  final bool gradientEnabled;

  /// 当前是否玻璃主题
  bool get isGlass => glassEnabled;
}

/// 初始主题 Token（2026-10-03 起 = 最终设计稿 I 系列基线：青蓝渐变 + 卡片 + 彩色标签）
const ThemeTokens kClassicTokens = ThemeTokens(
  primary: AppColors.primary,
  primarySecondary: AppColors.primarySecondary,
  bgPage: AppColors.bgPage,
  bgCard: AppColors.bgCard,
  scaffold: AppColors.bgPage,
  bgCardSolid: AppColors.bgCard,
  textPrimary: AppColors.textPrimary,
  textSecondary: AppColors.textSecondary,
  textTertiary: AppColors.textTertiary,
  divider: AppColors.divider,
  success: AppColors.success,
  warning: AppColors.warning,
  error: AppColors.error,
  radiusCard: 16,
  radiusControl: 10,
  radiusDialog: 20,
  gradientEnabled: true,
);

/// 液态玻璃主题 Token：半透明材质 + 边缘高光 + 背景光晕，通透轻盈
/// （2026-10-03：配色与初始主题一致，差异只在"材质"——磨砂/透明/光斑）
const ThemeTokens kGlassTokens = ThemeTokens(
  primary: AppColors.primary,
  primarySecondary: AppColors.primarySecondary,
  // 冷调浅底：让玻璃白卡与光晕更有层次
  bgPage: Color(0xFFEDF1F7),
  bgCard: Color(0xB3FFFFFF),
  scaffold: Colors.transparent,
  bgCardSolid: Color(0xE6FFFFFF),
  textPrimary: AppColors.textPrimary,
  textSecondary: AppColors.textSecondary,
  textTertiary: AppColors.textTertiary,
  divider: Color(0x1A0F172A),
  success: AppColors.success,
  warning: AppColors.warning,
  error: AppColors.error,
  radiusCard: 16,
  radiusControl: 12,
  radiusDialog: 24,
  gradientEnabled: true,
  glassEnabled: true,
  glassCardTint: Color(0x8CFFFFFF),
  glassBorder: Color(0x59FFFFFF),
  glassHighlight: Color(0xC7FFFFFF),
  glassBlurSigma: 14.0,
  glassShadowColor: Color(0x1F27314B),
);
