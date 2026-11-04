import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'fish_glass.dart';

/// 等级卡（2026-09-25 UI 整改，替代黑金奢华卡）：
/// 克制地体现等级差异 —— 等级色浅底 + 细描边 + 等级图标 + 进度条，不用渐变/金色/光斑。
/// 升级阈值来自后台配置（LevelRulesStore），进度=累计消费/下一级阈值。
class LevelSummaryCard extends StatelessWidget {
  const LevelSummaryCard({super.key, required this.me, this.compact = false, this.onTap});

  final AuthMe me;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = levelStyleOf(me.level);
    final nextSpent = nextLevelSpentOf(me.level);
    final progress = nextSpent == null ? 1.0 : (me.totalSpent / nextSpent).clamp(0.0, 1.0);
    return FishGlassCard(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(compact ? AppSpacing.md : AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: compact ? 34 : 40,
                    height: compact ? 34 : 40,
                    decoration: BoxDecoration(
                      color: style.bg,
                      borderRadius: BorderRadius.circular(compact ? 10 : 12),
                      border: Border.all(color: style.color.withValues(alpha: 0.22), width: 1),
                    ),
                    child: AppIcon.of(style.icon, size: compact ? 17 : 20, color: style.color),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'L${me.level} ${style.label}',
                          style: TextStyle(fontSize: compact ? 14.5 : 15.5, fontWeight: FontWeight.w700, color: style.color),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          nextSpent == null
                              ? '已达最高等级，累计消费 ${fmtMoney(me.totalSpent)}'
                              : '距下一级还差 ${fmtMoney((nextSpent - me.totalSpent).clamp(0, nextSpent))}',
                          style: const TextStyle(fontSize: 12, color: AppColors.mutedText),
                        ),
                      ],
                    ),
                  ),
                  const AppIcon.of(AppIconsLegacy.chevron_right, size: 18, color: AppColors.textTertiary),
                ],
              ),
              if (!compact) ...[
                const SizedBox(height: AppSpacing.md),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: style.color.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation<Color>(style.color),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
