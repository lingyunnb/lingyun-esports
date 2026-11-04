import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 排行榜（M7）：周榜/月榜切换、Top 榜单、我的排名与实时统计
class LeaderboardPage extends StatefulWidget {
  const LeaderboardPage({super.key});

  @override
  State<LeaderboardPage> createState() => _LeaderboardPageState();
}

class _LeaderboardPageState extends State<LeaderboardPage> {
  final ApiClient _api = ApiClient();
  String _kind = 'week'; // week / month
  List<dynamic> _list = [];
  Map<String, dynamic>? _me;
  Map<String, dynamic>? _stats;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = AuthStore.instance.accessToken;
      final boardResp = await _api.request('GET', '/worker/leaderboard', token: token, queryParameters: {'kind': _kind});
      final data = boardResp['data'] as Map<String, dynamic>?;
      _list = data?['list'] as List<dynamic>? ?? [];
      _me = data?['me'] as Map<String, dynamic>?;
      final statsResp = await _api.request('GET', '/worker/my-stats', token: token);
      _stats = statsResp['data'] as Map<String, dynamic>?;
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
    return FishGlassPage(
      title: '排行榜',
      blurredTopBar: true,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, AppSpacing.sm, AppSpacing.page, AppSpacing.sm),
            child: Row(
              children: [
                // 周榜/月榜切换胶囊（2026-09-25 与订单页筛选风格统一）
                _pill('周榜', _kind == 'week', () {
                  _kind = 'week';
                  _load();
                }),
                const SizedBox(width: AppSpacing.sm),
                _pill('月榜', _kind == 'month', () {
                  _kind = 'month';
                  _load();
                }),
                const Spacer(),
                if (_stats != null)
                  Text(
                    '已完成 ${_stats?['completedOrders'] ?? 0} 单 · ${fmtPoints(parsePoints(_stats?['totalAmount']))} 积分',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
          if (_me != null)
            Container(
              margin: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppRadii.card),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_outline, size: 16, color: AppColors.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '我的排名：#${_me?['rank'] ?? '-'}（有效金额 ${fmtPoints(parsePoints(_me?['effectiveAmount']))}，完成 ${_me?['completedOrders'] ?? 0} 单）',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
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
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _list.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: const [
                                  Padding(
                                    padding: EdgeInsets.symmetric(vertical: 80),
                                    child: Text('本期暂无榜单数据（管理员重算后显示）', textAlign: TextAlign.center, style: TextStyle(color: AppColors.textTertiary)),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.all(AppSpacing.lg),
                                itemCount: _list.length,
                                separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                                itemBuilder: (ctx, i) {
                                  final e = _list[i] as Map<String, dynamic>;
                                  final top3 = (e['rank'] as num? ?? 99) <= 3;
                                  return Card(
                                    margin: EdgeInsets.zero,
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        radius: 18,
                                        backgroundColor: top3 ? AppColors.warning.withValues(alpha: 0.15) : AppColors.primary.withValues(alpha: 0.08),
                                        child: Text(
                                          '#${e['rank']}',
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: top3 ? AppColors.warning : AppColors.primary),
                                        ),
                                      ),
                                      title: Text('${e['nickname'] ?? '打手'}（${e['workerNo'] ?? ''}）', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                                      subtitle: Text('完成 ${e['completedOrders']} 单', style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
                                      trailing: Text(
                                        fmtPoints(parsePoints(e['effectiveAmount'])),
                                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.primary),
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

  /// 周/月榜切换胶囊（2026-09-25 整改：与订单筛选统一风格）
  Widget _pill(String label, bool selected, VoidCallback onTap) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : (dark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.72)),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: selected ? AppColors.primary : Colors.white.withValues(alpha: 0.35), width: 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
