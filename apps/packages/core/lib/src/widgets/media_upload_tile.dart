/// 上传进度条组件（2026-10-06 上传体验专项）—— **唯一实现**。
///
/// 背景：上传背景图/头像/付款凭证原来只有一个 `CircularProgressIndicator`，
/// 弱网（Cloudflare 快速隧道实测上行 16KB/s）下 0.3–1MB 的图要传 20 秒~1 分钟，
/// 用户看到的就是**无限转圈**，观感等于卡死。负责人实测后要求：
///   百分比 + 速度 + 已传/总大小 + 慢网提示 + 失败中文可重试。
///
/// 为什么放在 core 而不是各页面各画一个：头像（编辑资料）、背景（编辑资料）、
/// 付款凭证（充值页）三处的进度语义完全相同，复制三份必然漂移
/// （"同一规则只有一份实现"）。
///
/// 视觉口径（守 docs/21 反 AI 味）：发丝线分隔、无渐变、无 emoji、进度条 4dp 细条、
/// 重试按钮是描边胶囊（不做大面积实色填充）、错误只用一个 error 色调，
/// 文案**具体可验证**（「当前网络较慢，正在上传 42%」而不是「请稍候」）。
///
/// 颜色一律走主题 token（[T] / [AppColors]），因此两套主题（classic / glass）下自洽 ——
/// 不写死色值。
library;

import 'package:flutter/material.dart';

import '../api/media_uploader.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';
import 'app_ui.dart';

/// 上传进度区：**空闲时不占位**（`SizedBox.shrink`），上传中/失败才出现。
///
/// 用法（页面持有 [MediaUploadState]，`onProgress` 里 `setState` 更新它）：
/// ```dart
/// MediaUploadTile(state: _bgUp, label: '背景', onRetry: _retryBackground)
/// ```
class MediaUploadTile extends StatelessWidget {
  const MediaUploadTile({
    super.key,
    required this.state,
    this.label = '',
    this.onRetry,
    this.margin = const EdgeInsets.only(top: AppSpacing.sm),
  });

  /// 上传状态（进度 + 错误）。空态时整个组件不渲染
  final MediaUploadState state;

  /// 前置说明（如 `背景` / `付款截图`）→ 文案变成「背景 上传中 42%」
  final String label;

  /// 失败时的「重试」回调；null = 不显示重试按钮（页面已另有重试入口时）
  final VoidCallback? onRetry;

  final EdgeInsetsGeometry margin;

  /// 慢网提示文案（**具体可验证**：带上当前百分比）
  static String slowHint(int percent) => '当前网络较慢，正在上传 $percent%';

  /// 上传中标题行文案（页面与测试共用同一份，避免两套字符串）
  static String progressTitle(String label, int percent) =>
      label.isEmpty ? '上传中 $percent%' : '$label 上传中 $percent%';

  /// 是否处于「慢网」：上传中且已越过阈值（阈值由 [MediaUploadState.begin] 的定时器置位）
  static bool isSlow(MediaUploadState s) => s.uploading && s.slow;

  @override
  Widget build(BuildContext context) {
    final MediaUploadProgress? p = state.progress;
    final bool uploading = state.uploading;
    final String? error = state.error;
    if (!uploading && error == null && p == null) return const SizedBox.shrink();

    final bool slow = MediaUploadTile.isSlow(state);

    return Container(
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploading) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    MediaUploadTile.progressTitle(label, p?.percent ?? 0),
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.textPrimary),
                  ),
                ),
                if (p != null)
                  Text(
                    '${p.sizeLabel} · ${MediaUploadProgress.formatSpeed(p.speedBytesPerSecond)}',
                    style: const TextStyle(fontSize: 11, color: AppColors.mutedText),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                // 拿不到总大小时退回不确定态（**不显示假百分比**）
                value: (p != null && p.hasTotal) ? p.percent / 100 : null,
                minHeight: 4,
                backgroundColor: T.divider,
                color: AppColors.primary,
              ),
            ),
            if (slow) ...[
              const SizedBox(height: 5),
              Text(
                MediaUploadTile.slowHint(p?.percent ?? 0),
                style: const TextStyle(fontSize: 11, color: AppColors.mutedText, height: 1.4),
              ),
            ],
          ] else if (error != null) ...[
            const AppHairline(),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon.of(AppIcon.info, size: 13, color: T.error),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    error,
                    style: TextStyle(fontSize: 11.5, color: T.error, height: 1.45),
                  ),
                ),
              ],
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 7),
              // 重试按钮：描边胶囊（不做大面积实色填充，守 docs/21 反 AI 味清单）
              Align(
                alignment: Alignment.centerLeft,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onRetry,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.primary),
                      ),
                      child: Text(
                        label.isEmpty ? '重试' : '重新上传$label',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
