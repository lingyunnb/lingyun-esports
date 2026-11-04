import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'friend_profile_page.dart';
import 'friend_requests_page.dart';

/// 添加好友 · **即时搜索**（A 套设计稿 `site/design/add-friend/a-instant.html`，
/// 负责人 2026-10-05 审批）
///
/// 一句话：把「搜」变成「打」——进页面即聚焦，输入 ≥2 个字**防抖 250ms 自动搜**，
/// 未处理的申请压成页头一个带角标的入口。
///
/// 本页逐条修掉设计阶段查清的缺陷：
/// - **D1** 原「空输入 + 搜索按钮」→ 现在自动聚焦 + 边输边搜（`_onChanged` / `_debounce`）
/// - **D2** 原结果卡是 `GlassSurface`（带阴影 + 圆角 12/10 不在分档内）→ 现在**白底发丝线**、
///   圆角只用分档 6/10/14、**零阴影零玻璃**（整页不含任何 `FishGlass*`）
/// - **D3** 原同一条结果 3 种按钮语义 → 现在 `friendStatus` 五态各**只有一个**动作
///   （`_action`）：可加=主色实色「添加」、已申请=灰态「等待验证」、对方申请你=唯一次级「同意」、
///   已是好友=灰态「已是好友」、自己=灰态「这是我」
/// - **D5** 空态/错误态原来只有一行字 → 现在 5 种状态**各自独立视觉与文案**（`_Phase`）
/// - **D6** 申请列表原来唯一入口挂在一段未引用代码上（几乎不可达）→ 现在页头「申请」+ 未处理角标
/// - **D7** 等级胶囊占主信息位、复制/ID 交互不清 → 等级不再进结果行，ID 用等宽字 + 事实行可复制
/// - **D8** 占位文案原写 `U2741312533`（界面里不存在这种格式）→ 现在用真实 uid 形态 `he_yutong`
/// - **D9** 本页入口全 App 只留一处：**消息 › 好友私聊 › 右上「+」**
/// - **D10** 原来整屏转圈、输入框与结果位置跳动 → 现在输入框固定，只在**结果区**给面板 + 骨架
///
/// 文案纪律：**错误一律取服务端原文**（`ApiException.message`），页面只补"下一步"提示，
/// 不硬编码任何错误码文案（服务端改词，界面跟着变）。
///
/// **2026-10-17 负责人真机反馈：注释型浅色小字全删** —— 本页删掉的是
/// ① 「热门搜索」整块（1.~5. 示例清单，后端无该接口、纯编造）；
/// ② 「不是「加了好友才能聊天」——私聊与好友是两件事，这里只加好友。」整段；
/// ③ 底部三行小字（「加好友 要对方同意…」/「搜昵称 只返回最匹配的 1 个…」/
///    「对方用 ID 加你；24 小时内最多修改 3 次…」）；
/// ④ 空态里那段「搜的是完整 ID 或昵称的一部分…」规则解释；
/// ⑤ 结果行下方的「在 消息 › 好友私聊 里找到他」；
/// ⑥ 输入框下那行里"解释规则/给示例"的整句（含「输入 2 个字开始搜；UID 要完整，如 he_yutong」）；
/// ⑦ 「我的好友」标题右侧的「来自 消息 › 好友私聊」。
/// **保留**：可点击的功能（「清空重输」「复制我的 ID」「添加/同意/等待验证」、最近搜索标签、
/// 「发申请时带上我的昵称」开关、**"我的 ID" + 其「复制」按钮**）与状态事实（「找到 1 个用户」
/// 「再输入 1 个字就可以搜了」、服务端原文错误提示）。
class FriendSearchPage extends StatefulWidget {
  const FriendSearchPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  /// 稳定锚点：出图与断言用（状态切换/滚动都不影响定位）
  static const Key fieldKey = Key('friend-search-field');
  static const Key requestsEntryKey = Key('friend-search-requests-entry');
  static const Key loadingKey = Key('friend-search-loading');
  static const Key resultRowKey = Key('friend-search-result-row');
  static const Key actionKey = Key('friend-search-action');
  static const Key emptyKey = Key('friend-search-empty');
  static const Key errorKey = Key('friend-search-error');
  static const Key postErrorKey = Key('friend-search-post-error');

  @override
  State<FriendSearchPage> createState() => _FriendSearchPageState();
}

/// 结果区状态机：每个状态有**独立的视觉与文案**（D5）
enum _Phase {
  /// 未输入：给「我的好友」，不空屏
  idle,

  /// 只输了 1 个字：提示再输一个字（**不发请求**，D1）
  tooShort,

  /// 已发出请求、等结果：结果区给面板 + 骨架（输入框与结果位置不动，D10）
  loading,

  /// 命中：结果行（动作由 friendStatus 决定）
  found,

  /// 404 `未找到该用户`：空态 + 下一步动作
  notFound,

  /// 其它失败（400 格式非法 / 网络等）：错误面板
  failed,
}

class _FriendSearchPageState extends State<FriendSearchPage> {
  static const Duration _debounceDelay = Duration(milliseconds: 250);

  /// 后端门槛（`friend.service.ts` UID_PATTERN：**2-20 位**中文/字母/数字/下划线）→
  /// 客户端在 2 个字之前不发请求，省掉注定查不到的一次往返
  static const int _minChars = 2;

  late final ApiClient _api = widget.api ?? ApiClient();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;

  /// 请求序号：连打时只认最后一次响应（防旧响应覆盖新结果）
  int _seq = 0;

  _Phase _phase = _Phase.idle;
  UserBriefModel? _result;

  /// 服务端原文（搜索失败 或 加好友被挡回）——一律原样展示
  String? _searchError;
  String? _actionError;

  /// 我收到的待处理申请数（页头角标）与申请原文（`pending_in` 时「同意」要用申请 id）
  int _pending = 0;
  List<FriendRequestModel> _incoming = const [];

  /// 已有好友（未输入时填充空屏；最多展示 3 行）
  List<UserBriefModel> _friends = const [];

  /// 我的展示 ID（对方用它加我）：优先服务端搜索响应里的 `myUid`，其次登录资料
  String _myUid = '';

  /// 「发申请时带上我的昵称」（设计稿结果行的次级文本按钮；默认开）
  bool _attachNickname = true;
  bool _focused = false;

  /// 最近搜索（方案 G「历史标签」）：**仅本页会话内**，不上传、不落盘、不调接口
  final List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _myUid = AuthStore.instance.me?.uid ?? '';
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
    _loadAside();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 页头角标（incoming）+ 空屏用的好友列表：失败静默（不影响搜索主流程）
  ///
  /// [force]：动作后回源（等服务端落库，绕开 45s SWR 缓存）
  Future<void> _loadAside({bool force = false}) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final results = await Future.wait([
        _api.request('GET', '/user/friends/requests/incoming', token: token, forceRefresh: force),
        _api.request('GET', '/user/friends', token: token, forceRefresh: force),
      ]);
      if (!mounted) return;
      setState(() {
        _incoming = _list(results[0]).map((e) => FriendRequestModel.fromJson(e)).toList();
        _pending = _incoming.length;
        _friends = _list(results[1]).map((e) => UserBriefModel.fromJson(e)).toList();
      });
    } on ApiException {
      // 静默：角标与"我的好友"都不是本页主路径
    }
  }

  List<Map<String, dynamic>> _list(Map<String, dynamic> resp) =>
      ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  // ---------------- 搜索（D1：边输边搜，防抖 250ms；D10：位置不动）----------------

  void _onChanged(String raw) {
    final q = raw.trim();
    _debounce?.cancel();
    setState(() {
      _actionError = null;
      _searchError = null;
      if (q.length < _minChars) {
        _seq++; // 让在途响应作废
        _result = null;
        _phase = q.isEmpty ? _Phase.idle : _Phase.tooShort;
        return;
      }
      _phase = _Phase.loading;
      _result = null;
    });
    if (q.length < _minChars) return;
    final seq = ++_seq;
    _debounce = Timer(_debounceDelay, () => _search(q, seq));
  }

  Future<void> _search(String q, int seq, {bool force = false}) async {
    if (!mounted || seq != _seq) return;
    // 最近搜索（方案 G 的「历史标签」）：只记本页会话内的关键词，**不落盘、不新增接口**。
    // 不进 setState —— 历史只在 idle 相渲染，此时正处于 loading，不需要多一次重建。
    if (!_history.contains(q)) {
      _history.insert(0, q);
      if (_history.length > 6) _history.removeLast();
    }
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request('GET', '/user/friends/search',
          token: token, queryParameters: {'uid': q}, forceRefresh: force);
      if (!mounted || seq != _seq) return;
      final data = resp['data'] as Map<String, dynamic>? ?? const {};
      setState(() {
        _result = UserBriefModel.fromJson(data);
        _myUid = '${data['myUid'] ?? ''}'.isEmpty ? _myUid : '${data['myUid']}';
        _phase = _Phase.found;
        _searchError = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _result = null;
        // 文案一律服务端原文（404「未找到该用户」走空态，其余走错误面板）
        _searchError = e.message;
        _phase = e.code == 404 ? _Phase.notFound : _Phase.failed;
      });
    }
  }

  /// 清空重输（空态的第一个动作）：清内容 + 保焦点
  void _resetInput() {
    _input.clear();
    _focus.requestFocus();
    setState(() {
      _phase = _Phase.idle;
      _result = null;
      _searchError = null;
      _actionError = null;
    });
  }

  Future<void> _copyMyUid() async {
    final uid = _myUid.isEmpty ? (AuthStore.instance.me?.uid ?? '') : _myUid;
    if (uid.isEmpty) {
      AppToast.info(context, '登录资料里还没有 ID，稍后重试');
      return;
    }
    await Clipboard.setData(ClipboardData(text: uid));
    if (mounted) AppToast.success(context, '我的 ID 已复制：$uid');
  }

  // ---------------- 动作（D3：一条结果只有一个动作）----------------

  Future<void> _addFriend(UserBriefModel u) async {
    final token = AuthStore.instance.accessToken;
    final nickname = AuthStore.instance.me?.nickname ?? '';
    try {
      final resp = await _api.request(
        'POST',
        '/user/friends/requests',
        token: token,
        data: {'uid': u.uid, 'message': _attachNickname && nickname.isNotEmpty ? '你好，我是 $nickname' : ''},
      );
      if (!mounted) return;
      final auto = (resp['data'] as Map<String, dynamic>?)?['autoAccepted'] == true;
      AppToast.success(context, auto ? '对方申请过你，你们已经是好友' : '好友申请已发送');
      _resync();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 就地显示、不弹窗、不跳页；输入框内容保留（失败后重新查到最新状态）
      setState(() => _actionError = e.message);
      _resync();
    }
  }

  /// 对方已申请我：拿申请 id 走 `accept`（唯一权威路径，不靠"再申请一次"自动通过）
  Future<void> _acceptIncoming(UserBriefModel u) async {
    final token = AuthStore.instance.accessToken;
    var req = _incoming.where((r) => r.userId == u.userId).toList();
    if (req.isEmpty) {
      await _loadAside();
      req = _incoming.where((r) => r.userId == u.userId).toList();
    }
    if (req.isEmpty) {
      if (mounted) AppToast.info(context, '这条申请已不在待处理列表，请到「新的朋友」查看');
      return;
    }
    try {
      await _api.request('POST', '/user/friends/requests/${req.first.id}/accept', token: token);
      if (!mounted) return;
      AppToast.success(context, '已同意，你们现在是好友了');
      await _loadAside(force: true);
      _resync();
    } on ApiException catch (e) {
      if (mounted) setState(() => _actionError = e.message);
    }
  }

  /// 动作后回源一次：服务端状态是唯一真相（例如刚申请完 → 变「等待验证」）
  void _resync() {
    final q = _input.text.trim();
    if (q.length < _minChars) return;
    final seq = ++_seq;
    _search(q, seq, force: true);
  }

  Future<void> _openRequests() async {
    // 把注入的 api 递下去（生产为 null → 各自用默认 ApiClient；测试注入时同一条假通道）
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FriendRequestsPage(api: widget.api)));
    // 回来刷新角标（对方可能刚在列表里处理了几条）
    if (mounted) await _loadAside(force: true);
  }

  // ---------------- 视图 ----------------

  @override
  Widget build(BuildContext context) {
    // 整页**不用玻璃页壳**（D2：本页任何位置都不得出现 FishGlass* / 阴影）
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 页头白条、搜索框、结果行一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: Column(
        children: [
          _header(),
          _fieldWrap(),
          Expanded(child: SingleChildScrollView(child: _resultArea())),
          _facts(),
        ],
      )),
    );
  }

  /// 页头：白底 + 发丝线；右侧「申请」入口 + 未处理角标（**D6**：申请列表从这里真的进得去）
  Widget _header() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgCard,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              if (Navigator.of(context).canPop())
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const AppIcon.of(AppIcon.arrowLeft, size: 20, color: AppColors.textPrimary),
                  tooltip: '返回',
                )
              else
                const SizedBox(width: AppSpacing.lg),
              const Expanded(
                child: Text('添加好友',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              Material(
                key: FriendSearchPage.requestsEntryKey,
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: _openRequests,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
                    child: Row(
                      children: [
                        const Text('申请', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                        if (_pending > 0) ...[
                          const SizedBox(width: 5),
                          Container(
                            constraints: const BoxConstraints(minWidth: 18),
                            height: 18,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            decoration: BoxDecoration(
                              color: AppColors.error,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text('$_pending',
                                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 搜索域：白底 44 + 圆角 10 + 发丝线；聚焦 → 主色描边 + 3dp 10% 主色环（无阴影）
  ///
  /// 【2026-10-17 ⑦ 删注释型小字】输入框下那行提示只保留**当前状态事实**，
  /// 凡"解释规则/给示例"的整句都删（负责人：「所有那种注释型的浅色小字不要有」）：
  /// - 1 个字 → 「再输入 1 个字就可以搜了」（原尾巴「（ID 要求 2-20 位）」删）
  /// - 命中 → 「找到 1 个用户」（原「· 昵称模糊匹配只返回最匹配的一个」删）
  /// - 其余（默认 / 搜不到）→ **不再渲染任何提示行**
  ///   （原「输入 2 个字开始搜；UID 要完整，如 he_yutong」已整句删除；占位符本身已说明该输什么）
  Widget _fieldWrap() {
    final hint = switch (_phase) {
      _Phase.tooShort => '再输入 1 个字就可以搜了',
      _Phase.found => '找到 1 个用户',
      _ => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 14, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 方案 G：聚焦态 = **主色 1.5px 描边**（粗由 1 → 1.5，外圈恒占位 → 聚焦时布局不跳，D10）
          Container(
            key: FriendSearchPage.fieldKey,
            padding: const EdgeInsets.all(3),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused ? AppColors.primary : AppColors.strokeSoft,
                  width: _focused ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  AppIcon.of(AppIcon.search, size: 17, color: _focused ? AppColors.primary : AppColors.textTertiary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      autofocus: true, // D1：进页即聚焦，键盘直接起
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '输入好友 ID 或昵称（支持中文）',
                        hintStyle: TextStyle(fontSize: 14, color: AppColors.mutedText),
                      ),
                    ),
                  ),
                  if (_input.text.isNotEmpty)
                    InkWell(
                      onTap: _resetInput,
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 17,
                        height: 17,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: AppColors.textTertiary, shape: BoxShape.circle),
                        child: const AppIcon.of(AppIcon.close, size: 13, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (hint.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(hint, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.5)),
          ],
        ],
      ),
    );
  }

  Widget _resultArea() {
    switch (_phase) {
      case _Phase.idle:
        return _idleArea();
      case _Phase.tooShort:
        return const SizedBox(height: 40);
      case _Phase.loading:
        return _loadingArea();
      case _Phase.notFound:
        return _emptyArea();
      case _Phase.failed:
        return _failedArea();
      case _Phase.found:
        return _foundArea();
    }
  }

  /// 未输入：**最近搜索** + 我的好友（已有好友 → 直接进资料页），不空屏
  ///
  /// 【2026-10-17 ⑦ 删注释型小字】「热门搜索」整块、底部那句
  /// 「不是「加了好友才能聊天」——私聊与好友是两件事，这里只加好友。」、
  /// 「我的好友」标题右侧那句「来自 消息 › 好友私聊」全部删除。
  Widget _idleArea() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_history.isNotEmpty) _historyBlock(),
        if (_friends.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpacing.lg, 20, AppSpacing.lg, AppSpacing.sm),
            child: Text('我的好友',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          ),
          for (final f in _friends.take(3)) ...[
            _friendRow(f),
            _hair(),
          ],
        ],
      ],
    );
  }

  /// 最近搜索（方案 G「历史标签：白底胶囊」）：点一下就按这个关键词再搜一次
  ///
  /// 【2026-10-17 负责人真机反馈】原来它下面还有一整块「热门搜索」1.~5. 清单 ——
  /// 那是**编出来的示例 ID**（后端没有热门接口），属于注释型内容，已**整块删除**。
  /// 最近搜索本身是**可用功能**（点击即按该关键词重搜），保留。
  Widget _historyBlock() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 16, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('最近搜索',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              const Spacer(),
              // 只清本页会话内的记录（不影响任何服务端数据）
              GestureDetector(
                onTap: () => setState(_history.clear),
                child: const Text('清空', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final q in _history) _tagPill(q)],
          ),
        ],
      ),
    );
  }

  /// 白底胶囊标签（方案 G：历史标签 / 圆角 999）
  Widget _tagPill(String label) => GestureDetector(
        onTap: () => _useQuery(label),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.strokeSoft),
          ),
          child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ),
      );

  /// 用某个关键词填进输入框并立刻走**同一条**搜索链路（与手输完全一致，不新增接口）
  void _useQuery(String q) {
    _input.text = q;
    _input.selection = TextSelection.collapsed(offset: q.length);
    _focus.requestFocus();
    _onChanged(q);
  }


  /// 搜索中：把等待变成有用的确认（面板 + 骨架），**输入框与结果区位置不动**（D10）
  Widget _loadingArea() {
    return Column(
      key: FriendSearchPage.loadingKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(AppSpacing.lg, 14, AppSpacing.lg, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('正在搜「${_input.text.trim()}」…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
          child: Container(
            height: 60,
            decoration: BoxDecoration(color: AppColors.placeholderBg, borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  /// 命中：结果行（唯一动作）+ 次级说明；加好友失败时**就地**出错误条
  Widget _foundArea() {
    final u = _result;
    if (u == null) return const SizedBox(height: 40);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _resultRow(u),
        if (u.friendStatus == 'none')
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: InkWell(
              onTap: () => setState(() => _attachNickname = !_attachNickname),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                child: Text(
                  // 功能开关（不是说明文字）：保留
                  _attachNickname ? '发申请时带上我的昵称（点此取消）' : '发申请时不带昵称（点此恢复）',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.primary),
                ),
              ),
            ),
          ),
        _hair(),
        if (_actionError != null) _errorBanner(_actionError!),
      ],
    );
  }

  Widget _friendRow(UserBriefModel f) => InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FriendProfilePage(friend: f))),
        child: _row(
          AppAvatar(nickname: f.nickname, mediaId: f.avatarMediaId, size: 46),
          f.nickname,
          'ID  ${f.uid}',
          _chip('已是好友', ghost: true),
        ),
      );

  Widget _resultRow(UserBriefModel u) => _row(
        AppAvatar(nickname: u.nickname, mediaId: u.avatarMediaId, size: 46),
        u.nickname,
        'ID  ${u.uid}',
        KeyedSubtree(key: FriendSearchPage.actionKey, child: _action(u)),
        key: FriendSearchPage.resultRowKey,
      );

  /// **一条结果只有一个动作**（D3）：可加=主色实色；其余都是灰态/唯一次级「同意」
  Widget _action(UserBriefModel u) {
    switch (u.friendStatus) {
      case 'self':
        return _chip('这是我');
      case 'accepted':
        return _chip('已是好友', ghost: true);
      case 'pending_out':
        return _chip('等待验证');
      case 'pending_in':
        // 唯一允许的次级样式：白底描边（同屏不会与实色主按钮并列出现）
        return _chip('同意', outline: true, onTap: () => _acceptIncoming(u));
      default:
        return _chip('添加', primary: true, onTap: () => _addFriend(u));
    }
  }

  /// 结果行/好友行：白底 + 发丝线，**零阴影**（D2）
  Widget _row(Widget avatar, String name, String id, Widget action, {Key? key}) => Container(
        key: key,
        color: AppColors.bgCard,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.mutedText, fontFamily: 'monospace')),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            action,
          ],
        ),
      );

  /// 发丝线：1dp 分隔 + 左侧 16dp 缩进（docs/21：列表用发丝线）
  Widget _hair() => Container(
        height: 1,
        color: AppColors.divider,
        margin: const EdgeInsets.only(left: AppSpacing.lg),
      );

  /// 空态（404 未找到）：**独立视觉**，文案取服务端原文 + 给下一步动作（D5）
  Widget _emptyArea() {
    return Padding(
      key: FriendSearchPage.emptyKey,
      padding: const EdgeInsets.fromLTRB(34, 56, 34, 0),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.bgCard,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.divider),
            ),
            child: const AppIcon.of(AppIcon.users, size: 26, color: AppColors.textTertiary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(_searchError ?? '未找到该用户',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          // 【2026-10-17】原来这里还有一段「搜的是完整 ID 或昵称的一部分；昵称要至少 2 个字，
          // ID 区分大小写…」的规则解释 —— 属注释型小字，已删；下一步动作由下面两枚按钮给。
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _chip('清空重输', outline: true, onTap: _resetInput),
              const SizedBox(width: AppSpacing.sm),
              _chip('复制我的 ID', text: true, onTap: _copyMyUid),
            ],
          ),
        ],
      ),
    );
  }

  /// 其它失败（400 格式非法 / 网络）：错误面板——服务端原文 + 为什么/怎么办
  Widget _failedArea() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _errorCard(
          key: FriendSearchPage.errorKey,
          title: _searchError ?? '搜索失败',
          body: 'ID 与昵称都试一次；ID 是 2-20 位中文/字母/数字/下划线，区分大小写。',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 10, AppSpacing.lg, 0),
          child: Row(
            children: [
              _chip('清空重输', primary: true, onTap: _resetInput),
              const SizedBox(width: AppSpacing.sm),
              _chip('复制我的 ID', outline: true, onTap: _copyMyUid),
            ],
          ),
        ),
      ],
    );
  }

  /// 加好友被挡回：就地错误条（不弹系统弹窗、不跳页）——标题＝服务端原文 + 按错误给下一步
  Widget _errorBanner(String message) {
    final next = message.contains('已经是好友') || message.contains('已是好友')
        ? '直接去消息页找他聊，或在好友资料里删除后重新添加。'
        : message.contains('等待对方处理')
            ? '对方处理前不用重复申请，行内已改为「等待验证」。'
            : message.contains('不存在')
                ? '换成完整 ID 再搜一次，或让对方向你确认一下 ID。'
                : message.contains('自己')
                    ? '这就是你自己的账号，复制 ID 发给对方即可。'
                    : message.contains('格式')
                        ? 'ID 是 2-20 位中文/字母/数字/下划线，改完再试。'
                        : '可以稍后重试，或先复制我的 ID 让对方加你。';
    return _errorCard(
      key: FriendSearchPage.postErrorKey,
      title: '这次没加成：$message',
      body: next,
    );
  }

  /// 错误卡（红底 + 描边 + 圆角 10，无阴影）：`_failedArea` 与 `_errorBanner` 共用同一视觉
  Widget _errorCard({required Key key, required String title, required String body}) => Container(
        key: key,
        margin: const EdgeInsets.fromLTRB(AppSpacing.lg, 14, AppSpacing.lg, 0),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.bannerDangerBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.bannerDangerBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: AppIcon.of(AppIcon.complaint, size: 17, color: AppColors.error),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.error)),
                  const SizedBox(height: 4),
                  Text(body, style: const TextStyle(fontSize: 12, color: AppColors.error, height: 1.6)),
                ],
              ),
            ),
          ],
        ),
      );

  /// 底部事实行：**我的 ID（可复制）**（D7）
  ///
  /// 【2026-10-17 ⑦ 删注释型小字】这里原来有三行小字，**全部删除**：
  /// 「加好友 要对方同意；同意后出现在 消息 › 好友私聊」、「搜昵称 只返回最匹配的 1 个…」、
  /// 「对方用 ID 加你；24 小时内最多修改 3 次（在「我的」里改）」。
  /// **保留的是功能**：`我的 ID` + 真 uid + 「复制」按钮（负责人原话：ID 与复制留着，只删解释性文字）。
  Widget _facts() {
    final uid = _myUid.isEmpty ? (AuthStore.instance.me?.uid ?? '') : _myUid;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.bgCard,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        10 + MediaQuery.paddingOf(context).bottom, // 手势导航条下留白
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _FactLabel('我的 ID'),
          Expanded(
            child: Text(uid.isEmpty ? '登录资料读取中…' : uid,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textPrimary, fontFamily: 'monospace')),
          ),
          InkWell(
            onTap: _copyMyUid,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text('复制', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
            ),
          ),
        ],
      ),
    );
  }

  /// 统一按钮（设计稿 .btn：实色 / 描边 / 灰态 / 纯文字；**无渐变、无阴影**）
  Widget _chip(
    String label, {
    bool primary = false,
    bool outline = false,
    bool ghost = false,
    bool text = false,
    VoidCallback? onTap,
  }) {
    final Color bg = primary
        ? AppColors.primary
        : text
            ? Colors.transparent
            : ghost
                ? AppColors.bgCard
                : outline
                    ? AppColors.bgCard
                    : AppColors.fieldBg;
    final Color fg = primary
        ? Colors.white
        : outline
            ? AppColors.textPrimary
            : text
                ? AppColors.primary
                : AppColors.mutedText;
    final style = TextStyle(fontSize: text ? 12.5 : 13, fontWeight: FontWeight.w600, color: fg);
    final child = Text(label, style: style);
    if (text) {
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6), child: child),
        ),
      );
    }
    // 透明 Material 放在有底色的 Container **之内**：水波纹才画在底色之上（视觉可反馈）
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6), // 分档 6：行内小按钮
        border: outline || ghost ? Border.all(color: AppColors.divider) : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 事实行的标签列（label 深一档）
///
/// 【2026-10-17 ⑦】原 `_Fact`（label + 说明小字）随"三行小字全删"一并移除了 ——
/// 底部事实行现在只剩「我的 ID + uid + 复制」。
class _FactLabel extends StatelessWidget {
  const _FactLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: AppSpacing.sm),
        child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
      );
}
