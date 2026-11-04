import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_ui.dart';
import 'identity_widgets.dart';
import 'worker_identity_models.dart';

/// 「切换身份」底部弹层（合并双端 · 身份切换；设计稿 A2 的 7 个状态全覆盖）
///
/// ## 三条设计原则（照设计稿 §6 文案原则）
/// 1. **不替服务端写文案**：所有错误标题/说明都取 `ApiException.message`（服务端中文原文）。
///    弹层只做**分类**（[IdentitySwitchFailure]）决定版式与"下一步动作"，
///    所以把假接口的文案换掉，页面上的字跟着换（验收项 ⑧）。
/// 2. 每条错误都给**一个明确的下一步**（重新输入 / 联系客服 / 联系管理员 / 仍然绑定）。
/// 3. 区分"你输错了"（红色行内错误）与"你拿错了账号"（橙色告知条）。
///
/// ## 为什么要 [autoSwitch] = false
/// "绑定成功但一个分部权限都没有"（`noperm`）是高频首屏路径：先在弹层里把事实说清楚，
/// 由用户决定"仍然进入接单大厅"还是"留在老板态"，而不是绑完直接把人扔进空大厅。
///
/// ## 第二类身份：管理员（充值审核；负责人 2026-10-06 方案②）
/// 上面两张身份卡从"纯告知"升级成**真正的二选一**（[IdentityBindMode]）：
/// - 「我是打手」→ 原流程一行未改（`POST /user/identity/bind`）；
/// - 「我是管理员」→ `POST /user/identity/bind-recharge-admin`，进去后**只能**做充值审核。
///
/// **不显示任何内部规则**：不写"最多 5 个账号"、不写白名单存在与否 —— 那些是服务端约束，
/// 界面只负责把服务端的拒绝原文（账号密码错 / 不在白名单 / 被封禁）显示出来。
class IdentitySwitchSheet extends StatefulWidget {
  const IdentitySwitchSheet({super.key, this.api, this.onSwitched});

  /// 测试注入（不传 → AuthStore 用自己的客户端）
  final ApiClient? api;

  /// 切换成功回调（页面据此弹 Toast / 刷新）：参数是**切到了哪个身份**
  final ValueChanged<AppIdentity>? onSwitched;

  static Future<void> show(
    BuildContext context, {
    ApiClient? api,
    ValueChanged<AppIdentity>? onSwitched,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => IdentitySwitchSheet(api: api, onSwitched: onSwitched),
    );
  }

  @override
  State<IdentitySwitchSheet> createState() => _IdentitySwitchSheetState();
}

/// 弹层里要绑定哪一类**次要身份**（老板身份永远在，不需要"绑定"）
enum IdentityBindMode {
  worker,
  admin;

  String get cardTitle => switch (this) {
        IdentityBindMode.worker => '我是打手',
        IdentityBindMode.admin => '我是管理员',
      };

  String get cardDetail => switch (this) {
        IdentityBindMode.worker => '我来接单：接单大厅、老板私聊、我的收益',
        IdentityBindMode.admin => '我来审核充值：待审核列表、发放余额、驳回',
      };

  String get accountLabel => switch (this) {
        IdentityBindMode.worker => '打手端账号',
        IdentityBindMode.admin => '管理员账号',
      };

  String get accountHint => switch (this) {
        IdentityBindMode.worker => '登录名 / 展示 ID / 工号',
        IdentityBindMode.admin => '平台分配的审核账号',
      };

  String get passwordHint => switch (this) {
        IdentityBindMode.worker => '打手端登录密码',
        IdentityBindMode.admin => '管理员登录密码',
      };

  String get lead => switch (this) {
        IdentityBindMode.worker => '用平台分配给你的打手端账号登录，绑定后本机可一键切换。',
        IdentityBindMode.admin => '用平台分配给你的充值审核账号登录，登录后本机只显示充值审核这一件事。',
      };

  String get primaryLabel => switch (this) {
        IdentityBindMode.worker => '绑定并切换为打手',
        IdentityBindMode.admin => '绑定并切换为管理员',
      };

  String get emptyCredentialMessage => switch (this) {
        IdentityBindMode.worker => '请填写打手端账号与密码',
        IdentityBindMode.admin => '请填写管理员账号与密码',
      };

  /// 目标身份（成功回调里回传）
  AppIdentity get identity => this == IdentityBindMode.admin ? AppIdentity.admin : AppIdentity.worker;
}

class _IdentitySwitchSheetState extends State<IdentitySwitchSheet> {
  final TextEditingController _account = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  bool _loadingStatus = true;

  /// 已绑定（`GET /user/identity` 返回 bound:true）→ 显示免密切换卡
  IdentityBindingStatus? _bound;

  /// 失败态（分类 + 服务端原文）
  IdentitySwitchFailure? _failure;
  String _failureMessage = '';

  /// 绑定成功但无任何分部接单权限时带回的打手摘要（noperm 态用）
  IdentityWorkerProfile? _pendingWorker;

  /// 当前选中的次要身份（打手 / 管理员）——**默认打手**，与改动前的默认形态一致
  IdentityBindMode _mode = IdentityBindMode.worker;

  /// 已绑定打手时仍要显示"绑定表单"（用于**绑定管理员账号**这条入口）
  ///
  /// 为什么需要它：已绑定的老板进来看到的是「免密切换卡」（切换为打手 / 解除绑定），
  /// 管理员入口不能藏在"解绑之后"——那等于要求用户先毁掉打手绑定。这里给一条并行的
  /// 「绑定管理员账号（充值审核）」入口，直接把表单切到管理员形态。
  bool _formOverride = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final status = await AuthStore.instance.fetchIdentityStatus(api: widget.api);
      if (!mounted) return;
      setState(() {
        _bound = status.bound ? status : null;
        _loadingStatus = false;
      });
    } catch (_) {
      // 拉不到绑定状态不影响绑定流程（退化为"未绑定"形态）
      if (!mounted) return;
      setState(() => _loadingStatus = false);
    }
  }

  /// 绑定并切换（[enterAnyway] 用于 noperm 态的「仍然进入接单大厅」）
  Future<void> _bindAndSwitch({bool enterAnyway = false}) async {
    final account = _account.text.trim();
    if (account.isEmpty || _password.text.isEmpty) {
      setState(() {
        _failure = IdentitySwitchFailure.credential;
        _failureMessage = _mode.emptyCredentialMessage;
      });
      return;
    }
    if (_mode == IdentityBindMode.admin) {
      await _bindAdmin();
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
      _failureMessage = '';
    });
    try {
      final result = await AuthStore.instance.bindWorkerIdentity(
        username: account,
        password: _password.text,
        api: widget.api,
        // noperm 路径下由本页决定何时真正切身份
        autoSwitch: enterAnyway,
      );
      final noPerm = result.worker.takeOrderDivisions.isEmpty;
      if (!noPerm) {
        await AuthStore.instance.switchToWorker();
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onSwitched?.call(AppIdentity.worker);
        return;
      }
      if (enterAnyway) {
        await AuthStore.instance.switchToWorker();
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onSwitched?.call(AppIdentity.worker);
        return;
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _pendingWorker = result.worker;
        _bound = AuthStore.instance.identityStatus;
        _failure = IdentitySwitchFailure.noPermission;
        _failureMessage = '绑定成功，但这个打手还没有任何分部的接单权限';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failure = classifyIdentityFailure(code: e.code, message: e.message, errorCode: e.errorCode);
        _failureMessage = e.message;
      });
    } finally {
      AuthStore.instance.clearIdentityBusy();
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  /// 绑定管理员账号 → **受限会话** → 进管理员态（**一条成功路径，没有"noperm"分支**：
  /// 白名单本来就只有"在里面 / 不在里面"两种结果，后者由服务端原文拒绝）。
  Future<void> _bindAdmin() async {
    setState(() {
      _busy = true;
      _failure = null;
      _failureMessage = '';
    });
    try {
      await AuthStore.instance.bindRechargeAdmin(
        username: _account.text.trim(),
        password: _password.text,
        api: widget.api,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSwitched?.call(AppIdentity.admin);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 与打手态同一套分类：账密错 → 行内红字；不在白名单/被封禁 → 服务端原文告知条
        _failure = classifyIdentityFailure(code: e.code, message: e.message, errorCode: e.errorCode);
        _failureMessage = e.message;
      });
    } finally {
      AuthStore.instance.clearIdentityBusy();
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _unbind() async {
    final ok = await IdentityUnbindSheet.show(context, api: widget.api, worker: _bound?.worker);
    if (!ok || !mounted) return;
    // 解绑后绑定关系已消失 → 弹层回到"未绑定"形态
    setState(() {
      _bound = null;
      _failure = null;
      _pendingWorker = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedBuilder(
      animation: AuthStore.instance,
      builder: (context, _) {
        return Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: ConstrainedBox(
            // A+ 清单 SW-A：maxHeight 760（超出时内容区滚动、按钮区固定）
            constraints: const BoxConstraints(maxHeight: 760),
            child: Container(
              decoration: BoxDecoration(
                color: T.bgCardSolid,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                // 唯一允许阴影的地方（A+ 清单 SW-A 硬参数）
                boxShadow: const [BoxShadow(color: Color(0x2E0F172A), blurRadius: 30, offset: Offset(0, -10))],
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ..._body(),
                          ],
                        ),
                      ),
                    ),
                    _footer(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 10, AppSpacing.page, 11),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 4,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(color: AppColors.dragHandle, borderRadius: BorderRadius.circular(2)),
          ),
          Text('切换身份', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
          const Spacer(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: T.divider),
              ),
              child: AppIcon.of(AppIdentityIcons.close, size: 16, color: T.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body() {
    if (_loadingStatus) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      ];
    }
    final f = _failure;
    final children = <Widget>[];

    // ---- 顶部形态：已绑定（免密） / 未绑定（输账密） ----
    if (_bound != null && f != IdentitySwitchFailure.noPermission && !_formOverride) {
      children.addAll(_boundBody(_bound!));
    } else if (f == IdentitySwitchFailure.noPermission) {
      children.addAll(_noPermBody());
    } else {
      children.addAll(_formBody());
    }

    // ---- 失败/告知条（文案一律服务端原文；noPermission 已在上面画过） ----
    if (f != null && f != IdentitySwitchFailure.noPermission && f != IdentitySwitchFailure.credential) {
      children.insert(0, Padding(padding: const EdgeInsets.only(bottom: 12), child: _bannerFor(f)));
    }
    if (f == IdentitySwitchFailure.credential && _failureMessage.isNotEmpty && _bound == null) {
      // 账密错误：行内错误行已经画在密码框下（见 _formBody），这里只保留服务端原文
    }
    return children;
  }

  Widget _bannerFor(IdentitySwitchFailure f) => switch (f) {
        IdentitySwitchFailure.role => AppIdentityBanner.warn(title: _failureMessage),
        IdentitySwitchFailure.banned => AppIdentityBanner.error(title: _failureMessage),
        IdentitySwitchFailure.conflict => AppIdentityBanner.warn(title: _failureMessage),
        IdentitySwitchFailure.rateLimited => AppIdentityBanner.warn(title: _failureMessage),
        _ => AppIdentityBanner.error(title: _failureMessage.isEmpty ? '绑定失败，请稍后重试' : _failureMessage),
      };

  /// 已绑定：**两张身份卡 + 各自的一键切换**（负责人 2026-10-06 截图反馈）
  ///
  /// 结构（不推倒既有卡片，只在其上扩展）：
  /// 1. **打手卡片**（既有）：工号/昵称/已授权分部 + 「切换为打手」（当前就在打手态 → 「正在使用」置灰）
  ///    + 右上「当前」徽标；
  /// 2. **管理员卡片**（新增）：本次运行内已有一枚管理员受限会话时显示 昵称/账号 + 「切换为管理员」
  ///    （当前就在管理员态 → 「正在使用」置灰）+ 徽标；**没有会话时**显示"去验证"形态；
  /// 3. **绑定上限只在"想新增绑定"时出现** —— 已挪到页脚那颗「绑定新的打手账号」下面做解释，
  ///    不再像以前那样顶在卡片上方（那会看着像"不能切换"）。
  List<Widget> _boundBody(IdentityBindingStatus status) {
    final w = status.worker ?? IdentityWorkerProfile.empty;
    final divisions = w.takeOrderDivisions;
    final current = AuthStore.instance.identity;
    final admin = AuthStore.instance.adminMe;
    return [
      _identityCard(
        title: w.nickname.isEmpty ? '已绑定的打手账号' : w.nickname,
        rows: [
          ('工号 / 昵称', w.workerNo.isEmpty ? w.nickname : '${w.workerNo} · ${w.nickname}'),
          ('已授权分部', divisions.isEmpty ? '暂无' : divisions.map((d) => d.label).join('、')),
        ],
        avatarMediaId: w.avatarMediaId,
        badge: current == AppIdentity.worker ? '当前' : null,
        action: _switchAction(target: AppIdentity.worker),
      ),
      const SizedBox(height: 12),
      if (admin != null)
        _identityCard(
          title: admin.admin.displayName,
          rows: [
            ('账号', admin.admin.username.isEmpty ? '—' : admin.admin.username),
            ('权限', '只做充值审核：待审核列表、发放余额、驳回'),
            ('有效期', '本次运行内有效 · App 重启后需重新验证'),
          ],
          badge: current == AppIdentity.admin ? '当前' : null,
          action: _switchAction(target: AppIdentity.admin),
        )
      else
        _adminUnboundCard(),
      const SizedBox(height: 14),
      AppIdentityBanner.info(
        title: '两个身份可以随时来回切',
        detail: '点卡片上的按钮直接切过去，不用重新输密码；'
            '老板这边的登录全程不受影响。App 重启后管理员身份需要重新验证一次。',
      ),
    ];
  }

  /// 卡片底部那颗一键切换按钮（当前身份 → 「正在使用」且不可点）
  Widget _switchAction({required AppIdentity target}) {
    final current = AuthStore.instance.identity;
    final isCurrent = current == target;
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: AppIdentityPrimaryButton(
        label: isCurrent ? '正在使用' : (target == AppIdentity.admin ? '切换为管理员' : '切换为打手'),
        height: 40,
        busy: _busy && !isCurrent,
        onPressed: (isCurrent || _busy) ? null : () => _switchTo(target),
      ),
    );
  }

  /// 一键切换（**不发任何绑定请求**：令牌已经在内存里，只换"当前用哪一枚 + 挂哪个 shell"）
  ///
  /// 失败回退：目标会话已经不在了（换机 / 令牌被清）→ 不切、留在当前身份并给出中文下一步；
  /// 目标令牌**已失效但本地还不知道**时，进去后第一条请求会 401，由 AuthStore 的回退逻辑
  /// 送回"切换前的那个身份"并提示（绝不出现两边都不是的空白态）。
  Future<void> _switchTo(AppIdentity target) async {
    final auth = AuthStore.instance;
    if (target == AppIdentity.worker) {
      if (auth.companionToken == null) {
        setState(() {
          _bound = null;
          _formOverride = false;
          _mode = IdentityBindMode.worker;
          _failure = IdentitySwitchFailure.credential;
          _failureMessage = '本机没有打手登录状态，请重新输入打手端账号与密码';
        });
        return;
      }
      setState(() => _busy = true);
      await auth.switchToWorker();
      try {
        await auth.fetchWorkerMe(api: widget.api);
      } catch (_) {
        // 静默：伴随令牌仍在 12h 窗口内即可用；真失效时由 401 回退兜底
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSwitched?.call(AppIdentity.worker);
      return;
    }
    if (auth.adminBound == false) {
      // 会话不在了（冷启动 / 被移出白名单）→ 走"验证管理员账号"表单，不假装能切
      setState(() {
        _formOverride = true;
        _mode = IdentityBindMode.admin;
        _failure = null;
        _failureMessage = '';
      });
      return;
    }
    setState(() => _busy = true);
    await auth.switchToAdmin();
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onSwitched?.call(AppIdentity.admin);
  }

  /// 管理员**尚未验证**时的卡片：说清"点这里去验证"，而不是给一颗不能点的灰按钮
  Widget _adminUnboundCard() {
    return Container(
      padding: const EdgeInsets.all(13),
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
              const Text('管理员身份', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const Spacer(),
              AppTag('未验证', color: AppColors.statusMuted),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '本次运行还没有验证过管理员账号。验证一次后，就能在这张卡片和打手卡片之间来回切，'
            '不用重新输密码（App 重启后需要再验证一次）。',
            style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.5),
          ),
          const SizedBox(height: 11),
          AppIdentityOutlineButton(
            label: '验证管理员账号',
            height: 40,
            expand: true,
            onTap: _busy
                ? () {}
                : () => setState(() {
                      _formOverride = true;
                      _mode = IdentityBindMode.admin;
                      _failure = null;
                      _failureMessage = '';
                    }),
          ),
        ],
      ),
    );
  }

  /// 绑定成功但零权限（设计稿 A2 `noperm`；负责人要求：**提示但仍可进入大厅看空态**）
  List<Widget> _noPermBody() {
    final w = _pendingWorker ?? AuthStore.instance.identityStatus?.worker ?? IdentityWorkerProfile.empty;
    return [
      AppIdentityBanner.warn(
        title: _failureMessage.isEmpty ? '绑定成功，但这个打手还没有任何分部的接单权限' : _failureMessage,
        detail: '进打手态后接单大厅会是空的。请联系客服开通至少一个分部的接单权限，'
            '开通后大厅会自动出现订单，不用重新绑定。',
      ),
      const SizedBox(height: 12),
      _identityCard(
        title: w.nickname.isEmpty ? '刚绑定的打手账号' : w.nickname,
        rows: [
          ('工号', w.workerNo.isEmpty ? '—' : w.workerNo),
          ('已授权分部', '暂无'),
        ],
        avatarMediaId: w.avatarMediaId,
      ),
    ];
  }

  List<Widget> _formBody() {
    final credErr = _failure == IdentitySwitchFailure.credential;
    return [
      // SW-B 默认态内容顺序：两个身份单选项 → 一行说明 → 账号字段 → 密码字段
      //
      // 这两枚选项在方案②里从"告知"升级为**真正的二选一**（打手 / 管理员）：
      // 仍然做成带单选圆钮的卡片（不是实色胶囊切换器，A+ 稿 13.2 已否掉那种形态），
      // 但可以点 —— 因为现在确实有第二类可绑定的次要身份。
      _identityOptions(),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          _mode.lead,
          style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.5),
        ),
      ),
      _field(
        label: _mode.accountLabel,
        controller: _account,
        hint: _mode.accountHint,
        icon: _mode == IdentityBindMode.admin ? AppIdentityIcons.badge : AppIdentityIcons.boss,
        error: credErr,
        obscure: false,
      ),
      const SizedBox(height: 12),
      _field(
        label: '密码',
        controller: _password,
        hint: _mode.passwordHint,
        icon: AppIconsLegacy.lock_outline_rounded,
        error: credErr,
        obscure: _obscure,
        trailing: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _obscure = !_obscure),
          child: Icon(
            _obscure ? AppIdentityIcons.visibility : AppIdentityIcons.visibilityOff,
            size: 17,
            color: T.textTertiary,
          ),
        ),
      ),
      if (credErr && _failureMessage.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1.5),
                child: AppIcon.of(AppIdentityIcons.warning, size: 13, color: AppColors.error),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _failureMessage,
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: AppColors.error, height: 1.45),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// 两枚身份单选卡（A+ 清单 SW-B：内边距 13/14、圆角 14、间距 11dp、19dp 单选圆钮；
  /// 选中态底 `AppColors.primarySoft` + 描边 `AppColors.primary`）
  ///
  /// 方案②新增一条**互斥**规则：当前处于打手态时，「我是管理员」这张卡置灰
  /// （两枚受限会话不能同时生效），并在卡片下方给出一句明确的下一步
  /// —— 不是把入口藏起来，而是告诉用户"先去哪儿"。
  Widget _identityOptions() {
    final adminLocked = AuthStore.instance.workerIdentity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _optionCard(
                title: IdentityBindMode.worker.cardTitle,
                detail: IdentityBindMode.worker.cardDetail,
                on: _mode == IdentityBindMode.worker,
                onTap: () => _selectMode(IdentityBindMode.worker),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: _optionCard(
                title: IdentityBindMode.admin.cardTitle,
                detail: IdentityBindMode.admin.cardDetail,
                on: _mode == IdentityBindMode.admin,
                enabled: !adminLocked,
                onTap: () => _selectMode(IdentityBindMode.admin),
              ),
            ),
          ],
        ),
        if (adminLocked) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1.5),
                child: AppIcon.of(AppIdentityIcons.info, size: 13, color: AppColors.warning),
              ),
              const SizedBox(width: 5),
              const Expanded(
                child: Text(
                  '当前在打手态，要绑定管理员账号请先切回老板态（顶部细带右侧「切回老板」）。',
                  style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.5),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 切换要绑定的身份：**顺手清掉上一类身份的错误态**（否则打手态的账密红字会挂到管理员表单上）
  void _selectMode(IdentityBindMode mode) {
    if (mode == IdentityBindMode.admin && AuthStore.instance.workerIdentity) return;
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _failure = null;
      _failureMessage = '';
      _pendingWorker = null;
    });
  }

  Widget _optionCard({
    required String title,
    required String detail,
    required bool on,
    bool enabled = true,
    VoidCallback? onTap,
  }) {
    final card = Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: on ? AppColors.primarySoft : T.bgCardSolid,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: on ? T.primary : T.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 19,
                height: 19,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? AppColors.primary : T.bgCardSolid,
                  border: Border.all(color: on ? AppColors.primary : AppColors.tagNeutralBorder, width: 1.5),
                ),
                child: on
                    ? Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                      )
                    : null,
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: enabled ? T.textPrimary : T.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: !enabled
                  ? AppColors.textTertiary
                  : (on ? AppColors.primary : AppColors.mutedText),
            ),
          ),
        ],
      ),
    );
    if (!enabled || onTap == null) return card;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: card);
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required bool error,
    required bool obscure,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
        ),
        Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: error ? AppColors.bannerDangerBg : T.bgCardSolid,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: error ? AppColors.error : AppColors.hairline),
          ),
          child: Row(
            children: [
              AppIcon.of(icon, size: 17, color: T.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscure,
                  enabled: !_busy,
                  style: TextStyle(fontSize: 15, color: T.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: hint,
                    hintStyle: const TextStyle(fontSize: 14, color: AppColors.textTertiary),
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ],
    );
  }

  /// 身份信息卡（发丝线 + 标签值两列；与设计稿 A2 的 `.card` 一致）
  ///
  /// [badge] = 右上角「当前」徽标（**哪个身份正在用**一眼可见，负责人 2026-10-06）；
  /// [action] = 卡片底部的一键切换按钮（「切换为打手 / 切换为管理员」，当前身份显示「正在使用」且置灰）。
  Widget _identityCard({
    required String title,
    required List<(String, String)> rows,
    String? avatarMediaId,
    String? badge,
    Widget? action,
  }) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: BorderRadius.circular(14),
        // 当前身份那张卡给一圈主色描边（比只靠一枚徽标更"一眼看出"，且不引入新颜色）
        border: Border.all(color: badge != null ? T.primary : T.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppAvatar(nickname: title, mediaId: avatarMediaId, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: T.textPrimary),
                ),
              ),
              if (badge != null) AppTag(badge, color: AppColors.statusOnline),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: T.divider),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(rows[i].$1, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                  ),
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: T.textSecondary, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _footer() {
    final f = _failure;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 20 + (bottomPad > 0 ? 0 : 0)),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: AppColors.divider))),
      child: Column(children: _footerButtons(f)),
    );
  }

  List<Widget> _footerButtons(IdentitySwitchFailure? f) {
    // ---- 已绑定：两张卡片各自带一键切换（见 _boundBody）；
    //      页脚只放"新增绑定 / 解除绑定"这两件**与切换无关**的事 ----
    if (_bound != null && f != IdentitySwitchFailure.noPermission && !_formOverride) {
      final status = _bound!;
      final atLimit = status.maxPerBoss > 0 && status.activeCount >= status.maxPerBoss;
      final adminBound = AuthStore.instance.adminBound;
      return [
        AppIdentityPrimaryButton(
          // SW-C：上限已满 → 置灰；但**旁边立刻给出"为什么灰"**（负责人 2026-10-06 要求：
          // 这条警告只在"想新增绑定"时出现，不能看着像"不能切换"）
          label: '绑定新的打手账号',
          onPressed: (atLimit || _busy)
              ? null
              : () => setState(() {
                    _mode = IdentityBindMode.worker;
                    _formOverride = true;
                    _failure = null;
                    _failureMessage = '';
                  }),
        ),
        if (atLimit)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(
              '本机最多绑定 ${status.maxPerBoss} 个打手账号；要换账号请先解除绑定。'
              '（不影响上面的身份切换）',
              style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.45),
            ),
          ),
        const SizedBox(height: 9),
        // 管理员入口与打手绑定**并行**；本次运行内已验证过就不再重复出现（卡片上已有切换按钮）
        if (!adminBound)
          AppIdentityOutlineButton(
            label: '验证管理员账号（充值审核）',
            height: 40,
            expand: true,
            onTap: _busy
                ? () {}
                : () => setState(() {
                      _mode = IdentityBindMode.admin;
                      _formOverride = true;
                      _failure = null;
                      _failureMessage = '';
                    }),
          ),
        if (!adminBound) const SizedBox(height: 9),
        AppIdentityOutlineButton(
          label: '解除绑定',
          height: 40,
          expand: true,
          color: AppColors.error,
          onTap: _busy ? () {} : _unbind,
        ),
      ];
    }

    // ---- 零权限：仍然进入 / 留在老板态（用户任务书：提示但仍可进入大厅看空态） ----
    if (f == IdentitySwitchFailure.noPermission) {
      return [
        AppIdentityPrimaryButton(
          label: '仍然进入接单大厅',
          busy: _busy,
          onPressed: _busy ? null : () => _bindAndSwitch(enterAnyway: true),
        ),
        const SizedBox(height: 9),
        AppIdentityOutlineButton(
          label: '留在老板态',
          height: 40,
          expand: true,
          onTap: () => Navigator.of(context).maybePop(),
        ),
      ];
    }

    // ---- 错误态：主按钮按"这条错误还有没有下一步"决定可用性 ----
    final primaryDisabled = f == IdentitySwitchFailure.role ||
        f == IdentitySwitchFailure.banned ||
        f == IdentitySwitchFailure.conflict ||
        f == IdentitySwitchFailure.rateLimited;
    final primaryLabel = switch (f) {
      IdentitySwitchFailure.credential => '重新绑定',
      IdentitySwitchFailure.role => _mode == IdentityBindMode.admin ? '账号无审核权限' : '账号角色不符',
      IdentitySwitchFailure.banned => '账号已停用',
      IdentitySwitchFailure.conflict => '无法绑定',
      IdentitySwitchFailure.rateLimited => '稍后再试',
      _ => _mode.primaryLabel,
    };
    final secondaryLabel = switch (f) {
      IdentitySwitchFailure.role => '联系客服',
      IdentitySwitchFailure.banned => '联系客服处理',
      IdentitySwitchFailure.conflict => '先不绑定',
      _ => _formOverride ? '返回' : '取消',
    };
    return [
      AppIdentityPrimaryButton(
        label: primaryLabel,
        busy: _busy,
        onPressed: (primaryDisabled || _busy) ? null : () => _bindAndSwitch(),
      ),
      const SizedBox(height: 9),
      AppIdentityOutlineButton(
        label: secondaryLabel,
        height: 40,
        expand: true,
        onTap: () {
          // 「返回」：从"绑定管理员"表单回到已绑定的打手卡（不打任何请求）
          if (_formOverride && f == null) {
            setState(() {
              _formOverride = false;
              _mode = IdentityBindMode.worker;
              _failure = null;
              _failureMessage = '';
            });
            return;
          }
          if (f == IdentitySwitchFailure.role || f == IdentitySwitchFailure.banned) {
            // 「联系客服 / 联系管理员」：不新造客服通道，退回老板态并提示走「我的 › 联系客服」
            Navigator.of(context).maybePop();
            AppToast.info(context, '请在「我的 › 联系客服」里说明情况，由客服协助处理');
            return;
          }
          Navigator.of(context).maybePop();
        },
      ),
    ];
  }
}

/// 「解除绑定」二次确认弹层（设计稿 A6 `unbind`）
///
/// **必须二次确认**（负责人硬要求）：解绑是一个不可逆的账号级动作，
/// 但影响面被刻意限制为"本机忘记这个打手账号"——不影响工作端 App 的登录状态。
class IdentityUnbindSheet extends StatefulWidget {
  const IdentityUnbindSheet({super.key, this.api, this.worker});

  final ApiClient? api;
  final IdentityWorkerProfile? worker;

  /// 返回 true = 解绑成功
  static Future<bool> show(BuildContext context, {ApiClient? api, IdentityWorkerProfile? worker}) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => IdentityUnbindSheet(api: api, worker: worker),
    );
    return ok == true;
  }

  @override
  State<IdentityUnbindSheet> createState() => _IdentityUnbindSheetState();
}

class _IdentityUnbindSheetState extends State<IdentityUnbindSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthStore.instance.unbindWorkerIdentity(api: widget.api);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      AppToast.success(context, '已解绑，打手身份已失效');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.worker ?? AuthStore.instance.identityStatus?.worker ?? IdentityWorkerProfile.empty;
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
                  Text('解除绑定', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(false),
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: T.divider)),
                      child: AppIcon.of(AppIdentityIcons.close, size: 16, color: T.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '解除后本机将忘记这个打手账号，需要重新输入打手端账密才能再次切换。',
                    style: TextStyle(fontSize: 12.5, color: AppColors.mutedText, height: 1.55),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: T.bgCardSolid,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: T.divider),
                    ),
                    child: Column(
                      children: [
                        _kv('工号 / 昵称', w.workerNo.isEmpty ? (w.nickname.isEmpty ? '—' : w.nickname) : '${w.workerNo} · ${w.nickname}'),
                        Divider(height: 1, thickness: 1, color: T.divider),
                        _kv('已授权分部', w.takeOrderDivisions.isEmpty ? '暂无' : w.takeOrderDivisions.map((d) => d.label).join('、')),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  AppIdentityBanner.info(
                    title: '不影响两件事',
                    detail: '① 工作端 App 在那台手机上的登录状态不变；② 你在打手态里的订单、收益、私聊记录都还在，重新绑定就能看到。',
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    AppIdentityBanner.error(title: _error!),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 20),
              child: Column(
                children: [
                  AppIdentityPrimaryButton(
                    label: '解除绑定',
                    color: AppColors.error,
                    busy: _busy,
                    onPressed: _busy ? null : _confirm,
                  ),
                  const SizedBox(height: 9),
                  AppIdentityOutlineButton(
                    label: '取消',
                    height: 40,
                    expand: true,
                    onTap: _busy ? () {} : () => Navigator.of(context).maybePop(false),
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
