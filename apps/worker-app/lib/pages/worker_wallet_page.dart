import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 工作端 · 我的积分（负责人 2026-09-25 完整积分入口）：
/// 当前积分 + 累计获得（订单结算/管理员发放）+ 累计消费 + 积分明细（分页）
/// 所有数据来自服务端 wallet_transaction 真实流水聚合，前端零计算。
class WorkerWalletPage extends StatefulWidget {
  const WorkerWalletPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  @override
  State<WorkerWalletPage> createState() => _WorkerWalletPageState();
}

class _WorkerWalletPageState extends State<WorkerWalletPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  Map<String, dynamic>? _summary;
  final List<_Txn> _txns = [];
  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 打赏实时通知退订句柄（负责人 2026-10-04：老板打赏后工作端立即知道）
  void Function()? _offTip;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 实时：收到老板打赏 → 顶部提示 + 立即刷新余额与明细（服务端权威，客户端只做展示）
    _offTip = RealtimeClient.shared.on('tip:received', (data) {
      if (!mounted) return;
      final amount = (data is Map ? data['amount'] : null);
      AppToast.success(context, '收到老板打赏 ${fmtPoints(parsePoints(amount))} 积分');
      _refresh();
    });
  }

  @override
  void dispose() {
    _offTip?.call();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = AuthStore.instance.accessToken;
      final resp = await _api.request('GET', '/worker/my-wallet', token: token);
      setState(() => _summary = resp['data'] as Map<String, dynamic>?);
      _page = 1;
      _txns.clear();
      await _loadMore();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final token = AuthStore.instance.accessToken;
      final resp = await _api.request('GET', '/worker/wallet/transactions', token: token, queryParameters: {'page': _page, 'pageSize': 20});
      final data = resp['data'] as Map<String, dynamic>;
      final list = (data['list'] as List<dynamic>? ?? []).map((e) => _Txn.fromJson(e as Map<String, dynamic>)).toList();
      setState(() {
        _txns.addAll(list);
        _total = (data['total'] as num?)?.toInt() ?? 0;
        _page += 1;
      });
    } on ApiException catch (e) {
      if (mounted) {
        AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _labelFor(String type) => switch (type) {
        'order_settlement' => '订单结算',
        'settlement_reversal' => '结算回退',
        // 负责人 2026-10-04：老板打赏（100% 到手，平台不抽成），与订单结算分开显示
        'order_tip_income' => '老板打赏',
        'order_tip_out' => '打赏支出',
        'grant' => '管理员发放',
        'recover' => '管理员回收',
        _ => type,
      };

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return FishGlassPage(
      title: '我的积分',
      blurredTopBar: true,
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // 余额主卡（与老板端我的积分页一致的渐变锚点）
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.primary, AppColors.primarySecondary],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8)),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Text('当前积分', style: TextStyle(fontSize: 13, color: Colors.white70)),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          fmtPoints(parsePoints(s?['balance'])),
                          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FishGlassCard(
                    insideMargin: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      children: [
                        Expanded(child: _stat('累计获得', fmtPoints(parsePoints(s?['totalIncome'])))),
                        Container(width: 1, height: 26, color: T.divider),
                        Expanded(child: _stat('订单结算', fmtPoints(parsePoints(s?['totalIncome'])))),
                        Container(width: 1, height: 26, color: T.divider),
                        Expanded(child: _stat('管理员发放', fmtPoints(parsePoints(s?['totalGranted'])))),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FishGlassCard(
                    insideMargin: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      children: [
                        Expanded(child: _stat('累计消费', fmtPoints(parsePoints(s?['totalSpent'])))),
                        Container(width: 1, height: 26, color: T.divider),
                        Expanded(child: _stat('结算单数', '${s?['settlementCount'] ?? 0}')),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // 打赏收益（负责人 2026-10-04）：老板打赏 100% 到打手，独立于 70% 订单结算展示
                  FishGlassCard(
                    insideMargin: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      children: [
                        Expanded(child: _stat('打赏收益', fmtPoints(parsePoints(s?['tipIncome'])))),
                        Container(width: 1, height: 26, color: T.divider),
                        Expanded(child: _stat('打赏笔数', '${s?['tipCount'] ?? 0}')),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.lg),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.error)),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  const Text('积分明细', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.sm),
                  if (_txns.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                      child: Text('暂无流水', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textTertiary)),
                    )
                  else
                    FishGlassCard(
                      insideMargin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 2),
                      child: Column(
                        children: [
                          for (int i = 0; i < _txns.length; i++) ...[
                            if (i > 0) Divider(height: 1, color: T.divider),
                            _txnRow(_txns[i]),
                          ],
                        ],
                      ),
                    ),
                  if (_txns.length < _total)
                    Center(
                      child: TextButton(
                        onPressed: _loadMore,
                        child: _loadingMore ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('加载更多'),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ],
      );

  Widget _txnRow(_Txn t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_labelFor(t.changeType), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  if (t.reason != null && t.reason!.isNotEmpty)
                    Text(t.reason!, style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  t.amount > 0 ? '+${fmtPoints(t.amount)}' : fmtPoints(t.amount),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: t.amount > 0 ? AppColors.success : AppColors.error,
                  ),
                ),
                Text('余额 ${fmtPoints(t.balanceAfter)}', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
              ],
            ),
          ],
        ),
      );
}

class _Txn {
  const _Txn(this.amount, this.changeType, this.reason, this.balanceAfter, this.createdAt);

  final double amount; // 小数价目：必须 double + parsePoints，禁止 as int
  final String changeType;
  final String? reason;
  final double balanceAfter;
  final String createdAt;

  factory _Txn.fromJson(Map<String, dynamic> json) => _Txn(
        parsePoints(json['amount']),
        json['changeType'] as String? ?? '',
        json['reason'] as String?,
        (json['balanceAfter'] as num?)?.toDouble() ?? 0,
        json['createdAt'] as String? ?? '',
      );
}
