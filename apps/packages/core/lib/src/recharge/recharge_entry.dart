import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_icon.dart';
import 'recharge_models.dart';

/// ============================================================================
/// 首页**充值入口** —— 独立、可整体替换的一个小 widget（负责人 2026-10-06）
/// ============================================================================
///
/// ## 为什么单独成件
/// 入口的形态经过设计审批（四宫格 / 顶部小入口 / 通栏条 / 余额胶囊 —— 四选一，
/// **定案 = C 套「导航下方通栏条」**）。因此这里把**渲染**与**位置**彻底分开：
/// - 本文件只负责"这一条长什么样"，是**唯一**要按定案改的地方；
/// - 放在首页的哪一行、上下留多少间距，由调用方（`services_page.dart`）决定；
/// - 是否出现由 [RechargeConfig.entryAvailable] 决定（没有可用收款码就不渲染入口）。
///
/// ## 当前实现（**已按设计稿定案**：C 套「导航下方通栏条」）
/// 逐项守 docs/21 与设计方实测值：
/// - 位置：**顶部导航之下、宣传图之前**，与导航**零间距、同宽**（导航底距设 0，见
///   `services_page.dart`）—— 负责人认可这是对 2026-10-05「宣传图通栏紧贴导航」的**有意修订**：
///   紧贴导航的变成这条充值入口，宣传图退到它下方。
/// - **实色**白底 + **发丝线**描边（`AppColors.divider`），**无渐变**、**无阴影**（阴影只给弹层）；
/// - 圆角 **6**（[radius]：与正下方「投诉/打赏/退款」三宫格同档 —— 分档 6 / 10 / 14 里的"块"档）；
/// - **高度 44**（[height]）：设计方实测 390dp 宽屏下 56dp 会把首屏最后一行小字挤出屏幕约 9dp，
///   44dp 把它从 **−9dp 拉回 +3dp**；
/// - 图标走 Flutter 内置 Material outlined（[AppIcon.coin]），**无 emoji**、无拟物、无插画；
/// - 主文案 14sp w600、副文案 11.5sp `AppColors.mutedText`（对比度 5.44:1）、右侧 16dp 箭头。
/// - **副文案选"缩短"而不是"允许 2 行"**：44dp 条内两行文字在 **1.3× 系统字号**下会撑破高度
///   （两行 ≈ 38.8dp 已逼近 44dp，再加内边距必溢出）→ 文案压到 ≤14 字
///   （[RechargeCopy.entrySubtitle]「扫码付款，审核后发放余额」12 字；1.3× 下约 179dp ≪ 可用 269dp），
///   并给两行写死行高（1.05 / 1.25）保证 1.3× 下总高 38.8dp 仍放得下。
///   证据：出图 `recharge_1b_entry_scale1_0.png` / `recharge_1c_entry_scale1_3.png` + 测试断言
///   `RenderParagraph.didExceedMaxLines == false`（1.0× 与 1.3× 两档分别断言）。
/// - 与「购买提示小字」分工明确：**提示字在商品卡底部**（讲一件商品的限购/提示），
///   这里是**首页唯一的充值入口**（讲"钱怎么变成余额"），两处不重复、不抢位。
class RechargeEntry extends StatelessWidget {
  const RechargeEntry({
    super.key,
    required this.onTap,
    this.title = RechargeCopy.entryTitle,
    this.subtitle = RechargeCopy.entrySubtitle,
  });

  /// 点击进充值页
  final VoidCallback onTap;

  /// 主文案（默认「充值」）
  final String title;

  /// 副文案（默认 12 字，讲清"扫码付款 → 上传截图 → 超管审核发放"，**不承诺即时到账**）
  final String subtitle;

  /// 测试/调用方定位用（首页断言"有入口"时按它找）
  static const Key entryKey = Key('recharge-entry');

  // ---- 版式硬参数（测试断言与出图共用同一份数字；均为设计方审批实测值）----
  /// 圆角：块档 6（与三宫格同档；分档 6 / 10 / 14）
  static const double radius = 6;

  /// 整行高度（44 = 把首屏余量从 −9dp 拉回 +3dp 的审批值）
  static const double height = 44;

  /// 图标容器尺寸与圆角
  static const double iconBox = 30;
  static const double iconBoxRadius = 6;

  /// **无渐变**（docs/21 禁"渐变做主视觉"；这里连小面积渐变都不用）
  static const bool usesGradient = false;

  /// **无阴影**（docs/21：阴影只给弹层）
  static const bool usesShadow = false;

  /// 背景/描边取值（实色 + 发丝线）
  static const Color background = Colors.white;
  static const Color border = AppColors.divider;

  /// 文字与图标尺寸（两行**写死行高** → 1.3× 系统字号下总高可控，不撑破 44dp）
  static const double titleSize = 14;
  static const double subtitleSize = 11.5;
  static const double titleLineHeight = 1.05;
  static const double subtitleLineHeight = 1.25;
  static const double iconSize = 15;
  static const double chevronSize = 16;

  /// 副文案字数上限（设计方给的可读上限：1.3× 下 ≤14 字才不会截断）
  static const int subtitleMaxChars = 14;

  /// 一行**户外**（首屏最上方）放置时的外间距（左右 16 = `AppSpacing.page`）
  static const EdgeInsets pageInsets = EdgeInsets.symmetric(horizontal: AppSpacing.page);

  /// emoji 检测（docs/21 禁 emoji 当图标）：命中任意 emoji 码点段即视为"有 emoji"
  ///
  /// 放在这里是为了让**测试与实现共用同一份判定**（不是测试里另写一套正则）。
  static bool containsEmoji(String text) {
    for (final r in text.runes) {
      if (r >= 0x1F000 && r <= 0x1FAFF) return true; // 各类 emoji / 表情 / 旗帜
      if (r >= 0x2600 && r <= 0x27BF) return true; // 杂项符号与装饰符号
      if (r == 0xFE0F) return true; // 变体选择符（emoji 表示）
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: pageInsets,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          key: entryKey,
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: Container(
            height: height,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: border),
            ),
            child: Row(
              children: [
                Container(
                  width: iconBox,
                  height: iconBox,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.ice,
                    borderRadius: BorderRadius.circular(iconBoxRadius),
                  ),
                  child: const AppIcon.of(AppIcon.coin, size: iconSize, color: AppColors.primary),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: titleSize,
                          height: titleLineHeight,
                          fontWeight: FontWeight.w600,
                          color: T.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: subtitleSize,
                          height: subtitleLineHeight,
                          color: AppColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AppIcon.of(AppIcon.chevronRight, size: chevronSize, color: T.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
