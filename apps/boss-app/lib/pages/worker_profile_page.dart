/// 打手个人主页（二级页，**不显示底栏**）—— **版式重构 · 2026-10-17 参考图 2 + 2026-10-18 修订**
///
/// ## 依据（口径变更，先读这一段）
/// 负责人 2026-10-17 提供两张东东电竞/GM 风格参考图，明确要求照版式重构本页；
/// 并当日下指令覆盖 `CLAUDE.md` 结构规则 6 的旧禁项（原「展示极简：只名字 + 介绍，
/// 禁止评分/等级/单价/人数/标签胶囊」）。因此本页**允许**出现这些字段；
/// 相关测试里"禁止出现 X"的断言已按新口径重钉成"必须有 X"
/// （每条都在测试注释里写明依据「负责人 2026-10-17 指示照参考图重构」）。
/// **2026-10-18 再修订**：删掉当日新加的三块（礼物墙卡 / 海报两个计数 / 底部礼物按钮），
/// 能力雷达改成六轴六边形且数值允许溢出卡片边界 —— 依据见下方「负责人 2026-10-18 定案」。
///
/// **只学版式 / 信息层级 / 卡片构成，配色一律走项目 token**（蓝金体系，不抄参考图的粉紫）：
/// 主色 `AppColors.primary` · 金额/等级 `AppColors.gold`(`goldText`) · 页底 `AppColors.bgPageG`
/// · 卡白 + 1px `AppColors.strokeSoft`/`T.divider` · 圆角只用 0/4/6/10/14/胶囊。
///
/// ## 页面结构（自上而下；2026-10-18 删三块后重排）
/// ① **海报式头部**（整块铺顶的场：头像 + 名字 + 等级 + ID + 右上切口）
/// ② 标尺线（头部与内容的分界）
/// ③ **统计行**（接单次数 / 好评率 / 时长）
/// ④ **介绍卡**
/// ⑤ **游戏胶囊 + 等级徽章**
/// ⑥ **双 Tab**（个人能力 / 评价 N）
/// ⑦ **6 个圆环评分** + **六轴六边形雷达**（顶点外侧画 标签 / 数值 / 单位）
/// ⑧ **评价区**（Tab「评价 N」的真实内容）
/// ⑨ 底部固定操作条（推荐 / 联系客服 + 主按钮「找 TA 下单」）
///
/// ## 负责人 2026-10-18 定案（本轮口径，覆盖 2026-10-17 的版式清单）
/// 原话要点：礼物墙不要加，海报上那两个计数也去掉；雷达图改成参考图那样，
/// 数据可以直接溢出去的；第一个轴那几个字改成「评分」，「店内表现」改成「综合表现」。
/// - **礼物墙整卡删除**（含 `-- / --` 计数、4×3 灰格墙、墙上那句待接入说明）；
/// - **海报里的 粉丝 N / 推荐 N 两个数字删除**（头像 / 名字 / ID / 等级徽章照旧）；
/// - **底部条「礼物」按钮删除**（「推荐」是置灰待接入位，按指示原样保留）；
/// - **雷达图重画成六轴六边形**（5 圈网格 / 半透明主色填充 + 1.5px 主色描边 /
///   标签与数值画在**图外**并允许溢出卡片边界）；
/// - **轴名固定六个**：评分 / 技术水平 / 情绪价值 / 抗压能力 / 声音听感 / 综合表现
///   （第一个轴只叫「评分」；「店内表现」改名「综合表现」）。
///
/// ## 六个轴的数据来源（**全部真实字段，缺就 `--`，绝不编数字**）
/// | 轴 | 数据来源 |
/// |---|---|
/// | 评分 | 好评率 ÷ 10（`98.6%` → `9.86`；轴范围 0–10；见 [_scoreFromRate]） |
/// | 技术水平 | `rating.skill` |
/// | 情绪价值 | `rating.emotion` |
/// | 抗压能力 | `rating.stress` |
/// | 声音听感 | `rating.voice` |
/// | 综合表现 | `rating.shop`（原「店内表现」改名） |
///
/// `rating` 由 `GET /public/workers/:id` 下发（服务端 `WorkerGradeService.detail()`，
/// 形状 `{skill, emotion, stress, voice, shop, avg, samples}`）；**`samples == 0` 视为
/// 还没有人评过** → 六轴全部 `--`、只画网格不画多边形（0 分不是"差"，是没有）。
///
/// 仍待接入的两项保留原样：**时长**（统计格 `--`，唯一剩下的 `// TODO(评分体系)`）、
/// **单价**（本页不画）。
///
/// ## 等级（2026-10-17 上线，**真数据**）
/// 详情接口已带 `grade / gradeLabel / gradeName / rating / progress`（`WorkerGradeService.detail()`）：
/// - 等级位 = **24dp 徽章 + `gradeLabel gradeName`**（`WorkerGradeBadge`，core 唯一出口）；
/// - 等级下一行 = **升级进度**（`progress.remain` 的差额，`gradeRemainItems` 唯一出口）。
/// - 两者**都没有数据就整块不画**（`--` 占位 / 不出现进度行），绝不编数字。
/// - 注意：打手用「初出/立足/扬名/称雄/宗师」这套名字，**不是**老板端「会员」那套。
///
/// ## 两处唯一出口（不许在页面里另写一套）
/// - **好评率** → `satisfiedRateText()`：服务端给**百分数字符串**（`"98.2"` = 98.2%），
///   无评价 `null` → 「暂无评价」，**绝不编 100%**；`"1.0"` + 100 条 → **1%**。
/// - **接单次数** → `countText()`（千分位）。
///
/// ## 视觉纪律
/// 白底为主 · **零渐变** · **零阴影铺卡片** · 圆角只用 4/6/10/14/999 · 零 emoji ·
/// **零硬编码色值**（全走 `T.*` / `AppColors.*`）· 环图/雷达图**自己画**（`CustomPainter`，
/// 不引图表库、不用 `createShader`）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../models/review_models.dart';
import 'chat_detail_page.dart';
import 'product_list_page.dart';

/// 6 类"后端没有字段"的统一占位文案（与列表页共用一句，避免两处各写一种说法）
const String kRatingPendingText = '评分体系待接入';

/// 六个能力轴的名字（**顺序固定**：雷达从正上方起顺时针，环图 3+3 同序）
///
/// 负责人 2026-10-18：第一个轴的名字改成「评分」，最后一个轴改成「综合表现」——
/// 这里就是全部六个轴的**唯一出处**（雷达顶点、环图标签都读它，不许在别处另写一份）。
const List<String> kRatingAxes = <String>[
  '评分',
  '技术水平',
  '情绪价值',
  '抗压能力',
  '声音听感',
  '综合表现',
];

class WorkerProfilePage extends StatefulWidget {
  const WorkerProfilePage({
    super.key,
    this.api,
    required this.workerId,
    this.fallbackNickname = '',
    this.fallbackIntro = '',
    this.fallbackAvatarMediaId,
    this.fallbackDivisionName,
  });

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  /// 打手 id（来自 `/public/players` 的 `workerId`）——**海报上直接展示为 ID**（唯一真实标识）
  final String workerId;

  /// 列表已经拿到的名字/介绍/头像：详情拉回来之前先渲染（不白屏），
  /// 拉回来之后一律以服务端值为准（列表只是"先看一眼"的兜底，不是第二份真相）。
  final String fallbackNickname;
  final String fallbackIntro;
  final String? fallbackAvatarMediaId;

  /// 列表已经拿到的分部副标（`/public/players` 新增字段；可空）
  final String? fallbackDivisionName;

  /// **等级徽章 L-SLOT** 的几何尺寸（高 20 × 最长 72）
  ///
  /// 几何**取自装饰原子** `AppLevelSlot`（不在这里另写一遍数字）：与列表页共用
  /// **同一个** L-SLOT 定义，两页的等级位不可能各说各话。
  /// 这条几何只在**没有等级数据**时用（`--` 占位）；有等级时换 [gradeBadgeSize] 的真徽章位。
  static const double levelSlotHeight = AppLevelSlot.slotHeight;
  static const double levelSlotMaxWidth = AppLevelSlot.slotMaxWidth;

  /// 真等级徽章的边长（2026-10-17 等级上线）：主页/打手态「我的」用 24dp，列表卡用 16dp
  static const double gradeBadgeSize = 24;

  /// 海报式头部高度（含 96 头像 + 名字块 + ID 行；2026-10-18 删掉 粉丝/推荐 行后场高不变）
  static const double headerHeight = 176;

  /// 头部字标头像直径 + 外圈标尺环直径
  static const double avatarSize = 80;
  static const double avatarRingSize = 96;

  /// 底部固定操作条高度
  static const double bottomBarHeight = 72;

  /// 整页滚动区（顶栏 + 海报 + 内容**同一根滚动轴**：负责人 2026-10-18「上方那一块要跟着滑动」）
  ///
  /// 断言走这个 key 拿 `Scrollable`（页面里只有一个滚动区 → 滚动/回弹的唯一入口）
  static const Key scrollKey = Key('worker-profile-scroll');

  /// 内容区页边与段距（页边 16 / 上 20 / 页底 32）—— 与重构前 `ListView` 的内距**逐值相同**
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(16, 20, 16, 32);

  /// 六个圆环的直径（参考图 2 的 6 个评分环）
  static const double ringSize = 48;

  // ---- 六轴六边形雷达（负责人 2026-10-18：数值允许溢出卡片边界）----

  /// 轴数（固定 6：见 [kRatingAxes]）
  static const int radarAxes = 6;

  /// 同心六边形网格的圈数（**5 圈**，细线弱色；不画满 10 圈）
  static const int radarRings = 5;

  /// 雷达画布边长（**只框六边形本体**：轴标签、数值、单位一律画在外侧，见 [radarBlockHeight]）
  static const double radarChartSize = 160;

  /// 雷达块高 = 画布 160 + **上下各 62** 的顶点外标签位
  ///
  /// 上下左右留白都 ≥44dp（左右 = 卡片内容宽 −160 再除 2，402 宽视口下是 89dp），
  /// 数值往卡片描边外溢时有地方可去。
  static const double radarBlockHeight = 284;

  /// 轴标签组宽（超宽部分由 `Stack` 的 `Clip.none` 兜住，卡片不裁）
  static const double radarLabelWidth = 64;

  /// 轴标签组高（11px 标签 + 4 + 18px 数值一行）
  static const double radarLabelHeight = 52;

  /// 数据多边形的填充透明度（半透明主色；描边恒为实色主色 1.5px）
  static const double radarFillAlpha = 0.16;

  @override
  State<WorkerProfilePage> createState() => _WorkerProfilePageState();
}

class _WorkerProfilePageState extends State<WorkerProfilePage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  /// 首次进入 / 换行头时拉取的每页评价条数（与"查看更多"用同一个 pageSize）
  static const int _pageSize = 10;

  bool _loading = true;
  bool _failed = false;
  _WorkerProfile? _profile;

  /// 已展示的评价（初始 = 详情接口下发的「最近评价」）
  List<WorkerReview> _reviews = const [];

  /// 服务端给的评价总数（决定还有没有下一页）
  int _reviewTotal = 0;
  int _page = 1;
  bool _moreLoading = false;

  /// 双 Tab 的当前项（0 = 个人能力，1 = 评价）—— 点击会把对应区块滚到顶部
  int _tabIndex = 0;

  /// 滚动锚点（Tab 点击 → `Scrollable.ensureVisible`，不做假的"点了没反应"）
  final GlobalKey _abilityKey = GlobalKey();
  final GlobalKey _reviewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      // forceRefresh：好评率/评价条数随时会变（刚打完分就该看到），
      // 详情属于低频页，一次回源换"不给用户看旧分数"是划算的。
      final resp = await _api.request(
        'GET',
        '/public/workers/${widget.workerId}',
        forceRefresh: true,
      );
      if (!mounted) return;
      final p = _WorkerProfile.fromJson((resp['data'] as Map?) ?? const <String, dynamic>{});
      setState(() {
        _profile = p;
        _reviews = p.reviews;
        // reviewCount 缺失时退一步用"本次拿到的条数"，保证"查看更多"的判定不会瞎猜
        _reviewTotal = p.reviewCount ?? p.reviews.length;
        _page = 1;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// 还有下一页：服务端总数 > 已展示条数
  bool get _hasMore => _reviewTotal > _reviews.length;

  /// 查看更多评价（`GET /public/workers/:id/reviews?page&pageSize`）
  ///
  /// 去重：详情接口的「最近评价」很可能与本页第一页重叠 → 用 `dedupeKey`
  /// 丢重复行，宁可少显示一条，也不让同一条评价在列表里出现两次。
  Future<void> _loadMore() async {
    if (_moreLoading || !_hasMore) return;
    setState(() => _moreLoading = true);
    try {
      final resp = await _api.request(
        'GET',
        '/public/workers/${widget.workerId}/reviews',
        queryParameters: {'page': _page + 1, 'pageSize': _pageSize},
        forceRefresh: true,
      );
      final data = (resp['data'] as Map?) ?? const <String, dynamic>{};
      final fresh = ((data['list'] as List?) ?? const [])
          .map(WorkerReview.fromJson)
          .whereType<WorkerReview>()
          .toList();
      if (!mounted) return;
      final seen = _reviews.map((r) => r.dedupeKey).toSet();
      setState(() {
        _reviews = [..._reviews, ...fresh.where((r) => seen.add(r.dedupeKey))];
        final total = int.tryParse('${data['total'] ?? ''}');
        if (total != null) _reviewTotal = total;
        _page += 1;
        _moreLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 拿不到更多就保持现状（已经有"最近评价"在屏幕上），不弹错、不白屏
      setState(() => _moreLoading = false);
    }
  }

  /// 去下单：跳既有下单链路（该分部的商品列表 → 商品 → 下单页可"指定护航员"）
  Future<void> _openOrderFlow() {
    final divisionId = _profile?.divisionId;
    return Navigator.of(context).push(
      AppMotionRoute<void>(
        builder: (_) => ProductListPage(api: widget.api, initialDivisionId: divisionId),
      ),
    );
  }

  /// 联系客服：获取（自动创建）客服会话 → 进入聊天详情
  ///
  /// 与「我的 › 联系客服」「商品详情 › 客服」**同一条真实入口**（`GET /user/conversation`），
  /// 不新造第二个客服通道。
  Future<void> _openCsChat() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      AppToast.info(context, '登录后可以联系客服');
      return;
    }
    try {
      final resp = await _api.request('GET', '/user/conversation', token: token);
      final convId = '${resp['data']?['id'] ?? ''}';
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatDetailPage(
            conversationId: convId,
            title: '联系客服',
            csConversation: true,
            peerNickname: '祁连山客服',
          ),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    }
  }

  /// Tab 点击：把对应区块滚到顶部（真滚动，不是死控件）
  Future<void> _jumpTo(GlobalKey key, int index) async {
    if (_tabIndex != index) setState(() => _tabIndex = index);
    final ctx = key.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 240), alignment: 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    final nickname = (p != null && p.nickname.isNotEmpty) ? p.nickname : widget.fallbackNickname;
    final intro = (p != null && p.intro.isNotEmpty) ? p.intro : widget.fallbackIntro;
    final avatarMediaId = p?.avatarMediaId ?? widget.fallbackAvatarMediaId;
    final divisionName = (p?.divisionName?.isNotEmpty == true) ? p!.divisionName : widget.fallbackDivisionName;

    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 海报头部、信息卡、底部操作条一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      // **二级页**：没有 bottomNavigationBar（底栏不显示，整屏交给这一页）
      body: AppPageBg(child: Column(
        children: [
          /**
           * 【负责人 2026-10-18 真机】「上方那一块要跟着用户滑动而动，不要在那停着不动」
           *
           * 顶栏从**固定**（原来挂在 `Column` 第一格、与滚动区并列）改成**滚动区里的第一段**：
           * `SliverPersistentHeader(pinned: false, floating: true)` —— 下滑时它随内容一起滚走，
           * **上滑时自己滑回来**，所以滚到页面深处也永远有返回入口（滚走后无返回路径是这条的否决项）。
           *
           * 为什么不用 `SliverAppBar`：`AppPageHeader` 是二级页页头的唯一实现
           * （白底 + 56 高 + 发丝线 + 20/800 标题 + 返回），套 `SliverAppBar` 等于把同一套页头
           * 再写第二份 —— 这里用 `SliverPersistentHeader` 原样装它，页头只有一份实现。
           *
           * `extent` = 状态栏内距 + 57（56 内容 + 1 发丝线，与 `AppPageHeader` 逐值同源）：
           * 高度必须给死（sliver 协议），所以由 [WorkerProfilePage.headerExtent] 一处推导。
           */
          Expanded(
            child: CustomScrollView(
              key: WorkerProfilePage.scrollKey,
              slivers: [
                SliverPersistentHeader(
                  pinned: false,
                  floating: true,
                  delegate: _ScrollingPageHeader(
                    extent: headerExtent(context),
                    child: const AppPageHeader(title: '打手信息'),
                  ),
                ),
                // ① 海报式头部（整块铺顶的场）—— 本来就跟内容走，现在与顶栏同一根滚动轴
                SliverToBoxAdapter(child: _poster(nickname, avatarMediaId)),
                SliverToBoxAdapter(child: _ruler()),
                SliverPadding(
                  padding: WorkerProfilePage.contentPadding,
                  sliver: SliverList(delegate: SliverChildListDelegate(_contentItems(p, intro, divisionName))),
                ),
              ],
            ),
          ),
          // **底部操作条不随滚动**（推荐 / 联系客服 / 找 TA 下单 = 操作区，钉在页底）
          _bottomBar(),
        ],
      )),
    );
  }

  /// 页头 sliver 的固定高度 = 状态栏内距（`AppPageHeader` 内部 `SafeArea` 消耗的那段）+ 57。
  ///
  /// 57 = 页头内容 56 + 底部发丝线 1，与 `AppPageHeader` 的实现逐值同源：
  /// sliver 协议要求 `minExtent == maxExtent` 且必须给死数字，页头自己拿不到这个数。
  static double headerExtent(BuildContext context) =>
      MediaQuery.paddingOf(context).top + AppPageHeader.barHeight;

  // -------------------------------------------------------------------------
  // ① 海报式头部（参考图 2 的一整张大图铺顶 → 我们落到"场 + 尺度 + 锚 + 切口"）
  // -------------------------------------------------------------------------

  /// 海报场 176dp：① 场（冷灰蓝 + 1px×8dp 细网格）② 尺度（头像 80 / 名字 22/800）
  /// ③ 锚（墨蓝字标头像）④ 装饰（右上切口）⑤ 秩序（4dp 网格）
  ///
  /// ## 三个装饰**全部走 `deco.dart` 的原子**
  /// | 原子 | 为什么 |
  /// |---|---|
  /// | [`AppFineGrid`] | 网格的间距 8 / 透明度 5% / 线宽 1px 三项从此只有一份定义 |
  /// | [`AppNotch`] | 手写三角是**第 4 种切口尺寸**，与谱系"只取 4/6/8、由高度推导"冲突 |
  /// | [`AppRuleLine`] | 端点 3×3 与"左端点品牌色 / 右端点描边灰"的分工只有一份定义 |
  Widget _poster(String nickname, String? avatarMediaId) {
    // 打手自定义的主页背景（负责人 2026-10-18）：有就铺图，没有就用原来的场 + 网格。
    // 铺图时必须压一层深色遮罩 —— 名字/ID 是深墨字，直接压在图上看不清。
    final cover = _profile?.backgroundMediaId;
    final hasCover = cover != null && cover.isNotEmpty;
    return Container(
      key: const Key('worker-profile-header-field'),
      height: WorkerProfilePage.headerHeight,
      color: AppColors.fieldBg,
      child: Stack(
        children: [
          // ① 场：有自定义背景 → 铺图 + 遮罩；否则 1px × 8dp 细网格（硬边纹理，不是渐变）
          if (hasCover)
            Positioned.fill(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // ⚠️ 路径必须带 `/media/public/` 前缀：`resolveMediaUrl` 只负责拼 host，
                  // 它期望入参是**完整路径**（2026-10-18 踩过：只传 mediaId "295" 会拼成
                  // `http://host295` → 整张图 404 → 只剩遮罩，真机表现"一坨灰"）。
                  // 另：公开媒体**不带 `/api/v1`**（`setGlobalPrefix` 排除了 `media/public/*`）。
                  Image.network(
                    AppConfig.resolveMediaUrl('/media/public/$cover'),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  // 遮罩：只要够压住文字就行，**不能把图糊成一片**。
                  // 旧值 0x1A→0x8C（底部 55% 深蓝）太重 → 图看不清；现在 6% → 38%。
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x0F0F2440), Color(0x610F2440)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            const Positioned.fill(child: IgnorePointer(child: AppFineGrid())),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              // 2026-10-18 删掉 粉丝/推荐 那一行后，场内只剩「96 头像 + 名字块 + ID」，
              // 垂直居中免得下半场空出一截像是没做完（场高 176 被三处断言钉住，不动）
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    _avatarRing(nickname, avatarMediaId),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // 名字行：名字 22/800（Display 档，本页最大的字）+ 8dp + 等级徽章
                          _nameRow(nickname),
                          const SizedBox(height: 8),
                          // ID 行（唯一真实标识）
                          _idRow(),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // ④ 装饰：右上切口（底色盖角 + 只画两条边，**不做路径真裁**）
          Positioned(
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: AppNotch(
                height: WorkerProfilePage.headerHeight,
                corner: AppNotchCorner.topRight,
                // 盖角方块 = 场**底下那层**的颜色（页底浅灰）：切口才像"被切掉"，
                // 取白会在场与页底之间夹一个更亮的方块
                baseColor: AppColors.bgPageG,
                borderColor: AppColors.hairline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 80dp 字标头像 + 96dp 外圈刻度环
  ///
  /// **不用品牌渐变做底**（渐变做主视觉是 `docs/21` 的禁项，且线上 14 人头像全为 null →
  /// 这一屏永远走兜底）。墨蓝实底 + 白字（品牌锚 `#0F2440` 的极小面积用法，占壳 ≤1.5%）。
  Widget _avatarRing(String nickname, String? avatarMediaId) {
    return SizedBox(
      width: WorkerProfilePage.avatarRingSize,
      height: WorkerProfilePage.avatarRingSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 外圈 1px 环（主色浅底档，不发光、不旋转、无粒子）
          Container(
            width: WorkerProfilePage.avatarRingSize,
            height: WorkerProfilePage.avatarRingSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.primarySoft, width: 1),
            ),
          ),
          // 4 枚 6×1dp 刻度（上 / 下 / 左 / 右），替掉参考图的旋转光效环
          const Positioned(top: 0, child: _Tick(vertical: true)),
          const Positioned(bottom: 0, child: _Tick(vertical: true)),
          const Positioned(left: 0, child: _Tick(vertical: false)),
          const Positioned(right: 0, child: _Tick(vertical: false)),
          // ③ 锚：**墨蓝实底 + 白字**（零渐变）
          AppAvatar(
            key: const Key('worker-profile-avatar'),
            nickname: nickname.isEmpty ? '打手' : nickname,
            mediaId: avatarMediaId,
            size: WorkerProfilePage.avatarSize,
            color: AppColors.brandInk,
            // 支持动图（负责人 2026-10-18）：大尺寸头像值得付出不走缓存的代价
            allowAnimation: true,
          ),
        ],
      ),
    );
  }

  /// 名字行：22/800 名字 + **8dp** + **等级徽章（有等级 → 24dp 徽章 + `LV3 扬名`；无 → `--` 占位）**
  Widget _nameRow(String nickname) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          // 名字可缩（单行省略），**绝不挤压**等级徽章
          Flexible(
            child: Text(
              nickname.isEmpty ? '打手' : nickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: T.textPrimary),
            ),
          ),
          _levelSlot(),
        ],
      ),
    );
  }

  /// **等级徽章**：有等级 → **24dp 徽章 + `LV3 扬名`**；没等级 → 原 L-SLOT `--` 占位
  ///
  /// ## 2026-10-17 起：真等级已上线
  /// 服务端详情（`GET /public/workers/:id`）带 `grade / gradeLabel / gradeName`，
  /// 与打手态 `GET /worker/grade` **同一形状**（同一 `WorkerGradeService.detail()`）。
  /// 因此这里画的是**真徽章 + 真等级名**，图标/墨色走 core 唯一出口 `WorkerGradeBadge`
  /// （1 circle-dot / 2 star / 3 award / 4 trophy / 5 diamond；1–2 弱色 / 3 深金 / 4–5 金）。
  /// 打手用「初出/立足/扬名/称雄/宗师」这套名字，**不是**老板端「会员」那套。
  ///
  /// ## 缺数据时（`grade == null`，例如接口挂了 / 老版本服务端）
  /// **保持改造前的样子**：L-SLOT 几何 72×20 + 灰底 `--`，节点 Key 不变 ——
  /// 「版式不塌、也不编等级名」；几何常量仍由 `AppLevelSlot` 一处给出。
  Widget _levelSlot() {
    final g = _profile?.grade;
    if (g == null) {
      return const Padding(
        padding: EdgeInsets.only(left: 8),
        child: SizedBox(
          key: Key('worker-profile-level-slot'),
          height: WorkerProfilePage.levelSlotHeight,
          width: WorkerProfilePage.levelSlotMaxWidth,
          child: _PendingBadge(badgeKey: Key('worker-profile-level-badge')),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        key: const Key('worker-profile-level-slot'),
        height: WorkerProfilePage.gradeBadgeSize,
        child: Center(
          child: WorkerGradeBadge(grade: g.grade, size: 24, label: g.title, labelSize: 12),
        ),
      ),
    );
  }

  /// 升级进度（`progress`）：**距下一级还差什么** —— 「有就显示，没数据就不显示」
  ///
  /// - 没有 `progress` / 已到最高档（`nextGrade == null` 且 `remain == null`）→ 整段不画；
  /// - 有差额 → 一行 11.5px：「距 LV4 称雄 · 完成单还差 3 单 · 结算累计还差 ¥120.00」；
  /// - 差额全为 0（已达标）→ 按服务端 `needManualReview` 说清是"等生效"还是"等人工审核"。
  /// 文案里的每一条都来自服务端 `progress.remain`（`gradeRemainItems` 是唯一出口），**不编数字**。
  List<Widget> _gradeProgressChildren() {
    final p = _profile?.grade?.progress;
    if (p == null) return const [];
    final next = [p.nextGradeLabel ?? '', p.nextGradeName ?? ''].where((s) => s.isNotEmpty).join(' ');
    final items = gradeRemainItems(p.remain);
    if (next.isEmpty && items.isEmpty) return const [];
    final head = next.isEmpty ? '升级进度' : '距 $next';
    final tail = items.isEmpty
        ? (p.needManualReview ? '门槛已达标，等待人工审核' : '门槛已达标，等待生效')
        : items.map((e) => e.text).join(' · ');
    return [
      const SizedBox(height: 12),
      Text(
        '$head · $tail',
        key: const Key('worker-profile-grade-progress'),
        style: TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.mutedText),
      ),
    ];
  }

  /// ID 行：`ID 11`（真实 `workerId`）+ 分隔点（可空时整段不画）
  Widget _idRow() {
    final id = widget.workerId.trim();
    if (id.isEmpty) return const SizedBox(height: 20);
    return SizedBox(
      height: 20,
      child: Row(
        children: [
          Text('ID ', style: TextStyle(fontSize: 13, color: T.textSecondary)),
          Text(
            id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textPrimary),
          ),
        ],
      ),
    );
  }

  /// ② 标尺线：**走装饰原子** `AppRuleLine`（1dp 线 + 两端 **3×3** 端点方块）。
  /// 语义是"头部与内容的分界"：线在这两处之间，所以它有端点。
  Widget _ruler() {
    return const SizedBox(
      key: Key('worker-profile-ruler'),
      height: 4,
      child: AppRuleLine(dots: AppRuleLineDots.both),
    );
  }

  // -------------------------------------------------------------------------
  // 内容区（卡间 20dp；页边 16dp；页底 32dp）
  // -------------------------------------------------------------------------

  /// 内容区子项（2026-10-18 起**不再自带滚动**）
  ///
  /// 顶栏 / 海报 / 内容现在同处**一根滚动轴**（`CustomScrollView` 的 sliver）——
  /// 嵌套第二个滚动视图会让"上方那一块跟着滚"变成两个各自独立的 offset。
  /// 内容本身、顺序、间距一个都没动：外层 `SliverPadding` 用的仍是
  /// [WorkerProfilePage.contentPadding]（与旧 `ListView.padding` 逐值相同）。
  List<Widget> _contentItems(_WorkerProfile? p, String intro, String? divisionName) {
    return [
      if (_failed && p == null) ...[
        // 异常态：**头部照常渲染**（名字来自上一页的兜底），只在下面给原因 + 重试。
        const SizedBox(height: 8),
        AppEmpty(
          icon: AppIcon.info,
          text: '打手信息暂时取不到',
          action: '重试',
          onAction: _load,
        ),
      ] else ...[
        // ③ 统计行
        _statsCard(p),
        const SizedBox(height: 20),
        // ④ 介绍卡
        _introCard(intro),
        const SizedBox(height: 20),
        if (_loading && p == null) ...[
          _tabRow(0),
          _reviewSkeleton(),
        ] else ...[
          // ⑤ 游戏胶囊 + 等级徽章
          _capsuleRow(divisionName),
          // ⑤' 升级进度一行（`progress.remain`；没数据就不画，见 [_gradeProgressChildren]）
          ..._gradeProgressChildren(),
          const SizedBox(height: 20),
          // ⑥ 双 Tab
          _tabRow(_reviewTotal),
          const SizedBox(height: 16),
          // ⑦ 六维圆环 + 六轴雷达
          _abilityCard(key: _abilityKey),
          const SizedBox(height: 20),
          // ⑧ 评价区
          SizedBox(key: _reviewKey, height: 8),
          if (_reviews.isEmpty)
            _reviewEmpty()
          else
            _reviewList(),
          if (_hasMore) ...[
            const SizedBox(height: 12),
            Center(
              // 用 `TextButton`（**页面唯一的次级文本按钮**，与 `AppEmpty` 的动作同一档）
              child: TextButton(
                key: const Key('worker-profile-more-reviews'),
                onPressed: _moreLoading ? null : _loadMore,
                child: Text(
                  _moreLoading ? '加载中…' : '查看更多评价',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: T.primary),
                ),
              ),
            ),
          ],
        ],
      ],
    ];
  }

  /// ③ 统计行（ContentCard）：**接单次数 / 好评率 / 时长**，中间 1px 发丝线分隔
  ///
  /// 参考图是「已接单 / 评分 / 时长」三格 —— 图标一律走 `AppIcons`（零 emoji）：
  /// - 接单次数 = `worker_stats.completed_orders` 生效值（真实）；
  /// - 好评率 = 服务端百分数（真实，唯一出口 `satisfiedRateText`）——**这就是参考图"评分"位的真数据源**；
  /// - 时长 = **后端没有** → `--`（待接入，绝不编 778.6 时）。
  // TODO(评分体系): 需要后端补 `worker_stats.online_seconds`（累计时长）→ 第三格换真值
  Widget _statsCard(_WorkerProfile? p) {
    final rate = satisfiedRateText(p?.satisfiedRate, reviewCount: p?.reviewCount);
    return AppNotched.forRole(
      AppNotchRole.contentCard,
      baseColor: T.bgCardSolid,
      borderColor: T.divider,
      child: Container(
        key: const Key('worker-profile-stats'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: T.divider, width: 1),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _stat(
                  icon: AppIcons.players,
                  label: '接单次数',
                  value: countText(p?.completedOrders, unit: '次'),
                ),
              ),
              Container(width: 1, color: T.divider),
              const SizedBox(width: 12),
              Expanded(
                child: _stat(
                  icon: AppIcons.medal,
                  label: '好评率',
                  value: rate,
                  muted: rate == kNoReviewYet,
                ),
              ),
              Container(width: 1, color: T.divider),
              const SizedBox(width: 12),
              Expanded(
                child: _stat(icon: AppIcons.clock, label: '时长', value: '--', muted: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个统计格：图标 + 11px 标签在上、数值在下、左对齐
  ///
  /// ## 数字口径（`docs/45 §二④`）
  /// - **等宽**（`FontFeature.tabularFigures`）：两格数字位数不同也不"跳栏"；
  /// - **三档字号里的 sm（15）**：不临时挑一个 16 或 17；
  /// - **不上金**：金只给"金额与等级位"，统计数字一律正文色（本页金额位=0，等级位已上金到徽章）。
  /// - 「暂无评价」「--」不是数字（是"没有"），退回 13/600 次级字。
  Widget _stat({required AppIcons icon, required String label, required String value, bool muted = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(icon, size: 16, color: AppColors.textPlaceholder),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: muted ? 13 : AppFigureSize.sm.value,
              fontWeight: muted ? FontWeight.w600 : FontWeight.w700,
              color: muted ? T.textSecondary : T.textPrimary,
              fontFeatures: muted ? null : const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      );

  /// ④ 介绍卡（ContentCard）：11px 标签 + 13/1.8 正文；**高度不因介绍为空而改变**
  ///
  /// 介绍为空 → 渲染弱化占位「介绍待补充」（`#8A99AB`），**不隐藏节点**（线上 13/14 人为空）。
  Widget _introCard(String intro) {
    final empty = intro.isEmpty;
    return AppNotched.forRole(
      AppNotchRole.contentCard,
      baseColor: T.bgCardSolid,
      borderColor: T.divider,
      child: Container(
        key: const Key('worker-profile-intro'),
        constraints: const BoxConstraints(minHeight: 104),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(AppDecoRadius.card),
          border: Border.all(color: T.divider, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('打手介绍', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textPlaceholder)),
            const SizedBox(height: 8),
            if (empty)
              Text(
                '$kIntroPlaceholder —— 该打手的介绍由打手自己填写，目前还没有填写。',
                key: const Key('worker-profile-intro-placeholder'),
                style: TextStyle(fontSize: 13, height: 1.8, color: AppColors.textPlaceholder),
              )
            else
              // 介绍属于"必须看全"的信息 → 不设 maxLines（长介绍完整展示）
              Text(intro, style: TextStyle(fontSize: 13, height: 1.8, color: T.textPrimary)),
          ],
        ),
      ),
    );
  }

  /// ⑤ 游戏胶囊 + 等级徽章（参考图的"游戏胶囊 + 等级徽章（一品）"一行）
  ///
  /// 胶囊**全页只有这一处**、**最多 3 枚**、单一主色浅底；数据只有「分部副标」一项真实来源
  /// （线上 13/14 人为 null → 不画空格子，结构规则 2）。
  Widget _capsuleRow(String? divisionName) {
    final caps = [
      if (divisionName != null && divisionName.trim().isNotEmpty) divisionName.trim(),
    ].take(3).toList();
    if (caps.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          for (final (i, c) in caps.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            WorkerCapsule(label: c),
          ],
        ],
      ),
    );
  }

  /// ⑥ 双 Tab（个人能力 / 评价 N）——**真滚动**：点击把对应区块滚到顶部
  Widget _tabRow(int count) {
    return Container(
      key: const Key('worker-profile-tab-row'),
      height: 44,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: T.divider, width: 1))),
      child: Row(
        children: [
          _tabItem(0, '个人能力', _abilityKey),
          const SizedBox(width: 20),
          _tabItem(1, count > 0 ? '评价 $count' : '评价', _reviewKey),
        ],
      ),
    );
  }

  Widget _tabItem(int index, String label, GlobalKey target) {
    final selected = _tabIndex == index;
    return GestureDetector(
      key: Key('worker-profile-tab-$index'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _jumpTo(target, index),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? T.primary : Colors.transparent, width: 2)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? T.primary : T.textSecondary,
          ),
        ),
      ),
    );
  }

  /// ⑦ 六维圆环 + **六轴六边形雷达**（**自己画**：`CustomPainter`，不引图表库、不用 shader）
  ///
  /// ## 口径（负责人 2026-10-18）
  /// - 环图与雷达**读同一份数值**（`_axisValues()`）：环 = 简表，雷达 = 图，
  ///   两处不可能各说各话（同一次请求、同一份 `rating`）；
  /// - 六个轴名固定为 [kRatingAxes]；第一个轴「评分」= 好评率 ÷ 10（见 `_scoreFromRate`）；
  /// - **缺数据时只画网格、不画多边形**，数值显示 `--`（0 分不是"差"，是没有）。
  Widget _abilityCard({Key? key}) {
    final values = _axisValues();
    final hasAny = values.any((v) => v != null);
    return AppNotched.forRole(
      AppNotchRole.contentCard,
      baseColor: T.bgCardSolid,
      borderColor: T.divider,
      child: Container(
        key: key ?? const Key('worker-profile-ability'),
        // **数值允许溢出卡片边界**（负责人 2026-10-18「数据可以直接溢出去的」）：
        // 雷达顶点外侧的 标签 / 数值 / 分 允许压到卡片描边之外。Container 的默认值本就是
        // `Clip.none`，这里显式写出来 —— 让"不裁"成为契约，而不是靠默认值碰巧成立。
        clipBehavior: Clip.none,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(AppDecoRadius.card),
          border: Border.all(color: T.divider, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('个人能力', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textPrimary)),
                const Spacer(),
                // 一格数据都没有时才说明"评分体系待接入"；有数据就不占版面
                if (!hasAny) Text(kRatingPendingText, style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder)),
              ],
            ),
            const SizedBox(height: 16),
            // 6 个圆环（3 × 2）：中心 = 该轴数值；无数据 → `--` 且进度 0
            Row(
              key: const Key('worker-profile-rings'),
              children: [
                for (final (i, label) in kRatingAxes.take(3).indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: _ratingRing(index: i, label: label, value: values[i])),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              key: const Key('worker-profile-rings-2'),
              children: [
                for (final (i, label) in kRatingAxes.skip(3).indexed) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: _ratingRing(index: i + 3, label: label, value: values[i + 3])),
                ],
              ],
            ),
            const SizedBox(height: 20),
            // 六轴六边形雷达：标签 / 数值 / 单位画在顶点**外侧**，允许溢出卡片边界
            _radarChart(values),
          ],
        ),
      ),
    );
  }

  /// 一枚评分环（参考图 2 的 6 个评分环之一）
  ///
  /// 灰度轨道 + 进度弧（`value == null` → 进度 0，只剩轨道）+ 中心数值 + 下方 11px 轴名。
  Widget _ratingRing({required int index, required String label, required double? value}) {
    // 0–10 的值 ÷ 10 = 环的进度（`null` 不参与，进度恒 0）
    final ratio = value == null ? 0.0 : value.clamp(0.0, _RadarPainter.maxValue) / _RadarPainter.maxValue;
    final filled = value != null;
    return Column(
      key: Key('worker-profile-ring-$index'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: WorkerProfilePage.ringSize,
          height: WorkerProfilePage.ringSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(WorkerProfilePage.ringSize),
                painter: _RingPainter(track: AppColors.statusMutedSoft, ring: T.primary, progress: ratio),
              ),
              Text(
                _scoreText(value),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: filled ? T.textPrimary : AppColors.textPlaceholder,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: T.textSecondary),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 六轴雷达（网格 + 数据多边形 + 顶点外侧的 标签 / 数值 / 单位）
  // -------------------------------------------------------------------------

  /// 六轴数值（顺序 = [kRatingAxes]）：**缺数据 = null，绝不填 0**
  ///
  /// - 「评分」= 好评率 ÷ 10（判空走 `satisfiedRateText` 唯一出口，见 [_scoreFromRate]）；
  /// - 其余五轴 = `rating.skill / emotion / stress / voice / shop`；
  /// - `rating.samples == 0` 由 [_WorkerRating.tryParse] 判成"还没人评过" → 五轴全 null
  ///   （不是 0 分：0 是"很差"，null 是"没有"）。
  List<double?> _axisValues() {
    final r = _profile?.rating;
    return <double?>[
      // 服务端已算好生效值（管理端手填优先，否则好评率 ÷ 10）→ 直接用；
      // 没有才回落自己按好评率换算（两条口径不会打架，见 [_scoreFromRate]）。
      r?.score ??
          _scoreFromRate(_profile?.satisfiedRate, reviewCount: _profile?.reviewCount),
      r?.skill,
      r?.emotion,
      r?.stress,
      r?.voice,
      r?.shop,
    ];
  }

  /// 六轴六边形雷达：**5 圈网格 + 数据多边形**（半透明主色填充 + 1.5px 主色描边）
  ///
  /// 布局：整块 [WorkerProfilePage.radarBlockHeight] 高、卡片内容宽；
  /// 六边形本体固定 [WorkerProfilePage.radarChartSize] 居中，六个轴的
  /// 「标签 / 数值 / 分」贴各自顶点**外侧**。块内 `Stack` 用 `Clip.none`，
  /// 窄屏上那几个数字可以压到卡片描边之外（卡片本身也 `Clip.none`，见 [_abilityCard]）。
  Widget _radarChart(List<double?> values) {
    return LayoutBuilder(
      key: const Key('worker-profile-radar'),
      builder: (context, constraints) {
        const radius = WorkerProfilePage.radarChartSize / 2;
        final center = Offset(constraints.maxWidth / 2, WorkerProfilePage.radarBlockHeight / 2);
        return SizedBox(
          height: WorkerProfilePage.radarBlockHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: center.dx - radius,
                top: center.dy - radius,
                width: WorkerProfilePage.radarChartSize,
                height: WorkerProfilePage.radarChartSize,
                child: CustomPaint(
                  painter: _RadarPainter(
                    grid: AppColors.strokeSoft,
                    axis: AppColors.hairline,
                    fill: T.primary.withValues(alpha: WorkerProfilePage.radarFillAlpha),
                    stroke: T.primary,
                    values: values,
                  ),
                ),
              ),
              for (var i = 0; i < kRatingAxes.length; i++) _axisLabel(i, values[i], center, radius),
            ],
          ),
        );
      },
    );
  }

  /// 一个轴的「标签（11px 灰）+ 数值（18px 粗体）+ 单位（10px 灰 `分`）」
  ///
  /// 落点按顶点方向分四种：正上 / 正下（左右居中），左侧 / 右侧（垂直居中贴顶点外侧）。
  Widget _axisLabel(int index, double? value, Offset center, double radius) {
    final angle = -math.pi / 2 + 2 * math.pi * index / kRatingAxes.length;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final vx = center.dx + radius * dx;
    final vy = center.dy + radius * dy;
    const gap = 8.0;
    final width = WorkerProfilePage.radarLabelWidth;
    const height = WorkerProfilePage.radarLabelHeight;
    final double left;
    final double top;
    if (dy < -0.5) {
      // 正上方那一轴（「评分」）：标签整组落在顶点上方
      left = vx - width / 2;
      top = vy - gap - height;
    } else if (dy > 0.5) {
      // 正下方那一轴（「综合表现」）
      left = vx - width / 2;
      top = vy + gap;
    } else if (dx > 0) {
      left = vx + gap;
      top = vy - height / 2;
    } else {
      left = vx - gap - width;
      top = vy - height / 2;
    }
    final filled = value != null;
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            kRatingAxes[index],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: T.textSecondary),
          ),
          const SizedBox(height: 4),
          // 数值行不折行、超宽整体缩小（不让「9.86 分」折成两行把标签顶出格子）
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _scoreText(value),
                  style: TextStyle(
                    fontSize: AppFigureSize.md.value,
                    fontWeight: FontWeight.w800,
                    color: filled ? T.textPrimary : AppColors.textPlaceholder,
                  ),
                ),
                // 单位只跟真实数值：`--` 后面不挂「分」（"-- 分"读不通）
                if (filled) ...[
                  const SizedBox(width: 4),
                  Text('分', style: TextStyle(fontSize: 10, color: T.textSecondary)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 评价列表：ListCard（**发丝线行**）—— 列表语义用列表档
  Widget _reviewList() => Container(
        key: const Key('worker-profile-reviews'),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: T.divider, width: 1))),
        child: Column(
          children: [
            for (var i = 0; i < _reviews.length; i++) ...[
              if (i > 0) const AppHairline(),
              WorkerReviewTile(review: _reviews[i]),
            ],
          ],
        ),
      );

  /// 0 评价：**说清为什么空 + 给下一步的期待**（`docs/21` §五），不摆任何假数据
  ///
  /// 走装饰原子的空态档 `AppEmptyDeco`（5% 细网格底 + 48×48 线框图标 + 标尺线 + 一句下一步）。
  Widget _reviewEmpty() => Container(
        key: const Key('worker-profile-reviews-empty'),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: T.divider, width: 1))),
        child: AppEmptyDeco(
          icon: AppIcon.comment,
          title: '这位打手还没有收到评价',
          hint: '完成第 1 单后，评价会出现在这里；好评率也只从有评价那天开始算。',
        ),
      );

  Widget _reviewSkeleton() => Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppSkeletonBlock(width: 56, height: 12, animate: false),
                const Spacer(),
                AppSkeletonBlock(width: 56, height: 12, animate: false),
              ],
            ),
            const SizedBox(height: 8),
            AppSkeletonBlock(width: double.infinity, height: 12, animate: false),
            const SizedBox(height: 8),
            AppSkeletonBlock(width: 72, height: 12, animate: false),
          ],
        ),
      );

  // -------------------------------------------------------------------------
  // ⑨ 底部固定操作条：推荐 / 联系客服 + 主按钮
  // -------------------------------------------------------------------------

  /// 参考图 2 的底部条是 `[推荐][礼物][联系客服(主按钮)]`；负责人 2026-10-18 删掉「礼物」。
  ///
  /// 落到我们的真实能力上：
  /// - **联系客服是真功能**（`GET /user/conversation`，与「我的 › 联系客服」同一条入口）；
  /// - **推荐没有后端**（点赞表不存在）→ 仍是**置灰的待接入位**（按指示原样保留），
  ///   不做"点了没反应"的假按钮（`docs/21` §三）；
  /// - **主按钮仍是「找 TA 下单」**：本页的业务目的就是把老板送到既有下单链路
  ///   （「指定护航员」），这一条不因版式重构而丢。
  Widget _bottomBar() {
    // 用 `alignment` 居中而不是 padding：**padding 版的父容器会先扣掉 1px 顶边框**，
    // 于是 72 − 14×2 − 1 = 43 → 主按钮在渲染上会矮 1dp（设计稿要求 44）。
    return Container(
      key: const Key('worker-profile-bottom-bar'),
      height: WorkerProfilePage.bottomBarHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: Border(top: BorderSide(color: T.divider, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _barAction(icon: AppIcons.heart, label: '推荐'),
          const SizedBox(width: 12),
          _barAction(icon: AppIcons.headset, label: '联系客服', onTap: _openCsChat),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              key: const Key('worker-profile-order-button'),
              height: 44,
              // ③ 装饰：主按钮右上切口 —— 走装饰原子 `AppNotched`（底色盖角 + 只画两条边），
              // 边长由**按钮高 44** 推导 = 8×8（`AppNotch.sizeForHeight(44)`，谱系封顶 8）。
              child: AppNotched(
                height: 44,
                corner: AppNotchCorner.topRight,
                baseColor: T.bgCardSolid,
                borderColor: T.primary,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openOrderFlow,
                  child: Container(
                    width: double.infinity,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: T.primary),
                    child: Text(
                      '找 TA 下单',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 底部条上的一个图标动作（`onTap == null` → 待接入：置灰、不可点）
  Widget _barAction({required AppIcons icon, required String label, VoidCallback? onTap}) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 44,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppIcon(icon, size: 20, color: enabled ? T.textSecondary : AppColors.textTertiary),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: enabled ? T.textSecondary : AppColors.textPlaceholder,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 随滚顶栏（把既有 `AppPageHeader` 装进 `CustomScrollView`）
// ---------------------------------------------------------------------------

/// 把 `AppPageHeader` 装进 sliver 的最小适配器（**只有高度这一件事**）
///
/// - `minExtent == maxExtent == extent`：页头高度固定（sliver 协议要求给死数字），
///   `extent` 由 [WorkerProfilePage.headerExtent] 一处推导（状态栏内距 + `AppPageHeader.barHeight`）。
/// - **不复用 `SliverAppBar`**：那会把页头的白底 / 56 高 / 发丝线 / 20-800 标题再实现第二份；
///   页头本体始终只有 `AppPageHeader` 一份实现，这里只负责"把它摆进滚动轴"。
/// - `floating` / `pinned` 由调用点决定：本页是 `pinned: false, floating: true`
///   → 下滑随内容滚走、上滑自己滑回来（负责人 2026-10-18「上方那一块要跟着滑动」，
///   同时保留"滚到深处也能返回"的入口）。
class _ScrollingPageHeader extends SliverPersistentHeaderDelegate {
  const _ScrollingPageHeader({required this.extent, required this.child});

  /// 整条高度（含状态栏内距）
  final double extent;

  /// 页头本体（`AppPageHeader`）
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox(height: extent, child: child);

  @override
  bool shouldRebuild(covariant _ScrollingPageHeader oldDelegate) =>
      oldDelegate.extent != extent || oldDelegate.child != child;
}

// ---------------------------------------------------------------------------
// 六轴数值文案（**唯一出口**：页面里不许再写第二套换算）
// ---------------------------------------------------------------------------

/// 「评分」轴的值 = **好评率 ÷ 10**（负责人 2026-10-18 指定；轴范围 0–10）
///
/// 好评率的契约是**百分数**（服务端下发 `"98.6"` 表示 98.6%，唯一出口
/// `satisfiedRateText`），而六个轴的量程统一是 **0–10**，所以把百分数除以 10 落进
/// 同一个量程：`98.6%` → `9.86`、`100%` → `10`、`1%` → `0.1`。
///
/// 判空**只走 `satisfiedRateText` 这一个出口**（它已经把「无评价 / `reviewCount 0` /
/// 非法值」统一成 `kNoReviewYet`）→ 这里不重复判断：否则会出现"统计格说暂无评价、
/// 雷达却按 0 分算"的两套口径（`docs/09` 的 F1 同类根因）。
double? _scoreFromRate(Object? rate, {Object? reviewCount}) {
  final text = satisfiedRateText(rate, reviewCount: reviewCount);
  if (text == kNoReviewYet) return null;
  final percent = double.tryParse(text.replaceAll('%', ''));
  if (percent == null) return null;
  final score = percent / 10;
  return score.clamp(0.0, _RadarPainter.maxValue).toDouble();
}

/// 数值文案（0–10 量程）：`9.86` / `8.5` / `10`；没有数据 → `--`
///
/// 整数不带小数点、小数最多两位且不吃尾零 —— 与 `gradeRemainItems` 同一写法
/// （同一页里两个小数不会一个写 `9.9` 一个写 `9.90`）。
String _scoreText(double? value) {
  if (value == null) return '--';
  final v = value.clamp(0.0, _RadarPainter.maxValue).toDouble();
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  final s = v.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}

/// **待接入徽章**（等级位用）：灰底 + `--`，几何由外层 SizedBox 锁定
class _PendingBadge extends StatelessWidget {
  const _PendingBadge({required this.badgeKey});

  final Key badgeKey;

  @override
  Widget build(BuildContext context) => Container(
        key: badgeKey,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.statusMutedSoft,
          borderRadius: BorderRadius.circular(AppDecoRadius.tag),
        ),
        child: Text('--', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textPlaceholder)),
      );
}

/// 评分圆环（`CustomPainter` 自绘：一圈灰度轨道 + 一段主色进度弧，**无 shader**）
class _RingPainter extends CustomPainter {
  const _RingPainter({required this.track, required this.ring, required this.progress});

  final Color track;
  final Color ring;

  /// 0–1 的进度（`value / 10`；该轴没有数据时调用点传 0，只剩轨道）
  final double progress;

  /// 环宽 4（4dp 网格；48 直径下与 12sp 的 `--` 不打架）
  static const double strokeWidth = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);
    if (progress <= 0) return;
    final arcPaint = Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.track != track || old.ring != ring;
}

/// **六轴六边形雷达**（`CustomPainter` 自绘：5 圈同心六边形 + 6 条轴线 + 数据多边形，
/// **无 shader、无图表库**）
///
/// ## 画法（负责人 2026-10-18 参考图）
/// 1. **5 圈同心六边形网格**：细线 1px、弱色 [grid]（`AppColors.strokeSoft`）——
///    不画满 10 圈（密网格会把多边形压得看不见）；
/// 2. **6 条轴线**：从中心到顶点，比网格再弱一档 [axis]（`AppColors.hairline`）；
/// 3. **数据多边形**：**六轴都有值才画** —— 半透明主色填充 [fill] + 1.5px 主色描边 [stroke]。
///    缺任何一个轴就不画（"没有评分"绝不能画成"0 分"：那是一个贴着中心的小正六边形，
///    读起来就是"样样稀烂"）。
///
/// 轴标签 / 数值 / 单位**不在这个 painter 里**：它们要量文本、要溢出卡片边界，
/// 交给外层 `Stack` 的 `Positioned` 文本组（见 `_axisLabel`）。
class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.grid,
    required this.axis,
    required this.fill,
    required this.stroke,
    required this.values,
  });

  /// 同心六边形网格（弱色）
  final Color grid;

  /// 从中心到顶点的轴线（比网格更弱一档）
  final Color axis;

  /// 数据多边形的填充（半透明主色）
  final Color fill;

  /// 数据多边形的描边（实色主色，1.5px）
  final Color stroke;

  /// 六轴数值（0–10，顺序 = `kRatingAxes`；`null` = 该轴没有数据）
  final List<double?> values;

  /// 轴数（6，唯一出处 [WorkerProfilePage.radarAxes]）
  static const int axes = WorkerProfilePage.radarAxes;

  /// 网格圈数（5，唯一出处 [WorkerProfilePage.radarRings]）
  static const int rings = WorkerProfilePage.radarRings;

  /// 轴范围上限（六个轴统一 0–10）
  static const double maxValue = 10;

  /// 数据多边形描边宽（1.5px）
  static const double strokeWidth = 1.5;

  /// 网格与轴线线宽（细线 1px）
  static const double lineWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 描边有 1.5px 宽，半径让出这一档，免得最外圈被画布切掉一半
    final radius = size.shortestSide / 2 - strokeWidth;

    // ① 5 圈同心六边形（细线弱色）
    final gridPaint = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth;
    for (var r = 1; r <= rings; r++) {
      canvas.drawPath(_polygon(center, radius * r / rings), gridPaint);
    }

    // ② 6 条轴线（更弱一档）
    final axisPaint = Paint()
      ..color = axis
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth;
    for (var i = 0; i < axes; i++) {
      canvas.drawLine(center, _vertex(center, radius, i), axisPaint);
    }

    // ③ 数据多边形：**六轴都有值才画**（缺一个就只留网格）
    if (!hasData) return;
    final path = Path();
    for (var i = 0; i < axes; i++) {
      final v = values[i]!.clamp(0.0, maxValue);
      final p = _vertex(center, radius * v / maxValue, i);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 数据是否齐全（六个轴都有值）—— 多边形只在这个条件下画
  bool get hasData => values.length == axes && values.every((v) => v != null);

  /// 第 i 个顶点（从正上方起顺时针均分；与外层 `_axisLabel` 的角度公式必须同一份）
  Offset _vertex(Offset center, double radius, int i) {
    final angle = -math.pi / 2 + 2 * math.pi * i / axes;
    return Offset(center.dx + radius * math.cos(angle), center.dy + radius * math.sin(angle));
  }

  /// 一整圈六边形
  Path _polygon(Offset center, double radius) {
    final path = Path();
    for (var i = 0; i < axes; i++) {
      final p = _vertex(center, radius, i);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.grid != grid ||
      old.axis != axis ||
      old.fill != fill ||
      old.stroke != stroke ||
      !_sameValues(old.values, values);

  /// 六个数值逐项比较（`List<double?>` 没有内置相等）
  static bool _sameValues(List<double?> a, List<double?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 4 枚刻度之一：6×1dp 主色小条（静态，无发光、无旋转、无粒子）
class _Tick extends StatelessWidget {
  const _Tick({required this.vertical});

  /// true = 上下两枚（竖条 1×6）；false = 左右两枚（横条 6×1）
  final bool vertical;

  @override
  Widget build(BuildContext context) => Container(
        width: vertical ? 1 : 6,
        height: vertical ? 6 : 1,
        color: T.primary,
      );
}

/// 小胶囊（**全页唯一一处**）：高 24 / 圆角 6 / 11px w600 / **单一主色浅底**
///
/// ## 形状接入斜切角语言（`docs/45 §二⑤`：分区标签 = 高 24 → **右上 6×6**）
/// 数据上它就是**分部副标（归属）**：与列表页那枚胶囊是同一个字段 → 必须同形，
/// 否则"分部副标"在列表上是一个角、点进去变成另一个角（同一件事两套装扮）。
class WorkerCapsule extends StatelessWidget {
  const WorkerCapsule({super.key, required this.label});

  final String label;

  /// 胶囊高 24（切口由此推导 = 6×6）
  static const double capsuleHeight = 24;

  /// 该胶囊的角位（分区/归属标签：右上 —— 与列表页 `PlayerCapsule.notchCorner`
  /// 及 `AppNotchRole.sectionTag.corner` 同一个角位，测试钉住三者相等）
  static const AppNotchCorner notchCorner = AppNotchCorner.topRight;

  @override
  Widget build(BuildContext context) => AppNotched(
        height: capsuleHeight,
        corner: notchCorner,
        // 盖角方块 = 场底下的颜色（页底浅灰）：切口才像"被切掉"
        baseColor: AppColors.bgPageG,
        borderColor: T.primary,
        child: Container(
          height: capsuleHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: T.primary),
          ),
        ),
      );
}

/// 评价行（发丝线由外层给，行内只负责内容）
///
/// ## 三层重排（与参考图 2 的行内组织对齐）
/// ```
/// 昵称脱敏（上，13/600）        →        判定（右上：16 图标 + 12/700 + 文案 + 颜色）
/// 备注（中，13/1.7）
/// 时间（下，11 弱化）
/// ```
///
/// ## 判定**没有星**
/// 我们的评价模型是**二元**（`order_review.satisfied`），不是 5 星 —— 所以用
/// 「**图标（形状）+ 字重 w700 + 文案「满意 / 不满意」+ 颜色**」**四重信号**，
/// **不只靠颜色**（`docs/21`：状态不能只靠颜色）。
class WorkerReviewTile extends StatelessWidget {
  const WorkerReviewTile({super.key, required this.review});

  final WorkerReview review;

  /// 判定小片的高 20 → 斜切角谱系里的"高 20 → **右上 6×6**"那一档
  static const double _verdictChipHeight = 20;

  @override
  Widget build(BuildContext context) {
    final color = reviewVerdictColor(review.satisfied);
    final time = reviewTimeText(review.createdAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 评价人头像字标（浅底 + 主色字；**无渐变**）
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppColors.primarySoft, shape: BoxShape.circle),
            child: Text(
              review.nicknameMasked.isEmpty ? '匿' : review.nicknameMasked.characters.first,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: T.primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        review.nicknameMasked.isEmpty ? '匿名用户' : review.nicknameMasked,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: T.textPrimary),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 判定在**右上**：图标 + 形状（右上 6×6 切口）+ 字重 w700 + 颜色，四重信号
                    AppNotched(
                      height: _verdictChipHeight,
                      corner: AppNotchRole.statusTag.corner,
                      baseColor: T.bgCardSolid,
                      borderColor: color,
                      borderWidth: 1,
                      child: Container(
                        height: _verdictChipHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: AppColors.categorySoft(color),
                          borderRadius: BorderRadius.circular(AppDecoRadius.tag),
                          border: Border.all(color: AppColors.categoryBorder(color), width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon.of(reviewVerdictIcon(review.satisfied), size: 16, color: color),
                            const SizedBox(width: 4),
                            Text(
                              reviewVerdictText(review.satisfied),
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (review.remark.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(review.remark, style: TextStyle(fontSize: 13, height: 1.7, color: T.textPrimary)),
                ],
                if (time.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(time, style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `/public/workers/:id` 的解析结果
///
/// 字段名与接口契约逐字对齐：`nickname / intro / avatarMediaId / completedOrders /
/// reviewCount / satisfiedRate / reviews[]`（+ `divisionName` / `divisionId`，服务端可空；
/// 2026-10-18 起再吃 `rating{skill, emotion, stress, voice, shop, samples}`）。
/// **多一个都不取**（客户端不发明字段）；**全部按可空处理** —— 缺字段就不显示那一项。
class _WorkerProfile {
  _WorkerProfile({
    required this.nickname,
    required this.intro,
    required this.avatarMediaId,
    this.backgroundMediaId,
    required this.completedOrders,
    required this.reviewCount,
    required this.satisfiedRate,
    required this.divisionName,
    required this.divisionId,
    required this.reviews,
    required this.grade,
    required this.rating,
  });

  final String nickname;
  final String intro;
  final String? avatarMediaId;

  /// 主页背景 mediaId（负责人 2026-10-18：打手可自定义；null = 用默认场 + 细网格）
  final String? backgroundMediaId;

  /// 接单次数（服务端权威；缺失 → null → 页面显示 `—`，不编 0）
  final int? completedOrders;

  /// 评价总数（决定"查看更多"）
  final int? reviewCount;

  /// 好评率原值（**原样收**，怎么显示由 `satisfiedRateText` 一处说了算）
  final Object? satisfiedRate;

  /// 分部名（「找 TA 下单」带下去当分部筛选；可空）
  final String? divisionName;

  /// 分部 id（可空 → 下单链路退到"全部分部"）
  final String? divisionId;

  /// 最近评价（形状不对的条目在解析时就被丢掉，见 [WorkerReview.fromJson]）
  final List<WorkerReview> reviews;

  /// 打手等级（2026-10-17 上线）：`grade / gradeLabel / gradeName` + `progress`（升级进度）
  ///
  /// 服务端把 `WorkerGradeService.detail()` 的字段**平铺**在详情响应上（`{...profile, ...grade}`），
  /// 所以这里直接吃整包 JSON。`null` = 没有等级数据 → 等级位回到 `--` 占位、进度行整块不画。
  /// 注意：这是**打手等级**（初出/立足/扬名/称雄/宗师），不是老板端「会员」那套名字。
  final WorkerGrade? grade;

  /// 五维均值 + 样本数（2026-10-18 起接进雷达）：`rating{skill, emotion, stress, voice, shop, samples}`
  ///
  /// 与等级同源（服务端 `WorkerGradeService.detail()` 平铺在详情响应上）。
  /// `null` = **还没有人评过**（`samples == 0` 或缺字段）→ 六轴只画网格、数值 `--`。
  final _WorkerRating? rating;

  factory _WorkerProfile.fromJson(Map json) => _WorkerProfile(
        nickname: '${json['nickname'] ?? ''}'.trim(),
        intro: '${json['intro'] ?? ''}'.trim(),
        avatarMediaId: json['avatarMediaId'] == null ? null : '${json['avatarMediaId']}',
        backgroundMediaId:
            json['backgroundMediaId'] == null ? null : '${json['backgroundMediaId']}',
        completedOrders: _intOf(json['completedOrders']),
        reviewCount: _intOf(json['reviewCount']),
        satisfiedRate: json['satisfiedRate'],
        divisionName: (json['divisionName'] as String?)?.trim(),
        divisionId: json['divisionId'] == null ? null : '${json['divisionId']}',
        reviews: ((json['reviews'] as List?) ?? const [])
            .map(WorkerReview.fromJson)
            .whereType<WorkerReview>()
            .toList(),
        grade: WorkerGrade.tryParse(json),
        rating: _WorkerRating.tryParse(json['rating']),
      );

  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.isFinite ? raw.toInt() : null;
    return int.tryParse('${raw ?? ''}'.trim());
  }
}

/// 五维均值（服务端 `RatingSummary` 的客户端镜像；**只读，不重算**）
///
/// 字段与 `server/src/modules/rating/worker-grade.service.ts` 的 `RatingSummary`
/// 一一对应（`avg` 用不上，不取）。五列都是 **0–10 分**的均值。
class _WorkerRating {
  const _WorkerRating({
    required this.skill,
    required this.emotion,
    required this.stress,
    required this.voice,
    required this.shop,
    this.score,
  });

  /// 技术水平
  final double? skill;

  /// 情绪价值
  final double? emotion;

  /// 抗压能力
  final double? stress;

  /// 声音听感
  final double? voice;

  /// 综合表现（服务端列名仍是 `shop`，展示名 2026-10-18 改为「综合表现」）
  final double? shop;

  /// 「评分」轴（2026-10-18）：服务端下发的生效值（管理端手填优先，否则好评率÷10）。
  /// 为 null 时由 [_axisValues] 回落到自己按好评率算 —— 两条口径不会打架。
  final double? score;

  /// 解析；**没有真实数据 → `null`（整块当"还没有人评过"）**
  ///
  /// 为什么用样本数当开关：服务端在没有聚合行时五列一律回 `0`，而 `0` 在这张图上
  /// 的意思是"这项极差"，不是"没人评"——两者必须分开，否则一个新打手一上来就是
  /// 贴着中心的六边形（等于给他画了个"样样稀烂"的画像）。
  ///
  /// ⚠️ 2026-10-18 修（负责人：管理端改完老板端看不到）：光看 `samples` 不够了。
  /// 管理端可以**手填**六维（`worker_rating_manual`），此时 `samples` 仍是 0（确实没人评过），
  /// 但服务端已经把值算好了并通过 `sources` 标明来源 —— 原逻辑会把它当"没数据"整块丢掉。
  /// 现在：**只要任一维 `sources[dim] == 'manual'`，就认为有数据**，照常取值。
  static _WorkerRating? tryParse(Object? raw) {
    if (raw is! Map) return null;

    // 先看有没有手填：任一手填维 → 有数据（即便 samples 是 0）
    final sources = raw['sources'];
    var hasManual = false;
    if (sources is Map) {
      for (final v in sources.values) {
        if ('$v'.trim() == 'manual') {
          hasManual = true;
          break;
        }
      }
    }

    final samples = _doubleOf(raw['samples']);
    final hasSamples = samples != null && samples > 0;
    if (!hasManual && !hasSamples) return null;

    return _WorkerRating(
      skill: _doubleOf(raw['skill']),
      emotion: _doubleOf(raw['emotion']),
      stress: _doubleOf(raw['stress']),
      voice: _doubleOf(raw['voice']),
      shop: _doubleOf(raw['shop']),
      score: _doubleOf(raw['score']),
    );
  }

  /// `int` / `num` / 数字串都吃，其余 → null（不猜 0）
  static double? _doubleOf(Object? raw) {
    if (raw is num) return raw.isFinite ? raw.toDouble() : null;
    final s = '${raw ?? ''}'.trim();
    if (s.isEmpty) return null;
    final d = double.tryParse(s);
    return d == null || !d.isFinite ? null : d;
  }
}
