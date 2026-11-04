import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_cache.dart';
import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../icons/app_icon.dart';
import '../realtime/realtime_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_toast.dart';
import 'identity_widgets.dart';
import 'worker_chat_target.dart';

/// 打手态 · **客服大厅**（负责人 2026-10-08：「有人申请客服 → 有客服权限的人用打手端主动接，
/// 就像接单大厅那样」）。
///
/// ## 它是什么
/// 一个**待接入池**：老板发起客服咨询后，会话进入池子；持有客服权限的打手（= 客服）
/// 在打手态底部第 4 项「客服」里看到它，**谁先点「接入」谁得**（抢占式）。
/// 已经被别人接走的条目会**立刻从列表里消失**（服务端 `cs:claimed` 实时事件 + 本次刷新兜底）。
///
/// ## 与「接单大厅」的关系（照抄它的版式与语汇，不另造一套）
/// | 元素 | 接单大厅 | 客服大厅（本页） |
/// |---|---|---|
/// | 页头 | `IdentityWorkerPageHeader` 标题 17dp w700 + 右侧刷新 | 同一组件 |
/// | 事实行 | 「可接单打手 N 名 \| 当前待接 N 单」 | 「待接入 N · 在线客服 M」 |
/// | 身份细带 | 页头正下方 28dp `AppIdentityBar` | 同一位置同一组件 |
/// | 卡片 | 白底 r14 发丝线、组内 10 组间 22 | 同一套取值 |
/// | 主行动 | 卡底右侧「抢单」主色实心 32dp | 卡右「接入」主色实心 32dp |
/// | 空态 | `IdentityWorkerEmptyState` | 同一组件 |
/// | 失败 | 中文原因 + 「重试」（**不允许无限转圈**） | 同一口径 |
/// | 刷新 | 下拉强回源 + SWR 秒开 + 实时事件强刷 | 同一套（见下） |
///
/// ## 刻意**不做**的东西（docs/21「不存在的东西不出现」）
/// - **搜索框**：`GET /worker/cs/hall` 没有 keyword 参数（服务端契约里就没有）；
/// - **「退回池子」按钮**：负责人对 release 的原话是「仍待定」→ 客户端本轮**不渲染**它
///   （服务端已实现 + 开关控制，见 `server/src/modules/chat/cs-hall.ts`）。少一个按钮
///   不会挡路，多一个未定案的按钮反而会让人以为"退了就没事了"；
/// - **老板头像 / 订单信息 / 金额**：大厅只需要"谁在等 + 等什么 + 等了多久"，
///   多一列就等于多一列可被扫走的注意力（也与服务端只回 nickname + uid 的取齐）。
///
/// ## 权限门控（两道，缺一不可）
/// 1. **入口**：底部第 4 项只在 `canServeCustomer == true` 时存在（见 `worker_shell.dart`）；
/// 2. **页面**：服务端**每请求实时查库**，权限刚被撤销时 `GET /worker/cs/hall` 会回中文 403 →
///    本页据此切成「你没有客服权限」的说明态，**不渲染任何「接入」按钮**
///    （不是弹一个 toast 就留在原地：留在原地会让人反复点一个必然失败的按钮）。
class IdentityWorkerCsHallPage extends StatefulWidget {
  const IdentityWorkerCsHallPage({
    super.key,
    this.api,
    this.openChat,
    this.onSwitchBack,
    this.onClaimed,
  });

  final ApiClient? api;

  /// 聊天页注入（宿主 App 提供；见 [IdentityWorkerChatOpener]）
  final IdentityWorkerChatOpener? openChat;

  /// 身份细带右侧「切回老板」（由 shell 注入同一套切换流程）
  final VoidCallback? onSwitchBack;

  /// 接入成功后的回调（宿主可用来切到「消息 › 客服」；不传则只进会话详情）
  final void Function(String conversationId)? onClaimed;

  // ---------------------------------------------------------------- 文案常量
  // 全部放在 widget 上（而不是 State 里）：测试与出图断言的就是生产同一份字符串。

  /// 页头标题
  static const String title = '客服大厅';

  /// 页头一句说明（紧贴标题下方，小灰字）
  static const String subtitle = '等待接入的咨询，先到先得';

  /// 空态（语气与接单大厅的「大厅暂无待接订单」一致：陈述事实 + 给一条可做的事）
  static const String emptyTitle = '当前没有等待接入的咨询';
  static const String emptyDetail = '老板发起咨询后会实时出现在这里，也可以下拉刷新看看。';

  /// 权限刚被撤销时的说明（服务端中文原文优先，这句是兜底）
  static const String deniedTitle = '你没有客服权限';
  static const String deniedDetail = '客服权限由平台单独开通，与接单权限互相独立；'
      '开通后这里会重新出现等待接入的咨询。';

  /// 「接入」按钮文案（与接单大厅的「抢单」同一种动词短语长度）
  static const String claimLabel = '接入';

  /// 等待超过这个秒数 → 等待时长改用**小字金**（`AppColors.goldText` = #935F06，11.5px 白底 5.41:1）
  ///
  /// 为什么是 5 分钟：客服的自我承诺口径是"尽快接入"，5 分钟是"这位老板已经等了一会儿"的
  /// 第一档可感知阈值；再短的阈值会让整屏都在发黄（等于没有强调）。
  static const int longWaitSeconds = 300;

  /// 列表每页条数（与 `cs-hall.ts` 的 `CS_HALL_PAGE_SIZE_DEFAULT` 同源）
  static const int pageSize = 20;

  /// 「被抢走」轻提示的停留时长（一行内联提示，不弹窗打断）
  static const Duration noticeDuration = Duration(seconds: 4);

  /// 淡出时长（被抢走的条目：先淡出，再移除）
  static const Duration fadeOutDuration = Duration(milliseconds: 220);

  @override
  State<IdentityWorkerCsHallPage> createState() => IdentityWorkerCsHallPageState();
}

class IdentityWorkerCsHallPageState extends State<IdentityWorkerCsHallPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  final List<void Function()> _offEvents = [];

  List<CsHallItem> _items = const [];
  int _waitingTotal = 0;
  int _onlineCs = 0;

  bool _loading = true;
  String? _error;

  /// 服务端中文拒绝（权限刚被撤销）时的说明；非 null = 渲染说明态、**不渲染接入按钮**
  String? _denied;

  /// SWR 三件套（与接单大厅同一口径）：整页转圈只允许发生在 [_hasLoadedOnce] 还是 false 时
  bool _hasLoadedOnce = false;
  bool _refreshing = false;
  _CsHallSource? _bodySource;

  /// 正在接入中的会话 id（按钮 loading + **防连点**：同一条第二次点击直接丢弃）
  final Set<String> _claiming = <String>{};

  /// 正在淡出的会话 id（被抢走：先淡出，再移除）
  final Set<String> _fading = <String>{};

  /// 一行轻提示（被抢走 / 其它不打断的告知）；null = 不渲染这一行
  String? _notice;
  Timer? _noticeTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _initRealtime();
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    for (final off in _offEvents) {
      off();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据层

  /// 实时事件：`cs:new` 有新咨询进池 / `cs:claimed` 某条被抢走（名字以服务端最终实现为准）
  void _initRealtime() {
    final token = AuthStore.instance.activeToken;
    if (token == null) return;
    _realtime.connect(token: token);
    // 新咨询进池 → **绕过 SWR 强刷**（否则大厅会停在上一次的列表上）
    _offEvents.add(_realtime.on('cs:new', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('cs:claimed', _onClaimedEvent));
    // 断开重连后补一次（断线期间进池的咨询不该丢）
    _offEvents.add(_realtime.on('connect', (_) => _reloadQuietly()));
  }

  /// 别人抢走了某一条：**本地先淡出移除**（即时反馈），再静默回源确认
  ///
  /// 为什么先本地移除而不是等下一次刷新：抢占式的体验就在这里 ——
  /// 慢一个往返的话，用户会对着一条已经不属于任何人的条目继续点「接入」。
  void _onClaimedEvent(dynamic data) {
    final map = data is Map ? data : const <String, dynamic>{};
    final id = '${map['conversationId'] ?? ''}';
    if (id.isEmpty || !mounted) return;
    final who = '${map['workerNickname'] ?? map['byNickname'] ?? ''}'.trim();
    setState(() => _fading.add(id));
    _showNotice(who.isEmpty ? '该咨询已被其他客服接入' : '已被 客服$who 接入');
    Future<void>.delayed(IdentityWorkerCsHallPage.fadeOutDuration, () {
      if (!mounted) return;
      setState(() {
        _fading.remove(id);
        _items = _items.where((e) => e.conversationId != id).toList();
        if (_waitingTotal > 0) _waitingTotal -= 1;
      });
    });
    unawaited(_reloadQuietly());
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(IdentityWorkerCsHallPage.noticeDuration, () {
      if (mounted) setState(() => _notice = null);
    });
  }

  /// 进页面 / 用户主动刷新 / 重试：**先用缓存秒开，再强制回源**
  ///
  /// 不变量（与接单大厅同一条）：**缓存只负责"先亮出来"，绝不承担"结论"**。
  /// 因此这里对网络那一发永远用 `forceRefresh: true` —— 若走 `forceRefresh: false`，
  /// 刚写进缓存的条目在 TTL（15s）内是"新鲜"的，`ApiClient.request` 会**直接返回缓存、
  /// 一个请求都不发**，于是"进页面就刷新"这条需求会**静默失效**（单测里表现为
  /// "缓存里的内容换不掉"）。缓存的全部价值就是那 0 等待的第一帧。
  ///
  /// 「切走再回来不重复请求」由结构保证：打手态是 `IndexedStack`，切底部 tab **不会**
  /// 重建本页 State，因此 `initState` 只跑一次 —— 不需要额外写"防重复请求"的代码。
  Future<void> _load() async {
    final cached = _seedFromCache();
    if (cached != null && !_hasLoadedOnce) _apply(cached);
    await _fetchAndApply();
  }

  Future<void> _reloadQuietly() async {
    try {
      await _fetchAndApply();
    } catch (_) {
      // 静默：下一次事件或下拉刷新会重试
    }
  }

  Future<void> _fetchAndApply() async {
    setState(() {
      _error = null;
      if (_items.isEmpty && !_hasLoadedOnce) _loading = true;
    });
    await _setRefreshing(true);
    try {
      _apply(await _fetchHall());
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 服务端中文拒绝（权限被撤销 / 无权进这个池子）→ 说明态，而不是"报错 + 重试"
        if (_isPermissionDenied(e)) {
          _denied = e.message.isEmpty ? IdentityWorkerCsHallPage.deniedTitle : e.message;
          _items = const [];
          _hasLoadedOnce = true;
        } else {
          _error = e.message;
        }
      });
    } finally {
      await _setRefreshing(false);
    }
  }

  /// 是不是"没有客服权限"这一类拒绝
  ///
  /// 判据两条（任一命中）：HTTP/业务码 403，或中文里出现「客服权限」。**刻意不只看 403** ——
  /// 服务端把权限拒绝统一给 403 中文，但网关/代理也可能回 403 而文案不同；反过来只认文案
  /// 又会在文案改字时失效。两条取或，代价只是"文案里恰好带这四个字的其它 403"也走说明态，
  /// 而那种情况下"显示你没有客服权限"仍然是比"报错 + 重试"更好的答案。
  static bool _isPermissionDenied(ApiException e) =>
      e.code == 403 || e.message.contains('客服权限');

  Future<void> _setRefreshing(bool value) async {
    if (!mounted || _refreshing == value) return;
    setState(() => _refreshing = value);
  }

  /// `GET /worker/cs/hall` 的请求参数（**缓存键含分页**，与接单大厅同源）
  Map<String, dynamic> _query() => {'page': 1, 'pageSize': IdentityWorkerCsHallPage.pageSize};

  Future<_CsHallResult> _fetchHall() async {
    final resp = await _api.request(
      'GET',
      '/worker/cs/hall',
      token: AuthStore.instance.activeToken,
      // forceRefresh: true → **绕过缓存读并强回源**（进页面 / 下拉 / 页头刷新 / 实时事件 / 抢失败后重拉
      // 全都走这一条；唯一的非 force 用法是 `_seedFromCache` 的"先把屏填上"）
      forceRefresh: true,
      queryParameters: _query(),
    );
    return _CsHallResult.fromBody(resp, source: _CsHallSource.network);
  }

  /// 读本页缓存把屏先填上（任何已存在的条目都算命中，不看新鲜度 —— 它只负责"先亮出来"，
  /// 紧接着一定回源覆盖，所以不存在"拿过期数据糊弄用户"）
  _CsHallResult? _seedFromCache() {
    final entry = ApiCache.instance.get(_api.cacheKeyOf('/worker/cs/hall', _query()), Duration.zero);
    if (entry == null) return null;
    return _CsHallResult.fromBody(entry.body, source: _CsHallSource.cache);
  }

  /// **唯一**的上屏出口（缓存渲染与网络响应走同一条路，不会出现两套渲染漂移）
  void _apply(_CsHallResult r) {
    if (!mounted) return;
    setState(() {
      _items = r.items;
      _waitingTotal = r.waitingTotal;
      _onlineCs = r.onlineCs;
      _denied = null;
      _error = null;
      _loading = false;
      _hasLoadedOnce = true;
      _bodySource = r.source;
    });
  }

  // ------------------------------------------------------------------ 抢占

  /// 点「接入」：**抢占式**，谁先点谁得
  ///
  /// 防连点两层：
  ///   ① [_claiming] 里已有这条 → 直接 return（**不发第二个请求**，负向用例⑩钉这条）；
  ///   ② 按钮自身 `busy` → `onPressed` 变 null（连点根本进不来）。
  Future<void> _claim(CsHallItem item) async {
    if (_claiming.contains(item.conversationId)) return;
    setState(() => _claiming.add(item.conversationId));
    try {
      await _api.request(
        'POST',
        '/worker/cs/hall/${item.conversationId}/claim',
        token: AuthStore.instance.activeToken,
        // 服务端契约：这个 POST **没有 body**（`@Post('hall/:conversationId/claim')` 只吃路径参数）
        // —— 刻意不传 `{}`：幂等语义由服务端 `alreadyClaimed` 表达，不靠客户端塞任何东西。
      );
      if (!mounted) return;
      // 成功 → 本地立刻移除（不进"已接入"列表：那不是大厅的内容），再进会话详情
      setState(() {
        _items = _items.where((e) => e.conversationId != item.conversationId).toList();
        if (_waitingTotal > 0) _waitingTotal -= 1;
      });
      widget.onClaimed?.call(item.conversationId);
      await _openConversation(item);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 失败 → **中文原因 toast（服务端原文）** + **立刻刷新列表**
      // （刷新是必须的：抢失败最常见的原因就是"已被别人接走"，不刷新的话那条还挂在屏上）
      AppToast.error(context, e.message);
      await _reloadQuietly();
    } finally {
      if (mounted) setState(() => _claiming.remove(item.conversationId));
    }
  }

  Future<void> _openConversation(CsHallItem item) async {
    final opener = widget.openChat;
    if (opener == null) {
      if (mounted) AppToast.info(context, '本机未接入聊天页，请到「消息 › 客服」里继续');
      return;
    }
    await opener(
      context,
      IdentityWorkerChatTarget(
        conversationId: item.conversationId,
        title: item.bossNickname.isEmpty ? '老板' : item.bossNickname,
        csConversation: true,
        // 大厅这一条是**我刚接入的**（`claim` 成功才会走到这里）→ 我是当事客服，走 worker 侧：
        // 聊天页据此把 id 带进 `/worker/cs/conversations/<id>/close`，同时服务多条也不会关错。
        csServing: true,
        peerNickname: item.bossNickname,
      ),
    );
    if (mounted) await _reloadQuietly();
  }

  // ------------------------------------------------------------------ 渲染

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IdentityWorkerPageHeader(
          title: IdentityWorkerCsHallPage.title,
          actions: [
            IdentityWorkerHeaderButton(
              icon: AppIdentityIcons.refresh,
              tooltip: '刷新',
              onTap: _load,
            ),
          ],
          // 事实行 = 一句说明（紧贴标题，小灰字）
          fact: Text(
            IdentityWorkerCsHallPage.subtitle,
            style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
          ),
          // 统计行（真实数据；待接入 N=0 时也显示，只是弱化）
          bottom: _statsRow(),
          // 身份细带：页头正下方、滚动内容之上、不随内容滚动（A+ 清单 ID-A）
          banner: AppIdentityBar(
            workerNo: _workerNo,
            nickname: _workerNickname,
            onSwitchBack: widget.onSwitchBack,
          ),
        ),
        _noticeRow(),
        _refreshLine(),
        Expanded(child: _content()),
      ],
    );
  }

  String get _workerNo {
    final wm = AuthStore.instance.workerMe;
    if (wm != null && wm.workerNo.isNotEmpty) return wm.workerNo;
    return AuthStore.instance.identityStatus?.worker?.workerNo ?? '';
  }

  String get _workerNickname {
    final wm = AuthStore.instance.workerMe;
    if (wm != null && wm.nickname.isNotEmpty) return wm.nickname;
    return AuthStore.instance.identityStatus?.worker?.nickname ?? '';
  }

  /// 统计行：`待接入 N · 在线客服 M`（两个数字都是服务端真实数据）
  ///
  /// `N == 0` 时**照常显示**（"现在没人等"本身就是要传达的信息），只把数字降一档颜色 ——
  /// 弱化不等于隐藏，隐藏会让人以为这一行坏了。
  Widget _statsRow() {
    final n = _waitingTotal;
    final dim = n == 0 || _denied != null;
    return Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: dim ? AppColors.textTertiary : AppColors.statusOnline,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        const Text('待接入 ', style: _statStyle),
        Text('$n', style: dim ? _statDim : _statStrong),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('·', style: TextStyle(fontSize: 11.5, color: T.divider)),
        ),
        const Text('在线客服 ', style: _statStyle),
        Text('$_onlineCs', style: _denied == null ? _statStrong : _statDim),
        /**
         * 后台刷新中的细进度：与接单大厅同一口径 —— **列表保持可见，只在事实行右侧转一个 10dp**，
         * 不整页转圈、不抖动布局（把它挂在行尾，不新增一行）。
         */
        if (_refreshing)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: AppColors.primary),
            ),
          ),
      ],
    );
  }

  static const _statStyle = TextStyle(fontSize: 11.5, color: AppColors.mutedText);
  static const _statStrong =
      TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
  static const _statDim = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textTertiary);

  /// 一行轻提示（**不弹窗打断**）：被抢走时说清"谁接走了"，4 秒后自动消失
  @visibleForTesting
  Widget noticeRow() => _noticeRow();

  Widget _noticeRow() {
    final text = _notice;
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 9, AppSpacing.page, 9),
      decoration: BoxDecoration(
        color: AppColors.goldSoft,
        border: Border(bottom: BorderSide(color: T.divider)),
      ),
      child: Row(
        children: [
          const AppIcon.of(AppIdentityIcons.info, size: 13, color: AppColors.goldText),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppColors.goldText, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部**细进度线**（后台刷新中）：2dp，只在刷新时占位（与接单大厅同一条实现）
  Widget _refreshLine() {
    if (!_refreshing) return const SizedBox.shrink();
    return const SizedBox(
      height: 2,
      child: LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: Color(0x00000000),
        color: AppColors.primary,
      ),
    );
  }

  Widget _content() {
    // 【整页转圈的唯一合法时机】首屏第一次（此后一律保留旧列表 + 细进度）
    if (_loading && !_hasLoadedOnce) {
      return const Center(
        child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2)),
      );
    }
    return RefreshIndicator(
      // 用户主动刷新 → **强制回源**（`_load` 里那一发永远是 force）
      onRefresh: _load,
      child: _denied != null
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [_deniedState()],
            )
          : _error != null
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    // 失败要看得见：中文原因 + 「重试」（**不允许无限转圈**）
                    IdentityWorkerEmptyState(
                      icon: AppIdentityIcons.info,
                      title: _error!,
                      detail: '下拉或点右上刷新重试。',
                      action: '重试',
                      onAction: _load,
                    ),
                  ],
                )
              : _items.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [_emptyState()],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 22),
                      children: [
                        // 组内紧 10 / 组间松 22（docs/21）
                        for (var i = 0; i < _items.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _card(_items[i]),
                        ],
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            // 「已经到底了」是**结论**：只在数据真的来自服务端时才给
                            _bodySource != _CsHallSource.cache ? '已经到底了 · 共 $_waitingTotal 条等待接入' : '',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 10.5, color: AppColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
    );
  }

  /// 权限刚被撤销：中文说明 + **没有任何「接入」按钮**
  Widget _deniedState() => IdentityWorkerEmptyState(
        icon: AppIdentityIcons.badge,
        title: _denied == IdentityWorkerCsHallPage.deniedTitle ? _denied! : IdentityWorkerCsHallPage.deniedTitle,
        detail: _denied == IdentityWorkerCsHallPage.deniedTitle
            ? IdentityWorkerCsHallPage.deniedDetail
            : '${_denied!}。${IdentityWorkerCsHallPage.deniedDetail}',
        action: '联系客服',
        onAction: _contactCustomerService,
        topPadding: 48,
      );

  /// 空态：**绝对不是报错页**（语气与接单大厅的「大厅暂无待接订单」一致）
  Widget _emptyState() => const IdentityWorkerEmptyState(
        icon: AppIdentityIcons.headset,
        title: IdentityWorkerCsHallPage.emptyTitle,
        detail: IdentityWorkerCsHallPage.emptyDetail,
      );

  Widget _card(CsHallItem item) {
    final fadingOut = _fading.contains(item.conversationId);
    final busy = _claiming.contains(item.conversationId);
    return AnimatedOpacity(
      // 被抢走 → 淡出（220ms）后再移除；不做位移、不做缩放（docs/21：动效要克制）
      opacity: fadingOut ? 0 : 1,
      duration: IdentityWorkerCsHallPage.fadeOutDuration,
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: T.divider),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          item.bossNickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: T.textPrimary,
                            height: 1.35,
                          ),
                        ),
                      ),
                      if (item.bossDisplayId.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          item.bossDisplayId,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 首条摘要：**一行截断**（图片消息服务端已给「【图片】」这类占位）
                  Text(
                    item.summary.isEmpty ? '（暂无消息）' : item.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: AppColors.mutedText, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      // 等待时长：**超过 5 分钟用小字金**（AppColors.goldText = #935F06）
                      Text(
                        item.waitLabel,
                        key: csHallWaitKey(item.conversationId),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: item.isLongWait ? FontWeight.w600 : FontWeight.w400,
                          color: item.isLongWait ? AppColors.goldText : AppColors.mutedText,
                        ),
                      ),
                      if (item.messageCount > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text('|', style: TextStyle(fontSize: 11.5, color: T.divider)),
                        ),
                      if (item.messageCount > 0)
                        Text(
                          '${item.messageCount} 条消息',
                          style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AppIdentityPrimaryButton(
              label: IdentityWorkerCsHallPage.claimLabel,
              height: 32,
              expand: false,
              // 接入中 → 按钮进入 loading（转圈 + 不可点）→ 连点根本进不来
              busy: busy,
              onPressed: () => _claim(item),
            ),
          ],
        ),
      ),
    );
  }

  /// 等待时长文本的 key（测试/出图定位"到底哪个颜色"用；不靠找 Text 猜）
  @visibleForTesting
  static Key csHallWaitKey(String conversationId) => Key('cs-hall-wait-$conversationId');

  /// 「联系客服」：与打手态其它页同一条真实入口（`GET /user/conversation` 拿/建客服会话）
  Future<void> _contactCustomerService() async {
    try {
      final resp = await _api.request('GET', '/user/conversation', token: AuthStore.instance.activeToken);
      final convId = '${resp['data']?['id'] ?? ''}';
      if (!mounted) return;
      final opener = widget.openChat;
      if (opener == null) {
        AppToast.info(context, '本机未接入聊天页，请到「消息 › 客服」里联系');
        return;
      }
      await opener(
        context,
        IdentityWorkerChatTarget(
          conversationId: convId,
          title: '联系客服',
          csConversation: true,
          // 「联系客服」拿到的是**我发起的那条**（`GET /user/conversation`）→ `user` 侧（缺省即 false）
          peerNickname: '祁连山客服',
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message);
    }
  }
}

/// 屏上这份大厅数据**来自哪里**（决定"已经到底了"这句结论能不能下 —— 与接单大厅同一口径）
enum _CsHallSource { cache, network }

/// 一次客服大厅请求的结果（`/worker/cs/hall` 的解析产物）
class _CsHallResult {
  const _CsHallResult({
    required this.items,
    required this.waitingTotal,
    required this.onlineCs,
    required this.source,
  });

  final List<CsHallItem> items;
  final int waitingTotal;
  final int onlineCs;
  final _CsHallSource source;

  static _CsHallResult fromBody(Map<String, dynamic> body, {required _CsHallSource source}) {
    final data = body['data'] as Map<String, dynamic>?;
    final items = (data?['list'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => CsHallItem.fromJson(e.cast<String, dynamic>()))
        .toList();
    return _CsHallResult(
      items: items,
      // 服务端两个字段同值；缺 `waitingTotal` 时回落到 `total`，再回落到本页条数
      waitingTotal: (data?['waitingTotal'] as num?)?.toInt() ??
          (data?['total'] as num?)?.toInt() ??
          items.length,
      onlineCs: (data?['onlineCsCount'] as num?)?.toInt() ?? 0,
      source: source,
    );
  }
}

/// 客服大厅的一条待接入咨询
///
/// ## 字段名为什么有"两个候选"
/// 任务书给的契约是 `bossNickname / bossDisplayId / summary / waitSeconds / waitText / messageCount`，
/// 而**服务端已落地的实现**用的是 `userNickname / userUid / preview / waitedSeconds / waitedText / msgCount`
/// （`server/src/modules/chat/chat.service.ts` 的 `csHall`）。两者都对同一件事命名了一次。
/// 本类**同时接受两套拼写**（任务书口径优先、服务端口径兜底）—— 好处是：
/// 无论联调时最终是哪一套，客户端都不会显示空白；而且**不需要**为了改一个字段名动页面代码。
/// 联调时若发现第三套拼写，只改 [fromJson] 一处。
class CsHallItem {
  const CsHallItem({
    required this.conversationId,
    required this.bossNickname,
    required this.bossDisplayId,
    required this.summary,
    required this.waitSeconds,
    required this.waitText,
    required this.messageCount,
    this.createdAt,
  });

  final String conversationId;
  final String bossNickname;
  final String bossDisplayId;
  final String summary;
  final int waitSeconds;

  /// 服务端给的人类可读等待时长（为空则由客户端 [formatWait] 生成，两者**同口径**）
  final String waitText;
  final int messageCount;
  final String? createdAt;

  /// 超过 [IdentityWorkerCsHallPage.longWaitSeconds]（5 分钟）→ 等待时长要用琥珀金
  bool get isLongWait => waitSeconds > IdentityWorkerCsHallPage.longWaitSeconds;

  /// 屏上显示的等待文案
  ///
  /// 服务端的 `humanWait()` 给的是**纯时长**（「刚刚」/「5 分钟」/「1 小时 12 分钟」），
  /// 直接贴上去会变成「等待 刚刚」这种病句，所以这里补一个词：
  /// 「刚刚」→「刚刚提交」，其余 →「等待 X」。
  String get waitLabel {
    final t = waitText.trim();
    if (t.isEmpty) {
      final f = formatWait(waitSeconds);
      return f == '刚刚' ? '刚刚提交' : '等待 $f';
    }
    return t.startsWith('刚刚') ? '刚刚提交' : '等待 $t';
  }

  /// 等待时长的中文格式（**与 `server/src/modules/chat/chat.service.ts` 的 `humanWait` 逐字同口径**）
  ///
  /// 服务端没下发 `waitText` 时用它兜底，保证两端口径不会各说一套。
  static String formatWait(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    if (s < 60) return '刚刚';
    final m = s ~/ 60;
    if (m < 60) return '$m 分钟';
    final h = m ~/ 60;
    if (h < 24) return '$h 小时 ${m % 60} 分钟';
    return '${h ~/ 24} 天 ${h % 24} 小时';
  }

  /// 宽容解析：两套字段名都认（见类注释），缺字段一律给"能渲染"的值，绝不抛异常
  factory CsHallItem.fromJson(Map<String, dynamic> json) {
    String str(List<String> keys) {
      for (final k in keys) {
        final v = '${json[k] ?? ''}'.trim();
        if (v.isNotEmpty && v != 'null') return v;
      }
      return '';
    }

    int num0(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v is num) return v.toInt();
        if (v is String) {
          final p = int.tryParse(v);
          if (p != null) return p;
        }
      }
      return 0;
    }

    return CsHallItem(
      conversationId: str(const ['conversationId', 'id']),
      bossNickname: str(const ['bossNickname', 'userNickname', 'nickname', 'peerNickname']),
      bossDisplayId: str(const ['bossDisplayId', 'userUid', 'uid']),
      summary: str(const ['summary', 'preview', 'lastContent']),
      waitSeconds: num0(const ['waitSeconds', 'waitedSeconds']),
      waitText: str(const ['waitText', 'waitedText']),
      messageCount: num0(const ['messageCount', 'msgCount']),
      createdAt: str(const ['createdAt', 'waitingSince']).isEmpty ? null : str(const ['createdAt', 'waitingSince']),
    );
  }
}
