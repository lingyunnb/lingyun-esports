import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'about_privacy_page.dart';
import 'chat_detail_page.dart';
import 'edit_profile_page.dart';
import 'membership_page.dart';
import 'notification_page.dart';
import 'recharge_page.dart';
import 'security_page.dart';
import 'settings_page.dart';
import 'wallet_page.dart';

/// 「我的」页 —— **方案 G 视觉重构**（负责人 2026-10-17 定案）
///
/// ## 逻辑零改动（本轮硬约束）
/// 数据来源、接口、状态流转、路由目标**一个字节都没改**：
/// - 余额 `GET /user/wallet`、订单三状态计数 `GET /user/orders`（45s SWR，下拉强刷）；
/// - 绑定状态 `GET /user/identity`（失败静默 → 退化为"未绑定"形态）；
/// - 会员等级 `LevelRulesStore`；客服会话 `GET /user/conversation`；
/// - 跳转：余额明细 → `WalletPage`、编辑资料 → `EditProfilePage`、会员 → `MembershipPage`、
///   系统通知 → `NotificationPage`、账号安全 → `SecurityPage`、设置 → `SettingsPage`、
///   关于 → `AboutPrivacyPage`、订单 → 底栏订单 tab —— 全部与改版前一致。
///
/// ## 方案 G 的 5 块（自上而下）
/// ① 页头：白底实色 + 发丝线 + 19sp「我的」（无渐变、无多余图标入口）；
/// ② **资料卡**：头像 + 昵称 +「当前身份：老板」+ 展示 ID + 编辑资料 →（发丝线）→ 会员成长；
/// ③ **余额卡**：深墨蓝 `#0F2440` **实底白字** + 大号余额 + 右侧「充值 / 明细」两枚次按钮；
/// ④ **我的订单四宫格**：图标按**功能区色相**着色、数字 **tabular**；订单为 0 时给去下单空态；
/// ⑤ **服务宫格 3×2**（**紧跟「我的订单」**：负责人 2026-10-17 真机反馈「把这个放到我的订单的下面」）
///    —— 图标按 [featureOfIcon] / [featureHue] 的**语义色**着色（同功能同色）；
/// ⑥ **身份**区（绑定打手账号 / 切换身份 / 解除绑定）—— 因为 ⑤ 上移，本区落到页面最末。
///
/// **注释型浅色小字已全删**（负责人 2026-10-17）：分区标题右侧的说明、宫格每格的一句话说明、
/// 底部「切换后只显示…」这类解释段落一律不再渲染；只留**数据标签**（如「待接单」「全部订单 17 单」）
/// 与**功能文案**（如「去下单」「重新加载」「复制」）。
///
/// 视觉口径（方案 G）：页底 `#F6F7F9`、卡片白底 + 1px 描边 `#E8ECF2` + 圆角 **12**、
/// 正文 `#14202E` / 次要 `#4A5A6E` / 弱 `#8A99AB`、强调色只有品牌蓝 `#2563EB`、
/// **零渐变、零阴影**（阴影只给弹层）、图标一律 `AppIcon` 新体系（无 emoji）。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.onNavigate});

  /// 切换底部 tab（我的订单 → 订单 tab；空态「去下单」→ 服务 tab）
  final ValueChanged<int>? onNavigate;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  // 页底（2026-10-17）：原方案 G 的 `#F6F7F9` 实色页底已停用 —— 全站页底统一改由
  // `AppPageBg` 画「白 + 极浅品牌蓝」渐变（负责人要求），因此本页不再持有页底色常量。
  // 卡片圆角、卡间距、等宽数字等其余常量一个字未动。

  /// 卡片圆角（方案 G：卡片档 12）
  static const double _cardRadius = 12;

  /// 卡间间距（组间松；方案 G 的 20–24 档取 16，页面更紧凑）
  static const double _cardGap = 16;

  /// 数字用等宽（tabular）：余额/计数不再左右抖
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  final ApiClient _api = ApiClient();
  double? _balance;
  int? _orderCount;

  /// 订单三状态计数（待接单 / 进行中 / 待评价；均由服务端订单列表真实统计）
  int? _pendingTake;
  int? _inProgress;
  int? _pendingConfirm;

  /// 资产区加载态（数据未到 → 骨架占位，不留空白）
  bool _statsLoading = true;

  /// 资产区失败态（拉取失败 → 可见中文提示 + 重试入口）
  bool _statsError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStats());
    unawaited(LevelRulesStore.instance.ensureLoaded());
    // 绑定状态（合并双端 · 身份切换）：老板态「我的」页身份分组的数据源。
    // 拉失败静默 —— 身份分组退化为"未绑定"形态，不影响页面其它部分（口径与改版前一致）。
    unawaited(AuthStore.instance.fetchIdentityStatus().catchError((_) => IdentityBindingStatus.empty));
  }

  /// 核心数据：余额 + 订单数 + 三状态计数（全部服务端真实数据）
  ///
  /// 失败**不再静默**：置 [_statsError]，资产卡渲染中文提示 + 「重新加载」。
  Future<void> _loadStats({bool force = false}) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) return;
    try {
      final results = await Future.wait([
        _api.request('GET', '/user/wallet', token: token,
          forceRefresh: force),
        // 订单三状态计数同源 /user/orders（45s SWR 缓存）→ 下拉刷新必须强刷，
        // 否则订单已完成，「进行中」计数仍停在旧值（负责人 2026-10-04 报障）
        _api.request('GET', '/user/orders', token: token,
          forceRefresh: force, queryParameters: {'page': 1, 'pageSize': 50}),
      ]);
      if (!mounted) return;
      final list = ((results[1]['data'] as Map<String, dynamic>?)?['list'] as List?) ?? const [];
      int countOf(Set<String> statuses) =>
          list.where((e) => statuses.contains('${(e as Map)['status']}')).length;
      setState(() {
        _balance = ((results[0]['data'] as Map<String, dynamic>?)?['balance'] as num?)?.toDouble() ?? 0;
        _orderCount = ((results[1]['data'] as Map<String, dynamic>?)?['total'] as num?)?.toInt() ?? 0;
        _pendingTake = countOf({'pending_take'});
        _inProgress = countOf({'taken', 'in_progress'});
        _pendingConfirm = countOf({'pending_confirm'});
        _statsLoading = false;
        _statsError = false;
      });
    } catch (_) {
      // 可见失败态（不是静默）：网络/服务异常都落到这里，用户能看见并且能重试
      if (!mounted) return;
      setState(() {
        _statsLoading = false;
        _statsError = true;
      });
    }
  }

  Future<void> _reloadStats() async {
    setState(() {
      _statsLoading = true;
      _statsError = false;
    });
    await _loadStats(force: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 页头白条、余额卡、服务宫格一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: AnimatedBuilder(
        animation: Listenable.merge([AuthStore.instance, LevelRulesStore.instance]),
        builder: (context, _) {
          final me = AuthStore.instance.me;
          if (me == null) return const _ProfileSkeletonPage();
          return Column(
            children: [
              // ---------- ① 页头：白底实色 + 发丝线 + 19sp「我的」----------
              const _ProfileHeader(),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _loadStats(force: true),
                  // 用 SingleChildScrollView + Column 而不是 ListView：本页只有 5 块、
                  // 高度可控，整块构建换来"树序断言/保证可见"这类结构测试的确定性
                  // （ListView 的懒构建会让靠后的"服务宫格"在某些视口下根本没被 build）。
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: 14,
              bottom: 28 + NavStyleController.instance.navReservedHeight,
            ),
                    child: Column(
                      children: [
                        // ---------- ② 资料卡（资料 + 会员成长同卡）----------
                        _buildProfileCard(context, me),
                        const SizedBox(height: _cardGap),
                        // ---------- ③ 余额卡（深墨蓝实底白字 + 充值/明细）----------
                        _buildBalanceCard(context),
                        const SizedBox(height: _cardGap),
                        // ---------- ④ 我的订单四宫格 ----------
                        _buildOrdersCard(context),
                        const SizedBox(height: _cardGap),
                        // ---------- ⑤ 服务宫格 3×2（**紧跟「我的订单」**——负责人 2026-10-17 真机反馈）----------
                        _buildServiceCard(context),
                        const SizedBox(height: _cardGap),
                        // ---------- ⑥ 身份（放在服务区之后，页面最末）----------
                        _buildIdentityGroup(context),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      )),
    );
  }

  /// 方案 G 卡片：白底 + 1px 描边 `#E8ECF2` + 圆角 12（**零阴影**）
  Widget _gCard({required Widget child, EdgeInsetsGeometry? padding, VoidCallback? onTap}) {
    final body = Container(
      padding: padding ?? EdgeInsets.zero,
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: AppColors.strokeSoft),
      ),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(_cardRadius), child: body),
    );
  }

  // =====================================================================================
  // ② 资料卡（头像 / 昵称 / 当前身份 / 展示 ID / 编辑资料 + 会员成长）
  // =====================================================================================

  /// 资料卡**上半部分**（负责人 2026-10-18 照设计图定稿）
  ///
  /// ## 严格照图的三条
  /// 1. **动态背景只铺在这一块**（头像 / 昵称 / 身份 / ID / 编辑资料那一行），
  ///    卡片的**会员等级区以下是纯白**，不受背景影响 —— 图里明确标注了
  ///    「会员等级区域以下保持原有白色背景不受影响」。
  /// 2. 背景被**卡片顶部圆角裁住**：`_gCard` 是裸 `Container(decoration)`，没有
  ///    `clipBehavior`，所以这里自己套 `ClipRRect(vertical top)`，否则图会溢出圆角。
  /// 3. 有背景时**前景整体转白**（名字 / 身份 / ID / 编辑资料），并压一层
  ///    左深右浅的遮罩 —— 不这么做，深墨字压在深色星空上直接读不清。
  ///
  /// ## 没有背景时
  /// 与改动前**逐像素一致**：深墨名字、`AppIdentityTag`、灰 ID、描边胶囊按钮。
  /// 这条是硬约束：自定义背景是可选能力，不设就该和以前一模一样。
  Widget _profileHeader(BuildContext context, AuthMe me) {
    final cover = me.backgroundMediaId;
    final hasCover = cover != null && cover.isNotEmpty;

    // 前景色：有背景 → 白；无背景 → 原有深墨（一个色值都没改）
    final nameColor = hasCover ? Colors.white : AppColors.textPrimary;
    final subColor = hasCover ? const Color(0xD9FFFFFF) : AppColors.statusMuted;
    final btnFg = hasCover ? Colors.white : AppColors.textSecondary;

    return ClipRRect(
      // 只裁上边两角：下半段是白色会员区，不属于背景范围
      borderRadius: BorderRadius.vertical(top: Radius.circular(_cardRadius)),
      child: Stack(
        children: [
          // ① 动态背景（用户上传的 GIF/静图；GIF 会动 —— Image.network 不传 cacheWidth）
          if (hasCover)
            Positioned.fill(
                // 视频背景（2026-10-21「实况」）→ 循环静音播放；
                // 图片（含 GIF）→ Image.network，不传 cacheWidth 所以动图会播。
                // 类型由服务端 `/auth/me` 的 backgroundType 指认（mediaId 看不出类型）。
                child: me.backgroundIsVideo
                    ? _CoverVideo(mediaId: cover)
                    : Image.network(
                        AppConfig.resolveMediaUrl('/media/public/$cover'),
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
            ),
          // ② 遮罩：左深右浅（名字在左侧，先把对比度给到文字区）
          if (hasCover)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0x9E0F2440), Color(0x380F2440)],
                  ),
                ),
              ),
            ),
          // ③ 内容（与改动前同一套结构，只按有无背景切配色）
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(
              children: [
                // 头像：有背景时加一圈白描边（图里就是这么做的：让头像从背景里"浮"出来）
                Container(
                  padding: hasCover ? const EdgeInsets.all(2) : EdgeInsets.zero,
                  decoration: hasCover
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.85),
                            width: 2,
                          ),
                        )
                      : null,
                  child: AppAvatar(
                    nickname: me.nickname,
                    mediaId: me.avatarMediaId,
                    size: 52,
                    // 头像支持动图（2026-10-18）
                    allowAnimation: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        me.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: nameColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 身份标签：有背景 → 半透明白描边胶囊（图里样式）；
                      // 无背景 → 原有 AppIdentityTag（组件不动）
                      if (hasCover)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                          ),
                          child: const Text(
                            AppIdentityTag.bossLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Colors.white,
                            ),
                          ),
                        )
                      else
                        // 必须套 `Row(mainAxisSize: min)`：AppIdentityTag 内部是
                        // Container(alignment:)，直接进 Column 会被拉满整行
                        const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [AppIdentityTag(AppIdentityTag.bossLabel)],
                        ),
                      const SizedBox(height: 5),
                      Text(
                        'ID: ${me.uid}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: subColor),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 编辑资料：有背景 → 玻璃感半透明胶囊（白字白边）；无背景 → 原描边胶囊
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const EditProfilePage()),
                  ),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                    decoration: BoxDecoration(
                      color: hasCover
                          ? Colors.white.withValues(alpha: 0.2)
                          : null,
                      border: Border.all(
                        color: hasCover
                            ? Colors.white.withValues(alpha: 0.55)
                            : AppColors.strokeSoft,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon.of(AppIcon.edit, size: 13, color: btnFg),
                        const SizedBox(width: 4),
                        Text(
                          '编辑资料',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: btnFg,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context, AuthMe me) {
    final style = levelStyleOf(me.level);
    final progress = _levelProgress(me);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: _gCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              _profileHeader(context, me),
            const AppHairline(),
            // 会员成长（同卡下半段，点击进会员中心）
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MembershipPage())),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(style.label,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                        const SizedBox(width: 8),
                        AppTag('L${me.level}', color: style.color),
                        const Spacer(),
                        Text('累计消费 ${fmtMoney(me.totalSpent)}',
                            style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText)),
                        AppIcon.of(AppIcon.chevronRight, size: 15, color: AppColors.textPlaceholder),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 6,
                        backgroundColor: AppColors.primarySoft,
                        valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('${(progress * 100).round()}% 进度',
                            style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _levelHint(me),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10.5, color: AppColors.mutedText),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================================================
  // ③ 余额卡（深墨蓝 #0F2440 实底白字 + 大号余额 + 右侧「充值 / 明细」）
  // =====================================================================================

  Widget _buildBalanceCard(BuildContext context) {
    final solidInk = AppColors.brandInk;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 16),
        decoration: BoxDecoration(
          color: solidInk,
          borderRadius: BorderRadius.circular(_cardRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 「余额」是资产区的入口名（页底灰底上唯一一处「余额」字样）
                const Text('余额',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
                const Spacer(),
                // 两枚次按钮（白 30% 描边胶囊；充值进既有 RechargePage，明细进既有 WalletPage）
                _darkPill('充值', () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RechargePage()));
                }),
                const SizedBox(width: 8),
                _darkPill('明细', () {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WalletPage()));
                }),
              ],
            ),
            const SizedBox(height: 10),
            if (_statsError)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Row(
                  children: [
                    const AppIcon.of(AppIcon.info, size: 15, color: Colors.white70),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('余额与订单未能加载，请检查网络后重试',
                          style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.4)),
                    ),
                    const SizedBox(width: 8),
                    _darkPill('重新加载', _reloadStats, solid: true),
                  ],
                ),
              )
            else if (_statsLoading)
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 2),
                child: _AssetSkeleton(key: Key('profile-asset-skeleton'), onDark: true),
              )
            else ...[
              // 余额最多 ¥85,383.50（9 字符）→ FittedBox 兜住超长金额/大字号系统字体，
              // 绝不裁切、绝不省略（金额被省略号吃掉是不可接受的）
              Row(
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: AppPrice(value: fmtMoney(_balance ?? 0), size: 34, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('余额由平台发放，仅限平台内消费，不可提现、不可转让',
                  style: TextStyle(fontSize: 10.5, color: Colors.white54, height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }

  /// 深墨蓝卡上的小胶囊按钮（白色描边 / `solid` = 白底深字）
  Widget _darkPill(String label, VoidCallback onTap, {bool solid = false}) {
    final radius = BorderRadius.circular(999);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: solid ? Colors.white : Colors.transparent,
            borderRadius: radius,
            border: solid ? null : Border.all(color: Colors.white.withValues(alpha: .30)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: solid ? AppColors.brandInk : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  // =====================================================================================
  // ④ 我的订单四宫格（图标按功能区色相、数字 tabular）
  // =====================================================================================

  Widget _buildOrdersCard(BuildContext context) {
    final ordersEmpty = (_orderCount ?? 0) == 0;
    final showEmpty = ordersEmpty && !_statsLoading && !_statsError;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: _gCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 12, 0),
              child: Row(
                children: [
                  const Text('我的订单',
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                  const Spacer(),
                  // 「全部订单」保留改版前的动作：进订单 tab
                  InkWell(
                    onTap: () => widget.onNavigate?.call(1),
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('全部订单 ${_orderCount ?? 0} 单',
                              style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                          AppIcon.of(AppIcon.chevronRight, size: 15, color: AppColors.textPlaceholder),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 四宫格：待接单 / 进行中 / 待评价 / 全部订单
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 10, 6, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _orderCell('待接单', _pendingTake, AppIcon.clock, AppFeature.money),
                  ),
                  Expanded(
                    child: _orderCell('进行中', _inProgress, AppIcon.bolt, AppFeature.support),
                  ),
                  Expanded(
                    child: _orderCell('待评价', _pendingConfirm, AppIcon.star, AppFeature.safe),
                  ),
                  Expanded(
                    child: _orderCell('全部订单', _orderCount, AppIcon.orders, AppFeature.brand, showArrow: true),
                  ),
                ],
              ),
            ),
            if (showEmpty) ...[
              const AppHairline(),
              InkWell(
                onTap: () => widget.onNavigate?.call(0),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(14, 11, 12, 12),
                  child: Row(
                    children: [
                      AppIcon.of(AppIcon.orders, size: 14, color: AppColors.textPlaceholder),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('还没有订单，去看看有哪些陪玩服务',
                            style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                      ),
                      Text('去下单',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.primary)),
                      AppIcon.of(AppIcon.chevronRight, size: 15, color: AppColors.primary),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 订单四宫格单项：图标（功能区色相）+ 数字（tabular）+ 名称
  ///
  /// 图标尺寸刻意用 20（不是 17）：服务宫格那 5 枚 17dp 图标是既有回归用例的锚点。
  Widget _orderCell(String label, int? count, IconData icon, AppFeature feature, {bool showArrow = false}) {
    final hue = featureHue(feature);
    return InkWell(
      onTap: () => widget.onNavigate?.call(1),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: featureSoft(feature),
                borderRadius: BorderRadius.circular(10),
              ),
              child: AppIcon.of(icon, size: 20, color: hue),
            ),
            const SizedBox(height: 6),
            Text(
              count == null ? '—' : '$count',
              maxLines: 1,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                fontFeatures: _tabular,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: const TextStyle(fontSize: 11, color: AppColors.mutedText)),
                if (showArrow) AppIcon.of(AppIcon.chevronRight, size: 13, color: AppColors.textPlaceholder),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================================================
  // ⑥ 身份区块（负责人 2026-10-17：服务区上移后，本区落到页面最末）
  // =====================================================================================

  /// 身份区块（A+ 清单 ID-D / ID-E / SW-C）
  ///
  /// - 位置：**服务宫格之后**（页面最末）—— 2026-10-17 负责人把「服务」提到「我的订单」下面；
  /// - 组标题 `AppSectionHeader`（15sp w700），**右侧不再挂说明小字**
  ///   （原为「打手端账号绑定后可在本机切换」/「已绑定打手端账号」/「已达上限 …」）；
  /// - **未绑定打手账号时不存在"切换身份"入口**（结构规则 2「不存在的东西不出现」）：
  ///   入口文案退化为「绑定打手账号」，切换能力在绑定后才出现；
  /// - 行尾是**可见的**「当前身份：老板」中性标签（ID-D）；同一枚标签也在资料卡昵称行（ID-E）。
  /// - 行内二级文案是**绑定状态数据标签**（「未绑定打手端账号」/「已绑定 · 工号」），保留；
  ///   原来那行「切换后只显示接单大厅…」属于解释性段落，已删。
  Widget _buildIdentityGroup(BuildContext context) {
    final status = AuthStore.instance.identityStatus;
    final bound = status?.bound == true;
    final worker = status?.worker;
    // 副标题只写"绑定状态"本身：身份事实已由行尾那枚**可见标签**「当前身份：老板」表达
    final sub = bound ? '已绑定 · ${worker?.shortLabel ?? '打手账号'}' : '未绑定打手端账号';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(
          title: '身份',
          padding: EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 8),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: _gCard(
            child: Column(
              children: [
                // 入口行（左右内边距 14/12、图标容器 30×30 r10 浅蓝底、主文案 14sp w600）
                InkWell(
                  onTap: _openIdentitySheet,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
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
                          child: AppIcon.of(AppIdentityIcons.swap, size: 16, color: AppColors.primary),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(bound ? '切换身份' : '绑定打手账号',
                                  style: const TextStyle(
                                      fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                              const SizedBox(height: 2),
                              Text(sub,
                                  style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4)),
                            ],
                          ),
                        ),
                        // ID-D：行尾「当前身份：老板」标签（可见标签，不只靠正文文字）
                        const AppIdentityTag(AppIdentityTag.bossLabel),
                        const SizedBox(width: 6),
                        AppIcon.of(AppIdentityIcons.chevron, size: 16, color: AppColors.textPlaceholder),
                      ],
                    ),
                  ),
                ),
                if (bound) ...[
                  const AppHairline(),
                  _row('解除绑定', AppIdentityIcons.linkOff, _unbindIdentity),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // =====================================================================================
  // ⑤ 服务宫格 3×2（图标 17dp + **语义色**：同功能同色，取自 feature_hues）
  // =====================================================================================

  Widget _buildServiceCard(BuildContext context) {
    final rows = _serviceRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分区标题只有「服务」两个字：右侧那句「5 项，每一项一句话说明」是**注释型小字**，
        // 负责人 2026-10-17 明确点名要删（`AppSectionHeader.subtitle` 传 null）。
        const AppSectionHeader(
          title: '服务',
          padding: EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, 8),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: _gCard(
            child: Column(
              children: [
                // 3 列 × 2 行宫格：第一行 3 项，第二行 2 项（末格留空，不硬凑第 6 个入口）
                _serviceGridRow(context, rows, 0),
                const AppHairline(),
                _serviceGridRow(context, rows, 3),
              ],
            ),
          ),
        ),
              _appearanceSection(),
      ],
    );
  }

  /// 宫格的一行（3 列；不足 3 项时用等宽空位补齐，保证每列宽度一致）
  Widget _serviceGridRow(BuildContext context, List<_ServiceRow> rows, int start) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          for (var col = 0; col < 3; col++)
            Expanded(
              child: start + col < rows.length
                  ? _serviceCell(context, rows[start + col])
                  : const SizedBox(height: 1),
            ),
        ],
      ),
    );
  }

  /// 服务宫格单元：图标（17dp，**按功能区上色**）+ 标题
  ///
  /// 上色口径：`featureOfIcon(row.icon)` → `featureHue()`（实色）/ `featureSoft()`（浅底）。
  /// 这样「客服=青 / 安全=绿 / 活动=粉 / 品牌=蓝」与底栏、订单四宫格、服务页**同一映射**，
  /// 不在这里另取色（同功能必须与别处同色）。
  ///
  /// 【2026-10-17 ⑦】**每格的"一句话说明"整类删掉**（含原先唯一被测试钉死的那句：
  /// 「好友申请与账号提醒」已按负责人裁决一并删除，测试改为按入口图标定位），
  /// 格里只剩「图标 + 名称」—— 名称是入口文案，不是注释。
  Widget _serviceCell(BuildContext context, _ServiceRow row) {
    final feature = featureOfIcon(row.icon);
    return InkWell(
      onTap: () => row.onTap(context),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: featureSoft(feature),
                borderRadius: BorderRadius.circular(10),
              ),
              child: AppIcon.of(row.icon, size: 17, color: featureHue(feature)),
            ),
            const SizedBox(height: 6),
            Text(row.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  /// 服务宫格的 5 项（**顺序即渲染顺序**；「我的余额」不在此列 —— 余额入口只有余额卡一处）
  ///
  /// `NotificationPage` 的入口说明（口径不变）：它此前**唯一**入口是服务页顶部「公告」，
  /// 而那个入口本身是错的（点进去是通知页、真公告看不到）。「公告」修正为真公告列表后，
  /// 系统通知必须另给入口，否则功能**彻底失去可达性**。全 App 仅此一处入口（规则 1）。
  ///
  /// 【2026-10-17 ⑦ · 删注释型小字】每格的「一句话说明」**全部删除**（'平均 5 分钟回复'、
  /// '修改密码、登录保护'、'通知、隐私与清理缓存'、'版本、协议与反馈'、'好友申请与账号提醒'）。
  /// 入口靠**标题 + 语义色图标**识别，不再靠副标解释。
  List<_ServiceRow> get _serviceRows => [
        _ServiceRow(
          '系统通知',
          AppIcon.bell,
          (context) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationPage())),
        ),
        _ServiceRow('联系客服', AppIcon.headset, (context) => _openCsChat(context)),
        _ServiceRow(
          '账号安全',
          AppIcon.lock,
          (context) => Navigator.of(context).push<void>(AppMotionRoute<void>(builder: (_) => const SecurityPage())),
        ),
        _ServiceRow(
          '设置',
          AppIcon.settings,
          (context) => Navigator.of(context).push<void>(AppMotionRoute<void>(builder: (_) => const SettingsPage())),
        ),
        _ServiceRow(
          '关于祁连山电竞',
          AppIcon.info,
          (context) => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AboutPrivacyPage(kind: 'about'))),
        ),
      ];

  /// 身份卡行（图标 + 标题 + 右箭头）—— 图标 16dp，与服务宫格的 17dp 区分开
  ///
  /// 二级文案（`sub`）已按负责人 2026-10-17 要求删除：那行「本机忘记这个打手账号，
  /// 不影响工作端 App」属于对功能的解释，不是数据标签。
  /// 「外观」段（负责人 2026-10-18：液态玻璃底栏，用户可自主开关）
  ///
  /// 为什么做成开关而不是直接改默认：液态玻璃每帧对背后区域做折射采样，
  /// 低端机上是真实代价；且项目历史上 `liquid_glass_widgets` 曾因真机着色器
  /// 问题整体停用（CLAUDE.md 有记录）。所以"要不要"交给用户。
  Widget _appearanceSection() {
    final on = NavStyleController.instance.glass;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(
          title: '外观',
          padding: EdgeInsets.fromLTRB(AppSpacing.page, 20, AppSpacing.page, 8),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: _gCard(
            child: InkWell(
              onTap: () => NavStyleController.instance.setGlass(!on),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppColors.statusMutedSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: AppIcon.of(
                        AppIdentityIcons.visibility,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '液态玻璃底栏',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            on ? '底部导航悬浮，实时折射背后内容' : '关闭中：底部导航实色贴底',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: on,
                      onChanged: (v) => NavStyleController.instance.setGlass(v),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(String title, IconData icon, VoidCallback onTap) => InkWell(
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
                  color: AppColors.statusMutedSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: AppIcon.of(icon, size: 16, color: AppColors.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              ),
              AppIcon.of(AppIcon.chevronRight, size: 16, color: AppColors.textPlaceholder),
            ],
          ),
        ),
      );

  // =====================================================================================
  // 身份弹层 / 解除绑定 / 会员进度
  // =====================================================================================

  /// 打开「切换身份」弹层（绑定 / 免密切换 / 解绑的唯一入口；管理员态也在这里进）
  Future<void> _openIdentitySheet() async {
    await IdentitySwitchSheet.show(
      context,
      onSwitched: (identity) {
        // 切到打手态/管理员态由 HomeShell 的身份分支接管（本页会被卸载），
        // 这里只给一次过渡提示（TR-A；方案②新增管理员文案）
        if (!mounted) return;
        AppToast.success(
          context,
          identity == AppIdentity.admin ? IdentityTransition.toAdmin : IdentityTransition.toWorker,
        );
      },
    );
    if (mounted) {
      unawaited(AuthStore.instance.fetchIdentityStatus().catchError((_) => IdentityBindingStatus.empty));
    }
  }

  /// 解除绑定（**二次确认**在弹层里；解绑后身份必定回到老板态）
  Future<void> _unbindIdentity() async {
    final ok = await IdentityUnbindSheet.show(context, worker: AuthStore.instance.identityStatus?.worker);
    if (!ok || !mounted) return;
    unawaited(AuthStore.instance.fetchIdentityStatus().catchError((_) => IdentityBindingStatus.empty));
  }

  /// 会员进度（与 LevelSummaryCard 同算法：累计消费 / 下一级阈值；满级为 1）
  double _levelProgress(AuthMe me) {
    final next = nextLevelSpentOf(me.level);
    return next == null ? 1.0 : (me.totalSpent / next).clamp(0.0, 1.0);
  }

  /// 会员进度文案（真实规则，不用假数据）
  String _levelHint(AuthMe me) {
    final next = nextLevelSpentOf(me.level);
    if (next == null) return '已达最高等级 · 累计消费 ${fmtMoney(me.totalSpent)}';
    return '距下一级还差 ${fmtMoney((next - me.totalSpent).clamp(0, next))}';
  }

  /// 联系客服：获取（自动创建）客服会话 → 进入聊天详情（WS 实时，docs/07）
  Future<void> _openCsChat(BuildContext context) async {
    try {
      final resp = await _api.request('GET', '/user/conversation', token: AuthStore.instance.accessToken,
          );
      final convId = '${resp['data']?['id'] ?? ''}';
      if (context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatDetailPage(
              conversationId: convId,
              title: '联系客服',
              csConversation: true,
              peerNickname: '祁连山客服',
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      if (context.mounted) {
        AppToast.error(context, e.message); // 通用失败：品牌浮层（替代系统默认黑色 SnackBar）
      }
    }
  }
}

/// 服务宫格一项的事实（标题 / 图标 / 动作）
///
/// 【2026-10-17 ⑦】`sub`（一句话说明）整类删除 —— 负责人：「所有那种注释型的浅色小字不要有」。
class _ServiceRow {
  _ServiceRow(this.title, this.icon, this.onTap);

  final String title;
  final IconData icon;
  final void Function(BuildContext context) onTap;
}

/// ① 页头（**白底实色，无品牌渐变、无通知/设置图标**）
///
/// 页头 = 白底 + 1px 发丝线 + 19sp「我的」，与二级页 `AppPageHeader` 同形。
/// - **去掉品牌渐变主视觉**：docs/21 禁止"渐变做主视觉"；
/// - **不放「通知 / 设置」两个图标**：服务宫格里已有同名两项，页头再出现即违反
///   CLAUDE.md 结构规则 1「同一入口只出现一次」。
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('profile-header'),
      color: T.bgCardSolid,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 13, AppSpacing.page, 14),
              child: Row(
                children: [
                  Text('我的',
                      style: TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800, color: T.textPrimary, letterSpacing: 0.2)),
                ],
              ),
            ),
            Container(height: 1, color: T.divider),
          ],
        ),
      ),
    );
  }
}

/// 整页骨架（会话未就绪时；**静态灰块，不做 shimmer 动画**）
class _ProfileSkeletonPage extends StatelessWidget {
  const _ProfileSkeletonPage();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('profile-page-skeleton'),
      children: [
        const _ProfileHeader(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 14, bottom: 28),
            children: const [
              _SkeletonProfileCard(),
              SizedBox(height: _ProfilePageState._cardGap),
              _SkeletonAssetCard(),
            ],
          ),
        ),
      ],
    );
  }
}

class _SkeletonProfileCard extends StatelessWidget {
  const _SkeletonProfileCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.strokeSoft),
        ),
        child: const Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Row(
                children: [
                  _SkeletonBox(width: 52, height: 52, radius: 26),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SkeletonBox(width: 108, height: 16, radius: 5),
                        SizedBox(height: 9),
                        _SkeletonBox(width: 78, height: 16, radius: 4),
                        SizedBox(height: 9),
                        _SkeletonBox(width: 120, height: 11),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            AppHairline(),
            Padding(padding: EdgeInsets.fromLTRB(14, 14, 14, 16), child: _SkeletonBox(height: 40, radius: 6)),
          ],
        ),
      ),
    );
  }
}

class _SkeletonAssetCard extends StatelessWidget {
  const _SkeletonAssetCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 16),
        decoration: BoxDecoration(
          color: AppColors.brandInk,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const _AssetSkeleton(onDark: true),
      ),
    );
  }
}

/// 资产卡骨架（形状与真实内容一致：大数值 + 一行小字 + 一行说明）
///
/// **刻意不做 shimmer 动画**：动画会让 `pumpAndSettle` 永不收敛（既有大量出图/交互测试用它），
/// 而"灰块占位"本身已达成"加载时不空白"的目的；也不引入 `shimmer` 新依赖。
///
/// `key` 供结构测试断言"加载态确实是骨架而不是空白"（见 `test/profile_redesign_test.dart`）。
class _AssetSkeleton extends StatelessWidget {
  const _AssetSkeleton({super.key, this.onDark = false});

  /// 深墨蓝卡上用半透明白块（灰块在深色底上会"发光"）
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final tint = onDark ? Colors.white.withValues(alpha: .16) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SkeletonBox(width: 136, height: 26, radius: 6, color: tint),
        const SizedBox(height: 11),
        _SkeletonBox(width: 92, height: 11, color: tint),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: _SkeletonBox(height: 30, radius: 5, color: tint)),
            const SizedBox(width: 12),
            Expanded(child: _SkeletonBox(height: 30, radius: 5, color: tint)),
            const SizedBox(width: 12),
            Expanded(child: _SkeletonBox(height: 30, radius: 5, color: tint)),
          ],
        ),
      ],
    );
  }
}

/// 骨架灰块（默认复用发丝线灰 token `T.divider`；深色卡传半透明白，不硬编码新色值）
class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({this.width, required this.height, this.radius = 4, this.color});

  final double? width;
  final double height;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color ?? T.divider,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}

/// 视频背景播放器（2026-10-21「实况背景」）
///
/// ## 为什么需要它
/// 负责人要"实况"背景。Android 的动态照片是 **JPEG + 内嵌 mp4**，外壳只有封面帧；
/// `Image.network` 对它无能为力。要真动，素材必须是 mp4 → 用 `video_player` 循环播放。
///
/// ## 三条硬约束
/// 1. **静音**：这是背景，不是视频播放器。出声会被当成 bug。
/// 2. **循环**：背景不能播完就黑。
/// 3. **失败不崩**：加载失败/编码不支持 → 整块退化成透明，页面其余部分照常可用
///    （背景是纯装饰，不该有让页面白屏的能力）。
///
/// 控制器在 `initState` 里异步初始化，`dispose` 里释放 —— 切页/销毁必须停，
/// 否则退到后台还在解码，白烧电。
class _CoverVideo extends StatefulWidget {
  const _CoverVideo({required this.mediaId});

  final String mediaId;

  @override
  State<_CoverVideo> createState() => _CoverVideoState();
}

class _CoverVideoState extends State<_CoverVideo> {
  VideoPlayerController? _c;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final url = AppConfig.resolveMediaUrl('/media/public/${widget.mediaId}');
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(0);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (_) {
      await c.dispose();
      // 静默失败：背景层不该有能力搞坏整页
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    final size = c.value.size;
    if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
    // FittedBox + cover：铺满容器同时保持比例（与 Image.network 的 BoxFit.cover 同语义）
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
