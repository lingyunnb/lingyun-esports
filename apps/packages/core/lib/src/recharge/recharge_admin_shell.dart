import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_ui.dart';
import '../widgets/cached_image.dart';
import '../identity/identity_widgets.dart';
import '../identity/worker_shell.dart';
import '../withdraw/withdraw_review_page.dart' show WithdrawReviewList, WithdrawReviewListState;
import 'recharge_models.dart';

/// ============================================================================
/// 管理员态（充值审核）—— 负责人 2026-10-06 方案②
/// ============================================================================
///
/// ## 这个身份**只做三件事**（多一件都不做）
/// 1. 看**待审核列表**（用户昵称 / 中文 ID / 金额 / 到账余额 / 凭证 / 提交时间）；
/// 2. **发放余额**（必须二次确认：确认弹层里明确写"给 某某 发放 ¥600.00 余额"）；
/// 3. **驳回**（必须填原因）。
///
/// 界面里**没有**商品/订单/服务/找陪玩/排行榜/余额卡/会员/钱包…任何老板端内容，
/// 也没有任何别的管理能力（没有用户管理、没有封禁、没有配置、没有数据看板）。
/// 干净度是**结构上**保证的：本 shell 里只有这一个页面（+ 一个详情页），
/// 老板态的页面一个都不在这棵树里，所以它们的轮询/订阅/缓存刷新自然全都不跑。
///
/// ## 底栏：**一个都没有**（负责人留的判断题，这里给出结论与理由）
/// 打手态底栏有 3 项（三个页面各一项），管理员态只有**一处**内容 —— 给它配一条
/// 只有一项的底栏等于造一个"点了哪儿也不去"的假控件（docs/21「不存在的东西不出现」）。
/// 因此管理员态**无底栏**：唯一的固定出口是顶部 28dp 身份细带右侧的「切回老板」。
/// 验收里有一条结构断言就盯这个：管理员态不许出现 `AppBottomNav` / `AppPlainBottomNav`。
///
/// ## 会话失效（401）
/// 受限会话被移出白名单/过期时，两条路都会自动回落老板态并给中文提示：
/// - 受限令牌存在 → `ApiClient.onUnauthorized` → `AuthStore.dropAdminIdentity`；
/// - 服务端没发独立令牌（沿用 primary）→ **本页自己捕获 401** 并调同一个落点。
/// 提示复用打手态那套 `AuthStore.identityNotice`（[RechargeAdminShell] 挂监听消费一次）。
class RechargeAdminShell extends StatefulWidget {
  const RechargeAdminShell({
    super.key,
    this.api,
    this.onSwitchBack,
    this.onGranted,
  });

  /// 测试注入（不传 → AuthStore 自己的客户端）
  final ApiClient? api;

  /// 细带右侧「切回老板」的行为；不传 → 直接切回 + Toast（与打手态同规则）
  final VoidCallback? onSwitchBack;

  /// 发放成功回调（宿主可据此刷新别处；默认只做本地列表移除 + Toast）
  final ValueChanged<PendingRechargeRequest>? onGranted;

  /// 页头标题（验收断言用同一份常量）
  ///
  /// 刻意**不叫「充值审核」**：那四个字已经写在身份细带上，页头再写一遍就是同一事实出现两次
  /// （与打手态删掉页头「打手态」绿标同一条规矩，A+ 清单 ID-C）。页头只说这一屏在看什么。
  static const String title = '待审核申请';

  /// 第二段页头标题（**提现审核**）—— 负责人 2026-10-11：与「充值审核」并列，风格一致
  ///
  /// 同样**不写「提现审核」四个字**：它已经在分段控件上（见 [tabLabels]），页头只描述这一屏。
  static const String withdrawTitle = '待处理提现';

  /// 页头分段：两段就是管理员态能做的**两件事**（充值审核 / 提现审核）
  ///
  /// 值 = [AppSegmented.items]，顺序即下标（[tabRecharge] / [tabWithdraw]）。
  static const List<String> tabLabels = ['充值审核', '提现审核'];

  /// 分段下标（默认第一段 = 充值审核，**改动前的形态**）
  static const int tabRecharge = 0;
  static const int tabWithdraw = 1;

  /// 状态标签/细带用的身份串
  static String get identityLabel => AppIdentityBar.adminLabel;

  /// 列表分页（一页够用：待审核是"需要马上处理"的小集合；多的靠下拉刷新）
  static const int pageSize = 50;

  @override
  State<RechargeAdminShell> createState() => _RechargeAdminShellState();
}

class _RechargeAdminShellState extends State<RechargeAdminShell> {
  late final ApiClient _api = widget.api ?? ApiClient();

  List<PendingRechargeRequest> _items = const [];
  bool _loading = true;
  String? _error;

  /// 当前分段（0 = 充值审核 / 1 = 提现审核）；默认充值审核 = 改动前的形态
  int _tab = RechargeAdminShell.tabRecharge;

  /// 提现审核列表的 State（**它自己管加载**：切到这一段的第一次才发请求）
  final GlobalKey<WithdrawReviewListState> _withdrawKey = GlobalKey<WithdrawReviewListState>();

  /// 提现待处理笔数（分段徽标用；由列表加载结果回填）
  int _withdrawPending = 0;

  @override
  void initState() {
    super.initState();
    AuthStore.instance.addListener(_consumeIdentityNotice);
    unawaited(_load());
  }

  @override
  void dispose() {
    AuthStore.instance.removeListener(_consumeIdentityNotice);
    super.dispose();
  }

  /// 管理员态被动失效提示（被移出白名单/会话过期）：**在这里消费一次**
  ///
  /// 为什么不用 shell 的 initState：401 到达时本 shell 已经挂在树上（不会再 initState），
  /// 而老板态 HomeShell 的 initState 也早跑完了 —— 只有挂监听才收得到这条提示。
  void _consumeIdentityNotice() {
    final notice = AuthStore.instance.identityNotice;
    if (notice == null || !mounted) return;
    // 身份已经回落老板态 → 本页马上会被 HomeShell 换掉，先把握提示弹出来
    AppToast.error(context, notice);
    AuthStore.instance.clearIdentityNotice();
  }

  Future<void> _load({bool force = true}) async {
    if (!mounted) return;
    setState(() {
      _error = null;
      if (_items.isEmpty) _loading = true;
    });
    try {
      // 待审核数（页头事实行）与列表并发；/recharge/me 失败不影响列表可用
      final results = await Future.wait([
        _api
            .request('GET', '/recharge/requests',
                queryParameters: {'status': 'pending', 'page': 1, 'pageSize': RechargeAdminShell.pageSize},
                token: AuthStore.instance.activeToken,
                forceRefresh: force)
            .then<Object?>((v) => v, onError: (Object e) => e),
        _api
            .request('GET', '/recharge/me', token: AuthStore.instance.activeToken, forceRefresh: true)
            .then<Object?>((v) => v, onError: (Object e) => e),
      ]);
      final listResp = results[0];
      final meResp = results[1];
      if (listResp is ApiException) {
        await _handleApiError(listResp);
        return;
      }
      if (meResp is ApiException && meResp.code == 401) {
        await _handleApiError(meResp);
        return;
      }
      if (meResp is! ApiException) {
        try {
          AuthStore.instance.applyAdminMe(RechargeAdminMe.fromJson(_dataOf(meResp as Map)));
        } catch (_) {
          // 静默：事实行的数字，不影响列表
        }
      }
      final page = PendingRechargePage.fromData(_dataOf(listResp as Map));
      if (!mounted) return;
      setState(() {
        _items = page.list;
        _loading = false;
      });
    } on ApiException catch (e) {
      await _handleApiError(e);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 401（受限会话失效）→ 自动切回老板态 + 中文提示；其它错误 → 页内可重试
  Future<void> _handleApiError(ApiException e) async {
    if (e.code == 401) {
      await AuthStore.instance.dropAdminIdentity(e.message);
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = e.message;
    });
  }

  Map<String, dynamic> _dataOf(Map resp) {
    final data = resp['data'];
    return data is Map ? data.cast<String, dynamic>() : (data is List ? {'list': data} : <String, dynamic>{});
  }

  /// 细带右侧「切回老板」：**直接切回**（不是打开弹层）+ Toast（与打手态 ID-B / TR-A 同规则）
  ///
  /// ⚠️ 顺序是**先提示、后切身份**：`switchToBoss()` 会 `notifyListeners` → 宿主立刻把本 shell
  /// 换掉（`mounted` 变 false）→ 那时再弹 Toast 就弹不出来了（真机表现为"点了没反应"）。
  /// Toast 插在根 Overlay 上，因此先弹它也不会随本层一起消失。
  Future<void> _switchBack() async {
    if (widget.onSwitchBack != null) {
      widget.onSwitchBack!();
      return;
    }
    AppToast.success(context, IdentityTransition.toBoss);
    await AuthStore.instance.switchToBoss();
  }

  Future<void> _openDetail(PendingRechargeRequest r) async {
    final result = await Navigator.of(context).push<RechargeReviewOutcome>(
      MaterialPageRoute<RechargeReviewOutcome>(
        builder: (_) => RechargeReviewDetailPage(request: r, api: widget.api, onSwitchBack: _switchBack),
      ),
    );
    if (!mounted || result == null) return;
    // 发放成功 → 列表移除 + Toast「已发放 ¥600.00 余额」；驳回 → 列表移除 + Toast
    setState(() => _items = _items.where((e) => e.id != r.id).toList());
    if (result.granted) {
      AppToast.success(context, '已发放 ${fmtMoney(result.points)} 余额');
      widget.onGranted?.call(r);
    } else {
      AppToast.info(context, '已驳回这笔申请');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthStore.instance.adminMe;
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      // **无底栏**（见类注释：只有一处内容，配一项底栏就是假控件）
      body: Column(
        children: [
          _header(me),
          // 身份细带：页头正下方、内容之上、不随内容滚动（与打手态同一条 28dp 细带）
          AppIdentityBar(
            label: RechargeAdminShell.identityLabel,
            onSwitchBack: _switchBack,
          ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  /// 页头：分段（充值审核 / 提现审核）+ 标题 + 刷新 + 事实行「审核员 · 待审核 N 笔」
  ///
  /// ## 分段为什么放在页头而不是底栏
  /// 管理员态**没有底栏**（负责人定案：只有一处内容时配底栏就是假控件，见类注释）。
  /// 现在管理员态有**两件事**了，但**仍然不引入底栏** —— 底栏是"App 的一级导航"，
  /// 而这个身份的全部内容就是两段审核；用页头里一枚 34dp 的分段切换（[AppSegmented]，
  /// 实色选中、圆角 6、发丝线）说清"我在哪一段"，比给受限身份配一条一级导航更轻。
  ///
  /// 标题随段切换（[RechargeAdminShell.title] / [withdrawTitle]），
  /// 事实行的"待审核 N 笔"也跟着换成当前那一段的数字 —— 两个数字混在一起会看错。
  Widget _header(RechargeAdminMe? me) {
    final onRecharge = _tab == RechargeAdminShell.tabRecharge;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 6, AppSpacing.page, 12),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: Border(bottom: BorderSide(color: T.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 34,
            child: Row(
              children: [
                Text(
                  onRecharge ? RechargeAdminShell.title : RechargeAdminShell.withdrawTitle,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary),
                ),
                const Spacer(),
                IdentityWorkerHeaderButton(
                  icon: AppIdentityIcons.refresh,
                  tooltip: '刷新',
                  onTap: _refreshCurrent,
                ),
              ],
            ),
          ),
          AppSegmented(
            items: RechargeAdminShell.tabLabels,
            current: _tab,
            onChanged: _switchTab,
            // 页头的左右内边距已经在容器上：这里只留上下，避免双重缩进
            padding: const EdgeInsets.fromLTRB(0, 9, 0, 0),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: _error == null ? AppColors.statusOnline : AppColors.textTertiary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  AppIdentityBar.adminFactLine(
                    name: me?.admin.displayName ?? '',
                    pending: onRecharge ? (me?.pendingCount ?? _items.length) : _withdrawPending,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                ),
              ),
              // 事实行随段说明"这个身份能做什么"：两段都是审核，别的管理能力一件都没有
              Text(
                onRecharge ? '只能做充值审核' : '只能做提现审核',
                style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 切换分段：**不重置另一段的缓存**（切回去还是原来那份列表，下拉可校准）
  void _switchTab(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
  }

  /// 刷新当前那一段（提现段由它自己的 State 回源）
  void _refreshCurrent() {
    if (_tab == RechargeAdminShell.tabWithdraw) {
      unawaited(_withdrawKey.currentState?.load() ?? Future<void>.value());
      return;
    }
    unawaited(_load());
  }

  Widget _content() {
    if (_tab == RechargeAdminShell.tabWithdraw) {
      return WithdrawReviewList(
        key: _withdrawKey,
        api: widget.api,
        onSwitchBack: _switchBack,
        onPendingChanged: (n) {
          if (!mounted || n == _withdrawPending) return;
          setState(() => _withdrawPending = n);
        },
      );
    }
    return _rechargeContent();
  }

  Widget _rechargeContent() {
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
                      Text('待审核列表加载失败', style: TextStyle(fontSize: 12.5, color: T.textSecondary)),
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
            IdentityWorkerEmptyState(
              title: '暂无待审核的充值申请',
              detail: '老板提交申请后会出现在这里，下拉可刷新。',
            ),
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
          child: _row(_items[i]),
        ),
      ),
    );
  }

  /// 一行待审核：凭证缩略图 + 用户（昵称/中文 ID）+ 金额·到账余额 + 提交时间
  Widget _row(PendingRechargeRequest r) {
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () => _openDetail(r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RechargeProofThumb(url: r.proofUrl, size: 48, headers: proofImageHeaders(AuthStore.instance.activeToken)),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          r.nickname.isEmpty ? '（无昵称）' : r.nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary),
                        ),
                      ),
                      AppPrice(value: fmtMoney(r.points), size: 16),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    r.uid.isEmpty ? '中文 ID 未下发' : '中文 ID ${r.uid}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Text(RechargeRules.formatYuan(r.amountYuan),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: T.textSecondary)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _timeText(r.createdAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
                        ),
                      ),
                      Text('详情', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.primary)),
                      AppIcon.of(AppIdentityIcons.chevron, size: 14, color: T.primary),
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

  static String _timeText(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)} 提交';
  }
}

/// 审核结果（详情页 pop 回列表时带回）
class RechargeReviewOutcome {
  const RechargeReviewOutcome({required this.granted, required this.points});

  final bool granted;
  final num points;
}

/// 待审核详情（凭证大图 + 用户信息 + 金额/到账余额 + 备注 + 发放/驳回）
///
/// 详情页**同样带身份细带**：细带"出现即表示当前在管理员态"，逐屏一致
/// （与打手态"每屏都能找到细带"同一条验收口径）。
class RechargeReviewDetailPage extends StatefulWidget {
  const RechargeReviewDetailPage({
    super.key,
    required this.request,
    this.api,
    this.onSwitchBack,
  });

  final PendingRechargeRequest request;
  final ApiClient? api;
  final VoidCallback? onSwitchBack;

  /// 凭证大图的热区（测试/出图定位用；点它 = 打开可缩放查看器）
  static const Key proofKey = Key('recharge-proof-image');

  @override
  State<RechargeReviewDetailPage> createState() => _RechargeReviewDetailPageState();
}

class _RechargeReviewDetailPageState extends State<RechargeReviewDetailPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  bool _busy = false;

  PendingRechargeRequest get r => widget.request;

  Future<void> _switchBack() async {
    if (widget.onSwitchBack != null) {
      widget.onSwitchBack!();
      return;
    }
    await AuthStore.instance.switchToBoss();
    if (mounted) Navigator.of(context).maybePop();
  }

  /// 受限会话失效（401）：回落老板态 **并且把详情页一起收掉**
  ///
  /// 为什么必须 pop：详情页是压在 root Navigator 上的一层，HomeShell 换骨架只换它自己那棵子树
  /// —— 不 pop 的话，用户会在"已经是老板态"的界面上继续看着审核详情（身份串味）。
  Future<void> _dropAndExit(String message) async {
    await AuthStore.instance.dropAdminIdentity(message);
    if (mounted) Navigator.of(context).maybePop();
  }

  /// 发放（**必须先过二次确认弹层**；未确认绝不发请求）
  Future<void> _grant() async {
    final ok = await RechargeGrantConfirmSheet.show(context, request: r);
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final resp = await _api.request(
        'POST',
        '/recharge/requests/${r.id}/grant',
        token: AuthStore.instance.activeToken,
        data: const <String, dynamic>{},
      );
      if (!mounted) return;
      // 服务端回带 points 时以它为准（客户端金额×比例只是预览）
      final data = resp['data'];
      final num points = (data is Map ? num.tryParse('${data['points']}') : null) ?? r.points;
      Navigator.of(context).pop(RechargeReviewOutcome(granted: true, points: points));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.code == 401) {
        await _dropAndExit(e.message);
        return;
      }
      // 幂等兜底：重复发放时服务端 400「该申请已发放」→ **原样展示**
      AppToast.error(context, e.message);
    }
  }

  /// 驳回（必须填原因）
  Future<void> _reject() async {
    final reason = await RechargeRejectSheet.show(context, request: r);
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _api.request(
        'POST',
        '/recharge/requests/${r.id}/reject',
        token: AuthStore.instance.activeToken,
        data: {'reason': reason},
      );
      if (!mounted) return;
      Navigator.of(context).pop(const RechargeReviewOutcome(granted: false, points: 0));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.code == 401) {
        await _dropAndExit(e.message);
        return;
      }
      AppToast.error(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          IdentityWorkerPageHeader(
            title: '审核详情',
            actions: [
              IdentityWorkerHeaderButton(
                icon: AppIdentityIcons.close,
                tooltip: '返回',
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
            banner: AppIdentityBar(label: RechargeAdminShell.identityLabel, onSwitchBack: _switchBack),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 24),
              children: [
                _applicantCard(),
                const SizedBox(height: 12),
                _amountCard(),
                const SizedBox(height: 12),
                _proofCard(),
                if (r.note.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _noteCard(),
                ],
              ],
            ),
          ),
          _actionBar(),
        ],
      ),
    );
  }

  Widget _applicantCard() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('申请人', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
          const SizedBox(height: 6),
          Text(r.nickname.isEmpty ? '（无昵称）' : r.nickname,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.textPrimary)),
          const SizedBox(height: 3),
          Text(r.uid.isEmpty ? '中文 ID 未下发' : '中文 ID ${r.uid}',
              style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
          const SizedBox(height: 10),
          Divider(height: 1, thickness: 1, color: T.divider),
          const SizedBox(height: 10),
          Text('提交时间　${_RechargeAdminFormat.time(r.createdAt)}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
        ],
      ),
    );
  }

  Widget _amountCard() {
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('应付金额', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                const SizedBox(height: 5),
                Text(RechargeRules.formatYuan(r.amountYuan),
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
                const Text('发放余额', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                const SizedBox(height: 5),
                AppPrice(value: fmtMoney(r.points), size: 19),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 凭证：列表页缩略图一样，这里是**大图**；点一下进可缩放查看器
  Widget _proofCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('付款凭证', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
        ),
        GestureDetector(
          key: RechargeReviewDetailPage.proofKey,
          behavior: HitTestBehavior.opaque,
          onTap: r.proofUrl.isEmpty
              ? null
              : () => RechargeProofViewer.show(
                    context,
                    r.proofUrl,
                    headers: proofImageHeaders(AuthStore.instance.activeToken),
                  ),
          child: Container(
            height: 260,
            width: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: T.bgCardSolid,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: T.divider),
            ),
            child: r.proofUrl.isEmpty
                ? const Text('这笔申请没有凭证地址', style: TextStyle(fontSize: 12, color: AppColors.textTertiary))
                : ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetImage(
                      url: r.proofUrl,
                      headers: proofImageHeaders(AuthStore.instance.activeToken),
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: 260,
                      placeholder: const Center(
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                      /**
                       * 【2026-10-07 修「付款凭证图一直转圈」的可见性】
                       *
                       * 图加载失败时**必须说话**：原来失败也走上面那个 `placeholder`，
                       * 于是转圈永不消失 —— 审核员既不知道是 404 还是 401，也没有任何下一步。
                       * 现在给中文原因（含状态码）+ 「重试」，重试即重新拉取这张凭证。
                       */
                      errorBuilder: (_, failure, retry) => ImageLoadError(
                        failure: failure,
                        onRetry: retry,
                        title: '凭证图加载失败',
                      ),
                    ),
                  ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 7),
          child: Text('点图可放大核对金额与时间', style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
        ),
      ],
    );
  }

  Widget _noteCard() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('老板备注', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
          const SizedBox(height: 6),
          Text(r.note, style: TextStyle(fontSize: 13, color: T.textSecondary, height: 1.5)),
        ],
      ),
    );
  }

  Widget _actionBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 18),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: Border(top: BorderSide(color: T.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: AppIdentityOutlineButton(
                label: '驳回',
                height: 44,
                expand: true,
                color: AppColors.error,
                onTap: _busy ? () {} : _reject,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: AppIdentityPrimaryButton(
                label: '发放',
                busy: _busy,
                onPressed: _busy ? null : _grant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 发放**二次确认**弹层（负责人硬要求：确认文案里必须明确写"给 某某 发放 ¥600.00 余额"）
///
/// 返回值：true = 用户确认；null/false = 取消（**取消不发任何请求**）。
class RechargeGrantConfirmSheet extends StatelessWidget {
  const RechargeGrantConfirmSheet({super.key, required this.request});

  final PendingRechargeRequest request;

  static Future<bool?> show(BuildContext context, {required PendingRechargeRequest request}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => RechargeGrantConfirmSheet(request: request),
    );
  }

  /// 确认弹层的**主文案**（测试与页面共用同一份实现）
  static String confirmText(PendingRechargeRequest r) {
    final who = r.nickname.isEmpty ? '该用户' : r.nickname;
    return '给 $who 发放 ${fmtMoney(r.points)} 余额';
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
                  Text('发放确认', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
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
                        _kv('申请人', r.nickname.isEmpty ? '—' : r.nickname),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('中文 ID', r.uid.isEmpty ? '—' : r.uid),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('应付金额', RechargeRules.formatYuan(r.amountYuan)),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('发放余额', fmtMoney(r.points)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  AppIdentityBanner.info(
                    title: '发放后余额立刻到老板账上',
                    detail: '这笔申请会从待审核列表移除；重复点发放不会重复到账（服务端只会成功一次）。',
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
                    label: '确认发放',
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
            SizedBox(width: 84, child: Text(k, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText))),
            Expanded(
              child: Text(v, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: T.textSecondary, height: 1.4)),
            ),
          ],
        ),
      );
}

/// 驳回弹层（必须填原因）；返回原因字符串，取消返回 null
class RechargeRejectSheet extends StatefulWidget {
  const RechargeRejectSheet({super.key, required this.request});

  final PendingRechargeRequest request;

  static Future<String?> show(BuildContext context, {required PendingRechargeRequest request}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => RechargeRejectSheet(request: request),
    );
  }

  @override
  State<RechargeRejectSheet> createState() => _RechargeRejectSheetState();
}

class _RechargeRejectSheetState extends State<RechargeRejectSheet> {
  final TextEditingController _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _confirm() {
    final text = _reason.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '请填写驳回原因，老板会在充值记录里看到它');
      return;
    }
    Navigator.of(context).pop(text);
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
                      decoration: BoxDecoration(color: AppColors.dragHandle, borderRadius: BorderRadius.circular(2)),
                    ),
                    Text('驳回申请', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 4, AppSpacing.page, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '驳回 ${r.nickname.isEmpty ? '该用户' : r.nickname} 的 ${fmtMoney(r.amountYuan)} 充值申请',
                      style: TextStyle(fontSize: 13, color: T.textSecondary, height: 1.5),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _error == null ? T.bgCardSolid : AppColors.bannerDangerBg,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _error == null ? AppColors.hairline : AppColors.error),
                      ),
                      child: TextField(
                        controller: _reason,
                        maxLines: 3,
                        style: TextStyle(fontSize: 14, color: T.textPrimary),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '例如：未查到这笔转账 / 截图金额与申请金额不一致',
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
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 20),
                child: Column(
                  children: [
                    AppIdentityPrimaryButton(
                      label: '确认驳回',
                      color: AppColors.error,
                      onPressed: _confirm,
                    ),
                    const SizedBox(height: 9),
                    AppIdentityOutlineButton(
                      label: '取消',
                      height: 40,
                      expand: true,
                      onTap: () => Navigator.of(context).pop(),
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

/// 凭证**大图**（可缩放）：复用既有图片预览能力
///
/// 与老板端聊天页的图片预览是同一套做法（`Dialog` + `InteractiveViewer`），
/// 不引新依赖（`photo_view` 只在 boss-app 里，core 不能用）。
class RechargeProofViewer {
  RechargeProofViewer._();

  /// [headers]：受保护凭证必须带受限会话令牌（公开图 —— 如收款码 —— 不传即可）
  static Future<void> show(BuildContext context, String url, {Map<String, String> headers = const <String, String>{}}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: CachedNetImage(
                url: url,
                headers: headers,
                fit: BoxFit.contain,
                placeholder: const Center(
                  child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                // 【2026-10-07】放大查看器同样不许"无声转圈"：中文原因 + 重试（守 docs/21：
                // 深色蒙层上用白底卡片承载文字，圆角 14 与弹层同档）
                errorBuilder: (c, failure, retry) => Container(
                  padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
                  decoration: BoxDecoration(
                    color: T.bgCardSolid,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ImageLoadError(
                    failure: failure,
                    onRetry: retry,
                    title: '凭证图加载失败',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 凭证缩略图（列表行用；统一尺寸/圆角/空态，避免每处各写一遍）
class RechargeProofThumb extends StatelessWidget {
  const RechargeProofThumb({
    super.key,
    required this.url,
    this.size = 48,
    this.headers = const <String, String>{},
  });

  final String url;
  final double size;

  /// 受保护凭证的鉴权头（见 [proofImageHeaders]）
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.ice,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: T.divider),
      ),
      child: url.isEmpty
          ? AppIcon.of(AppIcon.image, size: size * 0.42, color: T.textTertiary)
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedNetImage(
                url: url,
                headers: headers,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                placeholder: AppIcon.of(AppIcon.image, size: size * 0.42, color: T.textTertiary),
                // 【2026-10-07】48dp 塞不下文字：整格可点即重试（红图标 = 这张图没出来）
                errorBuilder: (_, failure, retry) => ImageLoadError(
                  failure: failure,
                  onRetry: retry,
                  compact: true,
                ),
              ),
            ),
    );
  }
}

/// 详情页的时间格式（本地时区，年月日 + 时分；空值给空串，绝不显示 null）
class _RechargeAdminFormat {
  _RechargeAdminFormat._();

  static String time(DateTime? t) {
    if (t == null) return '—';
    final l = t.toLocal();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}';
  }
}

/// ============================================================================
/// 管理员态**干净度**核验工具（黑名单）
/// ============================================================================
///
/// 三条一起用：
/// 1. **继承打手态那 22 个老板端专属词**（[IdentityWorkerCleanliness.bossOnlyWords]）——
///    管理员态同样是"受限形态"，老板端的东西一个都不许出现；
/// 2. 追加**管理员态自己的**禁用词：别的管理能力（用户管理/封禁/配置）、
///    打手态专有内容（接单大厅/抢单/我的收益）、以及合规红线（提现/兑换现金/支付成功）；
/// 3. **逐屏挑表**（2026-10-11 提现审核上线后新增）：
///    - **充值审核**那一屏用 [rechargeForbiddenWords]（含「提现」—— docs/06 铁律：
///      老板充值链路上不做提现，那四个字不许出现在充值屏上）；
///    - **提现审核**那一屏用 `WithdrawAdminCleanliness.blacklist`
///      （放行「提现」「打款」= 那一屏在看什么/做什么，但**照旧禁用**「积分」「充值」「钱包」）。
///
/// ⚠️ 为什么必须分开：把两段用同一张表 = 要么提现审核屏被自己的功能名判违规，
/// 要么充值屏放行了本该禁掉的「提现」。**同一个身份的两件事，口径不同**，所以两张表。
///
/// 用法：测试对管理员态**每一屏**的可见文本按它所属的表逐条比对，命中任意一个 → FAIL。
class RechargeAdminCleanliness {
  RechargeAdminCleanliness._();

  /// **充值审核**这一屏追加的禁用词（在打手态 22 词之外）
  static const List<String> rechargeForbiddenWords = [
    // 别的管理能力：受限身份只有充值审核 + 提现审核两件事，不能出现任何"管理"字样
    '用户管理',
    '封禁',
    '后台管理',
    '数据看板',
    '系统设置',
    '操作日志',
    // 打手态专有
    '接单大厅',
    '抢单',
    '我的收益',
    '打手态',
    // 订单/服务/娱乐侧（老板态内容）
    '订单',
    '钱包',
    // ⚠️ 2026-10-09：**「余额」已从本黑名单移除** —— 计价单位由「积分」改为「余额」后，
    // 管理员态自己就必须说「发放余额 / 到账余额」（这是它唯一要展示的金额口径），
    // 再把它当"老板端专属词"会把**本屏的正常文案**判成违规。
    // 其余老板端词（钱包/会员/VIP/优惠券/购物/赛事/排行榜/找陪玩…）一律保留。
    '会员',
    'VIP',
    '优惠券',
    '购物车',
    '购物',
    '赛事',
    '排行榜',
    '找陪玩',
    // 合规红线（充值链路上不做提现、不做余额兑换现金）+ 旧计价单位
    '提现',
    '兑换现金',
    '支付成功',
    '自动到账',
    // 2026-10-11：提现链路的禁用词表里已有「积分」（`WorkerWithdrawCopy.forbiddenWords`），
    // 充值链路同样不许出现旧计价单位 —— 两条链路各钉一次，任一处漏掉都测得出
    '积分',
  ];

  /// 两段审核的**并集**（供"整个管理员态一屏都不许出现"的粗筛用）
  ///
  /// ⚠️ 刻意**不含**「充值」：并集要拿去做"整个管理员态"的粗筛，而这个身份的第一段
  /// 就叫「充值审核」（分段控件常驻在页头上）—— 把它塞进并集，等于让粗筛必然命中自己的页签。
  /// 「提现审核那一屏不许出现「充值」」这条更细的规矩落在
  /// `WithdrawAdminCleanliness.auditForbiddenWords` 里（那张表只比对提现审核屏）。
  static const List<String> adminForbiddenWords = [
    ...rechargeForbiddenWords,
  ];

  /// 完整黑名单（打手态 22 词 + 管理员追加词并集，去重后按稳定顺序）
  static List<String> get blacklist {
    final out = <String>[...IdentityWorkerCleanliness.bossOnlyWords];
    for (final w in adminForbiddenWords) {
      if (!out.contains(w)) out.add(w);
    }
    return out;
  }

  /// 在 [texts] 里找出命中的词（空列表 = 干净）；**逐条文本比对**，不拼接
  ///
  /// ⚠️ **本方法是「打手态 22 词 + 两段审核禁用词并集」**：它含「提现」，因此
  /// **不能**用来比对提现审核那一屏（那一屏的页头就写着「提现审核」）。
  /// 提现审核屏用 `WithdrawAdminCleanliness.violations`（放行提现/打款，禁用积分/充值/钱包）。
  static List<String> violations(Iterable<String> texts) => _violationsOf(blacklist, texts);

  static List<String> _violationsOf(List<String> list, Iterable<String> texts) {
    final hit = <String>{};
    for (final t in texts) {
      for (final w in list) {
        if (t.contains(w)) hit.add(w);
      }
    }
    return list.where(hit.contains).toList();
  }
}

/// 管理员态元数据（测试与页面引用同一份常量，避免两套数字）
class RechargeAdminMeta {
  RechargeAdminMeta._();

  /// 管理员态**底栏项数 = 0**（结构性断言：没有底栏）
  static const int bottomNavItemCount = 0;

  /// 管理员态能做的事（**只有三件**）
  static const List<String> abilities = ['看待审核列表', '发放余额', '驳回'];

  /// 页头动作数量（只有刷新一个）
  static const int headerActionCount = 1;

  /// 身份细带文案（「当前身份 · 充值审核」的右段）
  static String get bandLabel => AppIdentityBar.adminLabel;

  /// 完整细带文案（左段 + 右段，测试直接断言这一串）
  static String get bandFullText => '${AppIdentityBar.leadLabel}${AppIdentityBar.adminLabel}';
}
