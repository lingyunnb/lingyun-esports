import 'package:flutter/material.dart';

import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';

/// 商品卡「徽标」（负责人 2026-10-05：「董事长推荐」这类，后台可配 badgeText）
///
/// ## 视觉取值与理由（docs/21 反 AI 味逐条对照）
///
/// | 取值 | 为什么是它 |
/// |---|---|
/// | 实色底 `#D97706`（琥珀金，= 全站价格/等级色） | docs/21 禁「渐变当主视觉」；琥珀金在本项目**已经有语义**（价格/等级＝价值与稀缺），推荐位复用它，用户不需要学新颜色 |
/// | 白字 10px / w700 | 徽标是**卡片附属信息**，字号必须小于商品名（13.5）和价格（15），不能抢主次 |
/// | 圆角 5（4–6 档） | docs/21「小控件 4–6」；胶囊全圆只给筛选条，徽标用方片才不像按钮 |
/// | padding 6×2 | 与全站标签同一套内边距（`AppTag`），四个字刚好 46pt 宽，不挤不空 |
/// | 无 emoji、无图标 | docs/21 禁 emoji 当图标；「董事长推荐」本身已经把意思说清 |
/// | **非空才渲染** | 留空 = 不显示（`SizedBox.shrink()`），后台清空文案后卡片自动回到普通样式 |
///
/// 徽标本体只负责「我是谁」，**突出明显**由卡片描边一起完成（见 [productCardBorder]）：
/// 单靠一个小片在长列表里不够跳，但也不能靠渐变/阴影/彩色堆砌（那是 AI 味），
/// 所以用「1px 琥珀金描边 + 左上角实色小片」这一对克制但成体系的信号。
class ProductBadge extends StatelessWidget {
  const ProductBadge(this.text, {super.key});

  /// 徽标文案（服务端 `badgeText`）；null / 空串 / 全空白 → 不渲染任何东西
  final String? text;

  /// 是否真的会渲染出徽标（页面需要在布局上留位置时用同一判定，避免"留了空位"）
  static bool shows(String? text) => text != null && text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final label = text?.trim() ?? '';
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.gold,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white, height: 1.25),
      ),
    );
  }
}

/// 商品卡描边：**有徽标的商品**换成 1px 琥珀金实线，其余保持全站默认发丝线
///
/// 只改描边颜色与 1px 宽度，不改圆角/底色/阴影 —— 卡片形态与列表其它项完全一致，
/// 「突出」靠一条线，不靠把卡片做成另一个物种（docs/21：卡片形态不要什么都塞进一样的圆角卡，
/// 但也不要用装饰代替结构）。
BoxBorder productCardBorder(String? badgeText) =>
    ProductBadge.shows(badgeText) ? Border.all(color: AppColors.gold, width: 1) : Border.all(color: T.divider);

/// 「每周限购」提示行（文案**全部来自服务端** `weeklyQuota` / `weeklyLimit`）
///
/// 客户端不拼规则、不算剩余：服务端说不限购（返回空文案且 weeklyLimit 为空/0）时，
/// 这里返回 `SizedBox.shrink()`，页面上不会有任何"限购"字样。
/// 颜色用次级灰而不是红色：**这是规则说明，不是错误**（错误态由服务端 400 文案承担）。
class WeeklyLimitNote extends StatelessWidget {
  const WeeklyLimitNote({super.key, this.limitText, this.quotaText});

  /// 服务端下发的规则文案（如「每周限购 2 单」）；空则不显示
  final String? limitText;

  /// 服务端下发的额度文案（如「本周还可下 2 单」/「本周额度已用完，下周再来」）；空则不显示
  final String? quotaText;

  @override
  Widget build(BuildContext context) {
    final limit = limitText?.trim() ?? '';
    final quota = quotaText?.trim() ?? '';
    if (limit.isEmpty && quota.isEmpty) return const SizedBox.shrink();
    final text = [limit, quota].where((e) => e.isNotEmpty).join(' · ');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon.of(AppIconsLegacy.event_available_outlined, size: 12, color: T.textTertiary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 2,
            style: TextStyle(fontSize: 11, height: 1.35, color: T.textSecondary),
          ),
        ),
      ],
    );
  }
}
