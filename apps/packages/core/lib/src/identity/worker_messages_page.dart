import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../chat/conversation_incremental.dart';
import '../chat/user_models.dart';
import '../config/app_settings.dart';
import '../realtime/realtime_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/event_coalescer.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_toast.dart';
import 'identity_widgets.dart';
import 'worker_chat_target.dart';

/// 打手态 · **消息**（合并双端 · 身份切换；设计稿 A 套 `a4-worker-messages.html`）
///
/// ## 单页三分区（负责人 2026-10-17 定案，与老板态同一口径）
/// 一页之内按**固定顺序**列出三段：**老板 → 官方客服 → 好友**（边缘功能靠后）。
/// 上方原分段控件（老板 / 客服 / 好友 的胶囊）**整段删除**、页头右侧「一键已读」入口**整个移除**
/// （未读提示只剩每行那一枚红点）；空段整段不渲染，三段全空时给一次全页空态。
///
/// ## 好友段**条件显示**（负责人 2026-10-06 定案，本轮一个字都没破）
/// **该账号确实存在好友会话时才显示第三段【好友】**，没有就完全不渲染
/// （不显示空段、也不留占位）→ 多数打手看到的就是两段。判据见 [IdentityWorkerMessagesPage.friendSegmentRule]。
///
/// 数据源两处（都在伴随会话白名单内）：
///   - `GET /worker/cs/conversations` → 老板（`type == 'worker'`）与客服（`type == 'cs'`）
///   - `GET /user/conversations`      → 判定「有没有好友会话」并取好友段数据（`type == 'friend'`）
/// 判定**只看会话列表里有没有 `friend`**，不主动调 `/user/friends`（那是另一条接口）。
///
/// ## 未读机制
/// - 列表未读来自会话摘要的 `unread` 字段（服务端权威）；
/// - WS `unread:update` 用**服务端权威值**就地覆盖该会话未读；`msg:new` 就地更新该会话的
///   "最后一条消息"摘要；两者都**不再全量重拉列表**（2026-10-15 聊天实时接收优化，见下）；
/// - 只有"事件里的会话本地还没有"（新会话：打手刚抢到单等）才回源补一条，且用 200ms 合并窗口
///   把连续事件并成**一次**请求；
/// - 底部导航「消息」的红点由本页通过 [onUnreadChanged] 上报给 shell，
///   shell 只认这一个数据源，**不会读老板态的未读**（身份隔离）。
///
/// ## 聊天实时接收（2026-10-15 优化）
/// 此前每收到一条 `msg:new` 就 `_refresh()` **重拉整个会话列表** —— 对方发一句话，
/// 客户端打 1–2 次全量请求、列表重建 1–2 次（卡顿 / 闪烁 / 滚动跳位 / 输入框抖动）。
/// 现在：`msg:new` 的 payload 已带齐摘要 → [ConversationIncremental] 就地改这一行（**0 请求**），
/// 增量动作再由 [EventCoalescer] 合并成 200ms 一次 UI 更新。
///
/// ## 已结束的客服会话（2026-10-11 真机报障）
/// 咨询结束后（`chat_conversation.status='closed'`）该会话**不进列表、不计未读** ——
/// 服务端两条列表查询都已只取 `status='open'`；本页再按 [IdentityWorkerMessagesPage.isClosedCs]
/// 兜一道（判据只此一处），避免旧服务端/缓存里的旧响应让"已结束还挂红点"从客户端漏出来。
/// 历史一行未删：按 id 直接打开仍可读（服务端不断 404），只是不再出现在会话列表。
class IdentityWorkerMessagesPage extends StatefulWidget {
  const IdentityWorkerMessagesPage({
    super.key,
    this.api,
    this.openChat,
    this.onUnreadChanged,
    this.onSwitchBack,
  });

  final ApiClient? api;
  final IdentityWorkerChatOpener? openChat;

  /// 未读总数上报（打手态底部导航红点用）
  final ValueChanged<int>? onUnreadChanged;

  /// 身份细带右侧「切回老板」（由 shell 注入同一套切换流程）
  final VoidCallback? onSwitchBack;

  /// 基础两段（**顺序固定** 老板 → 官方客服；负责人 2026-10-17 把「客服」正名为「官方客服」）
  static const List<String> segments = ['老板', '官方客服'];

  /// **条件显示的第三段**：只有确实存在好友会话时才追加（负责人追加裁决）
  ///
  /// 为什么不做成"永远三段 + 空态"：好友是边缘功能，多数打手没有好友会话，
  /// 常驻一个空段等于每天在打手眼前放一个用不到的东西（docs/21「不存在的东西不出现」）。
  static const String friendSegment = '好友';

  /// 判定口径的中文说明（报告与测试共用一份）
  static const String friendSegmentRule = '会话列表里存在 type=friend 的会话时才显示第三段';

  /// **已结束的客服会话**判定（列表渲染 + 未读统计的**唯一**口径）
  ///
  /// 【2026-10-11 真机报障双保险】负责人：「都结束咨询了为啥还会显示那个会话还有红点
  /// **这个结束之后就不显示了**」。服务端口径已经修好（`listUserConversations` /
  /// `workerConversations` 都只取 `status='open'` 的客服会话），客户端这一层**再兜一道**：
  /// 万一服务端仍然返回了已结束的会话（旧服务端 / 15s SWR 缓存里的旧响应 / 将来有人放宽 SQL），
  /// 也**不许**出现"已结束还挂红点"或"列表里有、点开是会话不存在"。
  ///
  /// 只认服务端权威字段 `status`（解析缺省是 `open` —— 缺字段时不隐藏，宁可不隐藏也不误藏）。
  /// 判据只写在这里一处：列表过滤与 [unreadTotal] 都走同一个列表，不再各写一遍。
  static bool isClosedCs(ConversationSummaryModel c) => c.type == 'cs' && c.status == 'closed';

  /// 口径的中文说明（报告与测试同源引用）
  static const String closedCsRule = 'type=cs 且 status=closed 的会话不渲染、不计未读（结束咨询后即消失）';

  /// 「正在刷新」弱提示的锚点（发丝线级 2dp；测试用它断言"画了旧数据就必须给提示"）
  static const Key refreshingHairlineKey = Key('worker-messages-refreshing-hairline');

  /// **测试仪表**：本页 `build` 的累计次数（"连续 3 条事件只触发 1 次 UI 更新"的证据）。
  ///
  /// 为什么需要它：`testWidgets` 里没有"某页 build 了几次"的现成出口，而父级 widget 的 build
  /// 不会因本页 `setState` 而重跑 —— 于是只能在本页自己的 build 里累加。
  /// **生产零影响**：只是一个自增 int（与 `RealtimeClient.debugConnectCount` 同一范式）。
  @visibleForTesting
  static int debugBuildCount = 0;

  /// 空态文案（A+ 清单 MSG-B）
  ///
  /// 与清单原文的唯一差异：原文是「下单的老板会自动出现在这里」，其中「下单」命中
  /// **打手态 22 词黑名单**（同一份清单 §7 的硬规则）。两处要求冲突时以黑名单为准 ——
  /// 打手态任何屏都不能出现老板端词，故改为中性表述，语义不变。
  static const String emptyBossTitle = '还没有老板来找你';
  static const String emptyBossDetail = '抢到第一单后，那位老板会自动出现在这里；抢单或派单成功时服务端会自动建会话';
  static const String emptyCsTitle = '你还没有客服会话';
  static const String emptyCsDetail = '客服权限由平台单独开通，与接单权限互相独立；开通后老板的咨询会出现在这里';
  static const String emptyFriendTitle = '还没有好友会话';
  static const String emptyFriendDetail = '好友私聊是你的个人会话，与接单无关；好友发来消息时会出现在这里。';

  /// **全页空态**（三段都为空时只给一次；负责人 2026-10-17：空段整段不渲染，不许出现三个空标题）
  ///
  /// 上面三组「段内空态」文案保留下来只作口径留档：分段控件删除后**空段不再渲染**，
  /// 所以它们不再单独上屏；上屏的是这一组。
  static const String emptyPageTitle = '还没有会话';
  static const String emptyPageDetail = '老板、客服与好友的会话都会出现在这里；有会话时按 老板 · 官方客服 · 好友 分区列出';

  @override
  State<IdentityWorkerMessagesPage> createState() => IdentityWorkerMessagesPageState();
}

class IdentityWorkerMessagesPageState extends State<IdentityWorkerMessagesPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  final List<void Function()> _offEvents = [];

  /// 老板 + 客服（来自 `/worker/cs/conversations`）
  List<ConversationSummaryModel> _convs = const [];

  /// 好友会话（来自 `/user/conversations`；为空 = **不显示第三段**）
  List<ConversationSummaryModel> _friends = const [];

  /// **我作为发起方**的客服会话 id（= 侧别判定里的 `user` 侧）—— 2026-10-11 遗留缺陷修复
  ///
  /// 客服段的两类行长得一模一样，但侧别不同，判定口径（**只此一处**，与服务端同源）：
  /// - `/worker/cs/conversations` 的客服行 = 「**我发起的** ∪ **我作为客服被指派的**」
  ///   （`workerConversations` 的两个当事方条件）；
  /// - `/user/conversations` 的客服行 = 服务端按 `c.user_id = 我 AND type='cs' AND status='open'`
  ///   取的行 → **我发起的**那些。
  ///
  /// 于是「在我这个集合里」= 我是发起方（与老板态逐字相同，走 `user` 侧）；
  /// 「不在」= 我只可能是被指派的**当事客服**（走 `worker` 侧，与服务端 `resolveUserRouteActor`
  /// 的「当事客服 → worker 侧」同一口径）。
  ///
  /// `null` = 这次没拿到（接口失败）→ **不猜**：退回改动前的 `user` 侧行为
  /// （宁可不改行为，也不能把"可能是我发起的"那条推上 worker 路由冒 403）。
  Set<String>? _ownCsIds;

  bool _loading = true;
  String? _error;
  bool _notify = true;

  /// **首屏是"拿上一次的数据先画"的吗 / 后台有回源在飞**（决定要不要显示弱提示，见 [_content]）
  bool _refreshing = false;

  /// 实时事件合并窗口（200ms 内的连续事件 → 一次 UI 更新）
  ///
  /// 为什么必须合并：一次"对方发了一句话"在客户端常常是 `msg:new`（房间广播）+
  /// `unread:update`（`uid:` 单播）**两个回调**，此前各 `setState` 一次 → 列表连续重建两次。
  late final EventCoalescer _coalescer = EventCoalescer(onFlush: _onCoalesced);

  /// 合并窗口结算时：这次要不要**回源**（而不是只重画）
  ///
  /// 只有一种情况置 true：事件里的会话**本地列表里没有**（= 新会话，本地没有它的摘要可改）。
  /// 这就是"最小补拉"——普通消息/未读变化一律 0 请求。
  bool _needsReload = false;

  /// 是否显示好友段（判定口径见 [IdentityWorkerMessagesPage.friendSegmentRule]）
  bool get hasFriendSegment => _friends.isNotEmpty;

  /// shell 读红点用（测试也直接读它）：只统计**当前存在的段**的未读
  int get unreadTotal => _visibleConvs.fold(0, (sum, c) => sum + c.unread);

  /// 当前存在的段的会话全集
  List<ConversationSummaryModel> get _visibleConvs =>
      [..._convs.where((c) => c.type == 'worker' || c.type == 'cs'), ..._friends];

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    for (final off in _offEvents) {
      off();
    }
    _coalescer.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final token = AuthStore.instance.activeToken;
    if (token == null) {
      setState(() {
        _error = '未登录';
        _loading = false;
      });
      return;
    }
    try {
      await _load();
      _setupRealtime(token);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      // 兜底：任何非 ApiException（存储/解析异常）都不能让页面永远转圈
      if (!mounted) return;
      setState(() {
        _error = '消息加载失败，请下拉重试';
        _loading = false;
      });
    }
  }

  void _setupRealtime(String token) {
    _realtime.connect(token: token);
    // 【2026-10-15 聊天实时接收优化】**不再每来一条消息就重拉整个列表**：
    // `msg:new` 的 payload（服务端 `chat.service.ts#messageView`）已带齐最后一条摘要，
    // 本地就地改那一行即可（0 请求）；`unread:update` 带服务端权威未读值，同样就地覆盖。
    // 只有"会话本地没有"（新会话）才由 [_onCoalesced] 回源补一条，并用 200ms 窗口合并成一次。
    _offEvents.add(_realtime.on('msg:new', _onMessageEvent));
    _offEvents.add(_realtime.on('unread:update', _onUnreadEvent));
    _offEvents.add(_realtime.on('chat:assigned', (_) => _refresh()));
    _offEvents.add(_realtime.on('chat:closed', (_) => _refresh(force: true)));
    // 订单完成 -> 该「老板↔打手」直聊被服务端删除：本地先移除，再强刷校验
    _offEvents.add(_realtime.on('conv:removed', (data) {
      final id = data is Map ? '${data['conversationId'] ?? ''}' : '';
      if (id.isNotEmpty && mounted) {
        setState(() {
          _convs = ConversationIncremental.removeById(_convs, id);
        });
        _report();
      }
      _refresh(force: true);
    }));
    // 连上/重连后主动拉一次未读快照 + 刷新列表（断线期间的消息不丢）
    _offEvents.add(_realtime.on('connect', (_) {
      _realtime.emit('sync:unread');
      _refresh();
    }));
  }

  /// `msg:new` → **增量**更新该会话的最后一条摘要（0 请求）
  ///
  /// 命中不了本地列表（新会话）才交给合并窗口去回源补一条。
  /// 未读**不在这里动**：它由 `unread:update` 的权威值覆盖（客户端自增在并发/多端下必然分叉）。
  void _onMessageEvent(dynamic data) {
    if (!mounted) return;
    final next = ConversationIncremental.applyMessageEvent(_convs, data) ??
        ConversationIncremental.applyMessageEvent(_friends, data);
    if (next == null) {
      _scheduleReload();
      return;
    }
    _applyIncremental(next, data);
  }

  /// `unread:update` → 用服务端权威未读**增量**覆盖（0 请求）
  void _onUnreadEvent(dynamic data) {
    if (!mounted) return;
    final next = ConversationIncremental.applyUnreadEvent(_convs, data) ??
        ConversationIncremental.applyUnreadEvent(_friends, data);
    if (next == null) {
      _scheduleReload();
      return;
    }
    _applyIncremental(next, data);
  }

  /// 把增量结果落回**对应的那一段**（老板/客服段与好友段是两个数据源，不能混装）
  void _applyIncremental(List<ConversationSummaryModel> next, dynamic data) {
    final id = data is Map ? '${data['conversationId'] ?? ''}' : '';
    final bool isFriend = _friends.any((c) => c.id == id);
    if (isFriend) {
      _friends = next;
    } else {
      _convs = next;
    }
    // **未读上报对两段都要做**：`unreadTotal` 同时统计老板/客服段与好友段，
    // 只报其中一段会让底部导航「消息」红点在好友段变化时停在旧值上（改前 `_refresh` 里是统一上报的）。
    _report();
    _coalescer.add(); // 合并成 200ms 一次 UI 更新（不逐条重建列表）
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
      unawaited(_refresh(force: true));
      return;
    }
    setState(() {});
  }

  Future<void> _load() async {
    // 【2026-10-15 秒刷专项 · 缓存优先】进页**先用上一次的会话列表把屏画上**（哪怕已过期），
    // 再回源刷新 —— 用户感知从"转圈等一个网络往返"变成"秒出"。
    // 画完之后 `_refreshing = true` → 顶部一条发丝线级弱提示，别让用户以为这就是最新的。
    //
    // 必须**早于本方法里任何 await**：放在通知开关读完之后就只能等到第一个微任务，
    // 首帧仍然是一屏转圈（实测差 1 帧，用户看得出来是"闪了一下"）。
    _paintFromCache();
    // 通知开关读不到（无平台实现的测试环境/存储异常）不能把整页卡在转圈上：默认开
    try {
      _notify = await AppSettings.instance.csNotifyEnabled();
    } catch (_) {
      _notify = true;
    }
    await _refresh(force: true);
    if (mounted) setState(() => _loading = false);
  }

  /// 缓存优先渲染（**同步、0 请求**）：命中就用上一次的响应先画一屏
  ///
  /// 键与 [ApiClient.request] 完全同源（[ApiClient.peekCache] 复用它那一套算法），
  /// 所以这里读到的就是"上一次进入本页时服务端给的那份"。
  /// 未命中（本次运行内从没拉到过）→ 什么都不做，保持原有加载态。
  void _paintFromCache() {
    if (_convs.isNotEmpty || _friends.isNotEmpty) return;
    final convsPeek = _api.peekCache('/worker/cs/conversations');
    if (convsPeek == null) return;
    final friendsPeek = _api.peekCache('/user/conversations');
    final list = _parseConvs(convsPeek.body['data']);
    final all = friendsPeek == null ? null : _parseConvs(friendsPeek.body['data'], applySegmentFilter: false);
    if (!mounted) return;
    setState(() {
      _convs = list;
      if (all != null) {
        _friends = all.where((c) => c.type == 'friend').toList();
        // 侧别判定数据同源落地：与 [_refresh] 同一口径（见 [_ownCsIds]）
        _ownCsIds = all.where((c) => c.type == 'cs').map((c) => c.id).toSet();
      }
      _loading = false;
      _refreshing = true;
    });
    _report();
  }

  /// 会话列表响应的**唯一**解析口径（缓存先画与回源刷新必须完全一致，否则两份口径迟早分叉）
  ///
  /// [applySegmentFilter]：老板段+客服段的过滤（含 [IdentityWorkerMessagesPage.isClosedCs] 双保险）；
  /// `/user/conversations`（好友段数据源）不需要它。
  List<ConversationSummaryModel> _parseConvs(Object? rawData, {bool applySegmentFilter = true}) {
    final parsed = ((rawData as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
        .map((e) => ConversationSummaryModel.fromJson(e as Map<String, dynamic>))
        .toList();
    if (!applySegmentFilter) return parsed;
    return parsed
        .where((c) => c.type == 'worker' || c.type == 'cs')
        // 【2026-10-11】已结束的客服会话**不上屏、不计红点**（判据见 [isClosedCs]）
        .where((c) => !IdentityWorkerMessagesPage.isClosedCs(c))
        .toList();
  }

  /// 会话列表回源（[force] = true 绕过 15s SWR 缓存；删除/关闭等状态事件必须强刷）
  ///
  /// 两个数据源（都在伴随会话白名单内）：
  ///  1. `/worker/cs/conversations` → 老板段 + 客服段
  ///  2. `/user/conversations`      → **判定有没有好友会话**并取好友段
  /// 第 2 条失败（含 403）只意味着"看不到好友段"，**不影响前两段**，因此单独 try/catch。
  Future<void> _refresh({bool force = false}) async {
    final token = AuthStore.instance.activeToken;
    if (token == null) return;
    // 屏上已经有内容时的回源（下拉刷新 / 状态事件强刷）同样要给弱提示：
    // 此刻显示的是"上一次的数据"，正在追平 —— 见 [_content] 里那条发丝线
    if (mounted && !_refreshing && (_convs.isNotEmpty || _friends.isNotEmpty)) {
      setState(() => _refreshing = true);
    }
    try {
      // 【2026-10-15 秒刷专项 · 并行化】两条数据源**同时发**（此前是串行 `await`：
      // 先 `/worker/cs/conversations`、回来之后才发 `/user/conversations` → 首屏白等一整个往返）。
      // 两条互不依赖：一条给【老板】+【客服】段，一条给【好友】段与侧别判定。
      // 两条都在伴随会话白名单内（白名单一个字都没改）。
      final results = await Future.wait<Object?>([
        _api.request('GET', '/worker/cs/conversations', token: token, forceRefresh: force),
        _loadMineAndFriends(token, force: force),
      ]);
      final resp = results[0]! as Map<String, dynamic>;
      final mine = results[1] as ({List<ConversationSummaryModel> friends, Set<String> ownCsIds})?;
      final list = _parseConvs(resp['data']);
      if (!mounted) return;
      setState(() {
        _convs = list;
        _friends = mine?.friends ?? const [];
        // 侧别判定数据同源更新：拿到就用这一次的结果，拿不到置 null（`_open` 里退回 `user` 侧）
        _ownCsIds = mine?.ownCsIds;
        // 【2026-10-17 单页三分区】原来这里要把选中的段收回基础两段（防停在空白段上）；
        // 分段控件删除后不存在"选中的段"，好友段由 [_sections] 按 _friends 是否为空决定是否渲染。
        _loading = false;
        _refreshing = false;
      });
      _report();
    } on ApiException {
      // 静默：下一次事件或下拉刷新会重试
      if (mounted) setState(() => _refreshing = false);
    } catch (_) {
      // 非 ApiException（解析/存储异常）同样不能把"正在刷新"提示永久挂在屏幕上
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// `GET /user/conversations` 的**两个用途**（同一次请求，不重复打接口）：
  /// 1. 好友段数据源：`type == 'friend'` 的会话（**不调 `/user/friends`** —— 负责人追加裁决：
  ///    判定口径只按会话列表）；
  /// 2. **侧别判定数据源**：`type == 'cs'` 的 id 集合 = **我作为发起方**的客服会话
  ///    （口径见 [_ownCsIds]）。
  ///
  /// 拉不到（未放行/网络失败）返回 `null` → 好友段**不显示**（不是显示空段），
  /// 侧别判定**不猜**（退回 `user` 侧）。
  Future<({List<ConversationSummaryModel> friends, Set<String> ownCsIds})?> _loadMineAndFriends(
    String token, {
    required bool force,
  }) async {
    try {
      final resp = await _api.request('GET', '/user/conversations', token: token, forceRefresh: force);
      final all = ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
          .map((e) => ConversationSummaryModel.fromJson(e as Map<String, dynamic>))
          .toList();
      return (
        friends: all.where((c) => c.type == 'friend').toList(),
        ownCsIds: all.where((c) => c.type == 'cs').map((c) => c.id).toSet(),
      );
    } catch (_) {
      return null;
    }
  }

  void _report() => widget.onUnreadChanged?.call(_notify ? unreadTotal : 0);

  /// 打手侧的显示名：客服固定「祁连山客服」；老板直聊用老板昵称
  String _nameOf(ConversationSummaryModel c) => c.type == 'cs' ? '祁连山客服' : (c.peer?.nickname ?? '老板');

  String _preview(ConversationSummaryModel c) {
    if (c.lastRecalled) return '[消息已撤回]';
    if (c.lastMsgType == 'image') return '[图片]';
    return c.lastContent;
  }

  String _timeText(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day}';
  }

  Future<void> _open(ConversationSummaryModel c) async {
    final opener = widget.openChat;
    if (opener == null) {
      AppToast.info(context, '本机未接入聊天页');
      return;
    }
    await opener(
      context,
      IdentityWorkerChatTarget(
        conversationId: c.id,
        title: _nameOf(c),
        csConversation: c.type == 'cs',
        workerDirect: c.type == 'worker',
        // 侧别（判据只在 [_ownCsIds] 一处）：不在"我发起的"集合里 = 我是**当事客服**
        // → 走 worker 侧；「结束咨询」据此带上 id，同时服务多条也能精确关掉当前这一条
        csServing: c.type == 'cs' && _ownCsIds != null && !_ownCsIds!.contains(c.id),
        peerNickname: c.type == 'cs' ? '祁连山客服' : c.peer?.nickname,
        peerAvatarMediaId: c.peer?.avatarMediaId,
        lastMessage: _preview(c),
        lastAt: c.lastAt,
        lastIsImage: c.lastMsgType == 'image',
        lastRecalled: c.lastRecalled,
      ),
    );
    if (mounted) await _refresh(force: true);
  }

  // ---------- 单页三分区（负责人 2026-10-17 定案）----------
  //
  // 【已删除】页头右侧的「一键已读」（原 `_markAllRead`）：负责人 2026-10-17 要求整个移除。
  // 它打的是既有的 `POST /user/conversations/:id/read`（聊天页读消息走同一条）——**接口保留不动**，
  // 只是消息页不再有"整批已读"的 UI，未读提示从此只剩行内那一枚红点（红点必须保留）。

  /// 一页之内的三段（**顺序固定**：老板 → 官方客服 → 好友）
  ///
  /// 好友段**条件显示**（负责人 2026-10-06 定案，本轮继续原样保留）：[_friends] 为空 → 该段根本不进列表；
  /// 另外**空段整段不渲染**（没有会话的段连标题都不出现），三段全空时由 [_content] 给一次全页空态。
  List<({String title, List<ConversationSummaryModel> convs})> get _sections {
    final all = <({String title, List<ConversationSummaryModel> convs})>[
      (title: IdentityWorkerMessagesPage.segments[0], convs: _convs.where((c) => c.type == 'worker').toList()),
      (title: IdentityWorkerMessagesPage.segments[1], convs: _convs.where((c) => c.type == 'cs').toList()),
      if (_friends.isNotEmpty)
        (title: IdentityWorkerMessagesPage.friendSegment, convs: _friends),
    ];
    return all.where((s) => s.convs.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context) {
    IdentityWorkerMessagesPage.debugBuildCount += 1; // 测试仪表（见 debugBuildCount 注释；生产零影响）
    return Column(
      children: [
        IdentityWorkerPageHeader(
          title: '消息',
          // 页头右侧原本只有「一键已读」，已按负责人 2026-10-17 定案移除（不再留占位）。
          // 身份细带：**页头正下方**（A+ ID-A：位置三屏一致、不随内容滚动）
          banner: AppIdentityBar(
            workerNo: _workerNo(),
            nickname: _workerNickname(),
            onSwitchBack: widget.onSwitchBack,
          ),
        ),
        // 【已删除】分段控件（老板 / 客服 / 好友 的胶囊）：改成一页之内三段并列（分区标题组织）。
        Expanded(child: _content()),
      ],
    );
  }

  String _workerNo() {
    final wm = AuthStore.instance.workerMe;
    if (wm != null && wm.workerNo.isNotEmpty) return wm.workerNo;
    return AuthStore.instance.identityStatus?.worker?.workerNo ?? '';
  }

  String _workerNickname() {
    final wm = AuthStore.instance.workerMe;
    if (wm != null && wm.nickname.isNotEmpty) return wm.nickname;
    return AuthStore.instance.identityStatus?.worker?.nickname ?? '';
  }

  /// 分区标题（口径与老板态消息页一致）：**12px 弱色段名（左） + 上 20dp（首段）/ 24dp（段间）留白
  /// + 右侧 10.5px 会话数**
  ///
  /// 段间留白 24 = 组间松；段内（标题下沿到首行）8 = 组内紧。
  Widget _sectionHeader(String title, int count, {required bool first}) => Padding(
        padding: EdgeInsets.fromLTRB(AppSpacing.page, first ? 20 : 24, AppSpacing.page, 8),
        child: Row(
          children: [
            Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: T.mutedText)),
            const Spacer(),
            Text('$count 个会话', style: const TextStyle(fontSize: 10.5, color: AppColors.statusMuted)),
          ],
        ),
      );

  /// 单行会话卡：白底 + 1px `AppColors.strokeSoft` + 圆角 12（与老板态同一语言）
  ///
  /// 行与行之间留 **8**（组内紧），所以一行一张卡；透明 Material 供 InkWell 水波纹使用。
  Widget _rowCard(Widget row) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.strokeSoft, width: 1),
        ),
        child: Material(type: MaterialType.transparency, child: row),
      );

  /// 三段并列的内容区；全部为空 → 一次全页空态（不出现三个空标题）
  Widget _sectioned() {
    final sections = _sections;
    if (sections.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          IdentityWorkerEmptyState(
            icon: AppIdentityIcons.empty,
            title: IdentityWorkerMessagesPage.emptyPageTitle,
            detail: IdentityWorkerMessagesPage.emptyPageDetail,
          ),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (int i = 0; i < sections.length; i++) ...[
          _sectionHeader(sections[i].title, sections[i].convs.length, first: i == 0),
          for (int j = 0; j < sections[i].convs.length; j++) ...[
            if (j > 0) const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: _rowCard(
                // 会话 id 作 key：列表顺序变化（新消息置顶）时按 id 复用元素，
                // 行内部的进度条/头像不重建 → 不闪、不跳（2026-10-15 实时接收优化）
                KeyedSubtree(key: ValueKey('conv-${sections[i].convs[j].id}'), child: _row(sections[i].convs[j])),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2)));
    }
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => _refresh(force: true),
          child: _error != null
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    IdentityWorkerEmptyState(
                      icon: AppIdentityIcons.info,
                      title: _error!,
                      detail: '下拉或重新进入本页重试。',
                      action: '重试',
                      onAction: _init,
                    ),
                  ],
                )
              : _sectioned(),
        ),
        /**
         * 「正在刷新」弱提示（发丝线级 2dp，**绝对定位 → 零布局位移**）。
         *
         * 为什么必须有：进页先用**已过期**的缓存把屏画上（秒出）之后就少了"加载中"这个信号，
         * 不给提示用户会以为这就是最新的（负责人口径：「别让用户以为数据是新的」）。
         * 为什么不做无限动画的进度条：本仓既有出图/渲染用例大量使用 `pumpAndSettle`，
         * 无限动画会把它们挂死 —— 静态发丝线同样起到"有活儿在干"的作用，且不闪屏。
         */
        if (_refreshing)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              key: IdentityWorkerMessagesPage.refreshingHairlineKey,
              height: 2,
              color: AppColors.primary.withValues(alpha: 0.45),
            ),
          ),
      ],
    );
  }

  // 【已删除】`_openCsDirect()`：「客服段空态」里的「联系客服」按钮随空段不再渲染而一起下线。
  // 这条能力没丢：打手态「我的 › 联系客服」（`worker_mine_page.dart`）与接单大厅/客服大厅页
  // 走的是同一条真实入口（`GET /user/conversation`），白名单一个字都没改。

  Widget _row(ConversationSummaryModel c) {
    final isCs = c.type == 'cs';
    final badge = c.unread > 0 && _notify;
    return InkWell(
      onTap: () => _open(c),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            AppAvatar(
              nickname: _nameOf(c),
              mediaId: isCs ? null : c.peer?.avatarMediaId,
              size: 40,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _nameOf(c),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _roleTag(isCs ? '客服' : '老板'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _preview(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_timeText(c.lastAt), style: const TextStyle(fontSize: 10.5, color: AppColors.textTertiary)),
                const SizedBox(height: 4),
                if (badge)
                  Container(
                    constraints: const BoxConstraints(minWidth: 17),
                    height: 17,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(9)),
                    child: Text(
                      c.unread > 99 ? '99+' : '${c.unread}',
                      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  )
                else
                  const SizedBox(height: 17),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleTag(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.ice,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.bannerInfoBorder),
        ),
        child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.primary)),
      );
}
