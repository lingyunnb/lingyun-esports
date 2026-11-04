import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 系统通知（负责人需求 #24）：好友申请/通过等；支持全部已读
class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final ApiClient _api = ApiClient();
  final List<NotificationModel> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resp = await _api.request('GET', '/user/notifications', token: AuthStore.instance.accessToken, queryParameters: {'page': 1, 'pageSize': 50});
      setState(() {
        _items.clear();
        _items.addAll(((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
            .map((e) => NotificationModel.fromJson(e as Map<String, dynamic>)));
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _markAllRead() async {
    try {
      await _api.request('POST', '/user/notifications/read', token: AuthStore.instance.accessToken, data: {});
      await _load();
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  String _timeText(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return FishGlassPage(
      title: '系统通知',
      actions: [TextButton(onPressed: _markAllRead, child: const Text('全部已读'))],
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: AppColors.error)),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _items.isEmpty
                  ? const Center(child: Text('暂无通知', style: TextStyle(color: AppColors.mutedText)))
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: AppSpacing.lg),
                      itemBuilder: (ctx, i) {
                        final n = _items[i];
                        return ListTile(
                          leading: Icon(
                            n.type == 'friend_request' ? AppIconsLegacy.person_add_alt : AppIconsLegacy.check_circle_outline,
                            color: n.isRead ? AppColors.textTertiary : AppColors.primary,
                          ),
                          title: Text(n.title, style: TextStyle(fontSize: 15, fontWeight: n.isRead ? FontWeight.w400 : FontWeight.w600)),
                          subtitle: Text(n.content, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                          trailing: Text(_timeText(n.createdAt), style: const TextStyle(fontSize: 11, color: AppColors.mutedText)),
                        );
                      },
                    ),
    );
  }
}
