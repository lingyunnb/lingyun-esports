import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'friend_profile_page.dart';

/// 好友搜索（负责人需求 #16/#46）：按展示 ID 精确搜索（中文/数字/英文），查看状态并申请添加
class FriendSearchPage extends StatefulWidget {
  const FriendSearchPage({super.key});

  @override
  State<FriendSearchPage> createState() => _FriendSearchPageState();
}

class _FriendSearchPageState extends State<FriendSearchPage> {
  final ApiClient _api = ApiClient();
  final TextEditingController _input = TextEditingController();
  UserBriefModel? _result;
  bool _loading = false;
  String? _error;

  Future<void> _search() async {
    final q = _input.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final resp = await _api.request('GET', '/user/friends/search', token: AuthStore.instance.accessToken, queryParameters: {'uid': q});

      setState(() => _result = UserBriefModel.fromJson(resp['data'] as Map<String, dynamic>));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _addFriend(UserBriefModel u) async {
    try {
      await _api.request('POST', '/user/friends/requests', token: AuthStore.instance.accessToken, data: {'uid': u.uid, 'message': '你好，我是 ${AuthStore.instance.me?.nickname ?? ''}'});
      if (!mounted) return;
      AppToast.success(context, '好友申请已发送');
      await _search();
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  Future<void> _acceptIncoming(UserBriefModel u) async {
    // 对方已申请我：走申请列表处理（这里仅提示）
    if (!mounted) return;
    AppToast.info(context, '对方已向你发出申请，请在"新的好友申请"中同意');
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('添加好友')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: InputDecoration(
                      hintText: '输入对方 ID 或昵称（支持中文）',
                      filled: true,
                      fillColor: AppColors.bgPage,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppSpacing.md), borderSide: BorderSide.none),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(onPressed: _loading ? null : _search, child: const Text('搜索')),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.error)))
                    : _result == null
                        ? const Center(child: Text('按 ID 或昵称搜索用户，例如：U2741312533 或中文 ID/昵称', style: TextStyle(color: AppColors.textTertiary)))
                        : ListView(
                            padding: const EdgeInsets.all(AppSpacing.lg),
                            children: [
                              _resultCard(_result!),
                            ],
                          ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(UserBriefModel u) {
    Widget action;
    switch (u.friendStatus) {
      case 'self':
        action = const SizedBox.shrink();
      case 'accepted':
        action = FilledButton.tonal(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FriendProfilePage(friend: u))),
          child: const Text('已是好友'),
        );
      case 'pending_out':
        action = FilledButton.tonal(onPressed: null, child: const Text('等待验证'));
      case 'pending_in':
        action = FilledButton(onPressed: () => _acceptIncoming(u), child: const Text('对方已申请'));
      default:
        action = FilledButton(onPressed: () => _addFriend(u), child: const Text('添加好友'));
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.md),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          AppAvatar(nickname: u.nickname, mediaId: u.avatarMediaId, size: 52),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(u.nickname, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('ID: ${u.uid}', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (u.levelName.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(u.levelName, style: const TextStyle(fontSize: 11, color: AppColors.primary)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}
