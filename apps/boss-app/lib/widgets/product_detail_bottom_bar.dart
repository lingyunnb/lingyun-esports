import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 商品详情页底部固定操作栏（设计稿 `.bar`，v2 方案 B）
///
/// ## 三个位置，各有理由
///
/// | 位置 | 是什么 | 为什么是它 |
/// |---|---|---|
/// | 左 1 | **客服**（真实会话入口） | 详情页是"下单前还在犹豫"的页面，客服是这一屏唯一能解决的疑问的出口 |
/// | 左 2 | **我的订单**（真实订单页） | 与客服并列：老用户点进来常常只是要去看上次的单 |
/// | 右 | **立即购买**（实色 #2563EB，高 44） | 首屏唯一的转换动作；**实色不用渐变** —— 与右下「下单」浮标同一句话（`AppOrderFab` 也是实色主色） |
///
/// **没有「店铺」**：结构规则 4（CLAUDE.md）—— 全站只有官方自营，不存在店铺概念，
/// 画一个点不动的店铺位属于"不存在的东西不出现"。
///
/// ## 尺寸取值（方案 G「交易链路」定案，2026-10-17）
/// - 整条 **76** = 顶 8 + 按钮 **48** + 底 20，上边 1px 描边 [AppColors.strokeSoft]（`#E8ECF2`）。
/// - 主按钮 **48 高**（方案 G 长条，高于 44 触控下限）+ 圆角 **12**（方案 G 允许的 999/12 二选一里
///   取 12：底栏是"通栏长条"，999 会让它在两侧屏幕上"收成一个球"，12 才有长条的直边感）、
///   字 15 w800 白字（`.bar .buy .lb`）。
/// - 图标位宽 **50**（`.bar .ic { width: 50px }`）、图标 21、标签 9.5。
///
/// 整条放进 `SafeArea(top: false)`：真机手势条不会压住按钮（设计稿的尺寸是不含系统 insets 的）。
class ProductDetailBottomBar extends StatelessWidget {
  const ProductDetailBottomBar({
    super.key,
    required this.onService,
    required this.onMyOrders,
    required this.onBuy,
  });

  /// 客服（真实会话入口）
  final VoidCallback onService;

  /// 我的订单（真实订单页）
  final VoidCallback onMyOrders;

  /// 立即购买；为 null 时按钮禁用（详情还没加载完）
  final VoidCallback? onBuy;

  /// 操作栏高度（不含系统手势条 insets）
  static const double barHeight = 76;

  /// 主按钮高度（方案 G 定案 48；测试与页面共用同一份数字）
  static const double buyHeight = 48;

  /// 主按钮圆角（方案 G：999 或 12 二选一 → 底栏长条取 12）
  static const double buyRadius = 12;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        // 方案 G 描边档（#E8ECF2）：底栏与内容区之间只留一条 1px 线
        border: Border(top: BorderSide(color: AppColors.strokeSoft)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: SizedBox(
            height: barHeight - 8,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _iconAction(icon: AppIcon.headset, label: '客服', onTap: onService),
                const SizedBox(width: 3),
                _iconAction(icon: AppIcon.orders, label: '我的订单', onTap: onMyOrders),
                const SizedBox(width: 8),
                Expanded(child: _buyButton()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconAction({required IconData icon, required String label, required VoidCallback onTap}) {
    return SizedBox(
      width: 50,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图标位固定 24 高：标签文字基线在三个位置间对齐，不随图标字体度量浮动
            SizedBox(height: 24, child: Center(child: AppIcon.of(icon, size: 21, color: T.textSecondary))),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, height: 1.2, color: T.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buyButton() {
    final disabled = onBuy == null;
    return Opacity(
      opacity: disabled ? .5 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onBuy,
          borderRadius: BorderRadius.circular(buyRadius),
          child: Container(
            height: buyHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // **实色主色**（不用渐变/不用青蓝渐变）：与右下「下单」浮标同一句话
              color: T.primary,
              borderRadius: BorderRadius.circular(buyRadius),
            ),
            child: const Text(
              '立即购买',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: .6),
            ),
          ),
        ),
      ),
    );
  }
}
