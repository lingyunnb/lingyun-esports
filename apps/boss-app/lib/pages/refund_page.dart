import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 退款（顶部导航入口 · 负责人 2026-10-04）
///
/// 结构规则（CLAUDE.md 规则 1）：退款页 = **选订单 → 申请** 的列表页，提交后回到本页并刷新；
/// 不在订单详情里重复挂入口。
///
/// 业务：
/// - 可申请退款的订单 = 未开始 / 进行中 / 待确认（**已完成走既有售后申诉**，docs/05）
/// - 原因必填 + 说明可选；金额不可填（服务端按订单金额快照原路退回）
/// - 幂等键一次申请一个 → 重复提交只落一条；同一订单同时只允许一条待处理申请（服务端判定）
class RefundPage extends StatefulWidget {
  const RefundPage({super.key, this.api});

  final ApiClient? api;

  @override
  State<RefundPage> createState() => _RefundPageState();
}

class _RefundPageState extends State<RefundPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  int _tab = 0; // 0 可申请退款的订单 / 1 我的退款申请
  bool _loading = true;
  String? _error;
  List<_RefundableOrder> _orders = const [];
  List<_MyRefund> _requests = const [];

  /// 退款原因（客户端只提供选项，判定与落库全在服务端）
  static const List<String> _reasons = [
    '打手未开始服务',
    '服务与约定不符',
    '时间对不上，无法继续',
    '重复下单 / 下错单',
    '其它原因',
  ];

  @override
  void initState() {
    super.initState();
    // 订单状态/是否已有待处理申请决定能不能申请 → 首屏强制取服务端最新值（不走 SWR 缓存）
    _load(force: true);
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = AuthStore.instance.accessToken;
      if (_tab == 0) {
        final resp = await _api.request('GET', '/user/refunds/orders',
            token: token, queryParameters: {'page': 1, 'pageSize': 30}, forceRefresh: force);
        final data = (resp['data'] as Map?) ?? const {};
        if (!mounted) return;
        setState(() {
          _orders = ((data['list'] as List?) ?? const []).map((e) => _RefundableOrder.fromJson(e as Map)).toList();
          _loading = false;
        });
      } else {
        final resp = await _api.request('GET', '/user/refunds',
            token: token, queryParameters: {'page': 1, 'pageSize': 30}, forceRefresh: force);
        final data = (resp['data'] as Map?) ?? const {};
        if (!mounted) return;
        setState(() {
          _requests = ((data['list'] as List?) ?? const []).map((e) => _MyRefund.fromJson(e as Map)).toList();
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _switchTab(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
    _load(force: true);
  }

  Future<void> _openApplySheet(_RefundableOrder order) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: T.bgCardSolid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (_) => _RefundSheet(order: order, reasons: _reasons, api: _api),
    );
    if (ok == true && mounted) {
      AppToast.success(context, '退款申请已提交，客服审核后会通知你');
      setState(() => _tab = 1);
      await _load(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => Scaffold(
        backgroundColor: T.scaffoldColor,
        appBar: AppBar(
          backgroundColor: T.bgCardSolid,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 16,
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('退款', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: T.textPrimary)),
              const SizedBox(width: 8),
              // 【2026-10-08 客服大厅专项】原文是「客服 9:00-次日 2:00 在线审核」——
              // 那个时段是**客户端写死的**，而客服已改成「有客服权限的打手主动接咨询」，
              // 在不在线取决于此刻有没有人接，客户端没有任何可承诺的时段（负责人口径：不承诺时间）。
              // 改为只描述"会发生什么"，不描述"多久会发生"。
              Text('客服会尽快审核', style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            ],
          ),
        ),
        body: Column(
          children: [
            AppSegmented(items: const ['可申请退款的订单', '我的申请'], current: _tab, onChanged: _switchTab),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _load(force: true),
                child: _body(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: AppCard(
                radius: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 150, height: 13, color: T.divider),
                    const SizedBox(height: 10),
                    Container(height: 11, color: T.divider),
                    const SizedBox(height: 6),
                    Container(width: 110, height: 11, color: T.divider),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [AppEmpty(icon: AppIcon.info, text: '加载失败：$_error', action: '重试', onAction: _load)],
      );
    }
    if (_tab == 1) {
      if (_requests.isEmpty) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [AppEmpty(icon: AppIcon.record, text: '还没有退款申请\n订单在服务开始前都可以申请退款')],
        );
      }
      return ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        itemCount: _requests.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _requestCard(_requests[i]),
      );
    }
    if (_orders.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          AppEmpty(icon: AppIcon.empty, text: '暂无可申请退款的订单\n已完成订单请在订单详情里申请售后'),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      itemCount: _orders.length,
      itemBuilder: (_, i) => _orderCard(_orders[i]),
    );
  }

  Widget _orderCard(_RefundableOrder o) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AppCard(
          radius: 10,
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(o.productName.isEmpty ? o.orderNo : o.productName,
                        // 商品名最多 3 行（统一规则；旧值 1 行会截断长套餐名）
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.35, color: T.textPrimary)),
                  ),
                  AppTag(_statusLabel(o.status), color: _statusColor(o.status)),
                ],
              ),
              const SizedBox(height: 6),
              Text('${o.orderNo} · 下单 ${_timeText(o.createdAt)}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: T.mutedText)),
              const SizedBox(height: 10),
              Container(height: 1, color: T.divider),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: AppPrice(value: fmtMoney(o.totalAmount), size: 16)),
                  SizedBox(
                    height: 32,
                    child: AppButton(
                      label: '申请退款',
                      gradient: false,
                      expand: false,
                      height: 32,
                      onPressed: () => _openApplySheet(o),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _requestCard(_MyRefund r) => AppCard(
        radius: 10,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(r.orderNo,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
                ),
                AppTag(_refundStatusLabel(r.status), color: _refundStatusColor(r.status)),
              ],
            ),
            const SizedBox(height: 6),
            Text('申请退款 ${fmtMoney(r.amount)} · ${_timeText(r.createdAt)}',
                style: TextStyle(fontSize: 11, color: T.mutedText)),
            const SizedBox(height: 8),
            Text('原因：${r.reason}${r.remark.isEmpty ? '' : '（${r.remark}）'}',
                style: TextStyle(fontSize: 11.5, color: T.textSecondary, height: 1.5)),
            if (r.handlerRemark.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(color: T.bgPage, borderRadius: BorderRadius.circular(6)),
                child: Text('处理意见：${r.handlerRemark}',
                    style: TextStyle(fontSize: 11.5, color: T.textSecondary, height: 1.5)),
              ),
            ],
          ],
        ),
      );

  static String _statusLabel(String s) => switch (s) {
        'pending_take' => '待接单',
        'pending_dispatch' => '待确认派单',
        'taken' => '已接单',
        'in_progress' => '进行中',
        'pending_confirm' => '待确认',
        _ => s,
      };

  static Color _statusColor(String s) => switch (s) {
        'pending_take' || 'pending_dispatch' => T.textTertiary,
        'taken' => T.primary,
        'in_progress' => T.primary,
        'pending_confirm' => T.warning,
        _ => T.textTertiary,
      };

  static String _refundStatusLabel(String s) => switch (s) {
        'pending' => '待处理',
        'approved' => '已通过',
        'rejected' => '已驳回',
        _ => s,
      };

  static Color _refundStatusColor(String s) => switch (s) {
        'pending' => T.warning,
        'approved' => T.success,
        'rejected' => T.error,
        _ => T.textTertiary,
      };

  static String _timeText(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final l = t.toLocal();
    return '${l.month}月${l.day}日 ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

/// 退款申请弹层（原因必选 + 说明可选；金额由服务端按订单快照退回）
class _RefundSheet extends StatefulWidget {
  const _RefundSheet({required this.order, required this.reasons, required this.api});

  final _RefundableOrder order;
  final List<String> reasons;
  final ApiClient api;

  @override
  State<_RefundSheet> createState() => _RefundSheetState();
}

class _RefundSheetState extends State<_RefundSheet> {
  String _reason = '';
  final TextEditingController _remark = TextEditingController();
  bool _submitting = false;
  // 一次申请一个幂等键（重复点击/超时重试复用 → 服务端只落一条）
  final String _idempotencyKey = generateIdempotencyKey();

  /// 表单错误（原因/说明行内红字 + 按钮上方汇总条）
  final FormErrors _errs = FormErrors();

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _errs.clear();
    if (_reason.isEmpty) {
      // 本地必选校验 → 原因区块下方红字（不再弹浮层）
      setState(() => _errs.set('reason', '请选择退款原因'));
      return;
    }
    setState(() => _submitting = true);
    try {
      await widget.api.request('POST', '/user/refunds',
          token: AuthStore.instance.accessToken,
          data: {
            'orderId': widget.order.orderId,
            'reason': _reason,
            'remark': _remark.text.trim(),
            'idempotencyKey': _idempotencyKey,
          });
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // 服务端 fields[] → 对应输入位下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.bindApiException(e, aliases: const {
        'reason': 'reason',
        'remark': 'remark',
        'orderId': 'orderId',
      })) {
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('申请退款', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: T.textPrimary)),
                const SizedBox(height: 4),
                Text('${widget.order.orderNo} · 可退 ${fmtMoney(widget.order.totalAmount)}（原路退回）',
                    style: TextStyle(fontSize: 11.5, color: T.mutedText)),
                const SizedBox(height: 14),
                Text('退款原因', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [for (final r in widget.reasons) _reasonChip(r)],
                ),
                AppFieldError(_errs, 'reason'),
                const SizedBox(height: 14),
                TextField(
                  controller: _remark,
                  maxLines: 3,
                  maxLength: 200,
                  onChanged: (v) {
                    if (_errs.errorOf('remark') != null) setState(() => _errs.clearField('remark'));
                  },
                  style: TextStyle(fontSize: 13.5, color: T.textPrimary),
                  decoration: InputDecoration(
                    hintText: '补充说明（可选，例如订单进行到哪一步）',
                    hintStyle: TextStyle(fontSize: 12.5, color: T.textTertiary),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    counterStyle: TextStyle(fontSize: 10, color: T.mutedText),
                  ),
                ),
                AppFieldError(_errs, 'remark', padding: const EdgeInsets.only(top: 2, left: 2)),
                Text('审核通过后余额原路退回；审核结果会在站内通知里告诉你。',
                    style: TextStyle(fontSize: 10.5, color: T.mutedText, height: 1.5)),
                const SizedBox(height: 14),
                AppFormErrorFooter(
                  errors: _errs,
                  submit: AppButton(label: _submitting ? '提交中…' : '提交退款申请', onPressed: _submitting ? null : _submit),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reasonChip(String r) {
    final selected = _reason == r;
    return GestureDetector(
      onTap: () => setState(() {
        _reason = r;
        // 选了原因就把「请选择退款原因」的红字撤掉
        _errs.clearField('reason');
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? T.primary : T.bgCardSolid,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? T.primary : T.divider),
        ),
        child: Text(r,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? Colors.white : T.textSecondary,
            )),
      ),
    );
  }
}

class _RefundableOrder {
  _RefundableOrder({
    required this.orderId,
    required this.orderNo,
    required this.status,
    required this.totalAmount,
    required this.productName,
    required this.createdAt,
  });

  final String orderId;
  final String orderNo;
  final String status;
  final double totalAmount;
  final String productName;
  final String createdAt;

  factory _RefundableOrder.fromJson(Map json) => _RefundableOrder(
        orderId: '${json['orderId']}',
        orderNo: '${json['orderNo'] ?? ''}',
        status: '${json['status'] ?? ''}',
        totalAmount: parsePoints(json['totalAmount']),
        productName: '${json['productName'] ?? ''}',
        createdAt: '${json['createdAt'] ?? ''}',
      );
}

class _MyRefund {
  _MyRefund({
    required this.orderNo,
    required this.amount,
    required this.reason,
    required this.remark,
    required this.status,
    required this.handlerRemark,
    required this.createdAt,
  });

  final String orderNo;
  final double amount;
  final String reason;
  final String remark;
  final String status;
  final String handlerRemark;
  final String createdAt;

  factory _MyRefund.fromJson(Map json) => _MyRefund(
        orderNo: '${json['orderNo'] ?? ''}',
        amount: parsePoints(json['amount']),
        reason: '${json['reason'] ?? ''}',
        remark: '${json['remark'] ?? ''}',
        status: '${json['status'] ?? ''}',
        handlerRemark: '${json['handlerRemark'] ?? ''}',
        createdAt: '${json['createdAt'] ?? ''}',
      );
}
