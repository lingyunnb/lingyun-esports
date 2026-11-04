import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../theme/app_colors.dart';
import 'app_updater.dart';
import 'update_center.dart';

/// 更新弹窗（双端共用，FISH 简洁高级风格）：版本信息 → 下载进度 → 失败重试 → 调起系统安装。
/// 强制更新不可关闭；普通更新可选「稍后更新」。
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.info});

  final AppUpdateInfo info;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _started = false;

  Future<void> _startDownload() async {
    setState(() => _started = true);
    final ok = await UpdateCenter.instance.download();
    if (!ok) {
      if (!mounted) return;
      // 失败：更新中心已置 failed（错误文案 + 重试按钮）
      setState(() {});
      return;
    }
    if (!mounted) return;
    final path = UpdateCenter.instance.filePath;
    if (path != null) {
      // 校验通过：调起 Android 系统安装流程（FileProvider 安全机制，不绕过系统）
      await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
    }
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = UpdateCenter.instance;
    final info = widget.info;
    return PopScope(
      canPop: !info.force,
      child: AnimatedBuilder(
        animation: center,
        builder: (context, _) {
          final flow = center.flow;
          return AlertDialog(
            icon: Icon(
              flow == UpdateFlow.failed ? Icons.error_outline : Icons.system_update_alt,
              size: 40,
              color: flow == UpdateFlow.failed ? AppColors.error : AppColors.primary,
            ),
            title: Text(
              flow == UpdateFlow.failed
                  ? '更新失败'
                  : (_started && flow != UpdateFlow.idle ? '正在更新' : '发现新版本 v${info.versionName}'),
            ),
            content: flow == UpdateFlow.idle
                ? _buildInfo(info)
                : flow == UpdateFlow.failed
                    ? _buildError(center)
                    : _buildProgress(center, flow),
            actions: _buildActions(context, center, flow, info),
          );
        },
      ),
    );
  }

  Widget _buildInfo(AppUpdateInfo info) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.force) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('重要更新，需完成更新后才能继续使用', style: TextStyle(fontSize: 11.5, color: AppColors.error, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 10),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: Text(info.updateDesc.isEmpty ? '优化体验与修复问题' : info.updateDesc, style: const TextStyle(fontSize: 14, height: 1.6, color: AppColors.textSecondary)),
          ),
        ),
        const SizedBox(height: 12),
        Text('安装包大小 ${(info.fileSize / 1024 / 1024).toStringAsFixed(1)} MB', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
      ],
    );
  }

  Widget _buildProgress(UpdateCenter center, UpdateFlow flow) {
    final bool downloading = flow == UpdateFlow.downloading;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          downloading ? '正在下载安装包，请稍候…' : '正在校验文件完整性…',
          style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: LinearProgressIndicator(value: downloading ? center.progress : null, minHeight: 8),
        ),
        const SizedBox(height: 10),
        if (downloading) ...[
          // 百分比 + 实时速度 + 预计剩余时间（并行分片时标注「多连接加速」）
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(center.progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              ),
              Text(
                // 停滞重试期间**不许再显示「计算中…」**：速度本来就是 0，那行字只会让人
                // 以为还在正常算剩余时间；改说「正在重试」，真正的重试计数在下面一行。
                center.stallRetrying
                    ? '${center.speedText} · 正在重试'
                    : '${center.speedText} · ${center.remainingText}',
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_fmt(center.downloaded)} / ${_fmt(center.total)}',
                style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
              ),
              if (center.parallelActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '多连接加速',
                    style: TextStyle(fontSize: 10.5, color: AppColors.primary, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          // 停滞判死后正在退避重试（2026-10-17）：**必须说出来**。
          // 停滞时没有任何错误、速度显示 0.00 MB/s，最坏 ~3 分钟才出失败态 ——
          // 不提示的话，用户看到的就是"卡死了"（负责人原话："网没问题但卡住不下了"）。
          // 注意：这里只加一行提示，**进度与已下字节一个都不动**（绝不回退）。
          if (center.stallRetrying) ...[
            const SizedBox(height: 8),
            Text(
              center.stallNotice,
              style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.4),
            ),
          ],
        ] else
          Text(
            '${(center.progress * 100).toStringAsFixed(0)}% · ${_fmt(center.downloaded)} / ${_fmt(center.total)}',
            style: const TextStyle(fontSize: 12, color: AppColors.textTertiary),
          ),
      ],
    );
  }

  Widget _buildError(UpdateCenter center) {
    return Text(center.error ?? '下载失败', style: const TextStyle(fontSize: 13.5, color: AppColors.error, height: 1.5));
  }

  List<Widget> _buildActions(BuildContext context, UpdateCenter center, UpdateFlow flow, AppUpdateInfo info) {
    if (flow == UpdateFlow.idle) {
      return [
        if (!info.force)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后更新'),
          ),
        FilledButton(onPressed: _startDownload, child: const Text('立即更新')),
      ];
    }
    if (flow == UpdateFlow.failed) {
      // 「重试下载」不是「重新下载」：中途失败的进度**全部保留**（.part + sidecar），
      // 重试只补缺口（2026-10-17 停滞判活落地后，失败态一定会出现，而不是永远挂着）
      return [
        FilledButton(
          onPressed: () {
            center.reset();
            _startDownload();
          },
          child: const Text('重试下载'),
        ),
      ];
    }
    if (flow == UpdateFlow.done) {
      return [
        FilledButton(
          onPressed: () async {
            final path = center.filePath;
            if (path != null) await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
            if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
          },
          child: const Text('重新安装'),
        ),
      ];
    }
    // 下载中/校验中：给「取消」（立即断流并清理临时文件），不给关闭按钮
    return [
      TextButton(
        onPressed: () {
          center.cancel();
          setState(() {});
        },
        child: const Text('取消下载', style: TextStyle(color: AppColors.textTertiary)),
      ),
    ];
  }

  String _fmt(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// 展示更新弹窗（普通/强制共用；强制更新关闭后由调用方置 forceBlocked）
Future<void> showUpdateDialog(BuildContext context, AppUpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: !info.force,
    builder: (_) => UpdateDialog(info: info),
  ).then((_) {
    if (info.force && UpdateCenter.instance.flow != UpdateFlow.done) {
      UpdateCenter.instance.forceBlocked = true;
    }
  });
}
