import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 我的余额（阶段 10，docs/06）：余额 + 流水（只读；余额只能由平台发放）
/// 2026-10-09 口径：计价单位 = 余额（1 元 = 1 元），金额一律 `fmtMoney`（¥ + 两位小数 + 千分位）
class WalletPage extends StatefulWidget {
  const WalletPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _Txn {
  const _Txn(this.amount, this.changeType, this.reason, this.balanceAfter, this.createdAt);

  final double amount; // 小数金额（5.5 这类价目）：必须用 double + parsePoints，禁止 as int
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

class _WalletPageState extends State<WalletPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  double? _balance;
  final List<_Txn> _txns = [];
  int _page = 1;
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = AuthStore.instance.accessToken;
      final balance = await _api.request('GET', '/user/wallet', token: token,
          forceRefresh: force);
      setState(() => _balance = ((balance['data'] as Map<String, dynamic>?)?['balance'] as num?)?.toDouble() ?? 0);
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
      final resp = await _api.request('GET', '/user/wallet/transactions', token: token, queryParameters: {'page': _page, 'pageSize': 20});
      final data = resp['data'] as Map<String, dynamic>;
      final list = (data['list'] as List<dynamic>? ?? []).map((e) => _Txn.fromJson(e as Map<String, dynamic>)).toList();
      setState(() {
        _txns.addAll(list);
        _total = data['total'] as int? ?? 0;
        _page += 1;
      });
    } on ApiException catch (e) {
      if (mounted) {
        AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
      }
    } finally {
      setState(() => _loadingMore = false);
    }
  }

  String _labelFor(String type) => switch (type) {
        'grant' => '发放',
        'recover' => '回收',
        'order_pay' => '下单扣款',
        'order_refund' => '退款',
        // 负责人 2026-10-04：打赏（老板出账，金额 100% 到打手，平台不抽成）
        'order_tip_out' => '打赏打手',
        'order_tip_income' => '收到打赏',
        // ⚠️ 兜底必须是**中文**，不能回落成原始枚举名。
        //
        // 历史实现是 `_ => type`，于是任何没列进来的服务端类型都会把英文枚举
        // **原样印在用户界面上**（实测 `order_settlement` 渲染成 "order_settlement"，
        // 见回归出图 `build/balance_1_wallet.png` 第二行流水）。
        // 口径与打手态收益页 `core/.../identity/worker_wallet_page.dart` 的
        // `typeName()` 兜底逐字一致（那边一直是 `_ => '余额变动'`）。
        _ => '余额变动',
      };

  @override
  Widget build(BuildContext context) {
    return FishGlassPage(
      title: '我的余额',
      blurredTopBar: true,
      body: RefreshIndicator(
        onRefresh: () => _refresh(force: true),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // 余额主卡：主色渐变（HyperOS 风格视觉锚点）
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
                        const Text('当前余额', style: TextStyle(fontSize: 13, color: Colors.white70)),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          fmtMoney(_balance ?? 0),
                          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        const Text('余额由平台发放 · 仅限平台内消费，不可提现、不可转让',
                            style: TextStyle(fontSize: 12, color: Colors.white60)),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.lg),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.error)),
                    ),
                  const SizedBox(height: AppSpacing.xl),
                  const Text('余额流水', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: AppSpacing.sm),
                  if (_txns.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                      child: Text('暂无流水', textAlign: TextAlign.center, style: TextStyle(color: AppColors.mutedText)),
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
                    Text(t.reason!, style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  t.amount > 0 ? '+${fmtMoney(t.amount)}' : fmtMoney(t.amount),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: t.amount > 0 ? AppColors.success : AppColors.error,
                  ),
                ),
                Text('余额 ${fmtMoney(t.balanceAfter)}', style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
              ],
            ),
          ],
        ),
      );
}
