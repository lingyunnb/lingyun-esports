import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 好友申请（负责人需求 #16）：收到的申请（同意/拒绝）+ 发出的申请（可取消视为删除）
class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({super.key});

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

class _FriendRequestsPageState extends State<FriendRequestsPage> {
  final ApiClient _api = ApiClient();
  List<FriendRequestModel> _incoming = [];
  List<FriendRequestModel> _outgoing = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _api.request('GET', '/user/friends/requests/incoming', token: AuthStore.instance.accessToken),
        _api.request('GET', '/user/friends/requests/outgoing', token: AuthStore.instance.accessToken),
      ]);
      setState(() {
        _incoming = ((results[0]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
            .map((e) => FriendRequestModel.fromJson(e as Map<String, dynamic>))
            .toList();
        _outgoing = ((results[1]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
            .map((e) => FriendRequestModel.fromJson(e as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _accept(FriendRequestModel r) async {
    try {
      await _api.request('POST', '/user/friends/requests/${r.id}/accept', token: AuthStore.instance.accessToken);
      if (mounted) AppToast.success(context, '已同意，你们现在是好友了');
      await _load();
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message); // 通用失败：品牌浮层
    }
  }

  Future<void> _reject(FriendRequestModel r) async {
    try {
      await _api.request('POST', '/user/friends/requests/${r.id}/reject', token: AuthStore.instance.accessToken);
      await _load();
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message); // 通用失败：品牌浮层
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('好友申请')),
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
              : ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
                      child: Text('收到的申请', style: TextStyle(fontSize: 13, color: AppColors.textTertiary)),
                    ),
                    if (_incoming.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                        child: Text('暂无待处理的申请', style: TextStyle(color: AppColors.textTertiary)),
                      )
                    else
                      ..._incoming.map((r) => ListTile(
                            leading: AppAvatar(nickname: r.nickname, mediaId: r.avatarMediaId, size: 46),
                            title: Text(r.nickname, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                            subtitle: Text(r.message.isEmpty ? '请求添加你为好友' : r.message, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FilledButton.tonal(onPressed: () => _reject(r), child: const Text('拒绝')),
                                const SizedBox(width: AppSpacing.sm),
                                FilledButton(onPressed: () => _accept(r), child: const Text('同意')),
                              ],
                            ),
                          )),
                    const Divider(height: AppSpacing.xl),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                      child: Text('我发出的', style: TextStyle(fontSize: 13, color: AppColors.textTertiary)),
                    ),
                    if (_outgoing.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                        child: Text('暂无发出的申请', style: TextStyle(color: AppColors.textTertiary)),
                      )
                    else
                      ..._outgoing.map((r) => ListTile(
                            leading: AppAvatar(nickname: r.nickname, mediaId: r.avatarMediaId, size: 46),
                            title: Text(r.nickname, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                            subtitle: Text('ID: ${r.uid}', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                            trailing: const Text('等待验证', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                          )),
                  ],
                ),
    );
  }
}
