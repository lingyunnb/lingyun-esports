import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/api_client.dart';
import '../api/media_uploader.dart';
import '../auth/auth_store.dart';
import '../icons/app_icon.dart';
import '../models/worker_grade.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_page_bg.dart';
import '../widgets/app_toast.dart';
import '../utils/image_sniff.dart';
import '../widgets/app_ui.dart';
import '../widgets/grade_badge.dart';
import '../withdraw/withdraw_media.dart';
import '../withdraw/worker_withdraw_page.dart';
import '../withdraw/worker_withdraw_records_page.dart';
import '../withdraw/withdraw_models.dart';
import 'identity_switch_sheet.dart';
import 'identity_widgets.dart';
import 'worker_chat_target.dart';
import 'worker_intro_sheet.dart';
import 'worker_orders_page.dart';
import 'worker_wallet_page.dart';
import 'worker_identity_models.dart';

/// 打手态 · **我的**（合并双端 · 身份切换；设计稿 A 套 `a5-worker-mine.html`）
///
/// 内容（负责人要求逐项落地）：
/// 1. **工号**（+ 昵称 + 打手标签 + 可接分部事实行）
/// 2. **个人介绍**（**2026-10-17 新增**：负责人改定「介绍让打手自己写」，
///    入口只有这一处 → [WorkerIntroSheet]；老板态「我的」页没有这个入口，
///    服务端也只对 `role=worker` 放行）
/// 3. **接单权限**：只列**已授权**分部，逐行带「已开通」标签（服务端实时查库，撤销后自动消失）
/// 4. **收益入口**：`GET /worker/my-wallet`（余额 / 累计结算 / 结算笔数 / 打赏收入）→ 明细页
/// 5. **「切换回老板身份」**：放在**页面靠上**（资料头之后、收益卡之前）——放页面底部要滚动
///    才看得到，在 844dp 高度里被折叠就等于没有出口（设计稿 A5 说明）
/// 6. **解绑**：二次确认弹层；解绑后本机忘记该打手账号，**不影响工作端 App 的登录**
///
/// **老板端元素一个不留**：没有会员成长、没有余额卡充值口、没有找陪玩/排行榜/玩家圈。
class IdentityWorkerMinePage extends StatefulWidget {
  const IdentityWorkerMinePage({
    super.key,
    this.api,
    this.openChat,
    this.onSwitchedToBoss,
    this.onSwitchBack,
    this.withdrawPicker,
    this.withdrawUploader,
  });

  final ApiClient? api;
  final IdentityWorkerChatOpener? openChat;

  /// 切回老板态后的回调（shell 侧无需处理，页面自身会因身份变化被卸载）
  final VoidCallback? onSwitchedToBoss;

  /// 身份细带右侧「切回老板」（与页内「切换回老板身份」行走同一套流程）
  final VoidCallback? onSwitchBack;

  /// 提现链路**收款码选图注入**（宿主 App 提供；见 `WithdrawMedia`）
  ///
  /// 为什么一路透传到这一页：提现四页都在 core 里，而选图/裁剪是宿主平台依赖
  /// （core 不引 `image_picker`/`image_cropper`）。与 [openChat] 同一条注入路线。
  final Future<PickedWithdrawImage?> Function()? withdrawPicker;

  /// 提现链路**上传注入**（测试用；不传 → 既有媒体上传链路 `uploadMedia`）
  final Future<MediaUploadResult> Function({
    required String type,
    required List<int> bytes,
    required String filename,
    required String token,
  })? withdrawUploader;

  @override
  State<IdentityWorkerMinePage> createState() => _IdentityWorkerMinePageState();
}

class _IdentityWorkerMinePageState extends State<IdentityWorkerMinePage>
    with WithdrawBalanceRefreshMixin<IdentityWorkerMinePage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  Map<String, dynamic>? _wallet;
  bool _switching = false;

  /// 我的陪玩介绍（`GET /worker/profile`）。
  ///
  /// `null` = 还没取到（卡片显示占位，**不显示假文案**）；`''` = 取到了但打手还没写。
  /// 保存成功后直接用**服务端回传值**覆盖这里，所以本页立刻能看到新简介
  /// （老板端「找陪玩」列表走它自己的 30s SWR 缓存，到点/下拉即变 —— 不为这一处强清缓存）。
  String? _intro;

  /// 头像 / 主页背景 mediaId（负责人 2026-10-18：打手可自定义；null = 用默认字标 / 默认场）
  String? _avatarMediaId;
  String? _backgroundMediaId;

  /// 我的打手等级（`GET /worker/grade`）
  ///
  /// `null` = 没取到 / 接口没下发 → **整张等级卡不画**（结构规则 2：不存在的东西不出现），
  /// 不影响其它区块。取到后卡里显示：当前徽章 + `gradeLabel gradeName` + 升级进度差额。
  WorkerGrade? _grade;

  /// 余额变了（提现申请成功/被驳回退回）→ 收益卡立刻回源
  ///
  /// 打手态三页在 `IndexedStack` 里**一直挂载**，所以这条监听一定在 → 「我的」页的余额
  /// 一定与提现页一致（负责人 2026-10-11：不要只刷一处）。
  @override
  void onWithdrawBalanceChanged() {
    if (mounted) unawaited(_loadWallet());
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadWallet());
    unawaited(_loadIntro());
    unawaited(_loadGrade());
    // 打手资料（工号/昵称/分部权限）用伴随令牌拉一次；失败用绑定摘要兜底
    unawaited(AuthStore.instance.fetchWorkerMe(api: widget.api).catchError((_) => null));
  }

  /// 拉我的打手等级（`GET /worker/grade`，companion 令牌 —— 走 [AuthStore.activeToken]）
  ///
  /// 与公开详情 `GET /public/workers/:id` **同一形状**（服务端同一 `WorkerGradeService.detail()`）：
  /// `grade / gradeLabel / gradeName / rating / progress`。打手态下**只读自己**——
  /// 本接口没有路径参数，主体只从会话主体取，客户端也拿不到别人的等级。
  Future<void> _loadGrade() async {
    try {
      final resp = await _api.request(
        'GET',
        '/worker/grade',
        token: AuthStore.instance.activeToken,
        forceRefresh: true,
      );
      if (!mounted) return;
      setState(() => _grade = WorkerGrade.tryParse(resp['data']));
    } on ApiException {
      // 静默：没有等级数据就整块不画（不挡其它区块，也不编一个等级出来）
    }
  }

  /// 拉自己的简介（`GET /worker/profile`，companion 令牌 —— 走 [AuthStore.activeToken]）
  Future<void> _loadIntro() async {
    try {
      final resp = await _api.request('GET', '/worker/profile', token: AuthStore.instance.activeToken);
      if (!mounted) return;
      setState(() => _intro = '${(resp['data'] as Map<String, dynamic>?)?['intro'] ?? ''}');
    } on ApiException {
      // 静默：卡片显示"还没写介绍"的占位，点进去就能写（不影响其它区块）
    }
  }

  /// 打开「个人介绍」编辑弹层；保存成功 → 卡片立刻显示新文案
  Future<void> _editIntro() async {
    final saved = await WorkerIntroSheet.show(context, api: widget.api, initial: _intro ?? '');
    if (saved == null || !mounted) return;
    setState(() => _intro = saved);
    AppToast.success(context, '简介已保存');
  }

  /// 一行"设置项"：左标签 + 副标 + 右侧状态与箭头
  ///
  /// 与「个人介绍」卡同一个视觉口径（30dp 图标块 + 标题 + 副标 + 箭头），
  /// [taken] 只用于把右侧状态写成"已设置 / 未设置"——**不显示图片本身**：
  /// 这一页是设置入口，预览交给陪玩主页（避免一张图在两处各画一遍、口径漂移）。
  Widget _mediaRow({
    required String label,
    required String hint,
    required bool taken,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 13),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.ice,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const AppIcon.of(AppIdentityIcons.edit, size: 16, color: AppColors.primary),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              taken ? '已设置' : '未设置',
              style: TextStyle(
                fontSize: 11.5,
                color: taken ? AppColors.primary : AppColors.textPlaceholder,
              ),
            ),
            const AppIcon.of(AppIdentityIcons.chevron, size: 16, color: AppColors.textPlaceholder),
          ],
        ),
      ),
    );
  }

  /// 换头像 / 换主页背景（负责人 2026-10-18：打手可自定义）
  ///
  /// 链路与老板端「编辑资料」一致（`ImagePicker` 压缩 → `uploadMedia` → `PUT`），
  /// 只把写入目标从 `/user/profile` 换成 `/worker/profile`：
  /// **打手态是 companion 受限会话，`PUT /user/profile` 会被白名单 403**，
  /// 而 `/worker/*` 天然放行（见 worker-profile.controller 的注释）。
  ///
  /// [isAvatar] true = 头像（用途 `avatar`），false = 主页背景（用途 `bg`）。
  Future<void> _pickAndUpload({required bool isAvatar}) async {
    final label = isAvatar ? '头像' : '主页背景';
    // ⚠️ 不传 `imageQuality` / `maxWidth`（负责人 2026-10-18：「让头像支持动态」）
    //
    // `ImagePicker` 一旦传了 `imageQuality`，Android/iOS 都会把文件**重新编码成 JPEG**
    // —— GIF 的动画帧在那一步就全丢了，用户会以为"我传了动图却变成静止图"。
    // 所以这里取**原文件**，压缩交给服务端：
    // 服务端对非 GIF 走 sharp（>1920px 等比缩放 + JPEG q85），
    // 对 GIF 跳过重编码（见 media.service 的 `sniffed.ext !== 'gif'` 分支）→ 动画保留。
    // 代价：上传体积变大，故头像上限已从 2MB 提到 5MB。
    final picked = await ImagePicker().pickMedia();
    if (picked == null || !mounted) return;
    // 超限时给中文提示（服务端也会拦，但等一个来回不如本地先说）
    // 上限与服务端 TYPE_RULES 对齐：头像 5MB、背景 10MB（2026-10-18 支持动图后各放宽一档）
    final int maxMb = isAvatar ? 5 : 10;
    final int maxBytes = maxMb * 1024 * 1024;
    if (await picked.length() > maxBytes) {
      if (mounted) AppToast.error(context, '$label图片超过 $maxMb MB，请换一张小一点的');
      return;
    }
    try {
      final bytes = await picked.readAsBytes();
      // 上传前校验（2026-10-18）：挡掉视频 / 挡掉"文件名是 .gif 但字节已被转成静态图"
      final kind = sniffImageKind(bytes);
      if (kind == null) {
        if (mounted) AppToast.error(context, '$label只支持 GIF / PNG / JPEG / WebP 图片');
        return;
      }
      if (looksLikeGifName(picked.name) && kind != ImageKind.gif) {
        if (mounted) {
          AppToast.error(
            context,
            '$label选的是动图，但系统已把它转成${kind.label}。请用「文件」而不是相册重新选择原始 GIF',
          );
        }
        return;
      }
      // 打手态一定有令牌（否则页面都进不来）；这里仍显式判空，
      // 是因为 `uploadMedia` 的 token 是非空参数，而 AuthStore 的 getter 是可空类型。
      final token = AuthStore.instance.activeToken;
      if (token == null || token.isEmpty) {
        if (mounted) AppToast.error(context, '登录已过期，请重新切换身份');
        return;
      }
      final up = await uploadMedia(
        type: isAvatar ? 'avatar' : 'bg',
        bytes: bytes,
        filename: picked.name,
        token: token,
      );
      final resp = await _api.request(
        'PUT',
        '/worker/profile',
        token: AuthStore.instance.activeToken,
        data: isAvatar ? {'avatarMediaId': up.id} : {'backgroundMediaId': up.id},
      );
      if (!mounted) return;
      // 服务端回显为准（不拿本地值猜）
      final d = resp['data'] as Map<String, dynamic>?;
      setState(() {
        if (isAvatar) {
          _avatarMediaId = d?['avatarMediaId'] as String? ?? up.id;
        } else {
          _backgroundMediaId = d?['backgroundMediaId'] as String? ?? up.id;
        }
      });
      AppToast.success(context, '$label已更新');
    } on ApiException catch (e) {
      if (mounted) AppToast.error(context, e.message);
    } catch (_) {
      if (mounted) AppToast.error(context, '$label上传失败，请重试');
    }
  }

  Future<void> _loadWallet() async {
    try {
      final resp = await _api.request(
        'GET',
        '/worker/my-wallet',
        token: AuthStore.instance.activeToken,
        // 余额是钱：提现后必须回源，不能吃 45s 缓存
        forceRefresh: true,
      );
      if (!mounted) return;
      setState(() => _wallet = resp['data'] as Map<String, dynamic>?);
    } on ApiException {
      // 静默：收益卡显示占位，下拉再刷
    }
  }

  /// 打手档案：优先实时资料，其次绑定摘要（两条都是服务端下发）
  IdentityWorkerProfile get _profile {
    final wm = AuthStore.instance.workerMe;
    if (wm != null) {
      return IdentityWorkerProfile(
        workerNo: wm.workerNo,
        nickname: wm.nickname,
        avatarMediaId: wm.avatarMediaId,
        canTakeOrder: wm.canTakeOrder,
        canServeCustomer: wm.canServeCustomer,
        workerStatus: 1,
        divisionPermissions: wm.divisionPermissions,
      );
    }
    return AuthStore.instance.identityStatus?.worker ?? IdentityWorkerProfile.empty;
  }

  Future<void> _switchToBoss() async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      // 细带右侧与页内行走**同一套**流程（ID-B：两者等价）
      if (widget.onSwitchBack != null) {
        widget.onSwitchBack!();
        return;
      }
      await AuthStore.instance.switchToBoss();
      widget.onSwitchedToBoss?.call();
      if (!mounted) return;
      AppToast.success(context, IdentityTransition.toBoss);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _unbind() async {
    final ok = await IdentityUnbindSheet.show(context, api: widget.api, worker: _profile);
    if (!ok || !mounted) return;
    // 解绑后伴随令牌已失效 → AuthStore 已自动回到老板态，本页会被 shell 卸载
  }

  /// 打开提现页（选图/上传注入一路透传 —— 见 [IdentityWorkerMinePage.withdrawPicker]）
  void _openWithdraw() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkerWithdrawPage(
          api: widget.api,
          picker: widget.withdrawPicker,
          uploader: widget.withdrawUploader,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthStore.instance,
      builder: (context, _) {
        final p = _profile;
        final divisions = p.takeOrderDivisions;
        // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：打手态三屏与老板端同一层底色。
        // 页头细带、卡片、行列表一律实色 —— 它们浮在渐变上，自身一句未改。
        return AppPageBg(child: Column(
          children: [
            // 页头（A5：标题「我的」）+ 身份细带（A+ ID-A：三屏位置完全一致）
            IdentityWorkerPageHeader(
              title: '我的',
              banner: AppIdentityBar(
                workerNo: p.workerNo,
                nickname: p.nickname,
                onSwitchBack: widget.onSwitchBack,
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadWallet,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 26),
                  children: [
              _profileHeader(p, divisions.isNotEmpty),
              // ---------- 切换回老板（靠上，不需要滚动就能看到） ----------
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 4, AppSpacing.page, 0),
                child: AppCard(
                  padding: EdgeInsets.zero,
                  radius: 14,
                  border: Border.all(color: AppColors.bannerInfoBorder),
                  onTap: _switching ? null : _switchToBoss,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const AppIcon.of(AppIdentityIcons.swap, size: 16, color: AppColors.primary),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('切换回老板身份',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.primary)),
                              const SizedBox(height: 2),
                              Text(
                                _bossHint(),
                                style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                        AppIcon.of(AppIdentityIcons.chevron, size: 16, color: T.textTertiary),
                      ],
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(AppSpacing.page + 2, 8, AppSpacing.page, 0),
                child: Row(
                  children: [
                    AppIcon.of(AppIdentityIcons.info, size: 13, color: AppColors.textTertiary),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '切换后打手账号仍保持绑定，下次可免密切回',
                        style: TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                      ),
                    ),
                  ],
                ),
              ),
              // ---------- 收益（/worker/my-wallet） ----------
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 20, AppSpacing.page, 0),
                child: AppCard(
                  padding: EdgeInsets.zero,
                  radius: 14,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => IdentityWorkerWalletPage(api: widget.api)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('我的收益',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
                            const Spacer(),
                            const Text('结算流水与明细',
                                style: TextStyle(fontSize: 10.5, color: AppColors.textTertiary)),
                            AppIcon.of(AppIdentityIcons.chevron, size: 15, color: T.textTertiary),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              _wallet == null ? '—' : fmtMoney(parsePoints(_wallet?['balance'])),
                              style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700, color: AppColors.gold),
                            ),
                            const SizedBox(width: 6),
                            const Text('余额',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.mutedText)),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 13),
                          child: Divider(height: 1, thickness: 1, color: AppColors.divider),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          child: Row(
                            children: [
                              _stat(fmtMoney(parsePoints(_wallet?['totalIncome'])), '累计结算'),
                              _statDivider(),
                              _stat('${(_wallet?['settlementCount'] as num?)?.toInt() ?? 0}', '结算笔数'),
                              _statDivider(),
                              _stat(fmtMoney(parsePoints(_wallet?['tipIncome'])), '打赏收入'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // ---------- 提现（负责人 2026-10-11：提现放「我的」里，不新开 tab） ----------
              const AppSectionHeader(title: '提现', padding: EdgeInsets.fromLTRB(18, 20, 16, 8)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                child: AppCard(
                  padding: EdgeInsets.zero,
                  radius: 14,
                  child: WorkerWithdrawEntry(
                    balance: _wallet == null ? null : parsePoints(_wallet?['balance']),
                    onTap: _openWithdraw,
                  ),
                ),
              ),
              // ---------- 头像与主页背景（负责人 2026-10-18：打手可自定义） ----------
          //
          // 老板在陪玩主页看到的就是这两张图。放在「个人介绍」之前：
          // 头像是第一眼，介绍是第二眼（信息优先级从"看脸"到"看字"）。
          // 两个入口各自独立上传，互不影响（服务端也是定列更新）。
          const AppSectionHeader(title: '头像与主页背景', padding: EdgeInsets.fromLTRB(18, 20, 16, 8)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            child: AppCard(
              padding: EdgeInsets.zero,
              radius: 14,
              child: Column(
                children: [
                  _mediaRow(
                    label: '头像',
                    hint: '老板在列表和主页看到的那张图',
                    taken: _avatarMediaId != null,
                    onTap: () => _pickAndUpload(isAvatar: true),
                  ),
                  const AppHairline(),
                  _mediaRow(
                    label: '主页背景',
                    hint: '陪玩主页顶部的大图（不设则用默认底纹）',
                    taken: _backgroundMediaId != null,
                    onTap: () => _pickAndUpload(isAvatar: false),
                  ),
                ],
              ),
            ),
          ),

          // ---------- 个人介绍（2026-10-17 负责人改定：介绍让打手自己写） ----------
              //
              // 打手态里**唯一**的简介入口（结构规则 1：同一入口只出现一次）。
              // 卡片直接显示当前简介原文（而不是只给一个"编辑"按钮），因为这段文字就是
              // 老板看到的样子，打手需要能一眼看出"我在外面长什么样"。
              const AppSectionHeader(title: '个人介绍', padding: EdgeInsets.fromLTRB(18, 20, 16, 8)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                child: AppCard(
                  padding: EdgeInsets.zero,
                  radius: 14,
                  onTap: _editIntro,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 13),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: AppColors.ice, borderRadius: BorderRadius.circular(6)),
                          child: const AppIcon.of(AppIdentityIcons.edit, size: 16, color: AppColors.primary),
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
                                      '老板会看到这段话',
                                      style: TextStyle(
                                          fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary),
                                    ),
                                  ),
                                  Text(
                                    (_intro ?? '').isEmpty ? '去填写' : '编辑',
                                    style: const TextStyle(
                                        fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.primary),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _intro == null
                                    ? '正在读取…'
                                    : (_intro!.isEmpty
                                        ? '还没有写介绍。写一句能被记住的话（2–120 字），老板在挑人时会先看这段。'
                                        : _intro!),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: (_intro ?? '').isEmpty ? AppColors.mutedText : T.textSecondary,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: AppIcon.of(AppIdentityIcons.chevron, size: 16, color: T.textTertiary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // ---------- 我的等级（2026-10-17：`GET /worker/grade`） ----------
              //
              // **只在拿到数据时画**：没等级 / 接口没回 → 整段不渲染（结构规则 2）。
              // 内容是"当前徽章 + LV 标签 + 等级名 + 距下一级还差什么"，
              // 每一格数字都来自服务端 `progress.remain`（`gradeRemainItems` 唯一出口）。
              if (_grade != null) ...[
                const AppSectionHeader(title: '我的等级', padding: EdgeInsets.fromLTRB(18, 20, 16, 8)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                  child: _gradeCard(_grade!),
                ),
              ],
              // ---------- 接单权限（只列已授权分部） ----------
              const AppSectionHeader(title: '接单权限', padding: EdgeInsets.fromLTRB(18, 14, 16, 8)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                child: divisions.isEmpty
                    ? AppCard(
                        padding: const EdgeInsets.all(14),
                        radius: 14,
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('你暂无任何分部的接单权限',
                                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                            SizedBox(height: 6),
                            Text(
                              '接单能力由平台按分部开通。请联系客服开通至少一个分部；'
                              '开通后接单大厅会自动出现订单，不用重新绑定。',
                              style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.55),
                            ),
                          ],
                        ),
                      )
                    : AppCard(
                        padding: EdgeInsets.zero,
                        radius: 14,
                        child: Column(
                          children: [
                            for (var i = 0; i < divisions.length; i++) ...[
                              if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.divider, indent: 55),
                              _divisionRow(divisions[i]),
                            ],
                          ],
                        ),
                      ),
              ),
              // ---------- 常用 ----------
              const AppSectionHeader(title: '常用', padding: EdgeInsets.fromLTRB(18, 14, 16, 8)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                child: AppCard(
                  padding: EdgeInsets.zero,
                  radius: 14,
                  child: Column(
                    children: [
                      _row('我的订单', '派单确认、开始服务、提交完成', AppIdentityIcons.receipt, () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => IdentityWorkerOrdersPage(api: widget.api)),
                        );
                      }),
                      _divider(),
                      _row('我的收益', '余额与结算流水明细', AppIdentityIcons.wallet, () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => IdentityWorkerWalletPage(api: widget.api)),
                        );
                      }),
                      _divider(),
                      // 提现（与上方「提现」分组同一落点：入口只有一个动作，两处都能进）
                      _row(
                        WorkerWithdrawCopy.entryTitle,
                        '绑定收款信息后申请提现',
                        AppIdentityIcons.wallet,
                        _openWithdraw,
                      ),
                      _divider(),
                      _row('联系客服', '结算异常、权限问题找这里', AppIdentityIcons.headset, _openCustomerService),
                      _divider(),
                      // 解绑（二次确认）——刻意放在最下面：它是账号级破坏性动作，不该在拇指热区
                      _row(
                        '解除绑定',
                        '本机忘记这个打手账号，不影响工作端 App',
                        AppIdentityIcons.linkOff,
                        _unbind,
                        danger: true,
                      ),
                    ],
                  ),
                ),
              ),
                  ],
                ),
              ),
            ),
          ],
        ));
      },
    );
  }

  String _bossHint() {
    final me = AuthStore.instance.me;
    if (me == null) return '回到你的老板身份';
    final uid = me.uid.isEmpty ? '' : '（${me.uid}）';
    // ⚠️ 文案里**不能**出现「下单」这类老板端词（打手态 22 词黑名单）：
    // 这里只说"回哪个账号"，把"回去干什么"留给老板态自己的界面说。
    return '回到 ${me.nickname}$uid 的老板身份';
  }

  /// 等级卡：当前徽章 + `LV3 扬名` + 距下一级还差什么（数据源 `GET /worker/grade`）
  ///
  /// - 徽章与等级名走 core 唯一出口 [WorkerGradeBadge]（1–2 弱色 / 3 深金 / 4–5 金，零硬编码色值、
  ///   零渐变、零 emoji）；等级中文名**由服务端下发**，客户端不写死（与老板端「会员」无关）；
  /// - 进度逐项一行（完成单 / 好评率 / 五维均分 / 结算累计 / 五维样本），**只列还差 > 0 的项**
  ///   （`gradeRemainItems` 是唯一出口；好评率 `null` = 暂无评价 → 那一项不出现，不编 0）；
  /// - 已到最高档 → 只画一行「已是最高等级」；4 → 5 这一档服务端标了"必须人工审核" →
  ///   差额全 0 时说"等待人工审核"，其余情况说"等待生效"。
  Widget _gradeCard(WorkerGrade g) {
    final p = g.progress;
    final items = gradeRemainItems(p?.remain);
    final next = [p?.nextGradeLabel ?? '', p?.nextGradeName ?? ''].where((s) => s.isNotEmpty).join(' ');
    final note = p == null
        ? ''
        : items.isNotEmpty
            ? (next.isEmpty ? '升级进度' : '距 $next')
            : (next.isEmpty
                ? '已是最高等级'
                : (p.needManualReview ? '门槛已达标，等待人工审核' : '门槛已达标，等待生效'));
    return AppCard(
      padding: EdgeInsets.zero,
      radius: 14,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                WorkerGradeBadge(grade: g.grade, size: 24, label: g.title, labelSize: 13),
                const Spacer(),
                if (note.isNotEmpty)
                  Text(note, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
              ],
            ),
            if (items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Divider(height: 1, thickness: 1, color: AppColors.divider),
              for (final e in items)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Text(e.label, style: const TextStyle(fontSize: 12, color: AppColors.mutedText)),
                      const Spacer(),
                      Text(
                        e.value,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: T.textPrimary),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _profileHeader(IdentityWorkerProfile p, bool hasPermission) {
    final divisions = p.takeOrderDivisions;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 15, AppSpacing.page, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppAvatar(nickname: p.nickname, mediaId: p.avatarMediaId, size: 52, allowAnimation: true),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            p.nickname.isEmpty ? '打手' : p.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.primarySoft,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppColors.bannerInfoBorder),
                          ),
                          child: const Text('打手',
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.primary)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '工号 ${p.workerNo.isEmpty ? '—' : p.workerNo}',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                hasPermission ? AppIdentityIcons.check : AppIdentityIcons.info,
                size: 14,
                color: hasPermission ? AppColors.statusOnline : AppColors.textTertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasPermission
                      ? '在职中 · 可接分部：${divisions.map((d) => d.label).join(' / ')}'
                      : '在职中 · 暂无接单权限',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divisionRow(WorkerDivisionPermission d) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: AppColors.ice, borderRadius: BorderRadius.circular(6)),
              child: const AppIcon.of(AppIdentityIcons.bolt, size: 16, color: AppColors.primary),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                d.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.statusOnlineSoft,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.bannerOkBorder),
              ),
              child: const Text('已开通',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.bannerOkInk)),
            ),
          ],
        ),
      );

  Widget _stat(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: T.textPrimary)),
            const SizedBox(height: 3),
            Text(label, style: const TextStyle(fontSize: 10.5, color: AppColors.textTertiary)),
          ],
        ),
      );

  Widget _statDivider() => Container(width: 1, height: 24, color: AppColors.divider);

  Widget _row(String title, String sub, IconData icon, VoidCallback onTap, {bool danger = false}) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: danger ? AppColors.fieldBg : AppColors.ice,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: AppIcon.of(icon, size: 16, color: danger ? AppColors.mutedText : AppColors.primary),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: danger ? AppColors.error : T.textPrimary)),
                    const SizedBox(height: 2),
                    Text(sub, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4)),
                  ],
                ),
              ),
              AppIcon.of(AppIdentityIcons.chevron, size: 16, color: T.textTertiary),
            ],
          ),
        ),
      );

  Widget _divider() => Divider(height: 1, thickness: 1, color: AppColors.divider, indent: 55);

  Future<void> _openCustomerService() async {
    try {
      final resp = await _api.request('GET', '/user/conversation', token: AuthStore.instance.activeToken);
      final convId = '${resp['data']?['id'] ?? ''}';
      if (!mounted) return;
      final opener = widget.openChat;
      if (opener == null) {
        AppToast.info(context, '本机未接入聊天页，请到「消息 › 客服」里联系');
        return;
      }
      await opener(
        context,
        IdentityWorkerChatTarget(
          conversationId: convId,
          title: '联系客服',
          csConversation: true,
          // 「联系客服」拿到的是**我发起的那条**（`GET /user/conversation`）→ `user` 侧（缺省即 false）
          peerNickname: '祁连山客服',
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.message);
    }
  }
}
