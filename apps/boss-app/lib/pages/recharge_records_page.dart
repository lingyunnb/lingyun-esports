import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 「我的充值记录」（入口在充值页内）—— 负责人 2026-10-06 方案①
///
/// 每行：付款金额 / 到账余额 / 状态（待审核 · 已到账 · 已驳回 + 原因）/ 时间。
/// 状态文案由 [RechargeRequestItem.statusText] 统一给（只翻译已知状态，未知显示服务端原文）；
/// **这里的"已到账"是超管手工发放的结果**，与"支付成功"是两件事（合规口径见 `RechargeCopy`）。
class RechargeRecordsPage extends StatefulWidget {
  const RechargeRecordsPage({super.key, this.api});

  final ApiClient? api;

  static const int pageSize = 20;

  @override
  State<RechargeRecordsPage> createState() => _RechargeRecordsPageState();
}

class _RechargeRecordsPageState extends State<RechargeRecordsPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  List<RechargeRequestItem> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = true}) async {
    if (!mounted) return;
    setState(() {
      _error = null;
      if (_items.isEmpty) _loading = true;
    });
    try {
      final resp = await _api.request(
        'GET',
        '/user/recharge/requests',
        queryParameters: {'page': 1, 'pageSize': RechargeRecordsPage.pageSize},
        token: AuthStore.instance.accessToken,
        forceRefresh: force,
      );
      final page = RechargeRequestPage.fromData(resp['data']);
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          AppPageHeader(title: '我的充值记录', onBack: () => Navigator.of(context).maybePop()),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary));
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 16, AppSpacing.page, 24),
        children: [
          AppCard(
            child: Row(
              children: [
                AppIcon.of(AppIcon.info, size: 18, color: T.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('充值记录加载失败', style: TextStyle(fontSize: 12.5, color: T.textSecondary)),
                      const SizedBox(height: 2),
                      Text(_error!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: T.textTertiary)),
                    ],
                  ),
                ),
                TextButton(onPressed: () => _load(), child: const Text('重试')),
              ],
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            AppEmpty(icon: AppIdentityIcons.receipt, text: '还没有充值申请，付完款上传截图就能提交'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 24),
        itemCount: _items.length,
        itemBuilder: (_, i) => Padding(
          padding: EdgeInsets.only(bottom: i == _items.length - 1 ? 0 : 10),
          child: _card(_items[i]),
        ),
      ),
    );
  }

  Widget _card(RechargeRequestItem r) {
    final tone = r.isGranted
        ? AppColors.success
        : (r.isRejected ? AppColors.error : AppColors.primary);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(RechargeRules.formatYuan(r.amountYuan),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.textPrimary)),
              const SizedBox(width: 8),
              AppTag(r.statusText, color: tone),
              const Spacer(),
              AppPrice(value: fmtMoney(r.points), size: 15),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _timeText(r.grantedAt ?? r.createdAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
              ),
              if (r.note.isNotEmpty)
                Flexible(
                  child: Text(
                    '备注：${r.note}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 11, color: AppColors.mutedText),
                  ),
                ),
            ],
          ),
          if (r.isRejected && r.rejectReason.isNotEmpty) ...[
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.bannerDangerBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.bannerDangerBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1.5),
                    child: AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('驳回原因：${r.rejectReason}',
                        style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
                  ),
                ],
              ),
            ),
          ],
          if (r.isPending) ...[
            const SizedBox(height: 8),
            const Text('客服核对付款截图后发放余额，请耐心等待',
                style: TextStyle(fontSize: 11, color: AppColors.mutedText, height: 1.45)),
          ],
        ],
      ),
    );
  }

  static String _timeText(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}';
  }
}
