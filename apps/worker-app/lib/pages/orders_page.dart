

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../widgets/fish_glass.dart';

/// 订单（阶段 16 + 结算需求 + 派单）：接单大厅（抢单）+ 我的订单（开始服务/提交完成/派单确认拒绝）
/// 接单权限由服务端每次请求实时校验（docs/04）；派单通知走实时通道（docs/07）
class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  int _tab = 0; // 0 大厅 / 1 我的订单
  final List<OrderBrief> _hall = [];
  final List<OrderBrief> _mine = [];
  bool _loading = true;
  String? _error;

  /// 大厅分部筛选（负责人第 7 条）：null = 全部分部
  String? _divisionId;
  List<({String id, String name})> _divisions = const [];

  /// 服务端下发的"该分部无接单权限"提示（大厅响应里的 divisionDenied/message）——
  /// 权限由服务端判定，客户端只负责把中文提示显示出来（负责人 2026-10-04 硬要求）
  String? _hallDeniedMessage;

  final List<void Function()> _offEvents = [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadDivisions();
    _initRealtime();
  }

  /// 我的分部接单权限（负责人 2026-10-04：接单权限按分部细分）
  ///
  /// 大厅的**分部筛选胶囊只列有权限的分部** —— 没权限的分部根本不该出现在筛选里，
  /// 从源头上避免"点进去空空如也"。权限每次请求实时查库（管理端刚改立刻反映）。
  /// 兼容多种返回形态：data 为 List，或为 { list: [...] }；异常一律静默退化（不挡大厅使用）。
  Future<void> _loadDivisions() async {
    try {
      final resp = await _api.request('GET', '/worker/division-permissions', token: AuthStore.instance.accessToken);
      final data = resp['data'];
      final raw = data is List ? data : (data is Map ? (data['list'] as List?) : null) ?? const [];
      if (!mounted) return;
      setState(() {
        _divisions = raw
            .whereType<Map>()
            .where((d) => d['canTakeOrder'] == true)
            .map((d) => (id: '${d['divisionId']}', name: (d['name'] as String?) ?? ''))
            .where((d) => d.id.isNotEmpty && d.name.isNotEmpty)
            .toList();
        // 当前选中的分部若已失去权限（管理端刚撤销）→ 回到"全部分部"，避免停在空白分部上
        if (_divisionId != null && !_divisions.any((d) => d.id == _divisionId)) {
          _divisionId = null;
        }
      });
    } catch (_) {
      // 拉不到权限不影响大厅使用（退化为"全部分部"，服务端仍会按权限过滤）
    }
  }

  /// 静默强刷（保留当前列表，不闪屏；绕过 SWR 缓存）
  ///
  /// 负责人 2026-10-04 报障「单子完成了还显示进行中」：`/worker/orders` 走 45s 列表缓存，
  /// 状态变化事件到达后若只做普通 `_load()`，45s 内命中旧缓存 → 工作端仍显示旧状态。
  Future<void> _reloadQuietly() async {
    try {
      await _load(force: true);
    } catch (_) {}
  }

  void _initRealtime() {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    _realtime.connect(token: token);
    _offEvents.add(_realtime.on('dispatch:new', (data) => _onDispatchNew(data)));
    // 负责人 2026-10-04：新单/被抢/状态变更实时同步（此前要大退才能看到）；一律 force 绕过缓存
    _offEvents.add(_realtime.on('order:new', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('order:update', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('dispatch:expired', (_) => _onDispatchChanged('派单已超时，订单回到大厅')));
    _offEvents.add(_realtime.on('dispatch:canceled', (_) => _onDispatchChanged('管理员已撤销派单')));
    // 订单完成 → 该「老板↔打手」直聊被删除：工作端订单列表强刷（状态立即变已完成）
    _offEvents.add(_realtime.on('conv:removed', (_) => _reloadQuietly()));

  }

  /// 派单通知：弹窗提示，确认/拒绝都在弹窗内完成（docs/05：仅被派对象可操作，服务端校验）
  Future<void> _onDispatchNew(dynamic data) async {
    final map = data is Map ? data : null;
    if (map == null) return;
    final orderId = '${map['orderId'] ?? ''}';
    final orderNo = '${map['orderNo'] ?? ''}';
    final amount = fmtPoints(parsePoints(map['totalAmount']));
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新的派单'),
        content: Text('订单 $orderNo\n金额 $amount 积分\n请在 5 分钟内确认，超时自动回到大厅'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'reject'), child: const Text('拒绝')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'accept'), child: const Text('确认接单')),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'accept') {
      await _action('/worker/orders/$orderId/accept', '已接单');
    } else {
      await _action('/worker/orders/$orderId/reject', '已拒绝，订单回到大厅');
    }
  }

  Future<void> _onDispatchChanged(String msg) async {
    if (!mounted) return;
    AppToast.info(context, msg); // 品牌浮层（替代系统默认黑色 SnackBar）
    await _load();
  }

  @override
  void dispose() {

    for (final off in _offEvents) {
      off();
    }

    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    // 需求 #6：已有数据时静默刷新，仅首载/空态转圈
    setState(() {
      _error = null;
      if (_hall.isEmpty && _mine.isEmpty) _loading = true;
    });
    try {
      final token = AuthStore.instance.accessToken;
      // 接单大厅按分部筛选（负责人第 7 条：工作端也要改，大厅支持分部）；
      // 服务端按「打手 × 分部」接单权限过滤，无权限分部返回空列表 + 中文提示
      final hallResp = await _api.request('GET', '/worker/order-hall',
          token: token, forceRefresh: force, queryParameters: {
        'page': 1,
        'pageSize': 50,
        'divisionId': ?_divisionId,
      });
      final hallData = hallResp['data'] as Map<String, dynamic>?;
      _hall
        ..clear()
        ..addAll((hallData?['list'] as List<dynamic>? ?? [])
            .map((e) => OrderBrief.fromJson(e as Map<String, dynamic>)));
      _hallDeniedMessage = hallData?['divisionDenied'] == true
          ? ((hallData?['message'] as String?) ?? '你暂无该分部的接单权限，请联系管理员')
          : null;
      final mineResp = await _api.request('GET', '/worker/orders',
          token: token, forceRefresh: force, queryParameters: {'page': 1, 'pageSize': 50});
      _mine
        ..clear()
        ..addAll(((mineResp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
            .map((e) => OrderBrief.fromJson(e as Map<String, dynamic>)));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _action(String path, String successMsg) async {
    try {
      await _api.request('POST', path, token: AuthStore.instance.accessToken, data: {});
      if (!mounted) return;
      AppToast.success(context, successMsg);
      // 抢单/接单可能刚拿到新分部的权限边界变化 → 权限与大厅一起刷（每次都实时查库）
      await _loadDivisions();
      await _load(force: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _tab == 0 ? _hall : _mine;
    return FishGlassPage(
      title: '订单',
      blurredTopBar: true,
      body: Column(
        children: [
          // 玻璃分段 Tab（与老板端消息页统一组件，2026-09-25）
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: MiuixGlassSegmentedTabRow(
              tabs: const ['接单大厅', '我的订单'],
              selectedIndex: _tab,
              onSelect: (i) => setState(() => _tab = i),
            ),
          ),
          // 大厅分部筛选（负责人第 7 条）：全部分部 + 各分部胶囊；只在接单大厅显示
          if (_tab == 0 && _divisions.isNotEmpty)
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
                itemCount: _divisions.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final isAll = i == 0;
                  final d = isAll ? null : _divisions[i - 1];
                  final on = isAll ? _divisionId == null : _divisionId == d!.id;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _divisionId = isAll ? null : d!.id);
                      _load(force: true);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: on ? AppColors.primary : AppColors.bgCard,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: on ? AppColors.primary : AppColors.divider),
                      ),
                      child: Text(
                        isAll ? '全部分部' : d!.name,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                          color: on ? Colors.white : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
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
                      : list.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 80),
                                  child: Text(
                                    // 无权限分部/无任何分部权限时，显示服务端下发的中文提示（负责人 2026-10-04）
                                    _tab == 0 ? (_hallDeniedMessage ?? '大厅暂无待接订单') : '暂无我的订单',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: AppColors.textTertiary),
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              itemCount: list.length,
                              itemBuilder: (ctx, i) {
                                final o = list[i];
                                return Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(AppSpacing.lg),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text('订单 ${o.orderNo}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                            const Spacer(),
                                            Text(o.statusName, style: TextStyle(fontSize: 12, color: o.status == 'completed' ? AppColors.success : AppColors.textSecondary)),
                                          ],
                                        ),
                                        const SizedBox(height: AppSpacing.sm),
                                        // 单子内容与数量：多老板点同一商品 = 各自一条订单，绝不合并（负责人需求 2026-09-24）
                                        if (o.productName.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                                            child: Text(
                                              '${o.productName} × ${o.quantityText}',
                                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                            ),
                                          ),
                                        Text('${o.amountText} 积分', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.primary)),
                                        // 老板游戏分区/游戏ID：只有抢上单后（我的订单）才显示；大厅服务端不返回（隐私铁律）
                                        if (_tab == 1 && (o.gameZone != null || o.gamePlayerId != null)) ...[
                                          const SizedBox(height: AppSpacing.sm),
                                          Text(
                                            '老板游戏：${o.zoneText} · ID ${o.gamePlayerId ?? '-'}',
                                            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                                          ),
                                        ],
                                        const SizedBox(height: AppSpacing.md),
                                        Row(
                                          children: [
                                            if (_tab == 0)
                                              FilledButton(onPressed: () => _action('/worker/orders/${o.id}/grab', '抢单成功'), child: const Text('抢单')),
                                            if (_tab == 1 && o.status == 'pending_dispatch') ...[
                                              FilledButton(onPressed: () => _action('/worker/orders/${o.id}/accept', '已接单'), child: const Text('确认接单')),
                                              const SizedBox(width: AppSpacing.sm),
                                              OutlinedButton(onPressed: () => _action('/worker/orders/${o.id}/reject', '已拒绝'), child: const Text('拒绝')),
                                            ],
                                            if (_tab == 1 && o.status == 'taken')
                                              FilledButton(onPressed: () => _action('/worker/orders/${o.id}/start', '已开始服务'), child: const Text('开始服务')),
                                            if (_tab == 1 && o.status == 'in_progress')
                                              FilledButton(
                                                onPressed: () => _action('/worker/orders/${o.id}/submit', '已提交完成，等待老板确认'),
                                                style: FilledButton.styleFrom(backgroundColor: AppColors.success),
                                                child: const Text('提交完成'),
                                              ),
                                            const Spacer(),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
          ),
        ],
      ),
    );
  }
}
