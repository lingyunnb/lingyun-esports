import 'package:flutter/material.dart';

import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_motion.dart';

/// 打手态**身份细带**（合并双端 · 身份切换；A+ 稿 §13.3 ID-A / ID-B）
///
/// > 打手态**所有屏**页头正下方一条**克制的身份标识**，与标题不抢位
///
/// ## 取值（照 A+ 清单 ID-A / ID-B 逐项落地）
/// - 高度 **28dp**、**通栏**（左右不缩进）、**无圆角（0）**、**无阴影、无渐变**
/// - 底色 `AppColors.primarySoft`（`#E8EEF7`）；底边 **1px** 发丝线 `AppColors.divider`（`#E3E8EF`）
/// - 左段：「当前身份」**10.5sp w600** → 盾牌图标 **13dp** → 「打手 · 工号 W20260118」
///   **11.5sp w700**；三段均用 `AppColors.primary`，组内间距 **6dp**
/// - 右段：「切回老板」**11.5sp w700** + **12dp** 右箭头；`InkWell` 热区**整条带高 28dp**、
///   左右各扩展 **8dp** 内边距（保证 ≥44dp 宽的可点区域）
/// - 左右内边距 **16dp**（= 页面 `--pad`）；`Expanded` 占位使身份串**不被压成省略号**（工号必须完整可见）
/// - 动效（TR-B）：出现/消失 **180ms** 淡入 + 高度 0→28 的 `SizeTransition`，曲线 `Motion.emphasized`
///
/// ## 位置（负责人裁决，覆盖 A+3 原稿）
/// 放在**页头正下方**、滚动内容之上，不随内容滚动，顶边距 0。
/// A+3 的 HTML 与核验器把它画在状态栏正下方（`idBarTop ∈ [44,54]`），但清单 ID-A 与负责人裁决
/// 都是"页头之下"——理由是贴在状态栏下会像系统 SIM 卡条、且与页面标题脱节。
///
/// ## 为什么右侧是「切回老板」而不是「切换」
/// 「切换」会被理解成"打开弹层选身份"；这里的动作是**直接切回、立刻生效**，措辞必须明确。
/// 它也**不是**"另一个身份"的并列声明（那会把「老板」带进打手态并挤占底栏语义），
/// 而是"离开当前形态"的唯一固定出口。
///
/// ## 管理员态（负责人 2026-10-06 方案②）复用同一条细带
/// 传 [label] = [adminLabel]，左侧三段的排版/字号/颜色/高度**一字不改**，
/// 只把身份串从「打手 · 工号 W…」换成「充值审核」——于是管理员态的每一屏顶部都写着
/// 「当前身份 · 充值审核」，右侧仍是同一个「切回老板」出口（快照测试逐屏断言这一点）。
class AppIdentityBar extends StatefulWidget {
  const AppIdentityBar({
    super.key,
    this.workerNo = '',
    this.nickname = '',
    this.onSwitchBack,
    this.switchLabel = '切回老板',
    this.label,
    this.onIdentityTap,
  });

  /// 工号（`W20260118`）；为空时退化为昵称，绝不显示空白条
  final String workerNo;
  final String nickname;

  /// 右侧「切回老板」点击（直接切回，不是打开弹层）
  final VoidCallback? onSwitchBack;
  final String switchLabel;

  /// **身份串覆盖**（负责人 2026-10-06 方案②）：管理员态传 [adminLabel]「充值审核」，
  /// 渲染成「当前身份 · 充值审核」。为 null 时走打手态原来的 [labelOf]（打手 · 工号 W…），
  /// 因此打手态的三屏**逐像素不变**。
  final String? label;

  /// 点细带主体（左/中段）的点击：**打开同一个「切换身份」弹层**（负责人 2026-10-06 截图反馈）
  ///
  /// 为什么做成"点细带"而不是再加一枚可见按钮：细带只有 28dp，再加控件会破坏它的极简
  /// （A+ 清单 ID-A 的定位就是"一条克制的身份标识"）。点主体 = 零新增像素、零新增文案，
  /// 却把"打手态/管理员态 → 另一个身份"从"先切回老板态再进弹层"缩成**一次点击**。
  /// 右侧「切回老板」保留自己的热区（[onSwitchBack]），它的点击**不会**被主体吞掉。
  final VoidCallback? onIdentityTap;

  /// **宿主注入的细带点击默认行为**（老板端 App 启动时设为"打开「切换身份」弹层"）
  ///
  /// 用静态注册而不是让本文件直接 import 弹层：那会造成 `identity_widgets` ←→
  /// `identity_switch_sheet` 的**循环 import**。注册式没有这个环，而且**未注册时细带不可点**
  /// —— 这样既有的打手态/管理员态测试（不注册）行为逐字不变。
  static VoidCallback? onBandTap;

  /// A+ 清单硬参数（测试、页面与出图共用同一份数字）
  static const double height = 28;

  /// 左侧小标签（只读事实：你现在是谁）
  static const String leadLabel = '当前身份';
  static const Color background = AppColors.primarySoft;
  static const Color border = AppColors.divider;

  /// 左侧小标签 10.5sp w600 / 身份串 11.5sp w700 / 右侧动作 11.5sp w700
  static const double leadSize = 10.5;
  static const double labelSize = 11.5;

  /// 组内间距 6dp（标签 → 图标 → 身份串）
  static const double gap = 6;
  static const double iconSize = 13;

  /// 出现/消失动效（TR-B：180ms + `Motion.emphasized`）
  static const Duration enterDuration = Duration(milliseconds: 180);

  /// 细带主体热区的 key（测试/出图定位"点细带打开身份弹层"用）
  static const Key bandTapKey = Key('identity-band-tap');

  /// 管理员态（充值审核）的身份串：细带最终渲染成「当前身份 · 充值审核」
  static const String adminLabel = '充值审核';

  /// 管理员态细带上显示的**审核员名字**（页头事实行用，细带本身不显示名字）
  static String adminFactLine({required String name, required int pending}) {
    final who = name.isEmpty ? '充值审核' : name;
    return '$who · 待审核 $pending 笔';
  }

  /// 标识文案：`打手 · 工号 W20260118`
  static String labelOf({required String workerNo, String nickname = ''}) {
    if (workerNo.isNotEmpty) return '打手 · 工号 $workerNo';
    if (nickname.isNotEmpty) return '打手 · $nickname';
    return '打手';
  }

  @override
  State<AppIdentityBar> createState() => _AppIdentityBarState();
}

class _AppIdentityBarState extends State<AppIdentityBar> with SingleTickerProviderStateMixin {
  /// 0 = 不存在（高度 0 / 全透明）；1 = 完全出现
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppIdentityBar.enterDuration,
    value: 0,
  );

  @override
  void initState() {
    super.initState();
    // 只在挂载时播一次（页面内 tab 切换不重播 —— A+ 清单 TR-B 明确要求）
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Motion.emphasized);
    // 主体热区：显式写的 onIdentityTap 优先，其次宿主注册的默认行为（未注册 → 不可点，
    // 因此既有的打手态/管理员态快照与"细带只读"的测试行为逐字不变）
    final bandTap = widget.onIdentityTap ?? AppIdentityBar.onBandTap;
    final content = Row(
      children: [
        const Text(
          AppIdentityBar.leadLabel,
          style: TextStyle(
            fontSize: AppIdentityBar.leadSize,
            fontWeight: FontWeight.w600,
            color: AppColors.primary,
            height: 1.2,
          ),
        ),
        const SizedBox(width: AppIdentityBar.gap),
        const AppIcon.of(AppIdentityIcons.badge, size: AppIdentityBar.iconSize, color: AppColors.primary),
        const SizedBox(width: AppIdentityBar.gap),
        Expanded(
          child: Text(
            widget.label ?? AppIdentityBar.labelOf(workerNo: widget.workerNo, nickname: widget.nickname),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: AppIdentityBar.labelSize,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
              height: 1.2,
            ),
          ),
        ),
        if (widget.onSwitchBack != null)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSwitchBack,
            child: Padding(
              // 左右各 8dp：热区 ≥44dp 宽，且高度撑满整条带（28dp）
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                height: AppIdentityBar.height,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.switchLabel,
                      style: const TextStyle(
                        fontSize: AppIdentityBar.labelSize,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                        height: 1.2,
                      ),
                    ),
                    const AppIcon.of(AppIdentityIcons.chevron, size: 12, color: AppColors.primary),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
    return SizeTransition(
      sizeFactor: curved,
      // 从顶边展开（等价于旧 `axisAlignment: -1`，改用新 API 以免 deprecated 告警）
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: curved,
        child: Container(
          height: AppIdentityBar.height,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          decoration: const BoxDecoration(
            color: AppIdentityBar.background,
            border: Border(bottom: BorderSide(color: AppIdentityBar.border)),
          ),
          // 整条主体可点（右侧「切回老板」自带热区，会先吃掉落在它自己范围内的点击）
          child: bandTap == null
              ? content
              : GestureDetector(
                  key: AppIdentityBar.bandTapKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: bandTap,
                  child: content,
                ),
        ),
      ),
    );
  }
}

/// 中性**身份标签**（老板态「当前身份：老板」，A+ 稿 §13.3 ID-D / ID-E）
///
/// 取值：**高 17dp / 圆角 4 / 10.5sp w700 / `textSecondary` 字 / 底 `#F1F5F9` / 1px 描边 `#CFD8E6`**；
/// 只读、不可点（切换入口只有「我的 › 身份 › 切换身份」一处）。
/// 文案固定为「当前身份：老板」（含中文全角冒号，客户端不改半角、不加空格）。
///
/// 出现两处（同一枚标签）：**资料头昵称行**（会员标签右侧，间距 7dp）+ **身份分组行右侧**。
class AppIdentityTag extends StatelessWidget {
  const AppIdentityTag(this.text, {super.key});

  final String text;

  /// 老板态固定文案（核验器 `APLUS_IDENTITY.bossNeed` 断言这一串）
  static const String bossLabel = '当前身份：老板';

  static const double height = 17;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.tagNeutralBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.tagNeutralBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: T.textSecondary,
          height: 1.2,
        ),
      ),
    );
  }
}


/// 身份相关的图标（走 Flutter 内置 Material outlined，禁用拟物/emoji；docs/20 结论）
class AppIdentityIcons {
  AppIdentityIcons._();

  /// 打手身份（盾牌）
  static const IconData badge = AppIconsLegacy.verified_user_outlined;

  /// 老板身份
  static const IconData boss = AppIconsLegacy.person_outline_rounded;

  /// 切换身份（左右箭头，与设计稿 A1「切换身份」行一致）
  static const IconData swap = AppIconsLegacy.swap_horiz_rounded;
  static const IconData chevron = AppIconsLegacy.chevron_right_rounded;
  static const IconData close = AppIconsLegacy.close_rounded;
  static const IconData refresh = AppIconsLegacy.refresh_rounded;
  static const IconData visibility = AppIconsLegacy.visibility_outlined;
  static const IconData visibilityOff = AppIconsLegacy.visibility_off_outlined;
  static const IconData warning = AppIconsLegacy.warning_amber_rounded;
  static const IconData info = AppIconsLegacy.info_outline_rounded;
  static const IconData check = AppIconsLegacy.check_circle_outline_rounded;
  static const IconData linkOff = AppIconsLegacy.link_off_rounded;
  static const IconData bolt = AppIconsLegacy.bolt_rounded;
  static const IconData wallet = AppIconsLegacy.account_balance_wallet_outlined;
  static const IconData receipt = AppIconsLegacy.receipt_long_outlined;
  static const IconData headset = AppIconsLegacy.headset_mic_outlined;
  static const IconData clock = AppIconsLegacy.schedule_rounded;
  static const IconData empty = AppIconsLegacy.inbox_outlined;
  static const IconData bell = AppIconsLegacy.notifications_none_rounded;

  /// 编辑（打手态「个人介绍」卡片的编辑入口，2026-10-17 打手自写简介）
  static const IconData edit = AppIconsLegacy.edit_outlined;
}

/// 提示条（设计稿 `.banner`：发丝线描边、无阴影、四种语气）
///
/// 用法分工（与设计稿 §6 文案原则一致）：
/// - [AppIdentityBanner.error]：真错误（账密错、被停用、被顶下线）
/// - [AppIdentityBanner.warn]：「需要你注意但没坏」（无权限、单设备冲突事前告知）
/// - [AppIdentityBanner.info]：中性告知（不影响什么）
/// - [AppIdentityBanner.ok]：成功
class AppIdentityBanner extends StatelessWidget {
  const AppIdentityBanner._({
    required this.tone,
    required this.title,
    this.detail,
  });

  factory AppIdentityBanner.error({required String title, String? detail}) =>
      AppIdentityBanner._(tone: _BannerTone.error, title: title, detail: detail);

  factory AppIdentityBanner.warn({required String title, String? detail}) =>
      AppIdentityBanner._(tone: _BannerTone.warn, title: title, detail: detail);

  factory AppIdentityBanner.info({required String title, String? detail}) =>
      AppIdentityBanner._(tone: _BannerTone.info, title: title, detail: detail);

  factory AppIdentityBanner.ok({required String title, String? detail}) =>
      AppIdentityBanner._(tone: _BannerTone.ok, title: title, detail: detail);

  final _BannerTone tone;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = tone;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: AppIcon.of(c.icon, size: 15, color: c.foreground),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.foreground, height: 1.45),
                ),
                if (detail != null && detail!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    detail!,
                    style: TextStyle(fontSize: 11.5, color: c.detailColor, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 身份页提示条配色（四档）
///
/// **2026-10-16 方案 F：四档全部收敛到 token** —— 原先这里刻意保留字面量，理由是
/// "`AppColors.xSoft` 只覆盖主色/金/青三档，提示条需要 error/warn 两档的浅底，
/// token 里没有对应值，硬套会得到'红字配青底'的语义错配"。
/// 本轮已补齐 `AppColors.banner*`（浅底 / 描边 / 深浅两级同色字），
/// 于是提示条不再有"体系外的颜色"，四档各自的 `foreground` 仍是既有语义 token。
enum _BannerTone {
  error(
    background: AppColors.bannerDangerBg,
    border: AppColors.bannerDangerBorder,
    foreground: AppColors.error,
    detailColor: AppColors.bannerDangerInk,
    icon: AppIdentityIcons.warning,
  ),
  warn(
    background: AppColors.bannerWarnBg,
    border: AppColors.bannerWarnBorder,
    foreground: AppColors.warning,
    detailColor: AppColors.bannerWarnInk,
    icon: AppIdentityIcons.info,
  ),
  info(
    background: AppColors.ice,
    border: AppColors.bannerInfoBorder,
    foreground: AppColors.primary,
    detailColor: AppColors.bannerInfoInk,
    icon: AppIdentityIcons.info,
  ),
  ok(
    background: AppColors.bannerOkBg,
    border: AppColors.bannerOkBorder,
    foreground: AppColors.bannerOkInk,
    detailColor: AppColors.bannerOkDetail,
    icon: AppIdentityIcons.check,
  );

  const _BannerTone({
    required this.background,
    required this.border,
    required this.foreground,
    required this.detailColor,
    required this.icon,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final Color detailColor;
  final IconData icon;
}

/// 打手态页面通用页头（A+ 稿 §13.3：页头 + 细带 = 一个紧凑头部块）
///
/// 取值：内边距 `6 / 16 / 12`、标题 17dp w700、右侧图标按钮 30 x 30 r6 发丝线描边；
/// **[banner] 槽**用于挂身份细带 —— 它**渲染在白色页头容器之外**（页头保留自己的白底与下边发丝线，
/// 细带自己带 `primarySoft` 底与下边发丝线），因此两者是"白块 + 冰蓝条"两层，不会互相吃掉描边。
class IdentityWorkerPageHeader extends StatelessWidget {
  const IdentityWorkerPageHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.fact,
    this.bottom,
    this.banner,
  });

  final String title;
  final List<Widget> actions;

  /// 标题下的事实行（如「可接单打手 3 名 | 当前待接 6 单」）
  final Widget? fact;

  /// 事实行下的额外内容（如公告行）
  final Widget? bottom;

  /// 页头正下方的常驻条（打手态身份细带 `AppIdentityBar`）
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final header = Container(
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
                Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
                const Spacer(),
                ...actions,
              ],
            ),
          ),
          if (fact != null) ...[const SizedBox(height: 9), fact!],
          if (bottom != null) ...[const SizedBox(height: 10), bottom!],
        ],
      ),
    );
    if (banner == null) return header;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [header, banner!],
    );
  }
}

/// 页头右侧的方形图标按钮（设计稿 `.icbtn` 30 x 30 r6）
class IdentityWorkerHeaderButton extends StatelessWidget {
  const IdentityWorkerHeaderButton({super.key, required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.divider),
        ),
        child: AppIcon.of(icon, size: 16, color: T.textSecondary),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// 打手态空态（设计稿 `.empty` / A+ 清单 MSG-B：顶部内边距 64dp、左右 30dp）
///
/// 图标 44×44 圆角 14 白底 + 发丝线 + `textTertiary` 图标 21dp；
/// 标题 13.5sp w600 `textSecondary`；说明 11.5sp `mutedText` 行高 1.55。
class IdentityWorkerEmptyState extends StatelessWidget {
  const IdentityWorkerEmptyState({
    super.key,
    required this.title,
    this.detail,
    this.icon = AppIdentityIcons.empty,
    this.action,
    this.onAction,
    this.topPadding = 64,
  });

  final String title;
  final String? detail;
  final IconData icon;
  final String? action;
  final VoidCallback? onAction;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(30, topPadding, 30, 0),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: T.bgCardSolid,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: T.divider),
            ),
            child: AppIcon.of(icon, size: 21, color: T.textTertiary),
          ),
          const SizedBox(height: 10),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textSecondary)),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.55),
            ),
          ],
          if (action != null && onAction != null) ...[
            const SizedBox(height: 14),
            AppIdentityOutlineButton(label: action!, onTap: onAction!),
          ],
        ],
      ),
    );
  }
}

/// 次按钮（设计稿 `.btn-ghost`：白底 + 发丝线 + 主色字）
class AppIdentityOutlineButton extends StatelessWidget {
  const AppIdentityOutlineButton({
    super.key,
    required this.label,
    required this.onTap,
    this.height = 36,
    this.color,
    this.expand = false,
  });

  final String label;
  final VoidCallback onTap;
  final double height;
  final Color? color;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = color ?? T.primary;
    final btn = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: T.divider),
        ),
        child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c)),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// 主按钮（设计稿 `.btn-primary`：实色主色、白字、高 44 r10）
///
/// 故意**不用渐变**：docs/21 禁"渐变做主视觉"，此处面积大且是主行动。
class AppIdentityPrimaryButton extends StatelessWidget {
  const AppIdentityPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.height = 44,
    this.color,
    this.busy = false,
    this.icon,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final double height;
  final Color? color;
  final bool busy;
  final IconData? icon;

  /// true = 撑满可用宽度（弹层按钮区/整行动作）；
  /// false = 按内容宽度（列表行内的「抢单」「确认接单」这类，放进 Row 时必须用 false，
  /// 否则 `width: infinity` 在 Row 的非弹性子节点上会直接抛布局断言）。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final bg = enabled ? (color ?? T.primary) : AppColors.disabledBg;
    final fg = enabled ? Colors.white : T.textTertiary;
    final body = Container(
      height: height,
      padding: expand ? null : const EdgeInsets.symmetric(horizontal: 15),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
          else if (icon != null)
            AppIcon.of(icon, size: 16, color: fg),
          if (busy || icon != null) const SizedBox(width: 7),
          Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: fg)),
        ],
      ),
    );
    final material = Material(
      color: bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onPressed : null,
        child: body,
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: material) : material;
  }
}

/// 切换身份的**过渡提示文案**（A+ 清单 TR-A）
///
/// **形式是顶部 Toast，不是通栏细带**（负责人裁决：`AppToast.info`，2000ms 自动消失）。
/// 这里只集中放文案常量，避免三处各写一遍：
/// - 切到打手：「已切换到打手身份」
/// - 切回老板：「已切换到老板身份」
/// - 解绑：「已解绑打手账号，已回到老板身份」
class IdentityTransition {
  IdentityTransition._();

  static const String toWorker = '已切换到打手身份';
  static const String toBoss = '已切换到老板身份';
  static const String unbound = '已解绑打手账号，已回到老板身份';

  /// 切到管理员态（充值审核）：说清"你现在只能做审核这三件事"，不是"你成了管理员"这种含糊说法
  static const String toAdmin = '已切换到充值审核身份 · 只有审核这一件事';
}

