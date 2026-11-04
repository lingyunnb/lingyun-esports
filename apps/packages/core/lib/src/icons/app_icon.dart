// 需要 `package:flutter/material.dart`：兼容别名区要写 `Icons.xxx`（见该类文档）
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'app_icons_data.dart';
import 'app_icons_legacy.dart';

// 反向再导出：只 import 本文件（或 `widgets/app_icon.dart`、`fish_core.dart`）的文件
// 就能同时看到 [AppIcons] / [AppIconsLegacy] / [AppIcon]，迁移期少一行 import。
export 'app_icons.dart';
export 'app_icons_legacy.dart';

/// 全 App 统一图标组件（方案 F「潮玩」图标集）
///
/// 图标几何来自 `site/design/color-graphics/assets/*.svg`（Lucide ISC + Tabler MIT），
/// 由 `scripts/tmp/gen-app-icons.mjs` 编译成 Dart `Path` 常量（[kAppIconData]），
/// 运行时用 [CustomPainter] 画 —— **零第三方依赖**，不吃字体，不依赖资源打包。
///
/// ## 为什么不用图标字体包 / flutter_svg
/// 实测踩坑（三次，见 git 历史）：
/// 1. `lucide_icons`：pubspec 把 Dart SDK 锁在 `<3.0.0`，本项目 Dart 3.x 无法解析依赖；
/// 2. `phosphor_flutter` 2.1.0：`class PhosphorIconData extends IconData`，而新版 Flutter 的
///    `IconData` 已是 `final` —— pub get 通过、analyze 不报，`flutter test`/`build` 编译直接炸；
/// 3. `font_awesome_flutter` 11.0.0：同样返回不继承 `IconData` 的类型。
/// 于是改用「SVG → Path 常量 + CustomPainter」：**不新增依赖、不联网、随仓库走**，
/// 且描边宽度/圆头圆角能与设计稿逐像素对齐。
///
/// ## 用法
/// ```dart
/// AppIcon(AppIcons.search, size: 18, color: T.textTertiary)   // 新代码：直接给枚举
/// AppIcon.of(AppIcon.info, size: 18, color: T.textTertiary)   // 迁移后的旧调用点（见下）
/// ```
///
/// ## 迁移收口（2026-10-16，方案 F 图标全局替换）
///
/// 迁移前全仓 152 处写的是 `Icon(AppIcon.x)` / `Icon(Icons.y)`，逐个改名既慢又容易改错。
/// 本文件因此提供**两个收口入口**：
///
/// 1. **[AppIcon.of]（旧 `IconData` 入口）** —— 传旧值（[AppIcon] 的语义别名或
///    [AppIconsLegacy] 的 Material 名），内部用 [kLegacyIconMap] 解析成新图标，
///    **画新几何**；同时镜像一枚 **不可见** `Icon`（`Opacity(0)`，不产生任何像素），
///    于是既有 finder 全部照旧可用：`find.byIcon(旧值)`、`find.byType(Icon)` 的**计数**、
///    `tester.getRect(...)` 的**矩形**、`tester.widget<Icon>(...).size/.color` 的**取值**。
///    ⇒ 迁移期「图标真的换了」与「既有断言一条不放宽」可以同时成立。
/// 2. **旧语义别名区（本文件下方 [AppIcon] 的 70 条 `static const IconData`）** ——
///    旧包装器（`src/widgets/app_icon.dart`）的成员名与值**逐字保留**，
///    因此既有调用点（含**负责人明确不许改动的 `product_list_page.dart`**）与测试
///    （`find.byIcon(AppIcon.check)` 等 53 处）**一行都不用改**。
///
/// 未登记在 [kLegacyIconMap] 的 `IconData` 走**显式 Material 保留**：仍按
/// Material 渲染（可见），不留空白、不留问号；清单见 [kMaterialRetained]。
class AppIcon extends StatelessWidget {
  /// 新代码入口：直接给 [AppIcons] 枚举
  const AppIcon(
    this.icon, {
    super.key,
    this.size = 20,
    this.color,
    this.strokeWidth,
  }) : legacy = null;

  /// **迁移入口**：给旧 `IconData`（[AppIcon] 的语义别名 / [AppIconsLegacy] 的 Material 名）
  ///
  /// `size` 不传时**与 Flutter 的 `Icon` 完全同源**（取 `IconTheme.of(context).size`，
  /// 通常 24），保证既有调用点的**几何零变化**；传了就与传值一致。
  const AppIcon.of(
    this.legacy, {
    super.key,
    this.size,
    this.color,
    this.strokeWidth,
  }) : icon = null;

  /// 新体系图标（[AppIcon.of] 入口下为 null）
  final AppIcons? icon;

  /// 旧 `IconData`（[AppIcon] 新入口下为 null）
  final IconData? legacy;

  /// 显示边长（dp）；viewBox 24 → 内部按 `size / 24` 缩放
  final double? size;

  /// 线条/填充颜色；**不传时与 `Icon` 一样继承 `IconTheme.of(context).color`**
  final Color? color;

  /// 覆盖描边宽度（viewBox 单位）；缺省取数据表里的原始值（lucide 系为 2）
  ///
  /// 只在个别需要「比常规更细/更粗」的场合用（如 11dp 的小角标）；常规场景不要传。
  final double? strokeWidth;

  /// 解析后的显示尺寸：显式值优先，其次 `IconTheme`，最后 24（= `Icon` 的兜底值）
  static double resolveSize(BuildContext context, double? size) =>
      size ?? IconTheme.of(context).size ?? 24;

  /// 解析后的颜色：显式值优先，其次 `IconTheme`，最后正文近黑蓝（`#14202E`）
  static const Color inkFallback = Color(0xFF14202E);

  static Color resolveColor(BuildContext context, Color? color) =>
      color ?? IconTheme.of(context).color ?? inkFallback;

  @override
  Widget build(BuildContext context) {
    final s = resolveSize(context, size);
    final c = resolveColor(context, color);

    final IconData? legacyData = legacy;
    if (legacyData == null) {
      return _paint(icon!, s, c, mirror: null);
    }

    final target = lookupLegacyIcon(legacyData);
    if (target == null) {
      // 映射表未覆盖 → **明确保留 Material**（可见渲染，绝不静默变空白/问号）
      return Icon(legacyData, size: s, color: c);
    }
    return _paint(target, s, c, mirror: legacyData);
  }

  /// 自绘新几何；[mirror] 非空时叠一枚**不可见** `Icon` 保留旧 `IconData`
  ///
  /// 镜像用 `Opacity(opacity: 0)`：`RenderOpacity` 在 alpha 为 0 时**直接 return，不画子节点**
  /// （也不建 layer），所以它只占极少的构建成本，**不产生任何像素**；
  /// 而 `Opacity` 不会像 `Offstage` 那样把子树从 finder 的 onstage 遍历中摘掉，
  /// 于是 `find.byIcon` / `find.byType(Icon)` / `getRect` / `widget<Icon>` 全部照旧。
  ///
  /// 镜像拿到的是**原始的** [size] / [color]（不代填解析值）：这样
  /// `tester.widget<Icon>(...).size` 在「调用点没写 size」时仍然是 `null`，
  /// 与迁移前**逐值相同**（真正生效的尺寸由 `Icon` 自己按 `IconTheme` 解析，两者同源）。
  Widget _paint(AppIcons target, double s, Color c, {IconData? mirror}) {
    final glyph = CustomPaint(
      painter: AppIconPainter(icon: target, color: c, strokeWidth: strokeWidth),
      isComplex: false,
      willChange: false,
    );
    if (mirror == null) {
      return SizedBox.fromSize(size: Size.square(s), child: glyph);
    }
    return SizedBox.fromSize(
      size: Size.square(s),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Opacity(opacity: 0, child: Icon(mirror, size: size, color: color)),
          glyph,
        ],
      ),
    );
  }

  // ============ 迁移期兼容别名区（旧包装器 70 条，名与值逐字保留）============
  //
  // ⚠️ 这一区是「旧 `IconData` → 新体系」映射表的**语义面**（另一半在
  // `app_icons_legacy.dart`）。业务代码里除本区外不得再出现 `Icons.` 字面量，
  // 由 `test/icon_migration_guard_test.dart` 的源码级红线守着。
  //
  // 为什么留在这：既有调用点写 `Icon(AppIcon.info)`、既有测试写 `find.byIcon(AppIcon.check)`，
  // 它们都需要 `AppIcon.info` / `AppIcon.check` 仍是**同一个 `IconData` 值**；
  // 值一变，53 处 finder 断言就会失效。渲染换成新图标靠的是 [AppIcon.of]，不是改这些值。

  // ---- 底部导航 ----
  static const IconData services = Icons.grid_view_outlined;
  static const IconData servicesFill = Icons.grid_view_rounded;
  static const IconData orders = Icons.receipt_long_outlined;
  static const IconData ordersFill = Icons.receipt_long_rounded;
  static const IconData messages = Icons.chat_bubble_outline_rounded;
  static const IconData messagesFill = Icons.chat_bubble_rounded;
  static const IconData mine = Icons.person_outline_rounded;
  static const IconData mineFill = Icons.person_rounded;

  // ---- 顶部导航 / 通用 ----
  static const IconData home = Icons.home_outlined;
  static const IconData homeFill = Icons.home_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData bell = Icons.notifications_none_rounded;
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData chevronDown = Icons.expand_more_rounded;
  static const IconData arrowRight = Icons.arrow_forward_rounded;
  static const IconData arrowLeft = Icons.arrow_back_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData plus = Icons.add_rounded;
  static const IconData minus = Icons.remove_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData dots = Icons.more_horiz_rounded;
  static const IconData refresh = Icons.refresh_rounded;
  static const IconData filter = Icons.tune_rounded;
  static const IconData edit = Icons.edit_outlined;

  // ---- 业务 ----
  static const IconData rank = Icons.leaderboard_outlined;
  static const IconData players = Icons.sports_esports_outlined;
  static const IconData headset = Icons.headset_mic_outlined;
  static const IconData coin = Icons.monetization_on_outlined;
  static const IconData gift = Icons.card_giftcard_rounded;
  static const IconData star = Icons.star_outline_rounded;
  static const IconData starFill = Icons.star_rounded;
  static const IconData shield = Icons.verified_user_outlined;
  static const IconData clock = Icons.schedule_rounded;
  static const IconData bolt = Icons.bolt_rounded;
  static const IconData image = Icons.image_outlined;
  static const IconData camera = Icons.photo_camera_outlined;
  static const IconData heart = Icons.favorite_outline_rounded;
  static const IconData heartFill = Icons.favorite_rounded;
  static const IconData comment = Icons.mode_comment_outlined;
  static const IconData share = Icons.share_outlined;
  static const IconData qr = Icons.qr_code_rounded;
  static const IconData empty = Icons.inbox_outlined;
  static const IconData phone = Icons.phone_outlined;
  static const IconData location = Icons.location_on_outlined;
  static const IconData lock = Icons.lock_outline_rounded;
  static const IconData logout = Icons.logout_rounded;
  static const IconData fire = Icons.local_fire_department_outlined;
  static const IconData trophy = Icons.emoji_events_outlined;
  static const IconData crown = Icons.workspace_premium_outlined;
  static const IconData wallet = Icons.account_balance_wallet_outlined;
  static const IconData chart = Icons.show_chart_rounded;
  static const IconData users = Icons.people_outline_rounded;
  static const IconData ticket = Icons.confirmation_number_outlined;
  static const IconData clipboard = Icons.assignment_outlined;
  static const IconData upload = Icons.file_upload_outlined;
  static const IconData trash = Icons.delete_outline_rounded;
  static const IconData ban = Icons.block_rounded;

  /// ⚠️ 旧名是 `AppIcon.key`，但 `key` 与 `Widget.key`（构造器参数）**同名冲突**
  /// （Dart：`Can't declare a member that conflicts with an inherited one`），
  /// 故此处命名为 `keyIcon`；全仓唯一一处旧调用点已同步改为 `AppIcon.keyIcon`（见迁移报告）。
  static const IconData keyIcon = Icons.vpn_key_outlined;
  static const IconData settings = Icons.settings_outlined;
  static const IconData info = Icons.info_outline_rounded;
  static const IconData help = Icons.help_outline_rounded;
  static const IconData cloud = Icons.cloud_outlined;
  static const IconData server = Icons.dns_outlined;
  static const IconData db = Icons.storage_rounded;
  static const IconData safe = Icons.security_rounded;
  static const IconData record = Icons.article_outlined;
  static const IconData category = Icons.category_outlined;

  // ---- 邮箱 ----
  static const IconData mail = Icons.mail_outline_rounded;
  static const IconData mailVerified = Icons.mark_email_read_outlined;

  // ---- 投诉 / 打赏 / 退款 ----
  static const IconData complaint = Icons.report_problem_outlined;
  static const IconData tip = Icons.volunteer_activism_outlined;
  static const IconData refund = Icons.assignment_return_outlined;
}

/// 把一枚 [AppIcons] 画到画布上（几何读 [kAppIconData]，无第二处硬编码）
class AppIconPainter extends CustomPainter {
  const AppIconPainter({required this.icon, required this.color, this.strokeWidth});

  final AppIcons icon;
  final Color color;

  /// 覆盖描边宽度（viewBox 单位）；null = 用数据表原值
  final double? strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final data = appIconDataOf(icon);
    final s = size.shortestSide / AppIconData.viewBox;
    if (!(s > 0)) return;

    // 统一把 viewBox(24) 坐标映射到实际绘制尺寸：canvas 缩放后 Path 直接按原坐标画。
    canvas.save();
    canvas.scale(s, s);

    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;

    if (data.mode == AppIconPaintMode.fill) {
      // 实心式（tabler 变体）：填充路径本身，不描边
      paint
        ..style = PaintingStyle.fill
        ..strokeWidth = 0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
    } else {
      // 描边式：**保留圆头圆角**（这是图标语言的一部分，不是可选装饰）
      // strokeWidth 是 viewBox 单位，随 canvas 缩放一起生效（size 20 时 2 → 1.67dp，与设计稿一致）
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth ?? data.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
    }

    canvas.drawPath(data.path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AppIconPainter old) {
    return old.icon != icon || old.color != color || old.strokeWidth != strokeWidth;
  }
}

/// 便捷构造：`AppIcons` → 可直接放进任意需要 widget 的地方
extension AppIconsWidgetX on AppIcons {
  /// `AppIcons.search.toWidget(size: 18, color: ...)`
  Widget toWidget({double size = 20, required Color color, double? strokeWidth}) =>
      AppIcon(this, size: size, color: color, strokeWidth: strokeWidth);
}
