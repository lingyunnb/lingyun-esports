import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'app_icon.dart';

/// 阶段 6/7 页面骨架占位：图标 + 标题 + 说明 + 后续计划内容。
/// 各页面在对应阶段（商品/订单/聊天/排行榜…）开发时替换为真实内容。
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({
    super.key,
    required this.title,
    required this.icon,
    required this.description,
    this.planned,
  });

  final String title;
  final IconData icon;
  final String description;

  /// 该页面后续将承载的内容（如"阶段12 商品列表/下单"）
  final String? planned;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon.of(icon, size: 48, color: AppColors.textTertiary),
              const SizedBox(height: AppSpacing.lg),
              Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
              ),
              if (planned != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  planned!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
