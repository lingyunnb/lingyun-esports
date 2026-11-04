

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../widgets/fish_glass.dart';
import 'chat_detail_page.dart';
import 'friend_profile_page.dart';
import 'friend_requests_page.dart';
import 'friend_search_page.dart';
import 'notification_page.dart';

/// 消息（负责人需求 #12-15）：聊天（客服会话，仅指派给自己的）+ 好友（列表/申请）+ 群组（预留空态）
/// 客服会话由后端控制权限与授权（docs/07），普通用户/未授权工作端不可见、不可伪造
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  final List<void Function()> _offEvents = [];

  List<ConversationSummaryModel> _convs = [];
  List<UserBriefModel> _friends = [];
  int _unreadNotif = 0;
  bool _friendNotify = true;
  bool _csNotify = true; // 消息通知设置
  int _pendingRequests = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      setState(() {
        _error = '未登录';
        _loading = false;
      });
      return;
    }
    try {
      await _loadData(token);
      _setupRealtime(token);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadData(String token) async {
    _friendNotify = await AppSettings.instance.friendNotifyEnabled();
    _csNotify = await AppSettings.instance.csNotifyEnabled();
    // 并行拉取（客服会话/好友/申请/通知未读，避免串行等待）
    final results = await Future.wait([
      _api.request('GET', '/worker/cs/conversations', token: token),
      _api.request('GET', '/user/friends', token: token),
      _api.request('GET', '/user/friends/requests/incoming', token: token),
      _api.request('GET', '/user/notifications', token: token, queryParameters: {'page': 1, 'pageSize': 5}),
    ]);
    _convs = ((results[0]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
        .map((e) => _convFrom(e as Map<String, dynamic>))
        .toList();
    _friends = ((results[1]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
        .map((e) => UserBriefModel.fromJson(e as Map<String, dynamic>))
        .toList();
    _pendingRequests = ((results[2]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? []).length;
    _unreadNotif = ((results[3]['data'] as Map<String, dynamic>?)?['unread'] as num?)?.toInt() ?? 0;
    setState(() => _loading = false);
  }

  void _setupRealtime(String token) {
    _realtime.connect(token: token);
    _offEvents.add(_realtime.on('chat:assigned', (_) => _loadCs()));
    _offEvents.add(_realtime.on('chat:unassigned', (_) => _loadCs()));
    _offEvents.add(_realtime.on('unread:update', (_) => _loadCs()));
    // 新消息：列表实时刷新（含未读与排序，不再依赖手动刷新）
    _offEvents.add(_realtime.on('group:new-message', (_) => _loadCs()));
    _offEvents.add(_realtime.on('msg:new', (_) => _loadCs()));
    // 订单完成 → 该「老板↔打手」直聊被结束并删除（负责人 2026-10-04）：
    // 工作端（打手侧）同样立即从会话列表移除，再**强刷**回源校验一次。
    // 必须 forceRefresh：/worker/cs/conversations 有 15s SWR 缓存，非强刷会把已删会话读回来
    // → 打手看到老板会话仍在、还能点进去发消息。
    _offEvents.add(_realtime.on('conv:removed', (data) {
      final id = data is Map ? '${data['conversationId'] ?? ''}' : '';
      if (id.isNotEmpty && mounted) {
        setState(() => _convs = _convs.where((c) => c.id != id).toList());
      }
      _loadCs(force: true);
    }));
    _offEvents.add(_realtime.on('friend:request', (_) => _refreshFriendMeta()));
    _offEvents.add(_realtime.on('friend:accepted', (_) => _refreshFriendMeta()));
    // 连接/重连后主动拉未读快照 + 刷新列表（断线期间消息不丢）
    _offEvents.add(_realtime.on('connect', (_) {
      _realtime.emit('sync:unread');
      _loadCs();
    }));
  }

  /// 会话列表回源（[force] = true 绕过 15s SWR 缓存；订单完成等状态事件必须强刷）
  Future<void> _loadCs({bool force = false}) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request('GET', '/worker/cs/conversations', token: token, forceRefresh: force);
      final list = ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
          .map((e) => _convFrom(e as Map<String, dynamic>))
          .toList();
      if (mounted) setState(() => _convs = list);
    } on ApiException {
      // 静默
    }
  }

  Future<void> _refreshFriendMeta() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final results = await Future.wait([
        _api.request('GET', '/user/friends', token: token),
        _api.request('GET', '/user/friends/requests/incoming', token: token),
      ]);
      if (!mounted) return;
      setState(() {
        _friends = ((results[0]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
            .map((e) => UserBriefModel.fromJson(e as Map<String, dynamic>))
            .toList();
        _pendingRequests = ((results[1]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? []).length;
      });
    } on ApiException {
      // 静默
    }
  }

  @override
  void dispose() {

    for (final off in _offEvents) {
      off();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          return FishGlassPage(
            title: '消息',
            blurredTopBar: true,
            actions: [
              IconButton(
                tooltip: '添加好友',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendSearchPage())),
              ),
              Stack(
                alignment: Alignment.topRight,
                children: [
                  IconButton(
                    tooltip: '系统通知',
                    icon: const Icon(Icons.notifications_none),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationPage())),
                  ),
                  if (_unreadNotif > 0 && _friendNotify)
                    Padding(
                      padding: const EdgeInsets.only(top: 8, right: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(9)),
                        child: Text('$_unreadNotif', style: const TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ),
                ],
              ),
            ],
            body: Column(
              children: [
                // HyperOS 玻璃分段 Tab（与老板端统一，2026-09-25）
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (_, _) => MiuixGlassSegmentedTabRow(
                      tabs: const ['好友私聊', '客服', '老板'],
                      selectedIndex: controller.index,
                      onSelect: (i) => controller.animateTo(i),
                    ),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_error!, style: const TextStyle(color: AppColors.error)),
                                  const SizedBox(height: AppSpacing.md),
                                  FilledButton(onPressed: _init, child: const Text('重试')),
                                ],
                              ),
                            )
                          : TabBarView(
                              children: [
                                _buildFriendsTab(),
                                _buildCsTab(),
                                _buildBossTab(),
                              ],
                            ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCsTab() {
    final csOnly = _convs.where((c) => c.type == 'cs').toList();
    if (csOnly.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadCs,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(vertical: 80),
              child: Column(
                children: [
                  Icon(Icons.support_agent_outlined, size: 48, color: AppColors.textTertiary),
                  SizedBox(height: AppSpacing.md),
                  Text('暂无客服会话', style: TextStyle(color: AppColors.textTertiary)),
                  SizedBox(height: 4),
                  Text('管理员在后台指派后自动出现', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadCs,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: csOnly.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (ctx, i) {
          final c = csOnly[i];
          final name = c.peer?.nickname ?? '用户';
          return Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.md), border: Border.all(color: AppColors.divider)),
            child: Material(color: Colors.transparent, child: ListTile(
              leading: AppAvatar(nickname: name, mediaId: c.peer?.avatarMediaId, size: 44),
              title: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              trailing: c.unread > 0 && _csNotify
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                      child: Text('${c.unread}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                    )
                  : null,
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatDetailPage(
                      conversationId: c.id,
                      title: name,
                      csConversation: true,
                      peerAvatarMediaId: c.peer?.avatarMediaId,
                      // 进页直出：会话列表已有信息先渲染，历史到达后替换（不整页转圈）
                      peerNickname: c.peer?.nickname,
                      peerLastMessage: c.lastContent.isEmpty ? null : c.lastContent,
                      peerLastAt: c.lastAt,
                      peerLastIsImage: c.lastMsgType == 'image',
                      peerLastRecalled: c.lastRecalled,
                    ),
                  ),
                );
                _loadCs(); // 返回刷新未读（角标即时消失）
              },
            )),
          );
        },
      ),
    );
  }

  Widget _buildFriendsTab() {
    return RefreshIndicator(
      onRefresh: _refreshFriendMeta,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ListTile(
            leading: Stack(
              alignment: Alignment.topRight,
              children: [
                const CircleAvatar(radius: 23, backgroundColor: Color(0xFFEFF1FF), child: Icon(Icons.person_add_alt, color: AppColors.primary, size: 22)),
                if (_pendingRequests > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(8)),
                    child: Text('$_pendingRequests', style: const TextStyle(color: Colors.white, fontSize: 9)),
                  ),
              ],
            ),
            title: const Text('新的好友申请', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            trailing: const Icon(Icons.chevron_right, color: AppColors.textTertiary),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FriendRequestsPage()));
              _refreshFriendMeta();
            },
          ),
          const Divider(height: 1),
          if (_friends.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.group_outlined, size: 48, color: AppColors.textTertiary),
                    SizedBox(height: AppSpacing.md),
                    Text('还没有好友', style: TextStyle(color: AppColors.textTertiary)),
                    SizedBox(height: 4),
                    Text('点右上角搜索按钮，按 ID 添加好友', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                  ],
                ),
              ),
            )
          else
            ..._friends.map(
              (f) => ListTile(
                leading: Stack(
                  children: [
                    AppAvatar(nickname: f.nickname, mediaId: f.avatarMediaId, size: 46),
                    // 在线状态点（服务端实时判断，2026-09-25）
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: f.online ? AppColors.success : AppColors.textTertiary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                title: Text(f.nickname, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                subtitle: Text('ID: ${f.uid}', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => FriendProfilePage(friend: f))),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBossTab() {
    final bosses = _convs.where((c) => c.type == 'worker').toList();
    if (bosses.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadCs,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(vertical: 80),
              child: Column(
                children: [
                  Icon(Icons.groups_outlined, size: 48, color: AppColors.textTertiary),
                  SizedBox(height: AppSpacing.md),
                  Text('暂无老板消息', style: TextStyle(color: AppColors.textTertiary)),
                  SizedBox(height: 4),
                  Text('抢单成功后，可与下单老板一对一沟通', style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadCs,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: bosses.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (ctx, i) {
          final c = bosses[i];
          return Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.md), border: Border.all(color: AppColors.divider)),
            child: Material(color: Colors.transparent, child: ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.groups_outlined, color: AppColors.primary, size: 22),
              ),
              title: Text(c.peer?.nickname ?? '下单老板', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              trailing: c.unread > 0
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                      child: Text('${c.unread}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                    )
                  : null,
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatDetailPage(
                      conversationId: c.id,
                      title: c.peer?.nickname ?? '下单老板',
                      workerDirect: true,
                      peerAvatarMediaId: c.peer?.avatarMediaId,
                      peerNickname: c.peer?.nickname ?? '下单老板',
                      peerLastMessage: c.lastContent.isEmpty ? null : c.lastContent,
                      peerLastAt: c.lastAt,
                      peerLastIsImage: c.lastMsgType == 'image',
                      peerLastRecalled: c.lastRecalled,
                    ),
                  ),
                );
                _loadCs(); // 返回列表刷新未读（角标即时消失）
              },
            )),
          );
        },
      ),
    );
  }
}

/// 工作端会话列表项解析：CS 会话取 userNickname，老板直聊取 name/orderId/type
ConversationSummaryModel _convFrom(Map<String, dynamic> e) {
  final m = ConversationSummaryModel.fromJson(e);
  if (m.peer == null && e['userNickname'] != null) {
    return ConversationSummaryModel(
      id: m.id,
      type: m.type,
      unread: m.unread,
      lastSeq: m.lastSeq,
      peer: UserBriefModel(userId: '', uid: '', nickname: '${e['userNickname']}'),
      name: m.name,
      orderId: m.orderId,
      status: m.status,
    );
  }
  return m;
}
