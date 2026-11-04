import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import 'update_center.dart';
import 'update_dialog.dart';

/// 强制更新阻断页（双端共用）：后台设置强制更新且用户未完成安装时，替代主界面，
/// 只有完成更新才能继续使用（负责人需求 #4）。
class UpdateBlockPage extends StatelessWidget {
  const UpdateBlockPage({super.key});

  @override
  Widget build(BuildContext context) {
    final info = UpdateCenter.instance.latest;
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.primary, AppColors.primarySecondary],
                    ),
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(color: AppColors.primary.withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 8)),
                    ],
                  ),
                  child: const Icon(Icons.system_update_alt, size: 40, color: Colors.white),
                ),
                const SizedBox(height: 24),
                const Text('发现新版本', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                if (info != null) ...[
                  const SizedBox(height: 6),
                  Text('v${info.versionName}', style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 10),
                const Text(
                  '为保障账号安全与功能正常，需要更新到最新版本后才能继续使用',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: AppColors.textTertiary, height: 1.6),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: 220,
                  child: FilledButton(
                    onPressed: () {
                      final i = UpdateCenter.instance.latest;
                      if (i != null) {
                        UpdateCenter.instance.forceBlocked = false;
                        showUpdateDialog(context, i).then((_) {
                          // 弹窗关闭（未完成安装）→ 重新阻断
                          if (UpdateCenter.instance.flow != UpdateFlow.done) {
                            UpdateCenter.instance.forceBlocked = true;
                          }
                        });
                      }
                    },
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('立即更新', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () {
                    // 允许退出 App，但不放行进入主功能
                    SystemNavigator.pop();
                  },
                  child: const Text('退出应用', style: TextStyle(color: AppColors.textTertiary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
