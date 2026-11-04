import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';
import '../widgets/level_summary_card.dart';

/// 会员中心（2026-09-25 UI 整改：去掉黑金渐变卡，改克制等级卡）：
/// 当前等级卡（等级色浅底+进度）+ 5 级体系总览（阈值来自后台配置/解锁状态）+ 会员权益
class MembershipPage extends StatelessWidget {
  const MembershipPage({super.key});

  @override
  Widget build(BuildContext context) {
    return FishGlassPage(
      title: '会员中心',
      body: AnimatedBuilder(
        animation: AuthStore.instance,
        builder: (context, _) {
          final me = AuthStore.instance.me;
          if (me == null) {
            return const Center(child: Text('加载中…', style: TextStyle(color: AppColors.mutedText)));
          }
          final style = levelStyleOf(me.level);
          final nextSpent = nextLevelSpentOf(me.level);
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _buildCurrentCard(me, style, nextSpent),
              const SizedBox(height: AppSpacing.lg),
              _buildSectionTitle('会员等级'),
              const SizedBox(height: AppSpacing.md),
              _buildLevelList(me.level),
              const SizedBox(height: AppSpacing.lg),
              _buildSectionTitle('会员权益'),
              const SizedBox(height: AppSpacing.md),
              _buildBenefits(),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  /// 当前等级卡（克制配色+进度，与"我的"页统一，2026-09-25）
  Widget _buildCurrentCard(AuthMe me, LevelStyle style, int? nextSpent) {
    return LevelSummaryCard(me: me);
  }

  Widget _buildSectionTitle(String title) => Row(
        children: [
          Container(
            width: 3.5,
            height: 15,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [AppColors.primary, AppColors.primarySecondary]),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
        ],
      );

  /// 5 级体系总览：每级渐变卡片 + 阈值 + 解锁状态
  Widget _buildLevelList(int current) {
    return FishGlassCard(
      insideMargin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (int i = 0; i < kLevelStyles.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 72, endIndent: 16, color: T.divider),
            _levelRow(i + 1, kLevelStyles[i], current),
          ],
        ],
      ),
    );
  }

  Widget _levelRow(int level, LevelStyle style, int current) {
    final unlocked = level <= current;
    final isCurrent = level == current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 12),
      child: Row(
        children: [
          // 等级圆标
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: unlocked ? style.gradient : [AppColors.divider, AppColors.divider],
              ),
              shape: BoxShape.circle,
              border: unlocked
                  // 等级位 = 全站"金"的合法落点之一 → 收敛到唯一金 token（方案 F 橙金）
                  ? Border.all(color: AppColors.gold.withValues(alpha: 0.7), width: 1.2)
                  : null,
            ),
            child: Icon(
              unlocked ? style.icon : AppIconsLegacy.lock_outline,
              size: 19,
              color: unlocked ? Colors.white : AppColors.textTertiary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'L$level ${style.label}',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: unlocked ? style.color : AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (isCurrent)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: style.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: style.color.withValues(alpha: 0.3)),
                        ),
                        child: Text('当前等级', style: TextStyle(fontSize: 10, color: style.color, fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  level == 1 ? '注册即享' : '累计消费满 ${fmtMoney(nextLevelSpentOf(level - 1) ?? 0)}',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                ),
              ],
            ),
          ),
          Text(
            unlocked ? (isCurrent ? '已解锁' : '已达成') : '未解锁',
            style: TextStyle(
              fontSize: 12,
              fontWeight: unlocked ? FontWeight.w600 : FontWeight.w400,
              color: unlocked ? style.color : AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  /// 会员权益（视觉身份权益：徽章/专属色卡/成长值/等级保留）
  Widget _buildBenefits() {
    const benefits = [
      (AppIconsLegacy.verified_outlined, '专属等级徽章', '头像旁、动态里展示你的等级标识'),
      (AppIconsLegacy.palette_outlined, '等级专属配色', '首页与会员卡片随等级呈现专属渐变色'),
      (AppIconsLegacy.trending_up, '成长值累计', '每次下单累计消费，等级只升不降'),
      (AppIconsLegacy.lock_clock_outlined, '等级永久保留', '消费回退不降级，会员身份长期有效'),
    ];
    return FishGlassCard(
      insideMargin: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (int i = 0; i < benefits.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 64, endIndent: 16, color: T.divider),
              ListTile(
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.primary.withValues(alpha: 0.16), AppColors.primary.withValues(alpha: 0.07)],
                    ),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: AppIcon.of(benefits[i].$1, size: 19, color: AppColors.primary),
                ),
                title: Text(benefits[i].$2, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                subtitle: Text(benefits[i].$3, style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
