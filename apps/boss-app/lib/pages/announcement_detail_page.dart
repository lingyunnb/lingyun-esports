import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 公告详情（阶段：首页公告；内容来自 GET /public/announcements/:id）
///
/// 2026-10-05：本页**保留复用**（公告列表页点进来就是它，未重写）。
/// 唯一改动是加了可选 `api` 注入口 —— 与 `ServicesPage` / `AnnouncementsPage` 同一模式，
/// 供 widget 测试传入 fixture 客户端；生产路径不传，行为完全不变。
class AnnouncementDetailPage extends StatefulWidget {
  const AnnouncementDetailPage({super.key, required this.announcementId, this.api});

  final String announcementId;

  /// 测试注入（不注入时新建，与其它页面一致）
  final ApiClient? api;

  @override
  State<AnnouncementDetailPage> createState() => _AnnouncementDetailPageState();
}

class _AnnouncementDetailPageState extends State<AnnouncementDetailPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _data = null;
    });
    try {
      final resp = await _api.request('GET', '/public/announcements/${widget.announcementId}');
      // ⚠️ `mounted` 必须在 await 之后、setState 之前判：用户在请求飞行途中按返回键
      // 关掉本页时，`setState` 会打到已 dispose 的 State 上（Flutter 抛
      // "setState() called after dispose()"）。同目录的 `announcements_page.dart`
      // 三处 setState 全都有这个守卫，本页此前漏了。
      if (!mounted) return;
      setState(() => _data = resp['data'] as Map<String, dynamic>);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
        return FishGlassPage(
      title: '公告详情',
      body: _error != null
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
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  children: [
                    Row(
                      children: [
                        if (d['pinned'] == 1) ...[
                          const AppIcon.of(AppIconsLegacy.push_pin, size: 16, color: AppColors.warning),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text('${d['title']}', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _formatTime('${d['createdAt']}'),
                      style: const TextStyle(fontSize: 12, color: AppColors.mutedText),
                    ),
                    const Divider(height: AppSpacing.xl),
                    Text('${d['content']}', style: const TextStyle(fontSize: 14, color: AppColors.textPrimary, height: 1.8)),
                  ],
                ),
    );
  }

  String _formatTime(String iso) {
    // ⚠️ 必须 `.toLocal()`：服务端下发的是 UTC（`2026-10-05T12:30:00.000Z`），
    // 少了这一步，同一条公告在**列表页**（`announcements_page.dart` 的 `timeText` 有 toLocal）
    // 与**详情页**会显示成相差 8 小时的两个时间（实测东八区差 8h）。
    // 展示格式保持 `YYYY-MM-DD HH:mm`，与列表页逐字一致（两页对得上）。
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
