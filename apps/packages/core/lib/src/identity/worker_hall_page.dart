import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_cache.dart';
import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../icons/app_icon.dart';
import '../models/order_brief.dart';
import '../realtime/realtime_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_page_bg.dart';
import '../widgets/app_toast.dart';
import 'identity_widgets.dart';
import 'worker_chat_target.dart';

/// ============================================================================
/// 方案 G 视觉层（2026-10-17 重构；**状态机 / 请求 / 缓存 / 自愈逻辑一个字节未改**）
/// ============================================================================
///
/// 取值与理由（与登录页、提现页同一套口径）：
/// - 页底：**白 + 极浅品牌蓝渐变**（负责人 2026-10-17）—— 由 `AppPageBg` 这一层画，
///   只铺在**列表区**：页头与身份细带仍是白的（细带是 28dp 常驻条，颜色归 `AppIdentityBar`）。
///   （原方案 G 的私有常量 `#F6F7F9` 因此停用：页底不再是实色，而是渐变。）
/// - [_hallCardRadius] `12`：方案 G 卡片圆角档（10 / 12 / 14 / 999）。
/// - 卡片 = **白底 + 1px 描边 `AppColors.strokeSoft`(`#E8ECF2`)**，不用渐变、不用阴影。
/// - 金额 = 胶囊容器（`goldSoft` 浅底）+ **大字金** `AppColors.gold`（19sp w700），
///   单位/标签一律 `AppColors.goldText`（小字金）—— 与提现页余额同一条资金口径。

/// 方案 G 卡片圆角
const double _hallCardRadius = 12;

/// 打手态 · **接单大厅**（合并双端 · 身份切换；设计稿 A 套 `a3-worker-hall.html`）
///
/// ## 与设计稿逐项对齐的部分
/// - 页头：标题「接单大厅」17dp w700 + 「打手态」状态标签 + 30x30 刷新按钮（`.phead` / `.icbtn`）
/// - 事实行：「可接单打手 N 名 | 当前待接 N 单」（圆点 5dp，11.5dp `#5B6B80`）
/// - **真实公告行**：`GET /public/announcements` 首条（`.anno`：高 36 / 冰蓝底 / `公告` 小标 + 单行省略）
/// - **分部胶囊只出"已授权"的分部**：数据源 `GET /worker/division-permissions`
///   且 `canTakeOrder == true`（服务端实时查库，管理端刚撤销的下一次进来就消失）
/// - 订单卡：商品名（最多 2 行）x 数量 | 分部 | 单号后 4 位 | 相对时间 + 琥珀金金额 + 抢单
/// - 卡底固定一行事实「接单后可见老板游戏区服与 ID」（服务端大厅本就不下发，隐私铁律）
///
/// ## 刻意**不做**的东西（docs/21「不存在的东西不出现」）
/// 搜索框（`/worker/order-hall` 没有 keyword 参数）、轮播 banner（`/public/banners` 当前为空）、
/// 会员/VIP/开通会员（平台没有会员体系）、微信区/QQ区胶囊（那是老板侧选大区，大厅按分部筛）。
class IdentityWorkerHallPage extends StatefulWidget {
  const IdentityWorkerHallPage({super.key, this.api, this.openChat, this.onSwitchBack});

  final ApiClient? api;

  /// 「联系客服」出口（宿主 App 注入聊天页；不传则退化为提示）
  final IdentityWorkerChatOpener? openChat;

  /// 身份细带右侧「切回老板」（由 shell 注入同一套切换流程）
  final VoidCallback? onSwitchBack;

  /// 页头右侧**只有刷新按钮**（A+ 清单 ID-C：删除原「打手态」绿色标签 ——
  /// 同一事实「我是打手」已由细带承担，不得出现在两个位置）。
  static const int headerActionCount = 1;

  /// 相对时间（3 分钟前 / 26 分钟前 / 1 小时前 / 昨天 / 09-28）
  ///
  /// 放在 [IdentityWorkerHallPage] 上（而不是 State 里）便于单测直接断言同一份实现。
  static String relativeTime(String iso, {DateTime? now}) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final n = now ?? DateTime.now();
    final d = n.difference(t.toLocal());
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays == 1) return '昨天';
    if (d.inDays < 30) return '${d.inDays} 天前';
    final local = t.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  State<IdentityWorkerHallPage> createState() => _IdentityWorkerHallPageState();
}

class _IdentityWorkerHallPageState extends State<IdentityWorkerHallPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  final List<void Function()> _offEvents = [];

  final List<OrderBrief> _orders = [];
  bool _loading = true;
  String? _error;

  /// 服务端下发的"该分部/无任何分部无接单权限"提示（`divisionDenied` + `message`）
  String? _deniedMessage;
  int _total = 0;

  /// null = 全部分部
  String? _divisionId;

  /// 已授权分部（胶囊只列这些）
  List<WorkerDivisionPermission> _divisions = const [];

  /// **分部加载失败的中文原因**（null = 没失败）
  ///
  /// 【2026-10-06 会话过期后 UI 静默残缺专项，负责人实测】原来 `_loadDivisions()` 整段
  /// `catch (_) {}` —— 失败没有任何痕迹：`_divisions` 空 → 胶囊整排不渲染（L512 的
  /// `if (_divisions.isNotEmpty)`）→ 用户看到的是"大厅没有分部"，**既不知道出了什么事，
  /// 也没有任何可点的下一步**。触发链：重置打手密码 → companion 会话被吊销 →
  /// `/worker/division-permissions` 失败被吞 → 直到用户手动下拉才恢复。
  ///
  /// 口径（负责人定的通用规则）：**凡是失败，都要让人看见并给出下一步**。
  /// 但"辅助请求失败绝不能拖住大厅内容"这条原则**保持不变** —— 它只影响这一行提示。
  String? _divisionError;

  /// 已自动重拉分部的次数（**上限 1 次**，见 [_maybeRecoverDivisions]）—— 防抖，不刷屏
  int _divisionRecoverTries = 0;

  /// 是否正在重拉分部（防重入：下拉刷新与自动自愈可能同时到达）
  bool _divisionRetrying = false;

  /// 已消费的**身份"代"**（[AuthStore.identityEpoch]）——涨了 = 刚刚"重新绑定 / 切换身份成功"
  ///
  /// 【2026-10-06 重绑后旧错误残留专项】见 [_onAuthChanged]：本页据此知道
  /// "手上那份失败结论属于上一个会话，已经过期了"，于是自己清错误 + 回源，
  /// 不需要用户手点「重试」。
  int _seenIdentityEpoch = 0;

  /// 自动自愈上限（次数）
  static const int _divisionRecoverMax = 1;

  /// 分部 id -> 展示名（订单卡拼分部名用）
  final Map<String, String> _divisionNames = {};

  /// 该打手可接的所有分部的"可接单打手数"合计（真实 `onlineCount`）
  int _onlineWorkers = 0;

  String? _announcement;

  /**
   * 【2026-10-06 抢单大厅延迟专项】SWR 三件套 —— 与 `product_list_page.dart:51`
   * 的 `_refreshing`「列表保持可见，只在标题行显示细进度，不整页转圈」同一口径。
   *
   * - [_hasLoadedOnce]：本页是否已经成功渲染过一份列表。**整页转圈只允许发生在它还是 false 时**
   *   （即真正的首屏第一次）；此后任何刷新（切分部/下拉/实时事件）都不再遮挡内容。
   * - [_refreshing]：后台刷新中 → 事实行右侧出一个 10dp 细进度（不遮挡、不抖动布局）。
   * - [_bodySource]：当前列表是"缓存"还是"服务端"。缓存态下不给"已经到底了 · 共 N 单待接"
   *   这句结论（那要等真实响应回来才算数），避免拿旧数据下结论。
   */
  bool _hasLoadedOnce = false;
  bool _refreshing = false;
  _HallSource? _bodySource;

  /// 本页这次运行已经**真实发出过**请求的分部（null = 全部）。
  ///
  /// 每个分部只预取一次：否则每次切回"全部"都会重发一轮预取，请求数反而涨回去。
  /// 冷启动（缓存已被 [dispose] 清空）时它随 State 一起重建，于是"重新进页面"会重新预取一遍 ——
  /// 这正是我们要的：进页面 = 重新确认服务端。
  final Set<String?> _prefetched = <String?>{};

  /// 预取并发上限（`/worker/order-hall` 每次要在服务端做**实时权限查库 + 分页查询**，
  /// 一次打 5 个并发既不礼貌也没收益：连接复用后它们本来就排在同一条连接上串行回来）。
  static const int _prefetchConcurrency = 3;

  @override
  void initState() {
    super.initState();
    /**
     * 【进页面 = 一定回源，绝不吃上一次的运行期缓存】
     *
     * 不变量：缓存只服务"**切分部**瞬间出内容"，不服务"重新进大厅"。
     * 同一次运行内第二次进大厅时，内存里的 `/worker/order-hall` 可能已经旧了；
     * 若让它命中，页面会先把**上一次进入时的列表**亮出来（用户会说"单子是老的"）。
     * 这里先把本页要用的大厅缓存条目丢掉 → 首屏那次一定走网络；
     * 随后 `_loadAll` 的第二阶段会把"全部 + 各分部"重新预取回来，
     * **切分部**才因此是瞬时的（预取用的就是本次进页面刚拉到的新数据）。
     */
    _clearHallCache();
    _seenIdentityEpoch = AuthStore.instance.identityEpoch;
    // 【重绑自愈】监听身份级成功动作（重新绑定 / 切换身份）：见 [_onAuthChanged]
    AuthStore.instance.addListener(_onAuthChanged);
    unawaited(_loadAll());
    _initRealtime();
  }

  @override
  void dispose() {
    AuthStore.instance.removeListener(_onAuthChanged);
    for (final off in _offEvents) {
      off();
    }
    /**
     * 【2026-10-06 大厅延迟专项】离开页面就把大厅族缓存丢掉。
     *
     * 为什么：缓存的价值是"**本次会话内切分部秒开**"，出了页面这个价值就归零；
     * 留着它只会换来"下次进来先闪一份旧列表"的风险。丢掉之后，下次进大厅必然回源
     * （见 `initState` 注释里的不变量），"重新进 = 重新确认服务端"这条语义由代码保证，
     * 而不是靠 TTL 长短去赌。
     */
    _clearHallCache();
    super.dispose();
  }

  /**
   * 丢掉"大厅族"的运行期缓存：`/worker/order-hall`（含各分部各一个键）+ 权限 + 在线数。
   *
   * **刻意不动 `/public/announcements`**：公告是管理端配置级内容（`ApiCache` 里字典档
   * 10 分钟），平台级同质数据、与账号无关，跨页面复用正是它该有的样子。
   */
  void _clearHallCache() {
    final base = _api.cacheScopeBase;
    ApiCache.instance
      ..invalidate('/worker/order-hall', apiBase: base)
      ..invalidate('/worker/division-permissions', apiBase: base)
      ..invalidate('/divisions', apiBase: base);
  }

  /// [force] = true 时**两个辅助请求也强制回源**（用户主动刷新/重试的语义：
  /// "给我现在的真相"）。默认 false 保持既有首屏行为（权限走 60s TTL 缓存，
  /// 这正是"切分部不再重拉权限"的延迟优化，不能顺手改掉）。
  Future<void> _loadAll({bool force = false}) async {
    setState(() {
      _error = null;
      // 只有"从没成功渲染过"才允许整页转圈（此后一律保留旧列表 + 细进度）
      if (_orders.isEmpty && !_hasLoadedOnce) _loading = true;
    });
    await _setRefreshing(true);
    // 大厅本身是否真的拿到了数据（决定"要不要自动重拉分部"，见 finally）
    bool hallOk = false;
    try {
      /**
       * 【阶段 1 · 关键路径】三个请求**并发**发出，首屏只取决于最慢的那个：
       *   ① `/worker/division-permissions` —— 胶囊数据源（60s TTL，切分部不再重拉）
       *   ② `/public/announcements` —— 公告行（字典档；`ApiClient.prefetch` 登录后已预热，
       *      这里通常是**缓存命中 0 等待**）
       *   ③ `/worker/order-hall` —— 真正的首屏内容，**不等 ①②**（原实现是 `await Future.wait`
       *      之后再串行发它，等于把首屏压在"最慢的辅助请求 + 大厅本身"之上）
       *
       * ①② 各自 catchError 兜底：辅助信息拿不到**绝不能**影响大厅出内容。
       */
      await Future.wait<void>([
        // **失败不再静默**：`_loadDivisions` 自己把中文原因写进 `_divisionError`，
        // 界面据此显示「分部列表加载失败 + 重试」（原来这里是 `catchError((_) {})`）。
        _loadDivisions(force: force).catchError((Object _) {}),
        _loadAnnouncement().catchError((_) {}),
        _loadHall(force: true),
      ]);
      hallOk = true;
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
      await _setRefreshing(false);
      /**
       * 【自动自愈】大厅**成功**、但分部仍未拿到（会话刚恢复的典型时序）：
       * 自动重拉一次分部 —— 用户不用手动下拉，页面自己就恢复出胶囊。
       *
       * 放在 `finally` 而不是 `try` 里：`Future.wait` 在**任一**分支抛错时整体抛出，
       * 跟在后面的语句根本不会执行 —— 而"分部失败"恰好就走那条路（它被 catchError
       * 兜住了，但"大厅失败"这条负向路径必须**不**触发重拉，所以要显式看 `hallOk`）。
       */
      if (hallOk && mounted) await _maybeRecoverDivisions();
    }
    /**
     * 【阶段 2 · 进页面即预取】用户看到第一份列表之后再并行预取其它分部。
     *
     * 放在 `await` 之后而不是并发进阶段 1：预取会占满隧道（实测单程 RTT ≈0.52s），
     * 与首屏抢同一条连接只会把首屏拖慢。这里等首屏落地再发，
     * 用户点 chip 时数据已经在缓存里 → **切分部 0 网络等待**（目标 ≤300ms）。
     * 预取失败不影响任何主流程：没有缓存就退化成"切过去时现拉一次"。
     */
    unawaited(_prefetchOtherDivisions());
  }

  /// 阶段 2：把**其它可用分部**的大厅也拉一遍（含"全部"共 N+1 个键，并发 ≤ [_prefetchConcurrency]）
  ///
  /// 用的是**真实请求 + 写缓存**（即 `force: true`）：只有真的把响应落到 ApiCache 里，
  /// 切过去时 `cacheKeyOf` 才命中得到。若走非 force 且已有缓存，API 会走 SWR **返回旧值**，
  /// 那就等于"预取失败"（切过去看到的是上一次的列表）—— 所以这里必须 force。
  ///
  /// 一个都不预取"当前已选中的分部"：它的数据刚刚由阶段 1 拉过，缓存已是新鲜的。
  Future<void> _prefetchOtherDivisions() async {
    final targets = <String?>[null, ..._divisions.map((d) => d.divisionId)]
        .where((id) => id != _divisionId && !_prefetched.contains(id))
        .toList();
    if (targets.isEmpty) return;
    for (final id in targets) {
      _prefetched.add(id); // 先标记再发：并发重入时不会重复预取同一个分部
    }
    for (var i = 0; i < targets.length; i += _prefetchConcurrency) {
      final batch = targets.skip(i).take(_prefetchConcurrency);
      await Future.wait<void>(batch.map(_prefetchHall));
    }
  }

  /// 单个分部的静默预取：**失败一律吞掉**（没有缓存 → 切过去时现拉，功能不受影响）
  Future<void> _prefetchHall(String? divisionId) async {
    try {
      await _fetchHall(divisionId: divisionId, force: true);
    } catch (_) {
      // 预取是尽力而为：不弹提示、不进 _error、不打断主流程
      _prefetched.remove(divisionId); // 允许以后（如实时事件到来时）再试一次
    }
  }

  Future<void> _setRefreshing(bool value) async {
    if (!mounted || _refreshing == value) return;
    setState(() => _refreshing = value);
  }

  void _initRealtime() {
    final token = AuthStore.instance.activeToken;
    if (token == null) return;
    _realtime.connect(token: token);
    // 新单/被抢/状态变更都要**绕过 SWR 缓存**强刷，否则大厅会停在旧列表上
    _offEvents.add(_realtime.on('order:new', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('order:update', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('conv:removed', (_) => _reloadQuietly()));
  }

  /// 我的分部接单权限（**胶囊的唯一数据源**）+ 各分部真实在线人数
  ///
  /// 【2026-10-06 大厅延迟专项】两个请求从**串行**改成**并发**：原来第二个请求
  /// （`/divisions`，只为拿 `onlineCount` 这一个数字）排在第一个后面，把"胶囊能点"
  /// 的时间硬生生推后一个往返；它俩互不依赖，没有任何理由串行。
  ///
  /// `/divisions` **不带 token**：它是公开接口，与 `ApiClient.prefetch` 预取时同一缓存键。
  /// 若这里带 token，就会在 `auth|...` 域里另建一份 `/divisions` 缓存，
  /// 让预取到的那份白白闲置（同一个接口被拉两次）。
  ///
  /// [force] = true 时**绕过缓存回源**：用于「重试」与自动自愈 —— 那两种情况正是
  /// "刚失败过、要确认现在到底行不行"，吃 60s 缓存等于让用户再等一轮（甚至永远好不了）。
  Future<void> _loadDivisions({bool force = false}) async {
    try {
      // ① 权限（必须成功，否则胶囊不出来）+ ② 在线数（失败只影响一个数字）
      //
      // 【2026-10-06 紧急修复】`/worker/division-permissions` 是**受保护接口**，必须带令牌。
      // 原来这一行漏了 `token:` —— `ApiClient.buildHeaders` 是 `if (token != null) 'Authorization'`，
      // 不传就**真的不带** Authorization 头 → 服务端守卫 401「未登录」→ 打手态接单大厅的
      // 分部胶囊**永远加载失败**（且"重试"无效，因为每次重试同样不带令牌）。
      // 该缺陷由大厅提速改造（两个请求串行改并发）引入，只影响这一行。
      final results = await Future.wait<Map<String, dynamic>>([
        _api.request(
          'GET',
          '/worker/division-permissions',
          token: AuthStore.instance.activeToken, // 受保护接口：漏了它 = 401（见上方说明）
          forceRefresh: force,
        ),
        _api.request('GET', '/divisions', forceRefresh: force).catchError((_) => <String, dynamic>{}),
      ]);
      final raw = results[0]['data'];
      final list = raw is List ? raw : (raw is Map ? (raw['list'] as List?) : null) ?? const [];
      final permitted = list
          .whereType<Map>()
          .map((e) => WorkerDivisionPermission.fromJson(e.cast<String, dynamic>()))
          .where((d) => d.canTakeOrder && d.divisionId.isNotEmpty)
          .toList();
      // 真实在线数：`/divisions` 的 onlineCount（该分部在职且已授权接单的打手数）
      var online = 0;
      final l = results[1]['data'];
      final items = l is List ? l : (l is Map ? (l['list'] as List?) : null) ?? const [];
      if (items.isNotEmpty) {
        final counts = <String, int>{};
        for (final e in items.whereType<Map>()) {
          counts['${e['id']}'] = (e['onlineCount'] as num?)?.toInt() ?? 0;
        }
        for (final d in permitted) {
          online += counts[d.divisionId] ?? 0;
        }
      }
      if (!mounted) return;
      setState(() {
        _divisions = permitted;
        _divisionError = null;
        _divisionNames
          ..clear()
          ..addEntries(permitted.map((d) => MapEntry(d.divisionId, d.label)));
        _onlineWorkers = online;
        // 选中分部若已失去权限（管理端刚撤销）-> 回到「全部」，避免停在空白分部上
        if (_divisionId != null && !permitted.any((d) => d.divisionId == _divisionId)) {
          _divisionId = null;
        }
      });
      // 权限回来才知道有哪些分部 → 这里补记"选中分部已预取过"，
      // 免得阶段 2 把刚由阶段 1 拉过的当前分部又预取一遍
      _prefetched.add(_divisionId);
    } catch (e) {
      /**
       * 【2026-10-06 静默残缺专项】原来这里是 `catch (_) {}`（一行注释都没有）——
       * 失败被完全吞掉，界面只剩"没有分部胶囊"这一个结果。
       *
       * 现在：**记下中文原因并让界面显示出来**（[divisionErrorRow]），
       * 同时**照旧不把它抛出去** —— 辅助请求失败绝不能拖住大厅内容这条原则不变。
       * 拉不到权限时服务端仍会按权限过滤并下发中文提示，大厅内容本身是可用的。
       */
      final String msg = e is ApiException ? e.message : '网络异常，请检查网络后重试';
      if (mounted) setState(() => _divisionError = msg);
    }
  }

  /// 【自动自愈】大厅成功但分部为空 → **自动重拉一次**分部（最多 [_divisionRecoverMax] 次）
  ///
  /// 解决的具体场景（负责人 2026-10-06 实测）：重置打手密码 → companion 会话被吊销 →
  /// 进大厅那一下 `/worker/division-permissions` 失败 → 胶囊整排消失；随后 App 已重新
  /// 拿到 companion 会话，但**页面不会自动重拉**，于是一直空到用户手动下拉为止。
  ///
  /// 两条边界：
  ///   - `_divisionError == null` → **不重拉**：那是"这个打手本来就没有分部权限"
  ///     （服务端 200 + 空列表，`divisionDenied` 由大厅自己给中文提示），不是故障；
  ///   - 次数上限 1 → 防抖，不会变成重试风暴（真没好就等用户下拉/下次进页面）。
  Future<void> _maybeRecoverDivisions() async {
    if (_divisionRetrying) return;
    if (_divisions.isNotEmpty) return;
    if (_divisionError == null) return;
    if (_divisionRecoverTries >= _divisionRecoverMax) return;
    _divisionRecoverTries += 1;
    _divisionRetrying = true;
    try {
      // force：这一步就是"会话刚恢复，去真回源确认一次"，吃 60s 缓存会白跑
      await _loadDivisions(force: true);
    } finally {
      _divisionRetrying = false;
    }
    if (!mounted || _divisions.isEmpty) return;
    // 胶囊终于回来了 → 顺手把它对应的其它分部预取一遍（否则点 chip 还是要现拉）
    unawaited(_prefetchOtherDivisions());
  }

  /// 用户点「重试」：手动重拉分部（与自动自愈同一条实现，只是不看次数上限）
  Future<void> _retryDivisions() async {
    if (_divisionRetrying) return;
    _divisionRetrying = true;
    setState(() => _divisionError = null);
    try {
      await _loadDivisions(force: true);
    } finally {
      _divisionRetrying = false;
    }
    if (!mounted || _divisions.isEmpty) return;
    unawaited(_prefetchOtherDivisions());
  }

  /// 【2026-10-06 重绑后旧错误残留专项】监听**身份"代"**：重新绑定 / 切换身份成功 → 自我修复
  ///
  /// ## 修的是什么（负责人实测）
  /// 会话过期或被解绑后，本页留下「分部列表加载失败（未登录）」；用户**重新绑定成功**回到大厅，
  /// **那句话还挂在原地**，非得手点「重试」。原因不是"没人重拉"，而是**没人知道该重拉**：
  /// 重新绑定换的是 companion **令牌**，`AuthStore.workerIdentity` 全程为 true
  /// → 宿主 `HomeShell` 的 `AnimatedSwitcher` 判定"同 key + 同 widget 类型"→ **复用整棵子树**
  /// → 本页 State（含 [_divisionError]）原样留着，`_loadAll` 不会再跑第二次。
  ///
  /// ## 判据为什么是"代"而不是别的
  /// - 不是 `workerIdentity`：它一直是 true（见上）；
  /// - 不是令牌：`POST /user/identity/refresh` 会在 12h 内续期 companion 令牌，
  ///   拿令牌当判据会把"续期"也当成一次重绑，凭空多一轮请求；
  /// - 不是"任何一次 notifyListeners"：那样资料刷新/忙碌文案都会触发重拉（负向用例专门钉这条）。
  /// 只有 [AuthStore.identityEpoch]（身份级成功动作，唯一出口在 AuthStore 里）才算数。
  void _onAuthChanged() {
    final epoch = AuthStore.instance.identityEpoch;
    if (epoch == _seenIdentityEpoch) return; // 与身份无关的通知：什么都不做（不重拉）
    _seenIdentityEpoch = epoch;
    // 已经离开打手态（切回老板 / 解绑 / 被顶下线）：本页马上会被卸载，这一发请求没有意义
    if (!mounted || !AuthStore.instance.workerIdentity) return;
    unawaited(_reloadAfterIdentityEstablished());
  }

  /// 新会话落地后的自我修复：**先清掉旧会话留下的失败结论，再整页回源（分部 + 大厅）**
  ///
  /// 三件事都要做，缺一条用户仍会觉得"没恢复"：
  ///   ① 清 [_divisionError] —— 不清就等于继续对外宣布上一个会话的失败；
  ///   ② 重置自动自愈预算（[_divisionRecoverTries]）—— 新会话理应重新拥有那一次自愈机会，
  ///      否则"重绑后第一次仍失败"就再也不会自愈了；
  ///   ③ 丢掉"已预取"标记 —— 换令牌 = 换缓存作用域（`ApiCache.beginSession` 已清空缓存），
  ///      旧标记会让切分部时误以为那份数据还在。
  ///
  /// 用 `_loadAll(force: true)`：与下拉刷新/页头刷新**同一条实现** —— 大厅、分部权限、在线数
  /// 三个请求全部真回源（吃 60s 缓存等于让刚恢复的会话再等一轮）。
  Future<void> _reloadAfterIdentityEstablished() async {
    if (!mounted) return;
    setState(() {
      _divisionError = null;
      _divisionRecoverTries = 0;
    });
    _prefetched.clear();
    await _loadAll(force: true);
  }

  /// 真实公告（首条；`GET /public/announcements` 置顶优先 + 时间倒序）
  ///
  /// 【2026-10-06 大厅延迟专项】**不带 token**（公开接口）：与 `ApiClient.prefetch`
  /// 预取时同一缓存键 → 登录后进大厅这一行通常直接命中缓存，0 等待。
  Future<void> _loadAnnouncement() async {
    try {
      final resp = await _api.request('GET', '/public/announcements');
      final data = resp['data'];
      final list = data is List ? data : (data is Map ? (data['list'] as List?) : null) ?? const [];
      final maps = list.whereType<Map>().toList();
      if (maps.isEmpty) return;
      final first = maps.first;
      final title = '${first['title'] ?? ''}'.trim();
      final content = '${first['content'] ?? ''}'.trim();
      final text = title.isEmpty ? content : (content.isEmpty ? title : '$title：$content');
      if (mounted && text.isNotEmpty) setState(() => _announcement = text);
    } catch (_) {
      // 公告拉不到就不显示这一行（不占位、不报错）
    }
  }

  /// `GET /worker/order-hall?divisionId=` 的**请求参数**（唯一出口）
  ///
  /// **缓存键含 `divisionId`** 这件事就落在这里：三个参数原样进 `ApiCache.keyOf`
  /// （`page=1&pageSize=50[&divisionId=x]`，键内按参数名排序）。
  /// 因此"全部"与"三角洲手游"是**两个物理隔离的缓存条目**，点错芯片不可能拿到别的分部的单。
  Map<String, dynamic> _hallQuery(String? divisionId) => {
        'page': 1,
        'pageSize': 50,
        if (divisionId != null) 'divisionId': divisionId,
      };

  /// 真实发一次请求，只返回结果、**不碰任何 UI 状态**（预取/刷新/首屏共用这一条出口）
  ///
  /// [force] 语义（两条，别混）：
  ///   - `true` —— **绕过缓存读、强制回源**，并把新响应写回缓存。用于：用户主动刷新
  ///     （下拉 / 页头刷新按钮）、抢单后重拉、实时事件（`order:new`）到来、以及**预取**。
  ///   - `false` —— 走 SWR：命中就同步返回（可能同时后台刷新）。用于：进页面首屏、
  ///     以及分部的"静默刷新"（先给缓存、后台拉新）。
  Future<_HallResult> _fetchHall({String? divisionId, bool force = false}) async {
    final resp = await _api.request(
      'GET',
      '/worker/order-hall',
      token: AuthStore.instance.activeToken,
      forceRefresh: force,
      queryParameters: _hallQuery(divisionId),
    );
    final data = resp['data'] as Map<String, dynamic>?;
    final list = (data?['list'] as List<dynamic>? ?? [])
        .map((e) => OrderBrief.fromJson(e as Map<String, dynamic>))
        .toList();
    return _HallResult(
      orders: list,
      total: (data?['total'] as num?)?.toInt() ?? list.length,
      // 无权限一律是"空列表 + 中文提示"，不是报错页（服务端已按 D4 修）
      deniedMessage: data?['divisionDenied'] == true
          ? ((data?['message'] as String?) ?? '你暂无该分部的接单权限，请联系客服')
          : null,
      source: force ? _HallSource.network : _HallSource.cache,
    );
  }

  /// 把一份结果落到屏上（**唯一**的 setState 出口 —— 缓存命中与网络响应走的是同一条路，
  /// 不会出现"缓存渲染和网络渲染长得不一样"这种漂移）
  void _applyHall(_HallResult r) {
    if (!mounted) return;
    setState(() {
      _orders
        ..clear()
        ..addAll(r.orders);
      _total = r.total;
      _deniedMessage = r.deniedMessage;
      _hasLoadedOnce = true;
      _bodySource = r.source;
      _loading = false;
      _error = null;
    });
  }

  /// 读"这个分部的缓存"（与 `request()` 内部**同一个键**，通过 `ApiClient.cacheKeyOf` 取）
  ///
  /// 任何已存在的条目都算命中（不看新鲜度）：它只用来**先把屏填上**，
  /// 随即 `_loadHall(force: true)` 一定会回源覆盖 —— 所以不存在"拿过期数据糊弄用户"。
  _HallResult? _seedFromCache(String? divisionId) {
    final entry = ApiCache.instance.get(
      _api.cacheKeyOf('/worker/order-hall', _hallQuery(divisionId)),
      Duration.zero,
    );
    if (entry == null) return null;
    final data = entry.body['data'] as Map<String, dynamic>?;
    final list = (data?['list'] as List<dynamic>? ?? [])
        .map((e) => OrderBrief.fromJson(e as Map<String, dynamic>))
        .toList();
    return _HallResult(
      orders: list,
      total: (data?['total'] as num?)?.toInt() ?? list.length,
      deniedMessage: data?['divisionDenied'] == true
          ? ((data?['message'] as String?) ?? '你暂无该分部的接单权限，请联系客服')
          : null,
      source: _HallSource.cache,
    );
  }

  /// 【切分部的主路径】读当前 [selectedDivisionId] 的缓存把屏先填上 + 回源确认
  ///
  /// 为什么用 force 而不是"靠 SWR 自动后台刷新"：SWR 那条路**不会把新数据交给页面**
  /// （它只把旧 body 返回给调用方，刷新结果留在缓存里）。大厅是"秒级变"的列表，
  /// 必须让回来的新数据真的上屏，否则用户在页面上永远看不到刚进来的单。
  /// force 的代价只是"缓存不再吸收这次请求"，而**感知延迟已经由上一行的缓存渲染吃掉了**。
  Future<void> _loadHall({bool force = false}) async {
    // ① 先把缓存亮出来（有就是 0 等待）—— 这是"切分部 ≤300ms 感知"的全部秘密
    final cached = _seedFromCache(_divisionId);
    if (cached != null) _applyHall(cached);

    // ② 后台刷新（列表保持可见，只有事实行右侧的细进度在动）
    await _setRefreshing(true);
    try {
      _applyHall(await _fetchHall(divisionId: _divisionId, force: force));
    } finally {
      await _setRefreshing(false);
    }
  }

  /// 【切分部】= 立即换选中态 + 立即用缓存填屏 + 后台静默回源
  ///
  /// **整页转圈、骨架闪烁在这条路径上被彻底消除**：`_hasLoadedOnce` 一进来就是 true，
  /// `_content()` 永远走内容分支；旧列表在缓存渲染之前一直留在屏上（不清空 `_orders`）。
  ///
  /// 重复点同一个 chip 是幂等的（相同 `divisionId` → 相同缓存键），不会把列表清零。
  void _switchDivision(String? id) {
    if (id == _divisionId) return;
    setState(() => _divisionId = id);
    unawaited(_loadHall(force: true).catchError((_) {
      // 切分部失败不动已有内容：保留刚填上的缓存列表 + 下一次下拉/实时事件重试
    }));
  }

  /// 实时事件（`order:new` / `order:update`）：**绕过缓存**静默强刷当前分部
  Future<void> _reloadQuietly() async {
    try {
      await _setRefreshing(true);
      _applyHall(await _fetchHall(divisionId: _divisionId, force: true));
    } catch (_) {
      // 静默：下一次事件或下拉刷新会重试
    } finally {
      await _setRefreshing(false);
    }
  }

  Future<void> _grab(OrderBrief o) async {
    try {
      await _api.request('POST', '/worker/orders/${o.id}/grab', token: AuthStore.instance.activeToken, data: {});
      if (!mounted) return;
      AppToast.success(context, '抢单成功');
      /**
       * 抢单成功 → **强制回源**（写操作已在 ApiClient 里失效 `/worker/order-hall` 前缀缓存，
       * 这里再显式 force 一次，确保上屏的是服务端刚算出来的那份）。
       *
       * 为什么必须 force：抢到的单要从大厅消失，靠缓存兜底会让刚抢到的单还挂在屏上。
       * 之后顺手把"其它分部"重新预取一遍（当前分部的缓存已因强刷变新），
       * 用户马上切分部依然是瞬时的。
       */
      await _loadHall(force: true);
      unawaited(_prefetchOtherDivisions());
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message);
      await _reloadQuietly();
    }
  }

  /// 相对时间（3 分钟前 / 26 分钟前 / 1 小时前 / 昨天 / 09-28）
  static String relativeTime(String iso, {DateTime? now}) => IdentityWorkerHallPage.relativeTime(iso, now: now);

  String _divisionLabelOf(OrderBrief o) {
    final id = o.divisionId;
    if (id == null || id.isEmpty) return '';
    return _divisionNames[id] ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IdentityWorkerPageHeader(
          title: '接单大厅',
          actions: [
            IdentityWorkerHeaderButton(
              icon: AppIdentityIcons.refresh,
              tooltip: '刷新',
              onTap: () => _loadAll(force: true),
            ),
          ],
          fact: _factRow(),
          bottom: _announcementRow(),
          // 身份细带：页头正下方、滚动内容之上、不随内容滚动（A+ 清单 ID-A）
          banner: AppIdentityBar(
            workerNo: workerNo,
            nickname: workerNickname,
            onSwitchBack: widget.onSwitchBack,
          ),
        ),
        // 胶囊只在真的有分部时渲染（守 docs/21「不存在的东西不出现」）；
        // 拿不到时**不留空**：换成一行中文提示 + 重试（见 [divisionErrorRow]）
        if (_divisions.isNotEmpty) _chips() else divisionErrorRow(),
        _refreshLine(),
        // 页底（白 + 极浅品牌蓝渐变）只铺内容区：页头与身份细带仍保持白，
        // 与老板端「页头白条 + 页底渐变」是同一套层次（负责人 2026-10-17）
        Expanded(child: AppPageBg(child: _content())),
      ],
    );
  }

  /// 分部加载失败行（**公开给测试断言**：`_divisions.isEmpty && _divisionError != null` 时才出现）
  ///
  /// 设计口径（守 docs/21）：不占满屏、不做成报错页 —— 只是一行发丝线内联提示：
  /// 左侧灰字说明「分部列表加载失败」，右侧主色描边胶囊「重试」。没有渐变、没有 emoji。
  ///
  /// 为什么必须放在**胶囊原来那一行**：那是用户预期看到分部的唯一位置；
  /// 失败时同一位置给出原因与下一步，才叫"让人看见"（而不是在屏幕角落弹一个 toast 就没了）。
  @visibleForTesting
  Widget divisionErrorRow() {
    if (_divisionError == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 8, AppSpacing.page, 6),
      child: Row(
        children: [
          AppIcon.of(AppIdentityIcons.info, size: 13, color: AppColors.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '分部列表加载失败（$_divisionError），大厅内容不受影响',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textTertiary, height: 1.4),
            ),
          ),
          const SizedBox(width: 8),
          // 重试：主色描边胶囊（小、可点、不抢大厅内容的视觉重心）
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _divisionRetrying ? null : _retryDivisions,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  // 方案 G 圆角分档：胶囊一律 999
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.primary),
                ),
                child: Text(
                  _divisionRetrying ? '重试中' : '重试',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部**细进度线**（后台刷新中）：与事实行右侧的转圈同一个 `_refreshing` 开关
  ///
  /// 高度只有 2dp 且**只在刷新时占位**：内容区上方是 chips 行，2dp 的位移在视觉上
  /// 不可察觉，但能给"数据正在变新"一个明确信号（负责人要求的"顶部细进度"）。
  /// 刻意不用 `LinearProgressIndicator` 的默认 4dp 高度 + 背景槽（那会显出一条灰杠）。
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

  /// 工号（实时资料优先，回落绑定摘要）
  String get workerNo {
    final wm = AuthStore.instance.workerMe;
    if (wm != null && wm.workerNo.isNotEmpty) return wm.workerNo;
    return AuthStore.instance.identityStatus?.worker?.workerNo ?? '';
  }

  String get workerNickname {
    final wm = AuthStore.instance.workerMe;
    if (wm != null && wm.nickname.isNotEmpty) return wm.nickname;
    return AuthStore.instance.identityStatus?.worker?.nickname ?? '';
  }

  Widget _factRow() {
    final denied = _deniedMessage != null;
    return Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: denied ? AppColors.textTertiary : AppColors.statusOnline,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        const Text('可接单打手 ', style: _factStyle),
        Text('$_onlineWorkers', style: _factStrong),
        const Text(' 名', style: _factStyle),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('|', style: TextStyle(fontSize: 11.5, color: T.divider)),
        ),
        const Text('当前待接 ', style: _factStyle),
        Text('$_total', style: _factStrong),
        const Text(' 单', style: _factStyle),
        /**
         * 【后台刷新中 · 细进度】（2026-10-06 大厅延迟专项）
         *
         * 与 `product_list_page.dart:51` 的 `_refreshing` 同一口径：**列表保持可见，
         * 只在标题行显示细进度，不整页转圈**。放在事实行右侧（把分隔符 `|` 挤掉，
         * 不新增一行 → **零布局跳动**，也不会因为"多一个节点"让 chips 上下位移）。
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

  static const _factStyle = TextStyle(fontSize: 11.5, color: AppColors.mutedText);
  static const _factStrong = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary);

  Widget _announcementRow() {
    final text = _announcement;
    if (text == null) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _showAnnouncement,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: AppColors.ice,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.bannerInfoBorder),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: T.bgCardSolid,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.bannerInfoBorder),
              ),
              child: const Text('公告',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
            AppIcon.of(AppIdentityIcons.chevron, size: 16, color: T.textTertiary),
          ],
        ),
      ),
    );
  }

  void _showAnnouncement() {
    final text = _announcement ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('公告'),
        content: SingleChildScrollView(child: Text(text, style: const TextStyle(height: 1.6))),
        actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了'))],
      ),
    );
  }

  Widget _chips() {
    final items = <({String? id, String label})>[
      (id: null, label: '全部'),
      ..._divisions.map((d) => (id: d.divisionId, label: d.label)),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        height: 30,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final it = items[i];
            final on = _divisionId == it.id;
            return GestureDetector(
              /**
               * 【切分部】按 [_switchDivision]，**绝不再走 `_loadHall(force: true)` 那条老路**：
               *   - 老路：先 await 网络（经隧道实测 ≈1.3s 冷连接 / ≈0.54s 复用连接）→ 期间列表不动
               *     → 回来才换列表，用户感知就是"点了半天没反应"；
               *   - 新路：`setState` 换选中态（**同一帧就变**）→ 同步用该分部的缓存填屏
               *     （预取命中 → **0 网络等待**）→ 后台静默回源确认。
               * `_hasLoadedOnce` 已经是 true，所以整页转圈与骨架闪烁都不可能出现在这条路径上。
               */
              onTap: () => _switchDivision(it.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // 方案 G：选中 = **品牌蓝实底 + 白字**（品牌蓝是唯一强调色）；未选中 = 白底 + 1px 描边
                  color: on ? AppColors.primary : Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: on ? AppColors.primary : AppColors.strokeSoft),
                ),
                child: Text(
                  it.label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: on ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _content() {
    /**
     * 【整页转圈的唯一合法时机】`_loading && !_hasLoadedOnce`
     *
     * 原实现只看 `_loading`，而 `_loading` 初值是 true —— 于是**进大厅第一帧必是整页转圈**，
     * 且切分部若走到刷新路径也会把内容换掉（骨架闪烁）。
     * 现在：`_hasLoadedOnce` 一旦为 true（成功渲染过任何一份列表，**含缓存渲染**），
     * 转圈分支就再也进不去了 —— 这是"切分部不出现整页转圈/骨架闪烁"的硬保证。
     */
    if (_loading && !_hasLoadedOnce) {
      return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2)));
    }
    return RefreshIndicator(
      // 【用户主动刷新】**这才该 force** —— 与"切分部/进页面"明确分开（原实现两者混用）
      onRefresh: _refreshAll,
      child: _error != null
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                IdentityWorkerEmptyState(
                  icon: AppIdentityIcons.info,
                  title: _error!,
                  detail: '下拉或点右上刷新重试。',
                  action: '重试',
                  onAction: _loadAll,
                ),
              ],
            )
          : _orders.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [_emptyState()],
                )
              : ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 22),
                  children: [
                    // 组内紧 10 / 组间松 22（docs/21）
                    for (var i = 0; i < _orders.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      _orderCard(_orders[i]),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        /**
                         * 「已经到底了 · 共 N 单待接」是**结论**，只在数据真的来自服务端时才给。
                         * 缓存态（[_bodySource] == cache）下这句留空：否则会拿旧列表的总数下结论，
                         * 典型的"看着像 3 单、其实刚进来 2 单"。
                         */
                        (_deniedMessage == null && _bodySource != _HallSource.cache)
                            ? '已经到底了 · 共 $_total 单待接'
                            : '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10.5, color: AppColors.textTertiary),
                      ),
                    ),
                  ],
                ),
    );
  }

  /// 【用户主动刷新】（下拉）：**强制回源**，并要求服务端重新算权限与在线数
  ///
  /// 与"页面切换"的区别就在这里：下拉是用户明确要求"给我最新的"，所以
  /// `_loadAll(force: true)` → 大厅、**分部权限**、在线数**三个请求全部回源**
  /// （2026-10-06 静默残缺专项：原来只 force 大厅，分部权限吃 60s 缓存 ——
  /// 会话刚恢复时用户下拉一次仍可能拿到失败的旧结果）。
  /// 页头右上刷新按钮走的是同一个 [_loadAll]。
  Future<void> _refreshAll() => _loadAll(force: true);

  /// 空态：**绝对不是报错页**（无权限分部 / 无任何分部权限 / 该分部暂时没单，三种都是空列表 + 中文提示）
  Widget _emptyState() {
    if (_deniedMessage != null) {
      final noAnyPermission = _deniedMessage!.contains('暂无任何分部');
      return IdentityWorkerEmptyState(
        icon: noAnyPermission ? AppIdentityIcons.badge : AppIdentityIcons.clock,
        title: _deniedMessage!,
        detail: noAnyPermission
            ? '绑定成功了，但平台还没有给你开通分部。请联系客服开通至少一个分部；'
                '开通后这里会自动出现订单，不用重新绑定。'
            : '这个分部暂时没有待接的订单。切回「全部」可以看到其他分部的单子。',
        action: '联系客服',
        onAction: _openCustomerService,
        topPadding: noAnyPermission ? 38 : 64,
      );
    }
    final name = _divisionId == null ? '' : (_divisionNames[_divisionId] ?? '');
    return IdentityWorkerEmptyState(
      icon: AppIdentityIcons.clock,
      title: name.isEmpty ? '大厅暂无待接订单' : '$name 暂无待接订单',
      detail: name.isEmpty
          ? '新单进来会实时出现在这里，也可以下拉刷新看看。'
          : '这个分部最近没有新单。切回「全部」可以看到其他分部的单子。',
    );
  }

  Widget _orderCard(OrderBrief o) {
    // 单号后 4 位（设计稿：`单号 8241`）
    final no = o.orderNo.length > 4 ? o.orderNo.substring(o.orderNo.length - 4) : o.orderNo;
    final division = _divisionLabelOf(o);
    final when = relativeTime(o.createdAt);
    final meta = <String>[
      '× ${o.quantityText} 单',
      if (division.isNotEmpty) division,
      if (no.isNotEmpty) '单号 $no',
      if (when.isNotEmpty) when,
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
      decoration: BoxDecoration(
        // 方案 G 卡片：白底 + 1px 描边 `#E8ECF2` + 圆角 12（无渐变、无阴影）
        color: Colors.white,
        borderRadius: BorderRadius.circular(_hallCardRadius),
        border: Border.all(color: AppColors.strokeSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  o.productName.isEmpty ? '订单 ${o.orderNo}' : o.productName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary, height: 1.38),
                ),
              ),
              const SizedBox(width: 10),
              // 金额胶囊（方案 G）：浅金底 + 大字金 + 小字金单位。
              // **大字(`AppColors.gold` 19sp w700) / 小字(`goldText`) 两档金**是同一支金，
              // 白底小字必须走 goldText 才有 5.41:1（`money_gold_guard_test` 源码红线守着）。
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(9, 3, 9, 4),
                    decoration: BoxDecoration(
                      color: AppColors.goldSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(fmtMoney(o.totalAmount),
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.gold)),
                  ),
                  const SizedBox(height: 3),
                  const Text('余额',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.goldText)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < meta.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('|', style: TextStyle(fontSize: 11.5, color: AppColors.divider)),
                  ),
                Text(meta[i], style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
              ],
            ],
          ),
          Container(
            margin: const EdgeInsets.only(top: 11),
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: AppColors.strokeSoft))),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    // 卡底固定一行事实（服务端大厅不保底字段，也不下发给老板的区服/ID —— 隐私铁律）
                    '接单后可见老板游戏区服与 ID',
                    style: TextStyle(fontSize: 10.5, color: AppColors.textPlaceholder),
                  ),
                ),
                AppIdentityPrimaryButton(
                  label: '抢单',
                  height: 32,
                  expand: false,
                  onPressed: () => _grab(o),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「联系客服」：复用打手态的客服会话（`GET /user/conversation`，伴随会话白名单已放行）
  Future<void> _openCustomerService() async {
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

/// 屏上这份大厅数据**来自哪里**（决定"已经到底了 · 共 N 单待接"这句结论能不能下）
enum _HallSource {
  /// 运行期缓存（预取或上一次请求的响应）——先渲染用，**不代表服务端此刻的真相**
  cache,

  /// 服务端这次请求的真实响应
  network,
}

/// 一次大厅请求的结果（`/worker/order-hall` 的解析产物）
///
/// 抽出来是为了让"缓存命中"与"网络响应"**走同一个渲染出口**（[_IdentityWorkerHallPageState._applyHall]）：
/// 两条路各自 setState 的话，迟早出现"缓存渲染少了某个字段"的漂移。
class _HallResult {
  const _HallResult({
    required this.orders,
    required this.total,
    required this.deniedMessage,
    required this.source,
  });

  final List<OrderBrief> orders;
  final int total;

  /// 服务端下发的"该分部/无任何分部无接单权限"中文提示（null = 有权限）
  final String? deniedMessage;
  final _HallSource source;
}
