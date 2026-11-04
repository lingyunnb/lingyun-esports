import 'dart:async';

import 'package:fish_core/fish_core.dart';
import '../widgets/order_review_section.dart';
import '../widgets/order_status_tag.dart';
import 'package:flutter/material.dart';
import '../widgets/fish_glass.dart';

/// 订单（阶段 14-16 + 结算需求）：状态分栏；待用户确认订单可点"已完成"触发正式结算。
/// 分账比例由服务端下发（抽成已改为后台可配，默认平台 25% / 打手 75%），客户端不写死。
class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  /// 「正在刷新」弱提示的锚点（发丝线级 2dp；缓存优先先画时就该出现）
  static const Key refreshingHairlineKey = Key('orders-refreshing-hairline');

  /// 订单筛选胶囊：**9 个内部状态 → 5 枚用户可见胶囊**（负责人：「订单页上方的胶囊太多了」）
  ///
  /// 合并的只是**胶囊**，状态一个没减：`docs/05` 的合法迁移表、后端 `OrderStatus` 枚举、
  /// `order_status_log` 全都没动 —— 本页只加一层"筛选分组"的视觉聚合。
  ///
  /// | 胶囊 | 覆盖的内部状态 | 为什么这么分 |
  /// |---|---|---|
  /// | 全部 | 不过滤（9 个状态都在） | 售后 / 已取消 / 异常**只在这里出现**，靠卡上状态标签区分 |
  /// | 待接单 | pending_take + pending_dispatch | 用户视角都是"还没人接" |
  /// | 进行中 | taken + in_progress | 已接单 + 服务中，都是"有人在打" |
  /// | 待确认 | pending_confirm | **必须单列**：这是用户要动手确认的待办，藏起来等于藏了操作 |
  /// | 已完成 | completed | 正常终态 |
  ///
  /// 为什么不再少：待接单（没人接）与进行中（正在打）是两个不同的焦虑点；
  /// 待确认并进「进行中」会让「确认完成」按钮更难被发现。
  ///
  /// 三列含义：(筛选键, 胶囊文案, 覆盖状态组)。**状态组为空 = 不过滤**。
  /// 筛选键刻意不与任何状态值同名 —— 它只是本页的选中态标识，**不发请求**。
  ///
  /// 放在 Widget 类（而不是 State）上的理由：这是本页对外的**筛选契约**，
  /// 页面测试直接断言这张表，不必把页面渲染出来才敢确认"到底合并了哪几个状态"。
  static const List<(String, String, List<String>)> filterCapsules = <(String, String, List<String>)>[
    ('all', '全部', <String>[]),
    ('group_not_taken', '待接单', <String>['pending_take', 'pending_dispatch']),
    ('group_serving', '进行中', <String>['taken', 'in_progress']),
    ('group_confirm', '待确认', <String>['pending_confirm']),
    ('group_done', '已完成', <String>['completed']),
  ];

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  /// 当前选中的胶囊键（默认「全部」；切胶囊**只 setState，零请求**）
  String _tab = 'all';

  /// 服务端下发的**全量**列表（首屏拉一次，5 枚胶囊都从这一份里就地分组）
  final List<OrderBrief> _orders = [];

  /// 屏上有内容、后台正在回源（发丝线级弱提示；见 [build] 里的 Stack 覆盖层）
  bool _refreshing = false;

  /// 分部对照表（订单卡显示该分部官方游戏图 + 端游角标用）
  /// 单独拉取、失败静默：拿不到分部就回退自绘游戏图标，**绝不影响订单列表本身**
  List<_DivisionLite> _divisions = const [];
  bool _loading = true;
  String? _error;

  /// 订单所属分部：先按订单的 `divisionId` 对照；老订单没挂分部时按 `gameId` 退一步匹配。
  /// 都对照不到 → null（GameIconTile 回退自绘图标，不猜平台、不猜游戏）
  _DivisionLite? _divisionOf(OrderBrief o) {
    final did = o.divisionId ?? '';
    if (did.isNotEmpty) {
      for (final d in _divisions) {
        if (d.id == did) return d;
      }
    }
    if (o.gameId.isNotEmpty) {
      for (final d in _divisions) {
        if (d.gameId == o.gameId) return d;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadDivisions();
  }

  /// 拉分部（公开接口，服务端 30s 微缓存 + 客户端 SWR 缓存，代价极小）
  Future<void> _loadDivisions() async {
    try {
      final resp = await _api.request('GET', '/divisions');
      final list = (resp['data'] as List?) ?? const [];
      final divs = list.map((e) => _DivisionLite.fromJson(e as Map)).toList();
      if (!mounted) return;
      setState(() => _divisions = divs);
    } catch (_) {
      // 静默：分部拿不到只是没有官方图，不影响订单列表
    }
  }

  /// [force] = true 时绕过 ApiClient 的 SWR 缓存强刷
  ///
  /// 负责人 2026-10-04 报障「单子完成了还显示进行中」的一处真因：
  /// `/user/orders` 走 45s 列表缓存，`order:update` 到达后如果只做普通 `_load()`，
  /// 45s 内命中旧缓存 → 列表仍显示「进行中」。因此**订单状态变化事件一律 force 强刷**。
  Future<void> _load({bool force = false}) async {
    /**
     * 【2026-10-15 秒刷专项 · 缓存优先】进页/切状态先用**上一次的订单**把列表画上
     * （哪怕已过期），再回源原地替换 —— 从"空列表 + 转圈"变成"秒出 + 一条发丝线细提示"。
     *
     * 只在一种情况下先画：屏上还没有订单（首载）。
     * （筛选改成"一次拉全量 + 本地按状态组过滤"之后，**不存在**"屏上那份是别的状态"的情况了：
     *  同一份全量列表服务 5 枚胶囊，切胶囊不换数据源、也不发请求。）
     * 其余路径（`force`：下拉刷新 / 实时事件强刷）不动屏，避免把"刚确认完成"的列表又换回旧的。
     */
    if (!force && _orders.isEmpty) _paintFromCache();
    // 需求 #6：已有数据时保留旧列表静默刷新（不再整页转圈）；仅首载/空态显示 loading
    setState(() {
      _error = null;
      if (_orders.isEmpty) {
        _loading = true;
      } else if (!force) {
        // 屏上是上一次的数据、正在追平 → 给弱提示；`force`（用户主动刷新）走 RefreshIndicator 自己的转圈
        _refreshing = true;
      }
    });
    try {
      final token = AuthStore.instance.accessToken;
      // **不传 status**：一次拉全量，5 枚胶囊在本地按状态组过滤（切胶囊零请求）。
      // 接口本来支持单状态参数，但每切一次胶囊就回源 = 把"看另一组订单"变成一次网络等待；
      // `pageSize` 沿用 50 —— 与"按状态拉 50 条"同一页容量口径，不新增分页、不改接口。
      final resp = await _api.request('GET', '/user/orders',
          token: token, forceRefresh: force, queryParameters: {
        'page': 1,
        'pageSize': 50,
      });
      final data = resp['data'] as Map<String, dynamic>;
      // （注意）必须判 mounted：订单页的请求是真异步（订单是私有数据、**不进缓存**，见 ApiCache
      //    `neverCachePrefixes`），用户可能在响应回来之前就退出这一页。
      //    此前订单走缓存同步命中，几乎没有这个异步间隙，所以这三处 setState 一直没暴露出问题；
      //    2026-10-16 把 `/user/orders` 收进红线名单后，`perf_first_paint_test ⑩` 立刻报出
      //    `setState() called after dispose()` —— 那是**既有缺陷被逼出来**，不是新引入的。
      if (!mounted) return;
      setState(() {
        _orders
          ..clear()
          ..addAll((data['list'] as List<dynamic>? ?? []).map((e) => OrderBrief.fromJson(e as Map<String, dynamic>)));
      });
    } on ApiException catch (e) {
      // 已有订单时静默保留旧列表（网络不稳不再整页变错误页）；仅空列表首载失败显示错误
      if (!mounted) return;
      setState(() => _error = _orders.isEmpty ? e.message : null);
    } finally {
      // `finally` 无论是否 return 都会执行 —— 这里最容易打到已销毁的 State，必须单独判一次
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  /// 缓存优先先画（**同步、0 请求**）：键与 `_load` 里的请求完全同源（不含状态参数）
  ///
  /// 未命中（本次运行内没拉到过）→ 什么都不做，保持原行为（屏上还是上一次那份）。
  void _paintFromCache() {
    final peek = _api.peekCache('/user/orders', <String, dynamic>{
      'page': 1,
      'pageSize': 50,
    });
    if (peek == null) return;
    final data = (peek.body['data'] as Map?) ?? const {};
    final list = (data['list'] as List?) ?? const [];
    List<OrderBrief> orders;
    try {
      orders = list.map((e) => OrderBrief.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return; // 缓存形状不认识：不画（退回原行为），绝不让首屏抛异常
    }
    if (!mounted) return;
    setState(() {
      _orders
        ..clear()
        ..addAll(orders);
      _loading = false;
    });
  }

  /// 当前胶囊覆盖的状态组（**空 = 不过滤**，即「全部」）
  List<String> get _activeStatuses {
    for (final c in OrdersPage.filterCapsules) {
      if (c.$1 == _tab) return c.$3;
    }
    // 兜底按「全部」：绝不因为一个认不出的筛选键把列表清空
    return const <String>[];
  }

  /// 屏上该显示哪些订单 —— **纯本地过滤，零请求**（与首页 `services_page` 的胶囊同一套口径）
  ///
  /// 数据本体是首屏一次拉全的 [_orders]，切换胶囊只改一个筛选键，
  /// 这里 `O(n)` 遍历一次几十条订单就地分组：不转圈、不闪屏、发不出请求。
  List<OrderBrief> get _visibleOrders {
    final group = _activeStatuses;
    if (group.isEmpty) return _orders;
    return _orders.where((o) => group.contains(o.status)).toList(growable: false);
  }

  /// 订单详情里已下发过的结算比例（订单号 → 比例），供"确认结算"预览复用。
  ///
  /// 只作为**缓存**：确认弹窗仍会先向服务端确认一次（见 [_confirm]），
  /// 缓存只是省掉"刚看过详情、马上又确认"这一次多出来的请求。
  final Map<String, ({double worker, double platform})> _splitCache = {};

  /// 从结算实体里取比例；缺任一项或数值非法 → null（**不猜、不回退 70/30**）
  ({double worker, double platform})? _splitOf(Map<String, dynamic>? settle) {
    if (settle == null) return null;
    final w = _asPct(settle['workerPercentage']);
    final p = _asPct(settle['platformPercentage']);
    if (w == null || p == null) return null;
    return (worker: w, platform: p);
  }

  static double? _asPct(Object? raw) {
    final n = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
    if (n == null || !n.isFinite || n <= 0 || n > 100) return null;
    return n;
  }

  /// 取该订单当前生效的分账比例（服务端为准）。
  ///
  /// 为什么确认结算前要拉一次详情：抽成比例已改成后台可配，而**未结算的订单还没有
  /// settlement**，比例只存在于"当前配置"里。订单详情接口的实现（order.service.ts
  /// `userOrderDetail`）在订单未结算时用服务端实时算出的比例补进同一字段，
  /// 因此拉详情是拿到权威比例的现成途径（不新增接口、不把结算逻辑搬到客户端）。
  /// 失败/取不到 → 返回 null → 调用方**不显示百分比**（而不是显示写死的 70/30）。
  Future<({double worker, double platform})?> _resolveSplit(OrderBrief o) async {
    final cached = _splitCache[o.id];
    if (cached != null) return cached;
    try {
      final resp = await _api.request('GET', '/user/orders/${o.id}', token: AuthStore.instance.accessToken);
      final split = _splitOf(resp['data'] is Map ? (resp['data'] as Map)['settlement'] as Map<String, dynamic>? : null);
      if (split != null) _splitCache[o.id] = split;
      return split;
    } on ApiException {
      return null;
    }
  }

  Future<void> _confirm(OrderBrief o) async {
    // 预览金额：与服务器算法保持一致（workerAmount = round(总价 × 打手比例)/100，
    // 平台 = 总额 - 打手，保证金额守恒；口径见 server/src/modules/setting/commission-rate.ts）。
    // 比例**从服务端取**：抽成已改为后台可配（当前默认 25% = 打手 75%），
    // 客户端写死 70/30 会把错误数字展示给用户。取不到比例时只显示"由服务器计算"。
    final split = await _resolveSplit(o);
    if (!mounted) return;
    String body;
    if (split == null) {
      body = '确认后订单将正式完成结算，\n具体金额由服务器按下单时的价格快照与当前抽成配置计算，仅一次生效。';
    } else {
      final workerShare = (o.totalAmount * split.worker).round() / 100;
      final platformShare = ((o.totalAmount - workerShare) * 100).round() / 100;
      body = '确认后订单将正式完成结算：\n'
          '打手获得 ${fmtMoney(workerShare)}（${_fmtPct(split.worker)}）\n'
          '平台抽成 ${fmtMoney(platformShare)}（${_fmtPct(split.platform)}）\n'
          '结算由服务器计算，仅一次生效。';
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认订单已完成？'),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('再想想')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('已完成，确认结算')),
        ],
      ),
    );
    if (sure != true) return;
    if (!mounted) return;
    try {
      final resp = await _api.request('POST', '/user/orders/${o.id}/confirm', token: AuthStore.instance.accessToken, data: {});
      final data = resp['data'] as Map<String, dynamic>;
      if (!mounted) return;
      _splitCache.remove(o.id); // 结算后比例以服务端落库值为准，清掉预览缓存
      AppToast.success(
          context, '结算完成：打手 +${fmtMoney(parsePoints(data['workerAmount']))}，平台 +${fmtMoney(parsePoints(data['platformAmount']))}');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  /// 比例文案：整数不带小数点（75 → "75%"），小数保留原样
  static String _fmtPct(double n) =>
      n == n.roundToDouble() ? '${n.toInt()}%' : '$n%';

  /// 申请售后（docs/05：仅已完成/异常订单，一单一申诉）
  Future<void> _appeal(OrderBrief o) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('申请售后'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 200,
          decoration: const InputDecoration(hintText: '请描述遇到的问题（如：服务未完成、体验不佳等）'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('提交申诉')),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) return;
    try {
      await _api.request('POST', '/user/orders/${o.id}/appeal', token: AuthStore.instance.accessToken, data: {'reason': reason});
      if (!mounted) return;
      AppToast.success(context, '申诉已提交，客服会尽快处理');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  /// 查看申诉状态
  Future<void> _appealStatus(OrderBrief o) async {
    try {
      final resp = await _api.request('GET', '/user/orders/${o.id}/appeal', token: AuthStore.instance.accessToken,
          );
      final a = resp['data'];
      if (!mounted) return;
      if (a == null) return;
      final statusText = a['status'] == 'handled' ? (a['result'] == 'refund' ? '已退款' : '已驳回') : '处理中';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('售后状态'),
          content: Text('原因：${a['reason']}\n状态：$statusText\n处理备注：${a['handlerRemark'] ?? '-'}'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  /// 订单详情（需求 #20：服务信息/打手信息/金额消费/状态/结算），点卡片查看
  Future<void> _detail(OrderBrief o) async {
    try {
      final resp = await _api.request('GET', '/user/orders/${o.id}', token: AuthStore.instance.accessToken,
          );
      final d = resp['data'] as Map<String, dynamic>? ?? {};
      final snap = d['snapshot'] as Map<String, dynamic>?;
      final settle = d['settlement'] as Map<String, dynamic>?;
      final worker = d['workerInfo'] as Map<String, dynamic>?;
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ① 状态时间轴（方案 G：竖线 `#E8ECF2` + 当前节点蓝实心 / 已完成绿点 / 未到空心点）
                  //
                  // **零新增数据**：节点状态全部由 `d['status']`（缺失时回落 `o.status`）*推导* ——
                  // 订单状态机是单向前进的（docs/05），因此"当前档位"蕴含"更早的档位都已走过"，
                  // 不需要为画这条线多打一个接口，也不改任何状态流转。
                  _statusTimeline('${d['status'] ?? o.status}', '${d['statusName'] ?? o.statusName}'),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('订单号 ${d['orderNo'] ?? o.orderNo}',
                        style: TextStyle(fontSize: 12, color: AppColors.textPlaceholder)),
                  ),
                  // ② 商品信息卡
                  _section('服务信息', [
                    _kv('商品', snap == null ? '-' : '${snap['productName']}'),
                    _kv('游戏 / 分类', snap == null ? '-' : '${snap['gameName']} / ${snap['categoryName']}'),
                    _kv('单价', snap == null
                        ? '-'
                        : '${fmtMoney(parsePoints(snap['unitPrice']))}/${snap['priceUnit']} × ${snap['quantity']}'),
                  ]),
                  const SizedBox(height: 10),
                  // ③ 下单信息卡（区服 / 游戏ID / 备注 / 联系方式）
                  _section('下单信息', [
                    _kv('游戏区服', d['gameZone'] == 'qq' ? 'QQ区' : (d['gameZone'] == 'wechat' ? '微信区' : '-')),
                    _kv('游戏昵称 / ID', '${d['gamePlayerId'] ?? '-'}'),
                    _kv('订单备注', (d['userRemark'] ?? '').toString().isEmpty ? '—' : '${d['userRemark']}'),
                    _kv('联系方式', (d['contactPhone'] ?? '').toString().isEmpty ? '—' : '${d['contactPhone']}'),
                    _kv('下单时间', _fmt('${d['createdAt'] ?? ''}')),
                  ]),
                  const SizedBox(height: 8),
                  // ④ **打手（护航员）信息卡**（方案 G：头像位 + 名字 + 工号 + 接单状态；
                  //    未接单时给空态，不画一个"假头像"）
                  _workerCard(worker),
                  const SizedBox(height: 8),
                  /**
                   * ⑤ 服务评价（负责人 2026-10-15）
                   *
                   * **只放在订单详情里**，不放列表卡上（一屏十几张卡都挂"去评价"会糊）。
                   * 位置：护航员卡之后、金额卡之前 —— 评价的对象是"这次服务/这位护航员"，
                   * 紧跟在它下面，读起来是一件事的两面。
                   *
                   * 组件自己把关三件事：仅 `completed` 才渲染/发请求；已评价 → 原地显示结果
                   * （入口消失）；不满意且服务端回 `needAfterSale` → 卡内给"申请售后"下一步。
                   */
                  OrderReviewSection(
                    api: _api,
                    orderId: o.id,
                    status: '${d['status'] ?? o.status}',
                    onAfterSale: () {
                      // 先关掉详情弹层（售后申请自己是弹窗，压在弹层上会叠两层）
                      Navigator.of(ctx).pop();
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) unawaited(_appeal(o));
                      });
                    },
                  ),
                  // 间距落 4dp 网格（本次新增的这一处用 12；上下相邻卡之间沿用既有 10）
                  const SizedBox(height: 12),
                  // ⑥ **费用明细**（方案 G：标签左 / 值右对齐 + **tabular 数字**，
                  //    等宽数字让"¥1,152.00"与"¥9.90"的小数点在同一条竖线上）
                  _section('金额', [
                    _kv('商品费用', fmtMoney(parsePoints(d['totalAmount']))),
                    _kv('订单数量', '${d['quantity'] ?? o.quantityText}'),
                  ]),
                  if (settle != null) ...[
                    const SizedBox(height: 10),
                    /**
                     * 结算信息（负责人 2026-10-04：抽成比例改成后台可配，客户端不得写死）
                     *
                     * 此前标签硬编码「(70%)」「(30%)」，与库里的 `order_settlement.worker_percentage`
                     * 完全脱钩；抽成改成可配置（当前默认 25% = 打手 75%）后，这两行会**直接显示错误比例**，
                     * 属于把错误信息展示给用户。改为读服务端在 `settlement` 里下发的
                     * `workerPercentage` / `platformPercentage`（订单详情接口
                     * `GET /user/orders/:id` 已经返回整个 settlement 实体，含这两列）。
                     *
                     * 取不到时**只显示金额、不显示百分比** —— 不猜、也不退回 70/30
                     * （退回写死值正是本次要消灭的问题）。
                     */
                    _section('结算信息', [
                      _kv('结算编号', '${settle['settlementNo'] ?? ''}'),
                      _kv('护航员收益${_pctLabel(settle['workerPercentage'])}',
                          fmtMoney(parsePoints(settle['workerAmount']))),
                      _kv('平台服务费${_pctLabel(settle['platformPercentage'])}',
                          fmtMoney(parsePoints(settle['platformAmount']))),
                    ]),
                  ],
                  const SizedBox(height: 16),
                  // ⑦ **底部固定操作条**（方案 G：白底 + 顶部 1px 描边 + 右对齐；
                  //    按状态真正可执行的操作，订单没有任何可执行动作时整条不渲染）
                  if (_actionsFor(o).isNotEmpty)
                    Container(
                      decoration: BoxDecoration(
                        color: T.bgCardSolid,
                        border: Border(top: BorderSide(color: AppColors.strokeSoft)),
                      ),
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: _actionsFor(o)),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  /// 结算比例标签：`" (75%)"` / 取不到时 `""`（只显示金额）。
  ///
  /// 服务端 `order_settlement.worker_percentage` / `platform_percentage` 是
  /// **百分数整数**（75 = 75%），与 `commission-rate.ts` 的口径一致。
  /// 这里刻意不设默认值：拿不到就不显示百分比，绝不猜、不回退到历史写死的 70/30。
  String _pctLabel(Object? raw) {
    final n = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
    if (n == null || !n.isFinite || n <= 0 || n > 100) return '';
    final text = n == n.roundToDouble() ? n.toInt().toString() : n.toString();
    return ' ($text%)';
  }

  /// 分区卡（订单详情用；标题 + 内容，圆角 16 + 灰发丝线，对齐设计稿）
  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 0),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: T.textPrimary)),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  /// 详情行（左标签 + 右值，长值自动换行）
  ///
  /// 方案 G「费用明细右对齐 + tabular 数字」：值列统一右对齐，并开
  /// [FontFeature.tabularFigures] —— 等宽数字让同一列里 `¥9.90` / `¥1,152.00`
  /// 的小数点与千分位落在同一条竖线上，扫一列金额时不用左右跳。
  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label, style: TextStyle(fontSize: 12, color: T.mutedText)),
            ),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: T.textPrimary)),
            ),
          ],
        ),
      );

  /// 订单状态时间轴（方案 G「状态时间轴」）
  ///
  /// ## 为什么只用 `status` 一个入参、不新拉状态历史
  /// 订单状态机是**单向前进**的（docs/05 的合法迁移表里没有回退边），因此
  /// "当前档位 ⇒ 更早的档位都已走过" 是**数据本身的性质**，画这条线不需要额外请求、
  /// 也不需要 `order_status_log` —— 本轮"逻辑零改动"的前提正是靠这一点成立的。
  ///
  /// ## 三个点各有独立语义（不靠颜色单独承载信息）
  /// - **已完成** = 绿实心 `success`（与"正常终态"同一支绿）
  /// - **当前**   = 蓝实心 `primary`（全站唯一"你在这里"的标记）
  /// - **未到**   = 空心（描边 `strokeSoft`），且文字降为弱色
  /// 竖线一律 1dp `#E8ECF2`。
  ///
  /// 终态（已取消 / 异常 / 售后）**不在主流程上**（它们不必走完前面各档），
  /// 因此不为它们伪造进度：标题行用该状态自己的语义色说明"这单停在哪"，主线一律画未到。
  Widget _statusTimeline(String status, String statusName) {
    // 顺序 = 主流程（与筛选胶囊同一套中文词表，避免同页出现两套叫法）
    const flow = <(String, String)>[
      ('pending_take', '待接单'),
      ('pending_dispatch', '待派单'),
      ('taken', '已接单'),
      ('in_progress', '进行中'),
      ('pending_confirm', '待确认'),
      ('completed', '已完成'),
    ];
    const rank = <String, int>{
      'pending_take': 0,
      'pending_dispatch': 1,
      'taken': 2,
      'in_progress': 3,
      'pending_confirm': 4,
      'completed': 5,
    };
    final cur = rank[status];
    final terminal = cur == null;

    final rows = <Widget>[
      // 标题行：当前状态（终态时它就是唯一说明"停在哪"的地方）
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          statusName,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _statusColor(status)),
        ),
      ),
    ];
    for (var i = 0; i < flow.length; i++) {
      final done = !terminal && cur > i;
      final active = !terminal && cur == i;
      rows.add(_timelineRow(
        label: flow[i].$2,
        // null = 空心（未到）
        dotColor: done ? AppColors.success : (active ? AppColors.primary : null),
        labelColor: done || active ? T.textPrimary : AppColors.textPlaceholder,
        last: i == flow.length - 1,
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// 时间轴的一行：左点/线 + 右文案
  Widget _timelineRow({
    required String label,
    required Color? dotColor,
    required Color labelColor,
    required bool last,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 点 + 竖线（固定宽 8，竖线居中）
        Column(
          children: [
            const SizedBox(height: 4),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor, // null → 透明 = 空心
                border: dotColor == null ? Border.all(color: AppColors.strokeSoft) : null,
              ),
            ),
            if (!last) Container(width: 1, height: 24, color: AppColors.strokeSoft),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 12),
            child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: labelColor)),
          ),
        ),
      ],
    );
  }

  /// 打手（护航员）信息卡（方案 G「打手信息卡」）
  ///
  /// 未接单时是**空态**而不是假头像：头像位换成线性图标，名字位写「等待接单」，
  /// 第二行给出"接下来会发生什么"（不承诺时长、不编在线状态）。
  Widget _workerCard(Map<String, dynamic>? worker) {
    final name = worker == null ? '' : '${worker['nickname'] ?? ''}'.trim();
    final no = worker == null ? '' : '${worker['workerNo'] ?? ''}'.trim();
    return _section('护航员', [
      Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // 实色浅底 + 主色首字（不用渐变头像、不放吉祥物）
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(AppDecoRadius.control),
            ),
            child: worker == null || name.isEmpty
                ? AppIcon.of(AppIcon.players, size: 18, color: T.textSecondary)
                : Text(name.substring(0, 1),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: T.primary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(worker == null ? '等待接单' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: T.textPrimary)),
                const SizedBox(height: 4),
                Text(
                  worker == null
                      ? '订单在待接单大厅，由该分部有权限的护航员接单'
                      : (no.isEmpty ? '已接单' : '工号 $no'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppColors.textPlaceholder),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 接单状态小标签（语义色实底 + 白字，与状态标签同一口径）
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: worker == null ? AppColors.statusMuted : AppColors.success,
              borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
            ),
            child: Text(worker == null ? '等待接单' : '已接单',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ],
      ),
    ]);
  }

  // ignore: unused_element
  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 96, child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.mutedText))),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 13, height: 1.4))),
          ],
        ),
      );

  String _fmt(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final l = t.toLocal();
    return '${l.month}-${l.day} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _cancel(OrderBrief o) async {
    try {
      await _api.request('POST', '/user/orders/${o.id}/cancel', token: AuthStore.instance.accessToken, data: {'reason': '用户取消'});
      if (!mounted) return;
      AppToast.success(context, '已取消并全额退款');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  /// 订单状态 → 前景色。**必须列全 9 种**（`server/src/modules/order/order.entity.ts` 的 `OrderStatus`）。
  ///
  /// 为什么本次要补：旧实现只认 4 种，`pending_dispatch / taken / in_progress / abnormal / after_sale`
  /// 全部落到 `_`（主色）—— **「异常」和「售后」被画成了跟「进行中」一模一样的颜色**，
  /// 这是"状态只靠颜色"里最危险的一种：把**需要人处理的事**画成了**正常的事**。
  ///
  /// 另外把「已取消」从 `error`（红）改为中性灰：它是**正常终态**不是错误，
  /// 一直用红色会让整页"看起来到处在报警"（对齐设计稿 `s-off` 档）。
  Color _statusColor(String status) => switch (status) {
        'completed' => AppColors.success,
        'canceled' => AppColors.statusMuted,
        'abnormal' || 'after_sale' => AppColors.error,
        'pending_take' || 'pending_dispatch' || 'pending_confirm' => AppColors.warning,
        _ => AppColors.primary,
      };

  @override
  Widget build(BuildContext context) {
    // 本地分组只算一次（5 枚胶囊共用这一份全量列表）
    final visible = _visibleOrders;
    return FishGlassPage(
      title: '订单',
      blurredTopBar: true,
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：渐变只在 body 这一层，
      // 顶栏与每张订单卡仍是实色（订单卡的白底因此浮在渐变上，卡片本身一句未改）。
      body: AppPageBg(child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                /**
                 * 状态筛选胶囊：**5 枚一行放得下、不滚**（负责人：胶囊尽量少）
                 *
                 * 宽度预算（390dp 宽 / 字号 12 / 胶囊内距 8 / 描边 1 / 胶囊间距 8 / 页边 16）：
                 * 每枚 = 字数 × 12 + (8 + 1) × 2
                 *   全部 2 字 = 42；待接单 / 进行中 / 待确认 / 已完成 各 3 字 = 54 → 小计 258
                 * 258 + 5 个间距 40 + 页边 32 = **330dp** < 390dp（余约 60dp）
                 *
                 * **2026-10 返工教训**：上一版按"内距 12 + 字号 12.5"算出 377dp 就断言"放得下"，
                 * 实测超宽 —— 中文字形推进比"字号 × 字数"略宽，且 Text 会继承 Material 默认
                 * letterSpacing，算出来的数是**乐观值**。所以内距收到 8、字号收到 12；
                 * 页面测试也不再只信算术：直接断横向 Scrollable 的 `maxScrollExtent == 0`
                 * （= 内容宽 ≤ 视口宽），**只有实测口径算数**。
                 *
                 * 仍套横向滚动容器，但它**只作兜底**：再大的系统字号 / 更窄的屏才需要滑，
                 * 日常切组永远在首屏一次点到（不靠滑动去够最后两个胶囊）。
                 */
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                    children: [
                      for (final c in OrdersPage.filterCapsules)
                        Padding(
                          padding: const EdgeInsets.only(right: AppSpacing.sm),
                          child: _filterPill(c.$1, c.$2),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _load(force: true),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, style: const TextStyle(color: AppColors.error)),
                              const SizedBox(height: AppSpacing.md),
                              FilledButton(onPressed: _load, child: const Text('重试')),
                            ],
                          ),
                        )
                      : visible.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                Padding(
                                  padding: EdgeInsets.symmetric(vertical: 80),
                                  child: Text('暂无订单', textAlign: TextAlign.center, style: TextStyle(color: AppColors.mutedText)),
                                ),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.md,
              AppSpacing.page,
              // 玻璃底栏悬浮（extendBody）→ 底部让出它的高度，否则最后一张卡被压住
              AppSpacing.md + NavStyleController.instance.navReservedHeight,
            ),
                              itemCount: visible.length,
                              itemBuilder: (ctx, i) {
                                final o = visible[i];
                                // 该订单所属分部（对照 /divisions；拿不到则 null → 自绘图标兜底）
                                final div = _divisionOf(o);
                                // 订单卡 = **通栏列表语言**（`docs/45 §二②` 的 ListCard 一档）：
                                // 通栏白底 + **上下各一条 1dp 发丝** + **圆角 0** + **无切口**、**0 阴影**。
                                //
                                // 三处替换（全是 `docs/21` 点名的手段）：
                                // ① 旧 `AppCard` = `radius 16 + 常驻浅投影` → 换成通栏直角 + 0 阴影
                                //    （大圆角当卡片＝玩具感；阴影只留给"浮在内容之上"的弹层/吸底/悬浮）；
                                // ② 卡内两条 `Divider` → **发丝线**（同一件事只给一个词，且缩进 16 对齐 V0）；
                                // ③ 状态标签的右上 6×6 切口是本页**唯一**的切口（列表档刻意不切口：
                                //    序列表格没有"角"的语义，这是三档卡片互相不可替换的那条线）。
                                //
                                // 为什么直接把 ListCard 的容器语义写在这里、而不是套 `AppListCard` 组件：
                                // 那个组件用固定 `rowHeight` 装**一行**，而订单卡是一张"卡"（3 段内容 ~120dp）；
                                // 套进去要么溢出、要么把卡片信息压成一行。这里用**同一个** `AppHairline`
                                // 与 `AppDecoSpacing.hairlineIndent`，语言一致、不复制第二套发丝线实现。
                                //
                                // padding 归零：卡内每一段自带左右 16 内距，上下两条发丝线才能通栏到屏宽。
                                return StaggeredItem(
                                  index: i,
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    // 非 const：卡面底色走**主题 token**（`T.bgCardSolid` 是 getter，
                                    // 这样玻璃主题下也跟着变，而不是把白写死）
                                    decoration: BoxDecoration(
                                      color: T.bgCardSolid,
                                      // 通栏直角（= AppDecoRadius.none）：序列表格没有"角"的语义
                                      borderRadius: BorderRadius.zero,
                                      border: Border(
                                        top: BorderSide(color: T.divider),
                                        bottom: BorderSide(color: T.divider),
                                      ),
                                    ),
                                    child: Material(
                                      type: MaterialType.transparency,
                                      child: InkWell(
                                        onTap: () => _detail(o),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                        // 表头：**白底 + 发丝线分隔**（2026-10-15 白底为主定案）
                                        // 旧做法是整条铺 `_statusColor(alpha .07)` 的状态色底带 —— 那是
                                        // "每张卡都在报颜色"的来源之一；改为白底后，状态只由标签承担。
                                        // 方案 G：左 = 状态标签（语义色，切口语言不变）、右 = **单号 12px 弱色**。
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                                          child: Row(
                                            children: [
                                              OrderStatusTag(
                                                status: o.status,
                                                label: o.statusName,
                                                // 通栏/卡面底色（切口要用它盖角，取错会在角上留白补丁）
                                                surfaceColor: T.bgCardSolid,
                                              ),
                                              const Spacer(),
                                              Text('订单号 ${o.orderNo}',
                                                  style: TextStyle(fontSize: 12, color: AppColors.textPlaceholder)),
                                            ],
                                          ),
                                        ),
                                        // 行分隔一律用**发丝线**（1dp / #E3E8EF / 无端点），缩进 16 与文案起点（V0）对齐。
                                        // 原来这里用 `Divider` 是同一个色值与厚度，属重复表达：收敛成 deco 组件，
                                        // 顺带把缩进补上 —— 通栏卡的通栏感靠"上下外边界"表达，
                                        // 卡内两条行分隔是要缩进的（否则线与文字不在同一套网格上）。
                                        const AppHairline(indent: AppDecoSpacing.hairlineIndent),
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              // 游戏图标块（负责人 2026-10-04：下单链路封面统一用游戏图标）
                                              // 订单接口已下发 divisionId/gameId → 对照 /divisions：
                                              // **该分部挂了官方图就用图**（端游仍叠「端」角标）；对照不到
                                              // 才退回"商品名推断 + 无平台角标"（绝不猜平台）
                                              GameIconTile(
                                                gameKey: div?.gameKey ??
                                                    (o.gameKey.isNotEmpty
                                                        ? o.gameKey
                                                        : inferGameKeyFromText(o.productName)),
                                                platform: div?.platform ?? o.platform,
                                                color: div?.color,
                                                size: 56,
                                                radius: 10,
                                                mediaId: div?.imageMediaId,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      o.productName.isEmpty ? '订单 ${o.orderNo}' : o.productName,
                                                      // 商品名统一最多 3 行（与商品列表卡一致；最长在售名 46 字）
                                                      // 方案 G：**商品名 13px 粗**（卡内第一层信息）
                                                      maxLines: 3,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                          fontSize: 13, fontWeight: FontWeight.w700, height: 1.35, color: T.textPrimary),
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Row(
                                                      children: [
                                                        Text(_fmt(o.createdAt),
                                                            style: TextStyle(fontSize: 10.5, color: T.mutedText)),
                                                        if (o.workerNickname.isNotEmpty) ...[
                                                          const SizedBox(width: 10),
                                                          AppIcon.of(AppIcon.players, size: 11, color: T.textTertiary),
                                                          const SizedBox(width: 4),
                                                          Flexible(
                                                            child: Text('护航员 ${o.workerNickname}',
                                                                maxLines: 1,
                                                                overflow: TextOverflow.ellipsis,
                                                                style: TextStyle(fontSize: 10.5, color: T.mutedText)),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        const AppHairline(indent: AppDecoSpacing.hairlineIndent),
                                        Padding(
                                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                                          child: Row(
                                            children: [
                                              // 金额：**唯一出口仍是 `fmtMoney`**（页面不拼 `¥`、不补小数位），
                                              // 由 `AppPrice` 渲染成"¥ + 两位小数 + 千分位"的唯一整串
                                              // （`find.text('¥30.00')` 可整串命中）。
                                              //
                                              // 方案 G「价格胶囊」：`#FACC15` 底 + `#3B2400` 字，弱光/大太阳下都读得清
                                              // （实测 9.7:1）。胶囊只包**金额整串**，单位与数量文案留在胶囊外，
                                              // 于是"哪个是钱"一眼可见，而不用给每个数字都上色。
                                              //
                                              // 为什么不用 deco 的 `AppMoney`：它确实实现了 `docs/45 §二④` 的字重与
                                              // 12sp 单位口径，但 `balance_display_test.dart` 对**这一行**做了跨层源码绑定
                                              // （要求字面量 `AppPrice(value: fmtMoney(o.totalAmount)`）——
                                              // 那条断言比换渲染器重要，故金额渲染器仍用 `AppPrice`，只换它的容器。
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: AppColors.pricePillBg,
                                                  borderRadius: BorderRadius.circular(AppDecoRadius.capsule),
                                                ),
                                                child: AppPrice(
                                                  value: fmtMoney(o.totalAmount),
                                                  size: 18,
                                                  color: AppColors.pricePillInk,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Text('×${o.quantityText} ${o.priceUnit}',
                                                  style: TextStyle(fontSize: 11, color: T.textSecondary)),
                                              const Spacer(),
                                              ..._actionsFor(o),
                                            ],
                                          ),
                                        ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
          /**
           * 「正在刷新」弱提示（发丝线级 2dp，绝对定位 → 零布局位移）。
           *
           * 缓存优先先画之后必须给这个信号：屏上此刻是**上一次**的订单，正在追平服务端。
           * 静态细线而非无限动画进度条：本仓出图/渲染用例大量用 `pumpAndSettle`，
           * 无限动画会把它们挂死；静态线同样表达"有活儿在干"，且不闪屏。
           */
          if (_refreshing)
            Positioned(
              top: 46,
              left: 0,
              right: 0,
              child: Container(
                key: OrdersPage.refreshingHairlineKey,
                height: 2,
                color: AppColors.primary.withValues(alpha: 0.45),
              ),
            ),
        ],
      )),
    );
  }

  final RealtimeClient _realtime = RealtimeClient.shared;

  bool _rtWired = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rtWired) return;
    _rtWired = true;
    // 负责人 2026-10-04：接单/开始服务/完成 实时同步（此前要手动刷新或重开）
    // 注意必须 force 强刷：普通 _load 会命中 45s SWR 缓存 → 订单已 completed 而列表仍显示「进行中」
    final tk = AuthStore.instance.accessToken;
    if (tk != null) {
      _realtime.connect(token: tk);
      _realtime.on('order:update', (_) => _reloadQuietly());
      _realtime.on('order:status', (_) => _reloadQuietly());
      // 订单完成 → 直聊会话被删除：订单列表一并强刷（状态与「联系打手」入口同时收敛）
      _realtime.on('conv:removed', (_) => _reloadQuietly());
    }
  }

  /// 静默强刷（保留当前列表，不闪屏；绕过 SWR 缓存，保证事件到达即最新）
  Future<void> _reloadQuietly() async {
    try {
      await _load(force: true);
    } catch (_) {}
  }

  /// 状态筛选胶囊（2026-10-15「全平台品牌化」改版；2026-10 精简为 5 枚）
  ///
  /// ## 一枚胶囊 = 一组内部状态（见 [filterCapsules]）
  /// 点击**只改筛选键、不发请求**：列表由 [_visibleOrders] 就地重算
  /// （与首页 `services_page` 的分类胶囊同一套口径，零请求切换）。
  ///
  /// ## 走斜切角语言（`docs/45 §二⑤` 谱系表）
  /// **未选中 = 不切口**（切口是"选中/状态"的专属信号，两边都切就退化装饰）；
  /// **选中 = 右下 8×8**（[AppNotchRole.filterChip]：胶囊高 32 比标签高一档 → 切口同步升一档；
  /// 右下 = 选中"向前"的方向感）。切口档位由 `deco.dart` 登记、由高度推导，**不在这里手挑数值**。
  ///
  /// ## 去掉旧的玻璃态
  /// 旧实现是"半透明白 + 半透明白描边 + 18dp 圆角 + 深色模式分支"——
  /// 白底为主定案后，未选中恒 **白底 + 1dp 描边**（`#E8ECF2`，方案 G 描边档）、
  /// 选中恒 **近黑实底 [AppColors.chipInk] `#111827` + 白字**（方案 G「状态筛选胶囊」定案：
  /// 选中态是"当前在看什么"的**事实**，不是"可操作"，所以它不吃品牌蓝；
  /// 蓝留给真正可点的动作 —— 主按钮/链接）。
  /// 高度由 31 归到 **32**（4dp 网格 · 也是切口谱系里"高 32 → 8×8"的那一档）。
  Widget _filterPill(String value, String label) {
    final selected = _tab == value;
    const radius = BorderRadius.all(Radius.circular(AppDecoRadius.capsule));
    final ink = selected ? AppColors.chipInk : T.bgCardSolid;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: () {
          if (_tab == value) return; // 已经在这一组：不重建、不发请求
          // **纯本地过滤：一发请求都不发**（全量列表已在手上，按状态组就地分组）
          setState(() => _tab = value);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: AppNotchRole.filterChip.height,
          // 胶囊内距收到 **8**（原 12）：5 枚胶囊一行放得下的必要压缩（每枚省 8dp，5 枚共 40dp）。
          // 写 `AppSpacing.sm` 而不是裸数字：既落 4dp 网格，也避免"手挑一个值"；
          // 为什么不是 10：10 不在允许刻度里（[AppDecoSpacing.grid]）。
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: ink,
            borderRadius: radius,
            border: Border.all(color: selected ? AppColors.chipInk : AppColors.strokeSoft, width: 1),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  // **12**（原 12.5）：与首页筛选胶囊同一档字号，再省一点宽度捐给"5 枚一行放得下"
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? Colors.white : T.textSecondary,
                ),
              ),
              // 右下 8×8 切口：底色盖角 + 只画朝内的两条边（不 ClipPath 真裁）。
              // 位置内缩 1dp = 描边宽，正好让切口的两条边接在描边内侧、把原来那点圆角切掉。
              if (selected)
                Positioned(
                  right: 1,
                  bottom: 1,
                  child: AppNotch.forRole(
                    AppNotchRole.filterChip,
                    baseColor: AppColors.chipInk,
                    borderColor: Colors.white,
                    borderWidth: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 各状态可执行操作（2026-09-25 整改：只显示当前状态真正可以做的）
  List<Widget> _actionsFor(OrderBrief o) => switch (o.status) {
        'pending_take' => [
            OutlinedButton(onPressed: () => _cancel(o), child: const Text('取消订单')),
          ],
        'pending_confirm' => [
            FilledButton(
              onPressed: () => _confirm(o),
              style: FilledButton.styleFrom(backgroundColor: AppColors.success),
              child: const Text('确认完成'),
            ),
          ],
        'completed' => [
            TextButton(onPressed: () => _appealStatus(o), child: const Text('售后进度')),
            const SizedBox(width: AppSpacing.sm),
            OutlinedButton(onPressed: () => _appeal(o), child: const Text('申请售后')),
          ],
        'after_sale' => [
            OutlinedButton(onPressed: () => _appealStatus(o), child: const Text('售后进度')),
          ],
        _ => [],
      };
}

/// 分部精简模型（订单页只用它画订单卡的官方游戏图 + 端游角标）
class _DivisionLite {
  _DivisionLite({
    required this.id,
    required this.gameId,
    required this.color,
    this.gameName = '',
    this.code = '',
    this.platform = '',
    this.iconMediaId,
    this.coverMediaId,
  });

  final String id;
  final String gameId;
  final Color color;
  final String gameName;
  final String code;
  final String platform;
  final String? iconMediaId;
  final String? coverMediaId;

  /// 游戏图标映射键（code → gameName 逐级兜底）
  String get gameKey => '$code $gameName'.trim();

  /// 分部官方图：有图就用图（iconMediaId 优先，其次 coverMediaId；都空 → 自绘游戏图标回退）
  String? get imageMediaId => divisionMediaId(iconMediaId: iconMediaId, coverMediaId: coverMediaId);

  factory _DivisionLite.fromJson(Map json) {
    final hex = (json['themeColor'] as String?)?.replaceFirst('#', '');
    Color? c;
    if (hex != null && hex.length == 6) {
      final n = int.tryParse(hex, radix: 16);
      if (n != null) c = Color(0xFF000000 | n);
    }
    return _DivisionLite(
      id: '${json['id']}',
      gameId: '${json['gameId'] ?? ''}',
      color: c ?? AppColors.primary,
      gameName: '${json['gameName'] ?? ''}',
      code: '${json['code'] ?? ''}',
      platform: '${json['platform'] ?? ''}',
      iconMediaId: json['iconMediaId'] == null ? null : '${json['iconMediaId']}',
      coverMediaId: json['coverMediaId'] == null ? null : '${json['coverMediaId']}',
    );
  }
}
