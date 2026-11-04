import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';
import '../widgets/migration_notice.dart';

/// 工作台首页（负责人需求 #5/#6 重构，参考图3）：
/// 顶部个人展示区（工号/昵称/权限，工作端无会员等级）→ 收益概览（真实后端流水聚合）→ 待处理 → 快捷入口
///
/// 2026-10-06（工作端停用）：页头下方**常驻**一条迁移引导条 —— 说明工作端已合并进「祁连山电竞」App、
/// 打手绑定打手账号后可在老板端接单、并给出下载地址。它不是弹窗、没有遮罩、不可关闭，
/// 但也不占任何操作：收益/待处理/快捷入口与大厅接单全部照旧（接单/抢单/收益逻辑一字未动）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onNavigate, this.refreshSignal, this.api, this.now});

  /// 切换底部 tab（接单大厅/客服会话/排行榜快捷入口）
  final ValueChanged<int>? onNavigate;

  /// 切回首页 tab 时的刷新信号（HomeShell 递增触发）
  final ValueNotifier<int>? refreshSignal;

  /// 接口客户端（缺省自建；测试/出图注入 fixture，行为与线上一致）
  final ApiClient? api;

  /// 注入的"现在"（**测试/出图专用**：引导条到期前/到期后的文案要能确定性复现）；
  /// null = 系统本地时间（生产行为）
  final DateTime? now;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final ApiClient _api = widget.api ?? ApiClient();

  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _wallet;
  Map<String, dynamic>? _pending;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 切回首页 tab / App 回前台自动刷新（收益与待处理实时同步）
    WidgetsBinding.instance.addObserver(this);
    widget.refreshSignal?.addListener(_load);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.refreshSignal?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    // 需求 #6：已有数据时静默刷新，仅首载转圈
    setState(() {
      _error = null;
      if (_stats == null && _wallet == null) _loading = true;
    });
    try {
      final token = AuthStore.instance.accessToken;
      // 并行拉取（统计/收益/订单概览，避免串行等待）
      final results = await Future.wait([
        _api.request('GET', '/worker/my-stats', token: token),
        _api.request('GET', '/worker/my-wallet', token: token),
        _api.request('GET', '/worker/orders', token: token, queryParameters: {'page': 1, 'pageSize': 100}),
      ]);
      _stats = results[0]['data'] as Map<String, dynamic>?;
      _wallet = results[1]['data'] as Map<String, dynamic>?;
      final list = ((results[2]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? []);
      int active = 0, toConfirm = 0, toDispatch = 0;
      for (final o in list) {
        final status = '${(o as Map<String, dynamic>)['status'] ?? ''}';
        if (status == 'taken' || status == 'in_progress') active++;
        if (status == 'pending_confirm') toConfirm++;
        if (status == 'pending_dispatch') toDispatch++;
      }
      _pending = {'active': active, 'toConfirm': toConfirm, 'toDispatch': toDispatch};
      setState(() => _loading = false);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthStore.instance.me;
    return FishGlassPage(
      title: '祁连山电竞',
      blurredTopBar: true,
      body: Column(
        children: [
          // ---------- 迁移引导条（工作端停用；负责人 2026-10-06）----------
          // 固定在页头下方：加载中 / 加载失败 / 正常三种状态都在（不存在"没请求到就看不到"的情况），
          // 不随列表滚走、不遮挡按钮、也不拦截任何手势 —— 打手仍可照常接单，直到自己迁移完
          // （到期后引导条文案自动变"已停止服务"，与阻断页同源）。
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.md, AppSpacing.page, 0),
            child: MigrationNotice(now: widget.now),
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
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                          children: [
                            _buildHeader(me),
                            Padding(
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              child: Column(
                                children: [
                                  _buildEarnings(),
                                  const SizedBox(height: AppSpacing.lg),
                                  _buildPending(),
                                  const SizedBox(height: AppSpacing.lg),
                                  _buildEntries(),
                                ],
                              ),
                            ),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 个人展示区（工作端无会员体系：固定品牌渐变，负责人指令） ----------

  Widget _buildHeader(AuthMe? me) {
    return Container(
      // 玻璃顶栏已消化状态栏高度，顶部不再留 56（2026-09-25 真机反馈：头部整体上移）
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.xl),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primarySecondary],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.7), width: 1.5),
                ),
                child: AppAvatar(nickname: me?.nickname ?? '', mediaId: me?.avatarMediaId, size: 60),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(me?.nickname ?? '未登录', style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text('工号 ${me?.workerNo ?? '-'}', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _chip(
                  // 接单权限按分部细分（负责人 2026-10-04）：显示已授权的分部数量，明细在「我的」页
                  (me?.canTakeOrder ?? false) ? '接单权限（${me!.takeOrderDivisions.length} 个分部）' : '暂无接单权限',
                  me?.canTakeOrder ?? false,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: _chip('客服权限', me?.canServeCustomer ?? false)),
            ],
          ),
          if (!(me?.canTakeOrder ?? false) && !(me?.canServeCustomer ?? false))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text('暂无接单/客服权限，请联系管理员开通', style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12)),
            ),
          // 有接单权限但只覆盖部分分部时，把"能接哪些分部"直接写在首页（避免以为全分部都能接）
          if ((me?.canTakeOrder ?? false) && me!.takeOrderDivisions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                '可接分部：${me.takeOrderDivisions.map((d) => d.label).join(' / ')}',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool enabled) => Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: enabled ? 0.2 : 0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(enabled ? Icons.check_circle : Icons.block, size: 13, color: enabled ? const Color(0xFFB9F6CA) : Colors.white60),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: enabled ? const Color(0xFFB9F6CA) : Colors.white60)),
          ],
        ),
      );

  // ---------- 收益概览（第 6 项：完成单数/累计金额/余额/累计收入，真实后端数据） ----------

  Widget _buildEarnings() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('我的收益', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(child: _stat('完成单数', '${_stats?['completedOrders'] ?? 0}')),
              Container(width: 1, height: 34, color: AppColors.divider),
              Expanded(child: _stat('累计金额', fmtPoints(parsePoints(_stats?['totalAmount'])))),
              Container(width: 1, height: 34, color: AppColors.divider),
              Expanded(child: _stat('收益余额', fmtPoints(parsePoints(_wallet?['balance'])))),
              Container(width: 1, height: 34, color: AppColors.divider),
              Expanded(child: _stat('累计收入', fmtPoints(parsePoints(_wallet?['totalIncome'])))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.primary), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textTertiary)),
        ],
      );

  // ---------- 待处理 ----------

  Widget _buildPending() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('待处理', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              _pendingItem('待确认派单', _pending?['toDispatch'] ?? 0, () => widget.onNavigate?.call(1)),
              _pendingItem('进行中', _pending?['active'] ?? 0, () => widget.onNavigate?.call(1)),
              _pendingItem('待用户确认', _pending?['toConfirm'] ?? 0, () => widget.onNavigate?.call(1)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pendingItem(String label, int count, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSpacing.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Column(
              children: [
                Text('$count', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: count > 0 ? AppColors.primary : AppColors.textTertiary)),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ),
      );

  // ---------- 快捷入口 ----------

  Widget _buildEntries() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('快捷入口', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              _entry('接单大厅', Icons.storefront_outlined, () => widget.onNavigate?.call(1)),
              _entry('客服会话', Icons.support_agent_outlined, () => widget.onNavigate?.call(3)),
              _entry('排行榜', Icons.emoji_events_outlined, () => widget.onNavigate?.call(2)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _entry(String label, IconData icon, VoidCallback onTap) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSpacing.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Column(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.md),
                  ),
                  child: Icon(icon, size: 20, color: AppColors.primary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ),
      );
}
