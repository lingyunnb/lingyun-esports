import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';
import 'announcement_detail_page.dart';

/// 公告列表（**方案 G 视觉重构**，负责人 2026-10-17 定案；逻辑与数据口径一字未改）
///
/// 为什么要有这一页：此前顶部「公告」进的是**系统通知**页（`NotificationPage`），
/// 而真正的公告只能从旧首页 `home_page.dart`（零 import 的死代码）进入 ——
/// 管理端发的公告用户在 App 里**永远看不到**。本页补上这个入口。
///
/// 数据源：`GET /public/announcements`（列表，不含正文）—— 接口、排序、跳转**全部未改**：
///   - 排序：**置顶优先（pinned=1），其后按发布时间倒序**，客户端再做一次稳定排序兜底；
///   - 详情：仍走既有的 `AnnouncementDetailPage`（`GET /public/announcements/:id`）。
///
/// 视觉（方案 G 原文逐条落地）：
/// - 页底 `#F6F7F9`，**每一条公告各自一张卡**（不是一张大卡里用分割线切）；
/// - 卡片 = 白底 + 1px 描边 `#E8ECF2` + 圆角 **12**，无阴影、无渐变（docs/21 禁渐变主视觉）；
/// - 卡内三行：标题 **14sp 粗**（`#14202E`）／摘要 **11sp 次要**（`#4A5A6E`，2 行截断）／
///   时间 **10sp 弱**（`#8A99AB`）；
/// - 卡与卡之间 **10dp**，**不使用分割线**（G 稿明确的"卡片间距代替分割线"）；
/// - 置顶仍然**克制地区分**：标题前一条 3×14 主色小竖条 + 小字「置顶」（不做整块彩色底）；
/// - 列表为空 → 通用空态组件 `AppEmptyState`（48 弱色图标 + 13sp 说明），中文文案「暂无公告」。
class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage({super.key, this.api});

  /// 测试注入（不注入时新建，与其它页面一致）
  final ApiClient? api;

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  /// 方案 G 页底（`#F6F7F9`）—— 本页私有常量，不新增/改动 core token
  static const Color _pageBg = AppColors.bgPageG;

  /// 卡与卡之间的间距（方案 G：10dp）
  static const double _cardGap = 10;

  late final ApiClient _api = widget.api ?? ApiClient();

  bool _loading = true;
  String? _error;
  List<_AnnouncementItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = _items.isEmpty;
      _error = null;
    });
    try {
      // force=true（下拉刷新）绕过 SWR 缓存，保证管理端刚发的公告立刻可见
      final resp = await _api.request('GET', '/public/announcements', forceRefresh: force);
      final raw = (resp['data'] as List?) ?? const [];
      final items = raw.whereType<Map>().map((e) => _AnnouncementItem.fromJson(e)).toList()
        ..sort(_byPinnedThenNewest);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '$e';
      });
    }
  }

  /// 置顶优先；同组内按发布时间倒序（服务端已排好，这里是客户端兜底）
  static int _byPinnedThenNewest(_AnnouncementItem a, _AnnouncementItem b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    final ta = a.createdAt, tb = b.createdAt;
    if (ta != null && tb != null) {
      final c = tb.compareTo(ta);
      if (c != 0) return c;
    }
    return 0;
  }

  void _openDetail(_AnnouncementItem a) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AnnouncementDetailPage(announcementId: a.id, api: widget.api)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FishGlassPage(
      title: '公告',
      body: ColoredBox(
        color: _pageBg,
        child: RefreshIndicator(
          onRefresh: () => _load(force: true),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _errorView()
                  : _items.isEmpty
                      ? _emptyView()
                      : _listView(),
        ),
      ),
    );
  }

  /// 失败：给出具体原因与重试入口（与其它页一致的失败分支；文案口径未改）
  Widget _errorView() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 120),
            child: Column(
              children: [
                Text('公告加载失败', style: TextStyle(fontSize: 14, color: T.textSecondary)),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _error ?? '',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: T.mutedText),
                  ),
                ),
                const SizedBox(height: 14),
                AppButton(label: '重试', onPressed: () => _load(), gradient: false, expand: false, height: 38),
              ],
            ),
          ),
        ],
      );

  /// 空态：通用空态组件（方案 G 版），文案仍是中文「暂无公告」
  Widget _emptyView() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [AppEmptyState(icon: AppIcon.bell, text: '暂无公告')],
      );

  Widget _listView() {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      itemCount: _items.length,
      // 方案 G：卡与卡之间 **10dp**，不用分割线（间距本身就是分组信号）
      separatorBuilder: (_, _) => const SizedBox(height: _cardGap),
      itemBuilder: (_, i) => _card(_items[i]),
    );
  }

  /// 单条公告卡：白底 + 1px 描边 `#E8ECF2` + 圆角 12（无阴影、无渐变）
  Widget _card(_AnnouncementItem a) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openDetail(a),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.strokeSoft),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 置顶标记：3×14 实色小竖条（不是彩色胶囊、不是图标）
              if (a.pinned) ...[
                Container(
                  width: 3,
                  height: 14,
                  margin: const EdgeInsets.only(top: 3),
                  decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            a.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            // 方案 G：标题 14sp 粗
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                              height: 1.35,
                            ),
                          ),
                        ),
                        if (a.pinned) ...[
                          const SizedBox(width: 6),
                          const Text('置顶',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.primary)),
                        ],
                      ],
                    ),
                    if (a.summary.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      // 方案 G：摘要 11sp 次要色，2 行截断
                      Text(
                        a.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.5),
                      ),
                    ],
                    const SizedBox(height: 7),
                    // 方案 G：时间 10sp 弱色
                    Text(a.timeText, style: const TextStyle(fontSize: 10, color: AppColors.statusMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              AppIcon.of(AppIcon.chevronRight, size: 16, color: AppColors.textPlaceholder),
            ],
          ),
        ),
      ),
    );
  }
}

/// 公告列表项（列表接口不含正文，正文在详情页单独拉取）
class _AnnouncementItem {
  _AnnouncementItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.pinned,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String summary;
  final bool pinned;
  final DateTime? createdAt;

  /// `pinned` 服务端是 tinyint（1/0，JSON 里是数字）；这里两种都认，避免真机拿到 1 却被判成 false
  factory _AnnouncementItem.fromJson(Map json) => _AnnouncementItem(
        id: '${json['id']}',
        title: '${json['title'] ?? ''}',
        summary: '${json['summary'] ?? ''}',
        pinned: _truthy(json['pinned']),
        createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      );

  static bool _truthy(Object? v) => v == 1 || v == true || v == '1';

  /// 本地时间「YYYY-MM-DD HH:mm」（与公告详情页同一格式，两页对得上）
  String get timeText {
    final t = createdAt?.toLocal();
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
