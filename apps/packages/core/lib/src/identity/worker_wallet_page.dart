import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_ui.dart';
import '../withdraw/worker_withdraw_page.dart';
import '../withdraw/worker_withdraw_records_page.dart';
import 'identity_widgets.dart';

/// 打手态 · **我的收益**（`GET /worker/my-wallet` + `GET /worker/wallet/transactions`）
///
/// 打手态「我的」页的收益入口落点。字段口径全部由服务端下发（docs/06）：
/// `balance`（余额）/ `totalIncome`（累计结算）/ `settlementCount`（结算笔数）/
/// `tipIncome`（打赏收入，100% 到手，不抽成）/ `totalGranted`（管理员发放）。
///
/// **不引入任何老板端元素**：没有会员成长、没有余额卡、没有充值入口（余额只能由平台发放）。
class IdentityWorkerWalletPage extends StatefulWidget {
  const IdentityWorkerWalletPage({super.key, this.api});

  final ApiClient? api;

  @override
  State<IdentityWorkerWalletPage> createState() => _IdentityWorkerWalletPageState();
}

class _IdentityWorkerWalletPageState extends State<IdentityWorkerWalletPage>
    with WithdrawBalanceRefreshMixin<IdentityWorkerWalletPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _transactions = const [];
  bool _loading = true;
  String? _error;

  /// 余额变了（提现申请成功 / 被驳回退回）→ **本页立刻回源**
  ///
  /// 这一页是 push 出来的：只有它挂着的时候才需要刷（没打开就没有监听）。
  @override
  void onWithdrawBalanceChanged() {
    if (mounted) unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([
        _api.request('GET', '/worker/my-wallet', token: AuthStore.instance.activeToken, forceRefresh: true),
        _api.request(
          'GET',
          '/worker/wallet/transactions',
          token: AuthStore.instance.activeToken,
          forceRefresh: true,
          queryParameters: {'page': 1, 'pageSize': 20},
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = results[0]['data'] as Map<String, dynamic>?;
        _transactions = ((results[1]['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 流水类型中文名（服务端 changeType 的口径镜像，只影响展示）
  ///
  /// ⚠️ `order_pay` 显示成「订单支出」而不是「下单支出」：打手态的 22 词黑名单里有「下单」，
  /// 打手态任何屏（含二级页）都不能出现它。
  static String typeName(String t) => switch (t) {
        'order_settlement' => '订单结算',
        'settlement_reversal' => '结算冲正',
        'order_tip_income' => '打赏收入',
        'grant' => '平台发放',
        'order_pay' => '订单支出',
        'refund' => '退款',
        _ => '余额变动',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      appBar: AppBar(
        backgroundColor: T.bgCardSolid,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('我的收益', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
        iconTheme: IconThemeData(color: T.textSecondary),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2)))
            : _error != null
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      IdentityWorkerEmptyState(
                        icon: AppIdentityIcons.info,
                        title: _error!,
                        action: '重试',
                        onAction: _load,
                      ),
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 24),
                    children: [
                      _balanceCard(),
                      const SizedBox(height: 10),
                      // 提现入口：收益页看余额 → 想提就在这里进（不必退回「我的」再找一次）
                      AppIdentityOutlineButton(
                        label: '提现',
                        height: 40,
                        expand: true,
                        onTap: _openWithdraw,
                      ),
                      const SizedBox(height: 12),
                      _summaryCard(),
                      const AppSectionHeader(title: '余额明细', padding: EdgeInsets.fromLTRB(2, 14, 2, 8)),
                      if (_transactions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 30),
                          child: Text('暂无流水',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                        )
                      else
                        Container(
                          decoration: BoxDecoration(
                            color: T.bgCardSolid,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: T.divider),
                          ),
                          child: Column(
                            children: [
                              for (var i = 0; i < _transactions.length; i++) ...[
                                if (i > 0)
                                  Divider(height: 1, thickness: 1, color: AppColors.divider, indent: 14),
                                _txRow(_transactions[i]),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }

  /// 「提现」入口：进申请页（余额不足/未绑定等判定都在那一页，这里只管跳）
  void _openWithdraw() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WorkerWithdrawPage(api: widget.api)),
    );
  }

  Widget _balanceCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: T.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('当前余额', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                fmtMoney(parsePoints(_summary?['balance'])),
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.gold),
              ),
              const SizedBox(width: 6),
              const Text('余额', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryCard() {
    final s = _summary;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: T.divider),
      ),
      child: Row(
        children: [
          _stat(fmtMoney(parsePoints(s?['totalIncome'])), '累计结算'),
          _vDivider(),
          _stat('${(s?['settlementCount'] as num?)?.toInt() ?? 0}', '结算笔数'),
          _vDivider(),
          _stat(fmtMoney(parsePoints(s?['tipIncome'])), '打赏收入'),
          _vDivider(),
          _stat(fmtMoney(parsePoints(s?['totalGranted'])), '平台发放'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: T.textPrimary)),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 10.5, color: AppColors.textTertiary)),
          ],
        ),
      );

  Widget _vDivider() => Container(width: 1, height: 24, color: AppColors.divider);

  Widget _txRow(Map<String, dynamic> t) {
    final amount = parsePoints(t['amount']);
    final positive = amount >= 0;
    final at = DateTime.tryParse('${t['createdAt'] ?? ''}')?.toLocal();
    final time = at == null
        ? ''
        : '${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
            '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(typeName('${t['changeType'] ?? ''}'),
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary)),
                const SizedBox(height: 2),
                Text(
                  [if (time.isNotEmpty) time, '余额 ${fmtMoney(parsePoints(t['balanceAfter']))}'].join(' · '),
                  style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          Text(
            '${positive ? '+' : ''}${fmtMoney(amount)}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: positive ? AppColors.statusOnline : AppColors.mutedText,
            ),
          ),
        ],
      ),
    );
  }
}

/// 打手态收益页的口径常量（测试与页面共用一份，避免两处各写一遍）
class IdentityWorkerWalletRules {
  IdentityWorkerWalletRules._();

  /// 展示用的四个口径（顺序即页面顺序）
  static const fields = ['balance', 'totalIncome', 'settlementCount', 'tipIncome'];

  /// 流水类型中文名（页面展示用）
  static String typeName(String t) => _IdentityWorkerWalletPageState.typeName(t);
}
