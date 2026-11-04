import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'chat_detail_page.dart';

/// 好友资料（负责人需求 #14/#19）：头像/ID/昵称/等级/权益 + 发消息 + 删除好友
class FriendProfilePage extends StatefulWidget {
  const FriendProfilePage({super.key, required this.friend});

  final UserBriefModel friend;

  @override
  State<FriendProfilePage> createState() => _FriendProfilePageState();
}

class _FriendProfilePageState extends State<FriendProfilePage> {
  final ApiClient _api = ApiClient();
  bool _deleting = false;

  Future<void> _openChat() async {
    try {
      final resp = await _api.request('POST', '/user/friends/${widget.friend.userId}/conversation', token: AuthStore.instance.accessToken);
      final convId = '${resp['data']?['conversationId'] ?? ''}';
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatDetailPage(
            conversationId: convId,
            title: widget.friend.nickname,
            peerAvatarMediaId: widget.friend.avatarMediaId,
            peerNickname: widget.friend.nickname,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message); // 通用失败：品牌浮层
    }
  }

  Future<void> _deleteFriend() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除好友？'),
        content: Text('删除后与 ${widget.friend.nickname} 的聊天记录仍保留，但不能再发消息'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _deleting = true);
    try {
      await _api.request('DELETE', '/user/friends/${widget.friend.userId}', token: AuthStore.instance.accessToken);
      if (mounted) {
        AppToast.success(context, '已删除好友');
        Navigator.of(context).pop();
      }
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message); // 通用失败：品牌浮层
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.friend;
    return Scaffold(
      appBar: AppBar(title: const Text('好友资料')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const SizedBox(height: AppSpacing.xl),
          Center(child: AppAvatar(nickname: f.nickname, mediaId: f.avatarMediaId, size: 72)),
          const SizedBox(height: AppSpacing.lg),
          Center(child: Text(f.nickname, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600))),
          const SizedBox(height: 4),
          Center(child: Text('ID: ${f.uid}', style: const TextStyle(fontSize: 13, color: AppColors.textTertiary))),
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('L${f.level} ${f.levelName}', style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: _openChat,
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            label: const Text('发消息'),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: _deleting ? null : _deleteFriend,
            icon: const Icon(Icons.person_remove_outlined, size: 18, color: AppColors.error),
            label: const Text('删除好友', style: TextStyle(color: AppColors.error)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.divider)),
          ),
        ],
      ),
    );
  }
}
