/// ============ 祁连山电竞 · 品牌装饰系统（可复用地基）============
///
/// 权威依据：`docs/45-品牌装饰系统（待审批）.md`（规范全文）+ `site/design/brand-deco/system.html`
/// （规范图，几何值以它的 CSS 为准：`.notch` / `.gridtex` / `.sr` / `.vtick` / `.hero` /
/// `.contentcard` / `.listcard` / `.amt` / `.stat` / `.emptybox` / `.frameico` / `.sk4`）。
///
/// ## 一句话内核
/// **一套装饰 = 一条 45° 刀口 + 一张 4dp 网格 + 三档尺度的色彩用量**
/// （第 1 档极浅底打底 / 第 2 档实色与描边定位 / 第 3 档极小面积墨蓝落徽）。
/// "一眼是同套"靠这三个量**被严格重复**，不靠多画元素。
///
/// ## 文件边界（2026-10-15，另外 3 路并行改 core）
/// 本文件是**纯新建**：`app_colors.dart` / `app_ui.dart` / `app_nav.dart` / `app_icon.dart` /
/// `fish_core.dart` **一行未动**（只 import 取用）。因此本文件**暂时不从**
/// `package:fish_core/fish_core.dart` 导出 —— 需要主控在那 3 路收口后，把
/// `export 'src/widgets/deco.dart';` 加进 `fish_core.dart` 的 export 列表。
///
/// ## 硬红线（源码级，`test/deco_test.dart` 先剥注释、再逐条扫描本文件）
/// 1. **不得出现任何软过渡填充**（渐变家族那三个类 + 着色器创建接口）—— 细网格与骨架亮带
///    都是**硬边纹理**（纯色线 / 纯色矩形），`docs/45 §四`「渐变边界」的自检口径实测软渐变面积 = 0；
/// 2. **不得出现路径真裁** —— 斜切角一律"**底色盖角 + 只画两条边**"（与
///    `apps/boss-app/lib/widgets/order_status_tag.dart` 现有实现同源），真裁会切断描边、留缝；
/// 3. **不得出现投影** —— 卡片与列表 0 阴影，阴影只留给弹层；
/// 4. **不写死十六进制色值** —— 颜色只走 `T.*` / `AppColors.*`；
/// 5. 间距只落 **4dp 网格**（4/8/12/16/20/24/32/48/64），圆角只用 `0（通栏直角）/4/6/10/14/胶囊`，
///    切口边长只取 `4/6/8`（三套词汇互不混用）。
///
/// ## 全文索引
/// - [AppBaseline] 页面骨架基准线常数
/// - [AppDecoSpacing] / [AppDecoRadius] 装饰专用间距与圆角词汇
/// - [AppNotch] / [AppNotched] / [AppNotchRole] **① 斜切角（刀口）**
/// - [AppFineGrid] **② 细网格底纹**（限量：只用于品牌区与空态）
/// - [AppRuleLine] **③ 标尺线**（区块分隔，3×3 端点；与发丝线 [AppHairline] 语义不同，不合组件）
/// - [AppBrandBar] **④ 品牌短标**（4×16 小实色竖标）
/// - [AppHeroCard] / [AppContentCard] / [AppListCard] **⑤ 三档卡片**
/// - [AppSectionHeaderDeco] **⑥ 区块标题（带装饰）**
/// - [AppMoney] / [AppStat] **⑦ 金额与数字**
/// - [AppLevelSlot] / [AppNameRow] **⑧ L-SLOT 等级预留位**
/// - [AppEmptyDeco] / [AppSkeletonBlock] **⑨ 空态 / 骨架的品牌化**
library;

import 'package:flutter/material.dart';

import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../util/idempotency.dart' show fmtMoney;
import 'app_ui.dart' show AppHairline, AppPrice;

// ===========================================================================
// 页面骨架 · 基准线（docs/45 §二①）
// ===========================================================================

/// 页面骨架基准线（docs/45 §二①）：**装饰不再"随手放"，而是"贴线放"**。
///
/// 5 条横线 + 2 条纵线，数值全部由"状态栏 / 页头 / 品牌区 / 区块 / 页底"五个组件高度相加得到
/// （所以它们不是拍脑袋的魔数，任何一个组件高度变了这里会跟着错，这正是我们要的）。
///
/// ⚠️ **装饰只准贴 B0 / B1 / B4**：B2 是内容停靠线（装饰不许压在上面），
/// B3 是区块间线（区块标题自带的标尺线落在区块之间，不贴页面基准线）。
class AppBaseline {
  AppBaseline._();

  /// 状态栏（`SafeArea` 之上，设计稿按 48 计）
  static const double statusBar = 48;

  /// 页头高（与既有 `AppPageHeader` 的 56 同值）
  static const double pageHeader = 56;

  /// 品牌区高（`docs/39 §五` 组件高度档）
  static const double brandBand = 64;

  /// 区块间间距（组间松 20）
  static const double blockGap = 20;

  /// 一个内容块的基准高
  static const double contentBlock = 80;

  /// 页底（底栏）高
  static const double pageBottom = 56;

  /// 设计基准屏宽（390 × 844）
  static const double screenWidth = 390;

  /// 设计基准屏高
  static const double screenHeight = 844;

  /// V0 左页边
  static const double v0 = 16;

  /// 栏宽 358（390 − 16 × 2；**390 本身不是 4 的倍数**，所以 V1 与栏宽是"屏宽推导值"，
  /// 不参与「间距落 4dp 网格」自检 —— 它们是画布尺寸，不是间距）
  static const double columnWidth = screenWidth - v0 * 2;

  /// V1 右页边
  static const double v1 = v0 + columnWidth;

  /// B0 页头底线 = 状态栏 48 + 页头 56 = 104
  static const double b0 = statusBar + pageHeader;

  /// B1 品牌区底线 = 104 + 64 = 168
  static const double b1 = b0 + brandBand;

  /// B2 首块内容线 = 168 + 20 = 188
  static const double b2 = b1 + blockGap;

  /// B3 区块间线 = 188 + 80 + 20 = 288
  static const double b3 = b2 + contentBlock + blockGap;

  /// B4 页底信号线 = 844 − 56 = 788
  static const double b4 = screenHeight - pageBottom;

  /// **装饰只准贴的三条线**（页头底线 / 品牌区底线 / 页底信号线）
  static const List<double> pageDecoLines = <double>[b0, b1, b4];

  /// 标尺线的端点配置按基准线取（docs/45 §二① 原文）：
  /// - **B0 页级分隔**：无左端点方块（示意"这是页级的分隔"）；
  /// - **B3 区块之间**：左右端点齐备（提示"上一块结束"）；
  /// - **B4 页底信号线**：带左端点方块（示意"这一页到此结束"）。
  ///
  /// B1 用细网格（见 [AppFineGrid]）、B2 不许压装饰 —— 两者都会在这里被拒。
  static AppRuleLineDots ruleDotsForBaseline(double y) {
    if (y == b0) return AppRuleLineDots.rightOnly;
    if (y == b3) return AppRuleLineDots.both;
    if (y == b4) return AppRuleLineDots.leftOnly;
    throw ArgumentError(
      '标尺线只允许落在 B0(页级) / B3(区块间) / B4(页底)；B1 用细网格、B2 是内容停靠线不许压装饰。收到 y=$y',
    );
  }
}

/// 装饰专用间距（单位 dp）。
///
/// 全部落在 **4dp 网格**上：`4 / 8 / 12 / 16 / 20 / 24 / 32 / 48 / 64`。
/// ⚠️ `docs/45 §六` 要求给既有 `AppSpacing` 补 `20 / 48 / 64` 三档，但本轮文件边界
/// 不允许改 `app_spacing.dart`，所以先在这里落常量（能引用既有 token 的就引用，值一致），
/// 主控合并时平移过去即可，零风险。
class AppDecoSpacing {
  AppDecoSpacing._();

  /// 标尺线到内容 8dp（`docs/45 §二③`「线到标题 8dp」）
  static const double ruleToContent = AppSpacing.sm;

  /// 内容到线 12dp
  static const double lineToContent = AppSpacing.md;

  /// 区块上间距 20dp（与"组间松"同档）—— 待补进 `AppSpacing`
  static const double blockGap = 20;

  /// 页边 16dp
  static const double pageEdge = AppSpacing.page;

  /// 品牌短标与标题间距 8dp（组内紧）
  static const double tickToTitle = AppSpacing.sm;

  /// 空态上下留白 48dp —— 待补进 `AppSpacing`
  static const double emptyVertical = 48;

  /// 品牌区高 64dp —— 待补进 `AppSpacing`
  static const double brandBandHeight = 64;

  /// 卡内距 12dp（三档卡片统一内距；骨架块也照抄这个值，加载完不跳版）
  static const double cardPadding = AppSpacing.md;

  /// 行内发丝线缩进 16dp（与 V0 对齐）
  static const double hairlineIndent = AppSpacing.lg;

  /// 允许的间距刻度（自检口径：装饰的间距只能取这 9 档）
  static const List<double> grid = <double>[4, 8, 12, 16, 20, 24, 32, 48, 64];
}

/// 圆角词汇（`docs/45 §四`：**不用大圆角**，≥16 当卡片即玩具感）。
///
/// `0` 是**通栏直角**专用（ListCard），`capsule` 是胶囊专用 —— 其余只有 4 / 6 / 10 / 14。
class AppDecoRadius {
  AppDecoRadius._();

  /// 通栏直角（ListCard：序列表格没有"角"的语义）
  static const double none = 0;

  /// 小片（标签、字标块）
  static const double tag = 4;

  /// 线框图标框
  static const double small = 6;

  /// 控件（分段控件外框一档）
  static const double control = 10;

  /// 卡片（Hero / Content 两档同用；`--r-card: 14px`）
  static const double card = 14;

  /// 胶囊（用 `circular(999)` 近似：任何高度都收成胶囊，且不引入 `StadiumBorder` 的第二套语义）
  static const double capsule = 999;

  /// 允许的圆角集合
  static const List<double> values = <double>[none, tag, small, control, card, capsule];
}

// ===========================================================================
// ① 斜切角（刀口）
// ===========================================================================

/// 切口角位。**同一元素只用一处切口**（两角全切 = 装饰退化，`docs/45 §四`正反例）。
enum AppNotchCorner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

/// 斜切角语言谱系（`docs/45 §二⑤`）—— 把定案表**变成数据**，再由测试逐条钉住。
///
/// 谱系：`45° 切口 ── 6×6（高 20–24，右上｜状态·归属） ── 8×8（高 32，右下｜选中·进行）
/// ── 4×4（高 16–20，右上｜最小号）`。
///
/// 每个档位的 [cut] **必须等于**由 [height] 推导出来的档位（[selfConsistent]）；
/// `deco_test.dart` 会逐条断言 —— 这样"谱系表"与"自动取档规则"永远不会各说各话。
enum AppNotchRole {
  /// 订单状态标签（`OrderStatusTag` 是切口语言的源头，本体零改动，这里只登记它的档位）
  statusTag(height: 24, cut: 6, corner: AppNotchCorner.topRight),

  /// 分区标签（分部 / 平台 / 区服）：与状态标签同形同档
  sectionTag(height: 20, cut: 6, corner: AppNotchCorner.topRight),

  /// 小角标（起 / 已接 N 单）：高 16 的最小号，缩到 6×6 会把字吃掉半边
  miniBadge(height: 16, cut: 4, corner: AppNotchCorner.topRight),

  /// 筛选胶囊 · 选中：胶囊高 32（比标签高一档）→ 切口同步升一档；右下 = 选中"向前"的方向感
  filterChip(height: 32, cut: 8, corner: AppNotchCorner.bottomRight),

  /// ContentCard：左下角是"块内起点"，与右上标签正好成对角
  contentCard(height: 24, cut: 6, corner: AppNotchCorner.bottomLeft),

  /// L-SLOT（等级位）：与状态 / 分区标签同档同形，名称确定后直接落
  levelSlot(height: 20, cut: 6, corner: AppNotchCorner.topRight);

  const AppNotchRole({required this.height, required this.cut, required this.corner});

  /// 该档位的元素高度（决定切口档位的唯一变量）
  final double height;

  /// 该档位的切口边长（定案值，只允许 4 / 6 / 8）
  final double cut;

  /// 该档位的角位
  final AppNotchCorner corner;

  /// 谱系自证：[cut] 是否等于"由高度推导出来的档位"
  bool get selfConsistent => cut == AppNotch.sizeForHeight(height);
}

/// **斜切角（刀口）—— 整套装饰唯一的角度符号**（45° 直线，没有弧形、没有三角贴片）。
///
/// ## 尺寸只由高度决定，不由审美决定
/// [sizeForHeight] 取 `高度 ÷ 4` 最接近的一档，只在 `4 / 6 / 8` 三档里选
/// （并列时取**大一档**：高 20 → 6，与 L-SLOT / 分区标签的定案一致）。
/// 尺寸与高度脱钩会变成"缺了个角 / 被咬掉"，这是硬规则。
///
/// ## 实现方式：底色盖角 + 只画两条边（**不入路径真裁**）
/// 一块 `边长 × 边长` 的方块贴在角上，底色 = 元素自身的底（把原来的描边盖掉），
/// 只画**朝向元素内部的两条边**。为什么不真裁：真裁会把描边切断、
/// 在任意底色上出现缝隙，且触发重绘（既有 `OrderStatusTag` 就是这么做的）。
///
/// ## 未选中态：一键关闭
/// [enabled] = false（或 [resolveSize] 的 `selected: false`）→ 什么都不画。
/// **切口是"选中 / 状态"的专属信号，未选中态一律不切口**。
class AppNotch extends StatelessWidget {
  const AppNotch({
    super.key,
    required this.height,
    this.corner = AppNotchCorner.topRight,
    this.enabled = true,
    this.baseColor,
    this.borderColor,
    this.borderWidth = 1,
  });

  /// 按谱系档位构造（[AppNotchRole.cut] 必须与高度推导一致，由测试钉住）
  AppNotch.forRole(
    AppNotchRole role, {
    super.key,
    this.enabled = true,
    this.baseColor,
    this.borderColor,
    this.borderWidth = 1,
  })  : height = role.height,
        corner = role.corner;

  /// 元素高度（**唯一**的切口档位来源）
  final double height;

  /// 角位（左上 / 右上 / 左下 / 右下）
  final AppNotchCorner corner;

  /// 是否切口（未选中态置 false 一键关闭）
  final bool enabled;

  /// 盖角方块的底色（= 元素自身的底，默认白卡面）
  final Color? baseColor;

  /// 只画的两条边的颜色（默认冷描边 `#CDD6E2`）
  final Color? borderColor;

  /// 边宽（默认 1dp）
  final double borderWidth;

  /// 切口只取这三档
  static const List<double> sizes = <double>[4, 6, 8];

  /// 高度 → 切口边长：取 `高度 ÷ 4` 最接近的一档（并列取大一档）
  static double sizeForHeight(double height) {
    final target = height / 4;
    var best = sizes.first;
    for (final s in sizes) {
      if ((s - target).abs() <= (best - target).abs()) best = s;
    }
    return best;
  }

  /// 未选中态 = 0（不切口）；选中态 = [sizeForHeight]
  static double resolveSize({required double height, bool selected = true}) =>
      selected ? sizeForHeight(height) : 0;

  /// 本实例的切口边长
  double get cut => sizeForHeight(height);

  /// 朝向元素内部的两条边（"只画两条边"的机械定义）
  static Set<AppNotchEdge> edgesFor(AppNotchCorner corner) {
    switch (corner) {
      case AppNotchCorner.topRight:
        return const <AppNotchEdge>{AppNotchEdge.left, AppNotchEdge.bottom};
      case AppNotchCorner.topLeft:
        return const <AppNotchEdge>{AppNotchEdge.right, AppNotchEdge.bottom};
      case AppNotchCorner.bottomLeft:
        return const <AppNotchEdge>{AppNotchEdge.right, AppNotchEdge.top};
      case AppNotchCorner.bottomRight:
        return const <AppNotchEdge>{AppNotchEdge.left, AppNotchEdge.top};
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final cut = this.cut;
    return Container(
      width: cut,
      height: cut,
      decoration: BoxDecoration(
        color: baseColor ?? T.bgCardSolid,
        border: notchBorder(corner, borderColor ?? AppColors.hairline, borderWidth),
      ),
    );
  }

  /// 按角位拼出"只画两条边"的 [Border]
  static Border notchBorder(AppNotchCorner corner, Color color, double width) {
    final side = BorderSide(color: color, width: width);
    final edges = edgesFor(corner);
    return Border(
      top: edges.contains(AppNotchEdge.top) ? side : BorderSide.none,
      right: edges.contains(AppNotchEdge.right) ? side : BorderSide.none,
      bottom: edges.contains(AppNotchEdge.bottom) ? side : BorderSide.none,
      left: edges.contains(AppNotchEdge.left) ? side : BorderSide.none,
    );
  }
}

/// 切口的两条边（枚举化，便于"恰好两条边"被断言）
enum AppNotchEdge { top, right, bottom, left }

/// 把切口贴到 [child] 的指定角上（内部 8 行 `Stack` 封装，保证"切口只贴一处、且貼在元素角上"）。
class AppNotched extends StatelessWidget {
  const AppNotched({
    super.key,
    required this.child,
    required this.height,
    required this.corner,
    this.enabled = true,
    this.baseColor,
    this.borderColor,
    this.borderWidth = 1,
  });

  /// 按谱系档位构造
  AppNotched.forRole(
    AppNotchRole role, {
    super.key,
    required this.child,
    this.enabled = true,
    this.baseColor,
    this.borderColor,
    this.borderWidth = 1,
  })  : height = role.height,
        corner = role.corner;

  final Widget child;
  final double height;
  final AppNotchCorner corner;
  final bool enabled;
  final Color? baseColor;
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned(
          top: (corner == AppNotchCorner.topLeft || corner == AppNotchCorner.topRight) ? 0 : null,
          bottom: (corner == AppNotchCorner.bottomLeft || corner == AppNotchCorner.bottomRight) ? 0 : null,
          left: (corner == AppNotchCorner.topLeft || corner == AppNotchCorner.bottomLeft) ? 0 : null,
          right: (corner == AppNotchCorner.topRight || corner == AppNotchCorner.bottomRight) ? 0 : null,
          child: AppNotch(
            height: height,
            corner: corner,
            baseColor: baseColor,
            borderColor: borderColor,
            borderWidth: borderWidth,
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// ② 细网格底纹
// ===========================================================================

/// **细网格底纹 —— 硬边纹理，不是软过渡填充**（1px 线 / 5% / 间距 8dp）。
///
/// ## 限量使用（硬规则）
/// 只允许出现在**两处**：**品牌区背景** + **空态背景**；其余区域 **0 处**
/// （正文区、卡片正文、列表里都不许出现 —— 它会跟正文抢注意力）。
///
/// ## 为什么这里没有软过渡
/// 网格是一组**纯色 1px 直线**（[AppFineGridPainter] 只有 `Paint..color`，没有 shader），
/// 所以 `docs/45 §四`「渐变边界」的自检口径实测**软渐变面积 = 0**，它被单列为"硬边纹理"。
class AppFineGrid extends StatelessWidget {
  const AppFineGrid({
    super.key,
    this.child,
    this.step = defaultStep,
    this.opacity = defaultOpacity,
    this.color,
  }) : assert(step > 0, '间距必须为正'),
       assert(step % 4 == 0, '间距必须落 4dp 网格'),
       assert(opacity >= 0 && opacity <= 1, '透明度必须在 0–1');

  /// 线间距 8dp（`docs/45 §二⑥` + 本轮 brief 口径；设计稿 `.gridtex` 用了 16px，
  /// 组件已参数化，主控若要 16 传 `step: 16` 即可）
  static const double defaultStep = 8;

  /// 线透明度 5%（`docs/45 §二⑥` 的 3–5% 档）
  static const double defaultOpacity = 0.05;

  /// 线宽 1px（硬指标：细网格是 1px 线，不是 1dp 描边）
  static const double lineWidth = 1;

  /// 可叠加的内容；为空时本组件需要**紧约束**（`Positioned.fill` / 固定尺寸容器内）
  final Widget? child;

  /// 线间距（dp，必须 4 的倍数）
  final double step;

  /// 线透明度
  final double opacity;

  /// 线色（默认品牌锚墨蓝 `#0F2440` —— 与设计稿 `.gridtex` 的 `rgba(15,36,64,.05)` 逐值一致）
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final painter = AppFineGridPainter(color: color ?? AppColors.brandInk, opacity: opacity, step: step);
    if (child == null) return CustomPaint(painter: painter, size: Size.infinite);
    return Stack(
      children: <Widget>[
        Positioned.fill(child: CustomPaint(painter: painter)),
        child!,
      ],
    );
  }
}

/// 细网格的画法：横竖各一组 1px 纯色直线 —— **无 shader、无软过渡、无抗锯齿**。
class AppFineGridPainter extends CustomPainter {
  AppFineGridPainter({
    required this.color,
    this.opacity = AppFineGrid.defaultOpacity,
    this.step = AppFineGrid.defaultStep,
  });

  final Color color;
  final double opacity;
  final double step;

  /// 线宽恒 1px
  static const double lineWidth = AppFineGrid.lineWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: opacity)
      ..strokeWidth = lineWidth
      ..isAntiAlias = false;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant AppFineGridPainter old) =>
      old.color != color || old.opacity != opacity || old.step != step;
}

// ===========================================================================
// ③ 标尺线
// ===========================================================================

/// 标尺线的端点配置（`docs/45 §二①`：页级 / 区块间 / 页底 三种，只此三种）。
///
/// ⚠️ **"两端都没有端点"不是标尺线**，那是发丝线 —— 用既有 [AppHairline]，
/// 不要用本组件拼（`docs/45 §二⑥`：发丝线管行、标尺线管区块，两者不同层）。
enum AppRuleLineDots {
  /// B0 页级分隔：无左端点方块
  rightOnly,

  /// B4 页底信号线：带左端点方块
  leftOnly,

  /// B3 区块之间：左右端点齐备
  both,
}

/// **标尺线 —— 区块分隔专用**（1dp 线 + 两端 3×3 端点方块）。
///
/// 与"发丝线"（[AppHairline]，无端点、管行、缩进 16）**语义不同，刻意不合并成一个组件**：
/// 一条线要表达的是"**这里是一个新结构**"还是"**上一行结束了**"，决定它能不能有端点。
/// 禁止用发丝线分隔区块（读不出层级），也禁止用标尺线分隔列表行（端点方块变噪音）。
///
/// 端点色分工（`docs/45 §二①` + 设计稿 `.sr .dot3.b`）：**左端点 = 品牌色**（跟随区块色系，
/// 蓝或青瓷），**右端点 = 描边灰**。3×3 是设计稿定案（`docs/45`：为对齐像素取 3）。
class AppRuleLine extends StatelessWidget {
  const AppRuleLine({
    super.key,
    this.dots = AppRuleLineDots.both,
    this.width,
    this.indent = 0,
    this.endIndent = 0,
    this.accent,
    this.lineColor,
    this.dotColor,
  });

  /// 端点配置
  final AppRuleLineDots dots;

  /// 指定宽度（为空 = 撑满可用宽度）
  final double? width;

  /// 左缩进（贴 V0 起）
  final double indent;

  /// 右缩进
  final double endIndent;

  /// 左端点色（区块色系；默认品牌蓝）
  final Color? accent;

  /// 线色（默认发丝线 `#E3E8EF`）
  final Color? lineColor;

  /// 右端点色（默认冷描边 `#CDD6E2`）
  final Color? dotColor;

  /// 端点方块 3×3（设计稿定案值）
  static const double dotSize = 3;

  /// 线宽 1dp
  static const double lineWidth = 1;

  @override
  Widget build(BuildContext context) {
    final lineColorResolved = lineColor ?? T.divider;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (dots == AppRuleLineDots.both || dots == AppRuleLineDots.leftOnly)
          _dot(accent ?? T.primary),
        Expanded(child: Container(height: lineWidth, color: lineColorResolved)),
        if (dots == AppRuleLineDots.both || dots == AppRuleLineDots.rightOnly)
          _dot(dotColor ?? AppColors.hairline),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(left: indent, right: endIndent),
      child: width == null ? row : SizedBox(width: width, child: row),
    );
  }

  Widget _dot(Color color) => Container(width: dotSize, height: dotSize, color: color);
}

// ===========================================================================
// ④ 品牌短标
// ===========================================================================

/// **品牌短标 —— 4×16 的小实色竖标**（区块标题用）。
///
/// 它替代的是 `docs/21` 点名的"**每张卡左侧一条彩色竖条**"（过时模板签名）：
/// 竖条**贯穿整卡高**只是背景色，短标**只占标题一行高**才是"标记"。
/// 短标数量 = 该页**顶级分区数**（不是每个标题都配一个 —— 第二层区块只用标尺线）。
///
/// ⚠️ 设计稿 `.vtick` 现画的是 8×2（横小条），与本类默认的 **4×16 竖标**
/// （`docs/45 §二③` + §四手段表 + 本轮 brief 三处口径）不一致 —— 以口径为准，
/// 需要横条时传 `width: 8, height: 2`。
class AppBrandBar extends StatelessWidget {
  const AppBrandBar({
    super.key,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.color,
    this.radius = AppDecoRadius.none,
  }) : assert(width > 0 && height > 0, '尺寸必须为正'),
       assert(width % 4 == 0 && height % 4 == 0, '尺寸必须落 4dp 网格');

  /// 宽 4dp
  static const double defaultWidth = 4;

  /// 高 16dp（= 标题字号 15 的 16dp）
  static const double defaultHeight = 16;

  final double width;
  final double height;

  /// 实色（默认品牌主交互蓝；次级区块可传青瓷）
  final Color? color;

  /// 直角（宽 4 上任何圆角都会把它变成胶囊，那是另一套词汇）
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color ?? T.primary,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

// ===========================================================================
// ⑤ 三档卡片
// ===========================================================================

/// HeroCard 的"每屏 ≤1"预算作用域（`docs/45 §二②`：品牌锚面积极小，出现第 2 个 = 品牌锚被摊平）。
///
/// ## 为什么是"自动降级"而不是"断言"
/// core 不知道"一屏"的边界，也不知道调用方是否已按规则排版。断言会在线上多一处崩溃点；
/// **降级是可预期且不崩**的行为：作用域内第 2 张及之后的 [AppHeroCard] 自动按
/// **ContentCard 外观**渲染（无细网格、无墨绿字标块，改走 14 圆角 + 左下 6×6 切口）。
///
/// ## 用法
/// 一屏的内容包一层即可：`AppHeroBudgetScope(child: ListView(...))`。
/// **不包 = 不降级**（调用方自担），这也是既有页面零改动的保证。
class AppHeroBudgetScope extends StatefulWidget {
  const AppHeroBudgetScope({super.key, required this.child});

  final Widget child;

  /// HeroCard 向作用域认领名额：返回 true = 允许画 hero 外观。
  /// 未安装作用域 → 恒 true（不降级）。
  static bool canShowHero(BuildContext context) {
    final node = context.dependOnInheritedWidgetOfExactType<_HeroBudgetNode>();
    if (node == null) return true;
    return node.budget.claim(context as Element) == 0;
  }

  @override
  State<AppHeroBudgetScope> createState() => _AppHeroBudgetScopeState();
}

class _AppHeroBudgetScopeState extends State<AppHeroBudgetScope> {
  /// 按 **Element 身份**记账（不用 key / 不用序号）：同一个 HeroCard 重建不会重复占名额。
  final Map<Element, int> _order = <Element, int>{};

  /// 认领一个名额，返回它是第几个（0 = 第一个，可画 hero）
  int claim(Element element) => _order.putIfAbsent(element, () => _order.length);

  @override
  Widget build(BuildContext context) {
    _order.clear(); // 每一次重建 = 重新记一遍"这一屏"
    return _HeroBudgetNode(budget: this, child: widget.child);
  }
}

/// 预算作用域的 InheritedWidget（`updateShouldNotify` 恒 true：
/// 作用域重建 → 依赖它的 HeroCard 必须重新认领）
class _HeroBudgetNode extends InheritedWidget {
  const _HeroBudgetNode({required this.budget, required super.child});

  final _AppHeroBudgetScopeState budget;

  @override
  bool updateShouldNotify(_HeroBudgetNode oldWidget) => true;
}

/// **HeroCard（每屏 ≤1）** —— 白底 + **细网格** + **右上 24dp 墨蓝字标块**（品牌锚）。
///
/// 唯一特征 = **细网格 + 墨蓝字标块**（三档卡片里只有它有网格）。
/// 品牌锚 `#0F2440` 每屏 ≤1 处 ≤1600px²（24×24 = 576px²，含切口），
/// 只允许出现在 [AppHeroCard.mark] 这个字标块上（`docs/45 §三` 配色表第 1 行）。
class AppHeroCard extends StatelessWidget {
  const AppHeroCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppDecoSpacing.cardPadding),
    this.margin,
    this.onTap,
    this.mark = inkMarkText,
    this.showMark = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  /// 字标块里的字（祁连山只以「**祁**」字标出现：几何字标、去山形，`docs/32 §〇`）
  final String mark;

  /// 是否画字标块
  final bool showMark;

  /// 字标块文字（品牌字标，不是 emoji、不是插画）
  static const String inkMarkText = '祁';

  /// 每屏上限（硬定案）
  static const int maxPerScreen = 1;

  /// 字标块边长 24dp
  static const double markSize = 24;

  /// 字标块内距（距卡片右上 8dp）
  static const double markInset = 8;

  @override
  Widget build(BuildContext context) {
    final hero = AppHeroBudgetScope.canShowHero(context);
    final radius = BorderRadius.circular(AppDecoRadius.card);
    final body = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: radius,
        // 设计稿 `.hero`：1px 品牌浅底描边（不投影 —— 卡片 0 阴影）
        border: Border.all(color: AppColors.primarySoft),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: <Widget>[
            if (hero) Positioned.fill(child: const AppFineGrid()),
            Padding(padding: padding, child: child),
            if (hero && showMark)
              Positioned(top: markInset, right: markInset, child: _inkMark()),
          ],
        ),
      ),
    );

    final content = hero
        ? body
        // 降级：走 ContentCard 外观（14 圆角 + 左下 6×6 切口，无网格无字标块）
        : AppNotched.forRole(
            AppNotchRole.contentCard,
            baseColor: T.bgCardSolid,
            borderColor: T.divider,
            child: body,
          );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: radius, onTap: onTap, child: content),
    );
  }

  Widget _inkMark() => SizedBox(
    width: markSize,
    height: markSize,
    child: AppNotched(
      height: markSize, // 24 → 6×6（由高度推导，配色表里写的 8×8 按硬规则取 6）
      corner: AppNotchCorner.topRight,
      baseColor: AppColors.brandInk,
      borderColor: T.primary,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.brandInk,
          borderRadius: BorderRadius.circular(AppDecoRadius.tag),
        ),
        child: Center(
          child: Text(
            mark,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1,
            ),
          ),
        ),
      ),
    ),
  );
}

/// **ContentCard** —— 白底 + 1dp 描边 + **圆角 14** + **左下 6×6 切口**（+ 可选标题行的 4×16 短标）。
///
/// 唯一特征 = **14 圆角 + 左下 6×6 切口**（三档里只有它有切口）。
/// 用法约束（`docs/45 §二②`）：只给"一个独立知识块"（一段规则、一个商品、一份明细）；
/// **同屏 ≤3 张**，超过就改 ListCard。
class AppContentCard extends StatelessWidget {
  const AppContentCard({
    super.key,
    required this.child,
    this.title,
    this.padding = const EdgeInsets.all(AppDecoSpacing.cardPadding),
    this.margin,
    this.onTap,
    this.showNotch = true,
  });

  final Widget child;

  /// 可选标题行：**标题前 4×16 品牌短标**（`docs/45 §二②` ContentCard 原文）
  final String? title;

  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  /// 切口开关（未选中 / 紧凑场景可一键关闭）
  final bool showNotch;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppDecoRadius.card);
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: radius,
        border: Border.all(color: T.divider), // 1dp 描边，0 阴影
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title != null) ...<Widget>[
            Row(
              children: <Widget>[
                const AppBrandBar(),
                const SizedBox(width: AppDecoSpacing.tickToTitle),
                Expanded(
                  child: Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: T.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDecoSpacing.ruleToContent),
          ],
          child,
        ],
      ),
    );

    final content = AppNotched.forRole(
      AppNotchRole.contentCard,
      enabled: showNotch,
      baseColor: T.bgCardSolid,
      borderColor: T.divider,
      child: box,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: radius, onTap: onTap, child: content),
    );
  }
}

/// **ListCard** —— 通栏白底 + 上下 1dp 发丝 + **圆角 0** + 行高 48/56/64（**无切口**）。
///
/// 唯一特征 = **通栏 0 圆角 + 发丝线行**（序列表格天生没有"角"的语义，
/// 强行加圆角会让 5 行以上列表出现"饼干盒"感）。行间发丝缩进 16 与文案起点对齐（= V0）。
class AppListCard extends StatelessWidget {
  const AppListCard({
    super.key,
    required this.rows,
    this.rowHeight = defaultRowHeight,
    this.dividerIndent = AppDecoSpacing.hairlineIndent,
    this.margin,
  }) : assert(
         rowHeight == 48 || rowHeight == 56 || rowHeight == 64,
         '行高只取 48 / 56 / 64（docs/45 §二②）',
       );

  /// 行（用 [AppListRow] 得到标准的 12dp 内距与居中）
  final List<Widget> rows;

  /// 行高（只取 48 / 56 / 64）
  final double rowHeight;

  /// 行间发丝缩进（默认 16，与 V0 对齐）
  final double dividerIndent;

  final EdgeInsetsGeometry? margin;

  /// 默认行高 56
  static const double defaultRowHeight = 56;

  /// 允许的行高
  static const List<double> rowHeights = <double>[48, 56, 64];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: Border(
          top: BorderSide(color: T.divider),
          bottom: BorderSide(color: T.divider),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < rows.length; i++) ...<Widget>[
            SizedBox(height: rowHeight, child: rows[i]),
            if (i != rows.length - 1) AppHairline(indent: dividerIndent),
          ],
        ],
      ),
    );
  }
}

/// ListCard 的标准行内容（左对齐 + 12dp 内距 + 垂直居中）
class AppListRow extends StatelessWidget {
  const AppListRow({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: AppDecoSpacing.cardPadding),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: padding, child: Align(alignment: Alignment.centerLeft, child: child));
}

// ===========================================================================
// ⑥ 区块标题（带装饰）
// ===========================================================================

/// 区块层级：**顶级分区**（配 4×16 短标）vs **第二层区块**（只有标尺线，标题降一档）。
///
/// 短标数量 = 该页顶级分区数 —— 第二层不配短标，这是"不靠彩色小片堆层级"的机械保证。
enum AppSectionLevel { top, secondary }

/// **区块标题（带装饰版）** —— 在既有 `AppSectionHeader` 的视觉基础上只加两处：
/// **① 标题左侧 4×16 品牌短标**（仅顶级分区）；**② 标题下方标尺线**（线到标题 8dp）。
///
/// ⚠️ **既有的 `AppSectionHeader` 一行未动**（`app_ui.dart` 属另外 3 路的文件边界）；
/// 本类是装饰版，独立存在。它替代的是"卡片上边框 + 分组底色"——
/// 一个信息只给一个信号（线），所以不会像"每段配一个彩色小标签"。
class AppSectionHeaderDeco extends StatelessWidget {
  const AppSectionHeaderDeco({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
    this.level = AppSectionLevel.top,
    this.accent,
    this.showRule = true,
    this.ruleDots = AppRuleLineDots.both,
    this.padding = const EdgeInsets.fromLTRB(
      AppDecoSpacing.pageEdge,
      AppDecoSpacing.blockGap,
      AppDecoSpacing.pageEdge,
      AppDecoSpacing.ruleToContent,
    ),
  });

  final String title;
  final String? subtitle;

  /// 右侧动作（12sp 品牌蓝，沿用既有口径）
  final String? action;
  final VoidCallback? onAction;

  /// 区块层级（决定是否配短标 + 标题字号档）
  final AppSectionLevel level;

  /// 区块色系（短标 + 标尺线左端点跟随；默认品牌蓝，青瓷体系传 `AppColors.primarySecondary`）
  final Color? accent;

  final bool showRule;
  final AppRuleLineDots ruleDots;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final isTop = level == AppSectionLevel.top;
    final accentResolved = accent ?? T.primary;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (isTop) ...<Widget>[
                AppBrandBar(color: accentResolved),
                const SizedBox(width: AppDecoSpacing.tickToTitle),
              ],
              Text(
                title,
                style: isTop
                    ? TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: T.textPrimary)
                    : TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textSecondary),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                const SizedBox(width: AppDecoSpacing.tickToTitle),
                Expanded(
                  child: Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder),
                  ),
                ),
              ] else
                const Spacer(),
              if (action != null)
                GestureDetector(
                  onTap: onAction,
                  child: Text(
                    action!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accentResolved,
                    ),
                  ),
                ),
            ],
          ),
          if (showRule) ...<Widget>[
            const SizedBox(height: AppDecoSpacing.ruleToContent),
            AppRuleLine(dots: ruleDots, accent: accentResolved),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// ⑦ 金额与数字
// ===========================================================================

/// 数字三档字号（`docs/45 §二④`：15 / 18 / 22 配 w700）
enum AppFigureSize {
  /// 15
  sm(15),

  /// 18
  md(18),

  /// 22
  lg(22);

  const AppFigureSize(this.value);

  /// 字号
  final double value;
}

/// **金额（全站唯一金）** —— 金额格式只有一个出口：既有 `fmtMoney`
/// （`¥` + 千分位 + 固定两位小数，如 `¥0.00` / `¥8.80` / `¥1,234.50`）。
///
/// ## 整串可命中（硬要求）
/// `¥` 与数字**在同一个 `Text` 里** —— `find.text('¥1,234.50')` 能整串命中。
/// 页面**不得**自己拼 `¥`、不得把符号拆成独立小号 `Text`（那会让"整串命中"失效，
/// 也会让金额被读成两个东西）。
///
/// ## 装饰三件事
/// `tabular-nums` 等宽 + 三档字号 15/18/22 配 w700 + 单位 12sp **贴基线**且**异色**
/// （单位用弱化灰 `#8A99AB`，与金额的金不同色 —— 否则单位会被读成钱）。
class AppMoney extends StatelessWidget {
  const AppMoney(
    this.amount, {
    super.key,
    this.size = AppFigureSize.md,
    this.unit = '',
    this.color,
  });

  /// 金额（一律经 `fmtMoney` 成串）
  final num amount;

  /// 三档字号
  final AppFigureSize size;

  /// **非金额**后缀（`/局`、`起`）—— 金额语境一律留空
  final String unit;

  /// 金额色（**按字号自动选档**：<19px 用小字金 [AppColors.goldText]，≥19px 用 [AppColors.gold]）
  ///
  /// 传自定义色时原样使用（如"已退款"降为灰）；见 `AppPrice.moneyInk`。
  final Color? color;

  /// `¥` 与单位的字号 12sp（比数字小 ≥2 档）
  static const double unitSize = 12;

  /// 金额串（复用既有唯一出口，本组件不自己拼 `¥`）
  static String text(num amount) => fmtMoney(amount);

  @override
  Widget build(BuildContext context) {
    // 两档金只有一处实现（`AppPrice.moneyInk`）：15/18 档 → goldText，22 档 → gold
    final c = AppPrice.moneyInk(size: size.value, explicit: color);
    final number = Text(
      fmtMoney(amount),
      style: TextStyle(
        fontSize: size.value,
        fontWeight: FontWeight.w700,
        color: c,
        height: 1.1,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
    if (unit.isEmpty) return number; // 整串一个 Text
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        number,
        const SizedBox(width: AppSpacing.xs),
        Text(
          unit,
          style: TextStyle(
            fontSize: unitSize,
            fontWeight: FontWeight.w600,
            color: AppColors.textPlaceholder, // 与金额异色
            height: 1.1,
          ),
        ),
      ],
    );
  }
}

/// **统计数字（灰黑，禁金）** —— 单量 / 在线数 / 次数 / 时长一律 `#14202E`。
///
/// 与 [AppMoney] **物理同屏时不允许上金**：金的唯一性绑定业务语义（钱 / 等级），
/// 统计数字上金等于出现第二个"重点"，`docs/45 §三` 自检口径里这一点算违规。
class AppStat extends StatelessWidget {
  const AppStat(
    this.value, {
    super.key,
    this.size = AppFigureSize.sm,
    this.unit = '',
    this.label,
    this.color,
  });

  /// 统计值（用 [thousands] 加千分位，**不要**用 `fmtMoney` —— 那会带上 `¥` 与两位小数）
  final num value;

  final AppFigureSize size;

  /// 单位（12sp / 弱化灰 `#8A99AB` / 贴基线）
  final String unit;

  /// 标签（11sp / 弱化灰，左对齐在数字上方）
  final String? label;

  /// 默认 `#14202E`（正文档，**禁金**）
  final Color? color;

  /// 单位字号 12sp
  static const double unitSize = AppMoney.unitSize;

  /// 统计数字的**千分位**（只分组整数部分：**不加 `¥`、不补两位小数**）。
  /// 金额一律走 [AppMoney] / `fmtMoney`，两者不可互换。
  static String thousands(num v) {
    final s = v.toString();
    final dot = s.indexOf('.');
    final intPart = dot < 0 ? s : s.substring(0, dot);
    final rest = dot < 0 ? '' : s.substring(dot);
    final negative = intPart.startsWith('-');
    final digits = negative ? intPart.substring(1) : intPart;
    final buf = StringBuffer(negative ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '$buf$rest';
  }

  @override
  Widget build(BuildContext context) {
    final c = color ?? T.textPrimary;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          thousands(value),
          style: TextStyle(
            fontSize: size.value,
            fontWeight: FontWeight.w700,
            color: c,
            height: 1.1,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        if (unit.isNotEmpty) ...<Widget>[
          const SizedBox(width: AppSpacing.xs),
          Text(
            unit,
            style: TextStyle(
              fontSize: unitSize,
              fontWeight: FontWeight.w600,
              color: AppColors.textPlaceholder,
              height: 1.1,
            ),
          ),
        ],
      ],
    );
    if (label == null || label!.isEmpty) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label!, style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder, height: 1.2)),
        const SizedBox(height: AppSpacing.xs),
        row,
      ],
    );
  }
}

// ===========================================================================
// ⑧ L-SLOT（等级标识预留位）
// ===========================================================================

/// **L-SLOT —— 打手等级标识的预留位：只锁几何，不锁内容**（负责人 2026-10-15：
/// "等我想好名称告诉你"）。
///
/// ## 规格（定案，全部由常量钉住）
/// 高 [slotHeight] 20 × 最长 [slotMaxWidth] 72 · 与名字间距 [gap] 8 · 与名字**同一行、垂直居中** ·
/// 名字行高 [nameRowHeight] 24（名字 15sp 行高 20 + 4dp 余量，补内容时不改版式、不挤行）。
///
/// ## 本轮**什么都不画**
/// 默认只输出一个 `SizedBox(height: 20)`（**只占行高、不占宽、不画形态**）——
/// 刻意避免"现在画一个以后要删的东西"。名称确定后按 `docs/45 §二⑤` 直接落地：
/// 高 20 → **右上 6×6 斜切角** + 字号 [labelSize] 11 + 字重 700 +（若有等级语义）
/// 琥珀 `#B4732A` —— 它是全站除价格外**唯一允许上金**的位置。
///
/// [debugOutline] = true 时画**琥珀虚线示意框**（只给出图核对用，不参与生产渲染）：
/// 它同时也是"金只出现在金额与等级两处"里等级那一处的落点。
class AppLevelSlot extends StatelessWidget {
  const AppLevelSlot({super.key, this.debugOutline = false});

  /// 出图核对开关（生产恒 false）
  final bool debugOutline;

  /// 高 20（与分区标签同档：高 20 → 右上 6×6）
  static const double slotHeight = 20;

  /// 最长 72
  static const double slotMaxWidth = 72;

  /// 与名字间距 8dp
  static const double gap = 8;

  /// 名字行高 24（名字 15sp 行高 20 + 4dp 余量）
  static const double nameRowHeight = 24;

  /// 名称定了以后要落的切口档：高 20 → 右上 6×6（**只记规格，不画**）
  static const AppNotchCorner notchCorner = AppNotchCorner.topRight;

  /// 名称定了以后要落的切口边长
  static const double notchCut = 6;

  /// 名称定了以后要落的字号
  static const double labelSize = 11;

  /// 示意框的琥珀色（唯一金，只给等级位 —— 且只在出图核对时可见）
  static const Color debugColor = AppColors.gold;

  @override
  Widget build(BuildContext context) {
    if (!debugOutline) {
      // 只留几何：高度 20 的行内占位，宽度 0（不画形态、不占名字的行宽）
      return const SizedBox(height: slotHeight);
    }
    return SizedBox(
      width: slotMaxWidth,
      height: slotHeight,
      child: CustomPaint(
        painter: _DashOutlinePainter(color: debugColor, radius: AppDecoRadius.tag),
        child: Center(
          child: Text(
            'L-SLOT',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: debugColor,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// 名字行（陪玩 / 打手列表行、身份卡顶卡共用）：
/// **头像位 / 名字 → 8dp → L-SLOT 预留位**，同一行、垂直居中，行高恒 24。
///
/// 为什么现在就把 L-SLOT 放进行里：**几何位先占住** —— 名称一到就能落，
/// 不会因为"补一个等级标识"而把整行撑高或挤掉名字。
class AppNameRow extends StatelessWidget {
  const AppNameRow({
    super.key,
    required this.name,
    this.leading,
    this.trailing,
    this.nameStyle,
    this.reserveLevelSlot = true,
    this.debugLevelSlot = false,
  });

  final String name;

  /// 行首（头像位）
  final Widget? leading;

  /// 行尾（右侧补充信息）
  final Widget? trailing;

  final TextStyle? nameStyle;

  /// 是否预留 L-SLOT 几何位（默认预留；**不画任何形态**）
  final bool reserveLevelSlot;

  /// 出图核对：把 L-SLOT 示意框画出来（生产恒 false）
  final bool debugLevelSlot;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppLevelSlot.nameRowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: AppDecoSpacing.tickToTitle)],
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nameStyle ??
                  TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: T.textPrimary,
                    height: 20 / 15, // 行高 20 → 与 L-SLOT 同行垂直居中时中心重合
                  ),
            ),
          ),
          if (reserveLevelSlot) ...<Widget>[
            const SizedBox(width: AppLevelSlot.gap),
            AppLevelSlot(debugOutline: debugLevelSlot),
          ],
          if (trailing != null) ...<Widget>[const SizedBox(width: AppDecoSpacing.tickToTitle), trailing!],
        ],
      ),
    );
  }
}

// ===========================================================================
// ⑨ 空态 / 骨架
// ===========================================================================

/// **空态（不靠插画）** —— 5% 细网格底 + 48×48 线框图标（右上切口）+ 标尺线 + 一句下一步动作。
///
/// 三件套里**没有插画、没有 emoji、没有山峰意象**（`docs/21` / `CLAUDE.md` 禁项）。
/// 图标框的切口按硬规则由高度推导：48 ÷ 4 = 12 → 封顶 **8×8**
/// （设计稿 `.frameico` 画的是 6×6 —— 以"切口边长由高度决定、不由审美决定"的硬规则为准）。
class AppEmptyDeco extends StatelessWidget {
  const AppEmptyDeco({
    super.key,
    required this.title,
    this.hint = '',
    this.icon = AppIconsLegacy.receipt_long_outlined,
    this.action,
    this.onAction,
    this.surfaceColor,
    this.ruleWidth = defaultRuleWidth,
  });

  /// 主文案（13sp / w700 / 正文色）
  final String title;

  /// 一句下一步动作（11sp / 弱化灰）
  final String hint;

  final IconData icon;

  /// 可点的动作文案（12sp / 品牌蓝）；为空则不渲染
  final String? action;
  final VoidCallback? onAction;

  /// 线框图标框所在的底色（盖角方块要与它同色才不出缝）
  final Color? surfaceColor;

  /// 标尺线宽 88（设计稿 `.sr2`）
  final double ruleWidth;

  /// 线框图标框边长 48
  static const double frameSize = 48;

  /// 线框图标框圆角
  static const double frameRadius = AppDecoRadius.small;

  /// 线框图标尺寸 24（图标 4 档里的中间档）
  static const double iconSize = 24;

  /// 标尺线默认宽
  static const double defaultRuleWidth = 88;

  @override
  Widget build(BuildContext context) {
    final surface = surfaceColor ?? T.bgCardSolid;
    return Container(
      color: surface,
      padding: const EdgeInsets.symmetric(
        vertical: AppDecoSpacing.emptyVertical,
        horizontal: AppDecoSpacing.pageEdge,
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: const AppFineGrid()),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              AppNotched(
                height: frameSize,
                corner: AppNotchCorner.topRight,
                baseColor: surface,
                borderColor: AppColors.hairline,
                child: Container(
                  width: frameSize,
                  height: frameSize,
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(frameRadius),
                    border: Border.all(color: AppColors.hairline),
                  ),
                  child: Center(child: AppIcon.of(icon, size: iconSize, color: T.textTertiary)),
                ),
              ),
              const SizedBox(height: AppDecoSpacing.lineToContent),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textPrimary),
              ),
              const SizedBox(height: AppDecoSpacing.ruleToContent),
              AppRuleLine(dots: AppRuleLineDots.both, width: ruleWidth),
              const SizedBox(height: AppDecoSpacing.ruleToContent),
              if (hint.isNotEmpty)
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.textPlaceholder),
                ),
              if (action != null) ...<Widget>[
                const SizedBox(height: AppDecoSpacing.ruleToContent),
                GestureDetector(
                  onTap: onAction,
                  child: Text(
                    action!,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: T.primary),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 骨架块的形状档（**保留真内容的圆角与内距** → 加载完成瞬间零位移，不跳版）。
enum AppSkeletonShape {
  /// 文本条（高 12 / 圆角 4）
  bar(radius: AppDecoRadius.tag, height: 12),

  /// 图标块（圆角 6）
  block(radius: AppDecoRadius.small, height: 24),

  /// 卡片（圆角 14 / 内距 12）
  card(radius: AppDecoRadius.card, height: 64),

  /// 通栏（直角 0）
  banner(radius: AppDecoRadius.none, height: 64);

  const AppSkeletonShape({required this.radius, required this.height});

  final double radius;
  final double height;
}

/// **骨架块** —— 6 档灰阶底（`#F1F4F8`，比页底亮一档，防"白上白"看不出）+
/// **白 55% / 40% 宽的硬边亮带**每 [period] 扫过一次。
///
/// 亮带是**纯色矩形位移**（不是软过渡填充）：`docs/45 §四` 渐变边界的自检口径把 shimmer
/// 单列为"硬边纹理"，实测软渐变面积 = 0。`animate: false` → 静态灰块（测试 / 无动效场景）。
class AppSkeletonBlock extends StatefulWidget {
  const AppSkeletonBlock({
    super.key,
    this.width,
    this.height,
    this.shape = AppSkeletonShape.bar,
    this.animate = true,
  });

  final double? width;
  final double? height;
  final AppSkeletonShape shape;

  /// 是否扫动（false = 静态灰块）
  final bool animate;

  /// 亮带宽度占块宽的比例 40%
  static const double bandWidthRatio = 0.40;

  /// 亮带色（白 55%）
  static const double bandOpacity = 0.55;

  /// 扫动周期 1.2s
  static const Duration period = Duration(milliseconds: 1200);

  /// 骨架底色（`AppColors.fieldBg` = 页头衬底/骨架条底色）
  static const Color baseColor = AppColors.fieldBg;

  @override
  State<AppSkeletonBlock> createState() => _AppSkeletonBlockState();
}

class _AppSkeletonBlockState extends State<AppSkeletonBlock> with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _start();
  }

  @override
  void didUpdateWidget(AppSkeletonBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && _controller == null) _start();
    if (!widget.animate && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  void _start() {
    _controller = AnimationController(vsync: this, duration: AppSkeletonBlock.period)..repeat();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height ?? widget.shape.height;
    final radius = BorderRadius.circular(widget.shape.radius);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: widget.width,
        height: h,
        child: Stack(
          children: <Widget>[
            const Positioned.fill(child: ColoredBox(color: AppSkeletonBlock.baseColor)),
            if (_controller == null)
              const SizedBox.shrink()
            else
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _controller!,
                  builder: (BuildContext context, Widget? _) => CustomPaint(
                    painter: AppSkeletonBandPainter(progress: _controller!.value),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 骨架亮带的画法：一个**硬边的白色矩形**从左扫到右（纯色，无 shader、无软过渡）。
class AppSkeletonBandPainter extends CustomPainter {
  AppSkeletonBandPainter({required this.progress});

  /// 0 → 1 的扫动进度
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final bandWidth = size.width * AppSkeletonBlock.bandWidthRatio;
    if (bandWidth <= 0 || size.width <= 0) return;
    final x = (size.width + bandWidth) * progress - bandWidth;
    final rect = Rect.fromLTWH(x, 0, bandWidth, size.height);
    canvas.drawRect(
      rect,
      Paint()..color = Colors.white.withValues(alpha: AppSkeletonBlock.bandOpacity),
    );
  }

  @override
  bool shouldRepaint(covariant AppSkeletonBandPainter old) => old.progress != progress;
}

/// L-SLOT 出图核对的虚线示意框（琥珀 1dp 虚线 + 圆角 4）。
///
/// 用虚线是**故意的语义**："这里还没有形态"。它是唯一一处用金的装饰绘制 ——
/// 位置就在等级位上，符合"金只给金额与等级"的铁律。
class _DashOutlinePainter extends CustomPainter {
  _DashOutlinePainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  /// 虚线段长 / 段间距（4dp 网格）
  static const double dash = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(r);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = distance + dash;
        final next = end > metric.length ? metric.length : end;
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + dash;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashOutlinePainter old) => old.color != color || old.radius != radius;
}
