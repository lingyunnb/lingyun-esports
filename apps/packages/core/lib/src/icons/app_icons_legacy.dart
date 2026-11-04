// 需要 `package:flutter/material.dart`（`Icons` 定义在 material 里，widgets 不含它）
import 'package:flutter/material.dart';

import 'app_icons.dart';

/// ⚠️ **本文件是全仓唯一允许出现 `Icons.`（Material）字面量的业务文件之一**
/// —— 它就是「旧图标 → 新体系」的**映射表本体**（另一处是同目录的 `app_icon.dart`
/// 里那 70 条**旧包装器语义别名**，见该文件顶部说明）。
///
/// ## 为什么需要它（方案 F 图标迁移的收口层）
///
/// 迁移前全仓有两套图标调用：
/// - 旧包装器：`Icon(AppIcon.info, size: 18, color: c)` —— `AppIcon.info` 是 `IconData`；
/// - 直接 Material：`Icon(Icons.info_outline_rounded, size: 18, color: c)`。
///
/// 新体系（`AppIcons` 枚举 + `AppIconPainter` 自绘）是**枚举**，与 `IconData` 类型不相通，
/// 所以「把 152 个调用点逐个改名」既慢又容易改错。
///
/// 收口做法（2026-10-16）：
/// 1. 旧名**一个不改**，全部在本表里保留（`AppIconsLegacy.search_rounded` 仍是 `IconData`）；
/// 2. 调用点只做**两处机械替换**（全仓统一，不做逐名决策）：
///    `Icons.` → `AppIconsLegacy.`、`Icon(AppIcon.` → `AppIcon.of(AppIcon.`；
/// 3. 渲染时 [AppIcon.of] 用本表的 [kLegacyIconMap] 把 `IconData` 解析成 `AppIcons`，
///    画**新图标几何**；同时镜像一枚不可见 `Icon` 保留旧 `IconData`
///    （于是 `find.byIcon(AppIcon.x)` / `find.byType(Icon)` 计数 / `getRect` 全部照旧可用）。
///
/// **映射不到的绝不静默变空白**：见 [resolveLegacyIconOr] 与 [kMaterialRetained]。
///
/// ## 与 `app_icon.dart` 里那 70 条别名的关系
/// 两处都是「旧名 → 旧 Material 值」，语义别名放 `AppIcon`（测试写 `AppIcon.check`），
/// 带下划线的原始 Material 名放本类（迁移期机械替换的落点）。二者**值域不重叠命名**，
/// 因此 `Icons.` → `AppIconsLegacy.` 的替换永远不会撞上 `AppIcon.` 的成员（反之亦然）。
class AppIconsLegacy {
  AppIconsLegacy._();

  // ============ 原始 Material 名（迁移期由 `Icons.` → `AppIconsLegacy.` 机械替换而来）============
  //
  // 只有全仓**实际用到**的名字才在这里登记（grep 统计去重，不猜、不铺开）。
  // 值必须与替换前的 `Icons.同名` **逐值相同** —— 这是「镜像 Icon 仍能被旧 finder 命中」的前提。

  // ---- 账户 / 身份 ----
  static const IconData account_balance_wallet_outlined = Icons.account_balance_wallet_outlined;
  static const IconData person_outline_rounded = Icons.person_outline_rounded;
  static const IconData person_rounded = Icons.person_rounded;
  static const IconData person_add_alt = Icons.person_add_alt;
  static const IconData person_remove_outlined = Icons.person_remove_outlined;
  static const IconData people_outline_rounded = Icons.people_outline_rounded;
  static const IconData badge_outlined = Icons.badge_outlined;
  static const IconData verified_outlined = Icons.verified_outlined;
  static const IconData verified_user_outlined = Icons.verified_user_outlined;
  static const IconData swap_horiz_rounded = Icons.swap_horiz_rounded;
  static const IconData logout_rounded = Icons.logout_rounded;

  // ---- 安全 / 权限 ----
  static const IconData lock_outline_rounded = Icons.lock_outline_rounded;
  static const IconData lock_outline = Icons.lock_outline;
  static const IconData lock_reset_rounded = Icons.lock_reset_rounded;
  static const IconData lock_clock_outlined = Icons.lock_clock_outlined;
  static const IconData security_rounded = Icons.security_rounded;
  static const IconData shield_outlined = Icons.shield_outlined;
  static const IconData vpn_key_outlined = Icons.vpn_key_outlined;
  static const IconData visibility = Icons.visibility;
  static const IconData visibility_outlined = Icons.visibility_outlined;
  static const IconData visibility_off_outlined = Icons.visibility_off_outlined;
  static const IconData block = Icons.block;
  static const IconData block_rounded = Icons.block_rounded;
  static const IconData link_off_rounded = Icons.link_off_rounded;

  // ---- 订单 / 资金 ----
  static const IconData receipt_long_outlined = Icons.receipt_long_outlined;
  static const IconData receipt_long_rounded = Icons.receipt_long_rounded;
  static const IconData assignment_outlined = Icons.assignment_outlined;
  static const IconData assignment_return_outlined = Icons.assignment_return_outlined;
  static const IconData monetization_on_outlined = Icons.monetization_on_outlined;
  static const IconData account_balance_wallet = Icons.account_balance_wallet_outlined;
  static const IconData credit_card_rounded = Icons.credit_card_rounded;
  static const IconData credit_card_outlined = Icons.credit_card_outlined;
  static const IconData confirmation_number_outlined = Icons.confirmation_number_outlined;
  static const IconData card_giftcard_rounded = Icons.card_giftcard_rounded;
  static const IconData volunteer_activism_outlined = Icons.volunteer_activism_outlined;
  static const IconData local_fire_department_outlined = Icons.local_fire_department_outlined;
  static const IconData emoji_events_outlined = Icons.emoji_events_outlined;
  static const IconData emoji_events = Icons.emoji_events;
  static const IconData workspace_premium_outlined = Icons.workspace_premium_outlined;
  static const IconData workspace_premium = Icons.workspace_premium;
  static const IconData leaderboard_outlined = Icons.leaderboard_outlined;
  static const IconData show_chart_rounded = Icons.show_chart_rounded;
  static const IconData trending_up = Icons.trending_up;
  static const IconData star = Icons.star;
  static const IconData star_border = Icons.star_border;
  static const IconData star_half = Icons.star_half;
  static const IconData star_outline_rounded = Icons.star_outline_rounded;
  static const IconData star_rounded = Icons.star_rounded;

  // ---- 服务 / 客服 ----
  static const IconData support_agent_outlined = Icons.support_agent_outlined;
  static const IconData support_agent_rounded = Icons.support_agent_rounded;
  static const IconData headset_mic_outlined = Icons.headset_mic_outlined;
  static const IconData phone_outlined = Icons.phone_outlined;
  static const IconData dialpad_outlined = Icons.dialpad_outlined;
  static const IconData location_on_outlined = Icons.location_on_outlined;

  // ---- 消息 / 社交 ----
  static const IconData chat_bubble_outline = Icons.chat_bubble_outline;
  static const IconData chat_bubble_outline_rounded = Icons.chat_bubble_outline_rounded;
  static const IconData chat_bubble_rounded = Icons.chat_bubble_rounded;
  static const IconData mode_comment_outlined = Icons.mode_comment_outlined;
  static const IconData share_outlined = Icons.share_outlined;
  static const IconData mail_outline_rounded = Icons.mail_outline_rounded;
  static const IconData mark_email_read_outlined = Icons.mark_email_read_outlined;

  // ---- 时间 / 状态 ----
  static const IconData schedule_rounded = Icons.schedule_rounded;
  static const IconData schedule = Icons.schedule;
  static const IconData hourglass_empty = Icons.hourglass_empty;
  static const IconData event_available_outlined = Icons.event_available_outlined;
  static const IconData check = Icons.check;
  static const IconData check_rounded = Icons.check_rounded;
  static const IconData check_circle = Icons.check_circle;
  static const IconData check_circle_outline = Icons.check_circle_outline;
  static const IconData check_circle_outline_rounded = Icons.check_circle_outline_rounded;
  static const IconData circle_outlined = Icons.circle_outlined;
  static const IconData block_outlined = Icons.block_outlined;
  static const IconData error_outline = Icons.error_outline;
  static const IconData error_outline_rounded = Icons.error_outline_rounded;
  static const IconData report_gmailerrorred = Icons.report_gmailerrorred;
  static const IconData report_problem_outlined = Icons.report_problem_outlined;
  static const IconData warning_amber_rounded = Icons.warning_amber_rounded;
  static const IconData info_outline_rounded = Icons.info_outline_rounded;
  static const IconData help_outline = Icons.help_outline;
  static const IconData help_outline_rounded = Icons.help_outline_rounded;

  // ---- 通用导航 / 操作 ----
  static const IconData search_rounded = Icons.search_rounded;
  static const IconData close_rounded = Icons.close_rounded;
  static const IconData add_rounded = Icons.add_rounded;
  static const IconData remove_rounded = Icons.remove_rounded;
  static const IconData expand_more_rounded = Icons.expand_more_rounded;
  static const IconData more_horiz_rounded = Icons.more_horiz_rounded;
  static const IconData chevron_right = Icons.chevron_right;
  static const IconData chevron_right_rounded = Icons.chevron_right_rounded;
  static const IconData arrow_back = Icons.arrow_back;
  static const IconData arrow_back_rounded = Icons.arrow_back_rounded;
  static const IconData arrow_back_ios_new_rounded = Icons.arrow_back_ios_new_rounded;
  static const IconData arrow_forward_rounded = Icons.arrow_forward_rounded;
  static const IconData refresh_rounded = Icons.refresh_rounded;
  static const IconData tune_rounded = Icons.tune_rounded;
  static const IconData edit_outlined = Icons.edit_outlined;
  static const IconData delete_outline_rounded = Icons.delete_outline_rounded;
  static const IconData file_upload_outlined = Icons.file_upload_outlined;
  static const IconData system_update_alt = Icons.system_update_alt;
  static const IconData settings_outlined = Icons.settings_outlined;
  static const IconData palette_outlined = Icons.palette_outlined;
  static const IconData push_pin = Icons.push_pin;

  // ---- 内容 / 媒体 ----
  static const IconData image_outlined = Icons.image_outlined;
  static const IconData photo_camera_outlined = Icons.photo_camera_outlined;
  static const IconData camera_alt = Icons.camera_alt;
  static const IconData favorite_outline_rounded = Icons.favorite_outline_rounded;
  static const IconData favorite_rounded = Icons.favorite_rounded;
  static const IconData qr_code_rounded = Icons.qr_code_rounded;
  static const IconData inbox_outlined = Icons.inbox_outlined;
  static const IconData article_outlined = Icons.article_outlined;
  static const IconData category_outlined = Icons.category_outlined;
  static const IconData notifications_none_rounded = Icons.notifications_none_rounded;

  // ---- 游戏 / 系统 ----
  static const IconData sports_esports = Icons.sports_esports;
  static const IconData sports_esports_outlined = Icons.sports_esports_outlined;
  static const IconData grid_view_outlined = Icons.grid_view_outlined;
  static const IconData grid_view_rounded = Icons.grid_view_rounded;
  static const IconData cloud_outlined = Icons.cloud_outlined;
  static const IconData dns_outlined = Icons.dns_outlined;
  static const IconData storage_rounded = Icons.storage_rounded;
  static const IconData bolt = Icons.bolt;
  static const IconData bolt_rounded = Icons.bolt_rounded;

  // ============ 映射表（旧 IconData → 新体系 AppIcons）============
  //
  // ⚠️ 键 = **旧值**（`IconData`，与上面每个成员的值一一对应，重复值自然去重）；
  //    值 = 新体系的图标。
  //
  // 语义降级（新图标集里没有同义素材，取「语义最近」并在报告里逐条登记）：
  // - `comment`（气泡评论）→ `messages`；`tip`（托举爱心）→ `heart`；
  //   `refund` / `swap_horiz_rounded`（回转/切换）→ `refresh`；
  //   `clipboard`（写字板）→ `record`；`dialpad_outlined`（键盘盘面）→ `smartphone`；
  //   `person_remove_outlined`（删好友）→ `trash`；`push_pin`（置顶）→ `star`；
  //   `visibility_off_outlined`（隐藏）→ `eye`；`star_half`（半星）→ `star`；
  //   `link_off_rounded`（断链）→ `link`；`users`（多用户）→ `mine`（`lu-users` 同一素材）；
  //   `home`（首页）→ `services`；`warning` / `error`（警示）→ `complaint`（三角警示）。
  /// ⚠️ 不能用 `const`：`IconData` 没有覆写 `==`/`hashCode`，Dart 不允许它做 **const map 的键**
  /// （报 `does not have a primitive equality`）。运行期 `final` map 没这个问题 ——
  /// 所有键值都是 const 规范化实例，同一常量在进程内是同一对象，查表命中稳定。
  static final Map<IconData, AppIcons> kLegacyIconMap = <IconData, AppIcons>{
    // —— 旧包装器 70 条语义别名所对应的 Material 值 ——
    Icons.grid_view_outlined: AppIcons.services,
    Icons.grid_view_rounded: AppIcons.servicesActive,
    Icons.receipt_long_outlined: AppIcons.orders,
    Icons.receipt_long_rounded: AppIcons.ordersActive,
    Icons.chat_bubble_outline_rounded: AppIcons.messages,
    Icons.chat_bubble_rounded: AppIcons.messagesActive,
    Icons.person_outline_rounded: AppIcons.mine,
    Icons.person_rounded: AppIcons.mineActive,
    Icons.home_outlined: AppIcons.services,
    Icons.home_rounded: AppIcons.servicesActive,
    Icons.search_rounded: AppIcons.search,
    Icons.notifications_none_rounded: AppIcons.bell,
    Icons.chevron_right_rounded: AppIcons.chevronRight,
    Icons.expand_more_rounded: AppIcons.chevronDown,
    Icons.arrow_forward_rounded: AppIcons.arrowRight,
    Icons.arrow_back_rounded: AppIcons.arrowLeft,
    Icons.close_rounded: AppIcons.close,
    Icons.add_rounded: AppIcons.plus,
    Icons.remove_rounded: AppIcons.minus,
    Icons.check_rounded: AppIcons.check,
    Icons.more_horiz_rounded: AppIcons.dots,
    Icons.refresh_rounded: AppIcons.refresh,
    Icons.tune_rounded: AppIcons.filter,
    Icons.edit_outlined: AppIcons.edit,
    Icons.leaderboard_outlined: AppIcons.rank,
    Icons.sports_esports_outlined: AppIcons.players,
    Icons.headset_mic_outlined: AppIcons.headset,
    Icons.monetization_on_outlined: AppIcons.coins,
    Icons.card_giftcard_rounded: AppIcons.gift,
    Icons.star_outline_rounded: AppIcons.star,
    Icons.star_rounded: AppIcons.tbStar,
    Icons.verified_user_outlined: AppIcons.shield,
    Icons.schedule_rounded: AppIcons.clock,
    Icons.bolt_rounded: AppIcons.bolt,
    Icons.image_outlined: AppIcons.image,
    Icons.photo_camera_outlined: AppIcons.camera,
    Icons.favorite_outline_rounded: AppIcons.heart,
    Icons.favorite_rounded: AppIcons.tbHeart,
    Icons.mode_comment_outlined: AppIcons.messages,
    Icons.share_outlined: AppIcons.share,
    Icons.qr_code_rounded: AppIcons.qr,
    Icons.inbox_outlined: AppIcons.empty,
    Icons.phone_outlined: AppIcons.phone,
    Icons.location_on_outlined: AppIcons.location,
    Icons.lock_outline_rounded: AppIcons.lock,
    Icons.logout_rounded: AppIcons.logout,
    Icons.local_fire_department_outlined: AppIcons.fire,
    Icons.emoji_events_outlined: AppIcons.trophy,
    Icons.workspace_premium_outlined: AppIcons.crown,
    Icons.account_balance_wallet_outlined: AppIcons.wallet,
    Icons.show_chart_rounded: AppIcons.chart,
    Icons.people_outline_rounded: AppIcons.mine,
    Icons.confirmation_number_outlined: AppIcons.ticket,
    Icons.assignment_outlined: AppIcons.record,
    Icons.file_upload_outlined: AppIcons.upload,
    Icons.delete_outline_rounded: AppIcons.trash,
    Icons.block_rounded: AppIcons.ban,
    Icons.vpn_key_outlined: AppIcons.key,
    Icons.settings_outlined: AppIcons.settings,
    Icons.info_outline_rounded: AppIcons.info,
    Icons.help_outline_rounded: AppIcons.help,
    Icons.cloud_outlined: AppIcons.cloud,
    Icons.dns_outlined: AppIcons.server,
    Icons.mail_outline_rounded: AppIcons.mail,
    Icons.mark_email_read_outlined: AppIcons.mailRead,
    Icons.storage_rounded: AppIcons.db,
    Icons.security_rounded: AppIcons.safe,
    Icons.article_outlined: AppIcons.record,
    Icons.category_outlined: AppIcons.category,
    Icons.report_problem_outlined: AppIcons.complaint,
    Icons.volunteer_activism_outlined: AppIcons.heart,
    Icons.assignment_return_outlined: AppIcons.refresh,

    // —— 其余「直接 Material」名（各页写 `Icons.x` 的那些）——
    Icons.shield_outlined: AppIcons.shield,
    Icons.error_outline: AppIcons.complaint,
    Icons.error_outline_rounded: AppIcons.complaint,
    Icons.report_gmailerrorred: AppIcons.complaint,
    Icons.warning_amber_rounded: AppIcons.complaint,
    Icons.visibility: AppIcons.eye,
    Icons.visibility_outlined: AppIcons.eye,
    Icons.visibility_off_outlined: AppIcons.eye,
    Icons.credit_card_rounded: AppIcons.recharge,
    Icons.credit_card_outlined: AppIcons.recharge,
    Icons.support_agent_outlined: AppIcons.headset,
    Icons.support_agent_rounded: AppIcons.headset,
    Icons.dialpad_outlined: AppIcons.smartphone,
    Icons.system_update_alt: AppIcons.download,
    Icons.chat_bubble_outline: AppIcons.messages,
    Icons.block: AppIcons.ban,
    Icons.event_available_outlined: AppIcons.calendarCheck,
    Icons.arrow_back_ios_new_rounded: AppIcons.arrowLeft,
    Icons.arrow_back: AppIcons.arrowLeft,
    Icons.help_outline: AppIcons.help,
    Icons.check: AppIcons.check,
    Icons.hourglass_empty: AppIcons.hourglass,
    Icons.chevron_right: AppIcons.chevronRight,
    Icons.schedule: AppIcons.clock,
    Icons.bolt: AppIcons.bolt,
    Icons.lock_outline: AppIcons.lock,
    Icons.lock_reset_rounded: AppIcons.lock,
    Icons.lock_clock_outlined: AppIcons.lock,
    Icons.swap_horiz_rounded: AppIcons.refresh,
    Icons.circle_outlined: AppIcons.circleCheck,
    Icons.check_circle: AppIcons.tbCircleCheck,
    Icons.check_circle_outline: AppIcons.circleCheck,
    Icons.check_circle_outline_rounded: AppIcons.circleCheck,
    Icons.badge_outlined: AppIcons.verified,
    Icons.verified_outlined: AppIcons.verified,
    Icons.person_add_alt: AppIcons.userPlus,
    Icons.person_remove_outlined: AppIcons.trash,
    Icons.push_pin: AppIcons.star,
    Icons.camera_alt: AppIcons.camera,
    Icons.palette_outlined: AppIcons.palette,
    Icons.trending_up: AppIcons.trendingUp,
    Icons.star_border: AppIcons.star,
    Icons.star_half: AppIcons.star,
    Icons.star: AppIcons.star,
    Icons.link_off_rounded: AppIcons.link,
    Icons.sports_esports: AppIcons.players,
    Icons.emoji_events: AppIcons.trophy,
    Icons.workspace_premium: AppIcons.crown,
    Icons.account_balance_wallet: AppIcons.wallet,
    Icons.block_outlined: AppIcons.ban,
  };
}

/// 解析 `IconData` → 新体系图标；**未登记返回 null**（由调用方决定回退方式）
AppIcons? lookupLegacyIcon(IconData icon) => AppIconsLegacy.kLegacyIconMap[icon];

/// 解析并给出兜底：未登记时返回 [fallback]（默认 [AppIcons.info]，语义中性、绝不空白）
AppIcons resolveLegacyIconOr(IconData icon, {AppIcons fallback = AppIcons.info}) =>
    AppIconsLegacy.kLegacyIconMap[icon] ?? fallback;

/// 源级映射表别名（供测试与页面直读；`AppIconsLegacy.kLegacyIconMap` 是同一张表）
Map<IconData, AppIcons> get kLegacyIconMap => AppIconsLegacy.kLegacyIconMap;

/// **明确保留 Material 的清单**（映射表覆盖不到、且本轮刻意不迁移的调用点）。
///
/// 每一枚都要在迁移报告里逐条登记；未登记却出现在业务代码里的 `Icons.` 由
/// `test/icon_migration_guard_test.dart` 的源码级红线拦下。
const List<IconData> kMaterialRetained = <IconData>[];

/// 「Material 保留」的**文件级白名单**（正则，相对 `lib/`）：
/// - `src/icons/` → 映射表本体（本文件 + `app_icon.dart` 的旧语义别名区）；
/// - `src/update/` → 云端更新模块**负责人明确要求本轮不许改**（另一路在改）。
const List<String> kMaterialRetainedFilePatterns = <String>[
  r'^src/icons/app_icons_legacy\.dart$',
  r'^src/icons/app_icon\.dart$',
  r'^src/update/',
];
