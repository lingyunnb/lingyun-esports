import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/product_detail_bottom_bar.dart';
import 'chat_detail_page.dart';
import 'order_create_page.dart';
import 'orders_page.dart';

/// 商品详情页（v2 **方案 B 极简克制**，负责人 2026-10-05 审批选定）
///
/// 设计稿：[`site/design/product-detail-v2/b-restrained.html`](../../../../site/design/product-detail-v2/b-restrained.html)
/// 出图：`site/design/product-detail-v2/Z2-B-默认.png` / `Z2-B-折叠.png` / `Z2-A-空态.png`
///
/// ## 这一版解决的三件事（v1 的问题，已在设计阶段查清）
/// 1. **v1 是死代码**：列表页点商品**直接进确认订单页**，用户根本看不到详情 →
///    本页现在由 `product_list_page.dart` 整卡 onTap 进入；
/// 2. **v1 用已停用的玻璃拟态**（`FishGlassPage` / `FishGlassCard`）→ 本版全平：白块 + 发丝线 +
///    冷灰蓝间隙，无渐变主视觉、无卡片阴影铺满、无 emoji（docs/21）；
/// 3. **v1 的「立即下单」走弹层直接下单**（`_OrderSheet` → `POST /user/orders`），
///    **绕过了确认订单页**（游戏分区/游戏 ID/数量都不经确认页）→ 本版「立即购买」
///    **只 push 现有 `order_create_page.dart`**，下单流程一个字没改。
///
/// ## 首屏只留一个动作
/// 底部固定操作栏右侧只有一个实色主按钮「立即购买」（#2563EB，高 44 ≥ 44 热区要求）；
/// 左侧两个图标位（客服 / 我的订单）都是**真实入口**（真实会话页、真实订单页），不做"店铺"
/// （结构规则 4：只有官方自营，没有店铺概念）。
///
/// ## 客户端不写死任何"规则数字"
/// - 提示条的「超 N 小时」中的 **N 来自接口** `orderPendingTakeTimeoutHours`
///   （服务端读 `system_setting.order_pending_take_timeout_hours`，管理端改完立即生效）；
/// - 「下单须知」全文来自接口 `effectiveOrderNotice`（商品级覆盖 → 平台默认，服务端已解析）；
/// - 每周限购文案来自 `/user/orders/weekly-quota`（与列表页/下单页同一份权威文案）。
class ProductDetailPage extends StatefulWidget {
  const ProductDetailPage({super.key, required this.productId, this.api, this.initialName, this.initialCoverUrl});

  final String productId;

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  /// 列表页带过来的商品名（**只用于加载态占位**：从列表点进来时有名字比一个空白页头好，
  /// 数据到了就用接口的权威值覆盖 —— 客户端不做任何"名称权威"判断）
  final String? initialName;

  /// 列表页带过来的封面（同上，只用于加载态占位）
  final String? initialCoverUrl;

  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<ProductDetailPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  Map<String, dynamic>? _product;
  String? _error;

  /// 每周限购配额（服务端 `/user/orders/weekly-quota`；与列表页/下单页同一份权威文案）
  Map<String, dynamic>? _quota;

  /// 展开的下标集合：商品说明区（0）与常见问题（1..4）
  final Set<int> _faqOpen = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _product = null;
    });
    try {
      final resp = await _api.request('GET', '/public/products/${widget.productId}');
      if (!mounted) return;
      setState(() => _product = (resp['data'] as Map?)?.cast<String, dynamic>());
      // 详情页也展示限购提示（与列表/下单页一致）
      unawaited(_loadQuota());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// 拉取每周限购配额；未登录 / 不限购 / 失败 → 不显示（客户端不硬编码规则文案）
  Future<void> _loadQuota() async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final resp = await _api.request(
        'GET',
        '/user/orders/weekly-quota',
        token: token,
        queryParameters: {'productId': widget.productId},
      );
      if (!mounted) return;
      setState(() => _quota = (resp['data'] as Map?)?.cast<String, dynamic>());
    } catch (_) {
      if (mounted) setState(() => _quota = null);
    }
  }

  // ---------------- 接口字段读取（客户端只读、不猜） ----------------

  /// 封面的**权威**来源：接口 `coverUrl`。接口没回来时用列表页带来的那张做占位。
  ///
  /// ⚠️ 不用 `coverMediaId` 兜底猜路径：媒体路径由服务端 `/media/public/:id` 决定，
  /// 客户端拼路径属于"猜"，一旦服务端改了 URL 规则就会静默白图。
  String? get _coverUrl {
    final p = _product;
    if (p != null) {
      final url = (p['coverUrl'] as String?)?.trim() ?? '';
      return url.isEmpty ? null : url;
    }
    final fallback = (widget.initialCoverUrl ?? '').trim();
    return fallback.isEmpty ? null : fallback;
  }

  /// 生效下单须知（**服务端已解析**商品级覆盖 → 平台默认）；空则不渲染该折叠块
  String get _notice {
    final text = (_product?['effectiveOrderNotice'] as String?)?.trim() ?? '';
    if (text.isNotEmpty) return text;
    return '';
  }

  /// 待接单超时小时数（接口下发；**客户端不写死 24**）
  ///
  /// 拿不到（老服务端 / 字段缺失）时返回 null → 提示条退化为不带数字的文案，
  /// **绝不本地编一个 24** —— 那正是本任务要消灭的硬编码。
  int? get _timeoutHours {
    final v = _product?['orderPendingTakeTimeoutHours'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 服务方式：`divisionPlatformLabel · 人工陪同`（如「手游 · 人工陪同」）
  String get _serviceMethod {
    final platform = (_product?['divisionPlatformLabel'] as String?)?.trim() ?? '';
    return platform.isEmpty ? '人工陪同' : '$platform · 人工陪同';
  }

  /// 提示条文案（N 来自接口；拿不到小时数时用不含数字的等价说法）
  String get _noticeText {
    final h = _timeoutHours;
    final tail = h == null ? '超时无人接单，系统自动取消并退款。' : '超 $h 小时无人接单，系统自动取消并退款。';
    return '未接单可随时取消并全额退回余额；$tail';
  }

  /// 须知正文按 `\n` 分条（服务端约定：条内不写序号，序号由 `AppTermsList` 排版）
  List<String> get _noticeItems => _notice
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// FAQ（页内静态问答：这里的问答**不含**任何规则数字的硬编码 —— 需要数字的那条用接口值拼）
  List<AppFaqItem> get _faqItems {
    final h = _timeoutHours;
    final hours = h == null ? '' : '$h 小时';
    return [
      AppFaqItem(
        question: '下单后多久有人接单？',
        answer: '订单进入待接单大厅后，由有该分部权限的护航员接单；'
            '${hours.isEmpty ? '超时无人接单' : '超过 $hours 无人接单'}，系统自动取消并全额退回余额。',
      ),
      const AppFaqItem(
        question: '填错游戏 ID 怎么办？',
        answer: '未接单时可以直接取消订单再重新下单；已接单后请联系客服，由客服协调护航员更换信息。',
      ),
      const AppFaqItem(
        question: '余额能退吗？',
        answer: '未接单取消、超时自动取消、售后申诉通过三种情况都会全额退回余额，明细在「我的 - 我的余额」。',
      ),
      const AppFaqItem(
        question: '护航员会要我账号密码吗？',
        answer: '不会。平台不支持任何形式的账号共享，服务过程中请勿把账号密码告知任何人。',
      ),
    ];
  }

  /// 「立即购买」→ push 现有确认订单页（**带商品，保持现有下单流程不变**）
  ///
  /// 传下去的字段与列表页原来的 `_openOrder` 完全同一套（id/name/price/priceUnit/coverUrl/
  /// divisionId/gameId/badgeText/weeklyLimit），确认订单页无需为新入口改任何代码。
  ///
  /// 注意（2026-10-05）：列表页的 `_openOrder` 已删除（点卡与点右下「下单」都先进本页），
  /// **本页的「立即购买」是确认订单页的唯一入口**。
  Future<void> _buyNow() async {
    final p = _product;
    if (p == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderCreatePage(
          api: widget.api,
          divisionId: '${p['divisionId'] ?? ''}',
          product: {
            'id': '${p['id']}',
            'name': '${p['name'] ?? ''}',
            'price': p['price'],
            'priceUnit': '${p['priceUnit'] ?? ''}',
            'coverUrl': p['coverUrl'],
            'divisionId': p['divisionId'],
            'gameId': '${p['gameId'] ?? ''}',
            'badgeText': p['badgeText'],
            'weeklyLimit': p['weeklyLimit'],
          },
        ),
      ),
    );
  }

  /// 客服：获取（自动创建）客服会话 → 进入聊天详情（与「我的 - 联系客服」同一条真实入口）
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

  /// 我的订单：push 一层**带返回箭头**的真实订单页
  ///
  /// 为什么不直接 push `OrdersPage()`：它在 `HomeShell` 里是**底栏分支**（页内没有返回箭头），
  /// 直接 push 会得到一个"回不去"的页面（顶部只有状态标签行）。这里补一个
  /// `AppPageHeader` 顶在它上面 —— 页面本体仍是**同一个** `OrdersPage`，
  /// 订单功能零改动（不复制第二套订单页、不改 `orders_page.dart` 一行）。
  ///
  /// 也不用"页内切换 + 隐藏详情页"那种写法：那会**卸载详情页**（丢滚动位置、
  /// 返回时要重新拉一次接口），push 一层才是真机上"我要看订单"该有的层级。
  Future<void> _openMyOrders() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: T.scaffoldColor,
          body: Column(
            children: [
              AppPageHeader(title: '我的订单'),
              Expanded(child: OrdersPage(api: widget.api)),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleFaq(int index) {
    setState(() {
      if (!_faqOpen.remove(index)) _faqOpen.add(index);
    });
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final p = _product;
    final name = (p?['name'] as String?)?.trim().isNotEmpty == true ? '${p!['name']}' : (widget.initialName ?? '商品详情');

    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          AppPageHeader(title: name),
          Expanded(
            child: _error != null
                ? _errorView()
                : p == null
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _content(p),
                          ),
                        ),
                      ),
          ),
          ProductDetailBottomBar(
            onService: _openCsChat,
            onMyOrders: _openMyOrders,
            onBuy: p == null ? null : _buyNow,
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: T.error)),
            const SizedBox(height: AppSpacing.lg),
            AppButton(label: '重试', onPressed: _load, expand: false, height: 40),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(Map<String, dynamic> p) {
    final items = _noticeItems;
    return [
      // ① 16:9 主图位（**通栏直角**，方案 G：大图不加圆角；无封面 → 设计稿空态：
      //    虚线位 + 真实字段 + 下一步动作，不是空白、不是插画）
      if (_coverUrl != null)
        _hero(_coverUrl!)
      else
        AppEmptyMediaBlock(
          title: '商品图待补充',
          subtitle: '这个商品只有文字配置；下面的字段都是接口下发的真实值',
        ),

      // ② 标题 + 价格（大字金）+ 销量 + 三列事实（白底一块，三列与价格同组）
      _priceBlock(p),

      // ③ 提示条（文案**全部来自接口**：小时数来自 system_setting）
      Container(
        color: T.bgCardSolid,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: AppNoticeBar(text: _noticeText),
      ),

      // ④ 规格与须知分区（方案 G：**同一张白面 + 1px 发丝线分块**，不堆卡片）
      _specZone(p, items),

      // ⑤ 页脚品牌标识（官方自营；复用 core 的雪山标，不用图片）
      _footer(),
    ];
  }

  /// 16:9 单图主图位（Hero 与列表卡封面连续过渡；无封面时**不渲染**本方法）
  Widget _hero(String url) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: T.bgCardSolid,
        child: Hero(
          tag: 'product-cover-${widget.productId}',
          child: Image.network(
            AppConfig.resolveMediaUrl(url),
            fit: BoxFit.cover,
            width: double.infinity,
            // 解码宽度按显示宽 ×2 传（1080 覆盖绝大多数机型；避免整张原图解码）
            cacheWidth: 1080,
            // 图挂了不能白屏：退化成与"没有封面"同一套空态（同一用户可见结果，不出现破图）
            errorBuilder: (_, _, _) => AppEmptyMediaBlock(
              title: '商品图加载失败',
              subtitle: '网络恢复后下拉刷新即可重新加载；下面的字段都是接口下发的真实值',
            ),
          ),
        ),
      ),
    );
  }

  /// 标题 + 价格 + 销量/事实一块（方案 G「标题/价格/销量区」）
  ///
  /// 顺序与设计稿一致：**标题 → 价格 → 徽标 + 限购 → 三列事实（已售/预计时长/服务方式）**。
  /// 价格用**大字金**（[AppColors.gold] `#F59E0B`，32px/w800 属"大字金额"档 —— ≥19px 且 w700+
  /// 才允许直接取 gold，否则必须走 [AppColors.goldText]，见 `core/test/money_gold_guard_test.dart`）；
  /// 蓝色是唯一的可操作色，全留给底部主按钮，价格不与它抢。
  Widget _priceBlock(Map<String, dynamic> p) {
    final badge = p['badgeText'] as String?;
    return Container(
      color: T.bgCardSolid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${p['name'] ?? ''}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.4, color: T.textPrimary),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fmtMoney(parsePoints(p['price'])),
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, height: 1, color: AppColors.gold),
                    ),
                    const SizedBox(width: 4),
                    // 右侧元信息：计价单位（`/单`、`/局`）—— 金额本身已含 `¥`，
                    // 不再有 `≈ N 元` 二次换算（口径 1 元 = 1 元，换算已无意义）。
                    // 方案 G：**一切"金"小字走 goldText**（单元字与价格同一支金，深一档保证可读）。
                    //
                    // ⚠️ 必须放在 `Expanded` + `Wrap` 里：窄屏（或价格位数多）时这一块放不下，
                    // 直接用 Row 会把价格行挤爆（实测 `RenderFlex overflowed by 6.6 pixels`）。
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '/${(p['priceUnit'] as String?)?.trim().isNotEmpty == true ? p['priceUnit'] : '单'}',
                              style: const TextStyle(fontSize: 12, color: AppColors.goldText),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 徽标（管理端 badgeText）与每周限购提示**都必须保留**；两者都可能不存在，
                // 都不存在时不渲染这一行（不留空行）
                if (ProductBadge.shows(badge) || _quota != null)
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (ProductBadge.shows(badge)) ProductBadge(badge),
                      if (_quota != null)
                        WeeklyLimitNote(
                          limitText: '${_quota!['limitText'] ?? ''}',
                          quotaText: '${_quota!['quotaText'] ?? ''}',
                        ),
                    ],
                  ),
              ],
            ),
          ),
          // 三列通栏**真实字段**：已售 N 单 / 预计时长 / 服务方式
          // （绝不出现"库存""日产能"：这两个字段系统里根本不存在，编出来就是假数据）
          // 组件自带顶部分隔线 → 与上方"标题/价格"之间是 1px 发丝线，不用空行分块。
          const SizedBox(height: 16),
          AppDataRow(
            items: [
              AppDataItem(label: '已售', value: '${_salesCount(p)}', valueUnit: '单'),
              AppDataItem(label: '预计时长', value: '${_estimateMinutes(p)}', valueUnit: '分钟'),
              AppDataItem(label: '服务方式', value: _serviceMethod),
            ],
          ),
        ],
      ),
    );
  }

  int _salesCount(Map<String, dynamic> p) {
    final v = p['salesCount'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  int _estimateMinutes(Map<String, dynamic> p) {
    final v = p['estimateDurationMin'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// 规格与须知分区（方案 G「用发丝线分块，不用卡片堆」）
  ///
  /// ## 为什么是"一张白面 + 发丝线"而不是"多个卡片"
  /// 旧实现是「折叠行 + 两个白块」中间夹 `AppBlockGap`（8dp 页底色缝）—— 那其实是
  /// **三张卡靠间距分开**，正是 docs/21 点名的"卡片堆"。方案 G 定案改为：
  /// **一整张白面**，分区之间只留 **1px 发丝线**（[AppColors.strokeSoft] `#E8ECF2`），
  /// 于是"块与块"的关系由**一条线**表达，而不是由"底色的空"表达。
  ///
  /// ## 段落顺序与既有实现**逐字一致**（只改视觉，不动信息结构）
  /// 下单须知（默认折叠）→ 商品说明 → 详细介绍 → 服务流程 → 服务规则 → 常见问题；
  /// 每个分区"有内容才渲染"的判定也原样保留。
  Widget _specZone(Map<String, dynamic> p, List<String> items) {
    final blocks = <(String, String)>[
      ('商品说明', '${p['description'] ?? ''}'),
      ('详细介绍', '${p['detail'] ?? ''}'),
      ('服务流程', '${p['serviceFlow'] ?? ''}'),
      ('服务规则', '${p['serviceRules'] ?? ''}'),
    ].where((e) => e.$2.trim().isNotEmpty).toList();

    final children = <Widget>[];
    // 第一个分区紧接"分区块的顶线"，不在它前面再补线（否则线与线叠成 2px）
    var firstSection = true;

    if (items.isNotEmpty) {
      // 折叠行自带上下发丝线（`AppFoldRow` 内部就是白底 + 1px 线）→ 它本身就是分区块的顶边，
      // 不需要再补一条通栏线，否则顶边会变成 2px。
      children.add(AppFoldRow(
        title: '下单须知',
        collapsed: items.first,
        footer: AppTermsList(items: items),
      ));
      firstSection = false;
    } else {
      children.add(const AppHairline());
    }

    for (final b in blocks) {
      if (!firstSection) children.add(const AppHairline(indent: 16));
      firstSection = false;
      children
        ..add(AppBlockTitle(title: b.$1))
        ..add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            b.$2,
            style: TextStyle(fontSize: 12, height: 1.8, color: T.textSecondary),
          ),
        ));
    }

    if (!firstSection) children.add(const AppHairline(indent: 16));
    children
      ..add(const AppBlockTitle(title: '常见问题'))
      ..add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: AppFaqBlock(items: _faqItems, expanded: _faqOpen, onToggle: _toggleFaq),
      ));

    return Container(
      color: T.bgCardSolid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppMountainMark(size: 15, color: T.textTertiary, snowColor: T.textTertiary),
          const SizedBox(width: 6),
          Text(
            '祁连山电竞 · 官方自营',
            style: TextStyle(fontSize: 11, color: T.textTertiary),
          ),
        ],
      ),
    );
  }
}
