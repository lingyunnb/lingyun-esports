import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../icons/app_icon.dart';
import '../models/order_brief.dart';
import '../realtime/realtime_client.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_toast.dart';
import 'identity_widgets.dart';

/// 打手态 · **我的订单**（从「我的」页进入的二级页，不占底部导航 —— 保持"只显示三处"）
///
/// 功能与工作端 App 的「我的订单」等价：派单确认 / 拒绝、开始服务、提交完成。
/// 数据源 `GET /worker/orders`（伴随会话白名单内），派单推送走 `dispatch:new`。
class IdentityWorkerOrdersPage extends StatefulWidget {
  const IdentityWorkerOrdersPage({super.key, this.api});

  final ApiClient? api;

  @override
  State<IdentityWorkerOrdersPage> createState() => _IdentityWorkerOrdersPageState();
}

class _IdentityWorkerOrdersPageState extends State<IdentityWorkerOrdersPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final RealtimeClient _realtime = RealtimeClient.shared;
  final List<void Function()> _offEvents = [];

  final List<OrderBrief> _orders = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _initRealtime();
  }

  @override
  void dispose() {
    for (final off in _offEvents) {
      off();
    }
    super.dispose();
  }

  void _initRealtime() {
    final token = AuthStore.instance.activeToken;
    if (token == null) return;
    _realtime.connect(token: token);
    _offEvents.add(_realtime.on('dispatch:new', (data) => _onDispatchNew(data)));
    _offEvents.add(_realtime.on('order:update', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('dispatch:expired', (_) => _reloadQuietly()));
    _offEvents.add(_realtime.on('dispatch:canceled', (_) => _reloadQuietly()));
  }

  Future<void> _reloadQuietly() async {
    try {
      await _load(force: true);
    } catch (_) {}
  }

  /// 派单通知：确认/拒绝都在弹窗内完成（服务端只允许被派对象操作）
  Future<void> _onDispatchNew(dynamic data) async {
    final map = data is Map ? data : null;
    if (map == null || !mounted) return;
    final orderId = '${map['orderId'] ?? ''}';
    final orderNo = '${map['orderNo'] ?? ''}';
    final amount = fmtMoney(parsePoints(map['totalAmount']));
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新的派单'),
        content: Text('订单 $orderNo\n金额 $amount\n请在 5 分钟内确认，超时自动回到大厅'),
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

  Future<void> _load({bool force = false}) async {
    setState(() {
      _error = null;
      if (_orders.isEmpty) _loading = true;
    });
    try {
      final resp = await _api.request(
        'GET',
        '/worker/orders',
        token: AuthStore.instance.activeToken,
        forceRefresh: force,
        queryParameters: {'page': 1, 'pageSize': 50},
      );
      final list = ((resp['data'] as Map<String, dynamic>?)?['list'] as List<dynamic>? ?? [])
          .map((e) => OrderBrief.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _orders
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _action(String path, String successMsg) async {
    try {
      await _api.request('POST', path, token: AuthStore.instance.activeToken, data: {});
      if (!mounted) return;
      AppToast.success(context, successMsg);
      await _load(force: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      appBar: AppBar(
        backgroundColor: T.bgCardSolid,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('我的订单', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
        iconTheme: IconThemeData(color: T.textSecondary),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
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
                        onAction: () => _load(force: true),
                      ),
                    ],
                  )
                : _orders.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          IdentityWorkerEmptyState(
                            icon: AppIdentityIcons.receipt,
                            title: '暂无我的订单',
                            detail: '在接单大厅抢单成功后，订单会出现在这里；被平台派单也会出现在这里。',
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 22),
                        itemCount: _orders.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _card(_orders[i]),
                      ),
      ),
    );
  }

  Widget _card(OrderBrief o) {
    final no = o.orderNo.length > 4 ? o.orderNo.substring(o.orderNo.length - 4) : o.orderNo;
    final hasGame = o.gameZone != null || o.gamePlayerId != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: T.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                o.productName.isEmpty ? '订单 $no' : o.productName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: T.textPrimary, height: 1.38),
              ),
              const Spacer(),
              Text(
                o.statusName,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: o.status == 'completed' ? AppColors.statusOnline : AppColors.mutedText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('× ${o.quantityText} 单', style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('|', style: TextStyle(fontSize: 11.5, color: T.divider)),
              ),
              Text('单号 $no', style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
              const Spacer(),
              Text(fmtMoney(o.totalAmount),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.goldText)),
              const SizedBox(width: 3),
              const Text('余额', style: TextStyle(fontSize: 10.5, color: AppColors.mutedText)),
            ],
          ),
          // 老板游戏区服与 ID：**只有抢上单之后**服务端才下发（隐私铁律，大厅不返回）
          if (hasGame) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                AppIcon.of(AppIdentityIcons.badge, size: 13, color: T.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '老板游戏：${o.zoneText} · ID ${o.gamePlayerId ?? '-'}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ],
          if (_actionsFor(o).isNotEmpty) ...[
            Container(
              margin: const EdgeInsets.only(top: 11),
              padding: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
              child: Row(
                children: [
                  const Spacer(),
                  for (final a in _actionsFor(o)) ...[
                    a,
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _actionsFor(OrderBrief o) {
    final id = o.id;
    return switch (o.status) {
      'pending_dispatch' => [
          AppIdentityOutlineButton(label: '拒绝', onTap: () => _action('/worker/orders/$id/reject', '已拒绝')),
          AppIdentityPrimaryButton(
            label: '确认接单',
            height: 32,
            expand: false,
            onPressed: () => _action('/worker/orders/$id/accept', '已接单'),
          ),
        ],
      'taken' => [
          AppIdentityPrimaryButton(
            label: '开始服务',
            height: 32,
            expand: false,
            onPressed: () => _action('/worker/orders/$id/start', '已开始服务'),
          ),
        ],
      'in_progress' => [
          AppIdentityPrimaryButton(
            label: '提交完成',
            height: 32,
            expand: false,
            color: AppColors.statusOnline,
            onPressed: () => _action('/worker/orders/$id/submit', '已提交完成，等待老板确认'),
          ),
        ],
      _ => const <Widget>[],
    };
  }
}
