import 'package:flutter/material.dart';

import '../icons/app_icon.dart';
import '../theme/app_colors.dart';

/// 通用空态（**方案 G 视觉版**，负责人 2026-10-17 定案）
///
/// ## 为什么是"新类"而不是改旧类
/// 全 App 原来共用的空态是 `AppEmpty`（`src/widgets/app_ui.dart`，与 `AppButton/AppTag/
/// `AppCard/AppPrice/AppSectionHeader` 同文件）—— 那是**公共组件，本轮不允许改动**。
/// 所以本文件新增 [AppEmptyState]：**旧 `AppEmpty` 一行未动**，因此
/// **既有调用点的渲染逐像素不变**（没有新增影子组件、没有替换实现），
/// 需要 G 视觉的页面显式改用本组件即可。
///
/// ## 参数向后兼容
/// 构造参数是 `AppEmpty` 的**严格超集**，语义与默认值一一对齐：
/// - `icon` / `text` / `action` / `onAction` —— 名字、类型、必填性与 `AppEmpty` 完全一致；
/// - 其余全部是**可选具名参数且带默认值**（`iconSize=48`、`textSize=13`…），
///   不传就得到本文件定义的 G 视觉，传了才覆盖 —— 不存在"同一个参数两种含义"。
/// 因此从 `AppEmpty` 换到本组件是**纯加法**：不会出现"行为随调用点漂移"。
///
/// ## 视觉（方案 G 原文）
/// - 图标 **48dp**，弱色（`#8A99AB`）线性描边 —— 不用彩色、不用 emoji、不用插画；
/// - 说明文字 **13sp**，次要色（`#4A5A6E`），居中、最多两行；
/// - 主动作 **蓝底白字**（`#2563EB`，纯实色 —— 不是渐变，docs/21 禁渐变做主视觉）；
/// - 圆角只用分档值：按钮 999（胶囊）、无卡片容器。
///
/// 用法：
/// ```dart
/// AppEmptyState(
///   icon: AppIcon.orders,
///   text: '还没有订单，去看看有哪些单',
///   action: '去下单',
///   onAction: () => ...,
/// )
/// ```
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
    this.iconSize = 48,
    this.iconColor,
    this.textSize = 13,
    this.textColor,
    this.iconTextGap = 14,
    this.actionGap = 18,
    this.actionHeight = 38,
    this.actionMinWidth = 120,
  });

  /// 图标（沿用旧 `IconData` 语义别名，如 `AppIcon.orders`；与 `AppEmpty.icon` 同一个值域）
  final IconData icon;

  /// 中文说明（一句具体的话，不写"暂无数据"这类空话）
  final String text;

  /// 主动作文案；`null` = 不渲染按钮（与 `AppEmpty` 同一口径）
  final String? action;

  /// 主动作回调（`action` 非空但这里是 `null` → 按钮呈禁用态，不静默消失）
  final VoidCallback? onAction;

  /// 外层内边距（默认上下 44 / 左右 24：列表内可直接当一项塞进去）
  final EdgeInsetsGeometry padding;

  /// 图标边长，默认 48（方法见类文档）
  final double iconSize;

  /// 图标色；默认弱色 `AppColors.statusMuted`（= `#8A99AB`）
  final Color? iconColor;

  /// 说明文字字号，默认 13
  final double textSize;

  /// 说明文字色；默认次要色 `AppColors.textSecondary`（= `#4A5A6E`）
  final Color? textColor;

  /// 图标与文字的间距，默认 14
  final double iconTextGap;

  /// 文字与按钮的间距，默认 18
  final double actionGap;

  /// 按钮高度，默认 38（列表内嵌也不显得笨重）
  final double actionHeight;

  /// 按钮最小宽度，默认 120
  final double actionMinWidth;

  @override
  Widget build(BuildContext context) {
    final actionLabel = action;
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 48dp 线性图标 + 弱色：装饰层，不参与对比度门槛（docs/21）
          AppIcon.of(icon, size: iconSize, color: iconColor ?? AppColors.statusMuted),
          SizedBox(height: iconTextGap),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: textSize,
              height: 1.5,
              color: textColor ?? AppColors.textSecondary,
            ),
          ),
          if (actionLabel != null) ...[
            SizedBox(height: actionGap),
            _PrimaryPill(
              label: actionLabel,
              onPressed: onAction,
              height: actionHeight,
              minWidth: actionMinWidth,
            ),
          ],
        ],
      ),
    );
  }
}

/// 主按钮（蓝底白字胶囊）—— 只在空态里用，实色无渐变、无阴影
class _PrimaryPill extends StatelessWidget {
  const _PrimaryPill({
    required this.label,
    required this.onPressed,
    required this.height,
    required this.minWidth,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final radius = BorderRadius.circular(999);
    return Opacity(
      opacity: disabled ? .5 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onPressed,
          child: Container(
            height: height,
            constraints: BoxConstraints(minWidth: minWidth),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.primary, borderRadius: radius),
            child: Text(
              label,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
