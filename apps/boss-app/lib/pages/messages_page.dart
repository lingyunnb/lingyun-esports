

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'chat_detail_page.dart';
import 'friend_search_page.dart';

/// 消息（负责人 2026-10-17 定案：**单页三分区**）。
///
/// 一页之内按**固定顺序**列出三段会话：① 联系打手 → ② 好友私聊 → ③ 官方客服。
/// 上方原三枚分区胶囊（好友私聊 / 客服 / 打手）**整排删除**，标题右侧「一键已读」入口**整个移除**
/// （未读提示只剩每一行的红点）—— 依据：负责人 2026-10-17
/// 「消息页上方不要有胶囊和一键已读，改成全部集中在一页。例如：联系打手 下方是打手；
/// 好友私聊 下方是好友；官方客服 下方是客服消息」。
///
/// 空段整段不渲染（没有会话就不出标题，也不出空态占位）；三段全空时给**一次**全页空态。
/// 接口一个没动：「一键已读」原本打的是既有的 `POST /user/conversations/:id/read`
/// （聊天页读消息走同一条），本轮只移除 UI 入口，后端一行未改。
///
/// **入口分工（2026-10-05 修 D9「同一入口出现两次」）**：
/// - 本页搜索框 = **搜已有会话**（在当前分区内按昵称/最后一条消息过滤，不发请求）
/// - 「好友私聊」分区右上「+」= **加好友的唯一入口**（`FriendSearchPage`；带未处理申请角标）
///   此前搜索框直接跳「添加好友」，与服务页顶部的搜索图标撞成两个入口，
///   且把"加人"塞进了"找人聊天"的位置 —— 现在两件事各归各位。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  /// 「正在刷新」弱提示的锚点（发丝线级 2dp；缓存优先先画时就该出现）
  static const Key refreshingHairlineKey = Key('messages-refreshing-hairline');

  /// 三个分区标题（**顺序固定** = 负责人 2026-10-17 指定的 ① → ② → ③）
  ///
  /// 为什么是这个顺序：负责人原话「联系打手 下方是打手；好友私聊 下方是好友；官方客服 下方是客服消息」。
  /// 正在进行的护航/上分交易排最前，社交（好友）居中，平台自营客服排最后。
  static const String sectionWorker = '联系打手';
  static const String sectionFriend = '好友私聊';
  static const String sectionCs = '官方客服';

  /// **测试仪表**：本页 `build` 的累计次数。
  ///
  /// 为什么要这个：本任务硬要求「200ms 内连续 3 条事件 → 只触发 **1 次** UI 更新」，
  /// 而"UI 更新次数"在 `testWidgets` 里没有现成出口 —— 父级 widget 的 build 不会因本页
  /// `setState` 而重跑（这正是我第一版测量测出 0 的原因）。于是在本页自己的 build 里累加。
  /// **生产零影响**：只是一个自增 int，没有任何分支依赖它（与 `RealtimeClient.debugConnectCount` 同一范式）。
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  final List<void Function()> _offEvents = [];

  /// 会话搜索（D9：只搜已有会话，本地过滤，不产生请求）
  final TextEditingController _search = TextEditingController();
  String _query = '';

  List<ConversationSummaryModel> _convs = [];
  int _pendingRequests = 0;
  bool _loading = true;
  String? _error;
  bool _friendNotify = true; // 消息通知设置（需求：好友申请角标开关）

  /// **首屏是"拿上一次的数据先画"的吗 / 后台有回源在飞**（决定要不要显示弱提示）
  bool _refreshing = false;

  /// 实时事件合并窗口（200ms 内的连续事件 → 一次 UI 更新；见 core 的 [EventCoalescer]）
  late final EventCoalescer _coalescer = EventCoalescer(onFlush: _onCoalesced);

  /// 合并窗口结算时这次要不要**回源**（只有"事件里的会话本地列表没有"= 新会话 才为 true）
  bool _needsReload = false;

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
    // 【2026-10-15 秒刷专项 · 缓存优先】先用上一次的会话列表把屏画上（哪怕已过期）再回源 ——
    // 冷启动/换身份重建本页时不再先给一屏转圈。
    //
    // 必须**早于本方法里任何 await**：放在通知开关读完之后就只能等到第一个微任务，
    // 首帧仍然是一屏转圈（实测差 1 帧）。
    _paintFromCache();
    _friendNotify = await AppSettings.instance.friendNotifyEnabled();
    // 并行拉取会话列表/申请数/通知未读（避免串行等待，负责人需求 #37）
    //
    // 2026-10-05：不再拉 `/user/friends`（原好友列表只喂给消息页内那段未引用的死代码；
    // 好友列表现在只出现在「添加好友」页的"我的好友"空屏区，少一次无用请求）。
    final results = await Future.wait([
      _api.request('GET', '/user/conversations', token: token),
      _api.request('GET', '/user/friends/requests/incoming', token: token),
      _api.request('GET', '/user/notifications', token: token, queryParameters: {'page': 1, 'pageSize': 5}),
    ]);
    _convs = ((results[0]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
        .map((e) => ConversationSummaryModel.fromJson(e as Map<String, dynamic>))
        .toList();
    _pendingRequests = ((results[1]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? []).length;
    setState(() {
      _loading = false;
      _refreshing = false;
    });
  }

  /// 缓存优先渲染（**同步、0 请求**）：键与 [ApiClient.request] 同源，命中就立刻上屏
  void _paintFromCache() {
    if (_convs.isNotEmpty) return;
    final peek = _api.peekCache('/user/conversations');
    if (peek == null) return;
    final list = ((peek.body['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
        .map((e) => ConversationSummaryModel.fromJson(e as Map<String, dynamic>))
        .toList();
    if (!mounted) return;
    setState(() {
      _convs = list;
      _loading = false;
      _refreshing = true;
    });
  }

  void _setupRealtime(String token) {
    _realtime.connect(token: token);
    // 【2026-10-15 聊天实时接收优化】**不再每来一条消息就重拉整个会话列表**：
    // `msg:new` 的 payload（服务端 `chat.service.ts#messageView`）已带齐"最后一条"
    // （msgId/seq/conversationId/senderType/msgType/content/recalled/createdAt）→
    // 本地就地改那一行（**0 请求**）；`unread:update` 带服务端权威未读值 → 同样就地覆盖。
    // 两者各自触发的 UI 更新由 [EventCoalescer] 合并成 200ms 一次（此前是两个回调各 setState 一次）。
    // 只有"事件里的会话本地还没有"（新会话 / 好友刚通过）才回源补一条摘要，且连续多次只打一次。
    _offEvents.add(_realtime.on('msg:new', _onMessageEvent));
    _offEvents.add(_realtime.on('unread:update', _onUnreadEvent));
    _offEvents.add(_realtime.on('msg:recalled', (_) => _refreshConvs()));
    // 新消息/会话结束：列表实时刷新（消息列表不再依赖手动刷新）
    _offEvents.add(_realtime.on('chat:closed', (_) => _refreshConvs(force: true)));
    // 订单完成 → 该「老板↔打手」直聊被结束并删除（负责人 2026-10-04）：
    // 先按 conversationId 本地移除（列表立即消失），再**强刷**回源校验一次。
    // 必须 forceRefresh：/user/conversations 有 15s SWR 缓存，非强刷会把刚删掉的会话又读回来
    // → 老板看到会话仍在、还能点进去联系打手（本次报障「还能联系打手」的客户端真因之一）。
    _offEvents.add(_realtime.on('conv:removed', (data) {
      final id = data is Map ? '${data['conversationId'] ?? ''}' : '';
      if (id.isNotEmpty && mounted) {
        setState(() => _convs = ConversationIncremental.removeById(_convs, id));
      }
      _refreshConvs(force: true);
    }));
    _offEvents.add(_realtime.on('friend:request', (_) => _refreshPendingRequests()));
    _offEvents.add(_realtime.on('friend:accepted', (_) => _refreshPendingRequests()));
    // 连接/重连后主动拉未读快照 + 刷新列表（断线期间的消息不丢）
    _offEvents.add(_realtime.on('connect', (_) {
      _realtime.emit('sync:unread');
      _refreshConvs();
    }));
  }

  /// `msg:new` → **增量**更新该会话的最后一条摘要（0 请求）
  ///
  /// 未读**不在这里动**：它由 `unread:update` 的权威值覆盖（客户端自增在并发/多端下必然分叉）。
  void _onMessageEvent(dynamic data) {
    if (!mounted) return;
    final next = ConversationIncremental.applyMessageEvent(_convs, data);
    if (next == null) {
      _scheduleReload();
      return;
    }
    _convs = next;
    _coalescer.add();
  }

  /// `unread:update` → 用服务端权威未读**增量**覆盖（0 请求）
  void _onUnreadEvent(dynamic data) {
    if (!mounted) return;
    final next = ConversationIncremental.applyUnreadEvent(_convs, data);
    if (next == null) {
      _scheduleReload();
      return;
    }
    _convs = next;
    _coalescer.add();
  }

  /// 需要回源（新会话 / 形状不认识的事件）→ 交给同一个合并窗口，连续多次只打**一次**
  void _scheduleReload() {
    _needsReload = true;
    _coalescer.add();
  }

  /// 合并窗口结算：要么按需回源，要么只做这一次 UI 更新
  void _onCoalesced() {
    if (!mounted) return;
    if (_needsReload) {
      _needsReload = false;
      _refreshConvs(force: true);
      return;
    }
    setState(() {});
  }

  /// 会话列表回源（[force] = true 绕过 15s SWR 缓存；订单完成等状态事件必须强刷）
  Future<void> _refreshConvs({bool force = false}) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    // 屏上已有内容时的回源 → 给发丝线级弱提示（此刻显示的是上一次的数据，正在追平）
    if (mounted && !_refreshing && _convs.isNotEmpty) {
      setState(() => _refreshing = true);
    }
    try {
      final resp = await _api.request('GET', '/user/conversations', token: token, forceRefresh: force);
      final list = ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
          .map((e) => ConversationSummaryModel.fromJson(e as Map<String, dynamic>))
          .toList();
      if (mounted) {
        setState(() {
          _convs = list;
          _refreshing = false;
        });
      }
    } on ApiException {
      // 静默失败，下次事件再刷新
      if (mounted) setState(() => _refreshing = false);
    } catch (_) {
      // 非 ApiException（解析异常）同样不能把"正在刷新"提示永久挂在屏幕上
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 未处理好友申请数（「+」上的角标；WS `friend:request` / `friend:accepted` 触发）
  Future<void> _refreshPendingRequests() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request('GET', '/user/friends/requests/incoming', token: token);
      if (!mounted) return;
      setState(() => _pendingRequests = ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? []).length);
    } on ApiException {
      // 静默
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _coalescer.dispose();

    for (final off in _offEvents) {
      off();
    }

    super.dispose();
  }

  /// 会话显示名（客服固定「联系客服」；一对一打手直聊「接单打手」；好友用对方昵称）
  String _convName(ConversationSummaryModel c) => c.type == 'cs'
      ? '联系客服'
      : (c.peer?.nickname ?? (c.isWorkerDirect ? '接单打手' : '好友'));

  /// 当前分区内的本地过滤（搜已有会话：昵称 / 最后一条消息，忽略大小写）
  List<ConversationSummaryModel> _filtered(List<ConversationSummaryModel> list) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list
        .where((c) => _convName(c).toLowerCase().contains(q) || c.lastContent.toLowerCase().contains(q))
        .toList();
  }

  /// 加好友的**唯一入口**（消息 › 好友私聊 › 右上「+」）；回来刷新角标
  Future<void> _openAddFriend() async {
    // 注入的 api 递下去（生产为 null → 各自用默认 ApiClient；测试注入时同一条假通道）
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FriendSearchPage(api: widget.api)));
    if (mounted) await _refreshPendingRequests();
  }

  void _openChat(ConversationSummaryModel c) {
    final name = _convName(c);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatDetailPage(
          conversationId: c.id,
          title: name,
          peerAvatarMediaId: c.peer?.avatarMediaId,
          csConversation: c.type == 'cs',
          workerDirect: c.isWorkerDirect,
          // 进页直出：会话列表已有的信息先渲染，历史到达后替换（不整页转圈）
          peerNickname: c.type == 'cs' ? '祁连山客服' : c.peer?.nickname,
          peerLastMessage: _preview(c),
          peerLastAt: c.lastAt,
          peerLastIsImage: c.lastMsgType == 'image',
          peerLastRecalled: c.lastRecalled,
        ),
      ),
    );
  }

  String _preview(ConversationSummaryModel c) {
    if (c.lastRecalled) return '[消息已撤回]';
    if (c.lastMsgType == 'image') return '[图片]';
    return c.lastContent;
  }

  String _timeText(DateTime? t) {
    if (t == null) return '';
    final now = DateTime.now();
    final local = t.toLocal();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day}';
  }

  @override
  Widget build(BuildContext context) {
    MessagesPage.debugBuildCount += 1; // 测试仪表（见 debugBuildCount 注释；生产零影响）
    // 视觉基线 = 设计图 `site/design/ref-video/planG-all.html` **第 3 行第 1 列「消息列表」**
    // （负责人 2026-10-17 真机反馈「消息页面和设计图不符」→ 逐项对齐 `.sh` / `.msgrow` / 卡片）；
    // 结构 = 负责人 2026-10-17 定案的单页三分区（上方胶囊与「一键已读」都已删除）。
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 会话行、搜索框、分区标题一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top + 8),
          // 标题行：**只有标题**（「一键已读」入口已按负责人 2026-10-17 定案整个移除；
          // 未读提示改由每一行的红点表达 —— 所以那一枚红点必须保留，它是唯一的未读信号）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Row(
              children: [
                Text('消息', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: T.textPrimary)),
              ],
            ),
          ),
          // 【已删除】三类分区胶囊（好友私聊 / 客服 / 打手）：
          // 负责人 2026-10-17「消息页上方不要有胶囊…改成全部集中在一页」→ 整排移除，
          // 改由下面各区段自己的分区标题组织内容（空段整段不渲染）。
          // 搜索框（**搜已有会话**，本地过滤，D9）+「+」（加好友唯一入口）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: T.bgCardSolid,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.strokeSoft),
                    ),
                    child: Row(
                      children: [
                        AppIcon.of(AppIcon.search, size: 15, color: T.textTertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _search,
                            onChanged: (v) => setState(() => _query = v),
                            textInputAction: TextInputAction.search,
                            style: TextStyle(fontSize: 12.5, color: T.textPrimary),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: '搜索已有会话',
                              // 白底上的输入提示 = 说明文字 → mutedText（#5B6B80，5.44:1）
                              hintStyle: TextStyle(fontSize: 12.5, color: AppColors.mutedText),
                            ),
                          ),
                        ),
                        if (_query.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                            child: AppIcon.of(AppIcon.close, size: 15, color: T.textTertiary),
                          ),
                      ],
                    ),
                  ),
                ),
                // 「+」= 加好友的唯一入口（D9）。单页三分区之后它**常驻**（不再跟着分区隐藏），
                // 于是也不存在"切分区要留同宽占位"的问题了。
                const SizedBox(width: 8),
                _addFriendButton(),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: _loading
                      ? Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary))
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
                          : _buildSections(),
                ),
                /**
                 * 「正在刷新」弱提示（发丝线级 2dp，**绝对定位 → 零布局位移**）。
                 *
                 * 进页先用**已过期**的缓存把屏画上（秒出）之后就少了"加载中"这个信号，
                 * 不给提示用户会以为这就是最新的（负责人口径：「别让用户以为数据是新的」）。
                 * 用静态细线而不是无限动画进度条：本仓既有出图/渲染用例大量用 `pumpAndSettle`，
                 * 无限动画会把它们挂死；静态线同样表达"有活儿在干"，且不闪屏。
                 */
                if (_refreshing)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      key: MessagesPage.refreshingHairlineKey,
                      height: 2,
                      color: AppColors.primary.withValues(alpha: 0.45),
                    ),
                  ),
              ],
            ),
          ),
        ],
      )),
    );
  }

  /// 「+」：**加好友的唯一入口**（D9）；有待处理申请时带角标（D6）
  ///
  /// 单页三分区（负责人 2026-10-17）之后它不再归属某个分区，而是**常驻**在搜索框右侧。
  /// 视觉：白底 + 发丝线 + 圆形（与搜索框同高 38）；角标＝红点数字（`_friendNotify` 可关，
  /// 对齐「消息通知设置」里"好友申请角标"的语义）。
  Widget _addFriendButton() {
    final showBadge = _pendingRequests > 0 && _friendNotify;
    return GestureDetector(
      onTap: _openAddFriend,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: T.bgCardSolid,
              shape: BoxShape.circle,
              border: Border.all(color: T.divider),
            ),
            child: AppIcon.of(AppIcon.plus, size: 19, color: T.primary),
          ),
          if (showBadge)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                constraints: const BoxConstraints(minWidth: 17),
                height: 17,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: T.bgCardSolid, width: 1.5),
                ),
                child: Text('$_pendingRequests',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 单页三分区（负责人 2026-10-17 定案）----------
  //
  // 【已删除】「一键已读」（原 `_markAllRead`，入口在标题行右侧）：负责人 2026-10-17 要求整个移除。
  // 它打的是既有的 `POST /user/conversations/:id/read`（聊天页读消息走同一条）——**接口保留不动**，
  // 只是消息页不再有"整批已读"的 UI，未读提示从此只剩行内那一枚红点。

  /// 一页之内的三段（**顺序固定**：联系打手 → 好友私聊 → 官方客服）
  ///
  /// 每段 = 分区标题 + 该段会话卡列表；**空段整段不渲染**（连标题都不出现，也不留空态占位）。
  /// [cs] 只影响行内文案（已结束客服会话的预览语），取色在 `_convTile` 里按身份判。
  List<({String title, List<ConversationSummaryModel> convs, bool cs})> get _sections => [
        (
          title: MessagesPage.sectionWorker,
          convs: _filtered(_convs.where((c) => c.isWorkerDirect).toList()),
          cs: false,
        ),
        (
          title: MessagesPage.sectionFriend,
          convs: _filtered(_convs.where((c) => c.type == 'friend').toList()),
          cs: false,
        ),
        (
          title: MessagesPage.sectionCs,
          convs: _filtered(_convs.where((c) => c.type == 'cs').toList()),
          cs: true,
        ),
      ].where((s) => s.convs.isNotEmpty).toList();

  Widget _buildSections() {
    final sections = _sections;
    if (sections.isEmpty) return _emptyPage();
    return RefreshIndicator(
      onRefresh: () async => _refreshConvs(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              bottom: 24 + NavStyleController.instance.navReservedHeight,
            ),
        children: [
          for (int i = 0; i < sections.length; i++) ...[
            // 分区标题：首段上方 20（与搜索框分开）；其后的段上方 24 = **段与段之间的留白**
            _sectionHeader(sections[i].title, sections[i].convs.length, first: i == 0),
            for (int j = 0; j < sections[i].convs.length; j++) ...[
              // 段内行距 **8**（组内紧）；段间 24（组间松）由下一个分区标题的上边距给出
              if (j > 0) const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _convCard(
                  // 会话 id 作 key：新消息置顶导致顺序变化时按 id 复用元素 → 不闪、不跳
                  KeyedSubtree(
                    key: ValueKey('conv-${sections[i].convs[j].id}'),
                    child: _convTile(
                      sections[i].convs[j],
                      name: _convName(sections[i].convs[j]),
                      cs: sections[i].cs,
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

  /// 全页空态（三段都为空时**只给一次**，绝不出现三个空标题）
  ///
  /// 两个状态分开说（D9 口径不变），都走 [AppEmptyState]（已存在的通用空态组件）：
  /// - 有搜索词 → 「没有匹配的会话」（搜不到 ≠ 没有会话）
  /// - 没有搜索词 → 「暂无会话」
  Widget _emptyPage() {
    final searching = _query.trim().isNotEmpty;
    return RefreshIndicator(
      onRefresh: () async => _refreshConvs(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (searching)
            const AppEmptyState(icon: AppIcon.search, text: '没有匹配的会话')
          else
            const AppEmptyState(icon: AppIconsLegacy.chat_bubble_outline, text: '暂无会话'),
        ],
      ),
    );
  }

  /// 分区段标题（设计图 `planG-all.html` 第 3 行「消息列表」的 `.sh`）：
  /// **12px 弱色段名（左） + 上 20dp 留白 + 右侧 10.5px 会话数**（`justify-content: space-between`）
  ///
  /// 会话数是**数据标签**（不是说明文字），所以留在右侧一行；除「N 个会话」之外不再写任何解释。
  /// [first]=false 时上边距改 **24** —— 那是段与段之间的留白（组间松）；首段用 20 与搜索框分开。
  Widget _sectionHeader(String title, int count, {required bool first}) => Padding(
        padding: EdgeInsets.fromLTRB(16, first ? 20 : 24, 16, 8),
        child: Row(
          children: [
            Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: T.mutedText)),
            const Spacer(),
            Text('$count 个会话', style: const TextStyle(fontSize: 10.5, color: AppColors.statusMuted)),
          ],
        ),
      );

  /// 身份方块头像（方案 G：**圆角 12 方块字标**；颜色按身份 —— 客服=青 / 打手=蓝 / 好友=墨蓝）
  ///
  /// 实底 + 白色字标（不是渐变、不是玻璃）；有真实头像时仍走 core 的 [AppAvatar]（自带磁盘缓存
  /// 与兜底），外层只负责把形状收成 12 圆角方块。
  Widget _convAvatar({
    required String name,
    required bool cs,
    required Color color,
    required String? mediaId,
    required bool closed,
  }) {
    final tone = closed ? AppColors.statusMuted : color;
    if (mediaId != null && mediaId.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AppAvatar(nickname: name, mediaId: mediaId, size: 44, color: tone),
      );
    }
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(12)),
      child: cs
          ? const AppIcon.of(AppIcon.headset, size: 20, color: Colors.white)
          : Text(
              name.isNotEmpty ? name.characters.first : '?',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
            ),
    );
  }

  /// 单行会话卡：**白底 + 1px `AppColors.strokeSoft` + 圆角 12**（负责人 2026-10-17 ④ 的行样式）
  ///
  /// 为什么是"一行一张卡"而不是"一段一张卡"：负责人 ③ 要求**段内行距 8**（组内紧）、段间 24（组间松）——
  /// 行与行之间既然要留 8，行就必须各自成立（此前一段一张卡、行间靠发丝线，行距实际是 0）。
  /// 不用玻璃底、不用阴影（docs/21）。
  /// 透明 Material：InkWell 水波纹需要 Material 祖先（视觉零影响）。
  Widget _convCard(Widget row) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.strokeSoft, width: 1),
        ),
        child: Material(type: MaterialType.transparency, child: row),
      );

  /// 会话行（设计图 `planG-all.html` 第 3 行「消息列表」的 `.msgrow`，逐项对齐）：
  ///
  /// ```
  /// [圆角 12 方块字标] 名字 13/粗            时间 10/弱
  ///                    摘要 11/次要（单行省略） 未读红点
  /// ```
  ///
  /// **时间与未读在右侧同一列**（设计图 `flex-direction:column; align-items:flex-end`），
  /// 不再把时间挤在名字行、也不再让未读红点插在摘要后面 —— 摘要因此拿满整行宽度（单行省略更干净）。
  ///
  /// 身份不再用彩色角色胶囊表达：设计图里好友/打手行没有任何角色标签，
  /// 靠**区块分组 + 方块字标取色**（客服青 / 打手蓝 / 好友墨蓝）已经说清「这是谁」；
  /// 只有 `/user/conversations` 的 `status=closed` 这个**状态事实**保留一枚灰标签（数据标签，不是装饰）。
  ///
  /// **内距全部落 4dp 网格**（4/8/12/16）：本轮随单页三分区重排，行内距由 14/11/10 收口到 12/12/8，
  /// 四周边距 12、字标与文字 12、正文与右列 12；字号/字重/圆角/取色一处未动（负责人 ④ 的行样式）。
  Widget _convTile(ConversationSummaryModel c, {required String name, required bool cs}) {
    final closed = c.status == 'closed';
    // 同功能同色：客服=青 · 打手=蓝 · 好友=墨蓝（feature_hues 的口径，一处不另取色）
    final roleColor = cs
        ? AppColors.accentSupport
        : (c.isWorkerDirect ? AppColors.primary : AppColors.brandInk);
    return InkWell(
      onTap: () => _openChat(c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _convAvatar(name: name, cs: cs, color: roleColor, mediaId: c.peer?.avatarMediaId, closed: closed),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        // 会话名（好友/打手/客服）：**最多 2 行**（负责人 2026-10-05 报障清单里的「会话名」）
                        // 昵称上限 20 字，去掉角色标签后本行可用宽 ≈240dp ≈17 个汉字 →
                        // 再留 2 行余量，极端长昵称也不会被省略号吃掉
                        child: Text(name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textPrimary)),
                      ),
                      if (closed) ...[
                        const SizedBox(width: 8),
                        const AppTag('已结束', color: AppColors.statusMuted),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cs && closed ? '本次咨询已结束，点击查看聊天记录' : _preview(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: T.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 右列：时间（上）+ 未读（下）—— 设计图 `.msgrow` 的最后一栏
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_timeText(c.lastAt ?? c.updatedAt),
                    style: const TextStyle(fontSize: 10, color: AppColors.textPlaceholder)),
                if (c.unread > 0 && !closed) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 17),
                    decoration: BoxDecoration(
                      // 未读红点：唯一允许的红色；胶囊形状（999）不与圆角档抢。
                      // 去掉「一键已读」之后它是页面上**唯一的未读提示**（负责人 2026-10-17 ④）。
                      color: AppColors.error,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      c.unread > 99 ? '99+' : '${c.unread}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 好友 ----------
  //
  // 2026-10-05（本任务 · 修 D6）：原先这里有一个 `_buildFriendsTab()`（好友列表 + 「新的好友申请」
  // 入口），但它**从未被 build 引用**（靠 `// ignore: unused_element` 压着告警）——
  // 后果就是"新的好友申请"在全 App **没有可达入口**：搜到"对方已申请你"只弹一句 Toast，
  // 让用户去一个进不去的地方。同时它喂着 `_friends` 与 `_openFriend`，那两处也一并成了死代码。
  //
  // 处置（与 A 套设计稿一致）：**明确移除**这段死代码，入口改到两处真实可达的位置——
  //   ① `FriendSearchPage` 页头「申请」+ 未处理角标（主入口）
  //   ② 本页搜索框右侧「+」上的角标（提示有待处理，点进去就是 ①；单页三分区后它常驻全页）
  // 好友列表本身不在这里重复：它只出现在「添加好友」页未输入时的"我的好友"区（点行进资料页）。
}
