import 'dart:async';
// `Platform.environment['FLUTTER_TEST']`：动效闸门（与 `announcement_ticker.dart` 同一套口径）。
// 老板端只出 Android，`dart:io` 没有 Web 兼容问题。
import 'dart:io';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../models/review_models.dart';
import 'announcement_detail_page.dart';
import 'announcements_page.dart';
import 'complaint_page.dart';
import 'division_construction_page.dart';
import 'friend_search_page.dart';
import 'leaderboard_page.dart';
import 'players_page.dart';
import 'product_detail_page.dart';
import 'recharge_page.dart';
import 'tip_page.dart';
import 'worker_profile_page.dart';

/// 服务页（= 首页；**负责人 2026-10-18 首页大改**定案结构）
///
/// ## 一句话
/// 参考图的信息架构 + 本项目蓝白配色：**顶部只有一个品牌行**，下面一条竖着的信息流
/// （轮播 → 公告 → 快捷入口 → 三宫格 → 热门游戏 → 精选服务 → 人气打手）。
///
/// ## 模块顺序（**严格按负责人 2026-10-18 首页重构规格 ⑥，不许调换**）
/// ```
/// 顶部品牌栏 → 轮播图 → 公告滚动栏 → 快捷入口 → 三宫格 → 热门游戏 → 精选服务 → 人气打手 → 底部导航
/// ```
/// 其中「三宫格」是负责人「不许让功能失去入口」那条要求在规格 ⑥ 之外的**唯一插入点**
/// （投诉客服 / 打赏 / 充值三件事没有别的入口，四格快捷入口已占满 → 独立小节，
/// 位置就钉在快捷入口之后、热门游戏之前）。
///
/// ## 相对上一版**删掉**的结构（规格 ②⑤ + 「处理现有首页里的旧结构」）
/// - 顶栏那三项文字导航（选择陪玩 / 排行榜 / 公告）→ **整排删除**（规格 ②）：
///   - 公告 → 由**公告滚动栏**承载（点进去还是现有公告页）；
///   - 排行榜 → 进「快捷入口」第 2 格；
///   - 选择陪玩 → 进「快捷入口」第 1 格；
/// - 分类 Tab + 筛选胶囊 + 分部卡列表 → **整体移除**（分部导航改由「热门游戏」承担）；
/// - 商品双列 → 改成「精选服务」横向卡片；
/// - 「会员中心」「平台公告」两个大模块 → 首页不再有（业务页面与路由一个都没删）。
///
/// ## 数据来源（**全部真实接口，零假数据、零「待接入」占位**）
/// | 模块 | 接口 |
/// |---|---|
/// | 轮播 | `GET /public/banners`（或聚合 `banners`），后台配置照旧 |
/// | 公告滚动栏 | `GET /public/announcements`（或聚合 `announcements`），**取最新一条** |
/// | 快捷入口 | 固定四格，各自指向**现有页面**（见 [_quickEntries]） |
/// | 热门游戏 | `GET /divisions/grouped`（或聚合 `divisions`） |
/// | 精选服务 | `GET /public/products` |
/// | 人气打手 | `GET /public/players`（或聚合 `players`），按 `completedOrders` 取前 4 |
///
/// 接口没给的字段**一律不渲染**（例如 `/public/players` 没有"在线状态" → 人气打手卡上就没有在线点；
/// `satisfiedRate` 为空 → 不编 100%，显示「暂无评价」）。
///
/// ## 铁律（一条都没放宽）
/// - 底部导航在 `home_shell.dart`，**本页不碰**；
/// - 商品/分部/公告/陪玩**全部来自服务端**，客户端零硬编码业务数据；
/// - 金额只经 `fmtMoney` → `AppPrice`（`¥` + 两位小数），计价单位只有「元 / ¥」这一套口径
///   （旧站那套虚拟计数单位、以及任何"到账即成功"的说法，本页一处都不写）；
/// - 所有列表按 **id 去重**（服务端重复下发时不会出现两张同款卡）。
class ServicesPage extends StatefulWidget {
  const ServicesPage({
    super.key,
    this.onGoOrder,
    this.onNavigate,
    this.refreshSignal,
    this.onFindPlayers,
    this.api,
  });

  /// 去下单（浮标 / 热门游戏「进入服务」/ 精选服务「全部服务」）
  final ValueChanged<String?>? onGoOrder;

  /// 切底部 tab（**页面索引**：0 服务 / 1 订单 / 2 消息 / 3 我的 / 4 祁小山）
  final ValueChanged<int>? onNavigate;

  /// 首页刷新信号（切回本 tab 时递增 → 重新拉取，管理端改动立即同步）
  final ValueNotifier<int>? refreshSignal;

  /// 选择陪玩（跳「选择陪玩」页）—— **快捷入口第 1 格**的点按回调
  ///
  /// 外壳没注入时该格仍然可用：直接 push 现有 [PlayersPage]（不给用户一个点了没反应的格子）。
  final VoidCallback? onFindPlayers;

  /// 测试注入
  final ApiClient? api;

  /// **测试专用**：把"本进程已预取"的标记复位，让同一次测试运行内多个用例都能各自观测
  /// "首屏到底发了几发数据请求"（否则第一个用例之后的用例都会因为已预取而少掉那几发，
  /// 数值不可比）。生产路径**没有任何调用点**（[visibleForTesting]），语义零影响。
  @visibleForTesting
  static void debugResetPrefetched() => _ServicesPageState._prefetched = false;

  /// **测试专用**：把聚合电路保护（`_aggUnavailableAt` 进程级冷却）复位。
  ///
  /// 为什么必须有：它是**进程级**状态 —— 同一次测试运行里"前一条用例把聚合判成不可用"会让
  /// 后一条用例**根本不发探测**（断言 `count == 1` 直接变 0，看起来像实现坏了，其实是被前一条污染）。
  @visibleForTesting
  static void debugResetAggregateBreaker() => _ServicesPageState._aggUnavailableAt = null;

  /// **测试专用**：当前是否处于聚合冷却中（true = 这次加载不会探测聚合）。
  @visibleForTesting
  static bool get debugAggregateBreakerArmed =>
      _ServicesPageState._aggUnavailableAt != null &&
      DateTime.now().difference(_ServicesPageState._aggUnavailableAt!) <
          _ServicesPageState._aggCooldown;

  /// 品牌字标：`祁连山` + `电竞`（两段不同色，见 [_ServicesPageState._brandBar]）
  static const String brandInkText = '祁连山';
  static const String brandAccentText = '电竞';

  /// **历史文案常量（保留，勿删）**：负责人 2026-10-04 指定的欢迎语原文。
  ///
  /// 首页结构里**没有这条欢迎语的位置**（品牌行只有字标 + 两个图标，轮播图自带服务端标题），
  /// 因此本页**不再渲染**它；常量保留的理由只有一条：它是**负责人指定原文的唯一出处**，
  /// 将来要在别处复用时不至于重新抄一遍抄错字。
  static const String headlineText =
      '欢迎各位板板来到祁连山电竞 祝各位板板玩的快乐 玩的开心';

  /// 官方标识文案（卡头用；**不写进占位，只在有真实对象时出现**）
  static const String cardOwnerLabel = '祁连山电竞';

  /// **品牌字标的测试锚点**（品牌行那一枚 `祁连山`+`电竞` 两段色 Text）
  static const Key brandKey = Key('services-brand');

  /// 销量达标才给「热门」贴纸的阈值（**真实依据**：服务端 `salesCount` ≥ 50）
  static const int hotSalesThreshold = 50;

  /// 公告滚动栏最多解析多少条（首页只展示**最新一条**，其余留给公告页）
  static const int tickerMaxItems = 5;

  /// 二级页横向转场时长（排行榜 / 公告 / 商品详情 / 建设中页…），**只写一份**
  static const Duration slideDuration = Duration(milliseconds: 260);

  /// 转场曲线（收尾快、启动稳 → 内容"滑到位"而不是"弹一下"）
  static const Curve slideCurve = Curves.easeOutCubic;

  /// 底栏「订单」页索引（`home_shell.dart`：pageOrders = 1）
  static const int navOrders = 1;

  /// 底栏「消息」页索引（`home_shell.dart`：pageMessages = 2）
  static const int navMessages = 2;

  /// 轮播框体高度 = 卡片宽 × 0.44（**负责人 2026-10-18 首页紧凑化 ②**）
  ///
  /// 旧值 `9 / 16 = 0.5625`（390dp 宽 → 219dp），首屏吃掉太多高度，导致
  /// 「公告 + 快捷入口 + 热门游戏」被挤到第二屏。改为 `0.44` → 390dp 宽 **172dp**，
  /// 缩幅约 **−22%**（落在他要求的 20%~25% 区间内）。
  ///
  /// 注意：这里只是收高度，**图片仍是 `BoxFit.cover`**；图上标题/按钮在新高度下
  /// 靠"降字号 + 收内距"适配（见 [_bannerOverlay]），**不是**把整块等比缩小。
  static double bannerHeightOf(double width) => width * 0.44;

  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<ServicesPage> with WidgetsBindingObserver {
  // 与其它页面一致：允许测试注入（widget.api），不注入时才新建
  late final ApiClient _api = widget.api ?? ApiClient();

  bool _loading = true;
  String? _error;
  List<_Division> _divisions = const [];

  /// **首页商品全量**（一次拉全；「精选服务」直接取前几条，切模块零请求）
  ///
  /// 数据源 = `GET /public/products?page=1&pageSize=50`（既有公开接口，服务端上限就是 50）。
  List<_HomeProduct> _allProducts = const [];

  /// 商品请求飞行中（防抖：`_load` 与刷新信号同时到达时只发一发）
  bool _productsInFlight = false;

  /// 人气打手（`GET /public/players` / 聚合的 `players`），按 `completedOrders` 取前 4
  List<_HomePlayer> _players = const [];

  /// 陪玩请求飞行中（防抖）
  bool _playersInFlight = false;

  /// 首页宣传图（`GET /public/banners`，服务端已过滤 visible=1 + 投放时间区间）
  List<HomeBannerItem> _banners = const [];

  /// 公告（`GET /public/announcements` / 聚合的 `announcements`；
  /// 服务端已按 `pinned DESC, createdAt DESC` 排好序）
  List<_HomeAnnouncement> _announcements = const [];

  /// 管理端添加的商品分类（`GET /public/categories`；**原表照收，不在这里去重**）
  ///
  /// 唯一用途：热门游戏卡那一行「服务标签」的兜底文案（[_oneLinerFor]）。
  List<_HomeCategory> _categories = const [];

  /// **顶栏铃铛的红点**：只在**服务端推来真实未读**时亮
  ///
  /// 为什么不轮询 `/user/notifications`：首页首屏**不许打 `/user/*` 私有接口**（既有红线断言，
  /// 见 `home_aggregate_first_screen_test` ⑤ 组），而"常亮红点"是假数据。
  /// 因此这里只订阅实时通道的**服务端权威未读**事件（零额外 HTTP）：
  /// 来过一条未读 → 亮；用户去看了消息（切走 tab）→ 灭。
  bool _hasUnread = false;

  /// 未读事件的退订函数（WS 未连接时是空函数，不会有任何副作用）
  void Function()? _unreadOff;

  // ---------------------------------------------------------------------
  // 「快速下单」浮标：滚动收起 / 停止滚动 600ms 展开（设计稿 order-fab/e-collapse-pill.html）
  // ---------------------------------------------------------------------

  /// 浮标是否展开（false = 收起成 44 × 44 小圆）
  bool _fabExpanded = true;

  /// 停止滚动后延时展开的定时器
  Timer? _fabExpandTimer;

  /// 预取是否**本次进程已跑过**（静态字段：冷启动预热全进程一次就够）
  static bool _prefetched = false;

  // ---------------------------------------------------------------------
  // 【2026-10-16 网卡治理专项】首屏聚合（GET /public/home）
  // ---------------------------------------------------------------------

  /// 聚合接口路径（契约：`GET /api/v1/public/home`；`baseUrl` 已含 `/api/v1`）
  static const String _aggPath = '/public/home';

  /// 契约里的**必需段** —— 缺任一即判"聚合不可用"（回落），见 [_fetchAggregate] 的完整性校验
  static const List<String> _aggRequiredSections = <String>[
    'banners',
    'divisions',
    'hotProducts',
    'players',
    'leaderboard',
  ];

  /// 聚合探测的超时上限（1.5s）：这一发在首屏关键路径上，超时即判定"不会回来了"
  static const Duration _aggTimeout = Duration(milliseconds: 1500);

  /// 聚合探测失败后的**冷却窗口**（冷却内不再探测，直接走回落）
  static const Duration _aggCooldown = Duration(minutes: 3);

  /// 本次探测是否收到了明确的"接口不存在"（404 / 501）—— 只有这一种情况会记冷却
  bool _aggNotFound = false;

  /// 上次判定"聚合不可用"的时刻（null = 从没失败过）
  ///
  /// **静态字段（跨页面实例）**：电路保护要挡的是"用户在这次运行里反复进首屏"，
  /// 而首屏可能被**重建**（换身份 / 热重启页面 / 测试里换 key）。
  static DateTime? _aggUnavailableAt;

  /// 本次运行内聚合是否成功过（观测/自检用）
  bool _aggHealthy = false;

  /// 聚合各段的条数（自检用：证明"一次拿全"真的拿到了 5 段）
  Map<String, int> _aggSections = const <String, int>{};

  /// 聚合给的分部原始行（自检口径：与回落路径区分 —— 前者只在聚合路径被赋值）
  List<dynamic> _aggDivisionRows = const <dynamic>[];

  /// **自检口径**：当前是否处于"聚合可用"（测试断言 + 报告数字用，不参与渲染）
  bool get debugAggregateHealthy => _aggHealthy;

  /// **自检口径**：本次探测是否收到了明确的"接口不存在"（404/501）
  bool get debugAggregateNotFound => _aggNotFound;

  /// **自检口径**：最近一次聚合各段的条数（`{}` = 还没成功过）
  Map<String, int> get debugAggregateSections => _aggSections;

  /// **自检口径**：聚合路径拿到的分部原始行数（0 = 本次走的是回落路径）
  int get debugAggregateDivisionRows => _aggDivisionRows.length;

  /// **自检口径**：当前是否处于聚合冷却中（on 表示"这次不探测聚合"）
  @visibleForTesting
  bool get debugAggregateCoolingDown => _aggCooldownRemaining > Duration.zero;

  /// 向下滚动的累计位移（带方向迟滞，见 [_onScrollNotification]）
  double _downwardAccum = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.refreshSignal?.addListener(_onRefreshSignal);
    // 服务端权威未读（零 HTTP；WS 未连接时是空退订函数）
    _unreadOff = RealtimeClient.shared.on('unread:update', _onUnreadEvent);
    // 首屏进入**允许先吃缓存**（SWR 命中即同步上屏 = 秒开，随后后台静默追平）
    _load();
  }

  @override
  void dispose() {
    _fabExpandTimer?.cancel();
    _unreadOff?.call();
    widget.refreshSignal?.removeListener(_onRefreshSignal);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 实时未读事件（服务端权威值）：`{conversationId, unread}`
  ///
  /// 只做一件事：把"有未读"这件事点亮。**不自增、不看具体数值**（客户端自增在多端下必然分叉）。
  void _onUnreadEvent(dynamic data) {
    final raw = data is Map ? data['unread'] : null;
    final n = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (n == null || n <= 0) return;
    if (_hasUnread) return;
    if (!mounted) return;
    setState(() => _hasUnread = true);
  }

  /// 收到「切回服务页」刷新信号（`HomeShell._switchTab` / 下单页返回时递增）
  ///
  /// **必须 `force: true`**：这条信号的语义就是"用户刚操作完/刚切回来，看到的必须是最新的"。
  void _onRefreshSignal() {
    unawaited(_load(force: true));
  }

  /// 列表滚动状态（**用 NotificationListener 而不是自己建 ScrollController**）
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0;
      if (delta > 0) {
        _downwardAccum += delta;
        if (_downwardAccum >= AppOrderFab.collapseTrigger) _collapseFab(true);
      } else if (delta < 0) {
        _downwardAccum = 0;
        if (!_fabExpanded) _collapseFab(false);
      }
      _scheduleFabExpand();
    } else if (n is ScrollEndNotification) {
      _scheduleFabExpand();
    }
    return false; // 绝不拦截通知
  }

  void _scheduleFabExpand() {
    _fabExpandTimer?.cancel();
    _fabExpandTimer = Timer(AppOrderFab.expandDelay, () {
      if (mounted) _collapseFab(false);
    });
  }

  /// 收起 / 展开浮标（[collapse] = true 收起成 44dp 小圆，false 展开成胶囊）
  void _collapseFab(bool collapse) {
    final next = !collapse;
    if (_fabExpanded == next) return;
    setState(() => _fabExpanded = next);
    if (!next) _downwardAccum = 0;
  }

  /// App 生命周期：**恢复前台必须回源**（force = true）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(force: true));
  }

  /// 服务页首屏加载 —— **聚合接口优先，失败即并行回落**（2026-10-16 网卡治理专项，口径不变）
  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = _divisions.isEmpty;
      _error = null;
    });
    // 商品与首屏数据**同批发出**（互不依赖）
    unawaited(_loadProducts(force: force));
    try {
      final aggF = _fetchAggregate(force: force);
      final fbF = _fetchFallbackParts(force: force);

      _HomeAggregate? agg;
      _HomeParts? fallback;
      await Future.any<void>(<Future<void>>[
        aggF.then((a) {
          if (a != null) {
            agg = a;
            fallback = null; // 聚合给出了完整数据：回落那份结果直接丢弃
          }
        }),
        fbF.then((f) {
          if (f != null && agg == null) {
            fallback = f;
          }
        }),
      ]);

      if (agg == null && fallback == null) {
        // 先到的那条没给出可用数据 → 等另一条终结，两边都空才走错误态。
        agg = await aggF;
        fallback = await fbF;
      }

      if (agg == null && fallback == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          // 这句细节文案刻意**不含"内容加载失败"四个字**：既有测试用 `findsOneWidget`
          // 断言那句话只出现一次，细节行若复用同样措辞会变成 2 处（实测踩到）。
          _error = '首页数据没拿到（聚合接口与分接口都没返回可用数据）';
        });
        return;
      }

      // 首屏数据到手后，后台预热其它常用接口（每进程一次）
      final tk = AuthStore.instance.accessToken;
      if (tk != null && !_prefetched) {
        _prefetched = true;
        unawaited(ApiClient.prefetch(_api, token: tk));
      }

      final _HomeAggregate? aggSnapshot = agg;
      final _HomeParts? fbSnapshot = fallback;
      if (aggSnapshot != null) {
        _applyAggregate(aggSnapshot);
      } else if (fbSnapshot != null) {
        if (!mounted) return;
        setState(() {
          _divisions = _dedupeById(fbSnapshot.divisions, (d) => d.id);
          _banners = fbSnapshot.banners;
          _announcements = fbSnapshot.announcements;
          _players = _topPlayersOf(fbSnapshot.players);
          _loading = false;
        });
      }

      // 聚合路径上 `players` 由聚合带来（零额外请求）；回落路径若聚合没给，才补一发。
      if (aggSnapshot == null && _players.isEmpty) {
        unawaited(_loadPlayers(force: force));
      }

      // 静态配置（分类）：一发，失败静默 → 保持"不存在就不出现"的口径。
      unawaited(_loadOptionalParts(force: force));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 静态配置（管理端分类）——**不进首屏阻塞路径**，失败静默
  ///
  /// 唯一消费方：热门游戏卡的「服务标签」兜底（[_oneLinerFor]）。
  Future<void> _loadOptionalParts({required bool force}) async {
    final resp = await _api
        .request('GET', '/public/categories', forceRefresh: force)
        .catchError((_) => <String, dynamic>{});
    if (!mounted) return;
    // 形状防御（同回落路径）：`data` 可能是错误信封里的对象，**不能直接 `as List?`**
    final catsRaw = resp['data'];
    // **管理端原表照收，不在这里去重**：去重必须发生在**按分部/游戏过滤之后**
    final cats = (catsRaw is List ? catsRaw : const <dynamic>[])
        .whereType<Map>()
        .map((e) => _HomeCategory.fromJson(e))
        .where((c) => c.name.isNotEmpty && c.id.isNotEmpty)
        .toList();
    setState(() {
      _categories = cats;
    });
  }

  /// **某分部所属游戏的分类**：**先按游戏过滤 → 再按 id 去重**（顺序不能反）
  List<_HomeCategory> _categoriesForGame(String gameId) => _dedupeById(
        _categories
            .where((c) => gameId.isEmpty || c.gameId.isEmpty || c.gameId == gameId)
            .toList(),
        (c) => c.id,
      );

  /// **按 id 去重**（保留首次出现的顺序）—— 全页所有列表唯一的去重口径。
  ///
  /// 类型参数叫 `E` 而不是 `T`：本文件全局用 `T`（`theme_colors.dart` 的主题别名），
  /// 用 `T` 会触发 `avoid_types_as_parameter_names`（analyze 必须 0 issue）。
  static List<E> _dedupeById<E>(List<E> src, String Function(E) idOf) {
    final seen = <String>{};
    final out = <E>[];
    for (final item in src) {
      final id = idOf(item);
      if (id.isEmpty) continue;
      if (!seen.add(id)) continue;
      out.add(item);
    }
    return out;
  }

  /// 人气打手：**按接单量降序取前 4**（负责人规格 ⑥ 的排序口径）
  ///
  /// 接单量缺失（服务端没给 `completedOrders`）的排最后；同分保持服务端顺序（稳定排序）。
  static List<_HomePlayer> _topPlayersOf(List<_HomePlayer> src) {
    final sorted = List<_HomePlayer>.of(src);
    // `List.sort` 在 Dart 里不保证稳定 → 用"带下标的复合比较"把服务端顺序作为第二关键字。
    final indexed = <MapEntry<int, _HomePlayer>>[
      for (var i = 0; i < sorted.length; i++) MapEntry<int, _HomePlayer>(i, sorted[i]),
    ];
    indexed.sort((a, b) {
      final oa = a.value.completedOrders ?? -1;
      final ob = b.value.completedOrders ?? -1;
      if (oa != ob) return ob.compareTo(oa);
      return a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).take(4).toList(growable: false);
  }

  /// 把聚合结果（若成功）落到页面状态：一次 setState 上屏
  void _applyAggregate(_HomeAggregate agg) {
    if (!mounted) return;
    setState(() {
      // 分部按 id 去重后上屏（多来源合并可能把同一个分部下发两次）
      _divisions = _dedupeById(agg.divisions, (d) => d.id);
      _aggDivisionRows = agg.rawDivisions;
      _banners = agg.banners;
      _announcements = agg.announcements;
      _players = _topPlayersOf(agg.players);
      _aggSections = agg.sections;
      _loading = false;
    });
  }

  /// 把分接口的原始响应解析成页面数据（**既有逻辑原样保留**，只是抽成纯函数便于回落路径复用）
  _HomeParts _parseHomeFromParts({
    required Map<String, dynamic> groupedRaw,
    required Map<String, dynamic> bannersRaw,
    required List<dynamic> announcementsRaw,
  }) {
    final grouped = groupedRaw['data'] is List ? groupedRaw['data'] as List : const <dynamic>[];
    return _HomeParts(
      divisions: _toDivisions(grouped),
      banners: _parseBanners(bannersRaw['data']),
      announcements: _parseAnnouncements(announcementsRaw),
      players: const <_HomePlayer>[],
    );
  }

  /// `/divisions/grouped`（按游戏分组）→ 页面用的扁平分部表
  List<_Division> _toDivisions(List<dynamic> grouped) {
    final divisions = <_Division>[];
    for (final g in grouped) {
      final m = g as Map;
      for (final d in (m['divisions'] as List? ?? const [])) {
        divisions.add(_Division.fromJson(d as Map, platformCount: (m['platformCount'] as num?)?.toInt() ?? 1));
      }
    }
    return divisions;
  }

  /// **首屏聚合接口**（`GET /public/home`）——契约：
  /// `{ announcements, banners, divisions, hotProducts, players, leaderboard, updatedAt }`
  ///
  /// 失败判定只有三层（写死，别"顺手优化"）：
  ///   - **404 / 501**（接口不存在）→ 记冷却；
  ///   - **超时** → 记冷却；
  ///   - **200 但形状不合契约**（非对象 / 缺段）→ **只判"这次不用它"，不记冷却**。
  Future<_HomeAggregate?> _fetchAggregate({required bool force}) async {
    if (!force && _aggCooldownRemaining > Duration.zero) return null;
    // 超时用**可取消**的定时器（不是裸 `Future.delayed`）：请求先回来时必须把定时器撤掉。
    final completer = Completer<Map<String, dynamic>?>();
    final timer = Timer(_aggTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    unawaited(_api.request('GET', _aggPath, forceRefresh: force).then((r) {
      if (!completer.isCompleted) completer.complete(r);
    }).catchError((Object e) {
      // 判据 = **HTTP 状态码 404/501**（"接口不存在"），不是业务错误码 `code`
      final st = ApiClient.lastHttpStatus;
      if (st == 404 || st == 501) _aggNotFound = true;
      if (!completer.isCompleted) completer.complete(null);
    }));

    final resp = await completer.future;
    timer.cancel();
    if (resp == null) {
      if (_aggNotFound) _markAggregateUnavailable();
      return null;
    }
    final data = resp['data'];
    if (data is! Map) return null; // 200 但 payload 不是对象 → 这次不用它（不记冷却）
    final map = data.cast<String, dynamic>();
    for (final k in _aggRequiredSections) {
      if (!map.containsKey(k)) return null;
    }
    _aggHealthy = true;
    final rawDivisions = _aggregateDivisionRows(map['divisions']);
    return _HomeAggregate(
      banners: _parseBanners(map['banners']),
      divisions: _parseAggregateDivisions(map['divisions']),
      rawDivisions: rawDivisions,
      announcements: _parseAnnouncements(map['announcements']),
      players: _parsePlayers(map['players']),
      sections: <String, int>{
        'banners': (map['banners'] as List?)?.length ?? 0,
        'divisions': rawDivisions.length,
        'hotProducts': (map['hotProducts'] as List?)?.length ?? 0,
        'players': (map['players'] as List?)?.length ?? 0,
        'leaderboard': (map['leaderboard'] as List?)?.length ?? 0,
      },
    );
  }

  /// **回落路径**（既有分接口，**并行发**），解析成页面数据。
  Future<_HomeParts?> _fetchFallbackParts({required bool force}) async {
    try {
      final parts = await Future.wait<Map<String, dynamic>>(<Future<Map<String, dynamic>>>[
        _api.request('GET', '/divisions/grouped', forceRefresh: force).catchError((_) => <String, dynamic>{}),
        _api.request('GET', '/public/banners', forceRefresh: force).catchError((_) => <String, dynamic>{}),
        _api.request('GET', '/public/announcements', forceRefresh: force).catchError((_) => <String, dynamic>{}),
      ]);
      final parsed = _parseHomeFromParts(
        groupedRaw: parts[0],
        bannersRaw: parts[1],
        // 形状防御：`data` 可能为 null（错误信封）/ 也可能是对象（被前置代理插页）——
        // **不能直接 `as List?`**（实测：非 List 的 data 会在 cast 处抛，整条回落路径崩掉）
        announcementsRaw: parts[2]['data'] is List ? parts[2]['data'] as List : const <dynamic>[],
      );
      // 全空 = 服务端什么都没给（真·失败）→ 返回 null 让上层走错误态；
      // 只要有任一份数据就照常渲染（**绝不白屏**是硬要求）。
      if (parsed.divisions.isEmpty && parsed.banners.isEmpty && parsed.announcements.isEmpty) {
        return null;
      }
      return parsed;
    } catch (_) {
      return null;
    }
  }

  /// 聚合/回落里的 `banners` → 轮播项（空/异常一律空列表 → 轮播走"零占位"空态）
  List<HomeBannerItem> _parseBanners(Object? raw) {
    if (raw is! List) return const [];
    final out = <HomeBannerItem>[];
    for (final b in raw) {
      if (b is Map) out.add(HomeBannerItem.fromJson(b));
    }
    return out;
  }

  /// 公告行 → 公告条数据（**最新 1 条展示，只解析前 [ServicesPage.tickerMaxItems] 条**）
  ///
  /// 空标题一律丢弃（不许出现空条）；`createdAt` 解析不出来 → `null`（那一行的日期就不渲染，
  /// 不编一个日期出来）。
  List<_HomeAnnouncement> _parseAnnouncements(Object? raw) {
    if (raw is! List) return const [];
    final out = <_HomeAnnouncement>[];
    for (final a in raw) {
      if (a is! Map) continue;
      final t = '${a['title'] ?? ''}'.trim();
      if (t.isEmpty) continue;
      out.add(_HomeAnnouncement(
        id: '${a['id'] ?? ''}',
        title: t,
        createdAt: DateTime.tryParse('${a['createdAt'] ?? ''}'),
      ));
      if (out.length >= ServicesPage.tickerMaxItems) break;
    }
    return out;
  }

  /// 聚合里的 `players` → 人气打手行（**逐项可空解析，缺字段就是没有**）
  List<_HomePlayer> _parsePlayers(Object? raw) {
    if (raw is! List) return const [];
    final out = <_HomePlayer>[];
    for (final p in raw) {
      if (p is! Map) continue;
      final item = _HomePlayer.fromJson(p);
      if (item.id.isEmpty) continue;
      out.add(item);
    }
    return _dedupeById(out, (p) => p.id);
  }

  /// 聚合里的 `divisions` → 页面分部表。**容忍两种形状**（扁平数组 / 与 grouped 同形）。
  List<_Division> _parseAggregateDivisions(Object? raw) {
    if (raw is! List) return const [];
    final looksGrouped = raw.isNotEmpty && raw.first is Map && (raw.first as Map).containsKey('divisions');
    if (looksGrouped) return _toDivisions(raw);
    final out = <_Division>[];
    for (final d in raw) {
      if (d is! Map) continue;
      out.add(_Division.fromJson(d, platformCount: (d['platformCount'] as num?)?.toInt() ?? 1));
    }
    return out;
  }

  /// 聚合里的 `divisions` → **原始行**（展平后的 Map 列表），供自检口径复用。
  List<dynamic> _aggregateDivisionRows(Object? raw) {
    if (raw is! List) return const [];
    final looksGrouped = raw.isNotEmpty && raw.first is Map && (raw.first as Map).containsKey('divisions');
    if (!looksGrouped) return raw;
    final out = <dynamic>[];
    for (final g in raw) {
      if (g is Map) out.addAll((g['divisions'] as List?) ?? const []);
    }
    return out;
  }

  /// 聚合探测失败的**电路保护矩阵**（语义写死在这里，避免后人"顺手优化"掉冷却）。
  ///
  /// | 失败形态 | 处置 | 为什么 |
  /// |---|---|---|
  /// | 404 / 501（接口不存在） | 记冷却 | 后端还没上线，冷却期内不必每次都白打一发 |
  /// | 超时 / 连不上 | 记冷却 | 隧道半死时同样不该反复探测 |
  /// | 200 但契约残缺 | **不记冷却** | 可能是灰度/字段没补齐，下一次仍值得再试 |
  /// | `force: true`（下拉/回前台/切回 tab） | 无视冷却直接重探 | 三条路径的语义就是"要看到最新" |
  Duration get _aggCooldownRemaining {
    if (_aggUnavailableAt == null) return Duration.zero;
    final elapsed = DateTime.now().difference(_aggUnavailableAt!);
    return elapsed >= _aggCooldown ? Duration.zero : _aggCooldown - elapsed;
  }

  void _markAggregateUnavailable() {
    _aggUnavailableAt = DateTime.now();
    _aggHealthy = false;
  }

  /// **商品全量拉一次**（`GET /public/products`，既有公开接口，服务端 pageSize 上限 50）
  ///
  /// 失败口径：**不把整页打成错误态**（轮播/公告/热门游戏照常可用）：
  /// 有旧数据就继续显示旧数据，一条都没有时「精选服务」整块不渲染（不摆假卡）。
  Future<void> _loadProducts({bool force = false}) async {
    if (_productsInFlight) return;
    _productsInFlight = true;
    try {
      final resp = await _api.request(
        'GET',
        '/public/products',
        queryParameters: <String, dynamic>{'page': 1, 'pageSize': 50},
        forceRefresh: force,
      );
      final data = resp['data'];
      final rawList = data is Map ? data['list'] : null;
      final items = (rawList is List ? rawList : const <dynamic>[])
          .whereType<Map>()
          .map(_HomeProduct.fromJson)
          .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        // 任何列表都按 id 去重（服务端重复下发时列表不会出现两张同款卡）
        _allProducts = _dedupeById(items, (p) => p.id);
      });
    } catch (_) {
      // 失败静默：保留屏上旧数据；一条都没有时「精选服务」整块不渲染（不摆假卡/不摆待接入）
    } finally {
      _productsInFlight = false;
    }
  }

  /// 人气打手（回落路径专用；聚合路径由聚合的 `players` 段直接给，零额外请求）
  Future<void> _loadPlayers({bool force = false}) async {
    if (_playersInFlight) return;
    _playersInFlight = true;
    try {
      final resp = await _api.request(
        'GET',
        '/public/players',
        queryParameters: <String, dynamic>{'page': 1, 'pageSize': 50},
        forceRefresh: force,
      );
      final data = resp['data'];
      final rawList = data is Map ? data['list'] : (data is List ? data : null);
      final items = _parsePlayers(rawList is List ? rawList : const <dynamic>[]);
      if (!mounted) return;
      setState(() => _players = _topPlayersOf(items));
    } catch (_) {
      // 失败静默：「人气打手」整块不渲染（服务端没给就是没有，不摆占位卡）
    } finally {
      _playersInFlight = false;
    }
  }

  /// **动效闸门**：测试环境 / 系统「减少动态效果」下一律关掉动画
  bool get _motionEnabled {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return false;
    return MediaQuery.maybeOf(context)?.disableAnimations != true;
  }

  /// **二级页转场：从右向左滑入**
  ///
  /// 全页所有二级入口都走 [_push]，而 [_push] 只调这一个函数 —— **转场只写一份**。
  Route<void> _slideRoute(Widget page) {
    final duration = _motionEnabled ? ServicesPage.slideDuration : Duration.zero;
    return PageRouteBuilder<void>(
      transitionDuration: duration,
      // 返回上一层的时长必须与进入一致，否则"退出比进入快"会显得页面在往回弹
      reverseTransitionDuration: duration,
      pageBuilder: (routeContext, animation, secondaryAnimation) => page,
      transitionsBuilder: (routeContext, animation, secondaryAnimation, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: ServicesPage.slideCurve)),
        child: child,
      ),
    );
  }

  /// 当前选中的分部（只用于「热门游戏」卡的元信息兜底）
  _Division? _divisionById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final d in _divisions) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 商品所属分部（封面无图时用该分部的游戏图标兜底；对照不到返回 null → 组件自己走兜底）
  _Division? _divisionOfProduct(_HomeProduct p) {
    final pid = p.divisionId;
    if (pid != null && pid.isNotEmpty) {
      final d = _divisionById(pid);
      if (d != null) return d;
    }
    if (p.gameId.isNotEmpty) {
      for (final d in _divisions) {
        if (d.gameId == p.gameId) return d;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => Scaffold(
        // 页底铺白 + 极浅品牌蓝渐变：Scaffold 自身让位成透明，底色由 `AppPageBg` 这一层画
        backgroundColor: Colors.transparent,
        body: AppPageBg(child: Stack(
          children: [
            // 滚动通知只用于浮标收起/展开（不拦截通知、不注册手势）
            NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: RefreshIndicator(
                onRefresh: () => _load(force: true),
                child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 8,
            // 玻璃底栏是悬浮的（extendBody），必须额外让出它的高度，否则最后一项被压住
            bottom: 24 + NavStyleController.instance.navReservedHeight,
          ),
                  /**
                   * **整页一次性构建**（ListView 里只放一个 Column）：首页是一条定序的短信息流，
                   * 不需要懒构建；而懒构建反而会让出图用例拿到"半张页面"。
                   * 保留 ListView 外壳是为了下拉刷新与 `find.byType(ListView)` 的手势用例继续成立。
                   */
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. 顶部品牌栏（字标 + 消息通知 + 搜索）
                        _brandBar(),
                        // 2. 轮播图（大圆角卡片 + 图上标题 + 进入服务胶囊 + 底部指示条）
                        _banner(),
                        // 3. 公告滚动栏（单行横向滚动；无公告 → 整块不渲染）
                        _announcementBar(),
                        // 4. 快捷入口（一行 4 格）
                        _quickEntries(),
                        // 5. 三宫格（投诉客服 / 打赏 / 充值）—— 三件事没有别的入口
                        _entryGrid(),
                        if (_error != null) _errorCard(),
                        if (_loading)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary),
                            ),
                          ),
                        // HeroCard 每屏 ≤1 的预算作用域（本页当前没有 HeroCard，作用域保留：
                        // 将来任一模块换成 HeroCard 时不必再补这层壳）。
                        AppHeroBudgetScope(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 6. 热门游戏（分部导航；`/divisions/grouped`）
                              _hotGamesSection(),
                              // 7. 精选服务（`/public/products`）
                              _featuredServicesSection(),
                              // 8. 人气打手（`/public/players`，按接单量取前 4）
                              _topPlayersSection(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        )),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 1. 顶部品牌栏
  // -------------------------------------------------------------------

  /// 顶栏：左「祁连山电竞」字标（墨蓝粗体 + 「电竞」主色蓝）+ 右侧**两个图标**
  ///
  /// **彻底取消横向导航**（负责人规格 ②）：原「选择陪玩 / 排行榜 / 公告」三项文字导航**整排删除**，
  /// 它们的页面与路由一个都没删 —— 公告改由下方公告滚动栏承载，排行榜与选择陪玩搬进快捷入口。
  ///
  /// 右侧两枚图标：
  /// - **消息通知**（铃铛，带红点角标）：点它 = 去「消息」tab。红点只在实时通道推来
  ///   **服务端权威未读**时亮（见 [_hasUnread]）——不轮询、不常亮；
  /// - **搜索**：20dp 墨蓝，点它进现有搜索入口（`FriendSearchPage`，与改版前同一条路；
  ///   本项目 `public/products` 没有 keyword 参数，后端 0 改动的约束下不存在"商品搜索"）。
  Widget _brandBar() {
    return Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 12, 8),
      child: Row(
        children: [
          Text.rich(
            // 测试锚点：本页别处也写「祁连山电竞」→ 只靠文字定位会命中多枚（见 [ServicesPage.brandKey]）
            key: ServicesPage.brandKey,
            TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: ServicesPage.brandInkText,
                  style: const TextStyle(color: AppColors.brandInk),
                ),
                TextSpan(
                  text: ServicesPage.brandAccentText,
                  style: TextStyle(color: T.primary),
                ),
              ],
            ),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 0.2),
          ),
          const Spacer(),
          _iconButton(
            icon: AppIcons.bell,
            onTap: _openMessages,
            badge: _hasUnread,
            tooltip: '消息通知',
          ),
          const SizedBox(width: 4),
          _iconButton(
            icon: AppIcons.search,
            onTap: _openSearch,
            tooltip: '搜索',
          ),
        ],
      ),
    );
  }

  /// 顶部图标按钮（36dp 命中区 + 20dp 图标；[badge] = 右上角红点）
  ///
  /// 红点是**唯一允许的"状态色"**：它只有一个语义（有未读），不做第二套用法。
  Widget _iconButton({
    required AppIcons icon,
    required VoidCallback onTap,
    required String tooltip,
    bool badge = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 36,
                height: 30,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(
                child: AppIcon(icon, size: 20, color: AppColors.brandInk),
              ),
              if (badge)
                Positioned(
                  right: 7,
                  top: 8,
                  child: Container(
                    width: 8,
                    decoration: BoxDecoration(
                      color: AppColors.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: T.bgCardSolid, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 2. 轮播图（大圆角卡片）
  // -------------------------------------------------------------------

  /// 轮播：**大圆角卡片**（左右各 16 页边、16 圆角、16:9 框体）
  ///
  /// - 组件仍走既有 [HomeBannerCarousel]（后台配置、点击跳转、指示条全部沿用）；
  /// - 本轮新增两个**可选**参数（core 里默认值不变）：
  ///   [HomeBannerCarousel.frameRadius] = 16（卡片化）、
  ///   [HomeBannerCarousel.ctaLabel] = 「进入服务」（图右下角胶囊，与整卡共用同一个 onTap）；
  /// - 文案压在图上时靠组件自带的底部遮罩保证可读（真实运营图不保证是深色底）。
  Widget _banner() {
    // 空态零占位由组件自己保证（`items.isEmpty` → `SizedBox.shrink()`）；
    // 这里**不做提前短路**：组件始终在树上，"配置为空 ⇒ 高度 0"这条断言才能被页面级用例观测到。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, box) => HomeBannerCarousel(
          items: _banners,
          onTap: _openBanner,
          frameHeight: ServicesPage.bannerHeightOf(box.maxWidth),
          frameRadius: 16,
          ctaLabel: '进入服务',
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 3. 公告滚动栏（单行横向滚动）
  // -------------------------------------------------------------------

  /// 公告滚动栏：铃铛 + 「官方」小标 + 公告标题（**单行横向滚动**）+ 右侧日期 + 箭头
  ///
  /// ## 为什么这样就不会换行 / 不会溢出
  /// - 文字外壳是 `SingleChildScrollView(scrollDirection: horizontal)` + `Text(maxLines: 1,
  ///   softWrap: false)`：**既不换行、也不 ellipsis**，超出部分靠横滑看完（比"截断成看不懂"好）；
  /// - 标题区套 `Expanded`（弹性宽度）→ 日期与箭头**恒在屏内**，永远不会被长标题挤出去。
  ///
  /// ## 数据
  /// 真实公告：`GET /public/announcements`（回落）或首屏聚合的 `announcements`。
  /// 只展示**最新一条**（服务端 `pinned DESC, createdAt DESC, id DESC` 已排好），
  /// 其余进公告页（点整条 = 现有 [AnnouncementsPage]）。
  /// 一条公告都没有 → 整块不渲染（不占高度、不留白条）。
  Widget _announcementBar() {
    if (_announcements.isEmpty) return const SizedBox.shrink();
    final a = _announcements.first;
    final date = _shortDate(a.createdAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: GestureDetector(
        onTap: _openAnnouncements,
        behavior: HitTestBehavior.opaque,
        child: Container(
              height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: T.bgCardSolid,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.strokeSoft),
          ),
          child: Row(
            children: [
              AppIcon(AppIcons.bell, size: 14, color: T.primary),
              const SizedBox(width: 8),
              // 「官方」小标：主色浅底 + 主色字（面积很小，不抢公告正文）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: T.primarySoft,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '官方',
                  style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: T.primary, height: 1.3),
                ),
              ),
              const SizedBox(width: 8),
              // 弹性宽度 + 横向滚动：长标题横滑看完，绝不换行、绝不 ellipsis
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: Text(
                    a.title,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: T.textSecondary, height: 1.3),
                  ),
                ),
              ),
              if (date.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  date,
                  style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.3),
                ),
              ],
              const SizedBox(width: 4),
              AppIcon(AppIcons.chevronRight, size: 14, color: T.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  /// 公告日期：`10-18`（**本地时间**；解析不出来 → 空串 → 那一格不渲染）
  static String _shortDate(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    final m = l.month.toString().padLeft(2, '0');
    final d = l.day.toString().padLeft(2, '0');
    return '$m-$d';
  }

  // -------------------------------------------------------------------
  // 4. 快捷入口（一行 4 格）
  // -------------------------------------------------------------------

  /// 快捷入口：**一行 4 格**（图标方块 + 名称 + 一行小字副标）
  ///
  /// 这四格就是负责人规格 ⑥ 指定的「覆盖现有页面入口」方案 —— **不造新页面，不删旧页面**：
  ///
  /// | 格 | 名称 | 去向 |
  /// |---|---|---|
  /// | 1 | 选择陪玩 | 现有「选择陪玩」页（外壳回调；未注入时直接 push [PlayersPage]） |
  /// | 2 | 排行榜 | 现有排行榜页 [LeaderboardPage] |
  /// | 3 | 我的订单 | 底栏「订单」tab（`navOrders`） |
  /// | 4 | 联系客服 | 底栏「消息」tab（客服会话在那里，与既有「联系客服」同一落点） |
  ///
  /// 参考图是"选择游戏/下单流程/会员中心/联系客服"，但那四项里有三项目前没有页面 —— 照抄就会
  /// 造出点不动的格子。**覆盖真实入口**优先，这是负责人原话允许的偏差。
  Widget _quickEntries() {
    final entries = <_QuickEntry>[
      _QuickEntry(
        label: '选择陪玩',
        sub: '按分部挑人',
        icon: AppIcons.players,
        color: T.primary,
        onTap: _openPlayers,
      ),
      _QuickEntry(
        label: '排行榜',
        sub: '分部周月榜',
        icon: AppIcons.rank,
        color: AppColors.accentPink,
        onTap: () => _push(LeaderboardPage(api: widget.api)),
      ),
      _QuickEntry(
        label: '我的订单',
        sub: '查看进度',
        icon: AppIcons.orders,
        color: AppColors.accentSafe,
        onTap: () => widget.onNavigate?.call(ServicesPage.navOrders),
      ),
      _QuickEntry(
        label: '联系客服',
        sub: '在线响应',
        icon: AppIcons.headset,
        color: AppColors.accentSupport,
        onTap: _openMessages,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.strokeSoft),
        ),
        child: Row(
          children: [
            for (final e in entries) Expanded(child: _quickCell(e)),
          ],
        ),
      ),
    );
  }

  Widget _quickCell(_QuickEntry e) {
    return GestureDetector(
      onTap: e.onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.categorySoft(e.color),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(child: AppIcon(e.icon, size: 22, color: e.color)),
            ),
            const SizedBox(height: 8),
            Text(
              e.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: T.textPrimary, height: 1.2),
            ),
            const SizedBox(height: 2),
            Text(
              e.sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: AppColors.textPlaceholder, height: 1.2),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 5. 三宫格（投诉客服 / 打赏 / 充值）
  // -------------------------------------------------------------------

  /// 三宫格：投诉客服（绿）/ 打赏（橙金）/ 充值（蓝）
  ///
  /// **为什么它还留在首页**：这三件事没有第二个入口（充值也只有这里进），
  /// 而快捷入口四格已被"覆盖现有页面入口"占满 → 按负责人「不许让功能失去入口」独立成节，
  /// 位置钉在快捷入口之后、热门游戏之前。
  ///
  /// 视觉上与上面那格 4 宫格**刻意不同**：横排"图标 + 文字"的紧凑条，避免两个同形宫格上下叠。
  Widget _entryGrid() {
    final items = <Widget>[
      _entryCell(
        label: '投诉客服',
        icon: AppIcons.headset,
        color: AppColors.entrySupport,
        onTap: () => _push(const ComplaintPage()),
      ),
      _entryCell(
        label: '打赏',
        icon: AppIcons.gift,
        color: AppColors.entryTip,
        onTap: () => _push(const TipPage()),
      ),
      _entryCell(
        label: '充值',
        icon: AppIcons.recharge,
        color: T.primary,
        onTap: _openRecharge,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.strokeSoft),
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Container(width: 1, height: 20, color: T.divider),
              Expanded(child: items[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entryCell({
    required String label,
    required AppIcons icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: T.textPrimary),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 6. 热门游戏（分部导航）
  // -------------------------------------------------------------------

  /// 热门游戏：`GET /divisions/grouped`（或聚合的 `divisions`）
  ///
  /// 一张卡 = **分部封面（管理端官方图，无图回退自绘游戏图标）+ 完整分部名 + 一行服务标签 +
  /// 真实在线人数 + 右侧「进入服务」主色按钮**。
  ///
  /// - 卡面**在线人数**来自服务端 `onlineCount`（按"在职 + 可接单"统计，客户端不写死）；
  /// - 「一行服务标签」= 分部自己的 `onlineDesc`，没填则用**管理端配置的分类名**拼前两项
  ///   （[_oneLinerFor]）—— 两者都没有就不渲染那一行，不编文案；
  /// - 点击 → 现有「选择服务」页（`ProductListPage`，按 `divisionId` 预选）；
  ///   建设中分部仍走既有「建设中」页（行为一字未改）；
  /// - 一个分部都没有 → 整块不渲染。
  Widget _hotGamesSection() {
    final list = _dedupeById(_divisions, (d) => d.id);
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: '热门游戏',
          action: '全部游戏',
          onAction: () => widget.onGoOrder?.call(null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _hotGameCard(list[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _hotGameCard(_Division d) {
    final oneLiner = _oneLinerFor(d);
    return GestureDetector(
      onTap: () => _openDivision(d),
      behavior: HitTestBehavior.opaque,
      child: Container(
                padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.strokeSoft),
        ),
        child: Row(
          children: [
            GameIconTile(
              gameKey: d.gameKey,
              platform: d.platform,
              color: d.color,
              size: 56,
              radius: 14,
              badge: false,
              mediaId: d.imageMediaId,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          // **完整名**（`三角洲行动 · 端游`）而不是 shortName：同游戏的手机端/端游
                          // 必须能区分（shortName 两条一模一样，列表里会像"重复项"）
                          d.name.isEmpty ? d.shortName : d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.textPrimary),
                        ),
                      ),
                      if (d.underConstruction) ...[const SizedBox(width: 6), _constructionChip()],
                    ],
                  ),
                  if (oneLiner.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      oneLiner,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: T.mutedText, height: 1.2),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        width: 6,
                          height: 4,
                        decoration: BoxDecoration(
                          color: d.onlineCount > 0 ? AppColors.statusOnline : AppColors.textTertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${d.onlineCount} 人在线',
                        style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _pillButton(
              label: '进入服务',
              onTap: () => _openDivision(d),
              filled: true,
            ),
          ],
        ),
      ),
    );
  }

  /// 分部卡的「一行服务标签」——**只取真实配置，不编文案**：
  /// 1. 分部自己的 `onlineDesc`（管理端给这个分部填的说明，最常见）；
  /// 2. 否则用**管理端配置的分类**拼一句（先按该分部所属游戏过滤、再按 id 去重，取前 2 个名字）；
  /// 3. 都没有 → 空串（整行不渲染）。
  String _oneLinerFor(_Division d) {
    final desc = d.onlineDesc.trim();
    if (desc.isNotEmpty) return desc;
    final names = <String>[];
    for (final c in _categoriesForGame(d.gameId)) {
      if (names.contains(c.name)) continue;
      names.add(c.name);
      if (names.length >= 2) break;
    }
    return names.join(' · ');
  }

  /// 建设中「小片」（发丝线描边 + 次级文字，不用彩色胶囊）
  Widget _constructionChip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: T.divider),
        ),
        child: Text(
          '建设中',
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: T.textSecondary, height: 1.3),
        ),
      );

  // -------------------------------------------------------------------
  // 7. 精选服务（横排卡片）
  // -------------------------------------------------------------------

  /// 精选服务：`GET /public/products`（既有公开接口，一次拉全）
  ///
  /// 一张卡 = **封面 + 名称 + 一行副标 + `¥N 起` + 圆形箭头**，点卡 → 现有商品详情页。
  /// 副标取服务端 `subtitle`；没有副标就只有名称（**不编副标**）。
  /// 商品为空/请求失败 → 整块不渲染（不摆假卡、不摆「待接入」）。
  Widget _featuredServicesSection() {
    final items = _allProducts.take(8).toList(growable: false);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: '精选服务',
          action: '全部服务',
          onAction: () => widget.onGoOrder?.call(null),
        ),
        LayoutBuilder(
          builder: (context, box) {
            // 卡宽 = 视口宽 × 0.44（一张卡 + 下一张露头 → 一眼看出"这里可以横滑"）
            final cardWidth = box.maxWidth * 0.44;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    SizedBox(width: cardWidth, child: _productCard(items[i])),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _productCard(_HomeProduct p) {
    return GestureDetector(
      onTap: () => _openProduct(p),
      behavior: HitTestBehavior.opaque,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.strokeSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 封面：管理端挂图就用图；没图回退所属分部的游戏图标块（不猜、不编）
            AspectRatio(
              aspectRatio: 16 / 9,
              child: p.coverUrl == null
                  ? _productCoverFallback(p)
                  : CachedNetImage(url: p.coverUrl!, fit: BoxFit.cover),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.listDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textPrimary, height: 1.3),
                  ),
                  if (p.subtitle.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      p.subtitle.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.2),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          // 金额串只经 `fmtMoney` 产出 → `AppPrice`，不自己拼 ¥ / 小数位
                          child: AppPrice(
                            value: fmtMoney(p.price),
                            unit: '起',
                            size: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 圆形箭头：主色浅底 + 主色箭头（"这一格可以点"的唯一信号）
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: T.primarySoft,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: AppIcon(AppIcons.arrowRight, size: 14, color: T.primary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 商品无封面时的兜底块：用**所属分部**的官方图/游戏图标（对照不到就交给组件的稳定兜底）
  Widget _productCoverFallback(_HomeProduct p) {
    final d = _divisionOfProduct(p);
    return Container(
      color: AppColors.fieldBg,
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.contain,
        child: GameIconTile(
          gameKey: d?.gameKey ?? p.gameId,
          platform: d?.platform,
          color: d?.color,
          size: 96,
          radius: AppDecoRadius.none,
          badge: false,
          mediaId: d?.imageMediaId,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 8. 人气打手（横排 4 卡）
  // -------------------------------------------------------------------

  /// 人气打手：`GET /public/players`（或聚合的 `players`），**按 `completedOrders` 降序取前 4**
  ///
  /// 一张卡 = 头像 + 等级徽章（`WorkerGradeBadge`，`grade/gradeLabel/gradeName` 由接口下发）
  /// + 名字 + 好评率 + 接单数 + 分部标签 + 「选择 TA」浅底按钮。
  ///
  /// **不显示"在线点"**：`/public/players` 没有在线状态字段 —— 接口没给就是没有，
  /// 不拿"随机亮一盏绿灯"凑版面（负责人硬要求：不许造假数据）。
  /// 好评率走唯一出口 `satisfiedRateText()`（无评价时是「暂无评价」，绝不编 100%）。
  Widget _topPlayersSection() {
    final list = _players;
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          title: '人气打手',
          action: '全部陪玩',
          onAction: _openPlayers,
        ),
        LayoutBuilder(
          builder: (context, box) {
            // 卡宽 = 视口宽 × 0.45（4 张横滑，一张卡 + 下一张露头）
            final cardWidth = box.maxWidth * 0.45;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    SizedBox(width: cardWidth, child: _playerCard(list[i])),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _playerCard(_HomePlayer p) {
    final rate = satisfiedRateText(p.satisfiedRate, reviewCount: p.reviewCount);
    final orders = p.completedOrders == null ? '' : '接单 ${countText(p.completedOrders)} 次';
    final division = (p.divisionName ?? '').trim();
    final grade = p.grade;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.strokeSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(
                nickname: p.nickname,
                mediaId: p.avatarMediaId,
                size: 44,
                color: T.primary,
              ),
              const Spacer(),
              // 等级徽章（右上）：接口没给等级 → 这一格不渲染（不画 `--` 占位）
              if (grade != null)
                WorkerGradeBadge(grade: grade, size: 14, label: p.gradeName, labelSize: 10.5),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            p.nickname,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textPrimary, height: 1.2),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              AppIcon(AppIcons.star, size: 11, color: AppColors.goldText),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  rate,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.goldText, height: 1.2),
                ),
              ),
            ],
          ),
          if (orders.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              orders,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.2),
            ),
          ],
          if (division.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.fieldBg,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                division,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: T.textSecondary, height: 1.2),
              ),
            ),
          ],
          const SizedBox(height: 10),
          _pillButton(
            label: '选择 TA',
            onTap: () => _openPlayer(p),
            filled: false,
            expand: true,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 公共小件
  // -------------------------------------------------------------------

  /// 模块标题：`▍标题` + 右侧「全部 X ›」（主色小字）
  ///
  /// 走既有装饰原子 [AppSectionHeaderDeco]（4×16 品牌短标 + 标题 + 主色 action），
  /// `showRule: false` —— 参考图这三块标题下面都没有分隔线（层级靠留白与卡片本身）。
  Widget _sectionHeader({
    required String title,
    required String action,
    required VoidCallback onAction,
  }) {
    return AppSectionHeaderDeco(
      title: title,
      action: '$action ›',
      onAction: onAction,
      level: AppSectionLevel.top,
      showRule: false,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
    );
  }

  /// 胶囊按钮：[filled] = 主色实底白字；false = 主色浅底主色字
  Widget _pillButton({
    required String label,
    required VoidCallback onTap,
    required bool filled,
    bool expand = false,
  }) {
    final body = Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? T.primary : T.primarySoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: filled ? Colors.white : T.primary,
          height: 1.2,
        ),
      ),
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: expand ? SizedBox(width: double.infinity, child: body) : body,
    );
  }

  Widget _errorCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: T.bgCardSolid,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: T.divider),
          ),
          child: Row(
            children: [
              AppIcon(AppIcons.info, size: 18, color: T.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('内容加载失败，请下拉重试', style: TextStyle(fontSize: 12.5, color: T.textSecondary)),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_error!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10.5, color: T.textTertiary)),
                      ),
                  ],
                ),
              ),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );

  // -------------------------------------------------------------------
  // 跳转
  // -------------------------------------------------------------------

  /// 宣传图点击 → 按 `linkType` 分发跳转
  void _openBanner(HomeBannerItem item) {
    final action = BannerLinkAction.resolve(item);
    if (action.isNone) return;
    switch (action.type) {
      case BannerLinkType.product:
        _push(ProductDetailPage(productId: action.value));
        break;
      case BannerLinkType.division:
        widget.onGoOrder?.call(action.value);
        break;
      case BannerLinkType.announcement:
        _push(AnnouncementDetailPage(announcementId: action.value));
        break;
      case BannerLinkType.url:
        AppToast.info(context, '外链需在浏览器打开：${action.value}');
        break;
      case BannerLinkType.none:
      case BannerLinkType.tab:
        break;
    }
  }

  /// **二级页唯一出口**：本页所有 push 都从这里走（转场只写一份，见 [_slideRoute]）
  Future<void> _push(Widget page) {
    return Navigator.of(context).push(_slideRoute(page));
  }

  /// 打开充值页（三宫格第三格 = 首页唯一的充值入口）
  Future<void> _openRecharge() async {
    await _push(RechargePage(api: widget.api));
    if (mounted) await _load(force: true);
  }

  /// 公告滚动栏 → **公告列表页**（真公告；系统通知在「我的」页，两者不同东西）
  void _openAnnouncements() => _push(AnnouncementsPage(api: widget.api));

  /// 搜索入口（与改版前同一条路：`FriendSearchPage`）
  void _openSearch() => _push(FriendSearchPage(api: widget.api));

  /// 消息通知 / 联系客服 → 底栏「消息」tab
  ///
  /// 红点点亮后，用户去看消息 = 未读已被消费 → 顺手灭灯（不残留一个假红点）。
  void _openMessages() {
    widget.onNavigate?.call(ServicesPage.navMessages);
    if (_hasUnread) setState(() => _hasUnread = false);
  }

  /// 选择陪玩：外壳回调优先；**没注入时直接 push 现有页面**（不给用户一个点了没反应的格子）
  void _openPlayers() {
    final cb = widget.onFindPlayers;
    if (cb != null) {
      cb();
      return;
    }
    _push(PlayersPage(api: widget.api));
  }

  /// 人气打手「选择 TA」→ 现有陪玩主页（列表已拿到的字段先渲染，详情页自己回源）
  void _openPlayer(_HomePlayer p) {
    _push(WorkerProfilePage(
      api: widget.api,
      workerId: p.id,
      fallbackNickname: p.nickname,
      fallbackIntro: p.intro,
      fallbackAvatarMediaId: p.avatarMediaId,
      fallbackDivisionName: p.divisionName,
    ));
  }

  /// 点分部（建设中 → 建设中页；正常分部 → 选择服务页，按 divisionId 预选）
  void _openDivision(_Division d) {
    if (!d.underConstruction) {
      widget.onGoOrder?.call(d.id);
      return;
    }
    _push(DivisionUnderConstructionPage(
      name: d.name,
      shortName: d.shortName,
      platform: d.platform,
      platformLabel: d.platformLabel,
      gameKey: d.gameKey,
      themeColor: d.themeColor,
      imageMediaId: d.imageMediaId,
      noticeText: d.noticeText,
    ));
  }

  /// 商品卡点击 → 商品详情页（详情/价格/限购一律由详情页自己回源）
  Future<void> _openProduct(_HomeProduct p) async {
    await _push(ProductDetailPage(
      api: widget.api,
      productId: p.id,
      initialName: p.name,
      initialCoverUrl: p.coverUrl,
    ));
    // 从详情页回来刷新商品（用户可能刚下过单：销量变了）—— 只刷商品，不动分部/公告
    if (mounted) unawaited(_loadProducts(force: true));
  }
}

/// 快捷入口的一格（数据 + 去向）
class _QuickEntry {
  const _QuickEntry({
    required this.label,
    required this.sub,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String sub;
  final AppIcons icon;
  final Color color;
  final VoidCallback onTap;
}

/// 分部（`/divisions/grouped` 单条）
class _Division {
  _Division({
    required this.id,
    required this.shortName,
    required this.name,
    required this.platformLabel,
    required this.onlineDesc,
    required this.themeColor,
    required this.platformCount,
    required this.onlineCount,
    this.gameName = '',
    this.gameId = '',
    this.code = '',
    this.platform = '',
    this.iconMediaId,
    this.coverMediaId,
    this.underConstruction = false,
    this.noticeText = '',
  });

  final String id;
  final String shortName;
  final String name;
  final String platformLabel;
  final String onlineDesc;
  final String themeColor;
  final String gameName;

  /// 所属游戏 id（服务端下发；分类按游戏过滤时用它）
  final String gameId;
  final String code;
  final String platform;
  final int platformCount;

  /// **真实在线人数**（服务端按 在职 + 可接单 统计，客户端不写死）
  final int onlineCount;

  final String? iconMediaId;
  final String? coverMediaId;

  /// **是否建设中**（服务端 `underConstruction`）：true = 名称后带「建设中」小片、点击进建设中页
  final bool underConstruction;

  /// **建设中页提示文案**（服务端 `noticeText`）—— 客户端**不硬编码任何文案**
  final String noticeText;

  /// 分部展示图：有图就用图（iconMediaId 优先，其次 coverMediaId；都空 → 自绘游戏图标回退）
  String? get imageMediaId => divisionMediaId(iconMediaId: iconMediaId, coverMediaId: coverMediaId);

  /// 游戏图标映射键：code（peace_mobile）→ gameName（和平精英）→ name 逐级兜底
  String get gameKey => '$code $gameName $name $shortName'.trim();

  Color get color {
    final hex = themeColor.replaceFirst('#', '');
    if (hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return AppColors.primary;
  }

  factory _Division.fromJson(Map json, {required int platformCount}) => _Division(
        id: '${json['id']}',
        shortName: (json['shortName'] as String?)?.trim().isNotEmpty == true
            ? json['shortName'] as String
            : (json['gameName'] as String? ?? ''),
        name: (json['name'] as String? ?? ''),
        platformLabel: (json['platformLabel'] as String? ?? ''),
        onlineDesc: (json['onlineDesc'] as String? ?? ''),
        themeColor: (json['themeColor'] as String? ?? ''),
        platformCount: platformCount,
        onlineCount: (json['onlineCount'] as num?)?.toInt() ?? 0,
        gameName: (json['gameName'] as String? ?? ''),
        gameId: '${json['gameId'] ?? ''}',
        code: (json['code'] as String? ?? ''),
        platform: (json['platform'] as String? ?? ''),
        iconMediaId: json['iconMediaId'] == null ? null : '${json['iconMediaId']}',
        coverMediaId: json['coverMediaId'] == null ? null : '${json['coverMediaId']}',
        underConstruction: divisionUnderConstruction(json['underConstruction']),
        noticeText: (json['noticeText'] as String? ?? ''),
      );
}

/// 管理端配置的商品分类（`GET /public/categories` 单条）
///
/// 存进页面状态时**保持管理端原样（不去重）**：去重必须发生在**按当前分部/游戏过滤之后**
/// （库里的「护航带打」是 id=71/72 两行，全局去重对它无效）。
class _HomeCategory {
  const _HomeCategory({required this.id, required this.name, this.gameId = ''});

  final String id;
  final String name;

  /// 所属游戏（服务端 `gameId`；空 = 不限游戏，用于和分部的 `gameId` 对位）
  final String gameId;

  factory _HomeCategory.fromJson(Map json) => _HomeCategory(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}'.trim(),
        gameId: '${json['gameId'] ?? ''}',
      );
}

/// 首页公告条单条（`/public/announcements` / 聚合的 `announcements`）
class _HomeAnnouncement {
  const _HomeAnnouncement({required this.id, required this.title, required this.createdAt});

  final String id;
  final String title;

  /// 发布时间（解析不出来 → null → 那一格日期不渲染）
  final DateTime? createdAt;
}

/// 人气打手单条（`/public/players` / 聚合的 `players`）
///
/// **逐项可空解析**：缺失就是 `null` → 那一项**不渲染**（最低降到「头像 + 名字」）。
/// 不猜 0、不编 100%。（字段口径与服务端 `PlayersService.list()` 的 `PublicPlayerItem` 逐字对应。）
class _HomePlayer {
  const _HomePlayer({
    required this.id,
    required this.nickname,
    required this.intro,
    required this.avatarMediaId,
    required this.divisionName,
    required this.completedOrders,
    required this.reviewCount,
    required this.satisfiedRate,
    required this.grade,
    required this.gradeName,
  });

  final String id;
  final String nickname;
  final String intro;
  final String? avatarMediaId;
  final String? divisionName;

  /// 接单次数（服务端**生效值**：管理端设过展示值则为展示值）—— 可空
  final int? completedOrders;

  /// 评价条数（永远真实）—— 可空
  final int? reviewCount;

  /// 好评率原值（**原样收**，怎么显示由 `satisfiedRateText()` 一处说了算）—— 可空
  final Object? satisfiedRate;

  /// 等级 1–5 与中文名（`WorkerGradeBadge` 直接吃）—— 可空
  final int? grade;
  final String gradeName;

  factory _HomePlayer.fromJson(Map json) => _HomePlayer(
        id: '${json['workerId'] ?? json['id'] ?? ''}',
        nickname: (json['nickname'] as String?)?.trim() ?? '',
        intro: (json['intro'] as String?)?.trim() ?? '',
        avatarMediaId: json['avatarMediaId'] == null ? null : '${json['avatarMediaId']}',
        divisionName: (json['divisionName'] as String?)?.trim(),
        completedOrders: _intOf(json['completedOrders']),
        reviewCount: _intOf(json['reviewCount']),
        satisfiedRate: json['satisfiedRate'],
        grade: _intOf(json['grade']),
        gradeName: '${json['gradeName'] ?? ''}'.trim(),
      );

  /// `int` / `num` / 数字串都吃，其余 → null（**不猜 0**）
  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.isFinite ? raw.toInt() : null;
    final s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    if (d == null || !d.isFinite) return null;
    return d.toInt();
  }
}

/// 首屏数据（回落路径的解析产物）
class _HomeParts {
  const _HomeParts({
    required this.divisions,
    required this.banners,
    required this.announcements,
    required this.players,
  });

  final List<_Division> divisions;
  final List<HomeBannerItem> banners;

  /// 公告（`/public/announcements`）
  final List<_HomeAnnouncement> announcements;

  /// 陪玩（回落路径这里恒为空 → 由 `_loadPlayers()` 补一发）
  final List<_HomePlayer> players;
}

/// 首屏聚合的解析结果（`GET /public/home`，契约见 [_ServicesPageState._fetchAggregate]）
class _HomeAggregate {
  const _HomeAggregate({
    required this.banners,
    required this.divisions,
    required this.rawDivisions,
    required this.announcements,
    required this.players,
    required this.sections,
  });

  final List<HomeBannerItem> banners;
  final List<_Division> divisions;

  /// 分部原始行（展平后的 Map）；自检口径用它证明"聚合路径拿到的分部行数"
  final List<dynamic> rawDivisions;

  /// 公告（聚合的 `announcements` → **零额外请求**）
  final List<_HomeAnnouncement> announcements;

  /// 陪玩（聚合的 `players` → **零额外请求**）
  final List<_HomePlayer> players;

  /// 各段条数（自检口径：证明"一次拿全"而非拿到半包）
  final Map<String, int> sections;
}

/// 首页商品（`GET /public/products` 列表档单条）
///
/// 只接列表卡用得到的字段（服务端列表接口本来就是裁剪档）；价格/须知/限购**一律不在列表里用**，
/// 点进详情页由 `ProductDetailPage` 自己回源 —— 客户端不把列表值当详情用。
class _HomeProduct {
  const _HomeProduct({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.price,
    required this.priceUnit,
    required this.salesCount,
    required this.coverUrl,
    required this.divisionId,
    required this.gameId,
    required this.categoryId,
    this.listName,
  });

  final String id;
  final String name;
  final String subtitle;
  final double price;
  final String priceUnit;
  final int salesCount;

  /// 封面绝对地址（`coverUrl` 优先，其次 `coverMediaId` 拼 `/media/public/{id}`）；空 = 用分部图标兜底
  final String? coverUrl;

  /// 所属分部（服务端 `divisionId`；空 = 老数据没挂分部 → 退一步按 [gameId] 对位）
  final String? divisionId;

  /// 所属游戏 id（分部对照不到时用它退一步匹配同分部的游戏）
  final String gameId;

  /// 所属分类（服务端 `categoryId`）
  final String categoryId;

  /// 列表短名（管理端可配；空 → 回退完整 [name]）
  final String? listName;

  /// 列表卡上真正显示的名字：短名优先，空则回退完整名
  String get listDisplayName => (listName != null && listName!.isNotEmpty) ? listName! : name;

  factory _HomeProduct.fromJson(Map json) {
    final rawCover = (json['coverUrl'] as String?) ?? '';
    return _HomeProduct(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      subtitle: '${json['subtitle'] ?? ''}',
      // 金额解析与全站同一套（`parsePoints`：字符串/整数/小数都收；非法值 → 0）
      price: parsePoints(json['price']),
      priceUnit: '${json['priceUnit'] ?? ''}',
      salesCount: (json['salesCount'] as num?)?.toInt() ?? 0,
      coverUrl: rawCover.isNotEmpty
          ? AppConfig.resolveMediaUrl(rawCover)
          : (json['coverMediaId'] == null
              ? null
              : AppConfig.resolveMediaUrl('/media/public/${json['coverMediaId']}')),
      divisionId: json['divisionId'] == null ? null : '${json['divisionId']}',
      gameId: '${json['gameId'] ?? ''}',
      categoryId: '${json['categoryId'] ?? ''}',
      // 短名 trim 后为空一律当"没配"（避免管理端存了空格就把名字显示成空白）
      listName: (json['listName'] as String?)?.trim().isNotEmpty == true ? '${json['listName']}'.trim() : null,
    );
  }
}
