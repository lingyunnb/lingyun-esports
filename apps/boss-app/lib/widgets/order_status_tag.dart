import 'package:flutter/material.dart';

import 'package:fish_core/fish_core.dart';

/// 订单状态标签（订单列表/详情共用）
///
/// ## 为什么单独成文件
/// 1. **可测**：`_OrdersPageState` 里的私有方法测不到，而"9 种状态是否真的两两可分"
///    是本功能的核心验收点 —— 抽成公开 API 才能写断言（见 `test/order_status_tag_test.dart`）。
/// 2. **可复用**：订单详情页要画同一枚标签，不该复制第二份实现。
///
/// ## 「不只靠颜色」的四条信号（`docs/21` 硬要求）
/// 每枚标签同时带：
/// | 信号 | 做法 |
/// |---|---|
/// | ① 图标 | 9 种状态**各不同**（同档内也不重复） |
/// | ② 形状 | 实色 vs 浅底 / **右上 6×6 斜切角** / 异常与售后档描边加粗（1dp→2dp） |
/// | ③ 字重 | 600 / 700 / 800 三档 |
/// | ④ 颜色 | 五档色族 |
/// → 整屏**去色后仍能两两区分**。
///
/// 规格对齐设计稿 `site/design/white-first/03-order.html` 的 `.stag`：
/// 高 **24** · 字号 **11** · 内距 **0/8** · 图标与文字间距 **4** · 圆角 **4** · 描边 1dp。

/// 状态标签的视觉档（数据载体）
class OrderStatusStyle {
  const OrderStatusStyle({
    required this.fg,
    required this.bg,
    required this.border,
    required this.weight,
    required this.icon,
    this.borderWidth = 1,
  });

  /// 前景（文字与图标同色）
  final Color fg;

  /// 底
  final Color bg;

  /// 描边
  final Color border;

  /// 字重（600 / 700 / 800）
  final FontWeight weight;

  /// 图标（去色后的第一重信号）
  final IconData icon;

  /// 描边宽度（异常 1dp / 售后 2dp —— 去色后的第三重信号）
  final double borderWidth;
}

/// 9 种状态 → 视觉档。取值来自 `server/src/modules/order/order.entity.ts` 的 `OrderStatus`。
///
/// **必须列全 9 种**：旧实现只认 4 种，`pending_dispatch / taken / in_progress /
/// abnormal / after_sale` 全落到"主色"——**「异常」与「售后」被画成了和「进行中」一样的颜色**，
/// 这是"状态只靠颜色"里最危险的一种：**把需要人处理的事画成了正常的事**。
///
/// 五档设计：
/// - ① **待处理**（amber 浅底 700）：需要平台/打手动 → 暖色
/// - ② **进行中**（品牌实色 白字 700）：**全页唯一实色档** → 一眼看出"这单在跑"
/// - ③ **已完成**（celadon 浅底 700）：青瓷=品牌强调里的"成功"
/// - ④ **中性终态**（灰 600）：取消是正常终态，**不是错误**（旧实现给了红色，整页像在报警）
/// - ⑤ **异常 / 售后**（红浅底 700／描边 2dp + 800）：售后比异常**再重一档**
///
/// ## 描边色为什么仍是字面色值（2026-10-15 品牌化**未收口**项，已上报）
/// 描边要的是"**浅底再深一档的同族色**"（amber / celadon / red 三族的中间色）。
// 状态标签的 6 个浅描边/中性底色值已收口到 `AppColors.status*` token（2026-10-15）。
// 原先它们是本文件里手写的 `const Color(0x…)`，值无法由既有 token 推导
// （实测 `Color.lerp` 遍历全部组合差 3–100+ 通道），且测试把 `#F0F2F5` 写进了断言 ——
// 于是"改上屏颜色"与"打挂断言"是同一个动作。收口后改色只需改一处 token。
OrderStatusStyle orderStatusStyleFor(String status) {
  switch (status) {
    // ---- ① 待处理档 ----
    case 'pending_take':
      return OrderStatusStyle(
        fg: AppColors.warning, bg: AppColors.statusBusySoft, border: AppColors.statusWarnBorder,
        weight: FontWeight.w700, icon: AppIconsLegacy.schedule,
      );
    case 'pending_dispatch':
      return OrderStatusStyle(
        fg: AppColors.warning, bg: AppColors.statusBusySoft, border: AppColors.statusWarnBorder,
        weight: FontWeight.w700, icon: AppIconsLegacy.hourglass_empty,
      );
    case 'pending_confirm':
      return OrderStatusStyle(
        fg: AppColors.warning, bg: AppColors.statusBusySoft, border: AppColors.statusWarnBorder,
        weight: FontWeight.w700, icon: AppIconsLegacy.help_outline,
      );
    // ---- ② 进行档（唯一实色）----
    case 'taken':
      return const OrderStatusStyle(
        fg: Colors.white, bg: AppColors.primary, border: AppColors.primary,
        weight: FontWeight.w700, icon: AppIconsLegacy.check,
      );
    case 'in_progress':
      return const OrderStatusStyle(
        fg: Colors.white, bg: AppColors.primary, border: AppColors.primary,
        weight: FontWeight.w700, icon: AppIconsLegacy.bolt,
      );
    // ---- ③ 完成档 ----
    case 'completed':
      return OrderStatusStyle(
        fg: AppColors.success, bg: AppColors.statusOnlineSoft, border: AppColors.statusOkBorder,
        weight: FontWeight.w700, icon: AppIconsLegacy.check_circle,
      );
    // ---- ④ 中性终态档 ----
    case 'canceled':
      return OrderStatusStyle(
        fg: AppColors.textSecondary, bg: AppColors.statusNeutralBg, border: AppColors.statusNeutralBorder,
        weight: FontWeight.w600, icon: AppIconsLegacy.block,
      );
    // ---- ⑤ 异常 / 售后档 ----
    case 'abnormal':
      return OrderStatusStyle(
        fg: AppColors.error, bg: AppColors.dangerSoft, border: AppColors.statusBadBorder,
        weight: FontWeight.w700, icon: AppIconsLegacy.error_outline,
      );
    case 'after_sale':
      return OrderStatusStyle(
        fg: AppColors.error, bg: AppColors.dangerSoft, border: AppColors.statusAfterSaleBorder,
        weight: FontWeight.w800, icon: AppIconsLegacy.report_gmailerrorred, borderWidth: 2,
      );
    // 兜底：服务端将来新增状态时用中性档 —— 不冒充"正常"，也不冒充"报警"
    default:
      return OrderStatusStyle(
        fg: AppColors.textSecondary, bg: AppColors.statusNeutralBg, border: AppColors.statusNeutralBorder,
        weight: FontWeight.w600, icon: AppIconsLegacy.circle_outlined,
      );
  }
}

/// 状态标签（高 24 / 字 11 / 内距 0·8 / 图标文字间距 4 / 圆角 4 / 右上斜切角）
///
/// ## 2026-10-15「全平台品牌化」：几何**接入品牌装饰系统的斜切角谱系**（扩展，不是另写）
///
/// 本标签是斜切角语言的**源头**，所以这一步只做"登记 + 收口"，不改任何语义：
/// - 高度 [tagHeight]=24、圆角 4、内距 0·8、图标 12、字重 600/700/800 与五档色族**逐字不变**
///   （`order_status_tag_test.dart` 的 15 条断言全部继续成立）；
/// - 右上切口从"手写的 6×6 + 手写两条边"改为 [AppNotch.forRole]`(AppNotchRole.statusTag)`：
///   谱系表里 `高 24 → 6×6`（`AppNotch.sizeForHeight` 推导），与 `deco.dart` 的
///   `AppNotched` / `AppContentCard` / `AppEmptyDeco` / `AppLevelSlot` **共用同一个类与同一条口径** ——
///   这样"状态标签的角"与"卡片左下角 / 空态图标框角 / 等级位角"在程序上**不可能各说各话**；
/// - 四重信号（图标 / 形状 / 字重 / 颜色）一条没少：切口只画两条边、不外扩，
///   去色后仍靠"图标 + 字重 + 描边宽 + 实色/浅底"两两可分（这是 `docs/21` 铁律）。
class OrderStatusTag extends StatelessWidget {
  const OrderStatusTag({
    super.key,
    required this.status,
    required this.label,
    this.surfaceColor,
  });

  /// 服务端状态码（`order.entity.ts` 的 OrderStatus）
  final String status;

  /// 服务端下发的中文状态名（`OrderBrief.statusName`）
  final String label;

  /// 标签底下那层的**实底颜色**（切口会把这一角"挖掉"，露出的必须是底层的真实颜色）。
  ///
  /// 不传 = 沿既有行为取 `T.bgCardSolid`（白卡面）。放进通栏 ListCard 这类
  /// "不是纯白"的底时由调用方传入，避免切口处出现一个比底层更白的方块。
  final Color? surfaceColor;

  /// 标签高 24（= 斜切角谱系里"高 20–24 → 6×6"的上一档）
  static const double tagHeight = 24;

  /// 圆角 4（沿用设计稿 `.stag`；与 `AppDecoRadius.tag` 同值）
  static const double tagRadius = AppDecoRadius.tag;

  /// 切口档位：`AppNotchRole.statusTag` = 高 24 / 6×6 / 右上（由 `deco.dart` 登记，测试钉住）
  static const AppNotchRole notchRole = AppNotchRole.statusTag;

  @override
  Widget build(BuildContext context) {
    final s = orderStatusStyleFor(status);
    // 底：调用方给就用给的（通栏 ListCard 这类非纯白底），否则沿既有行为取白卡面。
    // 为什么需要它：切口那 6×6 是**用底色盖出来的**，底色取错就会在角上留一个"更白的补丁"。
    final surface = surfaceColor ?? T.bgCardSolid;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          height: tagHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: s.bg,
            borderRadius: BorderRadius.circular(tagRadius),
            border: Border.all(color: s.border, width: s.borderWidth),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon.of(s.icon, size: 12, color: s.fg),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: s.weight, color: s.fg, height: 1),
              ),
            ],
          ),
        ),
        // 右上斜切角：走谱系档位 AppNotchRole.statusTag（高 24 → 6×6）。
        // 实现仍是「底色盖角 + 只画两条边」（不 ClipPath 真裁：真裁会切断描边、留缝）。
        Positioned(
          right: 0,
          top: 0,
          child: AppNotch.forRole(
            notchRole,
            baseColor: surface,
            borderColor: s.border,
            borderWidth: s.borderWidth,
          ),
        ),
      ],
    );
  }
}
