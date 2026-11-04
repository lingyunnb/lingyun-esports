import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../identity/identity_widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_page_bg.dart';
import 'withdraw_media.dart';
import 'withdraw_models.dart';
import 'worker_withdraw_page.dart';

/// ============================================================================
/// 打手态 · **提现记录**（`GET /worker/withdraw/requests?page=`）
/// ============================================================================
///
/// 每行：金额 + 状态标签（`处理中`/`已打款`/`已驳回`）+ 申请时间 + （打款时间 | 驳回原因）。
///
/// ## 状态三态是**服务端口径的镜像**，不是客户端判断
/// [WorkerWithdrawRequest.statusText] 只翻译已知状态；遇到没见过的状态值**原样显示**，
/// 绝不猜（猜错的代价是"钱到底到没到"这件事上说谎）。
///
/// ## 时间格式只有一个出口
/// [WorkerWithdrawRecordsPage.timeText] 被本页与管理员端列表共用：
/// `MM-DD HH:mm`，空值给 `—`（不显示 null）。
class WorkerWithdrawRecordsPage extends StatefulWidget {
  const WorkerWithdrawRecordsPage({super.key, this.api, this.pageSize = 20});

  final ApiClient? api;

  /// 每页条数（默认 20）
  final int pageSize;

  /// 列表行的 key 前缀（测试/出图定位）
  static Key rowKey(String id) => Key('withdraw-record-$id');

  /// 时间展示（**唯一出口**：打手端记录页 + 管理员端列表/详情共用）
  static String timeText(DateTime? t, {String suffix = ''}) {
    if (t == null) return '—';
    final l = t.toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}$suffix';
  }

  @override
  State<WorkerWithdrawRecordsPage> createState() => _WorkerWithdrawRecordsPageState();
}

class _WorkerWithdrawRecordsPageState extends State<WorkerWithdrawRecordsPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  List<WorkerWithdrawRequest> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 余额/状态可能刚变过（申请成功 → 进来就要看到新记录）→ 每次进入都回源
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _error = null;
      if (_items.isEmpty) _loading = true;
    });
    try {
      final resp = await _api.request(
        'GET',
        '/worker/withdraw/requests',
        token: AuthStore.instance.activeToken,
        forceRefresh: true,
        queryParameters: {'page': 1, 'pageSize': widget.pageSize},
      );
      final page = WorkerWithdrawRequestPage.fromData(resp['data']);
      if (!mounted) return;
      setState(() {
        _items = page.list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: Column(
        children: [
          IdentityWorkerPageHeader(
            title: WorkerWithdrawCopy.recordsTitle,
            actions: [
              IdentityWorkerHeaderButton(
                icon: AppIdentityIcons.refresh,
                tooltip: '刷新',
                onTap: _load,
              ),
              const SizedBox(width: 8),
              IdentityWorkerHeaderButton(
                icon: AppIdentityIcons.close,
                tooltip: '返回',
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          Expanded(child: _body()),
        ],
      )),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary));
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          IdentityWorkerEmptyState(
            icon: AppIdentityIcons.info,
            title: _error!,
            detail: '下拉可重试。',
            action: '重试',
            onAction: _load,
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            IdentityWorkerEmptyState(
              icon: AppIdentityIcons.receipt,
              title: WorkerWithdrawCopy.recordsEmpty,
              detail: WorkerWithdrawCopy.recordsEmptyDetail,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 24),
        children: [
          Container(
            decoration: BoxDecoration(
              color: T.bgCardSolid,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: T.divider),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _items.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.divider, indent: 14),
                  _row(_items[i]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              '共 ${_items.length} 笔 · 下拉可刷新',
              style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ),
          const SizedBox(height: 12),
          AppIdentityOutlineButton(
            label: WorkerWithdrawCopy.pageTitle,
            height: 40,
            expand: true,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => WorkerWithdrawPage(api: widget.api)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(WorkerWithdrawRequest r) {
    return Padding(
      key: WorkerWithdrawRecordsPage.rowKey(r.id),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      fmtMoney(r.amount),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: T.textPrimary),
                    ),
                    const SizedBox(width: 8),
                    _statusTag(r),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '申请 ${WorkerWithdrawRecordsPage.timeText(r.appliedAt)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
                if (r.isPaid)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '打款 ${WorkerWithdrawRecordsPage.timeText(r.paidAt)}',
                      style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ),
                if (r.isRejected && r.rejectReason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      '驳回原因：${r.rejectReason}',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45),
                    ),
                  ),
                if (r.balanceAfter != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '申请后余额 ${fmtMoney(r.balanceAfter!)}',
                      style: const TextStyle(fontSize: 11, color: AppColors.mutedText),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 状态标签：三态各自的颜色（**不用彩色小标签堆砌**：一行只有一个）
  Widget _statusTag(WorkerWithdrawRequest r) {
    final (Color bg, Color border, Color fg) = r.isPaid
        ? (AppColors.statusOnlineSoft, AppColors.bannerOkBorder, AppColors.bannerOkInk)
        : r.isRejected
            ? (AppColors.bannerDangerBg, AppColors.bannerDangerBorder, AppColors.error)
            : (AppColors.ice, AppColors.bannerInfoBorder, AppColors.primary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border),
      ),
      child: Text(
        r.statusText,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

/// 「我的收益 / 提现」入口（打手态「我的」页；提交后余额变化时自动回源）
///
/// ## 为什么入口长这样
/// - 一行，**只有标题 + 一句说明 + 右箭头**（docs/21：不存在的东西不出现；
///   提现不是营销位，不需要色块/图标堆砌）；
/// - 放在「我的」页：负责人 2026-10-11 定案 —— 打手态只显示三处，
///   提现属于「我的」，不新开 tab、不占底栏；
/// - 标题用 [WorkerWithdrawCopy.entryTitle]「我的收益 / 提现」：**同一行同时给出
///   "看收益"与"提现"两条出路**，用户不必先猜该点哪一个。
class WorkerWithdrawEntry extends StatelessWidget {
  const WorkerWithdrawEntry({super.key, required this.onTap, this.balance});

  final VoidCallback onTap;

  /// 可用余额（null = 还没拉到 → 显示 `—`，不显示 0 骗人）
  final num? balance;

  static const Key entryKey = Key('worker-withdraw-entry');

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: WorkerWithdrawEntry.entryKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.ice, borderRadius: BorderRadius.circular(6)),
              child: const Icon(AppIdentityIcons.wallet, size: 16, color: AppColors.primary),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    WorkerWithdrawCopy.entryTitle,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    balance == null
                        ? WorkerWithdrawCopy.entrySubtitle
                        : '可用余额 ${fmtMoney(balance!)} · 绑定收款信息后可申请',
                    style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
                  ),
                ],
              ),
            ),
            Icon(AppIdentityIcons.chevron, size: 16, color: T.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 打手态余额页面的刷新订阅（「我的」/「我的收益」各挂一次）
///
/// 用法：页面 `State` 混入本 mixin，并实现 [onWithdrawBalanceChanged]（一行 `unawaited(_load())`）：
/// ```dart
/// class _XxxState extends State<Xxx> with WithdrawBalanceRefreshMixin<Xxx> {
///   @override
///   void onWithdrawBalanceChanged() { if (mounted) unawaited(_load()); }
/// }
/// ```
/// 注册与注销都在这里，页面只写"被通知时做什么"——避免两处各写一遍
/// `addListener/removeListener`（漏掉 remove 就是泄漏，漏掉 add 就是"余额不刷新"）。
/// 见 [WithdrawRefreshNotifier] 的说明：这不是状态容器，只是"该回源了"的一个信号。
mixin WithdrawBalanceRefreshMixin<T extends StatefulWidget> on State<T> {
  /// 余额可能变了 → 页面自己回源
  void onWithdrawBalanceChanged();

  @override
  void initState() {
    super.initState();
    WithdrawRefreshNotifier.instance.addListener(onWithdrawBalanceChanged);
  }

  @override
  void dispose() {
    WithdrawRefreshNotifier.instance.removeListener(onWithdrawBalanceChanged);
    super.dispose();
  }
}
