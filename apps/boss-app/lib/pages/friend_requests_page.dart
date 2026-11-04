import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 新的朋友（好友申请）——A 套设计稿第 ⑤ 屏（`site/design/add-friend/a-instant.html`）
///
/// **可达性（D6）**：本页此前只有一个入口，挂在一段 `// ignore: unused_element` 的死代码上
/// （老板端搜到"对方已申请你"时只弹 Toast 让用户去一个**进不去**的地方）。
/// 现在入口有两处**互补**、互不重复的：① 添加好友页页头「申请」+ 未处理角标（主入口）；
/// ② 消息 › 好友私聊 › 右上「+」上的角标（提示有待处理）。本页自身不再是孤岛。
///
/// 与设计稿的唯一有意偏差：设计稿顶部有一排「收到的 / 我发出的」胶囊，同一屏下方又列了
/// 「我发出的」——两者会把同一份数据说两遍。这里**只保留分区**（收到的 N / 我发出的 N），
/// 让两边的待处理数**同屏可见**（这正是 D6 想要的"看得见、进得去"）。
///
/// 数据全部来自服务端：`incoming` / `outgoing` / `accept` / `reject`；
/// 拒绝不会通知对方（服务端行为，界面照实说明）。
class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

class _FriendRequestsPageState extends State<FriendRequestsPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  List<FriendRequestModel> _incoming = const [];
  List<FriendRequestModel> _outgoing = const [];
  bool _loading = true;
  String? _error;

  /// 正在处理的申请 id（防连点重复提交）
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = AuthStore.instance.accessToken;
    try {
      final results = await Future.wait([
        _api.request('GET', '/user/friends/requests/incoming', token: token),
        _api.request('GET', '/user/friends/requests/outgoing', token: token),
      ]);
      if (!mounted) return;
      setState(() {
        _incoming = _list(results[0]);
        _outgoing = _list(results[1]);
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message; // 服务端原文
        _loading = false;
      });
    }
  }

  List<FriendRequestModel> _list(Map<String, dynamic> resp) =>
      ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => FriendRequestModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();

  Future<void> _act(FriendRequestModel r, bool accept) async {
    final token = AuthStore.instance.accessToken;
    setState(() => _busyId = r.id);
    try {
      await _api.request('POST', '/user/friends/requests/${r.id}/${accept ? 'accept' : 'reject'}', token: token);
      if (!mounted) return;
      if (accept) AppToast.success(context, '已同意，你们现在是好友了');
      await _load();
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FishGlassPage(
      title: '新的朋友',
      actions: [
        if (_incoming.isNotEmpty)
          Container(
            constraints: const BoxConstraints(minWidth: 18),
            height: 18,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(right: AppSpacing.lg),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(999)),
            child: Text('${_incoming.length}',
                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
          ),
      ],
      body: Column(
        children: [
          Expanded(child: _body()),
          _facts(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: AppColors.error)),
            const SizedBox(height: AppSpacing.md),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _sectionHeader('收到的申请', '${_incoming.length} 条'),
          if (_incoming.isEmpty)
            _emptyLine('暂无待处理的申请')
          else
            for (final r in _incoming) ...[
              _incomingRow(r),
              _hair(),
            ],
          const SizedBox(height: AppSpacing.xl),
          _sectionHeader('我发出的', '${_outgoing.length} 条'),
          if (_outgoing.isEmpty)
            _emptyLine('暂无发出的申请')
          else
            for (final r in _outgoing) ...[
              _outgoingRow(r),
              _hair(),
            ],
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }

  /// 收到的申请：头像 42 + 昵称 + 申请原文 + 「拒绝」描边 / 「同意」实色（同屏唯一主色按钮）
  Widget _incomingRow(FriendRequestModel r) {
    final busy = _busyId == r.id;
    return Container(
      color: AppColors.bgCard,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 13),
      child: Row(
        children: [
          AppAvatar(nickname: r.nickname, mediaId: r.avatarMediaId, size: 42),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.nickname,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(r.message.isEmpty ? '请求添加你为好友' : r.message,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _btn('拒绝', onTap: busy ? null : () => _act(r, false)),
          const SizedBox(width: AppSpacing.sm),
          _btn('同意', primary: true, onTap: busy ? null : () => _act(r, true)),
        ],
      ),
    );
  }

  /// 我发出的：只读一行 + 时钟「等待验证」（服务端处理前不可撤回）
  Widget _outgoingRow(FriendRequestModel r) => Container(
        color: AppColors.bgCard,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 13),
        child: Row(
          children: [
            AppAvatar(nickname: r.nickname, mediaId: r.avatarMediaId, size: 42),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.nickname,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('ID  ${r.uid}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.mutedText, fontFamily: 'monospace')),
                ],
              ),
            ),
            const AppIcon.of(AppIcon.clock, size: 14, color: AppColors.textTertiary),
            const SizedBox(width: 5),
            const Text('等待验证', style: TextStyle(fontSize: 12, color: AppColors.mutedText)),
          ],
        ),
      );

  Widget _sectionHeader(String title, String count) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 20, AppSpacing.lg, AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
            const SizedBox(width: AppSpacing.sm),
            Text(count, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
          ],
        ),
      );

  Widget _emptyLine(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
        child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
      );

  Widget _hair() => Container(height: 1, color: AppColors.divider, margin: const EdgeInsets.only(left: 70));

  /// 行内按钮（高 32 / 圆角 6 / 无阴影）：拒绝＝描边，同意＝实色主色
  Widget _btn(String label, {bool primary = false, VoidCallback? onTap}) {
    final bg = primary ? AppColors.primary : AppColors.bgCard;
    final fg = primary ? Colors.white : AppColors.textPrimary;
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: primary ? null : Border.all(color: AppColors.divider),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
          ),
        ),
      ),
    );
  }

  /// 底部事实行：把「同意后会发生什么 / 我发出的能不能撤回」讲清楚（docs/21：文案具体可验证）
  Widget _facts() => Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: AppColors.bgCard,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 10),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Fact('同意后', '直接互为好友，会话出现在 消息 › 好友私聊'),
            _Fact('拒绝不通知', '对方不会收到提示；他重新申请时会覆盖旧记录，不堆两条'),
            _Fact('我发出的', '对方处理前不可撤回，只能等或让对方忽略'),
          ],
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.text);

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: Text(label,
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
            ),
            Expanded(
              child: Text(text, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.6)),
            ),
          ],
        ),
      );
}
