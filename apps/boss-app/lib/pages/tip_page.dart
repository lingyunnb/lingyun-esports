import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 打赏（顶部导航入口 · 负责人 2026-10-04）
///
/// 结构规则（CLAUDE.md 规则 1）：打赏页 = **选订单 → 打赏** 的列表页，动作完成后回到本页并刷新；
/// 不在订单详情里重复挂打赏入口。
///
/// 业务（docs/06 铁律）：
/// - 金额只能从服务端配置里选（预设 6/18/38/88 + 自定义），单次/同订单累计上限均由服务端判定
/// - 客户端生成的幂等键在**一次打赏动作内复用** → 网络重试/连点不会重复扣款
/// - 收款方由服务端按订单接单打手决定，客户端不可指定；金额 100% 给打手（平台不抽成）
///
/// 口径（负责人 2026-10-09）：计价单位 = 余额（1 元 = 1 元），金额一律 `fmtMoney`
/// （`¥38.00`）—— 档位与上限都来自服务端，客户端只做展示与本地预校验。
class TipPage extends StatefulWidget {
  const TipPage({super.key, this.api});

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;

  @override
  State<TipPage> createState() => _TipPageState();
}

class _TipPageState extends State<TipPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  int _tab = 0; // 0 可打赏订单 / 1 我的打赏
  bool _loading = true;
  String? _error;
  List<_TipableOrder> _orders = const [];
  List<_MyTip> _tips = const [];
  List<num> _presetList = const [];
  num _maxPerTip = 0;
  num _maxPerOrder = 0;

  @override
  void initState() {
    super.initState();
    // 金额上限/已打赏累计直接决定能不能打赏 → 首屏强制取服务端最新值（不走 SWR 缓存）
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
        final resp = await _api.request('GET', '/user/tips/orders',
            token: token, queryParameters: {'page': 1, 'pageSize': 30}, forceRefresh: force);
        final data = (resp['data'] as Map?) ?? const {};
        final cfg = (data['config'] as Map?) ?? const {};
        if (!mounted) return;
        setState(() {
          _orders = ((data['list'] as List?) ?? const []).map((e) => _TipableOrder.fromJson(e as Map)).toList();
          // 预设与上限都是**元**（可能是小数）：保留原值，绝不 toInt（0.6 会被截成 0）
          _presetList = ((cfg['presets'] as List?) ?? const [6, 18, 38, 88])
              .map((e) => e is num ? e : num.tryParse('$e') ?? 0)
              .where((v) => v > 0)
              .toList();
          _maxPerTip = (cfg['maxPerTip'] as num?) ?? 0;
          _maxPerOrder = (cfg['maxPerOrder'] as num?) ?? 0;
          _loading = false;
        });
      } else {
        final resp = await _api.request('GET', '/user/tips',
            token: token, queryParameters: {'page': 1, 'pageSize': 30}, forceRefresh: force);
        final data = (resp['data'] as Map?) ?? const {};
        if (!mounted) return;
        setState(() {
          _tips = ((data['list'] as List?) ?? const []).map((e) => _MyTip.fromJson(e as Map)).toList();
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

  /// 打赏弹层：预设 + 自定义；上限文案来自服务端配置（客户端只提示，判定在服务端）
  ///
  /// 泛型是 `num` 而不是 `int`：弹层会把**选中的金额**回传（口径 2026-10-09 起金额是元、可能是 0.6/8.8），
  /// 用 `int` 接会在 `Navigator.pop` 时抛「result of type double ... expected int」（实测）。
  Future<void> _openTipSheet(_TipableOrder order) async {
    final amount = await showModalBottomSheet<num>(
      context: context,
      isScrollControlled: true,
      backgroundColor: T.bgCardSolid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (_) => _TipSheet(
        order: order,
        presets: _presetList,
        maxPerTip: _maxPerTip,
        maxPerOrder: _maxPerOrder,
        api: _api,
      ),
    );
    if (amount != null && mounted) {
      AppToast.success(context, '打赏成功，${fmtMoney(amount)} 已到打手账户');
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
              Text('打赏', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: T.textPrimary)),
              const SizedBox(width: 8),
              Text('金额 100% 给打手，平台不抽成', style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            ],
          ),
        ),
        body: Column(
          children: [
            AppSegmented(items: const ['可打赏订单', '我的打赏'], current: _tab, onChanged: _switchTab),
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
                    Container(width: 140, height: 13, color: T.divider),
                    const SizedBox(height: 10),
                    Container(height: 11, color: T.divider),
                    const SizedBox(height: 6),
                    Container(width: 90, height: 11, color: T.divider),
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
      if (_tips.isEmpty) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [AppEmpty(icon: AppIcon.gift, text: '还没有打赏记录\n在订单服务得不错时打个赏，打手拿全额')],
        );
      }
      return ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        itemCount: _tips.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _myTipCard(_tips[i]),
      );
    }
    if (_orders.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          AppEmpty(icon: AppIcon.empty, text: '暂无可打赏的订单\n订单有打手接单（进行中 / 待确认 / 已完成）后就能打赏'),
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

  /// 订单卡：订单号 + 商品 + 打手 + 累计打赏进度 + 一个动作（打赏）
  Widget _orderCard(_TipableOrder o) {
    final full = o.remainingAmount <= 0;
    return Padding(
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
                      // 商品名最多 3 行（统一规则；旧值 1 行会把 46 字的博弈单名截成「…」）
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.35, color: T.textPrimary)),
                ),
                AppTag(_statusLabel(o.status), color: _statusColor(o.status)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${o.orderNo} · 打手 ${o.workerNickname.isEmpty ? '—' : o.workerNickname}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: T.mutedText),
            ),
            const SizedBox(height: 10),
            Container(height: 1, color: T.divider),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    o.tippedAmount > 0
                        ? '已打赏 ${fmtMoney(o.tippedAmount)} · 还可打赏 ${fmtMoney(o.remainingAmount)}'
                        : '本单还没打赏过 · 单次上限 ${fmtMoney(_maxPerTip > 0 ? _maxPerTip : 500)}',
                    maxLines: 2,
                    style: TextStyle(fontSize: 11, color: T.textSecondary, height: 1.5),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 32,
                  child: AppButton(
                    label: full ? '已达上限' : '打赏',
                    gradient: !full,
                    expand: false,
                    height: 32,
                    onPressed: full ? null : () => _openTipSheet(o),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _myTipCard(_MyTip t) => AppCard(
        radius: 10,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('打赏给 ${t.toNickname.isEmpty ? '打手' : t.toNickname}',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary)),
                  const SizedBox(height: 4),
                  Text('${t.orderNo} · ${_timeText(t.createdAt)}',
                      style: TextStyle(fontSize: 11, color: T.mutedText)),
                ],
              ),
            ),
            AppPrice(value: '-${fmtMoney(t.amount)}', size: 15),
          ],
        ),
      );

  static String _statusLabel(String s) => switch (s) {
        'in_progress' => '进行中',
        'pending_confirm' => '待确认',
        'completed' => '已完成',
        _ => s,
      };

  static Color _statusColor(String s) => switch (s) {
        'in_progress' => T.primary,
        'pending_confirm' => T.warning,
        'completed' => T.success,
        _ => T.textTertiary,
      };

  static String _timeText(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final l = t.toLocal();
    return '${l.month}月${l.day}日 ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

/// 打赏弹层（预设 + 自定义；幂等键在弹层内生成，同一次确认重试复用同一键）
class _TipSheet extends StatefulWidget {
  const _TipSheet({
    required this.order,
    required this.presets,
    required this.maxPerTip,
    required this.maxPerOrder,
    required this.api,
  });

  final _TipableOrder order;

  /// 预设档位（**num**：服务端 2026-10-09 起是元口径，可能是 0.6 / 1.8 这类小数）
  final List<num> presets;
  final num maxPerTip;
  final num maxPerOrder;
  final ApiClient api;

  @override
  State<_TipSheet> createState() => _TipSheetState();
}

class _TipSheetState extends State<_TipSheet> {
  /// 默认档位：**取第二档**（与"自定义"分开，避免默认就落在最小/最大档）
  ///
  /// 金额是 `num` 而不是 `int`：服务端 2026-10-09 起预设已按 ÷10 折算为**元**（0.6 / 1.8 / 3.8 / 8.8），
  /// 用 int 接会把 0.6 截成 0（档位显示 ¥0.00 且提交必然被服务端拒）。
  late num _amount = widget.presets.length > 1
      ? widget.presets[1]
      : (widget.presets.isNotEmpty ? widget.presets.first : 18);
  final TextEditingController _custom = TextEditingController();
  bool _useCustom = false;
  bool _submitting = false;
  // 一次打赏动作一个幂等键：重复点击/超时重试都复用（服务端只扣一次）
  final String _idempotencyKey = generateIdempotencyKey();

  /// 表单错误（金额行内红字 + 按钮上方汇总条）
  final FormErrors _errs = FormErrors();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  num get _finalAmount {
    if (!_useCustom) return _amount;
    return num.tryParse(_custom.text.trim()) ?? 0;
  }

  Future<void> _submit() async {
    final amount = _finalAmount;
    _errs.clear();
    // 金额类本地校验 → 金额区块下方红字（不再弹浮层）
    // 口径与服务端逐字一致（`tip.service.ts`）：>0 且**最多两位小数**（打赏预设本身就有 0.6/1.8/3.8/8.8）
    if (amount <= 0) {
      setState(() => _errs.set('amount', '请填写打赏金额（大于 0）'));
      return;
    }
    if (!RechargeRules.hasAtMostTwoDecimals(amount)) {
      setState(() => _errs.set('amount', '打赏金额最多保留 2 位小数'));
      return;
    }
    if (widget.maxPerTip > 0 && amount > widget.maxPerTip) {
      setState(() => _errs.set('amount', '单次最多 ${fmtMoney(widget.maxPerTip)}'));
      return;
    }
    if (amount > widget.order.remainingAmount) {
      setState(() => _errs.set('amount', '本单还可打赏 ${fmtMoney(widget.order.remainingAmount)}'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final resp = await widget.api.request('POST', '/user/tips',
          token: AuthStore.instance.accessToken,
          data: {
            'orderId': widget.order.orderId,
            'amount': amount,
            'idempotencyKey': _idempotencyKey,
          });
      final data = (resp['data'] as Map?) ?? const {};
      if (!mounted) return;
      // duplicated=true 表示服务端识别为重复提交并返回首次结果，对用户仍是「成功」
      Navigator.of(context).pop(amount);
      if (data['duplicated'] == true) {
        AppToast.info(context, '该次打赏已提交过，未重复扣款');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // 服务端 fields[] → 金额下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.bindApiException(e, aliases: const {'amount': 'amount', 'orderId': 'orderId'})) {
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final remain = widget.order.remainingAmount;
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
                Text('打赏打手', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: T.textPrimary)),
                const SizedBox(height: 4),
                Text(
                  '${widget.order.orderNo} · ${widget.order.workerNickname.isEmpty ? '本单打手' : widget.order.workerNickname}'
                  '${remain > 0 ? ' · 本单还可打赏 ${fmtMoney(remain)}' : ''}',
                  style: TextStyle(fontSize: 11.5, color: T.mutedText),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in widget.presets)
                      _amountChip(p),
                    _amountChip(-1),
                  ],
                ),
                AppFieldError(_errs, 'amount'),
                if (_useCustom) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _custom,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    // 允许小数（服务端 `tip.service.ts` 明确接受最多两位小数的余额金额）
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    autofocus: true,
                    onChanged: (_) => setState(() => _errs.clearField('amount')),
                    style: TextStyle(fontSize: 15, color: T.textPrimary),
                    decoration: InputDecoration(
                      hintText: '自定义金额（最多两位小数）',
                      hintStyle: TextStyle(fontSize: 13, color: T.textTertiary),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  '打赏后余额立即到打手账户，不可撤回；打赏不影响订单结算比例。',
                  style: TextStyle(fontSize: 10.5, color: T.mutedText, height: 1.5),
                ),
                const SizedBox(height: 14),
                AppFormErrorFooter(
                  errors: _errs,
                  submit: AppButton(
                    label: _submitting ? '提交中…' : '确认打赏 ${_finalAmount > 0 ? fmtMoney(_finalAmount) : ''}',
                    onPressed: _submitting ? null : _submit,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _amountChip(num value) {
    final isCustom = value == -1;
    final selected = isCustom ? _useCustom : (!_useCustom && _amount == value);
    return GestureDetector(
      onTap: () {
        setState(() {
          // 换了金额档位就把旧红字撤掉（错误属于上一次输入）
          _errs.clearField('amount');
          if (isCustom) {
            _useCustom = true;
          } else {
            _useCustom = false;
            _amount = value;
          }
        });
      },
      child: Container(
        // 用 minWidth + 内边距而不是写死宽度：档位文案现在是 `¥88.00`（6 字符），
        // 写死 62dp 在 1.3× 系统字号下会挤爆；Wrap 会按需要换行。
        constraints: BoxConstraints(minWidth: isCustom ? 84 : 62),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? T.primary : T.bgCardSolid,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? T.primary : T.divider),
        ),
        child: Text(
          isCustom ? '自定义' : fmtMoney(value),
          style: TextStyle(
            fontSize: isCustom ? 12.5 : 15,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            color: selected ? Colors.white : T.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _TipableOrder {
  _TipableOrder({
    required this.orderId,
    required this.orderNo,
    required this.status,
    required this.productName,
    required this.workerNickname,
    required this.tippedAmount,
    required this.remainingAmount,
  });

  final String orderId;
  final String orderNo;
  final String status;
  final String productName;
  final String workerNickname;
  final double tippedAmount;
  final double remainingAmount;

  factory _TipableOrder.fromJson(Map json) => _TipableOrder(
        orderId: '${json['orderId']}',
        orderNo: '${json['orderNo'] ?? ''}',
        status: '${json['status'] ?? ''}',
        productName: '${json['productName'] ?? ''}',
        workerNickname: '${json['workerNickname'] ?? ''}',
        tippedAmount: parsePoints(json['tippedAmount']),
        remainingAmount: parsePoints(json['remainingAmount']),
      );
}

class _MyTip {
  _MyTip({required this.orderNo, required this.toNickname, required this.amount, required this.createdAt});

  final String orderNo;
  final String toNickname;
  final double amount;
  final String createdAt;

  factory _MyTip.fromJson(Map json) => _MyTip(
        orderNo: '${json['orderNo'] ?? ''}',
        toNickname: '${json['toNickname'] ?? ''}',
        amount: parsePoints(json['amount']),
        createdAt: '${json['createdAt'] ?? ''}',
      );
}
