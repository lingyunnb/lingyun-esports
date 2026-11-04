import 'dart:math' as math;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../models/review_models.dart';
import 'worker_profile_page.dart';

/// 选择陪玩（**版式重构 · 照负责人 2026-10-17 两张参考图**）
///
/// ## 依据（口径变更，先读这一段）
/// 负责人 2026-10-17 提供两张东东电竞/GM 风格参考图，明确要求**照版式重构**本页与
/// 打手主页；并当日下指令覆盖 `CLAUDE.md` 结构规则 6 的旧禁项
/// （原「陪玩只允许 名字 + 介绍，禁止评分/等级/单价/人数/标签胶囊」）。
/// 因此本页**允许**出现这些字段；相关测试里"禁止出现 X"的断言已按新口径重钉成
/// "必须有 X"（每条都在测试注释里写明依据「负责人 2026-10-17 指示照参考图重构」）。
///
/// **只学版式 / 信息层级 / 卡片构成，配色一律走项目 token**（蓝金体系，不抄参考图的粉紫）：
/// 主色 `AppColors.primary` · 页底 `AppColors.bgPageG` · 卡白 + 1px `AppColors.strokeSoft`
/// · 圆角只用 0/4/6/10/14/胶囊。（金额那两档金色随金额位一起离开本页。）
///
/// ## 页面结构（自上而下，与参考图 1 逐块对齐）
/// ① 页头（选择陪玩）
/// ② **两张入口卡**（全部 · 人气陪玩；各占一半宽）
/// ③ 问祁小山 + AI 按需求挑人（既有能力，位置不变）
/// ④ **游戏宫格筛选**（胶囊 + 游戏图标；选中 = 主色实底/描边）
/// ⑤ **分页小圆点 + 右侧「筛选」**
/// ⑥ 计数行（真实总数）
/// ⑦ **陪玩卡**：左「大方形圆角头像」+ 右（名字 / 黑色实底分部胶囊 / 介绍 2 行 / 元信息）
///
/// **金额位已删除（负责人真机圈图，2026-10-18）**：参考图那一行「大号金字价格」在本卡上
/// 曾渲染成 `¥--` + 「待接入」（后端确实没有单价字段）——负责人圈着它说「这个标志也去掉」。
/// 于是整块删掉（占位、`¥--`、间距一起），卡高随之由 148 降到 128（见 [PlayersPage.cardHeight]）。
/// **保留**「接单 N 次」与「好评率」——这两项是真实数据（`completedOrders` / `satisfiedRate`）。
///
/// 参考图底部那「5 项导航 + 自助下单浮标」属于 `home_shell`（本页是二级页，不自建底栏，
/// 也不许改那个文件）。
///
/// ## 参考图里有、但**后端没有字段**的东西一律不造假
/// 性别小标 / 「空闲」状态 / 视频角标 `05"` / 打手角色（常规对局·航天）/「明星打手」浅底胶囊
/// —— 这些**一个新字段都没有**，所以**不渲染**（宁可少画，也不编）。
/// 版式上必须存在的缺失字段（详见 [kRatingPendingText] 附近注释）**照画版式、填「待接入」**：
/// 六维评分 · 礼物墙 · 粉丝/推荐数 · 等级 · 时长。
/// 单价不在其中：**列表卡上的金额位整块已删除**（负责人真机圈图，2026-10-18），
/// 详情页（`worker_profile_page.dart`）里的那一份仍按原样保留。
///
/// ## 三处必须锁死的口径（与重构前逐字相同）
/// 1. **卡片行高恒定** [PlayersPage.cardHeight]：带介绍 / 不带介绍**完全一样高**；
///    介绍为空渲染弱化占位「介绍待补充」，**不隐藏节点**（线上 13/14 人为空）。
/// 2. **好评率只认服务端百分数**：`satisfiedRateText()`（`models/review_models.dart`）**唯一出口**；
///    无评价 → 「暂无评价」，**绝不编 100%**。
/// 3. **接单次数**只走 `countText()`（千分位）。
class PlayersPage extends StatefulWidget {
  const PlayersPage({super.key, this.api, this.initialDivisionId});

  final ApiClient? api;
  final String? initialDivisionId;

  /// 「正在刷新」弱提示的锚点（发丝线级 2dp；缓存优先先画时就该出现）
  static const Key refreshingHairlineKey = Key('players-refreshing-hairline');

  /// 卡片高度（= 128dp）
  ///
  /// 恒定性是硬约束：带介绍 / 不带介绍**同一高度**（骨架卡也用这个常量）。
  ///
  /// 怎么算出来的：右栏五行 = 名字 20 + 4 + 分部胶囊 20 + 4 + 介绍 2 行 34 + 4 + 元信息 16
  /// = **102**，加上下内距 12×2 = 126，取 4dp 网格上最近的一档 → **128**（内容区 104，
  /// 留 2dp 余量，与改动前那 2dp 余量逐值相同）。
  ///
  /// 2026-10-18 负责人真机圈图：卡上那枚 `¥--  待接入` 整块删除（后端本来就没有单价字段，
  /// 占位画着更像"坏了的价签"）→ 行高由 148 降到 128，少掉的正是那 20dp 金额行与它上面的 4dp；
  /// 左头像随之由 120 收到 96（内容区只有 104，不收就溢出）。骨架卡与真卡仍共用一个常量。
  static const double cardHeight = 112;

  /// 左头像边长上限（390 逻辑宽下卡内容宽 332，头像 96 ≈ 卡宽 29%）
  ///
  /// 为什么不是"填满内容区 104"：104 会顶死卡内高度，字号/行高一动就溢出；
  /// 96 留 8dp 纵向余量，且 96 落在 4dp 网格上。
  static const double avatarMax = 64;

  /// 介绍位固定高度（**两行**，`12/16.8` 字号行高下正好 34dp）
  static const double introBoxHeight = 34;

  /// 等级预留位 L-SLOT 的尺寸（高 20 × 最长 72；见 `worker_profile_page.dart` 同名常量）
  static const double levelSlotHeight = AppLevelSlot.slotHeight;
  static const double levelSlotMaxWidth = AppLevelSlot.slotMaxWidth;

  @override
  State<PlayersPage> createState() => _PlayersPageState();
}

/// 名单排序（参考图顶部三入口卡里「人气陪玩」对应的**真实**排序）
///
/// 它不是假字段：`completedOrders` 是服务端下发的生效值，这里只是客户端重排。
enum _SortMode {
  /// 默认（服务端顺序 = 按 worker.id）
  byDefault,

  /// 人气陪玩：接单量从高到低
  byOrders,
}

class _PlayersPageState extends State<PlayersPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  bool _loading = true;
  String? _error;
  List<_Division> _divisions = const [];
  List<_Player> _players = const [];
  String? _divisionId;

  /// 服务端返回的真实总数（计数行用；拿不到时退一步用本次条数）
  int _total = 0;

  /// 屏上有内容、后台正在回源（发丝线级弱提示用；见 `build` 里的 Stack）
  bool _refreshing = false;

  /// 排序（默认 / 人气陪玩）—— 只影响本页渲染顺序，不改请求、不改服务端口径
  _SortMode _sort = _SortMode.byDefault;
  /// 搜索框控制器 + 当前关键词（本地过滤名字/介绍，不发请求）
  final TextEditingController _search = TextEditingController();
  String _query = '';


  /// AI 推荐：输入 / 进行中 / 结果 / 错误（与列表加载完全独立，互不阻塞）

  @override
  void initState() {
    super.initState();
    _divisionId = widget.initialDivisionId;
    _bootstrap();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    /**
     * 【2026-10-15 秒刷专项】两条改动，都不改接口、不改权限、不改数据口径：
     *
     * ① **缓存优先（0 请求先上屏）**：先把上一次的分部胶囊与名单画上（哪怕已过期），
     *    再回源覆盖 —— 用户感知从"进页白屏等 2 个往返"变成"秒出 + 顶部一条发丝线"。
     *    过期时给弱提示（`_refreshing`），别让用户以为这就是最新的。
     *
     * ② **并行化**：分部 id 能**提前确定**时（外部指定 / 缓存里就有上一次的分部列表），
     *    `/divisions` 与 `/public/players` **同时发** —— 首屏从 2 个往返压到 1 个。
     *    确定不了（本次运行内从没拉到过分部）则维持原来的串行两跳：宁可多等一跳，
     *    也不许拿"猜出来的分部"去请求（那会把别的分部的名单亮给老板）。
     */
    final cachedDivs = _cachedDivisions();
    final predicted = widget.initialDivisionId ?? (cachedDivs.isNotEmpty ? cachedDivs.first.id : null);
    if (predicted != null) _divisionId = predicted;
    if (cachedDivs.isNotEmpty && mounted) setState(() => _divisions = cachedDivs);
    _paintPlayersFromCache();

    try {
      final results = await Future.wait<Object?>([
        _api.request('GET', '/divisions'),
        // 只有"分部已确定"时才并行发名单；否则留到分部回来后再发（见下面的 else 分支）
        if (predicted != null)
          _api.request('GET', '/public/players', queryParameters: {
            'divisionId': predicted,
            'page': 1,
            'pageSize': 50,
          }, forceRefresh: true),
      ]);
      final resp = results[0]! as Map<String, dynamic>;
      if (!mounted) return;
      final list = (resp['data'] as List?) ?? const [];
      final divs = list.map((d) => _Division.fromJson(d as Map)).toList();
      setState(() {
        _divisions = divs;
        _divisionId ??= divs.isNotEmpty ? divs.first.id : null;
      });
      // 并行那条名单什么时候能直接用：**它请求的分部 == 最终选中的分部**。
      // - 外部指定 `initialDivisionId` → 最终选中就是它（`_divisionId ??=` 不会覆盖），恒成立；
      // - 由缓存推断 → 必须与服务端刚返回的第一个分部一致（管理端刚改过分部顺序时不一致 → 重取）。
      final serverFirst = divs.isNotEmpty ? divs.first.id : null;
      final parallelUsable = predicted != null && predicted == _divisionId && (widget.initialDivisionId != null || predicted == serverFirst);
      if (parallelUsable && results.length > 1) {
        final data = ((results[1] as Map<String, dynamic>)['data'] as Map?) ?? const {};
        if (mounted) {
          setState(() {
            _players = _playersOf(data);
            _total = _totalOf(data, _players.length);
            _loading = false;
            _error = null;
            _refreshing = false;
          });
        }
        return;
      }
      // 进入页面即回源（force）：名单随管理端「分部接单权限」实时变，
      // 不能把上一次进来时看到的旧名单直接亮出来（与「指定护航员」弹层同一口径）。
      await _loadPlayers(force: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e.message;
      });
    }
  }

  /// `data.list` → 玩家列表（**唯一入口**：解析规则只写一次）
  List<_Player> _playersOf(Map data) =>
      ((data['list'] as List?) ?? const []).map((p) => _Player.fromJson(p as Map)).toList();

  /// 计数行用的真实总数：服务端 `total` 优先，拿不到时退一步用本次条数（不编数字）
  int _totalOf(Map data, int fallback) => int.tryParse('${data['total'] ?? ''}') ?? fallback;

  /// 缓存里上一次的分部列表（同步、0 请求）—— 只用来"提前决定并行请求的分部 id"与先画胶囊
  ///
  /// 取不到（本次运行内从没拉到过）返回空列表：那时**不猜**，走原来的串行两跳。
  List<_Division> _cachedDivisions() {
    final peek = _api.peekCache('/divisions');
    if (peek == null) return const [];
    try {
      return ((peek.body['data'] as List?) ?? const [])
          .map((d) => _Division.fromJson(d as Map))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 用缓存里**当前选中分部**的名单先画一屏（同步、0 请求；未命中则什么都不做）
  void _paintPlayersFromCache() {
    if (_players.isNotEmpty) return;
    final peek = _api.peekCache('/public/players', <String, dynamic>{
      'divisionId': ?_divisionId,
      'page': 1,
      'pageSize': 50,
    });
    if (peek == null) return;
    final data = (peek.body['data'] as Map?) ?? const {};
    final list = (data['list'] as List?) ?? const [];
    if (!mounted) return;
    setState(() {
      _players = list.map((p) => _Player.fromJson(p as Map)).toList();
      _total = _totalOf(data, _players.length);
      _loading = false;
      _refreshing = true;
    });
  }

  Future<void> _loadPlayers({bool force = false}) async {
    setState(() {
      // 已有内容时不再整页转圈：保留名单可见，只显示发丝线级"正在刷新"（与原实现的差异仅此一处）
      if (_players.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });
    try {
      // forceRefresh 必须真透传：`/public/players` 的内容随「分部接单权限」变动，
      // 进入页面（force: true）与下拉刷新都要绕过 SWR 缓存直接回源；
      // 只有页内切换分部时 force=false（键含 divisionId，命中即秒开，不会串分部）。
      final resp = await _api.request('GET', '/public/players', queryParameters: {
        'divisionId': ?_divisionId,
        'page': 1,
        'pageSize': 50,
      }, forceRefresh: force);
      final data = (resp['data'] as Map?) ?? const {};
      if (!mounted) return;
      setState(() {
        _players = _playersOf(data);
        _total = _totalOf(data, _players.length);
        _loading = false;
        _refreshing = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e.message;
      });
    }
  }

  // -------------------------------------------------------------------------
  // ① 问祁小山（一行引导 → 既有 AI 会话页）
  // -------------------------------------------------------------------------



  /// 点卡片 / 点头像 → 打手主页（二级页，push 成全屏 → 底栏被这一页盖住）
  ///
  /// 列表已经拿到的名字/介绍/头像带下去当"先渲染"用的兜底，服务端值一到就覆盖
  /// （列表只是先看一眼，不是第二份真相）。
  Future<void> _openWorkerProfile(_Player p) => Navigator.of(context).push(
        AppMotionRoute<void>(
          builder: (_) => WorkerProfilePage(
            api: widget.api,
            workerId: p.id,
            fallbackNickname: p.name,
            fallbackIntro: p.intro,
            fallbackAvatarMediaId: p.avatarMediaId,
            fallbackDivisionName: p.divisionName,
          ),
        ),
      );

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  /// 排序后的名单（「人气陪玩」= 按接单量降序；接单量缺失的排最后，**不当作 0 分**）
  /// 过滤后的名单（搜索关键词匹配 **名字或介绍**，本地过滤不发请求）
  List<_Player> get _filteredPlayers {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _players;
    return _players.where((p) {
      return p.name.toLowerCase().contains(q) || p.intro.toLowerCase().contains(q);
    }).toList();
  }

  List<_Player> get _sortedPlayers {
    if (_sort == _SortMode.byDefault) return _filteredPlayers;
    final list = [..._filteredPlayers];
    list.sort((a, b) {
      final x = a.completedOrders;
      final y = b.completedOrders;
      if (x == null && y == null) return 0;
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => Scaffold(
        // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
        // 顶栏、入口卡、陪玩卡、筛选胶囊一律实色 —— 它们浮在渐变上，自身一句未改。
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: T.bgCardSolid,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 16,
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // 22 = 七级字号的 Display 档（19 不在七级里）；与入口同名「选择陪玩」
              Text('选择陪玩', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: T.textPrimary)),
              const SizedBox(width: 8),
              Text('介绍由陪玩自己填写', style: TextStyle(fontSize: 11, color: T.mutedText)),
            ],
          ),
        ),
        body: AppPageBg(child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () => _loadPlayers(force: true),
              child: ListView(
                // 页边距交给每个区块自己（卡片要通栏 + 发丝线到底，不能整片缩进 16）
                padding: EdgeInsets.zero,
                children: [
                  // ① 页级标尺线**贴 B0**：端点配置由 `AppBaseline.ruleDotsForBaseline` 给出
                  // （B0 = 无左端点方块），这里不许手挑 ——「装饰不再随手放，而是贴线放」的机械保证。
                  _baselineRule(AppBaseline.b0),
                  // ② 两张入口卡（全部 / 人气陪玩；「明星大神」已按负责人 2026-10-18 删除）
              _searchAndSort(),
                  // ④ 游戏宫格筛选 + ⑤ 圆点与筛选
                  _divisionGrid(),
                  _pagerRow(),
                  _countRow(),
                  _sectionRule(),
                  ..._listChildren(),
                ],
              ),
            ),
            /**
             * 「正在刷新」弱提示（发丝线级 2dp，绝对定位 → 零布局位移）。
             *
             * 缓存优先先画之后必须给这个信号：此刻屏上是**上一次**的名单（可能已过期）。
             * 静态细线而非无限动画：既有出图/渲染用例大量用 `pumpAndSettle`，
             * 无限动画会把它们挂死。
             */
            if (_refreshing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  key: PlayersPage.refreshingHairlineKey,
                  height: 2,
                  color: AppColors.primary.withValues(alpha: 0.45),
                ),
              ),
          ],
        )),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // ② 两张入口卡（信息层级 = 一个图标 + 一行名 + 一行注；各占一半宽）
  // -------------------------------------------------------------------------

  /// 两张入口卡：**全部 / 人气陪玩**（各占一半宽，中间 8dp）
  ///
  /// 两张都是**真功能**：默认顺序 / 按接单量降序，排序用的就是服务端下发的
  /// `completedOrders` 生效值（`null` 排最后，**不当作 0 分**）。
  ///
  /// 原来这里还有第三张「明星大神」：它背后既没有字段也没有列表（后端 0 字段），
  /// 只能渲染成「待接入」且不可点 —— 负责人 2026-10-18 真机圈图要求删掉
  /// （「选择陪玩那里明星大神那个删掉」）。删掉之后**不留第三格空位**：
  /// 两张 `Expanded` 平分整行，高度 / 圆角 / 选中态 / 图标风格一个都没变。
  /// 搜索框 + 排序胶囊（负责人 2026-10-18 重设计）
  ///
  /// 为什么把「全部 / 人气陪玩」两张 64dp 高卡降成横排胶囊：它们本质是**排序**
  /// （默认顺序 vs 按接单量），不是两个"页面"。用整行卡片表达一个排序切换太贵，
  /// 省下的高度正好放搜索框（真正帮人找陪玩的工件）。
  ///
  /// 搜索是**本地过滤**（名字 / 介绍），不发请求 —— 名单已整份在手，
  /// 再打一次接口只会带来延迟和分页口径混乱。
  Widget _searchAndSort() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: TextField(
              key: const Key('players-search-field'),
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: 13, color: T.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜名字或介绍',
                hintStyle: TextStyle(fontSize: 13, color: AppColors.textPlaceholder),
                filled: true,
                fillColor: T.bgCardSolid,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: AppColors.strokeSoft, width: 1),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: AppColors.strokeSoft, width: 1),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: AppColors.primary, width: 1),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _sortChip(
                chipKey: const Key('players-entry-all'),
                label: _loading ? '正在加载' : '全部',
                selected: _sort == _SortMode.byDefault,
                onTap: () => _setSort(_SortMode.byDefault),
              ),
              const SizedBox(width: 8),
              _sortChip(
                chipKey: const Key('players-entry-hot'),
                label: '人气陪玩',
                selected: _sort == _SortMode.byOrders,
                onTap: () => _setSort(_SortMode.byOrders),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 排序胶囊：白底 + 1px 描边；选中 = 深墨实底（全屏唯一重色，与顶部筛选同规则）
  Widget _sortChip({
    required Key chipKey,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: chipKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF111827) : T.bgCardSolid,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? const Color(0xFF111827) : AppColors.strokeSoft,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : T.textSecondary,
          ),
        ),
      ),
    );
  }


  void _setSort(_SortMode next) {
    if (_sort == next) return;
    setState(() => _sort = next);
  }

  // -------------------------------------------------------------------------
  // ④ 游戏宫格筛选（胶囊 + 游戏图标）
  // -------------------------------------------------------------------------

  /// 游戏/分部筛选胶囊：**有几格画几格**（结构规则 2：不画未接入的游戏、不画空框）
  ///
  /// 与旧实现的差别只有形状：由"宫格方块"改成参考图的**胶囊行**（高 32 / 圆角胶囊 /
  /// 图标 16 + 文字 12），选中 = **主色描边 + 主色浅底**（参考图的紫色描边在这里落成品牌蓝）。
  Widget _divisionGrid() {
    if (_divisions.isEmpty) return const SizedBox.shrink();
    final cells = <Widget>[
      _divisionCell(label: '全部', selected: _divisionId == null, onTap: () => _selectDivision(null)),
      for (final d in _divisions)
        _divisionCell(
                label: d.shortName.isNotEmpty ? d.shortName : d.name,
                iconMediaId: d.iconMediaId,
          selected: _divisionId == d.id,
          onTap: () => _selectDivision(d.id),
        ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      // 这一条是**页面底的一段**（不是卡片）：页底换成渐变后必须透明，
      // 否则会在渐变上压出一条 #F6F7F9 的灰带（2026-10-17）
      color: Colors.transparent,
      child: SizedBox(
        height: 32,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: cells.length,
          separatorBuilder: (_, i) => const SizedBox(width: 8),
          itemBuilder: (_, i) => cells[i],
        ),
      ),
    );
  }

  Widget _divisionCell({required String label, String? iconMediaId, required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      key: Key('division-cell-${label == '全部' ? 'all' : label}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // 筛选胶囊（选中态）：**右下 8×8 切口** —— 走谱系档位，切口边长由**胶囊高 32** 推导
      // （`AppNotch.sizeForHeight(32) = 8`，与 `AppNotchRole.filterChip.cut` 逐值一致，测试钉住）。
      // **未选中态 `enabled: false` 一键关掉 —— 未选中一律不切口**（切口是"选中/状态"的专属信号）。
      // `baseColor` 必须是**底下的颜色**（页底浅灰）：切口是"把这一角挖掉"，底色取错会留一个补丁。
      child: AppNotched(
        height: 32,
        corner: AppNotchRole.filterChip.corner,
        enabled: selected,
        baseColor: AppColors.bgPageG,
        borderColor: AppColors.primary,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.primarySoft : T.bgCardSolid,
            borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
            border: Border.all(color: selected ? AppColors.primary : AppColors.strokeSoft, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 游戏小图标（负责人 2026-10-18：「游戏那里放小图标」）
              //
              // 来源：`/divisions` 下发的 `iconMediaId` → 管理端上传的分部图标。
              // 「全部」这类没有图标的胶囊**不占图位**；有分部但没传图标 → 退还通用图标，
              // **绝不渲染空白方块**。
              if (iconMediaId != null && iconMediaId.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: AppAvatar(
                        nickname: label,
                        mediaId: iconMediaId,
                        size: 20,
                        square: true,
                      ),
                    ),
                  ),
                )
              else if (label != '全部')
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: AppIcon(
                    AppIcons.players,
                    size: 16,
                    color: selected ? AppColors.primary : AppColors.textPlaceholder,
                  ),
                ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? AppColors.primary : T.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _selectDivision(String? id) {
    if (_divisionId == id) return;
    setState(() => _divisionId = id);
    _loadPlayers();
  }

  // -------------------------------------------------------------------------
  // ⑤ 分页小圆点 + 右侧「筛选」
  // -------------------------------------------------------------------------

  /// 圆点 + 筛选：圆点的页数**只由真实数据算**（横滚胶囊总宽 ÷ 一屏可容纳几枚）
  ///
  /// 线上只有 1–2 个分部 → 一屏放得下 → **不画圆点**（不画一排永远只有一个点的装饰）；
  /// 分部多到需要横滚时，圆点就是"还有更多"的真实指示。
  /// 「筛选」是真功能：打开一个只含**真实可选排序**的底部面板（默认 / 按接单量）。
  Widget _pagerRow() {
    final pages = _pillPages();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(child: pages <= 1 ? const SizedBox.shrink() : _PagerDots(count: pages, index: 0)),
          GestureDetector(
            key: const Key('players-filter'),
            behavior: HitTestBehavior.opaque,
            onTap: _openFilterSheet,
            child: Container(
              height: 32,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: T.bgCardSolid,
                borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
                border: Border.all(color: AppColors.strokeSoft, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(AppIcons.filter, size: 16, color: T.textSecondary),
                  const SizedBox(width: 4),
                  Text('筛选', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: T.textSecondary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 胶囊行需要几屏（按 4 枚一屏估算：每枚 ≈ 96 宽 + 8 间距 = 104，屏宽 358 → 3.4 枚）
  int _pillPages() {
    final items = _divisions.length + (_divisions.isEmpty ? 0 : 1);
    return items <= 3 ? 1 : (items / 3).ceil();
  }

  /// 筛选面板：只列**真实存在**的排序（默认 / 按接单量），选中打勾
  Future<void> _openFilterSheet() async {
    final picked = await showModalBottomSheet<_SortMode>(
      context: context,
      backgroundColor: T.bgCardSolid,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppDecoRadius.card)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('筛选', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: T.textPrimary)),
            ),
            for (final (mode, label) in const <(_SortMode, String)>[
              (_SortMode.byDefault, '默认顺序'),
              (_SortMode.byOrders, '接单量从高到低'),
            ])
              GestureDetector(
                key: Key('players-filter-${mode.name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(sheetContext).pop(mode),
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: _sort == mode ? FontWeight.w700 : FontWeight.w400,
                              color: _sort == mode ? AppColors.primary : T.textPrimary,
                            ),
                          ),
                        ),
                        if (_sort == mode) AppIcon(AppIcons.check, size: 16, color: AppColors.primary),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _setSort(picked);
  }

  /// ⑥ 计数行 = 本页**唯一顶级分区标题行**（32dp；左 = 真实总数）
  ///
  /// 行内左侧加 **4×16 品牌短标**，行下 8dp 加 **标尺线** —— 这就是"区块标题"的全部装饰，
  /// **短标数 = 顶级分区数 = 1**（AI 引导与入口卡是第二层内容，**不配短标**）。
  Widget _countRow() {
    final text = _loading
        ? '正在加载…'
        : _error != null
            ? '共 — 位陪玩'
            : '共 $_total 位陪玩';
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: AppDecoSpacing.pageEdge),
      // 同上：计数行属于页面底，透明才与渐变连续
      color: Colors.transparent,
      child: Row(
        children: [
          const AppBrandBar(),
          const SizedBox(width: AppDecoSpacing.tickToTitle),
          Expanded(
            child: Text(
              text,
              key: const Key('players-count-row'),
              style: TextStyle(fontSize: 11, color: T.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// 页级 / 页底标尺线：端点配置**由基准线给出**，调用处不许手挑端点。
  Widget _baselineRule(double y) => AppRuleLine(dots: AppBaseline.ruleDotsForBaseline(y));

  /// 区块标题下方的标尺线（线到标题 8dp、左右端点齐备 = "上一块到此为止"）。
  Widget _sectionRule() => const Padding(
        padding: EdgeInsets.fromLTRB(
          AppDecoSpacing.pageEdge,
          AppDecoSpacing.ruleToContent,
          AppDecoSpacing.pageEdge,
          0,
        ),
        child: AppRuleLine(dots: AppRuleLineDots.both),
      );

  /// 空态 / 错误态的**品牌化外壳**（5% 细网格打底 + 标尺线收口，**不靠插画、不靠 emoji**）。
  Widget _emptyDeco(Widget child) => AppFineGrid(
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              child,
              const SizedBox(height: AppDecoSpacing.ruleToContent),
              const AppRuleLine(dots: AppRuleLineDots.both, width: AppEmptyDeco.defaultRuleWidth),
            ],
          ),
        ),
      );

  List<Widget> _listChildren() {
    if (_loading) {
      return [for (var i = 0; i < 5; i++) _skeletonCard(i)];
    }
    if (_error != null) {
      return [
        const SizedBox(height: 32),
        _emptyDeco(
          AppEmpty(icon: AppIcon.info, text: '加载失败：$_error', action: '重试', onAction: _loadPlayers),
        ),
        const SizedBox(height: 32),
      ];
    }
    if (_players.isEmpty) {
      // 空态：说清"为什么空" + 给下一步动作（`docs/21` §五）；
      // **不给「切换分部」** —— 线上只有 1 个分部，那会是个死入口（结构规则 2）。
      final name = _currentDivisionName();
      return [
        const SizedBox(height: 32),
        _emptyDeco(
          AppEmpty(
            icon: AppIcon.empty,
            text: name.isEmpty ? '还没有陪玩' : '$name分部还没有陪玩',
            action: '重试',
            onAction: () => _loadPlayers(force: true),
          ),
        ),
        const SizedBox(height: 32),
      ];
    }
    return [
      for (final p in _sortedPlayers) _playerCard(p),
      _listFooter(),
      // ② 页底信号线**贴 B4**（844 − 页底 56）：带左端点方块 = "这一页到此结束"。
      _baselineRule(AppBaseline.b4),
    ];
  }

  String _currentDivisionName() {
    for (final d in _divisions) {
      if (d.id == _divisionId) return d.shortName;
    }
    return '';
  }


  Widget _listFooter() => Container(
        key: const Key('players-list-footer'),
        height: 48,
        alignment: Alignment.center,
        // 列表页脚同属页面底（不是卡片）：透明才与渐变连续
        color: Colors.transparent,
        child: Text(
          '共 $_total 位陪玩 · 已到底',
          style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder),
        ),
      );

  /// 骨架卡：**与真卡逐块等高同宽**（行高 128 / 方头像 96 / 名字 / 胶囊 / 介绍 2 行 / 元信息）
  ///
  /// 条宽刻意不等长 —— 等长方块是「机器味」信号（`docs/21` §二）。
  /// 每块用 `AppSkeletonBlock`（真内容那一档圆角）+ `animate: false`（静态灰块：
  /// 本页既有 5 套渲染用例走 `pumpAndSettle`，无限动画会把它们挂死）。
  ///
  /// 金额位那一条（`width: 96, height: 16`）随真卡金额行一起删除（2026-10-18），
  /// 剩下的五块与真卡现在的五行一一对应：名字 / 胶囊 / 介绍两行 / 元信息。
  Widget _skeletonCard(int i) {
    const nameWidths = [72.0, 56.0, 88.0, 64.0, 80.0];
    const tagWidths = [88.0, 64.0, 72.0, 56.0, 80.0];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        key: Key('players-skeleton-$i'),
        height: PlayersPage.cardHeight,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(AppDecoRadius.card),
          border: Border.all(color: AppColors.strokeSoft, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头像位：真块是**方角圆角**块 → 骨架也必须是方角圆角，否则加载完会"方变圆"
            Container(
              width: PlayersPage.avatarMax,
              height: PlayersPage.avatarMax,
              decoration: BoxDecoration(
                color: AppSkeletonBlock.baseColor,
                borderRadius: BorderRadius.circular(AppDecoRadius.card),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 18,
                    child: AppSkeletonBlock(width: nameWidths[i % nameWidths.length], height: 16, animate: false),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 18,
                    child: AppSkeletonBlock(width: tagWidths[i % tagWidths.length], height: 18, animate: false),
                  ),
                  const SizedBox(height: 4),
                  AppSkeletonBlock(width: double.infinity, height: 12, animate: false),
                  const SizedBox(height: 8),
                  AppSkeletonBlock(width: 120, height: 12, animate: false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 陪玩卡（参考图 1 的 `.pcard`）：**行高恒定 [PlayersPage.cardHeight]**
  ///
  /// ```
  /// 左：**大方形圆角头像**（约卡宽 29%，封顶 96）
  /// 右：名字行 20 → 4 → 黑色实底分部胶囊 20 → 4 → 介绍 2 行 34
  ///      → 4 → 元信息 16
  /// ────────────────────────────────────────────────
  /// 卡内合计 102（可用 104）；卡高由常量 128 锁定
  /// ```
  ///
  /// **带介绍 / 不带介绍完全一样高**：介绍为空时渲染弱化占位「介绍待补充」（`#8A99AB`），
  /// **不隐藏节点**（线上 13/14 人介绍为空）。
  Widget _playerCard(_Player p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: GestureDetector(
        key: Key('player-card-${p.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _openWorkerProfile(p),
        child: Container(
          height: PlayersPage.cardHeight,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: T.bgCardSolid,
            borderRadius: BorderRadius.circular(AppDecoRadius.card),
            border: Border.all(color: AppColors.strokeSoft, width: 1),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(constraints.maxWidth * 0.40, PlayersPage.avatarMax);
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _avatarBlock(p, side),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 名字行（名字可缩 + 8dp + L-SLOT 等级徽章，同行垂直居中）
                        SizedBox(
                          height: 20,
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.textPrimary, height: 1.2),
                                ),
                              ),
                              _LevelSlot(name: p.name, grade: p.grade, gradeName: p.gradeName),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        // 介绍位（**固定两行 34dp**；空 → 弱化占位，节点不消失）
                        SizedBox(
                          height: PlayersPage.introBoxHeight,
                          child: Text(
                            p.intro.isNotEmpty ? p.intro : kIntroPlaceholder,
                            key: p.intro.isNotEmpty ? null : Key('player-intro-placeholder-${p.id}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: p.intro.isNotEmpty ? T.textSecondary : AppColors.textPlaceholder,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        // 元信息行（接单次数 · 好评率；字段缺失 → 各自降级，绝不显示 0 / 100%）
                        // 注：金额行（`¥--` + 「待接入」）已按负责人真机圈图整块删除（2026-10-18）
                        //
                        // 2026-10-18「颜色单调」：好评率按**口碑色阶**上色（数字即视觉）：
                        // ≥98% 绿 / 95–98% 蓝 / <95% 橙 / 暂无评价 灰。只给好评率上色，
                        // 接单次数保持中性 —— 一行元信息只允许一处强调。
                        SizedBox(
                          height: 16,
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: _metaOrdersText(p)),
                                const TextSpan(text: ' · '),
                                TextSpan(
                                  text: satisfiedRateText(
                                    p.satisfiedRate,
                                    reviewCount: p.reviewCount,
                                  ),
                                  style: TextStyle(
                                    color: _rateColor(p),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            key: Key('player-meta-${p.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1,
                              color: AppColors.textPlaceholder,
                              // 数字一律等宽（`docs/45 §二④` 的 tabular-nums）
                              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                    const SizedBox(width: 10),
                    _selectButton(p),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 大方形圆角头像（参考图 1 的左栏）
  ///
  /// 为什么不用 `AppAvatar(square: true)`：它的方角半径是 `size * 0.34`（132 → 45），
  /// 在 132 的方块上会变成"近似圆形"，与参考图的**小圆角方形**不是一回事；
  /// 而本项目圆角只允许 0/4/6/10/14/胶囊 → 这里用卡片档 14 自己裁。
  ///
  /// 头像为 null（线上全部）→ **字标兜底**：品类色 12% 浅底 + 同色首字，**零渐变**
  /// （`docs/21`：渐变不做主视觉）。
  /// 「选 TA」方形按钮（负责人 2026-10-18 重设计）
  ///
  /// 为什么独立成按钮而不是"点整张卡"：卡片的点击热区太模糊（改前整卡可点，
  /// 但用户不知道点哪儿会怎样）。独立按钮把"进详情"和"选这个人下单"分开：
  /// **按钮 = 明确的下一步**，卡片其它区域仍是进主页。
  ///
  /// 颜色：主色实底（品牌蓝）。**不再跟分部主题色**——分部只有一个时
  /// 那颜色等于没有信息量，反而和其它页面（首页/订单/我的）的蓝断掉。
  /// 无等级 / 未上架等不可选状态 → 灰底 + 文案「离线」，禁用。
  Widget _selectButton(_Player p) {
    final enabled = p.grade != null && (p.grade ?? 0) > 0;
    return GestureDetector(
      key: Key('player-select-${p.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => _openWorkerProfile(p) : null,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: enabled ? AppColors.primary : const Color(0xFFC7D0DC),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppIcon(AppIcons.arrowRight, size: 15, color: Colors.white),
            const SizedBox(height: 1),
            Text(
              enabled ? '选 TA' : '离线',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatarBlock(_Player p, double side) {
    return GestureDetector(
      key: Key('player-avatar-${p.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _openWorkerProfile(p),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppDecoRadius.card),
        child: SizedBox(
          width: side,
          height: side,
          child: (p.avatarMediaId == null || p.avatarMediaId!.isEmpty)
              ? Container(
                  color: p.color.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Text(
                    p.name.isNotEmpty ? p.name.characters.first : '?',
                    style: TextStyle(fontSize: side * 0.36, fontWeight: FontWeight.w700, color: p.color),
                  ),
                )
              : AppAvatar(
                  nickname: p.name,
                  mediaId: p.avatarMediaId,
                  size: side,
                  square: true,
                  color: p.color,
                ),
        ),
      ),
    );
  }


  /// 元信息行文案：「接单 30 次 · 98.2%」
  ///
  /// - 接单次数缺失 → 整段退到「暂无接单记录」；有值（含 0）→ 「接单 N 次」
  ///   （0 是**真实值**：这位打手确实还没接过单，不是"没有数据"）；
  /// - 好评率**只走** `satisfiedRateText()`（唯一出口）：`null` 或 `reviewCount<=0` → 「暂无评价」。
  /// 接单次数文案（元信息行左半段；与好评率分开是为了给它单独上色）
  String _metaOrdersText(_Player p) =>
      p.completedOrders == null ? '暂无接单记录' : '接单 ${countText(p.completedOrders)} 次';

  /// 好评率口碑色阶（≥98 绿 / 95–98 蓝 / <95 橙 / 无评价 灰）
  ///
  /// 为什么用颜色而不只是数字：用户在列表里是**扫**不是**读**，
  /// 98.6% 和 91% 在灰字里几乎同形；上色后一眼分出"口碑好"和"口碑一般"。
  /// 解析失败（无评价 / 非数字）→ 灰，**绝不猜一个颜色**。
  Color _rateColor(_Player p) {
    final text = satisfiedRateText(p.satisfiedRate, reviewCount: p.reviewCount);
    final v = double.tryParse(text.replaceAll('%', '').trim());
    if (v == null) return AppColors.textPlaceholder;
    if (v >= 98) return const Color(0xFF0E7A5F);
    if (v >= 95) return const Color(0xFF1E4FA8);
    return const Color(0xFFB45309);
  }

}

/// "后端没有字段"的统一占位文案 —— **全站唯一一处**「待接入」的字面量出处
///
/// 本页自己现在一个「待接入」位都不画了（金额位与「明星大神」入口卡都在 2026-10-18 删掉），
/// 但它仍是这句文案的**唯一定义点**：打手主页与后续新字段都引它；
/// `worker_profile_page_test.dart` 的源码级断言也钉在这条常量上
/// （口径是「后端没有的字段必须是这句占位，不许填假数字」）—— 删掉它会连锁断两处。
const String kFieldPendingText = '待接入';

/// 分页小圆点（参考图 1 的 `.dots`）—— 只在真实分页 > 1 时出现
class _PagerDots extends StatelessWidget {
  const _PagerDots({required this.count, required this.index});

  final int count;
  final int index;

  /// 圆点直径 6 / 间距 4（4dp 网格）
  static const double dotSize = 6;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: i == index ? AppColors.primary : AppColors.hairline,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      );
}

/// 黑色实底小胶囊（参考图 1 的"角色胶囊"位；这里承载**分部**这唯一真实归属字段）
///
/// 形状语言不变（`docs/45 §二⑤`：高 20 → **右上 6×6**），只把底色从"主色浅底"换成
/// `AppColors.chipInk`（`#111827`，全站唯一允许的近黑底，只用于**小面积胶囊**）——
/// 于是参考图的"黑色实底胶囊"与我们的"分部归属"合成同一个东西，不新增任何假字段。
class PlayerCapsule extends StatelessWidget {
  const PlayerCapsule({super.key, required this.label});

  final String label;

  /// 该胶囊的切口档位（分区/归属标签：高 20 → 右上 6×6）
  static const AppNotchCorner notchCorner = AppNotchCorner.topRight;

  /// 胶囊高 20（= 斜切角谱系里"高 20–24 → 6×6"的下一档）
  static const double capsuleHeight = 20;

  @override
  Widget build(BuildContext context) {
    return AppNotched(
      height: capsuleHeight,
      corner: notchCorner,
      // 盖角方块 = 卡片白底（不是胶囊自己的底）：这样右上角才像"被切掉"而不是多一个补丁
      baseColor: T.bgCardSolid,
      borderColor: AppColors.chipInk,
      child: Container(
        height: capsuleHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.chipInk,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(AppIcons.players, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// **等级位 L-SLOT**（负责人 2026-10-15：等级名称与形态待定 → **只锁几何**）
///
/// 规格：**高 20 × 最长 72 · 名字行内 · 距名字 8dp · 同行垂直居中**。
/// 参考图（负责人 2026-10-17）里等级徽章是**可见的一枚小牌子**。
///
/// ## 2026-10-17 起：真等级已上线，这里画**真徽章**
/// 服务端 `/public/players` 每项已带 `grade`(1–5) / `gradeLabel` / `gradeName` →
/// 名字右侧 = **16dp 徽章 + `gradeName` 文字 11px**（如「扬名」；徽章本身就是图标，
/// 文字旁边**不再加任何符号**），图标与墨色走 core 的唯一出口 `WorkerGradeBadge`
/// （1–2 弱色 / 3 深金 / 4–5 深金 `goldText`，11px 小字必须 AA 达标）。
///
/// **列表极简**：只放等级，**不放五维**（五维与进度只在详情页/打手态「我的」）。
///
/// ## 缺数据时（服务端没下发 `grade`）
/// 保持原样：**灰底 `--` 占位**，几何仍是 L-SLOT 的 72×20 —— 既不凭空编等级，
/// 也不让行高随数据有无而塌陷（列表行高恒定是硬约束）。节点与 Key 不变。
class _LevelSlot extends StatelessWidget {
  const _LevelSlot({required this.name, this.grade, this.gradeName = ''});

  final String name;

  /// 1–5；`null` = 服务端没下发等级 → 走 `--` 占位
  final int? grade;

  /// 服务端下发的等级名（`初出/立足/扬名/称雄/宗师`）；客户端**不写死**
  final String gradeName;

  @override
  Widget build(BuildContext context) {
    final g = grade;
    // 距名字 8dp（4dp 网格）；有等级 → 徽章 + 名字，无等级 → 原 `--` 占位
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        key: Key('level-slot-$name'),
        height: PlayersPage.levelSlotHeight,
        width: g == null ? PlayersPage.levelSlotMaxWidth : null,
        child: g == null
            ? Container(
                height: PlayersPage.levelSlotHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.statusMutedSoft,
                  borderRadius: BorderRadius.circular(AppDecoRadius.tag),
                ),
                child: Text('--',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textPlaceholder)),
              )
            : Center(
                child: WorkerGradeBadge(grade: g, size: 16, label: gradeName, labelSize: 11),
              ),
      ),
    );
  }
}

class _Division {
  _Division({required this.id, required this.name, required this.shortName, this.iconMediaId});

  final String id;
  final String name;

  /// 短名（如「和平精英」）—— 空态文案用；缺失时退到 [name]
  final String shortName;

  /// 分部图标 mediaId（负责人 2026-10-18：胶囊里放游戏图标；/divisions 已下发 iconMediaId）
  /// 缺失 → 退到通用图标，不空白
  final String? iconMediaId;

  factory _Division.fromJson(Map json) {
    final name = (json['name'] as String?)?.trim() ?? '';
    final short = (json['shortName'] as String?)?.trim() ?? '';
    final icon = (json['iconMediaId'] as String?)?.trim() ?? '';
    return _Division(
      id: '${json['id']}',
      name: name,
      shortName: short.isEmpty ? name : short,
      iconMediaId: icon.isEmpty ? null : icon,
    );
  }
}

/// 卡片用的一行数据（`/public/players`）
///
/// **新字段一律按可空解析**：缺失就是 `null` → 那一项**不显示**，
/// 最低降到「头像 + 名字 + 介绍」，**不崩、不显示 0、不显示 100%**。
class _Player {
  _Player({
    required this.id,
    required this.name,
    required this.intro,
    required this.avatarMediaId,
    required this.color,
    required this.completedOrders,
    required this.reviewCount,
    required this.satisfiedRate,
    required this.divisionName,
    required this.grade,
    required this.gradeLabel,
    required this.gradeName,
  });

  final String id;
  final String name;

  /// 介绍（**打手自写 / 官方兜底**；客户端只读展示）
  final String intro;
  final String? avatarMediaId;
  final Color color;

  /// 接单次数（`worker_stats.completed_orders` 生效值）—— 可空
  final int? completedOrders;

  /// 评价数 —— 可空
  final int? reviewCount;

  /// 好评率原值（**原样收**，怎么显示由 `satisfiedRateText()` 一处说了算）—— 可空
  final Object? satisfiedRate;

  /// 分部副标（`divisionName`）—— 可空
  final String? divisionName;

  /// 打手等级 `worker_grade.grade`（1–5）—— 可空：服务端没下发 → 等级位回到 `--` 占位
  ///
  /// 服务端口径：`/public/players` 每项带 `grade / gradeLabel / gradeName`，
  /// 来源 `WorkerGradeService.batchGrades()`（整页一条 SQL，无 N+1）。
  final int? grade;

  /// 服务端下发的 `LV1`–`LV5` 标签（列表**不展示**，详情/我的才用；这里原样收着）
  final String gradeLabel;

  /// 服务端下发的等级名（初出/立足/扬名/称雄/宗师）—— 列表徽章直接展示它
  final String gradeName;

  /// 黑色实底胶囊那一排（**最多 3 枚**，硬上限在这一处收口）
  ///
  /// 目前只可能有**一枚真实数据**：分部副标 `divisionName`。
  /// 打手标签体系（`worker_tag`）/ 角色（常规对局·航天）尚未建表，**不预置任何假标签**。
  List<String> get capsules => [
        if (divisionName != null && divisionName!.trim().isNotEmpty) divisionName!.trim(),
      ].take(3).toList();

  factory _Player.fromJson(Map json) {
    final id = '${json['workerId'] ?? json['id'] ?? ''}';
    final seed = id.isNotEmpty ? id.codeUnits.fold<int>(0, (a, b) => a + b) : 0;
    return _Player(
      id: id,
      name: (json['nickname'] as String?)?.trim().isNotEmpty == true ? json['nickname'] as String : '陪玩',
      intro: (json['intro'] as String?)?.trim() ?? '',
      avatarMediaId: json['avatarMediaId'] == null ? null : '${json['avatarMediaId']}',
      // 字标底色沿用分部/品类色循环（浅底档由页面自己算，不传渐变）
      color: AppColors.categoryColors[seed % AppColors.categoryColors.length],
      completedOrders: _intOf(json['completedOrders']),
      reviewCount: _intOf(json['reviewCount']),
      satisfiedRate: json['satisfiedRate'],
      divisionName: (json['divisionName'] as String?)?.trim(),
      // 等级三件套（2026-10-17 上线）：**逐项可空**，缺失就是没有 → 徽章位回到 `--`
      grade: _intOf(json['grade']),
      gradeLabel: '${json['gradeLabel'] ?? ''}'.trim(),
      gradeName: '${json['gradeName'] ?? ''}'.trim(),
    );
  }

  /// `int` / `num` / 数字串都吃，其余 → null（**不猜 0**）
  static int? _intOf(Object? raw) => _numOf(raw)?.toInt();

  static num? _numOf(Object? raw) {
    if (raw is num) return raw.isFinite ? raw : null;
    final s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    if (d == null || !d.isFinite) return null;
    return d;
  }
}
