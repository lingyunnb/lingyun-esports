import 'package:flutter/material.dart';

import 'glass_nav_bar.dart';

import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';
import 'app_icon_tile.dart';
import 'app_ui.dart';
import 'qishan_mark.dart';

/// 底部导航（最终设计稿 I 系列 + AI 入口改版 ai-entry-v3 + **2026-10-17 六项平铺改版**）
///
/// 老板端 [AppBottomNav] **六项等宽平铺**：服务 · 下单 · 订单 · 祁小山 · 消息 · 我的
///
/// ## 2026-10-17 负责人定案（当面作废了"凸起几何一个字节不许动"）
/// 1. 底栏新增「下单」→ 5 项变 6 项；**中间凸起位随之取消**（6 项等宽平铺，无凸起、无遮挡）；
/// 2. 祁小山降为**第 4 个普通项**（导航位 3 / 页面位 [HomeShell.pageAi] = 4）——
///    它**仍然是 shell 内的一个页面分支**（不是 push 二级页），选中态与其余五项同一套规则；
///    **长按仍然是快捷入口面板**（[AppBottomNav.onCenterLongPress]），功能一个没丢；
/// 3. 图标换成 filled 实心新素材（`site/design/color-graphics/assets/v2/nav-*.svg` 编译进
///    `AppIcons`，零 SVG 运行时）；**取消选中态的浅蓝方块底**（负责人："颜色非常丑"）→
///    选中 = 主色实心图标 + 主色文字；未选中 = `#94A3B8` 实心图标 + `#94A3B8` 文字。
///
/// 通用底部导航（无中位）—— 工作端用：首页 / 订单 / 排行榜 / 消息 / 我的
///
/// 与 [AppBottomNav] 同一套视觉（白底 + 发丝线 + 青蓝高亮 + 未读角标），
/// 差别只在于没有「下单」入口（打手不需要下单）。
class AppPlainBottomNav extends StatelessWidget {
  const AppPlainBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.badgeIndex = -1,
    this.badge = 0,
    this.height = defaultHeight,
  });

  /// 默认高度：与改动前**逐像素一致**（60 + 系统手势条 inset）
  ///
  /// 保持 60 而不是设计稿的 56：这个组件同时被 `apps/worker-app` 使用，
  /// 改默认值会让已停用但仍在线的**工作端 App 视觉跟着变**（负责人：本次不动工作端）。
  static const double defaultHeight = 60;

  /// 合并双端（A+ 清单 ID-F）：打手态底栏高度显式传入，与老板态底栏**取同一个值**，
  /// 这样 5 项 ↔ 3 项切换时底栏不会跳高（这是该参数存在的唯一理由）。
  static const double identityHeight = defaultHeight;

  final List<({String label, IconData icon, IconData active})> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// 需要显示未读角标的项（-1 = 不显示）
  final int badgeIndex;
  final int badge;

  /// 内容行高度（不含系统手势条 inset）
  final double height;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      height: height + bottomInset,
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        border: Border(top: BorderSide(color: T.divider)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Row(
          children: List.generate(items.length, (i) {
            final item = items[i];
            final on = i == currentIndex;
            final color = on ? T.primary : T.textTertiary;
            return Expanded(
              child: InkWell(
                onTap: () => onTap(i),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 方案 F 双色实底（planF `.bnav .it.on .nib`）：选中 = 品牌渐变方块 +
                        // 白色镂空图标 + 彩色柔和阴影；未选中 = 浅底方块 + 冷灰图标。
                        // 方块 22×22 与改动前的图标盒**同尺寸** → 底栏 60dp 行高与
                        // `AppBottomNav` 中间位占位（22+3）零变化（AI 分支几何一格未动）。
                        AppTabGlyph(
                          icon: on ? item.active : item.icon,
                          selected: on,
                          size: 22,
                          glyphSize: 15,
                        ),
                        if (i == badgeIndex && badge > 0)
                          Positioned(
                            right: -8,
                            top: -4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.error,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              constraints: const BoxConstraints(minWidth: 15),
                              child: Text(
                                badge > 99 ? '99+' : '$badge',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: color,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.onCenterTap,
    this.onCenterLongPress,
    this.onCreateOrder,
    this.messageBadge = 0,
    this.glass = false,
  });

  /// 液态玻璃悬浮模式（负责人 2026-10-18：「做液态玻璃让底部导航栏悬浮」）
  ///
  /// true → 底栏变成**悬浮胖胶囊**：左右各留 16、离手势条 8dp，
  /// 内部用 `LiquidGlass` 做**实时折射**（shader 扭曲背后像素，不是普通毛玻璃）。
  ///
  /// 默认 false —— 这是**用户可自主开启**的外观选项（开关落「我的 → 外观」），
  /// 不是默认视觉。宿主还需 `Scaffold(extendBody: true)` 让内容延伸到胶囊身后，
  /// 否则玻璃采样不到东西，看起来和实色一样。
  final bool glass;

  /// 导航位（**6 项等宽平铺**）：0 服务 / 1 下单 / 2 订单 / **3 祁小山** / 4 消息 / 5 我的
  ///
  /// 与页面索引不是一回事（`HomeShell` 用 `_pageToNav` / `_navToPage` 换算）。
  /// 「下单」不是页面分支（点它 push 选择服务页），但它**占一个导航位** ——
  /// 否则六项里会少一格，右半边挤在一起。
  final int currentIndex;

  /// 点某一项（参数 = **导航位索引**）。「下单」位若没给 [onCreateOrder] 也会走这里。
  final ValueChanged<int> onTap;

  /// 「祁小山」位（导航位 3）的点按：切到 shell 内的 AI 分支（**不是 push**）
  ///
  /// 不传时退化成 `onTap(3)`；传了就以它为准（既有调用点与测试都走这条）。
  final VoidCallback? onCenterTap;

  /// 「祁小山」位**长按**：原有快捷入口面板（找陪玩 / 聊天记录 / 联系客服 / 直接去下单）
  ///
  /// 2026-10-17 取消凸起后，这条**功能一个字没动**，只是挂载位置从"凸起圆"变成"第 4 格"。
  final VoidCallback? onCenterLongPress;

  /// 「下单」位（导航位 1）的点按：push「选择服务」页（`ProductListPage`）
  final VoidCallback? onCreateOrder;

  /// 未读角标（默认挂在「消息」位 = 导航位 4）
  final int messageBadge;

  /// 六项定义（顺序即导航位）：第 4 项（index 3）是「祁小山」，图标是自绘祁山标，
  /// 因此它在 [build] 里单独判断，不放进这张表。
  static const List<({String label, AppIcons icon})> _items = <({String label, AppIcons icon})>[
    (label: '服务', icon: AppIcons.navServices),
    (label: '下单', icon: AppIcons.navOrderCreate),
    (label: '订单', icon: AppIcons.navOrders),
    (label: '祁小山', icon: AppIcons.ai), // 占位：实际画自绘祁山标（见 build）
    (label: '消息', icon: AppIcons.navMessages),
    (label: '我的', icon: AppIcons.navMine),
  ];

  /// 「祁小山」的导航位（自绘祁山标、长按面板都挂在它上面）
  static const int aiNavIndex = 3;

  /// 「服务」的导航位
  static const int servicesNavIndex = 0;

  /// 「下单」的导航位
  static const int orderCreateNavIndex = 1;

  /// 「订单」的导航位
  static const int ordersNavIndex = 2;

  /// 「消息」的导航位（未读角标落点）
  static const int messagesNavIndex = 4;

  /// 「我的」的导航位
  static const int mineNavIndex = 5;

  /// 高度：60 + 系统手势条 inset（**与改动前逐像素一致**：取消凸起不改变栏高，
  /// 否则页面可用高度会跳 1 个档，`AppOrderFab` 的纵向净距也要跟着重算）
  static const double height = 60;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // 液态玻璃悬浮模式（负责人 2026-10-18）：底栏浮起来，里面做实时折射。
    // 两个模式下高度与底部内距取值不同：
    // · 普通模式：整条贴底，高度含手势条 inset（沿用改版前口径，一个像素没动）
    // · 玻璃模式：由外层 Padding 让开手势条，条内不再重复加 inset
    final bar = Container(
      height: glass ? height : height + bottomInset,
      // 玻璃模式下**条自身不能有底**：底色改由玻璃层的 tint 承担。
      // 压在玻璃外面的白会把折射和色散一起盖掉，特效等于白做。
      decoration: glass
          ? null
          : BoxDecoration(
              color: T.bgCardSolid,
              border: Border(top: BorderSide(color: T.divider)),
            ),
      child: Padding(
        padding: EdgeInsets.only(bottom: glass ? 0 : bottomInset),
        child: Row(
          children: List.generate(_items.length, (i) {
            final item = _items[i];
            final on = i == currentIndex;
            // 选中 = 主色 / 未选中 = #94A3B8（**没有方块底**：负责人 2026-10-17
            // 明确否掉了"浅蓝方块"那一套，图标直接落在白底上）
            final color = on ? T.primary : T.textTertiary;
            final isAi = i == aiNavIndex;

            final VoidCallback onTapCell = () {
              if (isAi) {
                final centerTap = onCenterTap;
                if (centerTap != null) {
                  centerTap();
                  return;
                }
              }
              if (i == orderCreateNavIndex) {
                final createOrder = onCreateOrder;
                if (createOrder != null) {
                  createOrder();
                  return;
                }
              }
              onTap(i);
            };

            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTapCell,
                // 长按只给「祁小山」：这是快捷入口面板唯一的挂载点（不新增第二个可见按钮）
                onLongPress: isAi ? onCenterLongPress : null,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 图标 22dp（filled 实心，几何编译自 assets/v2/nav-*.svg）
                        // 「祁小山」用自绘祁山标：它是品牌标识，不是图标集里的一枚
                    // 切换特效（2026-10-18，仅玻璃模式）：选中图标弹性放大给手感锚点。
                    // 只在 glass 下启用 —— 默认模式维持"与改动前逐像素一致"的承诺。
                    if (glass)
                      AnimatedScale(
                        scale: on ? 1.15 : 1.0,
                        duration: const Duration(milliseconds: 380),
                        curve: Curves.elasticOut,
                        child: isAi
                            ? AppQishanMark(size: 22, color: color)
                            : AppIcon(item.icon, size: 22, color: color),
                      )
                    else if (isAi)
                      AppQishanMark(size: 22, color: color)
                    else
                      AppIcon(item.icon, size: 22, color: color),
                        if (i == messagesNavIndex && messageBadge > 0)
                          Positioned(
                            right: -8,
                            top: -4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppColors.error,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              constraints: const BoxConstraints(minWidth: 15),
                              child: Text(
                                messageBadge > 99 ? '99+' : '$messageBadge',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
    if (!glass) return bar;

    // ── 液态玻璃悬浮模式（负责人 2026-10-18）──────────────────────────────
    //
    // 玻璃本体的实现搬到 `GlassNavBar`（独立 StatefulWidget）。理由：
    // 它需要多持一个"拖动中的滑块位置"状态（横滑跟手，见那边的注释），
    // 而 `AppBottomNav` 是公共无状态组件，不该为一个外观选项改变自身生命周期。
    return GlassNavBar(
      height: height,
      bottomInset: bottomInset,
      itemCount: _items.length,
      currentIndex: currentIndex,
      orderCreateIndex: orderCreateNavIndex,
      onSelect: onTap,
      child: bar,
    );
  }
}

/// 右下角「快速下单」浮标（设计稿 `site/design/order-fab/e-collapse-pill.html` 方案 E）
///
/// ## 外观（照稿硬参数，一个取值都不改）
/// - **默认**：128 × 44 胶囊（全圆 r=22）/ 白底 `#FFFFFF` + 1px 发丝线 `AppColors.divider` +
///   阴影 `0 4px 14px rgba(15,23,42,.08)`；内「雪山标 18dp + 快速下单 13dp w700」均取 `AppColors.primary`，
///   图标与文字间距 7、左右内边距 15
/// - **按下**：尺寸不变，底色 `#F1F5F9`、描边 `#CBD5E1`、阴影归零、缩放 0.97，图标/文字同步变深一档（`#1D4ED8`）
/// - **滚动收起**：只收宽度 128 → 44，**左缘（雪山标）与底边不动**
///   → 视觉上是"从右端往左缩"，收起后剩下的一定是图标那一头
///   （雪山标在内容左侧；前 44dp 恰好装下 18dp 图标 + 7dp 间距），
///   文字「快速下单」被裁掉；阴影降到 `0 3px 10px rgba(15,23,42,.10)`
///
/// ## 为什么不用渐变（与改版前的差别）
/// 旧实现是 ⌀54 实心品牌渐变球 —— 正是 docs/21 禁的「一坨蓝」。本方案把主色面积压到
/// 18dp 图标 + 13dp 文字两处，浮标整体是**白底 + 发丝线**，与底栏凸起「祁小山」同色系。
///
/// ## 热区（≥48dp 硬要求）
/// 视觉 44 高时外层各补 4dp 透明 padding → 热区 **48 × 144**（收起态 48 × 48）。
/// `right` 已按「热区右缘仍在 16dp 处」反算为 12（= 16 − 4），视觉位置与设计稿完全一致。
///
/// ## 与底部导航中间凸起「祁小山」的关系（**不得重叠**）
/// 收起/展开、按下缩放都**不改变**右缘、底边与热区尺寸，因此几何关系恒为
/// （390dp 宽屏、凸起 ⌀54 / `top: -16` / 居中）：
/// - 横向：浮标热区左缘 x=246 ↔ 凸起右缘 x=222 → **净距 24dp**
/// - 纵向：浮标视觉底边比凸起顶边高 **16dp**（`visualBottomGap` 的取值理由）
/// - 两者不在同一条竖向带上（热区占 x∈[246,382]，凸起占 x∈[168,222]）→ 矩形永不相交
/// 回归断言见 `test/app_order_fab_test.dart` 的几何组（在 390 × 844 + 底栏真实渲染下实测）。
///
/// ## 手势（不与列表/轮播抢事件）
/// 只用 `GestureDetector(onTap:)` = 单个 `TapGestureRecognizer`：
/// - **纵向**：手指在浮标上按下再纵滑，竞技场里可滚动列表的 `VerticalDragGestureRecognizer`
///   在超过 touch slop 后胜出，浮标的 tap 被取消 → 列表正常滚动（浮标不"吃"滚动）
/// - **横向**：浮标完全不认领先手势，`PageView`（宣传图轮播）的横向手势不受影响
/// - 浮标与宣传图在版面上也不重叠（宣传图在顶部 y≈60..216，浮标在底部）
class AppOrderFab extends StatefulWidget {
  const AppOrderFab({
    super.key,
    required this.onTap,
    this.label = '快速下单',
    this.expanded = true,
  });

  final VoidCallback onTap;

  /// 文案。设计稿建议把泛泛的「立即下单」改成「**快速下单**」（docs/21 禁"立即体验"式空话）
  final String label;

  /// 是否展开：`true` 胶囊（128 × 44）/ `false` 收起小圆（44 × 44）
  ///
  /// 由页面注入（服务页监听滚动决定）；不传 = 常驻展开，便于静态使用与单测。
  final bool expanded;

  // ---------------------------------------------------------------------
  // 设计稿硬参数（公开常量：页面定位与测试断言共用同一份数字，杜绝"两处各写一遍"）
  // ---------------------------------------------------------------------

  /// 展开态视觉尺寸：128 × 44
  static const double expandedWidth = 128;
  static const double height = 44;

  /// 收起态视觉尺寸：44 × 44
  static const double collapsedWidth = 44;

  /// 胶囊全圆半径
  static const double radius = height / 2;

  /// 收起动画**可见窗口**的圆角半径（== [radius]）
  ///
  /// ⚠️ 这个常量是为修「收起过程中右端被方角切断」而引入的，不要退回成矩形裁切：
  /// 收起只改**宽度**（128 → 44）、高度恒 44，所以中间态的可见区就是一个
  /// `w × 44 / r=22` 的胶囊切片。若用 `ClipRect` 裁，切边是**方角**，
  /// 且会从字形中间把「快速下单」劈开 → 录屏里表现为"右端一条竖直硬边 + 半截蓝字"。
  ///
  /// ## 2026-10-05 第二轮（真机复现后重做）：圆角裁切**不够**
  /// 第一轮只把 `ClipRect` 换成 `ClipRRect(r=22)`，`flutter test`（Skia 软件光栅化）
  /// 的像素断言通过，但负责人真机上「半截蓝字 / 抠图没扣干净」**依旧存在**。真机取证
  /// （`data/temp/fab-device-02.png`，OnePlus PKR110 / Android 16 / dpr=3）复核后确认：
  /// 根因**不是裁切形状，而是“固定 128dp 内容 + 外层裁窗口”这个结构本身**——
  /// 只要文字还在树上，任何中间宽度都会把字形拦腰截断，圆角裁切只是把破口从直线换成弧线；
  /// 再叠上 `ClipRect` 的**抗锯齿边缘**（半透明白像素）就是"没扣干净的一层"。
  ///
  /// 现在改为**结构上不可能出现**：窗口宽度真正参与布局（`_window` 同时驱动胶囊宽度与
  /// `ClipRRect` 尺寸，**没有 `OverflowBox`、没有固定 128 内容**），并且文字在窗口关到
  /// 字形之前就**淡出到 0 并不再绘制**（`_labelOpacity`）→ 不存在"半个字"这一帧。
  /// 常量保留：窗口圆角半径仍必须 == 胶囊半径，否则切边与轮廓不同心。
  static const double clipRadius = radius;

  /// 文字完全淡出（不再绘制）时对应的收起进度 [t]
  ///
  /// 为什么是 0.45：可见宽度 `visibleWidth(t) = 44 + 84(1−t)`，t=0.45 时窗口宽 90.2dp。
  /// 文字左缘固定在 `sidePadding(15) + markSize(18) + markGap(7) = 40dp`，而淡出是**线性**的
  /// → 该帧不透明度 `1 − .45/.45 = 0`，即**在遮罩压到第一个字形之前文字已经消失**。
  /// 反向（展开）时同理：窗口开到 90dp 之前文字一直不可见，不存在"先露半个字"。
  static const double labelFadeEnd = .45;

  /// 触控热区（≥48dp 硬要求）：视觉 44 → 四周各补 4dp 透明热区
  static const double tapPadding = 4;
  static const double tapWidth = expandedWidth + tapPadding * 2; // 136

  /// 热区高度：44 + 4 + 4 = 52（≥48 ✓）
  static const double tapHeight = height + tapPadding * 2;

  /// 视觉**右缘**距屏幕右边 = 16dp（设计稿 `right: 16` 指的是视觉位置）
  ///
  /// 注：收起动画以**左缘**为锚（雪山标不动、右端向左缩），但热区右缘与底边全程不动，
  /// 因此与底栏凸起的净距在展开/收起/按下三种状态下完全一致（见类注释"关系"一节）。
  static const double visualRight = 16;

  /// Flutter `Positioned.right`：热区比视觉宽 4dp，故 `right = 16 − 4 = 12`
  ///
  /// 若照抄 `right: 16`，视觉右缘会跑到 20dp，与稿不符 —— 这是"补热区"最容易出的偏差。
  static const double right = visualRight - tapPadding;

  /// 设计稿 `bottom: 116`（**屏幕坐标系**：浮标视觉底边 y = 844 − 116 = 728）
  static const double designBottomAnchor = 116;

  /// 底栏高度（[AppBottomNav] / [AppPlainBottomNav] 的固定 60dp；不含系统手势条 inset）
  static const double navHeight = 60;

  /// 中间凸起「祁小山」的直径与上凸高度（[AppBottomNav] 里 `⌀54 / top: -16`）
  static const double bulgeDiameter = 54;
  static const double bulgeProtrusion = 16;

  /// 展开态浮标**视觉底边**距「底栏顶边」的距离：设计稿 728 ↔ 760 = **32dp**
  ///
  /// ⚠️ 这里必须把设计稿的取值**换算**一次，不能直接把 `bottom: 116` 搬进 Flutter：
  /// - 设计稿 `bottom: 116` 是相对**屏幕底边**（844）算的 → 视觉底边 y = 728；
  /// - `AppOrderFab` 挂在服务页 `body` 的 `Stack` 里，而 `Scaffold` 的 body **底边 = 底栏顶边**，
  ///   不是屏幕底边 → 同一个 `bottom: 116` 会渲染到 y = 760 − 116 = **644**，
  ///   比设计位置整整高 84dp（= 底栏高度），于是设计稿那套「与凸起 24 × 16dp 净距」的标注全部失效。
  /// 所以本实现按**设计意图**（视觉底边落在凸起顶边之上 16dp）换算成 Stack 内的值：
  /// 设计位移 116 − 底栏高度 84 = **32**（底栏 84 = 60 内容行 + 24 手势条，与设计稿 `.nav` 一致）。
  static const double visualBottomGap = 32;

  /// Flutter `Positioned.bottom`：热区比视觉高 4dp（下沿补 8 − 4）→ `32 − 4 = 28`
  ///
  /// 展开态浮标视觉底边 = Stack 底边 + 28 + 4 = **距底栏顶边 32dp**；
  /// 凸起顶边在底栏顶边之上 16dp → **垂直净距 = 32 − 16 = 16dp**（与设计稿标注一致）。
  static const double bottom = visualBottomGap - tapPadding;

  /// 排版与配色（照设计稿表格硬参数）
  static const double sidePadding = 15;
  static const double markGap = 7;
  static const double markSize = 18;
  static const double markSizeCollapsed = 19;
  static const double labelSize = 13;

  /// 白底 + 发丝线（docs/21：禁止"一坨蓝"实色大色块；主色只落在图标与文字）
  ///
  /// 2026-10-14 品牌升级：白底/发丝线/墨蓝**改为直接引用 token**（此前是写死的旧值
  /// `#E2E8F0` / `#2563EB`，本轮 token 换成 `#E3E8EF` / `#1D5FA8` 后它们不会自动跟随，
  /// 会留下"浮标还是旧蓝"的局部漂移）。
  static const Color fill = AppColors.bgCard;
  static const Color border = AppColors.divider;
  static const Color ink = AppColors.primary;
  /// 按压态：主色压深一档（`#1D4ED8` = 与 `#2563EB` 同族的深一档，
  /// 保持"按下更沉"的手感；随方案 F 主色一起换掉旧的 `#17508F`）
  static const Color inkPressed = Color(0xFF1D4ED8);
  /// 按压态中性浅底（纯交互反馈灰，收敛到区块浅底 token）
  static const Color fillPressed = AppColors.fieldBg;
  static const Color borderPressed = AppColors.hairline;
  static const List<BoxShadow> shadow = [
    BoxShadow(color: Color(0x140F172A), blurRadius: 14, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> shadowCollapsed = [
    BoxShadow(color: Color(0x1A0F172A), blurRadius: 10, offset: Offset(0, 3)),
  ];

  /// 收起 / 展开动画时长（1 → 0 / 0 → 1 走完这条曲线的时间）
  static const Duration collapseDuration = Duration(milliseconds: 180);

  /// 视觉左缘（屏幕坐标）：设计稿实测 x = 246（390 − 16 − 128）
  static double visualLeft(double screenWidth) =>
      screenWidth - visualRight - expandedWidth;

  /// 横向净距（浮标视觉左缘 ↔ 凸起右缘）：390dp 屏、凸起居中 ⌀54 → 设计稿实测 **24dp**
  ///
  /// 按**视觉**左缘算（246），与设计稿标注的"浮标左缘 x=246"逐字对应；
  /// 热区左缘比它再往左 4dp（= 242），但热区是透明的、不产生视觉重叠，
  /// 且 242 仍在凸起右缘 222 之右 → 即便按最保守的热区边界算也不会与凸起相交。
  static double bulgeClearance(
    double screenWidth, {
    double bulgeDiameter = AppOrderFab.bulgeDiameter,
  }) => visualLeft(screenWidth) - (screenWidth / 2 + bulgeDiameter / 2);

  /// 纵向净距（浮标视觉底边 ↔ 凸起顶边）= `visualBottomGap − bulgeProtrusion` → **16dp**
  static double bulgeVerticalClearance() => visualBottomGap - bulgeProtrusion;

  /// 滚动状态机参数（服务页的 `ScrollNotification` 监听用同一份常量）
  ///
  /// - [hysteresis]：方向迟滞 8dp —— 手指轻微回抖不会让胶囊反复"收起/展开"闪动
  /// - [expandDelay]：停止滚动 600ms 后展开
  /// - [collapseTrigger]：向下滚动累计超过该距离才收起（避免"点一下列表"就收起）
  static const double hysteresis = 8;
  static const Duration expandDelay = Duration(milliseconds: 600);
  static const double collapseTrigger = 8;

  /// 视觉胶囊的稳定 Key（测试量尺寸用；不参与布局）
  ///
  /// ⚠️ 2026-10-05 第二轮起：它**随收起动画变化**（128 → 44）。
  /// 第一轮它标识的是"恒定 128 的内部内容、由外层裁窗口决定露出多少"，
  /// 那正是"半截蓝字"的结构来源；现在宽度真正参与布局，所以它 == 可见宽度。
  /// 静止在展开态时仍是设计稿的 128 × 44，几何断言（右缘 16dp / 净距 24×16dp）全部不变。
  static const Key visualKey = Key('order-fab-visual');

  /// **可见窗口**的稳定 Key（收起动画就是在动它的宽度：128 → 44）
  ///
  /// 测试量这个盒子的**实际渲染宽度**来判断收起是否生效 —— 这是"看得见多少"的唯一真相。
  static const Key clipKey = Key('order-fab-clip');

  /// 可见窗口的**裁切遮罩**（圆角 22）：中间态只能按胶囊轮廓裁，不能是矩形
  ///
  /// 回归断言见 boss-app 的 `test/order_fab_midstate_visual_test.dart`：它的圆角半径必须 == [clipRadius]，
  /// 且类型必须是圆角裁切（矩形 [ClipRect] 会让收起过程出现方角直线破口）。
  static const Key clipMaskKey = Key('order-fab-clip-mask');

  /// 阴影层（独立于裁切窗口，保证收起中途左端仍有正常投影）
  static const Key shadowKey = Key('order-fab-shadow');

  /// 收起进度 [t]（0 = 展开 / 1 = 收起）对应的**可见宽度**
  ///
  /// 抽成静态函数：页面、出图与测试共用同一份插值，杜绝"三处各写一遍"。
  static double visibleWidth(double t) =>
      collapsedWidth + (expandedWidth - collapsedWidth) * (1 - t);

  /// [visibleWidth] 的逆运算：由实测可见宽度反查收起进度 [t]
  ///
  /// 给测试用：量到渲染宽度后可以反过来核对"这一帧到底是哪个进度"，
  /// 也可以验证"数值序列 == 渲染序列"（两者共用同一次插值）。
  static double progressOf(double width) =>
      1 - (width - collapsedWidth) / (expandedWidth - collapsedWidth);

  /// **仅测试用**：强制按下态（出图需要"按下"这一格稳定可复现）
  ///
  /// 为什么不靠 `TestGesture`：`startGesture` 之后不 up 也能进按下态，但出图流程要跨多次
  /// `pump`（还要开 `runAsync` 真异步窗口），手势对象容易被回收，"保持按下"不稳定。
  /// 这里走的是**同一个** `_pressed` 字段（真实按住时也走它），语义没有分叉；
  /// 生产代码不读它（默认 false），用完必须置回。
  @visibleForTesting
  static bool debugPressed = false;

  @override
  State<AppOrderFab> createState() => _AppOrderFabState();
}

/// 「快速下单」浮标的**皮肤与交互本体**（不含定位）
///
/// 为什么把定位抽出去：`AppOrderFab` 自己返回 `Positioned`，由此带来两个硬约束 ——
/// 1. 它只能是某个 `Stack` 的**直接**子节点，外面再包一层 `Positioned` 会触发
///    Flutter 的 `Competing ParentDataWidgets` 断言；
/// 2. 位置完全由组件内部常量决定，调用方无法覆盖 —— 出图、以及将来任何
///    "把同一个胶囊放到别的位置"的场景都做不了。
///
/// 拆成 `AppOrderFab`（= `Positioned` + 本组件）之后：生产用法一个字没变
/// （仍是 `Stack(children: [AppOrderFab(onTap: ...)])`），而出图/预览可以直接把本组件
/// 放进任意 `Positioned` / `Align`，不与父数据打架。
class AppOrderFabSkin extends StatefulWidget {
  const AppOrderFabSkin({
    super.key,
    required this.onTap,
    this.label = '快速下单',
    this.expanded = true,
  });

  final VoidCallback onTap;
  final String label;
  final bool expanded;

  @override
  State<AppOrderFabSkin> createState() => AppOrderFabSkinState();
}

/// 皮肤状态（**公开**：出图测试靠 [AppOrderFab.debugPressed] 稳定复现"按下"这一格）
class AppOrderFabSkinState extends State<AppOrderFabSkin>
    with SingleTickerProviderStateMixin {
  /// 按下态（设计稿状态 2：底色/描边/阴影/缩放四处同时变）
  bool _pressed = false;

  /// 0 = 展开（128 × 44 胶囊）；1 = 收起（44 × 44 小圆）
  ///
  /// ## 为什么不是"固定宽度内容 + 外层裁剪"（2026-10-05 第二轮改）
  /// 第一轮为了"收起时内容不重排"，让内部布局恒定在展开态 128dp、只用外层窗口从右往左裁。
  /// 代价是：**文字一直在绘制**，任何中间宽度都会把一个汉字拦腰截断（只是切边从直线
  /// 变成圆弧），真机上就是负责人看到的"半截蓝字 / 像抠图没扣干净的一层"。
  ///
  /// 现在让**宽度真正参与布局**（[AppOrderFab.visibleWidth] 同时喂给胶囊宽度与裁切窗口），
  /// 并且文字在窗口关到字形之前就淡出到 0 且不再绘制 —— 双保险，结构上不可能露出半个字。
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: AppOrderFab.collapseDuration,
    value: widget.expanded ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    _anim.addListener(_onAnimTick);
  }

  @override
  void didUpdateWidget(covariant AppOrderFabSkin old) {
    super.didUpdateWidget(old);
    if (old.expanded == widget.expanded) return;
    // 180ms 的收起动画被中途要求反悔时，`reverse()` 会从当前位置平滑折返
    widget.expanded ? _anim.reverse() : _anim.forward();
  }

  /// 只让裁剪边界驱动重绘（不调 `setState` → 不重建整棵子树）
  void _onAnimTick() => setState(() {});

  @override
  void dispose() {
    _anim.removeListener(_onAnimTick);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _anim.value;
    final pressed = _pressed || AppOrderFab.debugPressed;

    final fillColor = pressed ? AppOrderFab.fillPressed : AppOrderFab.fill;
    final borderColor = pressed
        ? AppOrderFab.borderPressed
        : AppOrderFab.border;
    final inkColor = pressed ? AppOrderFab.inkPressed : AppOrderFab.ink;

    return SizedBox(
      // 热区尺寸恒定（136 × 52 = 视觉 128 × 44 + 四周 4dp 透明热区）：**热区不随视觉缩小**
      width: AppOrderFab.tapWidth,
      height: AppOrderFab.tapHeight,
      child: GestureDetector(
        // 只认 tap：纵向留给列表、横向留给 PageView（见 [AppOrderFab] 类注释"手势"一节）
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        // ⚠️ 这一层 `Align`（widthFactor/heightFactor = 1）是**必需的**，不是装饰：
        // 根 `SizedBox` 传下来的是**紧约束**（136 × 52），紧约束下里面写 128 也会被拉满，
        // "宽度参与布局"就完全失效（= 第一轮踩过的坑）。`Align` 把紧约束松开放给子树、
        // 自身尺寸跟着子树走，于是窗口才真的能收到 44。
        // `centerRight`：**右缘固定**（视觉右缘恒在 16dp 处，与设计稿一致），收起时左端向右缩，
        // 剩下的是**左侧的雪山标** —— 与设计稿"收起只留图标"一致。
        child: Padding(
          // ⚠️ 这 4dp 内缩**不能省，也不能靠 `centerLeft` 之类对齐去凑**：
          // 视觉盒比热区盒小 `tapPadding`（4dp），而 `Align` 只会把 128 宽的子树贴到
          // **热区盒的边**上 —— 于是胶囊右缘落在 `right: 12` 的位置，视觉右缘距屏幕边变成
          // **12dp**（设计稿要求 16dp）。第一轮用 `Padding(all: 4)` + `centerLeft` 正是为了
          // 拿到这个内缩；本轮改成 `centerRight`（右缘锚定）后必须把内缩显式写回来。
          // 实测（390 宽、`right: 12`）：补之前 `visual.right == 378`（= 12dp），补之后 374（= 16dp）。
          //
          // ⚠️ **只补右边，不补下边**：垂直方向上下各有 4dp 对称富余（52 = 44 + 4 + 4），
          // 根盒里的 `Align` 天然居中，已把视觉盒放在 y=4..48。再补一个 `bottom: 4` 会把它
          // 抬到 y=4..44，胶囊底边与底栏凸起的净距就从设计稿的 16dp 变成 **18dp**
          // （`app_order_fab_test.dart` 的纵向净距断言实测 18.0 vs 期望 16 —— 踩过）。
          // 水平方向不同：`centerRight` 把 8dp 富余全推到了左边，所以右边必须显式补回 4dp。
          padding: const EdgeInsets.only(right: 4),
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: 1,
            heightFactor: 1,
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) {
                final cur = AppOrderFab.visibleWidth(_anim.value);
                // 文字不透明度：`labelFadeEnd` 之内线性淡出，之后恒 0（且根本不建 Text）
                final op = (1 - _anim.value / AppOrderFab.labelFadeEnd).clamp(
                  0.0,
                  1.0,
                );
                // 图标尺寸 tween（18 → 19dp）：用阈值跳变会在动画中途"啪"地弹一下
                final markSize =
                    AppOrderFab.markSize +
                    (AppOrderFab.markSizeCollapsed - AppOrderFab.markSize) *
                        _anim.value;
                return ConstrainedBox(
                  // ⚠️ 这一层把 Stack 钉在**展开态 128 × 44**，是必需的：
                  // Stack 的尺寸由**非 positioned 子节点**决定，而下面第二层里的
                  // `Container(width: double.infinity)` 在松约束下会撑到 136（= 根盒宽），
                  // 于是 Stack 变 136 宽 → 胶囊右缘跑到 `right: 8` 而不是 4，
                  // 视觉右缘距屏幕边就成了 20dp（设计稿要求 16dp）。
                  // 收紧成 128 后：`centerRight` 对齐 + Stack 宽 128 → 右缘恒在 4dp 处。
                  constraints: const BoxConstraints.tightFor(
                    width: AppOrderFab.expandedWidth,
                    height: AppOrderFab.height,
                  ),
                  child: Stack(
                    // 阴影要画到胶囊圆角之外（裁了就不是"浮起"而是"贴纸"）。
                    // `Clip.none` 只对 **Stack 的子节点**生效 —— 所以这一层内部**不再有任何
                    // 矩形裁切**（第一轮在裁切层外还套了一个 `ClipRect`，它那条矩形抗锯齿
                    // 边缘就是真机上"像抠图没扣干净的一层"，本轮已彻底删除）。
                    clipBehavior: Clip.none,
                    children: [
                      // ── 第一层：阴影（独立、**不含任何填充色**）──────────────────
                      // 为什么单独一层：阴影若跟着内容一起被裁切窗口裁，只会剩下胶囊内部那点
                      // 模糊（等于没阴影）。它按当前宽度画同半径圆角矩形、不被裁，于是收起过程中
                      // 左端始终有正常投影，右端则被上面的内容盖住。
                      //
                      // ⚠️ 这里**绝对不能**给 `color:` —— `Clip.none` 的层若带白色填充，
                      // 会原样露出一块**方形白底**（正是"没扣干净"最典型的形态）。
                      // 回归断言见 boss-app 的 `test/visual/order_fab_fix_visual_test.dart`。
                      //
                      // 尺寸口径：圆角矩形本体按**可见胶囊盒**画（宽 = 当前窗口宽、高 = 44），
                      // 阴影的 y 偏移由 `Transform.translate` 承担。
                      // 不能用 `Positioned.fill` + `Alignment(0, .15)`：那会让盒子**高度也变成 52**
                      // （阴影被下移 6dp 而不是 4dp），且盒子与胶囊盒不同心 → 右端投影多出 2dp、
                      // 左右不对称。
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Transform.translate(
                            offset: const Offset(
                              0,
                              4,
                            ), // == AppOrderFab.shadow 的 offset.dy
                            child: Align(
                              alignment: Alignment.centerRight,
                              widthFactor: 1,
                              child: Container(
                                key: AppOrderFab.shadowKey,
                                width: cur,
                                height: AppOrderFab.height,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    AppOrderFab.clipRadius,
                                  ),
                                  boxShadow: pressed
                                      ? const []
                                      : (t > .5
                                            ? AppOrderFab.shadowCollapsed
                                            : AppOrderFab.shadow),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // ── 第二层：胶囊本体（宽度参与布局 + 内容按胶囊轮廓裁切）────────
                      // 这一层是**唯一**的裁切层，也是**唯一**画背景的层：
                      // `Container` 自己按当前宽度画白底 + 发丝线（r = 22，与裁切同半径、同心），
                      // 外层 `ClipRRect` 同时限住「可见宽度」与「内容溢出」两件事 —— 所以
                      // **不需要**（也绝不能有）第二层矩形裁切：多一层就多一条矩形抗锯齿边缘，
                      // 那正是真机上"像抠图没扣干净的一层"。
                      Align(
                        alignment: Alignment.centerRight,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: SizedBox(
                          key: AppOrderFab.clipKey,
                          width: cur,
                          height: AppOrderFab.height,
                          // ⚠️ 这里**不能**再包 `ClipRect`（`SizedBox` 也没有 `clipBehavior` 参数）。
                          // 唯一的裁切是下面这层 `ClipRRect`，且显式用 `Clip.antiAlias`
                          // （而不是 `Clip.hardEdge`）：圆角边缘与内容边缘口径一致，不会多出
                          // 一圈半透明白像素。不用 `antiAliasWithSaveLayer` —— 它插离屏合成层，
                          // 圆角边缘反而更"糊"。
                          child: ClipRRect(
                            key: AppOrderFab.clipMaskKey,
                            clipBehavior: Clip.antiAlias,
                            borderRadius: BorderRadius.circular(
                              AppOrderFab.clipRadius,
                            ),
                            child: AnimatedScale(
                              scale: pressed ? 0.97 : 1,
                              duration: AppOrderFab.collapseDuration,
                              child: Container(
                                // 稳定 Key：测试直接量这一层的渲染宽度（**随动画变化** 128 → 44）
                                key: AppOrderFab.visualKey,
                                width: double.infinity, // 铺满窗口 → 实际宽度 == 可见窗口宽度
                                height: AppOrderFab.height,
                                clipBehavior: Clip.none, // 描边不裁（裁了会在圆角外缘留一圈硬边）
                                decoration: BoxDecoration(
                                  color: fillColor,
                                  borderRadius: BorderRadius.circular(
                                    AppOrderFab.radius,
                                  ),
                                  border: Border.all(
                                    color: borderColor,
                                    width: 1,
                                  ),
                                ),
                                // ⚠️ `OverflowBox` 在这里的作用**只有一个**：把 Row 的布局宽度
                                // 钉死在展开态 128dp，让它**不随窗口每帧重排**。
                                // 第一轮也用了 `OverflowBox`，但方向反了 —— 它把 128dp 的**内容**
                                // 塞进更窄的**窗口**，于是文字被窗口拦腰截断（"半截蓝字"）。
                                // 现在窗口才是真宽度、内容恒定，文字又在窗口压到字形之前淡出到 0，
                                // 所以"被裁"这一帧根本不存在；这里的 128dp 恒定值退化为
                                // "防止 Row 在窄窗口下 overflow"的护栏（否则会报 RenderFlex overflow）。
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: AppOrderFab.expandedWidth,
                                  maxWidth: AppOrderFab.expandedWidth,
                                  minHeight: AppOrderFab.height,
                                  maxHeight: AppOrderFab.height,
                                  child: SizedBox(
                                    width: AppOrderFab.expandedWidth,
                                    height: AppOrderFab.height,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: AppOrderFab.sidePadding,
                                      ),
                                      child: Row(
                                        children: [
                                          AppMountainMark(
                                            // 设计稿：展开 18dp / 收起 19dp（收起后只留图标，略放大更"站得住"）
                                            size: markSize,
                                            color: inkColor,
                                          ),
                                          const SizedBox(
                                            width: AppOrderFab.markGap,
                                          ),
                                          // `op <= 0` 时**根本不建 Text**：Opacity(0) 仍会留一个合成层，
                                          // 而"结构上不可能出现半个字"最彻底的写法就是它压根不在树上。
                                          if (op > 0)
                                            Opacity(
                                              opacity: op,
                                              child: Text(
                                                widget.label,
                                                maxLines: 1,
                                                softWrap: false,
                                                style: TextStyle(
                                                  fontSize:
                                                      AppOrderFab.labelSize,
                                                  fontWeight: FontWeight.w700,
                                                  color: inkColor,
                                                  height: 1,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 页面级定位：把 [AppOrderFabSkin] 钉在右下角（`right` / `bottom` 见 [AppOrderFab] 的常量）
class _AppOrderFabState extends State<AppOrderFab> {
  @override
  Widget build(BuildContext context) => Positioned(
    right: AppOrderFab.right,
    bottom: AppOrderFab.bottom,
    child: AppOrderFabSkin(
      onTap: widget.onTap,
      label: widget.label,
      expanded: widget.expanded,
    ),
  );
}

/// 快捷入口（点中间＋后弹出的面板）
///
/// **面板只放"去别处也能做的事"的快捷方式**（聊天记录 / 联系客服 / 直接去下单）——
/// 它是快捷方式，**不计入「同一入口只出现一次」的判定**（结构规则 1 的注解，见 `docs/14`）。
///
/// 【2026-10-15 甲方案】原先第一项「找陪玩」已**整个移除**（连同 `onFindPlayers` 参数）：
/// 该入口改由老板端服务页**顶部导航第一项**单一承担（负责人定案）。留在面板里就成了
/// **不显形的第二条路径**（要长按底栏凸起按钮才看得到），违反规则 1。
class AppQuickActionsSheet extends StatelessWidget {
  const AppQuickActionsSheet({
    super.key,
    required this.onMessages,
    required this.onSupport,
    required this.onOrder,
  });

  final VoidCallback onMessages;
  final VoidCallback onSupport;
  final VoidCallback onOrder;

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onMessages,
    required VoidCallback onSupport,
    required VoidCallback onOrder,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x780B1220),
      builder: (_) => AppQuickActionsSheet(
        onMessages: onMessages,
        onSupport: onSupport,
        onOrder: onOrder,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        title: '聊天记录',
        sub: '好友 / 客服 / 打手',
        icon: AppIcon.messages,
        // 方案 F 语义绑定：**好友私聊 = 品牌主蓝**（F 消息页「好友私聊」段用的就是主色系）；
        // 原值 `statusOnline`（青瓷/绿）会把"消息"染成"在线/安全"那一档
        color: AppColors.primary,
        tap: onMessages,
      ),
      (
        title: '联系客服',
        sub: '平均 5 分钟回复',
        icon: AppIcon.headset,
        // 方案 F 语义绑定：**客服 = 青** `#06B6D4`（F 稿「客服 24h」一律青系）。
        // 原值 `#7C3AED`（紫）在 F 里属于 **AI** 那一档 —— 留着就是"随机用色"。
        color: AppColors.accentSupport,
        tap: onSupport,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: T.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 14, 6, 10),
              child: Row(
                children: [
                  Text(
                    '快速入口',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: T.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Text(
                      '收起',
                      style: TextStyle(fontSize: 11.5, color: T.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
            ...items.map(
              (it) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      // 必须用**同步**的 pop()：maybePop() 内部 await willPop()，
                      // 而下一行会立刻 push 新页面 → 顶层路由变了，maybePop 会"忘掉这次 pop"
                      // （navigator.dart: lastEntry != newLastEntry → return），面板就永远留在栈里，
                      // 它的 ModalBarrier 会一直压在主框架上（返回后点不动底栏）。
                      // 面板自己就是被点的那个路由 → pop() 就是正确语义。
                      Navigator.of(context).pop();
                      it.tap();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.categorySoft(it.color),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            // 方案 F `.rc`：渐变圆角方块 + 白色镂空图标（色相按图标所属功能区取，
                            // 「同功能同色」由 `featureOfIcon` 保证，不再跟着行色随机变）
                            child: AppIconTile(
                              icon: it.icon,
                              size: 32,
                              radius: 10,
                              glyphSize: 17,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  it.title,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: T.textPrimary,
                                  ),
                                ),
                                Text(
                                  it.sub,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: T.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            AppIcon.chevronRight,
                            size: 15,
                            color: Color.lerp(it.color, Colors.white, .35),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            AppButton(
              label: '直接去下单',
              icon: AppIcon.bolt,
              onPressed: () {
                Navigator.of(context).maybePop();
                onOrder();
              },
            ),
          ],
        ),
      ),
    );
  }
}
