import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/media_uploader.dart';
import '../auth/auth_store.dart';
import '../identity/identity_widgets.dart';
import '../recharge/recharge_admin_shell.dart' show RechargeProofViewer;
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_page_bg.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_ui.dart';
import '../widgets/cached_image.dart';
import '../widgets/media_upload_tile.dart';
import 'withdraw_media.dart';
import 'withdraw_models.dart';
import 'worker_withdraw_account_page.dart' show WithdrawQrThumb, bytesOfPicked;
import 'worker_withdraw_records_page.dart';

/// ============================================================================
/// 管理员态 · **提现审核**（列表）—— 与「充值审核」并列的第二个分段
///   `GET /withdraw/requests?status=&page=`
/// ============================================================================
///
/// 列表一行：打手昵称/工号 · **收款信息（完整：姓名 · 电话 · 微信号）** · 金额 · 状态 · 申请时间。
/// 收款信息给完整值（负责人 2026-10-11：能看列表 = 有 `withdraw:review` = 审核人本人）；
/// 字段完整值取不到时逐字段回退服务端下发的脱敏值（见 [WorkerWithdrawRequest.payeeLine]）。
/// 点一行进 [WithdrawReviewDetailPage]。
///
/// ## 与充值审核的关系
/// 两者住在**同一个受限会话**（`kind='recharge'`，白名单里 `/withdraw/*` 与 `/recharge/*`
/// 并列放行），共用 28dp 身份细带与「切回老板」出口，靠管理员态页头的分段控件切换。
/// 本页**不自己画页头**：页头由 `RechargeAdminShell` 提供（那里同时管着待审核计数与刷新）。
///
/// ## 403（权限不足）
/// 服务端中文原文直接展示，且**不渲染任何操作按钮** —— 受限会话白名单只放行
/// `/recharge/*` 与 `/withdraw/*`；管理员账号没被授予提现审核权限时，服务端会 403。
/// 客户端不做"猜权限"：拿到了就显示，拿不到就说清为什么。
class WithdrawReviewList extends StatefulWidget {
  const WithdrawReviewList({
    super.key,
    this.api,
    this.onSwitchBack,
    this.onPendingChanged,
    this.status = 'pending',
    this.managed = true,
  });

  final ApiClient? api;

  /// 细带右侧「切回老板」（详情页也要）
  final VoidCallback? onSwitchBack;

  /// 待审数变化（宿主页头事实行用）
  final ValueChanged<int>? onPendingChanged;

  /// 列表状态过滤（默认 `pending` = 待处理；传空串 = 全部）
  final String status;

  /// true = 本页自己管加载（独立使用时）；false = 由宿主控制（分段切换时避免白拉）
  final bool managed;

  /// 空态
  static const String empty = WorkerWithdrawCopy.auditEmpty;

  /// 加载失败标题
  static const String loadFailed = '提现申请加载失败';

  @override
  State<WithdrawReviewList> createState() => WithdrawReviewListState();
}

class WithdrawReviewListState extends State<WithdrawReviewList> {
  late final ApiClient _api = widget.api ?? ApiClient();

  List<WorkerWithdrawRequest> _items = const [];
  bool _loading = true;
  String? _error;

  /// 上一次加载的错误码（403 = 权限不足 → 不显示任何操作按钮）
  int? _errorCode;

  List<WorkerWithdrawRequest> get items => _items;
  bool get loading => _loading;
  String? get error => _error;
  int? get errorCode => _errorCode;

  @override
  void initState() {
    super.initState();
    if (widget.managed) unawaited(load());
  }

  Future<void> load({bool force = true}) async {
    if (!mounted) return;
    setState(() {
      _error = null;
      _errorCode = null;
      if (_items.isEmpty) _loading = true;
    });
    try {
      final resp = await _api.request(
        'GET',
        '/withdraw/requests',
        token: AuthStore.instance.activeToken,
        forceRefresh: force,
        queryParameters: {
          if (widget.status.isNotEmpty) 'status': widget.status,
          'page': 1,
          'pageSize': 50,
        },
      );
      final page = WorkerWithdrawRequestPage.fromData(resp['data']);
      if (!mounted) return;
      setState(() {
        _items = page.list;
        _loading = false;
      });
      widget.onPendingChanged?.call(page.list.length);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
        _errorCode = e.code;
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
    if (_loading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary));
    }
    // 403：中文说明 + **不显示任何操作按钮**（没有"重试"之外的任何入口）
    if (_errorCode == 403) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          IdentityWorkerEmptyState(
            icon: AppIdentityIcons.linkOff,
            title: WorkerWithdrawCopy.forbidden,
            detail: '这个账号只能看它被授权的审核范围。',
          ),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
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
                      Text(WithdrawReviewList.loadFailed,
                          style: TextStyle(fontSize: 12.5, color: T.textSecondary)),
                      const SizedBox(height: 2),
                      Text(
                        _error!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: T.textTertiary),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: () => load(), child: const Text('重试')),
              ],
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            IdentityWorkerEmptyState(
              title: WithdrawReviewList.empty,
              detail: WorkerWithdrawCopy.auditEmptyDetail,
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 24),
        itemCount: _items.length,
        itemBuilder: (_, i) => Padding(
          padding: EdgeInsets.only(bottom: i == _items.length - 1 ? 0 : 10),
          child: _row(_items[i]),
        ),
      ),
    );
  }

  Widget _row(WorkerWithdrawRequest r) {
    return AppCard(
      padding: EdgeInsets.zero,
      radius: 14,
      onTap: () => _openDetail(r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 收款码缩略图：**受保护媒体**（带受限会话令牌取图，不能直连 URL）
            WithdrawQrThumb(
              url: resolveWithdrawProof(r.qrUrl, requestId: r.id, kind: 'qr'),
              size: 48,
              headers: withdrawImageHeaders(AuthStore.instance.activeToken),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          r.workerLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary),
                        ),
                      ),
                      AppPrice(value: fmtMoney(r.amount), size: 16),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    r.workerNo.isEmpty ? '工号未下发' : '工号 ${r.workerNo}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                  ),
                  /*
                   * 收款信息（**完整**：姓名 · 电话 · 微信号）——负责人 2026-10-11：
                   * 能看列表 = 有 withdraw:review = 审核人本人，核对收款信息不必再点进详情。
                   * 完整值更长 → **单行 + 省略号**（绝不换行挤压右侧金额：金额在第一行，
                   * 本行在它下面独占一行）；整卡可点进详情，右下角另有「详情」入口 →
                   * 被截断的值一定点得开，不靠"猜"。
                   */
                  if (r.payeeLine.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      r.payeeLine,
                      key: Key('withdraw-review-payee-${r.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.2, color: T.textSecondary),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      _statusTag(r),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          '申请 ${WorkerWithdrawRecordsPage.timeText(r.appliedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                        ),
                      ),
                      Text('详情', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.primary)),
                      Icon(AppIdentityIcons.chevron, size: 14, color: T.primary),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
      child: Text(r.statusText, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Future<void> _openDetail(WorkerWithdrawRequest r) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => WithdrawReviewDetailPage(
          request: r,
          api: widget.api,
          onSwitchBack: widget.onSwitchBack,
        ),
      ),
    );
    if (!mounted || changed != true) return;
    // 处理过的这笔从待处理列表移除（与充值审核同规则）；服务端仍是权威，下拉可校准
    setState(() => _items = _items.where((e) => e.id != r.id).toList());
    widget.onPendingChanged?.call(_items.length);
  }
}

/// ============================================================================
/// 管理员态 · **提现审核详情**
///   `GET /withdraw/requests/:id` · `GET /withdraw/proof/:id?kind=qr|payout`
///   · `POST /withdraw/requests/:id/pay` · `POST /withdraw/requests/:id/reject`
/// ============================================================================
///
/// 三块内容：
/// 1. **收款信息**：完整姓名 / 电话 / 微信号（人工打款必须核对）+ **收款码大图**
///    （受保护媒体，`Authorization: Bearer <受限令牌>`，**不能**直连 URL 当公开图用）；
/// 2. **打款记录区**：上传支付记录截图（`withdraw_proof`）+ 备注；
/// 3. **动作栏**：「驳回」（填原因 → 二次确认"余额将退回打手"）与「已提现」
///    （**必须先上传凭证**，未上传时按钮不可用 → 二次确认里必须出现
///    「确认后将标记为已打款，此操作不可撤销」）。
class WithdrawReviewDetailPage extends StatefulWidget {
  const WithdrawReviewDetailPage({
    super.key,
    required this.request,
    this.api,
    this.onSwitchBack,
    this.picker,
    this.uploader,
  });

  final WorkerWithdrawRequest request;
  final ApiClient? api;
  final VoidCallback? onSwitchBack;

  /// 支付记录截图选图注入（测试用；不传 → [WithdrawMedia.pick]）
  final Future<PickedWithdrawImage?> Function()? picker;

  /// 上传注入（测试用；不传 → **专用通道** [uploadWithdrawPayProof]）
  ///
  /// 契约：`POST /withdraw/requests/:id/pay-proof`（multipart，字段名 `file`）→ `{mediaId, url}`。
  /// **不能**走 `/media/upload`：受限会话白名单里没有 `/media/*`（必然 403）。
  final Future<MediaUploadResult> Function({
    required String requestId,
    required List<int> bytes,
    required String filename,
    required String token,
  })? uploader;

  /// 收款码大图的热区（测试/出图定位）
  static const Key qrKey = Key('withdraw-review-qr');

  /// 「已提现」按钮
  static const Key payKey = Key('withdraw-review-pay');

  /// 「驳回」按钮
  static const Key rejectKey = Key('withdraw-review-reject');

  /// 未上传凭证时的按钮文案（**说清为什么不能点**，不是灰着不解释）
  static const String payNeedProof = '请先上传支付记录截图';

  /// 可否发起打款（**唯一判据**：有凭证 mediaId）—— 测试直接断言这个纯函数
  static bool canPay({required String? proofMediaId, required bool busy}) =>
      !busy && proofMediaId != null && proofMediaId.isNotEmpty;

  @override
  State<WithdrawReviewDetailPage> createState() => _WithdrawReviewDetailPageState();
}

class _WithdrawReviewDetailPageState extends State<WithdrawReviewDetailPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  /// 本地最新的这笔申请（加载详情后覆盖；打款/驳回后也更新，界面立刻反映）
  late WorkerWithdrawRequest _r = widget.request;

  /// 支付记录截图：本地预览 + 上传后的 mediaId
  PickedWithdrawImage? _picked;
  String? _proofMediaId;
  final MediaUploadState _up = MediaUploadState();
  bool _uploading = false;
  String? _proofError;

  final TextEditingController _note = TextEditingController();

  bool _busy = false;
  String? _actionError;

  /// 403（权限不足）：**不显示任何操作按钮**
  bool _forbidden = false;

  /// 打款凭证地址（服务端下发的受保护通道；带令牌取图）
  String get _payoutProofUrl =>
      resolveWithdrawProof(_r.payoutProofUrl, requestId: _r.id, kind: 'payout');

  @override
  void initState() {
    super.initState();
    _up.onTick = () {
      if (mounted) setState(() {});
    };
    unawaited(_loadDetail());
  }

  @override
  void dispose() {
    _up.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 拉详情：拿到**完整**姓名/电话/微信号与收款码地址（列表里是脱敏值）
  Future<void> _loadDetail() async {
    try {
      final resp = await _api.request(
        'GET',
        '/withdraw/requests/${_r.id}',
        token: AuthStore.instance.activeToken,
        forceRefresh: true,
      );
      if (!mounted) return;
      final data = resp['data'];
      if (data is Map && data.isNotEmpty) {
        final merged = <String, dynamic>{...data.cast<String, dynamic>()};
        // 详情接口若少下发列表已有的字段，用列表值补齐（避免界面从"有"变"没有"）
        merged.putIfAbsent('id', () => _r.id);
        setState(() => _r = WorkerWithdrawRequest.fromJson(merged));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 403) {
        setState(() => _forbidden = true);
        return;
      }
      // 详情拉不到不挡页面：列表数据本身就是一份可核对的信息，只是姓名/电话是脱敏值
      setState(() => _actionError = e.message);
    } catch (_) {
      // 静默：同上
    }
  }

  // ---------------------------------------------------------------------------
  // 支付记录截图：选图 → 上传（`withdraw_proof`，protected）
  // ---------------------------------------------------------------------------

  Future<void> _pickProof() async {
    if (_uploading) return;
    final picked = await WithdrawMedia.pick(injected: widget.picker);
    if (picked == null || !mounted) {
      if (mounted && !WithdrawMedia.available && widget.picker == null) {
        AppToast.info(context, WithdrawMedia.unavailableMessage);
      }
      return;
    }
    if (picked.byteLength > WithdrawMedia.maxBytes) {
      setState(() => _proofError = '图片太大（${picked.sizeLabel}），请换一张 10MB 以内的图');
      return;
    }
    setState(() {
      _picked = picked;
      _proofMediaId = null;
      _proofError = null;
      _actionError = null;
      _uploading = true;
      _up.begin();
    });
    await _doUpload(picked);
  }

  Future<void> _retryUpload() async {
    final picked = _picked;
    if (picked == null || _uploading) return;
    setState(() {
      _proofError = null;
      _uploading = true;
      _up.begin();
    });
    await _doUpload(picked);
  }

  Future<void> _doUpload(PickedWithdrawImage picked) async {
    final token = AuthStore.instance.activeToken;
    if (token == null) {
      if (!mounted) return;
      const msg = '登录已过期，请重新验证后再上传';
      setState(() {
        _uploading = false;
        _proofError = msg;
        _up.fail(msg);
      });
      return;
    }
    try {
      final up = await _upload(picked, token);
      if (!mounted) return;
      setState(() {
        _proofMediaId = up.id;
        _uploading = false;
        _up.succeed();
      });
    } catch (e) {
      if (!mounted) return;
      final msg = mediaUploadErrorMessage(e);
      setState(() {
        _uploading = false;
        _proofError = msg;
        _up.fail(msg);
      });
    }
  }

  Future<MediaUploadResult> _upload(PickedWithdrawImage picked, String token) {
    final injected = widget.uploader;
    if (injected != null) {
      return injected(
        requestId: _r.id,
        bytes: picked.bytes,
        filename: picked.name,
        token: token,
      );
    }
    // **专用通道**：受限会话不能走 `/media/upload`（白名单里没有 /media/*）
    return uploadWithdrawPayProof(
      requestId: _r.id,
      bytes: picked.bytes,
      filename: picked.name,
      token: token,
      onProgress: (p) {
        if (mounted) setState(() => _up.update(p));
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 打款 / 驳回
  // ---------------------------------------------------------------------------

  /// 打款：**凭证必填**（未上传 → 按钮不可用；即便如此这里再拦一次）
  ///
  /// 契约：`POST /withdraw/requests/:id/pay` body `{proofMediaId, note?}` ——
  /// **`proofMediaId` 是必填**（服务端会拒"只填备注"），备注才是选填。
  Future<void> _pay() async {
    if (_busy) return;
    if (!WithdrawReviewDetailPage.canPay(proofMediaId: _proofMediaId, busy: _busy)) {
      setState(() => _proofError = WithdrawReviewDetailPage.payNeedProof);
      return;
    }
    // 二次确认（**必须包含「确认后将标记为已打款，此操作不可撤销」**）；取消 → 不发请求
    final ok = await WithdrawPayConfirmSheet.show(context, request: _r);
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final note = _note.text.trim();
      await _api.request(
        'POST',
        '/withdraw/requests/${_r.id}/pay',
        token: AuthStore.instance.activeToken,
        data: {
          'proofMediaId': _proofMediaId,
          if (note.isNotEmpty) 'note': note,
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _r = _copyWith(_r, status: 'paid', paidAt: DateTime.now(), payoutProofUrl: _proofMediaId ?? '');
      });
      AppToast.success(context, WorkerWithdrawCopy.paid);
      // 余额没变（提现时已扣），但记录页状态变了 → 广播一次让余额页面回源（幂等）
      WithdrawRefreshNotifier.instance.refresh();
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 401) {
        await _dropAndExit(e.message);
        return;
      }
      if (e.code == 403) {
        setState(() {
          _busy = false;
          _forbidden = true;
        });
        return;
      }
      // 服务端中文原文原样展示（如「这笔提现已处理」）
      setState(() {
        _busy = false;
        _actionError = e.message;
      });
    }
  }

  /// 驳回：原因**必填** → 二次确认（提示"余额将退回打手"）
  Future<void> _reject() async {
    if (_busy) return;
    final reason = await WithdrawRejectSheet.show(context, request: _r);
    if (reason == null || !mounted) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await _api.request(
        'POST',
        '/withdraw/requests/${_r.id}/reject',
        token: AuthStore.instance.activeToken,
        data: {'reason': reason},
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _r = _copyWith(_r, status: 'rejected', rejectReason: reason);
      });
      AppToast.success(context, WorkerWithdrawCopy.rejected);
      // 驳回 = 余额退回打手 → 打手侧的余额页面必须回源
      WithdrawRefreshNotifier.instance.refresh(balanceAfter: null);
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 401) {
        await _dropAndExit(e.message);
        return;
      }
      if (e.code == 403) {
        setState(() {
          _busy = false;
          _forbidden = true;
        });
        return;
      }
      setState(() {
        _busy = false;
        _actionError = e.message;
      });
    }
  }

  /// 受限会话失效（401）→ 丢管理员身份 + **把详情页一起收掉**
  ///
  /// 与充值审核详情页同一个理由：详情页压在 root Navigator 上，HomeShell 换骨架只换自己
  /// 那棵子树 —— 不 pop 就会"已经是老板态"却还在看审核详情。
  Future<void> _dropAndExit(String message) async {
    await AuthStore.instance.dropAdminIdentity(message);
    if (mounted) Navigator.of(context).maybePop();
  }

  static WorkerWithdrawRequest _copyWith(
    WorkerWithdrawRequest src, {
    String? status,
    DateTime? paidAt,
    String? rejectReason,
    String? payoutProofUrl,
  }) =>
      WorkerWithdrawRequest(
        id: src.id,
        amount: src.amount,
        status: status ?? src.status,
        balanceAfter: src.balanceAfter,
        appliedAt: src.appliedAt,
        paidAt: paidAt ?? src.paidAt,
        rejectReason: rejectReason ?? src.rejectReason,
        nickname: src.nickname,
        workerNo: src.workerNo,
        uid: src.uid,
        realName: src.realName,
        phone: src.phone,
        wechatId: src.wechatId,
        qrUrl: src.qrUrl,
        payoutProofUrl: payoutProofUrl ?? src.payoutProofUrl,
        payoutNote: src.payoutNote,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 页头、明细卡、操作条一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: Column(
        children: [
          IdentityWorkerPageHeader(
            title: '提现审核详情',
            actions: [
              IdentityWorkerHeaderButton(
                icon: AppIdentityIcons.close,
                tooltip: '返回',
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
            banner: AppIdentityBar(label: AppIdentityBar.adminLabel, onSwitchBack: _switchBack),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 24),
              children: [
                if (_forbidden) ...[
                  AppIdentityBanner.error(
                    title: WorkerWithdrawCopy.forbidden,
                    detail: '这个账号只能看它被授权的审核范围。',
                  ),
                  const SizedBox(height: 12),
                ],
                _applicantCard(),
                const SizedBox(height: 12),
                _accountCard(),
                const SizedBox(height: 12),
                _qrCard(),
                const SizedBox(height: 12),
                _payoutCard(),
                if (_actionError != null) ...[
                  const SizedBox(height: 12),
                  _errorCard(_actionError!),
                ],
              ],
            ),
          ),
          if (!_forbidden) _actionBar(),
        ],
      )),
    );
  }

  Future<void> _switchBack() async {
    if (widget.onSwitchBack != null) {
      widget.onSwitchBack!();
      return;
    }
    await AuthStore.instance.switchToBoss();
    if (mounted) Navigator.of(context).maybePop();
  }

  Widget _applicantCard() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('申请人', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
          const SizedBox(height: 6),
          Text(_r.workerLabel, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.textPrimary)),
          const SizedBox(height: 3),
          Text(
            [
              if (_r.workerNo.isNotEmpty) '工号 ${_r.workerNo}',
              if (_r.uid.isNotEmpty) '中文 ID ${_r.uid}',
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: AppColors.mutedText),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, thickness: 1, color: T.divider),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('提现金额', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                    const SizedBox(height: 5),
                    Text(fmtMoney(_r.amount),
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: T.textPrimary)),
                  ],
                ),
              ),
              Container(width: 1, height: 34, color: T.divider),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('状态', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                    const SizedBox(height: 5),
                    Text(_r.statusText,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.textPrimary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '申请时间　${WorkerWithdrawRecordsPage.timeText(_r.appliedAt)}',
            style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
          ),
        ],
      ),
    );
  }

  /// **完整**收款信息（人工打款必须核对：姓名一致、微信号能加上）
  Widget _accountCard() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('收款信息', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
          const SizedBox(height: 10),
          _kv('姓名', _r.realName.isEmpty ? '未下发' : _r.realName),
          Divider(height: 1, thickness: 1, color: T.divider),
          _kv('电话', _r.phone.isEmpty ? '未下发' : _r.phone),
          Divider(height: 1, thickness: 1, color: T.divider),
          _kv('微信号', _r.wechatId.isEmpty ? '未下发' : _r.wechatId),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 62, child: Text(k, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText))),
            Expanded(
              child: Text(v,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary, height: 1.4)),
            ),
          ],
        ),
      );

  /// 收款码**大图**：受保护媒体 → 必须带受限会话令牌取图（`authImageHeaders`）
  Widget _qrCard() {
    final url = resolveWithdrawProof(_r.qrUrl, requestId: _r.id, kind: 'qr');
    final headers = withdrawImageHeaders(AuthStore.instance.activeToken);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('收款码', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
        ),
        GestureDetector(
          key: WithdrawReviewDetailPage.qrKey,
          behavior: HitTestBehavior.opaque,
          onTap: () => RechargeProofViewer.show(context, url, headers: headers),
          child: Container(
            height: 240,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: T.divider),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetImage(
                url: url,
                headers: headers,
                fit: BoxFit.contain,
                width: double.infinity,
                height: 240,
                placeholder: const Center(
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                // 失败必须说话（转圈永不消失 = 审核员既不知道 404 还是 401，也没有下一步）
                errorBuilder: (_, failure, retry) => ImageLoadError(
                  failure: failure,
                  onRetry: retry,
                  title: '收款码加载失败',
                ),
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 7),
          child: Text('点图可放大核对收款人', style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ),
      ],
    );
  }

  /// 打款记录区：上传支付记录截图（必填）+ 备注 + 已打款时的凭证回看
  Widget _payoutCard() {
    final picked = _picked;
    final paid = _r.isPaid;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('打款记录',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
              const Spacer(),
              if (paid && _r.paidAt != null)
                Text(
                  '已打款 ${WorkerWithdrawRecordsPage.timeText(_r.paidAt)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (paid && _r.payoutProofUrl.isNotEmpty) ...[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => RechargeProofViewer.show(
                context,
                _payoutProofUrl,
                headers: withdrawImageHeaders(AuthStore.instance.activeToken),
              ),
              child: Container(
                height: 150,
                width: double.infinity,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: T.divider),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetImage(
                    url: _payoutProofUrl,
                    headers: withdrawImageHeaders(AuthStore.instance.activeToken),
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: 150,
                    placeholder: const Center(
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    errorBuilder: (_, failure, retry) =>
                        ImageLoadError(failure: failure, onRetry: retry, title: '打款凭证加载失败'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: paid || _busy ? null : _pickProof,
                child: Container(
                  width: 84,
                  height: 84,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.ice,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _proofError == null ? T.divider : AppColors.error),
                  ),
                  child: picked == null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const AppIcon.of(AppIcon.upload, size: 18, color: AppColors.primary),
                            const SizedBox(height: 4),
                            Text('选择截图',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: T.primary)),
                          ],
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            bytesOfPicked(picked.bytes),
                            width: 84,
                            height: 84,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _uploading
                          ? '截图上传中…'
                          : (_proofMediaId != null ? '支付记录截图已上传' : '支付记录截图（打款必填）'),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: T.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '截图要能看清收款方、金额与时间，平台会按它核对这笔打款。',
                      style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.45),
                    ),
                    if (_proofMediaId != null) ...[
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          const AppIcon.of(AppIcon.check, size: 14, color: AppColors.success),
                          const SizedBox(width: 4),
                          Text('可以确认打款了',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.success)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_proofError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(_proofError!,
                        style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
                  ),
                ],
              ),
            ),
          MediaUploadTile(
            state: _up,
            label: '支付记录截图',
            onRetry: _picked == null ? null : _retryUpload,
          ),
          if (!paid) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                AppIdentityOutlineButton(
                  label: _picked == null ? WorkerWithdrawCopy.pickPayoutProof : '重新选择',
                  onTap: _uploading ? () {} : _pickProof,
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: paid ? AppColors.fieldBg : T.bgCardSolid,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: T.divider),
            ),
            child: TextField(
              key: const Key('withdraw-payout-note'),
              controller: _note,
              enabled: !paid,
              maxLines: 2,
              style: TextStyle(fontSize: 13.5, color: T.textPrimary),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '备注（选填）：例如转账流水号、打款渠道',
                hintStyle: TextStyle(fontSize: 12.5, color: AppColors.textTertiary),
              ),
            ),
          ),
          if (_r.payoutNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('上次备注：${_r.payoutNote}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.45)),
          ],
          if (_r.isRejected && _r.rejectReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('驳回原因：${_r.rejectReason}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
          ],
        ],
      ),
    );
  }

  Widget _errorCard(String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              child: AppIcon.of(AppIcon.info, size: 15, color: AppColors.error),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12.5, color: AppColors.error, height: 1.45)),
            ),
          ],
        ),
      );

  Widget _actionBar() {
    final canPay = WithdrawReviewDetailPage.canPay(proofMediaId: _proofMediaId, busy: _busy);
    final handled = !_r.isPending;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 18),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: Border(top: BorderSide(color: T.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (handled)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    const AppIcon.of(AppIcon.check, size: 14, color: AppColors.statusOnline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '这笔申请已是「${_r.statusText}」，不需要再处理',
                        style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: AppIdentityOutlineButton(
                    key: WithdrawReviewDetailPage.rejectKey,
                    label: WorkerWithdrawCopy.rejectButton,
                    height: 44,
                    expand: true,
                    color: AppColors.error,
                    onTap: (_busy || handled) ? () {} : _reject,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: AppIdentityPrimaryButton(
                    key: WithdrawReviewDetailPage.payKey,
                    // 未上传凭证 → 按钮不可用，且**说清缺什么**（不是灰着不解释）
                    label: handled
                        ? '已处理'
                        : (canPay || _uploading ? WorkerWithdrawCopy.payButton : WithdrawReviewDetailPage.payNeedProof),
                    busy: _busy,
                    onPressed: (!canPay || handled) ? null : _pay,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 打款**二次确认**弹层（负责人硬要求：必须包含「确认后将标记为已打款，此操作不可撤销」）
///
/// 返回值：true = 确认；null/false = 取消（**取消不发任何请求**）。
class WithdrawPayConfirmSheet extends StatelessWidget {
  const WithdrawPayConfirmSheet({super.key, required this.request});

  final WorkerWithdrawRequest request;

  static Future<bool?> show(BuildContext context, {required WorkerWithdrawRequest request}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => WithdrawPayConfirmSheet(request: request),
    );
  }

  /// 确认弹层的**主文案**（测试与页面共用同一份实现）
  static String confirmText(WorkerWithdrawRequest r) {
    final who = r.nickname.isEmpty ? '该打手' : r.nickname;
    return '确认给 $who 打过 ${fmtMoney(r.amount)} 了';
  }

  @override
  Widget build(BuildContext context) {
    final r = request;
    return Container(
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        boxShadow: const [BoxShadow(color: Color(0x2E0F172A), blurRadius: 30, offset: Offset(0, -10))],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 8),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 4,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(color: AppColors.dragHandle, borderRadius: BorderRadius.circular(2)),
                  ),
                  Text('打款确认', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 4, AppSpacing.page, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    confirmText(r),
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: T.textPrimary, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: T.bgCardSolid,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: T.divider),
                    ),
                    child: Column(
                      children: [
                        _kv('打手', r.workerLabel),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('提现金额', fmtMoney(r.amount)),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('收款人', r.realName.isEmpty ? '未下发' : r.realName),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('微信号', r.wechatId.isEmpty ? '未下发' : r.wechatId),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // ⚠️ 这一句是负责人点名的**不可撤销**告知，逐字不许改
                  AppIdentityBanner.warn(
                    title: WorkerWithdrawCopy.payConfirmWarning,
                    detail: '确认后这笔申请会从待处理列表移除，打手端立刻看到「已打款」。',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 20),
              child: Column(
                children: [
                  AppIdentityPrimaryButton(
                    label: '确认已打款',
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                  const SizedBox(height: 9),
                  AppIdentityOutlineButton(
                    label: '取消',
                    height: 40,
                    expand: true,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 72, child: Text(k, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText))),
            Expanded(
              child: Text(v,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: T.textSecondary, height: 1.4)),
            ),
          ],
        ),
      );
}

/// 驳回弹层：**原因必填** → 二次确认（提示"余额将退回打手"）
///
/// 返回值：填写的原因（取消返回 null）。**取消不发任何请求。**
class WithdrawRejectSheet extends StatefulWidget {
  const WithdrawRejectSheet({super.key, required this.request});

  final WorkerWithdrawRequest request;

  static Future<String?> show(BuildContext context, {required WorkerWithdrawRequest request}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => WithdrawRejectSheet(request: request),
    );
  }

  /// 原因必填的中文错误（测试与页面同一份）
  static const String reasonRequired = '请填写驳回原因，打手会在提现记录里看到它';

  @override
  State<WithdrawRejectSheet> createState() => _WithdrawRejectSheetState();
}

class _WithdrawRejectSheetState extends State<WithdrawRejectSheet> {
  final TextEditingController _reason = TextEditingController();
  String? _error;

  /// 已进入"二次确认"这一步（必填通过后才出现）
  bool _confirming = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// 第一步：校验必填。通过则进入二次确认（**还不 pop**）
  void _toConfirm() {
    final text = _reason.text.trim();
    if (text.isEmpty) {
      setState(() => _error = WithdrawRejectSheet.reasonRequired);
      return;
    }
    setState(() {
      _error = null;
      _confirming = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          boxShadow: const [BoxShadow(color: Color(0x2E0F172A), blurRadius: 30, offset: Offset(0, -10))],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 8),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 4,
                      margin: const EdgeInsets.only(right: 10),
                      decoration:
                          BoxDecoration(color: AppColors.dragHandle, borderRadius: BorderRadius.circular(2)),
                    ),
                    Text(_confirming ? '驳回确认' : '驳回申请',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 4, AppSpacing.page, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '驳回 ${r.workerLabel} 的 ${fmtMoney(r.amount)} 提现申请',
                      style: TextStyle(fontSize: 13, color: T.textSecondary, height: 1.5),
                    ),
                    const SizedBox(height: 12),
                    if (!_confirming) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _error == null ? T.bgCardSolid : AppColors.bannerDangerBg,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _error == null ? AppColors.hairline : AppColors.error),
                        ),
                        child: TextField(
                          key: const Key('withdraw-reject-reason'),
                          controller: _reason,
                          maxLines: 3,
                          style: TextStyle(fontSize: 14, color: T.textPrimary),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: '例如：收款信息与本人不一致 / 微信收款码无法收款',
                            hintStyle: TextStyle(fontSize: 13, color: AppColors.textTertiary),
                          ),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(_error!,
                              style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
                        ),
                    ] else
                      AppIdentityBanner.warn(
                        title: WorkerWithdrawCopy.rejectConfirmWarning,
                        detail: '驳回后这笔提现作废，打手端会看到你填的原因：${_reason.text.trim()}',
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 20),
                child: Column(
                  children: [
                    if (!_confirming)
                      AppIdentityPrimaryButton(
                        label: '下一步',
                        color: AppColors.error,
                        onPressed: _toConfirm,
                      )
                    else
                      AppIdentityPrimaryButton(
                        label: '确认驳回',
                        color: AppColors.error,
                        onPressed: () => Navigator.of(context).pop(_reason.text.trim()),
                      ),
                    const SizedBox(height: 9),
                    AppIdentityOutlineButton(
                      label: _confirming ? '返回改原因' : '取消',
                      height: 40,
                      expand: true,
                      onTap: () {
                        if (_confirming) {
                          setState(() => _confirming = false);
                          return;
                        }
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
