/// 订单评价区（**只放在订单详情里**，绝不放订单列表卡上）
///
/// ## 交互（负责人 2026-10-15；参考竞品的信息架构，文案与视觉全部自研）
///
/// - **满意 / 不满意二选一**（大按钮，不是 5 星）+ 可选文字备注（≤200 字）；
/// - 满意 → 「感谢认可！」；不满意 → 提示 + **在卡片里给出申请售后的下一步入口**
///   （只在服务端回 `needAfterSale == true` 时给 —— 这是服务端裁决，客户端不自己判）；
/// - **已评价 → 原地显示评价结果，入口消失**（两个按钮 + 备注框一起收掉）。
///
/// ## 为什么不是一个独立页面 / 不在列表卡上
///
/// 负责人明确要求：评价入口**不要**放在列表页每张卡上（一屏十几张卡都挂"去评价"会糊）。
/// 这里作为订单详情弹层里的**一段卡片**（与「服务信息」「护航员」同级的 `AppCard`），
/// 用户必须先点开那一笔订单才看得到。
///
/// ## 状态一律以服务端为准
///
/// 提交成功后**再读一次** `GET /user/orders/:id/review`（`forceRefresh`，绕 SWR 缓存）
/// 把结果换成权威值；但**回读不会把入口放回来**：`_review` 一旦非空就只增不减
/// （刚落库、回读还没看到的瞬间，也不能让用户以为"没评上"而重复提交）。
/// 一单一评的最终约束仍在服务端（重复 → 中文 400「该订单已评价」）。
library;

import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../models/review_models.dart';

/// 订单详情里的评价段
class OrderReviewSection extends StatefulWidget {
  const OrderReviewSection({
    super.key,
    this.api,
    required this.orderId,
    required this.status,
    this.onAfterSale,
  });

  /// 测试注入（不传则用默认 ApiClient）
  final ApiClient? api;
  final String orderId;

  /// 订单状态：**只有 `completed` 才评价**（与服务端「仅 status='completed' 可评」同口径；
  /// 非 completed 时本段整块不渲染，也不发请求）
  final String status;

  /// 「申请售后」的下一步（由订单详情页注入：先关掉弹层，再走既有售后申请）
  final VoidCallback? onAfterSale;

  @override
  State<OrderReviewSection> createState() => _OrderReviewSectionState();
}

class _OrderReviewSectionState extends State<OrderReviewSection> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final TextEditingController _remark = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  bool _failed = false;

  /// 用户的选择（null = 还没选 → 提交键置灰；**不允许"不选就提交"**）
  bool? _choice;

  /// 已评价 → 非空（此后再也不回到 null，见文件头注释）
  OrderReviewInfo? _review;

  /// 提交成功后服务端下发的售后引导开关（**只有它说了算**）
  bool _needAfterSale = false;

  bool get _reviewable => widget.status == 'completed';

  @override
  void initState() {
    super.initState();
    if (_reviewable) {
      unawaited(_load(force: true));
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  /// 读这笔订单的评价状态（`null` = 还没评价）
  ///
  /// `forceRefresh`：这是**是否已评价**的判定依据，不能吃 45s 的 SWR 列表缓存
  /// （吃了缓存 → 刚在小程序/别处评过，这里还会显示入口）。
  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final resp = await _api.request(
        'GET',
        '/user/orders/${widget.orderId}/review',
        token: AuthStore.instance.accessToken,
        forceRefresh: force,
      );
      if (!mounted) return;
      final parsed = OrderReviewInfo.fromJson(resp['data']);
      setState(() {
        _loading = false;
        // 服务端明确回 null = 未评价（首次进入时照实显示入口）；
        // 但本地已知结论时**不让 null 把它抹掉**（提交后回读竞态：入口不许回来）
        if (parsed != null || _review == null) _review = parsed;
      });
    } catch (_) {
      if (!mounted) return;
      // 读不到 ≠ 能评价：给一行"重试"，既不假装未评价（会引导重复提交），
      // 也不假装已评价（会把入口吞掉）。真正的一单一评仍由服务端把关。
      setState(() {
        _loading = false;
        _failed = _review == null;
      });
    }
  }

  Future<void> _submit() async {
    final choice = _choice;
    if (choice == null || _submitting) return;
    final remark = _remark.text.trim();
    setState(() => _submitting = true);
    try {
      final resp = await _api.request(
        'POST',
        '/user/orders/${widget.orderId}/review',
        token: AuthStore.instance.accessToken,
        // 备注：≤200 字（输入框 maxLength 已限）；空则不传这个字段（不写空串垃圾数据）
        data: {'satisfied': choice, if (remark.isNotEmpty) 'remark': remark},
      );
      final data = (resp['data'] as Map?) ?? const <String, dynamic>{};
      if (data['ok'] == false) {
        if (!mounted) return;
        setState(() => _submitting = false);
        AppToast.error(context, '评价提交失败，请稍后重试');
        return;
      }
      final needAfterSale = data['needAfterSale'] == true;
      if (!mounted) return;
      // 提交成功是确定事实 → 立刻把结果块换上去（**入口随即消失**），
      // 再静默回读一次拿服务端时间/备注（失败也保留本地结论）
      setState(() {
        _submitting = false;
        _needAfterSale = needAfterSale;
        _choice = null;
        _review = OrderReviewInfo(
          satisfied: choice,
          remark: remark,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        );
      });
      if (choice) {
        AppToast.success(context, '感谢认可！');
      } else {
        AppToast.info(context, '已收到你的反馈，可以申请售后');
      }
      unawaited(_load(force: true));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppToast.error(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_reviewable) return const SizedBox.shrink();
    final review = _review;
    return AppCard(
      key: const Key('order-review-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('服务评价',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: T.textPrimary)),
              const Spacer(),
              // 时间只在"已评价"时才有意义（还没评价就没有时间可说）
              if (review != null && reviewTimeText(review.createdAt).isNotEmpty)
                Text(reviewTimeText(review.createdAt), style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading && review == null)
            _readingRow()
          else if (review != null)
            ..._resultBlock(review)
          else if (_failed)
            _retryRow()
          else
            ..._form(),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 未评价：入口（二选一 + 可选备注 + 提交）
  // -------------------------------------------------------------------------

  List<Widget> _form() => [
        Text('这次服务还满意吗', style: TextStyle(fontSize: 12.5, color: T.textSecondary)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _verdictButton(true)),
            const SizedBox(width: 12),
            Expanded(child: _verdictButton(false)),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('order-review-remark'),
          controller: _remark,
          maxLines: 3,
          maxLength: 200,
          enabled: !_submitting,
          style: TextStyle(fontSize: 13.5, color: T.textPrimary),
          decoration: InputDecoration(
            hintText: '补充说明（选填，最多 200 字）',
            hintStyle: TextStyle(fontSize: 12.5, color: T.mutedText),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            counterStyle: TextStyle(fontSize: 10, color: T.mutedText),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: AppButton(
            label: _submitting ? '提交中…' : '提交评价',
            onPressed: (_choice == null || _submitting) ? null : _submit,
          ),
        ),
      ];

  /// 大按钮（满意 / 不满意）：选中 = 同族浅底 + 同族描边 + 图标 + 加粗
  ///
  /// 不能只靠颜色（`docs/21`）：这里同时有**图标形状**、**字重**、**取舍文案**三档信号。
  Widget _verdictButton(bool value) {
    final on = _choice == value;
    final color = reviewVerdictColor(value);
    final bg = on ? (value ? AppColors.statusOnlineSoft : AppColors.dangerSoft) : T.bgCardSolid;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key(value ? 'order-review-satisfied' : 'order-review-unsatisfied'),
        borderRadius: BorderRadius.circular(10),
        onTap: _submitting ? null : () => setState(() => _choice = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? color : T.divider, width: on ? 1.4 : 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon.of(reviewVerdictIcon(value), size: 17, color: on ? color : T.textSecondary),
              const SizedBox(width: 8),
              Text(
                reviewVerdictText(value),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                  color: on ? color : T.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 已评价：只读结果（入口不再出现）
  // -------------------------------------------------------------------------

  List<Widget> _resultBlock(OrderReviewInfo r) => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: AppIcon.of(reviewVerdictIcon(r.satisfied), size: 16, color: reviewVerdictColor(r.satisfied)),
            ),
            const SizedBox(width: 8),
            Text(
              reviewVerdictText(r.satisfied),
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: reviewVerdictColor(r.satisfied),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text('你的评价已记录', style: TextStyle(fontSize: 11, color: T.mutedText, height: 1.5)),
              ),
            ),
          ],
        ),
        if (r.remark.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(r.remark, style: TextStyle(fontSize: 12.5, height: 1.6, color: T.textPrimary)),
        ],
        // 售后引导：**只有服务端说 needAfterSale 时才有**（不满意才可能为 true）
        if (!r.satisfied && _needAfterSale) ...[
          const SizedBox(height: 12),
          _afterSaleBlock(),
        ],
      ];

  /// 不满意的下一步：申请售后（客服介入）
  ///
  /// 用"浅底 + 图标 + 文案 + 按钮"而不是"整块红"：这是**要人处理的事**，
  /// 不是错误提示（`docs/21`：不能只靠颜色；也不做大色块）。
  Widget _afterSaleBlock() => Container(
        key: const Key('order-review-after-sale'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.statusBusySoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: T.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: AppIcon.of(AppIcon.info, size: 15, color: AppColors.warning),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('这笔订单可以申请售后，客服会介入处理',
                  style: TextStyle(fontSize: 12, height: 1.5, color: T.textSecondary)),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('order-review-aftersale-action'),
              onPressed: widget.onAfterSale,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('申请售后', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );

  // -------------------------------------------------------------------------
  // 读状态中 / 读不到
  // -------------------------------------------------------------------------

  Widget _readingRow() => Row(
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: T.primary)),
          const SizedBox(width: 8),
          Text('正在读取评价…', style: TextStyle(fontSize: 12, color: T.mutedText)),
        ],
      );

  Widget _retryRow() => Row(
        key: const Key('order-review-load-failed'),
        children: [
          AppIcon.of(AppIcon.info, size: 14, color: T.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text('评价状态暂时取不到，可稍后从订单详情再看',
                style: TextStyle(fontSize: 12, color: T.textSecondary, height: 1.5)),
          ),
          TextButton(
            key: const Key('order-review-retry'),
            onPressed: () => unawaited(_load(force: true)),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('重试', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
        ],
      );
}
