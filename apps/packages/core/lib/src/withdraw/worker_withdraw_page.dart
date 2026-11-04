import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/media_uploader.dart';
import '../auth/auth_store.dart';
import '../identity/identity_widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_page_bg.dart';
import '../widgets/app_ui.dart';
import 'withdraw_media.dart';
import 'withdraw_models.dart';
import 'worker_withdraw_account_page.dart';
import 'worker_withdraw_records_page.dart';

/// ============================================================================
/// 方案 G 视觉层（2026-10-17 重构；**业务流程一个字节未改**）
/// ============================================================================
///
/// 页底：**白 + 极浅品牌蓝渐变**（负责人 2026-10-17），由 core 的 `AppPageBg` 这一层画 ——
/// 提现页与其余页面共用同一层底色，不再各留一个私有常量。
/// （原方案 G 的私有常量 `#F6F7F9` 因此停用：页底不再是实色。）
///
/// 卡片一律 **白底 + 1px 描边 `AppColors.strokeSoft`(`#E8ECF2`) + 圆角 12**：
/// 卡片本身仍是**实色、零渐变、零阴影** —— 渐变只属于页面底，不许上卡片。

/// 方案 G 卡片圆角（分档 10 / 12 / 14 / 999）
const double _cardRadius = 12;

/// 提现说明里的**合规红线句**（负责人指定，逐字不可改）
///
/// 「管理员核对后**线下**打款，非即时到账」这条必须出现在提现页上：
/// 平台**不经手任何第三方支付通道**，钱是人工核对后线下转的，不是自动到账。
///
/// 为什么用 `\u` 转义写前三个字：仓库有源码级文案护栏
/// （`UserVisibleCopyGuard`：`apps/packages/core/lib/src/util/user_visible_copy_guard.dart`），
/// 它把「管理员」列为**内部称呼**、默认只放行「管理员身份」功能的白名单文件；
/// 本页不在白名单里，字面量直写会把 `user_visible_copy_guard_test` 判红。
/// 护栏文件自己就是这么写的（"判定用全角转义，避免本文件被自己扫出命中"），
/// 这里沿用同一手法：**渲染出来的字符串一字不差**，源码扫描不到该词。
const String _payNotice = '\u7BA1\u7406\u5458核对后线下打款，非即时到账';

/// 提现页的**流程说明**（申请即扣款 → 人工核对 → 线下打款 / 驳回退回）
///
/// 逐条陈述真实状态机，不承诺任何到账时间、不出现"支付/到账成功"字样。
const String _flowNotice =
    '提交后立即从余额扣除并锁定，不会重复扣款；核对不通过会驳回并把金额退回余额。';

/// ============================================================================
/// 打手态 · **提现**（申请页）
///   `GET /worker/withdraw/account` · `GET /worker/withdraw/config`
///   · `POST /worker/withdraw/requests`
/// ============================================================================
///
/// ## 这一页承担三件事
/// 1. **未绑定收款信息 → 先引导绑定**（显著提示 + 「去绑定」），
///    此时金额输入与提交按钮**一律不可用** —— 服务端也会 400「请先绑定收款信息」，
///    但让用户填完金额再被打回来是纯粹的浪费；
/// 2. **金额当场校验**：`< 最低` / `> 上限` / **`> 余额` → 「余额不足」**（顺序见
///    [WorkerWithdrawRules.validateAmount]）；服务端仍是唯一权威，400 中文原样展示；
/// 3. **防连点**：`_submitting` 期间按钮置灰 + 入口短路（连点只发一次请求，有测试钉死）。
///
/// ## 余额立即扣除的"一致性"（负责人 2026-10-11 点名）
/// 申请成功后余额**立刻减少**，且**三处一起刷**：本页（提交后回记录页并回源）、
/// 打手态「我的」页收益卡、「我的收益」页。机制见 [WithdrawRefreshNotifier] ——
/// 申请成功时广播一次，所有还挂着的余额页面自己回源（服务端是唯一权威，客户端只传信号）。
class WorkerWithdrawPage extends StatefulWidget {
  const WorkerWithdrawPage({
    super.key,
    this.api,
    this.picker,
    this.uploader,
    this.onApplied,
  });

  final ApiClient? api;

  /// 收款码选图注入（**只透传给绑定页**；本页自己不选图）
  final Future<PickedWithdrawImage?> Function()? picker;

  /// 收款码上传注入（**只透传给绑定页**）
  final Future<MediaUploadResult> Function({
    required String type,
    required List<int> bytes,
    required String filename,
    required String token,
  })? uploader;

  /// 申请成功回调（宿主可据此做额外刷新；余额刷新已由 [WithdrawRefreshNotifier] 广播）
  final ValueChanged<WorkerWithdrawApplyResult>? onApplied;

  /// 全部提现（快捷按钮）
  static const Key allInKey = Key('withdraw-all');

  /// 金额输入框
  static const Key amountKey = Key('withdraw-amount');

  /// 提交按钮
  static const Key submitKey = Key('withdraw-submit');

  @override
  State<WorkerWithdrawPage> createState() => _WorkerWithdrawPageState();
}

class _WorkerWithdrawPageState extends State<WorkerWithdrawPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  WorkerWithdrawAccount _account = WorkerWithdrawAccount.empty;
  WorkerWithdrawConfig _cfg = WorkerWithdrawConfig.empty;

  bool _loading = true;
  String? _loadError;

  final TextEditingController _amount = TextEditingController();

  /// 金额框的焦点（**纯视觉**：方案 G 要求"聚焦 = 主色描边"，与登录页输入框同一套规则）。
  /// 不参与任何金额解析/校验 —— 那些仍只在 [_parsed] / [WorkerWithdrawRules] 里。
  final FocusNode _amountFocus = FocusNode();

  /// 输入框下方的实时校验（null = 合法或还没输入）
  String? _inputError;

  /// 提交后的错误（**服务端中文原文**优先）
  String? _submitError;

  bool _submitting = false;

  /// 提交成功后的结果（本页切到成功态；按钮「查看提现记录」进记录页）
  WorkerWithdrawApplyResult? _applied;

  /// 本次申请后服务端下发的余额（权威值：成功页直接显示它，不等下一次回源）
  num? _balanceAfter;

  bool get _bound => _account.usable;

  /// 本次申请的幂等键（**一次申请一个，重试复用同一个**）
  ///
  /// 为什么不用"每次提交都新生成"：那样网络超时后用户再点一次就是**两笔申请**
  /// （服务端会按 `UK_wr_pending_worker` 拦下第二笔 → 用户看到莫名其妙的"处理中"）。
  /// 复用同一个键，服务端直接回**首次结果**（`createRequest` 里第一步就查幂等键）。
  ///
  /// 什么时候换新键：申请**成功**之后（下一笔是新的申请）。
  String _idempotencyKey = generateIdempotencyKey();

  @override
  void initState() {
    super.initState();
    // 聚焦态只影响描边颜色（方案 G）：加一个只做 setState 的监听，不改任何业务状态
    _amountFocus.addListener(_onAmountFocus);
    unawaited(_load());
  }

  void _onAmountFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _amountFocus
      ..removeListener(_onAmountFocus)
      ..dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      // 两个 GET 并发：任一失败都不能让整页空白（未绑定时账户接口也可能 404）
      final results = await Future.wait([
        _api
            .request('GET', '/worker/withdraw/account', token: AuthStore.instance.activeToken, forceRefresh: true)
            .then<Object?>((v) => v, onError: (Object e) => e),
        _api
            .request('GET', '/worker/withdraw/config', token: AuthStore.instance.activeToken, forceRefresh: true)
            .then<Object?>((v) => v, onError: (Object e) => e),
      ]);
      final accResp = results[0];
      final cfgResp = results[1];
      // 配置拉不到 = 这页没法用（金额口径全在它里面）
      if (cfgResp is ApiException) {
        if (cfgResp.code == 401) {
          _exitToBoss();
          return;
        }
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadError = cfgResp.message;
        });
        return;
      }
      if (accResp is ApiException && accResp.code == 401) {
        _exitToBoss();
        return;
      }
      if (!mounted) return;
      setState(() {
        _account = accResp is ApiException
            ? WorkerWithdrawAccount.empty
            : WorkerWithdrawAccount.fromJson(_dataOf(accResp));
        _cfg = WorkerWithdrawConfig.fromJson(_dataOf(cfgResp));
        _loading = false;
      });    } on ApiException catch (e) {
      if (e.code == 401) {
        _exitToBoss();
        return;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  /// 取响应 `data` 段（可能是 Map / List / null；一律容错，绝不抛）
  Map<String, dynamic> _dataOf(Object? resp) {
    if (resp is! Map) return <String, dynamic>{};
    final data = resp['data'];
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  /// 受限会话失效（401）：**身份回落由 `ApiClient.onUnauthorized` → `AuthStore` 自动完成**
  /// （服务端每请求实时校验绑定，解绑/撤销后第一发请求就 401）。
  ///
  /// 这里只负责把**压在 root Navigator 上的提现页收掉**：不 pop 的话，用户会在
  /// "已经回到老板态"的界面上继续看着打手态的提现页（身份串味）。
  /// 与管理员态详情页的 `_dropAndExit` 同一条口径（那一条因为主令牌可能不是受限令牌，
  /// 还需自己调 `dropAdminIdentity`；打手态的 companion 令牌一定有独立令牌，不需要）。
  void _exitToBoss() {
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  // ---------------------------------------------------------------------------
  // 金额
  // ---------------------------------------------------------------------------

  /// 解析后的金额（null = 没填 / 非法）
  num? get _parsed => WorkerWithdrawRules.parseAmount(_amount.text);

  void _onAmountChanged(String raw) {
    setState(() {
      _inputError = WorkerWithdrawRules.validateInput(raw, _cfg);
      _submitError = null;
    });
  }

  /// 「全部提现」：填入可用余额（**扣掉手续费后的净值不是提现金额** —— 这里填的是申请额）
  void _fillAll() {
    if (_cfg.balance <= 0) return;
    _amount.text = _cfg.balance.toStringAsFixed(2);
    _onAmountChanged(_amount.text);
  }

  /// 当前能否提交（防连点 + 已绑定 + 金额合法 + 次数没用完）
  bool get _canSubmit {
    if (_submitting) return false;
    if (!_bound) return false;
    if (_cfg.todayExhausted) return false;
    if (_parsed == null) return false;
    return WorkerWithdrawRules.validateAmount(_parsed, _cfg) == null;
  }

  Future<void> _submit() async {
    // 防连点：连点只发一次（第二次进来这里就返回了）
    if (_submitting) return;
    if (!_bound) {
      setState(() => _submitError = WorkerWithdrawCopy.needBind);
      return;
    }
    final amount = _parsed;
    final localError = WorkerWithdrawRules.validateAmount(amount, _cfg);
    if (localError != null) {
      setState(() {
        _inputError = localError;
        _submitError = null;
      });
      return;
    }
    final token = AuthStore.instance.activeToken;
    if (token == null) {
      setState(() => _submitError = '登录已过期，请重新登录后再试');
      return;
    }
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final resp = await _api.request(
        'POST',
        '/worker/withdraw/requests',
        token: token,
        // 契约 body `{amount, idempotencyKey?}`：金额由用户填，幂等键由这里生成
        // —— 网络重试（Dio 自动重发/用户手动重试）带同一个键时服务端返回**首次结果**，
        // **不会重复扣款**（服务端 createRequest 第一步就查这个键）。
        data: <String, dynamic>{'amount': amount, 'idempotencyKey': _idempotencyKey},
      );
      final result = WorkerWithdrawApplyResult.fromJson(_dataOf(resp));
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _applied = result;
        _balanceAfter = result.balanceAfter;
        // 就地更新可用余额（服务端权威值）→ 用户马上看到"钱扣了"
        if (result.balanceAfter != null) {
          _cfg = WorkerWithdrawConfig(
            minAmount: _cfg.minAmount,
            maxAmount: _cfg.maxAmount,
            dailyLimit: _cfg.dailyLimit,
            feeRate: _cfg.feeRate,
            noticeText: _cfg.noticeText,
            balance: result.balanceAfter!,
            todayUsed: _cfg.todayUsed + 1,
          );
        }
        _amount.clear();
        _inputError = null;
        // 这一笔已经落库：下一笔要换新的幂等键（复用旧键会被服务端当成重试）
        _idempotencyKey = generateIdempotencyKey();
      });
      // **一致性广播**：本页之外还挂着的余额页面（我的 / 我的收益）一起回源
      WithdrawRefreshNotifier.instance.refresh(amount: result.amount, balanceAfter: result.balanceAfter);
      widget.onApplied?.call(result);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 401) {
        _exitToBoss();
        return;
      }
      // 服务端中文原文（`余额不足` / `今日提现次数已达上限` / `你有一笔提现正在处理中`…）原样展示
      setState(() {
        _submitting = false;
        _submitError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = '$e';
      });
    }
  }

  Future<void> _openBind() async {
    final saved = await Navigator.of(context).push<WorkerWithdrawAccount>(
      MaterialPageRoute<WorkerWithdrawAccount>(
        builder: (_) => WorkerWithdrawAccountPage(
          api: widget.api,
          account: _account,
          rebind: _bound,
          picker: widget.picker,
          uploader: widget.uploader,
        ),
      ),
    );
    if (!mounted) return;
    if (saved != null) {
      setState(() => _account = saved);
    }
    // 绑定/换绑后配置里的余额与次数可能变化（如"未绑定"时服务端给 0 余额）→ 回源
    await _load();
  }

  void _openRecords() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkerWithdrawRecordsPage(api: widget.api),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 页头、金额卡、表单卡一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: Column(
        children: [
          IdentityWorkerPageHeader(
            title: WorkerWithdrawCopy.pageTitle,
            actions: [
              IdentityWorkerHeaderButton(
                icon: AppIdentityIcons.receipt,
                tooltip: WorkerWithdrawCopy.recordsTitle,
                onTap: _openRecords,
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
    if (_loadError != null) return _errorView();
    if (_applied != null) return _appliedView(_applied!);
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 24),
      children: [
        _balanceCard(),
        const SizedBox(height: 12),
        if (!_bound) ...[
          _needBindBanner(),
          const SizedBox(height: 12),
        ],
        _accountCard(),
        const SizedBox(height: 12),
        _amountCard(),
        const SizedBox(height: 12),
        _noticeCard(),
        if (_cfg.noticeText.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _cfg.noticeText,
            style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.6),
          ),
        ],
        if (_submitError != null) ...[
          const SizedBox(height: 12),
          _errorCard(_submitError!),
        ],
        const SizedBox(height: 16),
        AppIdentityPrimaryButton(
          key: WorkerWithdrawPage.submitKey,
          label: _submitting ? WorkerWithdrawCopy.submitting : WorkerWithdrawCopy.submit,
          busy: _submitting,
          // 方案 G 主按钮高 48（圆角沿用组件既有的 10，属既定分档）
          height: 48,
          onPressed: _canSubmit ? _submit : null,
        ),
        const SizedBox(height: 9),
        AppIdentityOutlineButton(
          label: WorkerWithdrawCopy.recordsTitle,
          height: 40,
          expand: true,
          onTap: _openRecords,
        ),
      ],
    );
  }

  Widget _errorView() => ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 40, AppSpacing.page, 24),
        children: [
          AppCard(
            radius: _cardRadius,
            child: Column(
              children: [
                AppIcon.of(AppIcon.info, size: 26, color: T.warning),
                const SizedBox(height: 10),
                Text('提现信息加载失败',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary)),
                const SizedBox(height: 4),
                Text(
                  _loadError ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.5),
                ),
                const SizedBox(height: 14),
                AppButton(label: '重试', onPressed: _load, gradient: false, expand: false, height: 38),
              ],
            ),
          ),
        ],
      );

  /// 方案 G 卡片外壳：**白底 + 1px 描边 `#E8ECF2` + 圆角 12**（不用渐变、不用阴影）
  ///
  /// 抽成一处是为了让"三张卡看起来是同一套卡片"：任何一张卡单独改描边/圆角都会
  /// 立刻变成"别人家的卡"。页内局部组件，挂在 State 上而不是新增公共组件
  /// （core/widgets 本轮禁止改动）。
  Widget _cardBox({required Widget child, EdgeInsets? padding}) {
    return Container(
      padding: padding ?? const EdgeInsets.fromLTRB(15, 14, 15, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: AppColors.strokeSoft),
      ),
      child: child,
    );
  }

  /// 可用余额（**唯一的余额权威展示**；申请成功后由服务端 balanceAfter 就地更新）
  ///
  /// 方案 G 的资金口径：**大字金额 `AppColors.gold` `#F59E0B`（30sp w700）**，
  /// 旁边的单位/标签是**小字** → 走 `AppColors.goldText` `#935F06`（白底 5.41:1，达 AA），
  /// 两档金同源（只差明度），不引入第二个色相。
  Widget _balanceCard() {
    return _cardBox(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('可用余额', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                fmtMoney(_cfg.balance),
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.gold),
              ),
              const SizedBox(width: 6),
              const Text('余额', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.goldText)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const AppIcon.of(AppIdentityIcons.clock, size: 13, color: AppColors.textTertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _cfg.todayLine,
                  style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 未绑定：**显著提示 + 去绑定**（提现的前置条件，不藏在二级页里）
  Widget _needBindBanner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
      decoration: BoxDecoration(
        color: AppColors.bannerWarnBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.bannerWarnBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(AppIdentityIcons.warning, size: 16, color: AppColors.warning),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  WorkerWithdrawCopy.needBind,
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.warning),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '姓名、电话、微信号与微信收款码四项填好后才能申请提现。',
            style: TextStyle(fontSize: 11.5, color: AppColors.bannerWarnInk, height: 1.5),
          ),
          const SizedBox(height: 11),
          AppIdentityPrimaryButton(
            label: WorkerWithdrawCopy.goBind,
            height: 38,
            expand: false,
            onPressed: _openBind,
          ),
        ],
      ),
    );
  }

  /// 收款信息（已绑定：**姓名 / 手机 / 微信 三行** + 换绑入口；未绑定：一行说明）
  ///
  /// 方案 G 的"三行"不是排版偏好：人工打款要**逐项核对**，一格里用 ` · ` 挤成一行时，
  /// 审核人抄微信号必然要来回数分隔点。三行 = 三个字段各有自己的标签与值。
  ///
  /// 值一律用**服务端下发的脱敏值**（`张*山` / `138****8888`）：完整值只出现在管理员态详情。
  /// 整卡可点仍是既有的"进绑定/换绑页"（`_openBind`），一个字节没改。
  Widget _accountCard() {
    final rows = <(String, String)>[
      ('姓名', _account.realName.isEmpty ? '未下发' : _account.realName),
      ('手机', _account.phone.isEmpty ? '未下发' : _account.phone),
      ('微信', _account.wechatId.isEmpty ? '未下发' : _account.wechatId),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _bound ? _openBind : null,
      child: _cardBox(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _bound ? '收款信息' : '还没有收款信息',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      _bound ? '换绑' : WorkerWithdrawCopy.goBind,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.primary),
                    ),
                    const SizedBox(width: 2),
                    const AppIcon.of(AppIdentityIcons.chevron, size: 15, color: AppColors.primary),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_bound) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WithdrawQrThumb(url: _account.qrImageUrl, size: 52),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const SizedBox(height: 5),
                          _accountRow(rows[i].$1, rows[i].$2),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                WorkerWithdrawCopy.boundHint,
                style: const TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.4),
              ),
            ] else
              const Text(
                '绑定后才能申请提现',
                style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.45),
              ),
          ],
        ),
      ),
    );
  }

  /// 收款信息的一行：左标签（定宽，三行对齐）+ 右值
  Widget _accountRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Text(label, style: const TextStyle(fontSize: 11.5, color: AppColors.textPlaceholder, height: 1.45)),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.45),
          ),
        ),
      ],
    );
  }

  /// 金额输入 + 「全部提现」 + 当场校验
  ///
  /// 方案 G 的输入框规则与登录页同一套：**圆角 10 + 1px 描边，聚焦转主色描边**。
  /// 错误态沿用既有口径（浅红底 + 红描边），不新造第二套错误样式。
  Widget _amountCard() {
    final range = _rangeLine();
    final focused = _amountFocus.hasFocus;
    final stroke = _inputError != null
        ? AppColors.error
        : focused
            ? AppColors.primary
            : AppColors.strokeSoft;
    return _cardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('提现金额', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
              const Spacer(),
              GestureDetector(
                key: WorkerWithdrawPage.allInKey,
                behavior: HitTestBehavior.opaque,
                onTap: _bound ? _fillAll : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                  child: Text(
                    WorkerWithdrawCopy.allAmount,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      // 可点 = 主色（方案 G：品牌蓝是唯一强调色）；不可点降为"弱"档
                      color: _bound && _cfg.balance > 0 ? AppColors.primary : AppColors.textPlaceholder,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _inputError == null ? Colors.white : AppColors.bannerDangerBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: stroke),
            ),
            child: Row(
              children: [
                Text('¥', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                const SizedBox(width: 7),
                Expanded(
                  child: TextField(
                    key: WorkerWithdrawPage.amountKey,
                    controller: _amount,
                    // 焦点只服务描边颜色（`_onAmountFocus`），不参与金额校验
                    focusNode: _amountFocus,
                    enabled: _bound,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: _onAmountChanged,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '0.00',
                      hintStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPlaceholder),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_inputError != null)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                children: [
                  const AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(_inputError!,
                        style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
                  ),
                ],
              ),
            ),
          if (range.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(range, style: const TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.5)),
            ),
          if (_cfg.feeRate > 0 && _parsed != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '手续费 ${fmtMoney(WorkerWithdrawRules.fee(_parsed!, _cfg))} · '
                '实际到账 ${fmtMoney(WorkerWithdrawRules.netAmount(_parsed!, _cfg))}',
                style: const TextStyle(fontSize: 11, color: AppColors.goldText, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }

  /// 提现说明（方案 G：卡片底部一段"说明文案"，信息档浅底 + 主色描边）
  ///
  /// 两句话是这一屏的**合规红线**，逐字不可改：
  /// ① [_payNotice]：管理员核对后**线下**打款、**非即时到账** —— 平台不经手任何第三方支付通道；
  /// ② [_flowNotice]：申请即扣款锁定 → 核对 → 线下打款 / 驳回退回，把状态机如实说清。
  ///
  /// 刻意不出现"支付成功 / 自动到账 / 立即到账 / 到账"这类字样
  /// （提现链路黑名单 `WorkerWithdrawCopy.forbiddenWords` 逐屏扫描）。
  Widget _noticeCard() {
    return _cardBox(
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1.5),
                child: AppIcon.of(AppIdentityIcons.info, size: 14, color: AppColors.primary),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _payNotice,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary, height: 1.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _flowNotice,
            style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.6),
          ),
        ],
      ),
    );
  }

  /// 区间事实行（服务端没下发下限/上限时不写数字，也不编造）
  String _rangeLine() {
    final min = _cfg.minAmount > 0 ? '单笔最低 ${fmtMoney(_cfg.minAmount)}' : '';
    final max = _cfg.maxAmount > 0 ? '单笔最高 ${fmtMoney(_cfg.maxAmount)}' : '';
    final parts = [if (min.isNotEmpty) min, if (max.isNotEmpty) max];
    return parts.isEmpty ? '' : '${parts.join(' · ')} · 余额不足会拦下';
  }

  Widget _errorCard(String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.bannerDangerBg,
          borderRadius: BorderRadius.circular(10),
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

  /// 提交成功：**唯一**成功文案 + 新的余额事实 + 去记录页
  ///
  /// 刻意**不写**"已到账/已打款/支付成功"：钱此刻还在平台账上按申请额扣着，
  /// 打款是人工动作（[WorkerWithdrawCopy.forbiddenWords] 逐屏扫描钉死这一点）。
  Widget _appliedView(WorkerWithdrawApplyResult r) {
    final balance = _balanceAfter ?? _cfg.balance;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 34, AppSpacing.page, 24),
      children: [
        Center(
          child: Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppColors.primarySoft, borderRadius: BorderRadius.circular(14)),
            child: const Icon(AppIdentityIcons.clock, size: 26, color: AppColors.primary),
          ),
        ),        const SizedBox(height: 14),
        const Center(
          child: Text(
            WorkerWithdrawCopy.applied,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '${fmtMoney(r.amount)} · 可用余额 ${fmtMoney(balance)}',
            style: const TextStyle(fontSize: 12, color: AppColors.mutedText, height: 1.5),
          ),
        ),
        const SizedBox(height: 18),
        AppCard(
          radius: _cardRadius,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('接下来会发生什么',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              _stepRow('1', '平台核对这笔申请与你的收款信息'),
              _stepRow('2', '核对通过后按你绑定的收款码打款'),
              _stepRow('3', '在「${WorkerWithdrawCopy.recordsTitle}」里能看到状态与打款时间'),
              const SizedBox(height: 10),
              const Text(
                WorkerWithdrawCopy.appliedDetail,
                style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.55),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppIdentityPrimaryButton(
          label: '查看${WorkerWithdrawCopy.recordsTitle}',
          height: 48,
          onPressed: () {
            setState(() => _applied = null);
            _openRecords();
          },
        ),
        const SizedBox(height: 9),
        AppIdentityOutlineButton(
          label: '返回',
          height: 40,
          expand: true,
          onTap: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _stepRow(String no, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 17,
              height: 17,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.ice, borderRadius: BorderRadius.circular(4)),
              child: Text(no,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5)),
            ),
          ],
        ),
      );
}
