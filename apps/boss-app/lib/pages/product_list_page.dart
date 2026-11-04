import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/division_platform_label.dart';
import 'division_construction_page.dart';
import 'product_detail_page.dart';

/// 底部购买提示条的测试锚点（空文案时**整条不构造**，见 `_ProductListPageState._purchaseHintBar`）
const Key purchaseHintBarKey = Key('purchase-hint-bar');

/// 商品列表（负责人 2026-10-04：完全仿参考 App 的「分类」页结构，但用本项目的青蓝主题重绘）
///
/// 结构（仿参考）：
/// - 顶部：**专区圆形图**胶囊行（图来自管理端 `division.iconMediaId`，无图回退渐变色块）
/// - 左侧：分类竖排栏（选中项左侧竖条 + 高亮）
/// - 右侧：商品卡（封面图 + 标题两行 + 销量 + 价格 + 下单按钮）
///   - **点卡与点右下「下单」都进商品详情页**（`_openDetail`，负责人 2026-10-05 复报
///     「点下单也要弹到图二页面」）；确认订单页只由详情页底部「立即购买」进入
/// - 排序：综合 / 销量 / 价格
/// - 底部：**购买提示小字**（负责人 2026-10-05，文案来自 `GET /public/purchase-hint`，空则不渲染）
///
/// 数据全部来自服务端（商品/分类/分部/排序/购买提示），客户端不写死任何展示内容。
class ProductListPage extends StatefulWidget {
  const ProductListPage({super.key, this.api, this.initialDivisionId});

  final ApiClient? api;
  final String? initialDivisionId;

  @override
  State<ProductListPage> createState() => _ProductListPageState();
}

class _ProductListPageState extends State<ProductListPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  List<_Division> _divisions = [];
  List<_Category> _categories = [];
  List<_Product> _products = [];
  String? _divisionId;
  String? _categoryId;
  String _sort = 'default'; // default 综合 / sales 销量 / priceAsc 价格
  bool _loading = true;
  String? _error;

  /// 按「分部|分类」缓存商品列表 —— 切专区/切分类**瞬间出内容**（视频里就是这种手感）
  final Map<String, List<_Product>> _productsByKey = {};

  /// 后台刷新中（列表保持可见，只在标题行显示细进度，不整页转圈）
  bool _refreshing = false;

  /// 购买提示小字（负责人 2026-10-05；口径 2026-10-09 = 余额、1 元 = 1 元）：
  /// 「下单均使用余额…」——文案**完全来自服务端** `GET /public/purchase-hint`
  /// 的 `data.text`（平台级常驻提示：联系人会换人、口径会变，故与
  /// `order_notice_default`、`platform_commission_rate` 同一套做法，后台可改、App 不发版）。
  ///
  /// ⚠️ 服务端那段常量若还写着「10 积分等于 1 人民币」，页面会**逐字显示**旧口径
  /// （客户端不裁剪服务端文案）—— 需服务端同步改文案，见本次交付报告的"未做/风险"。
  ///
  /// **客户端一个字的兜底文案都没有**：拿不到（未登录/网络失败/接口 404）或服务端给了空串
  /// → 保持空串 → 底部**整行不渲染**（见 `build` 里的 `_purchaseHint.isNotEmpty` 判定）。
  /// 「空 = 整行不渲染」同时是**运营主动关闭这行提示**的合法状态（充值活动暂停时清空保存即可）。
  String _purchaseHint = '';

  @override
  void initState() {
    super.initState();
    _divisionId = widget.initialDivisionId;
    unawaited(_loadAll());
  }

  Future<void> _loadAll() async {
    /**
     * 【2026-10-15 秒刷专项 · 缓存优先】
     *
     * 本页首屏天然是**两跳**（商品列表要按「分部 + 分类」查，而分类来自 `/public/categories`、
     * 分部来自 `/divisions`）—— 这不改接口就消不掉（服务端没有"一次拿全"的货架接口）。
     * 因此这里换一条路：**先把上一次的货架画上（0 请求、0 等待）**，网络回来原地替换。
     * 用户感知从"进页两跳白屏"变成"进页秒出 + 顶部一条细进度"。
     *
     * 全部读的是**真 ApiCache**（键与 [ApiClient.request] 同源）；本次运行内没拉到过任何一份
     * 就什么都不画，退回原来的骨架屏（不猜、不编）。
     */
    _paintFromCache();
    setState(() {
      _loading = _products.isEmpty;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.request('GET', '/divisions'),
        _api.request('GET', '/public/categories'),
        /**
         * 购买提示（负责人 2026-10-05）：与上面两个请求**同一批并发**发出 ——
         * 首屏等待取决于最慢的那个，**不是串行多一跳**（三个都是公开字典级接口，
         * 服务端有 `PublicCacheInterceptor` 微缓存，实测 2ms 量级）。
         *
         * 为什么单开一个接口而不是挂在 `/divisions`、`/public/categories` 上：
         * 那两个接口返回的是**裸数组**（分部/分类实体数组），要塞平台级文案就得改成
         * `{list, purchaseHint}` 信封 —— 那是破坏性改形状（服务页/工作端大厅/官网全要跟着改），
         * 而"每个分部/每个分类各带一份同样的文案"是纯浪费。`/public/products` 更不行：
         * 它 1792000000000 做过列裁剪性能专项，50 条商品就是同一句话重复 50 遍。
         *
         * 单独 `.catchError` 兜底：**这一行取不到不能让整页报错**（原样留空串 → 不渲染），
         * 也不影响商品/分类的正常展示。
         */
        _api.request('GET', '/public/purchase-hint').catchError((_) => <String, dynamic>{}),
      ]);
      final divs = ((results[0]['data'] as List?) ?? const [])
          .map((e) => _Division.fromJson(e as Map))
          .toList();
      final cats = _dedupeCategories(((results[1]['data'] as List?) ?? const [])
          .map((e) => _Category.fromJson(e as Map)));
      // 购买提示：服务端 `data.text`（空/缺失一律当"没有提示"），trim 掉管理端误敲的首尾空白
      final hint = '${((results[2]['data'] as Map?)?['text'] ?? '')}'.trim();
      final firstDiv = _divisionId ?? (divs.isNotEmpty ? divs.first.id : null);
      final gameId = divs.firstWhere((d) => d.id == firstDiv, orElse: () => divs.first).gameId;
      final gameCats = _categoriesOf(cats, gameId);
      if (!mounted) return;
      setState(() {
        _divisions = divs;
        _divisionId = firstDiv;
        _categoriesAll = cats; // 全量留存：切分部时按 gameId 过滤（此前漏赋值 → 切分部分类会空）
        _categories = gameCats;
        _categoryId = gameCats.isNotEmpty ? gameCats.first.id : null;
        _purchaseHint = hint;
      });
      await _loadProducts();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 缓存优先先画（**同步、0 请求**）：分部/分类/商品三份缓存都在时，首帧就有内容
  ///
  /// 为什么允许"重新推一遍"这些推导（分部→gameId→分类→商品键）：本方法**只读缓存、只用于先行渲染**，
  /// 推导与实际请求不一致的最坏后果是"没命中 → 退回骨架屏"，不会把别的分部/分类的商品亮出来
  /// （商品键里同时带 divisionId 与 categoryId）。真正的请求构造口径仍然只有 `_loadProducts` 一处。
  void _paintFromCache() {
    if (_products.isNotEmpty) return;
    final divPeek = _api.peekCache('/divisions');
    final catPeek = _api.peekCache('/public/categories');
    if (divPeek == null || catPeek == null) return;
    final List<_Division> divs;
    final List<_Category> cats;
    try {
      divs = ((divPeek.body['data'] as List?) ?? const []).map((e) => _Division.fromJson(e as Map)).toList();
      cats = ((catPeek.body['data'] as List?) ?? const []).map((e) => _Category.fromJson(e as Map)).toList();
    } catch (_) {
      return; // 缓存形状不认识：不画（退回骨架屏），绝不让首屏抛异常
    }
    if (divs.isEmpty) return;
    final String firstDiv = _divisionId ?? divs.first.id;
    final String gameId = divs.firstWhere((d) => d.id == firstDiv, orElse: () => divs.first).gameId;
    final gameCats = _categoriesOf(_dedupeCategories(cats), gameId);
    final String? firstCat = _categoryId ?? (gameCats.isNotEmpty ? gameCats.first.id : null);
    final peek = _api.peekCache('/public/products', <String, dynamic>{
      'divisionId': firstDiv,
      'categoryId': ?firstCat,
      'page': 1,
      'pageSize': 50,
    });
    if (peek == null) return;
    final data = (peek.body['data'] as Map?) ?? const {};
    final list = (data['list'] as List?) ?? const [];
    final items = list.map((e) => _Product.fromJson(e as Map)).toList();
    if (!mounted) return;
    setState(() {
      _divisions = divs;
      _categoriesAll = cats;
      _categories = gameCats;
      _divisionId = firstDiv;
      _categoryId = firstCat;
      _productsByKey['$firstDiv|${firstCat ?? ''}|$_sort'] = items;
      _products = _applySort(items);
      _loading = false;
      _refreshing = true; // 屏上是旧数据 → 顶部细进度亮起（`_loadProducts` 回来即熄灭）
    });
  }

  String get _listKey => '${_divisionId ?? ''}|${_categoryId ?? ''}|$_sort';

  Future<void> _loadProducts({bool force = false}) async {
    // 建设中分部（负责人 2026-10-05）：本分部**没有商品**，货架请求打出去必然是空列表，
    // 白跑一次网络还多一次 loading 闪烁 —— 直接短路，页面在内容区渲染「建设中」内容。
    if (_currentDivision?.underConstruction == true) {
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshing = false;
          _products = const [];
        });
      }
      return;
    }
    // ① 命中本地缓存：立即上屏（0 等待），非强制时不打网络
    final cached = _productsByKey[_listKey];
    if (cached != null && !force) {
      setState(() {
        // 关键修复：缓存里存的是原始顺序，展示前必须按当前排序再排一次
        _products = _applySort(cached);
        _loading = false;
        // 缓存优先先画时点亮的"正在刷新"细进度必须在这里熄灭（否则它会一直挂着）
        _refreshing = false;
      });
      return;
    }
    // ② 已有内容时只显示"刷新中"，列表保持可见（不再整页白屏）
    setState(() {
      if (_products.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
    });
    try {
      final resp = await _api.request('GET', '/public/products', queryParameters: {
        if (_divisionId != null) 'divisionId': _divisionId,
        if (_categoryId != null) 'categoryId': _categoryId,
        'page': 1,
        'pageSize': 50,
      }, forceRefresh: force);
      final list = ((resp['data'] as Map?)?['list'] as List?) ?? const [];
      final items = list.map((e) => _Product.fromJson(e as Map)).toList();
      final sorted = _applySort(items);
      _productsByKey[_listKey] = items; // 缓存**原始顺序**数据；排序一律在读取时应用
      final sortedList = sorted;
      // 预热首屏图片到磁盘（图片也不再冷启动重下）
      unawaited(ImageDiskCache.instance.warmUp(items.take(8).map((e) => e.coverUrl ?? '')));
      if (!mounted) return;
      setState(() {
        _products = sortedList;
        _loading = false;
        _refreshing = false;
      });
      unawaited(_prefetchSiblingCategories());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = _products.isEmpty ? e.toString() : null;
      });
    }
  }

  /// 统一排序入口（综合 / 销量 / 价格升降）—— 读缓存与读网络都必须经过它，
  /// 否则预取进来的原始顺序会让"排序失效"（2026-10-04 负责人反馈的 bug）
  List<_Product> _applySort(List<_Product> items) {
    final out = List<_Product>.of(items);
    switch (_sort) {
      case 'sales':
        out.sort((a, b) => b.salesCount.compareTo(a.salesCount));
      case 'priceAsc':
        out.sort((a, b) => a.price.compareTo(b.price));
      case 'priceDesc':
        out.sort((a, b) => b.price.compareTo(a.price));
      default:
        break;
    }
    return out;
  }

  /// 后台预取同一分部下的其余分类（用户点左侧分类时也是瞬间出内容）
  Future<void> _prefetchSiblingCategories() async {
    for (final c in _categories) {
      if (c.id == _categoryId) continue;
      final key = '${_divisionId ?? ''}|${c.id}|$_sort';
      if (_productsByKey.containsKey(key)) continue;
      try {
        final resp = await _api.request('GET', '/public/products', queryParameters: {
          if (_divisionId != null) 'divisionId': _divisionId,
          'categoryId': c.id,
          'page': 1,
          'pageSize': 50,
        });
        final list = ((resp['data'] as Map?)?['list'] as List?) ?? const [];
        _productsByKey[key] = list.map((e) => _Product.fromJson(e as Map)).toList();
      } catch (_) {
        // 预取失败不影响主流程
      }
    }
  }

  Future<void> _switchDivision(_Division d) async {
    final cats = _categoriesOf(_categoriesAll, d.gameId);
    setState(() {
      _divisionId = d.id;
      _categories = cats;
      _categoryId = cats.isNotEmpty ? cats.first.id : null;
    });
    await _loadProducts(); // 命中缓存则瞬间上屏，未命中才拉网络
  }

  /// 全量分类（服务端返回），切分部时按 gameId 过滤
  List<_Category> _categoriesAll = const [];

  /// **分类唯一来源 = 管理端配置**：`GET /public/categories`（分类由管理端「游戏 › 分类」维护，
  /// 服务端读 `category` 表 `status=1` 的行）。客户端**不写死任何分类名**、也不做默认兜底分类 ——
  /// 管理端没配就一个都不显示（页面显示"该分类暂无商品"空态，而不是编一条出来）。
  ///
  /// 为什么不再叠加 `/divisions/grouped` 里的 categories：那是同一张表的另一条投影，
  /// 两路合并才是"分类出现两次"的温床；本页只认这一路。
  ///
  /// ### 按 id 去重（负责人：「护航带打」出现了两次）
  ///
  /// 口径（照负责人原话）：**按 id**，不是按名字 ——
  /// - 服务端 `/public/categories` 是裸 `find()`，没有 `DISTINCT`：一旦库里有重复行，
  ///   它原样透传，客户端得自己收口；
  /// - 用 id 当键（`Map` 保序，`putIfAbsent` 留第一条）：同一 id 出现多次只留一条，
  ///   **顺序仍按服务端 `sortOrder`**，不会因为去重把左侧导航重排；
  /// - 刻意**不**按名字合并：两条 id 不同、名字相同的分类是管理端建了两条，
  ///   该在管理端删（客户端合并会让"管理端看到 2 条、App 只显示 1 条"变成新的对不上）。
  ///
  /// 说明：`id` 是字符串（`'${json['id']}'`，服务端雪花/自增都可能），所以 Map 的键就是
  /// id 字符串本身 —— 与"按 int id 去重"是同一个语义（只认身份、不认名字）。
  static List<_Category> _dedupeCategories(Iterable<_Category> items) {
    final Map<String, _Category> byId = <String, _Category>{};
    for (final c in items) {
      byId.putIfAbsent(c.id, () => c);
    }
    return byId.values.toList(growable: false);
  }

  /// 某个游戏下的分类（管理端可把分类挂在具体游戏；`gameId` 为空的旧数据视为通用分类）
  static List<_Category> _categoriesOf(List<_Category> all, String gameId) =>
      _dedupeCategories(all.where((c) => c.gameId == gameId || c.gameId.isEmpty));

  /// 当前选中的分部（平台标识用；找不到返回 null，此时不显示标识）
  _Division? get _currentDivision {
    for (final d in _divisions) {
      if (d.id == _divisionId) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 页面里所有卡片/胶囊/商品块仍是实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(58),
        child: Container(
          color: T.bgCardSolid,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 58,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(AppIcon.arrowLeft, size: 20, color: T.textPrimary),
                    tooltip: '返回',
                  ),
                  Expanded(
                    child: Text('选择服务',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: T.textPrimary)),
                  ),
                  IconButton(
                    onPressed: _loadAll,
                    icon: Icon(AppIcon.search, size: 19, color: T.textSecondary),
                    tooltip: '刷新',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: AppPageBg(child: Column(
        children: [
          // 专区胶囊行（圆形图来自管理端；无图回退品牌渐变）
          if (_divisions.isNotEmpty)
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                itemCount: _divisions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 18),
                itemBuilder: (_, i) {
                  final d = _divisions[i];
                  final on = d.id == _divisionId;
                  return GestureDetector(
                    onTap: () => _switchDivision(d),
                    child: Column(
                      children: [
                        SizedBox(
                          width: 54,
                          height: 54,
                          // 圆形容器只负责裁剪与选中描边；4px 内边距让描边不挤压圆形图标块
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: on ? T.primary : Colors.transparent, width: 2),
                              ),
                              clipBehavior: Clip.antiAlias,
                              // 专区圆形图：**管理端挂了官方图就用图**（`/divisions` 的 iconMediaId/coverMediaId，
                              // 磁盘缓存秒开）；无图回退原来的游戏图标块（此前是所有分部同一个通用盾牌图标）
                              // 54px 圆内不贴「端」角标（会被圆裁掉、且文字只有 9px 不可读）
                              child: GameIconTile(
                                gameKey: d.gameKey,
                                platform: d.platform,
                                color: d.color,
                                size: 54,
                                radius: 27,
                                badge: false,
                                mediaId: d.imageMediaId,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          d.shortName,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                            color: on ? T.primary : T.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          // 当前分部的平台标识（负责人 2026-10-04：选择服务上方要标明是手游还是端游）
          // 数据来自管理端：分部 shortName + platformLabel（如「三角洲行动 · 端游」）
          // 本轮按方案 G 对齐成胶囊：**选中态 = 主色实底白字**（这枚永远表示"当前正在看的分部"）
          if (_currentDivision != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _platformPill(_currentDivision!, selected: true),
              ),
            ),
          // 发丝线分组①：顶部信息（专区 / 平台）｜ 筛选区
          // 方案 G：「不要靠页底色缝隙分组」—— 页底与卡片都是浅色时，缝隙分不出组，必须有一条 1px 线
          const AppHairline(),
          // 后台刷新细进度条（仿视频：切内容不白屏，只有一条极细进度）
          SizedBox(
            height: 2,
            child: _refreshing
                ? LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent, color: T.primary)
                : const SizedBox.shrink(),
          ),
          // 排序行（建设中分部不显示：没有商品可排）
          if (_currentDivision?.underConstruction != true) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  _sortChip('综合', 'default'),
                  const SizedBox(width: 8),
                  _sortChip('销量', 'sales'),
                  const SizedBox(width: 8),
                  _sortChip(_sort == 'priceDesc' ? '价格 ↓' : '价格 ↑', _sort == 'priceDesc' ? 'priceDesc' : 'priceAsc'),
                  const Spacer(),
                  // 排序的方向感图标（稿内 `.pill` 行尾那枚）：只表态"这一行可筛"，不新增可点入口
                  AppIcon.of(AppIcon.filter, size: 15, color: T.textTertiary),
                ],
              ),
            ),
            // 发丝线分组②：筛选区 ｜ 内容区
            const AppHairline(),
            // 分区标题条：`▍标题 + 右侧淡色副标`（数字全部来自服务端返回的本页商品）
            _sectionHeader('全部商品', _products.isEmpty ? null : '共 ${_products.length} 件'),
          ],
          Expanded(
            // 兜底拦截（负责人 2026-10-05）：正常路径上服务页已把建设中分部导向建设中页，
            // 但深链/胶囊行切分部/管理端刚把分部切成建设中都可能落到这里 —— 此时**不显示空货架**，
            // 而是渲染同一份「建设中」内容（文案仍取服务端 noticeText），并提供返回按钮。
            child: _currentDivision?.underConstruction == true
                ? DivisionUnderConstructionView(
                    name: _currentDivision!.name,
                    shortName: _currentDivision!.shortName,
                    platform: _currentDivision!.platform,
                    platformLabel: _currentDivision!.platformLabel,
                    gameKey: _currentDivision!.gameKey,
                    color: _currentDivision!.color,
                    imageMediaId: _currentDivision!.imageMediaId,
                    noticeText: _currentDivision!.noticeText,
                  )
                : (_loading && _products.isEmpty)
                ? Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary))
                : _error != null && _products.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.error)),
                              const SizedBox(height: 12),
                              FilledButton(onPressed: _loadAll, child: const Text('重试')),
                            ],
                          ),
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 左侧分类竖排栏（仿参考；方案 G：侧栏浅底 + 选中项白底 + 左侧 3px 主色竖条）
                          Container(
                            width: 96,
                            // 侧栏底 = 区块浅底（稿内 `#EFF2F6`；色板对应档 [AppColors.fieldBg] `#F1F4F8`，ΔRGB=(2,2,2)）
                            // 选中项是**白底**：白卡浮在浅灰侧栏上，选中态才立得住（纯白栏上只能靠竖条）
                            color: AppColors.fieldBg,
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: _categories.length,
                              itemBuilder: (_, i) {
                                final c = _categories[i];
                                final on = c.id == _categoryId;
                                return GestureDetector(
                                  onTap: () {
                                    setState(() => _categoryId = c.id);
                                    unawaited(_loadProducts());
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                                    decoration: BoxDecoration(
                                      // 选中 = 白底 + 左侧 3px 主色竖条（稿内 `box-shadow: inset 3px 0 0 #2563EB`）
                                      color: on ? T.bgCardSolid : Colors.transparent,
                                      border: Border(
                                        left: BorderSide(color: on ? T.primary : Colors.transparent, width: 3),
                                      ),
                                    ),
                                    child: Text(
                                      c.name,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        // 选中 = 墨蓝加粗（`brandInk` `#0F2440` 与稿内逐值相同）；
                                        // 未选中走次级文字（稿内 `#6B7A8C`，色板无同值档，取同语义的
                                        // [T.textSecondary]，浅灰侧栏上对比度 7:1+ 而不是 2.6:1）
                                        fontWeight: on ? FontWeight.w800 : FontWeight.w400,
                                        color: on ? AppColors.brandInk : T.textSecondary,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          // 右侧商品卡（仿参考：封面 + 标题 + 销量 + 价格 + 下单）
                          Expanded(
                            // 图案底纹只铺在**内容区底部空白带**：卡片是不透明白面，正常滚动时底纹
                            // 全被卡片挡住，只有"商品少 / 滚到底"留下的空白处才透出来 —— 不压文字
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_products.isNotEmpty)
                                  IgnorePointer(child: CustomPaint(painter: _DotBandPainter(color: T.primary))),
                                _products.isEmpty
                                    ? const AppEmpty(icon: AppIcon.empty, text: '该分类暂无商品')
                                    : ListView.separated(
                                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                                        // +1 = 列表尾部那条「平台保障」说明（不是卡片，不占 AppCard 计数）
                                        itemCount: _products.length + 1,
                                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                                        itemBuilder: (_, i) => i == _products.length
                                            ? _guaranteeRow()
                                            : StaggeredItem(index: i, child: _productCard(_products[i])),
                                      ),
                              ],
                            ),
                          ),
                        ],
                      ),
          ),
          // 购买提示小字（负责人 2026-10-05）：**贴屏幕底部常驻**，而不是塞进排序行下方
          //
          // 位置理由（三条，按权重）：
          // ① **不挤压首屏**：本页首屏纵向预算已经很紧（58 标题 + 92 专区胶囊 + 平台标识 + 排序行
          //    ≈ 222dp），再往上加两行说明会把商品卡第一行整体推下去；放底部则是从**列表视口**里借，
          //    商品列表第一行的 y 坐标一点不动，首屏信息结构不变。
          // ② **不与筛选控件混装**（CLAUDE.md 结构规则 3）：它既不是排序项也不是分类项。
          //    紧贴排序胶囊下方（那一段是"组内紧 8–10"）会被读成"排序的第四个选项"；
          //    底部独立成条 + 一条发丝线分隔，分组语义清楚（组间松）。
          // ③ **离「下单」最近**：商品卡的下单按钮在卡片右下角，滚动时始终落在屏幕下半部 ——
          //    提示常驻底部，正好是点下单前视线必经的位置。
          //
          // 样式（docs/21 反 AI 味）：11.5px / 常规字重 / **无图标 / 无彩色底 / 无圆角块 / 不加粗**，
          // 只用一条发丝线（`T.divider`）与列表同一套分隔语言。
          // 颜色取 `textSecondary`（`AppColors.textSecondary`）而不是 `textTertiary`：这行字含
          // "充值联系人 + 余额口径"，是**要看清才敢下单**的信息；`textTertiary` 在冷灰蓝底上对比度约 2.6:1
          // （低于 WCAG AA 4.5:1），11.5px 下过于虚。
          //
          // 建设中分部的页面**不显示**这行（那种分部不能下单，显示"如需下单请联系…充值"自相矛盾）；
          // 空串同样整行不渲染（见 `_purchaseHint` 注释与这里的判定）。
          if (_purchaseHint.isNotEmpty && _currentDivision?.underConstruction != true) _purchaseHintBar(),
        ],
      )),
    );
  }

  /// 底部购买提示条：**文案 100% 来自服务端**（`GET /public/purchase-hint` 的 `data.text`）
  ///
  /// 空值由调用方拦截（`_purchaseHint.isNotEmpty`）→ 本 widget 一旦构造就一定有文案，
  /// 因此这里**没有任何兜底文案分支**，也不存在"接口挂了显示一句客户端文案"的路径。
  ///
  /// 行数上限 2 行、**不加省略号**（负责人：「长文案允许 2 行、不许截断」）：
  /// 用 [TextOverflow.fade] 而不是 `ellipsis` —— 万一运营把文案写到超 2 行，
  /// 末行淡出看起来是"刻意收口"，且绝不会出现「…」；正式默认文案在 360dp 机型上
  /// 正好 2 行且未越界（`test/product_purchase_hint_test.dart` 用 RenderParagraph
  /// 的 didExceedMaxLines 锁死这一点）。
  Widget _purchaseHintBar() {
    return Container(
      // 测试锚点：空串时**整个条**都不构造（`find.byKey(purchaseHintBarKey)` findsNothing），
      // 断言"整行不渲染"比断言"某段文字找不到"更贴近需求语义
      key: purchaseHintBarKey,
      width: double.infinity,
      decoration: BoxDecoration(
        // 与页面同底色（不是彩色条、不是卡片）：提示靠"位置 + 发丝线"成立，不靠装饰。
        // 2026-10-17 页底换成渐变后，这里的取值从 `T.scaffoldColor` 改为 `Colors.transparent`：
        // 页面 Scaffold 已是透明（底色由 `AppPageBg` 画），透明条才真正"与页面同底色"，
        // 不会在渐变上留一条突兀的白带（`product_purchase_hint_test` 的等式断言仍然逐字成立）。
        color: Colors.transparent,
        border: Border(top: BorderSide(color: T.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          // 上 9 / 下 10：与标题行、排序行的 10 同一档呼吸感，不额外制造大留白
          padding: const EdgeInsets.fromLTRB(16, 9, 16, 10),
          child: Text(
            _purchaseHint,
            maxLines: 2,
            overflow: TextOverflow.fade,
            style: TextStyle(fontSize: 11.5, height: 1.45, color: T.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 排序胶囊（综合 / 销量 / 价格↑↓）
  ///
  /// 方案 G 定案：**选中 = 主色实底白字**，未选中 = **白底 + 1px `strokeSoft` 描边 + 次级文字**。
  /// 两者形状同为胶囊（`#FFF` 底的那一颗描边还在，只是从发丝线换成更浅的 `strokeSoft`，
  /// 让"选中/未选中"只差**一次填色**，不靠加粗/加框这种第二套语言）。
  Widget _sortChip(String label, String key) {
    final on = _sort == key || (key == 'priceAsc' && _sort == 'priceDesc');
    return GestureDetector(
      onTap: () {
        setState(() {
          if (key == 'priceAsc') {
            _sort = _sort == 'priceAsc' ? 'priceDesc' : 'priceAsc';
          } else {
            _sort = key;
          }
        });
        unawaited(_loadProducts());
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: on ? T.primary : T.bgCardSolid,
          borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
          border: Border.all(color: on ? T.primary : AppColors.strokeSoft),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? Colors.white : T.textSecondary)),
      ),
    );
  }

  /// 当前分部的平台标识胶囊（负责人 2026-10-04 引入，本轮按方案 G 对齐选中态）
  ///
  /// - **选中**（当前正在看的分部）= 主色实底 + 白字；
  /// - **未选中** = 白底 + 1px [AppColors.strokeSoft] 描边 + 次级文字。
  ///
  /// 本页只渲染"当前分部"这一枚（多分部的切换仍由上方圆形胶囊行承担 ——
  /// CLAUDE.md 结构规则 1：同一入口只出现一次），`selected` 形参保留两支，
  /// 是为了把两档样式写成同一处口径，而不是散在两个地方各写一半。
  ///
  /// ⚠️ **Key 仍是 [DivisionPlatformLabel.labelKey]**：`division_platform_label_test` 用这个 Key
  /// 取"平台标识那一行"并断言文案（`和平精英 · 手游` / `三角洲行动 · 端游`）。
  /// 本轮只允许改本文件，故胶囊外观在本页落地、文案规则仍复用
  /// [DivisionPlatformLabel] 的 `text`（**不在页面里重抄一遍拼接规则**）。
  Widget _platformPill(_Division d, {required bool selected}) {
    // 文案规则只有一份（`DivisionPlatformLabel.text`）：这里只借它的字符串，不构造那个白底条
    final label = DivisionPlatformLabel(
      name: d.name,
      shortName: d.shortName,
      platformLabel: d.platformLabel,
    ).text;
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      key: DivisionPlatformLabel.labelKey,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? T.primary : T.bgCardSolid,
        borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
        border: Border.all(color: selected ? T.primary : AppColors.strokeSoft),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.2,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? Colors.white : T.textSecondary,
        ),
      ),
    );
  }

  /// 分区标题条：`▍标题 + 右侧淡色副标`（方案 G `.sh` 的拆法）
  ///
  /// 竖标 **3px**（与左侧导航选中条、稿内 `inset 3px 0 0` 同一个 3）：
  /// 装饰系统里的 [AppBrandBar] 断言"宽高必须落 4dp 网格"（4×16），表达不了 3px，
  /// 所以这里自绘一枚 3px 实色条 —— 不是绕开装饰系统，是那一档口径不同。
  Widget _sectionHeader(String title, String? trailing) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Container(width: 3, height: 14, color: T.primary),
          const SizedBox(width: 8),
          // 标题 14 粗、墨蓝（稿内 `.sh b` = `#0F2440` = [AppColors.brandInk]，逐值相同）
          Text(title,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.brandInk, height: 1.2)),
          const Spacer(),
          if (trailing != null)
            Text(trailing, style: TextStyle(fontSize: 11, color: T.textTertiary, height: 1.2)),
        ],
      ),
    );
  }

  /// 列表尾部「平台保障」一行（方案 G 分类页底部那两条：图标语义色 + 短语）
  ///
  /// 两条都是**平台承诺**（不是商品数据），所以整行由一个发丝线与商品卡分开、**不做卡片**
  /// （不占 `AppCard` 计数，也不与商品卡争视线）。图标色分工：
  /// 安全绿 [AppColors.entrySupport] / 主色蓝 [T.primary] ——
  /// 2 个 token 在色板里本来就是"入口图标语义色"这一档，不是新造颜色。
  ///
  /// **不许再出现「N 倍赔付」这一类表述**（负责人已三次强调：一切赔付文案不许写，
  /// 2026-10-18 真机复报就是这里漏了）。剩下的两条（全程录屏 / 5 分钟介入）**不涉及赔付**，
  /// 是纯服务承诺，保留；任何"赔 / 3 倍 / 三倍 / 五倍 / 5 倍"的字样都不得回流到这一行。
  Widget _guaranteeRow() {
    final items = <(IconData, Color, String)>[
      (AppIcon.shield, AppColors.entrySupport, '全程录屏'),
      (AppIcon.clock, T.primary, '5 分钟介入'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
      child: Column(
        children: [
          const AppHairline(),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final (icon, color, text) in items)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon.of(icon, size: 13, color: color),
                    const SizedBox(width: 4),
                    Text(text, style: TextStyle(fontSize: 10.5, color: T.textSecondary)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 无封面时的游戏图标块（商品 → 所属分部的 gameKey/platform/themeColor/**官方图**）
  ///
  /// 分部对照表已在本页加载（专区胶囊行同一份 `_divisions`）；对照不到时传 null，
  /// GameIconTile 走兜底图标 + 稳定品类色，不会崩也不会猜。
  Widget _gameCover(_Product p, double size) {
    final d = _divisionOf(p);
    return GameIconTile(
      gameKey: d?.gameKey ?? p.gameId,
      platform: d?.platform,
      color: d?.color,
      size: size,
      radius: 10,
      // 管理端给该分部挂了官方游戏图 → 商品卡直接用图（端游仍在图片底部叠「端」角标）
      mediaId: d?.imageMediaId,
    );
  }

  /// 商品所属分部（按 divisionId 对照本页分部列表；找不到按 gameId 退一步匹配同游戏分部）
  _Division? _divisionOf(_Product p) {
    if (p.divisionId != null && p.divisionId!.isNotEmpty) {
      for (final d in _divisions) {
        if (d.id == p.divisionId) return d;
      }
    }
    if (p.gameId.isNotEmpty) {
      for (final d in _divisions) {
        if (d.gameId == p.gameId) return d;
      }
    }
    return null;
  }

  /// 商品卡（方案 G 形态：白底 + 1px 描边 + 圆角 12 + **无阴影**）
  ///
  /// 三处口径，逐条说清：
  /// - **圆角 12 / 白底**：稿内 `.prow`/`.gcard` 这一档就是 12（不是全站 16 那一档）；
  /// - **描边**：有徽标的卡仍是 1px 琥珀金（[productCardBorder] 的既有语义，`product_badge_*`
  ///   逐值断言过），其余卡走同一函数的发丝线档 —— `T.divider` `#E9EEF5` 与稿内 `#E8ECF2`
  ///   ΔRGB=(1,2,3)，肉眼不可分，而 `product_badge_limit_test` 把普通卡描边逐值钉在
  ///   `T.divider` 上，故**不为了 1 个通道差去动别人家断言**；
  /// - **无阴影**：[AppCard] 自带一层 4% 阴影（core 本轮禁改），外面套同半径的 [ClipRRect]
  ///   把那层溢出到卡外的阴影裁掉 —— 卡片回到"白面浮在页底上"的 G 形态，零 core 改动。
  Widget _productCard(_Product p) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AppCard(
        padding: const EdgeInsets.all(10),
        radius: 12,
        // 置顶/推荐商品（服务端下发 badgeText）换 1px 琥珀金描边：长列表里"一眼看到"，
        // 但**不用渐变/阴影/加粗底色**（docs/21 反 AI 味：突出靠结构信号，不靠装饰堆叠）
        border: productCardBorder(p.badgeText),
        // 整卡点击 → **商品详情页**（负责人 2026-10-05 方案 B：用户要先看详情再决定，
        // 不再"点商品直接进确认订单页"）
        onTap: () => _openDetail(p),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 74,
                height: 74,
                child: p.coverUrl == null
                    // 无管理端封面 → 用该商品所属**分部**的游戏图标（端游带「端」角标）
                    ? _gameCover(p, 74)
                    : CachedNetImage(url: p.coverUrl!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // 徽标在商品名**上方**（左上角）：文案由管理端配（badgeText），空则不渲染任何东西
                if (ProductBadge.shows(p.badgeText)) ...[
                  ProductBadge(p.badgeText),
                  const SizedBox(height: 5),
                ],
                // 商品名：**最多 4 行**（负责人 2026-10-05 二次报障「最长的两个博弈单名还是被截断」）
                //
                // 现场测算（flutter test 360×780 真机尺寸 + 系统黑体）：左侧分类栏占位后
                // 卡片仅 **240dp**、名字可用宽 ≈134dp → 13.5px 汉字每行 ≈9.9 字，
                // 45 / 49 字的博弈单名（36.6博弈宝冠单… / 44.6博弈鹰雕单…）需要**第 4 行**才放得下，
                // 3 行必截断（实测 didExceedMaxLines=true）。故上限放到 4 行。
                // 字号/行高（13.5 / 1.35）保持不变 —— 靠"多给行数"解决，不靠放大字号（docs/21 克制）；
                // 卡片高度仍随内容自适应，价格与下单按钮在名字**下方**，不会被压住。
                //
                // 显示优先级（负责人 2026-10-05 任务②）：**列表页优先用管理端配的「列表短名」
                // listName，留空回退完整 name**。详情页 / 确认订单页 / 订单页一律仍显示完整 name
                // （详情页拿到的是 p.name 而不是短名），短名只在"窄卡列表"这一处生效。
                Text(p.listDisplayName,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.35, color: T.textPrimary)),
                if (p.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // 副标题/说明：最多 2 行（同上：先给行数，不动字号）
                  Text(p.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: T.textTertiary, height: 1.4)),
                ],
                const SizedBox(height: 8),
                // 发丝线分组③：**文字信息块 ｜ 价格与动作块**。
                // 方案 G 明说"不要靠页底色缝隙分组"：卡内这两块底色相同，只靠 8dp 间距会被读成一整段，
                // 一条 1px 线就把"看清楚 / 决定下单"两件事分开（不叠底色块、不加圆角片）。
                const AppHairline(),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('销量 ${p.salesCount}', style: TextStyle(fontSize: 10, color: T.textTertiary)),
                          const SizedBox(height: 4),
                          // 价格行：**黄色价格胶囊**（方案 G 定案：`#FACC15` 底 + `#3B2400` 字，
                          // 实测 9.7:1，弱光/大太阳下都读得清）——不再让金色文字裸奔在卡上。
                          //
                          // 金额串仍只由 `fmtMoney` 产出、仍走 [AppPrice]（两档金按字号自动选档的
                          // 那个组件在这里被显式指定成深棕字：胶囊底是亮黄，`goldText` 压上去只有
                          // 3.55:1，不达 AA；`pricePillInk` 是这一档的唯一正解）。
                          //
                          // ⚠️ 必须用 **Wrap** 而不是 Row：列表卡在窄屏/长价格下只剩 ~80dp，
                          // Row 会把这一行挤爆（实测 `RenderFlex overflowed`）。
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.pricePillBg,
                                  borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
                                ),
                                // 胶囊里的金额必须能被**压缩**：窄卡（240dp 卡里价格列只剩 ~65dp）
                                // 遇上 `¥366.00/单` 这种长串时，[AppPrice] 的 value+unit 是一条 Row，
                                // 硬排版会 `RenderFlex overflowed`（实测 2.5dp）。`scaleDown` 只缩不放：
                                // 正常宽度下逐像素不变，极端窄卡才等比微缩 —— 既不截断也不省略号。
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  // ⚠️ 这一行**必须保持"一行写完 AppPrice(value: fmtMoney(p.price)"**
                                  // （`balance_display_test` ③ 是源码级绑定：金额只许经 fmtMoney 产出）
                                  child: AppPrice(value: fmtMoney(p.price), unit: p.priceUnit.isEmpty ? '' : '/${p.priceUnit}', size: 13, color: AppColors.pricePillInk),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // 右下「下单」（负责人 2026-10-05 复报：**点下单也要弹到详情页**）——
                    // 与整卡 onTap **同一个方法、同一组参数**（`_openDetail`），不再直达确认订单页。
                    // 文案仍叫「下单」：用户心智是"下单入口"，且改字会动按钮尺寸/观感（视觉零回归）。
                    GestureDetector(
                      onTap: () => _openDetail(p),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          gradient: T.brandGradient,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Text('下单',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
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

  /// **本页唯一的商品入口**：点卡 or 点右下「下单」都走这里 → 商品详情页
  /// （负责人 2026-10-05 方案 B + 同日复报「点下单也要弹到图二页面」）
  ///
  /// 参数：**整卡与右下「下单」按钮传的是完全同一组**（同一处调用 `_openDetail(p)`，
  /// 不存在两条分支也就不会漏字段）。`ProductDetailPage` 的全部入参只有三个 ——
  /// `productId`（它的**唯一权威来源**：详情/限购额度都用它回源 `GET /public/products/:id`）
  /// 与 `initialName` / `initialCoverUrl`（只用于接口回来之前的加载态占位）。
  ///
  /// 列表接口那份数据是**裁剪过的**（列表档 `/public/products` 只有卡片要的字段），
  /// 所以价格/原价/须知/超时小时数/服务方式/徽标/每周限购一律**由详情页自己回源**，
  /// 绝不把列表值当详情用 —— 详情页因此不需要（也不该接受）这些字段的"预填"。
  /// 确认订单页仍由详情页底部「立即购买」push，见 `product_detail_page.dart` 的 `_buyNow`。
  Future<void> _openDetail(_Product p) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductDetailPage(
          api: widget.api,
          productId: p.id,
          initialName: p.name,
          initialCoverUrl: p.coverUrl,
        ),
      ),
    );
    // 从详情页返回后刷新列表：用户可能在详情页走完了下单（销量/每周限购额度都变了，
    // 服务端 `salesCount` 与 `/user/orders/weekly-quota` 都得重取）——
    // 与改版前"从确认订单页返回刷新"保持同一行为，不是新增行为。
    if (mounted) unawaited(_loadProducts());
  }
}

/// #RRGGBB → Color（管理端可配主题色；非法值回退 null）
Color? _hex(String? v) {
  if (v == null || v.isEmpty) return null;
  final h = v.replaceFirst('#', '');
  if (h.length != 6) return null;
  final n = int.tryParse(h, radix: 16);
  return n == null ? null : Color(0xFF000000 | n);
}

class _Division {
  _Division({
    required this.id,
    required this.gameId,
    required this.name,
    required this.shortName,
    required this.color,
    this.iconMediaId,
    this.coverMediaId,
    this.gameName = '',
    this.code = '',
    this.platform = '',
    this.platformLabel = '',
    this.underConstruction = false,
    this.noticeText = '',
  });

  final String id;
  final String gameId;
  final String name;
  final String shortName;
  final Color color;
  final String? iconMediaId;

  /// 分部卡封面图（`/divisions` 下发）；与 iconMediaId 任一有值即用图
  final String? coverMediaId;

  /// 分部官方图：有图就用图（iconMediaId 优先，其次 coverMediaId；都空 → 自绘游戏图标回退）
  String? get imageMediaId => divisionMediaId(iconMediaId: iconMediaId, coverMediaId: coverMediaId);

  /// 游戏名（游戏图标映射用）
  final String gameName;

  /// 分部 code（peace_mobile / delta_pc）
  final String code;

  /// 平台 mobile / pc（端游显示「端」角标）
  final String platform;

  /// 平台标签（管理端配置：手游 / 端游）—— 服务区上方的平台标识用它
  final String platformLabel;

  /// 是否建设中（服务端 `underConstruction`）：true = 本分部无商品，内容区显示建设中内容
  final bool underConstruction;

  /// 建设中页提示文案（服务端 `noticeText`，可含换行与 QQ 号）—— 客户端不硬编码
  final String noticeText;

  /// 游戏图标映射键（code → gameName → name / shortName 逐级兜底）
  String get gameKey => '$code $gameName $name $shortName'.trim();

  factory _Division.fromJson(Map json) => _Division(
        id: '${json['id']}',
        gameId: '${json['gameId'] ?? ''}',
        name: '${json['name'] ?? ''}',
        shortName: '${json['shortName'] ?? json['name'] ?? ''}',
        color: _hex(json['themeColor'] as String?) ?? AppColors.categoryColors[0],
        iconMediaId: json['iconMediaId'] == null ? null : '${json['iconMediaId']}',
        coverMediaId: json['coverMediaId'] == null ? null : '${json['coverMediaId']}',
        gameName: '${json['gameName'] ?? ''}',
        code: '${json['code'] ?? ''}',
        platform: '${json['platform'] ?? ''}',
        platformLabel: '${json['platformLabel'] ?? ''}',
        underConstruction: divisionUnderConstruction(json['underConstruction']),
        noticeText: '${json['noticeText'] ?? ''}',
      );
}

class _Category {
  _Category({required this.id, required this.name, required this.gameId});

  final String id;
  final String name;
  final String gameId;

  factory _Category.fromJson(Map json) => _Category(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        gameId: '${json['gameId'] ?? ''}',
      );
}

class _Product {
  _Product({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.price,
    required this.priceUnit,
    required this.salesCount,
    required this.coverUrl,
    required this.categoryId,
    required this.divisionId,
    this.gameId = '',
    this.badgeText,
    this.weeklyLimit,
    this.listName,
    this.weeklyLimitByQuantity,
  });

  final String id;
  final String name;

  /// 列表短名（服务端 `listName`，管理端可配；负责人 2026-10-05 任务②）
  ///
  /// **只在列表卡这一处生效**：窄卡放不下超长商品名时，管理端给一个短名，
  /// 详情页/确认订单页/订单页仍是完整 `name`（订单快照也用 name，不受影响）。
  /// NULL / 空串 → 回退完整名（后端已归一化为 null，这里再兜一层空串）。
  final String? listName;

  /// 列表卡上真正显示的名字：短名优先，空则回退完整名
  String get listDisplayName => (listName != null && listName!.isNotEmpty) ? listName! : name;

  final String subtitle;
  final double price;
  final String priceUnit;
  final int salesCount;
  final String? coverUrl;
  final String? categoryId;
  final String? divisionId;

  /// 所属游戏 id（服务端下发；分部对照不到时用它退一步匹配同游戏的分部）
  final String gameId;

  /// 徽标文案（服务端 `badgeText`，管理端可配）；null/空 = 不显示徽标
  final String? badgeText;

  /// 每周限购数（服务端 `weeklyLimit`）；null/0 = 不限购。仅用于"带上更准的初始值"，
  /// 真正的额度由 `/user/orders/weekly-quota` 权威下发（客户端不自己算规则）
  final int? weeklyLimit;

  /// 限购口径（服务端 `weeklyLimitByQuantity`）：0=按订单条数（默认）/ 1=按件数。
  /// 客户端**不参与判定**，只是随商品一起带下去，避免下单页先显示旧口径的提示（随后被 weekly-quota 覆盖）
  final int? weeklyLimitByQuantity;

  factory _Product.fromJson(Map json) => _Product(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        subtitle: '${json['subtitle'] ?? ''}',
        price: parsePoints(json['price']),
        priceUnit: '${json['priceUnit'] ?? ''}',
        salesCount: (json['salesCount'] as num?)?.toInt() ?? 0,
        coverUrl: (json['coverUrl'] as String?)?.isNotEmpty == true
            ? AppConfig.resolveMediaUrl(json['coverUrl'] as String)
            : (json['coverMediaId'] == null
                ? null
                : AppConfig.resolveMediaUrl('/media/public/${json['coverMediaId']}')),
        categoryId: json['categoryId'] == null ? null : '${json['categoryId']}',
        divisionId: json['divisionId'] == null ? null : '${json['divisionId']}',
        gameId: '${json['gameId'] ?? ''}',
        // 徽标：只有非空字符串才算有徽标（服务端 NULL → 这里保持 null，卡片不画徽标也不换描边）
        badgeText: (json['badgeText'] as String?)?.trim().isNotEmpty == true ? '${json['badgeText']}'.trim() : null,
        weeklyLimit: (json['weeklyLimit'] as num?)?.toInt(),
        // 列表短名：trim 后为空一律当"没配"（回退完整名），避免管理端存了一个空格就把名字显示成空白
        listName: (json['listName'] as String?)?.trim().isNotEmpty == true ? '${json['listName']}'.trim() : null,
        weeklyLimitByQuantity: (json['weeklyLimitByQuantity'] as num?)?.toInt() ?? 0,
      );
}

/// **图案底纹（圆点阵）** —— 方案 F/G 那 8 套 SVG pattern 里**最克制的一套**
///
/// 稿源：`site/design/color-graphics/planF.html` 的 `<defs>`
/// （8 套 = 等高线 `p-topo` / 六边 `p-hex` / 斜纹 `p-diag` / 圆点 `p-dots` / 网格 `p-grid` /
/// 波浪 `p-wave` / 雪鳞 `p-scale` / 山形 `p-mount`）。这里取 **`p-dots`**：
/// - 它是 8 套里**唯一没有方向性、没有密度叠加**的一套（14×14 网格上一枚 r=1.5 的实心圆），
///   铺在页面上只提供"有质感"而不提供"图形语义"，不会和商品卡争注意力；
/// - 稿内参数逐值照抄：`width/height = 14`、圆心 `(2.5, 2.5)`、半径 `1.5`。
///
/// **为什么是 CustomPainter 而不是引 SVG**：core 没有 `flutter_svg`（不许为一个底纹引运行时），
/// 而这一套用 Canvas 画就是两行循环 —— 零依赖、零资源、可像素级复算。
///
/// **强度**：稿内 `p-dots` 是 22% 主色；本页按任务书压到 **6%（opacity 0.06）**。
/// 铺的位置也受两条约束：
/// 1. **只铺内容区底部空白带**（[band]）：卡片是不透明白面，正常滚动时底纹被全部挡住，
///    只有"商品少 / 滚到底"才透出来 —— 底纹不会垫在文字下面影响可读性；
/// 2. **只在有商品时画**（空态/建设中不画）：那两种状态的内容是居中文字，底纹会正好压在它下面。
class _DotBandPainter extends CustomPainter {
  const _DotBandPainter({required this.color});

  /// 点色（页面传主色；透明度统一由 [opacity] 收口，不靠调用方传半透明色）
  final Color color;

  /// 底纹只出现在"内容区最下面这么多 dp"里
  static const double band = 132;

  /// 网格步长（稿内 pattern 的 14）
  static const double step = 14;

  /// 圆点半径（稿内 1.5）
  static const double dotRadius = 1.5;

  /// **全页唯一一处透明度**：≤ 0.06（任务书硬上限）
  static const double opacity = 0.06;

  /// 稿内圆心偏移（`cx/cy = 2.5`，即格子左上内缩 2.5）
  static const double _inset = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // 带高不超过画面本身（内容区比带还矮时，整块都是"底部空白"）
    final double top = size.height > band ? size.height - band : 0;
    final paint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    for (double y = top + _inset; y < size.height; y += step) {
      for (double x = _inset; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotBandPainter oldDelegate) => oldDelegate.color != color;
}
