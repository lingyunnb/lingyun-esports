import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/feature_hues.dart';
import 'app_icon.dart';

/// **双色实底图标块**（方案 F 的招牌：「渐变圆角方块 + 白色镂空图标」）
///
/// 出处：`site/design/color-graphics/planF.html`
/// - 列表行/卡片上的 `.rc`：`border-radius:11~16px` + `linear-gradient(135deg,A,B)` + 白色 mask 图标
/// - 底栏选中态 `.bnav .it.on .nib`：`26×26; radius:9; linear-gradient(135deg,#2563EB,#06B6D4);
///   box-shadow:0 5px 11px rgba(37,99,235,.35)`；未选中是 `26×26; radius:9; background:#EEF2F7`
///
/// 用法：
/// ```dart
/// AppIconTile(icon: AppIcon.wallet, size: 32)                       // 32×32 渐变方块 + 白图标（资金默认橙金）
/// AppIconTile(icon: AppIcon.headset, size: 38, feature: AppFeature.support)
/// AppIconTile.plain(icon: AppIcon.services, size: 22)               // 未选中：浅底 + 冷灰图标
/// ```
///
/// ## 兼容
/// 内部走 [AppIcon.of]（迁移入口），因此**镜像 Icon 仍然存在** ——
/// `find.byIcon(旧 IconData)` / `find.byType(Icon)` 计数 / `getRect` / `widget<Icon>.size|color`
/// 在换成方块底之后依旧成立（[color] 会被镜像继承，所以断言读到的是同一个值）。
class AppIconTile extends StatelessWidget {
  /// 实底（渐变 + 白色图标）—— 选中态 / 强调位
  const AppIconTile({
    super.key,
    required this.icon,
    this.size = 34,
    this.glyphSize,
    this.radius,
    this.feature,
    this.shadow = false,
  })  : plain = false,
        glyphColor = Colors.white;

  /// 素底（浅底 + 冷灰图标）—— 未选中态（planF `.nib` 未选中：`#EEF2F7` + `#64748B`）
  const AppIconTile.plain({
    super.key,
    required this.icon,
    this.size = 26,
    this.glyphSize,
    this.radius,
    this.feature,
    this.shadow = false,
  })  : plain = true,
        glyphColor = const Color(0xFF64748B);

  /// 旧 `IconData`（`AppIcon.x` / `AppIconsLegacy.x`）—— [AppIcon.of] 会解析成新几何
  final IconData icon;

  /// 方块边长（dp）
  final double size;

  /// 图标边长（dp）；缺省 = `size * 0.5`（planF 实测比例：34→17、38→19 都是 0.5）
  final double? glyphSize;

  /// 圆角；缺省 = `size * 0.34`（34→11.6 ≈ planF 的 11；26→8.8 ≈ planF 的 9）
  final double? radius;

  /// 功能区色相（缺省时由 [featureOfIcon] 从 [icon] 推）—— **"同功能同色"的唯一入口**
  final AppFeature? feature;

  /// 素底模式（不画渐变，只画浅底 + 冷灰图标）
  final bool plain;

  /// 是否加彩色柔和阴影（planF：只给底栏选中 nib 与主 C 位）
  final bool shadow;

  /// 图标颜色（实底=白、素底=冷灰）
  final Color glyphColor;

  AppFeature get _feature => feature ?? featureOfIcon(icon);

  @override
  Widget build(BuildContext context) {
    final r = radius ?? size * 0.34;
    final g = glyphSize ?? size * 0.5;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: plain ? AppColors.placeholderBg : null,
        gradient: plain ? null : featureGradient(_feature),
        borderRadius: BorderRadius.circular(r),
        boxShadow: shadow && !plain ? featureShadow(_feature) : null,
      ),
      child: AppIcon.of(icon, size: g, color: glyphColor),
    );
  }
}

/// 底栏/列表行通用的一小块：**选中 = 品牌渐变方块 + 白图标；未选中 = 浅底 + 冷灰图标**
///
/// 单独抽出来是因为底栏有**两处**实现（`AppPlainBottomNav` 与 `AppBottomNav` 的非中间位），
/// 「同功能同色」要求它们在同一个状态下取**同一个色**（都是 [AppFeature.brand] 的品牌渐变）。
class AppTabGlyph extends StatelessWidget {
  const AppTabGlyph({
    super.key,
    required this.icon,
    required this.selected,
    this.size = 22,
    this.glyphSize = 15,
  });

  final IconData icon;
  final bool selected;
  final double size;
  final double glyphSize;

  @override
  Widget build(BuildContext context) => selected
      ? AppIconTile(
          icon: icon,
          size: size,
          radius: 8,
          glyphSize: glyphSize,
          feature: AppFeature.brand,
          shadow: true,
        )
      : AppIconTile.plain(
          icon: icon,
          size: size,
          radius: 8,
          glyphSize: glyphSize,
        );
}
