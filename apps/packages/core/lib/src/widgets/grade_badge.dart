/// 打手等级徽章（三处共用**同一份**图标映射与墨色口径）
///
/// ## 为什么收在一个文件里
/// 等级徽章要出现在**三个地方**（找陪玩列表卡 / 陪玩主页 / 打手态「我的」），
/// 而"1–5 档各用哪枚图标、什么墨色"只允许有**一份**定义 —— 否则三处各自演化，
/// 同一个 LV3 在不同页面长成两个样子。所以：
/// - 图标映射：[gradeBadgeIcon]（唯一）
/// - 墨色：[gradeInk]（唯一）
/// - 画法（图标 + 文案一行）：[WorkerGradeBadge]（唯一）
///
/// ## 图标来源（零依赖）
/// 五枚徽章由 `scripts/tmp/gen-app-icons.mjs` 从 `site/design/color-graphics/assets/grade/*.svg`
/// 编译进 [AppIcons]（`grade1`–`grade5`，Tabler filled）→ 运行时走 `AppIcon` 的
/// `CustomPainter`，**不引 flutter_svg、不吃字体、不打资源包**。
///
/// ## 颜色口径（负责人 2026-10-17；4–5 档按 accessibility 裁决改深金）
/// | 等级 | 墨色 | 理由 |
/// |---|---|---|
/// | LV1–LV2 | `T.textSecondary` | 起步档不该抢眼，弱化到正文同色 |
/// | LV3 | `AppColors.goldText` | 金色开始"值得看"，但用深金保证白底可读 |
/// | LV4–LV5 | `AppColors.goldText` | **徽章旁是 11px 文字**，裸 `gold`（#F59E0B）白底只有 2.15:1 读不清；统一用深金 `goldText`（#935F06，白底 5.41:1，AA 达标），**图标与文字同色更整齐**。视觉上仍是金，只是这一档金压暗了一级 |
///
/// 也就是说：**两个金色档位（3 档与 4–5 档）用的是同一个 `goldText`**，
/// 差别靠徽章图标本身（award / trophy / diamond）与文字区分 —— 小字一律不碰裸 `gold`，
/// 与 `money_gold_guard_test` 的"两档金"红线一致（本文件因此**不再出现**裸 `gold`）。
///
/// **零硬编码色值**（全走 token）、**零渐变**、**零 emoji**。
library;

import 'package:flutter/material.dart';

import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';

/// 等级 → 徽章图标（**唯一映射**）
///
/// 1 初出 → circle-dot · 2 立足 → star · 3 扬名 → award · 4 称雄 → trophy · 5 宗师 → diamond
/// 越界档位回落到 5 档（与后端"非法档位回落"同一防御口径，展示路径不抛错）。
AppIcons gradeBadgeIcon(int grade) {
  switch (grade) {
    case 1:
      return AppIcons.grade1;
    case 2:
      return AppIcons.grade2;
    case 3:
      return AppIcons.grade3;
    case 4:
      return AppIcons.grade4;
    default:
      return AppIcons.grade5;
  }
}

/// 等级 → 五档配色三元组（**唯一口径**）
///
/// 负责人 2026-10-18：「打手的等级太朴素了弄好看点」→ 从"单色图标 + 文字"
/// 升级为**胶囊片（淡底）+ 同色系图标 + 深色文字**，五档各一套色系（灰/青/蓝/紫/金），
/// 让人在列表里扫一眼就能分出高低。色值全部落在 `app_colors.dart`（本文件零硬编码色值）。
///
/// 返回 `(bg, ink, border)`：`border` 仅 LV5 有值（最高档加一层细描边形成层级差），其余为 null。
({Color bg, Color ink, Color? border}) gradePalette(int grade) {
  switch (grade < 1 ? 1 : (grade > 5 ? 5 : grade)) {
    case 1:
      return (bg: AppColors.grade1Bg, ink: AppColors.grade1Ink, border: null);
    case 2:
      return (bg: AppColors.grade2Bg, ink: AppColors.grade2Ink, border: null);
    case 3:
      return (bg: AppColors.grade3Bg, ink: AppColors.grade3Ink, border: null);
    case 4:
      return (bg: AppColors.grade4Bg, ink: AppColors.grade4Ink, border: null);
    default:
      return (bg: AppColors.grade5Bg, ink: AppColors.grade5Ink, border: AppColors.grade5Border);
  }
}

/// 等级 → 图标色（与 [gradePalette] 的 bg/ink 同色系，但更亮一档，让图标在淡底上跳出来）
Color gradeIconInk(int grade) {
  switch (grade < 1 ? 1 : (grade > 5 ? 5 : grade)) {
    case 1:
      return AppColors.grade1Icon;
    case 2:
      return AppColors.grade2Icon;
    case 3:
      return AppColors.grade3Icon;
    case 4:
      return AppColors.grade4Icon;
    default:
      return AppColors.grade5Icon;
  }
}

/// 等级 → 墨色（**保留的旧口径**，供纯文字场景用）：3 档与 4–5 档都是 `goldText`
///
/// ⚠️ 徽章本体已改用 [gradePalette]；这个函数留着是因为 `money_gold_guard_test`
/// 的白名单按它登记"裸 gold 出现位置"，删掉会连带改那张表（无收益）。
Color gradeInk(int grade) {
  final g = grade < 1 ? 1 : (grade > 5 ? 5 : grade);
  if (g <= 2) return T.textSecondary;
  return AppColors.goldText;
}

/// 等级徽章：一枚 [AppIcons] 徽章 +（可选）等级文案，横排一行
///
/// 用法（三处各自的尺寸口径）：
/// ```dart
/// WorkerGradeBadge(grade: 3, size: 16, label: '扬名', labelSize: 11)      // 列表卡
/// WorkerGradeBadge(grade: 3, size: 24, label: 'LV3 扬名', labelSize: 12)  // 主页 / 我的等级卡
/// ```
///
/// 文案为空时只画徽章（服务端没下发 `gradeLabel/gradeName` 时不会出现"孤零零的空白格"）。
class WorkerGradeBadge extends StatelessWidget {
  const WorkerGradeBadge({
    super.key,
    required this.grade,
    this.size = 16,
    this.label = '',
    this.labelSize = 11,
  });

  /// 1–5（越界按 [gradeBadgeIcon] 的防御规则处理）
  final int grade;

  /// 徽章边长（dp）：列表 16 / 主页与「我的等级」卡 24
  final double size;

  /// 等级文案（`扬名` 或 `LV3 扬名`），空串则不画文字
  final String label;

  /// 文案字号（列表 11 / 其余 12–13）
  final double labelSize;

  /// 徽章与文案的间距（4dp 网格的最小档）
  static const double gap = 4;

  @override
  Widget build(BuildContext context) {
    final p = gradePalette(grade);
    final text = label.trim();
    // 高度跟着 size 走：16dp 图标 → 20dp 片高；24dp → 28dp
    final h = size + 4;
    return Container(
      height: h,
      padding: EdgeInsets.only(left: 4, right: text.isEmpty ? 4 : 6),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(999),
        // LV5 唯一的细描边：最高档要有"多一层"的视觉重量
        border: p.border == null ? null : Border.all(color: p.border!, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(gradeBadgeIcon(grade), size: size * 0.72, color: gradeIconInk(grade)),
          if (text.isNotEmpty) ...[
            const SizedBox(width: gap),
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: labelSize,
                fontWeight: FontWeight.w700,
                color: p.ink,
                height: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
