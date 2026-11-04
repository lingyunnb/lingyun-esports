import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';
import 'app_motion.dart';

/// ============ 详情页通用块（负责人 2026-10-05 商品详情页 v2 方案 B）============
///
/// 从设计稿 `site/design/product-detail-v2/b-restrained.html` 的 B 套元件逐值搬到 Flutter，
/// 放在 core 里是因为**两端都可能用**（老板端商品详情 / 工作端将来若要展示服务条款），
/// 且它们的视觉参数成套出现（小圆角 6 + 发丝线 + 冷灰蓝底），拆开各自实现必然走样。
///
/// ## 设计取值与理由（docs/21 反 AI 味逐条对照）
///
/// | 取值 | 为什么是它 |
/// |---|---|
/// | 圆角 **6**（`_kBlockRadius`，4–6 档） | docs/21「小控件 4–6」：这几块是**信息条/折叠行**，不是主卡；用 10/14 会把页面切成"一堆卡片"，与本方案「极简克制、少卡片」的取向相反 |
/// | **发丝线**分隔，无阴影铺满 | docs/21 禁阴影铺满卡片；块与块之间靠 1px `T.divider` + 冷灰蓝 `T.bgPage` 间隙分层 |
/// | 三列**左对齐**（不是居中） | docs/21「左对齐为主」；三列等宽 + 列间发丝线，扫读时标签列能对齐 |
/// | 提示条底 `#EFF6FF` = `T.ice`、字 `#1E40AF` | 与设计稿逐值一致；**全屏只有一个高饱和色**（主按钮蓝），提示条只用浅底 + 深蓝字，不抢主按钮 |
/// | 空态块**在冷灰底上**（`T.bgPage`） | 设计稿明确注记：空态里不做"白格子"，否则会在冷灰底上切出一条白带；只有发丝线 + 三列文字 |
/// | 无 emoji、无装饰性插画 | docs/21 硬规则；空态用 Material outlined 图标（[AppIcon.image]，与全站同一套线性图标体系） |

/// 这几块共用的圆角（4–6 档，见文件头说明）
const double _kBlockRadius = 6;

/// 折叠展开动效时长（与 `AppSegmented` 的 160ms 同一节奏；再长会显得"拖"）
const Duration _kFoldDuration = Duration(milliseconds: 160);

/// 三列数据行的一项（标签 + 值）。
///
/// `valueUnit` 与 `value` 分开放的理由：单位要用小一号、次级灰（设计稿 `.datarow .v small`），
/// 拼成一个字符串就没法只把"单/分钟"压小 —— 而"已售 0**单**"里那个"单"压小正是稿上的样子。
/// 不需要小号单位时留空，只用 `value`。
class AppDataItem {
  const AppDataItem({required this.label, required this.value, this.valueUnit = ''});

  /// 上方小标签（次级灰 10.5px）
  final String label;

  /// 主值（13px w800 深色）
  final String value;

  /// 值后面的小号单位（10.5px 次级灰）；空则不渲染
  final String valueUnit;
}

/// 三列通栏数据行（发丝线上下分界 + 列间竖线，左对齐）
///
/// 设计稿里两处形态（`.datarow.tight` 与 `.datarow`）只有内外边距不同，这里统一成
/// 「贴边（左右 16 由调用方或本组件处理）」。列数不写死 3 —— 传几项画几列，等宽均分。
class AppDataRow extends StatelessWidget {
  const AppDataRow({
    super.key,
    required this.items,
    this.padding = const EdgeInsets.fromLTRB(16, 11, 16, 12),
    this.showTopBorder = true,
    this.showBottomBorder = false,
  });

  final List<AppDataItem> items;

  /// 内容内边距（首列左 16 / 末列右 16 由它给，与页面左右边距对齐）
  final EdgeInsetsGeometry padding;

  /// 顶部发丝线（默认有：它与上方信息块分界）
  final bool showTopBorder;

  /// 底部发丝线（默认无：下方若要接浅底间隙，线是多余的）
  final bool showBottomBorder;

  @override
  Widget build(BuildContext context) {
    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Container(width: 1, color: T.divider),
            Expanded(child: _cell(items[i], padding: padding, first: i == 0, last: i == items.length - 1)),
          ],
        ],
      ),
    );
    if (!showTopBorder && !showBottomBorder) return row;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: showTopBorder ? BorderSide(color: T.divider) : BorderSide.none,
          bottom: showBottomBorder ? BorderSide(color: T.divider) : BorderSide.none,
        ),
      ),
      child: row,
    );
  }

  Widget _cell(AppDataItem item, {required EdgeInsetsGeometry padding, required bool first, required bool last}) {
    // 首列只留左内边距、末列只留右内边距：三列的**文字起点**分别落在页面 16 / 居中 / 右侧，
    // 与设计稿「左右贴页面边距」一致（若每列都吃满 16，中间列会被挤得比两侧窄，三列就不等宽了）
    final p = padding.resolve(TextDirection.ltr);
    return Padding(
      padding: EdgeInsets.only(left: first ? p.left : 12, right: last ? p.right : 12, top: p.top, bottom: p.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, height: 1.2, color: T.textTertiary),
          ),
          const SizedBox(height: 3),
          // 值可能很长（「手游 · 人工陪同」）：换行而不是省略号 —— 三列是**关键事实**，
          // 截成「手游 · 人工陪…」信息就废了；换行只让该列高一行，行高由 IntrinsicHeight 撑平
          Text.rich(
            TextSpan(
              text: item.value,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, height: 1.35, color: T.textPrimary),
              children: [
                if (item.valueUnit.isNotEmpty)
                  TextSpan(
                    text: ' ${item.valueUnit}',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: T.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 提示条（浅冰蓝底 + 发丝描边 + 圆角 6，一行说明）
///
/// 只做**说明**，不做错误/警告 —— 错误态由 `AppToast` / 表单内联错误承担（docs/14）。
/// 文案**一律由调用方从接口取**：本组件不生成任何业务文案（客户端禁硬编码规则）。
class AppNoticeBar extends StatelessWidget {
  const AppNoticeBar({super.key, required this.text, this.icon = AppIcon.info});

  /// 提示文案（服务端下发）
  final String text;

  /// 左侧线性图标（默认 info outlined）
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        color: T.ice,
        borderRadius: BorderRadius.circular(_kBlockRadius),
        border: Border.all(color: AppColors.primarySoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图标顶部对齐首行文字（1px 微调，与设计稿 `.nb-ic { margin-top: 1px }` 一致）
          Padding(padding: const EdgeInsets.only(top: 1), child: AppIcon.of(icon, size: 13, color: T.primary)),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 11.5, height: 1.6, color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 折叠行（标题 + 收起态一行摘要 + 展开正文）
///
/// 与设计稿 `.fold` 逐值对齐：白底、上下发丝线（展开后才有下边线）、标题 13.5 w800、
/// 摘要 11px 次级灰**单行省略**、右侧「展开/收起 + 箭头」用主色。
///
/// `children` 为空时退化成纯静态信息块（不显示展开动作）—— 避免出现"点了没反应"的假交互。
class AppFoldRow extends StatefulWidget {
  const AppFoldRow({
    super.key,
    required this.title,
    required this.collapsed,
    this.footer,
    this.initiallyExpanded = false,
    this.onChanged,
  });

  /// 标题（如「下单须知」）
  final String title;

  /// 收起态右侧的一行摘要（调用方从正文里取；**不**在此处做省略，组件自己单行截断）
  final String collapsed;

  /// 展开后的正文（如 `AppTermsList`）
  final Widget? footer;

  final bool initiallyExpanded;

  /// 展开态变化回调（测试与埋点用；页面自身状态由本组件持有）
  final ValueChanged<bool>? onChanged;

  @override
  State<AppFoldRow> createState() => _AppFoldRowState();
}

class _AppFoldRowState extends State<AppFoldRow> {
  late bool _open = widget.initiallyExpanded;

  void _toggle() {
    setState(() => _open = !_open);
    widget.onChanged?.call(_open);
  }

  @override
  Widget build(BuildContext context) {
    final canFold = widget.footer != null;
    return Container(
      decoration: BoxDecoration(
        // 底色必须写在 decoration 里：Container 的 color 与 decoration 互斥（同时给会断言失败）
        color: T.bgCardSolid,
        border: Border(
          top: BorderSide(color: T.divider),
          // 展开后补下边线（与上方线一起把这块圈住；收起态不画，否则会和下一块的顶线叠成 2px）
          bottom: _open ? BorderSide(color: T.divider) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: canFold ? _toggle : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: T.textPrimary),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.collapsed,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: T.textTertiary),
                    ),
                  ),
                  if (canFold) ...[
                    const SizedBox(width: 8),
                    Text(
                      _open ? '收起' : '展开',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: T.primary),
                    ),
                    const SizedBox(width: 3),
                    // 箭头随展开旋转（160ms，与全站折叠同一节奏）
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: _kFoldDuration,
                      curve: Motion.standard,
                      child: AppIcon.of(AppIcon.chevronDown, size: 15, color: T.primary),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (canFold)
            AnimatedSize(
              duration: _kFoldDuration,
              curve: Motion.standard,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: SizedBox(width: double.infinity, child: widget.footer),
                    )
                  : const SizedBox(width: double.infinity),
            ),
        ],
      ),
    );
  }
}

/// 条款列表（1. 2. 3. … 左序号 + 正文），序号由**本组件**排版
///
/// 为什么序号不给文案：运营在管理端编辑须知时不该自己数数（数错了页面就会出现「1. 1. xxx」）。
/// 服务端下发的须知按 `\n` 分条、条内**不写序号**，序号在这里统一生成。
class AppTermsList extends StatelessWidget {
  const AppTermsList({super.key, required this.items, this.fontSize = 12});

  /// 每条正文（已去掉序号）
  final List<String> items;

  /// 正文字号（折叠块内 12；独立小节 12.5）
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 序号列固定 14 宽（`.terms .li .n { min-width: 14px }`）：两位数也不会把正文推走
                SizedBox(
                  width: 14,
                  child: Text(
                    '${i + 1}.',
                    style: TextStyle(fontSize: fontSize, height: 1.8, fontWeight: FontWeight.w700, color: T.textTertiary),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    items[i],
                    style: TextStyle(fontSize: fontSize, height: 1.8, color: T.textSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 常见问题（4 条可展开；问句右侧 `+`，展开后变 `-` 且问句转主色）
///
/// 与 `AppFoldRow` 的差别：这里是**多条并列**、每条独立开合、问句之间用浅发丝线分界，
/// 且**答案不折叠时完全不占高度**（设计稿 `.fa { display: none }`）。
class AppFaqBlock extends StatelessWidget {
  const AppFaqBlock({super.key, required this.items, this.expanded = const <int>{}, this.onToggle});

  /// 问答对（问句 + 答案）
  final List<AppFaqItem> items;

  /// 当前展开的下标集合（由调用方持有，便于测试与"只展开一条"这类策略调整）
  final Set<int> expanded;

  final ValueChanged<int>? onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Container(
            decoration: BoxDecoration(
              border: Border(
                // 首条不画线（上面就是小节标题），其余在**上方**画线，与设计稿 `.faq-i { border-top }` 一致
                top: i == 0 ? BorderSide.none : BorderSide(color: AppColors.divider),
              ),
            ),
            padding: EdgeInsets.only(top: i == 0 ? 2 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (i > 0) const SizedBox(height: 0),
                _question(i),
                if (expanded.contains(i))
                  Padding(
                    padding: const EdgeInsets.only(left: 21, top: 6),
                    child: Text(
                      items[i].answer,
                      style: TextStyle(fontSize: 11.5, height: 1.75, color: T.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _question(int i) {
    final open = expanded.contains(i);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle == null ? null : () => onToggle!(i),
      child: Padding(
        // 命中区比文字高（问句是主要的点击目标，11.5px 字直接点太小）
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: AppIcon.of(open ? AppIcon.minus : AppIcon.plus, size: 13, color: T.primary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                items[i].question,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.5,
                  color: open ? T.primary : T.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条问答（[AppFaqBlock] 用）
class AppFaqItem {
  const AppFaqItem({required this.question, required this.answer});

  final String question;
  final String answer;
}

/// 分隔间隙（冷灰蓝 8dp，把上下两个白块分开；设计稿 `.gap { height: 8px; background: #F5F7FB }`）
class AppBlockGap extends StatelessWidget {
  const AppBlockGap({super.key, this.height = 8});

  final double height;

  @override
  Widget build(BuildContext context) => Container(height: height, color: T.bgPage);
}

/// 小节标题行（左标题 + 右侧说明，**左对齐**；设计稿 `.sec-l`）
///
/// 与既有 `AppSectionHeader` 的差别：这里是**白底块内的标题行**（无外间距、下间距小），
/// 带一个恒为小号灰的补充说明（如「管理端维护」「客服 9:00-次日 2:00 在线」）。
class AppBlockTitle extends StatelessWidget {
  const AppBlockTitle({super.key, required this.title, this.subtitle = ''});

  final String title;

  /// 标题右侧小字说明（次级灰 10.5）；空则不渲染
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: T.textPrimary)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: T.textTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 16:9 主图位**空态**（无封面图时用它，**不是空白、不是插画**）
///
/// 设计稿要求（`Z2-A-空态.png`）：一块**虚线** 16:9 位 + 说明"管理端还没上传商品图"，
/// 下面接三列**真实字段**。刻意不做插画、不做吉祥物、不做大图标（docs/21 禁装饰性插画）。
///
/// 为什么放在冷灰蓝底（`T.bgPage`）而不是白底：设计稿注记 —— 空态做成白格子会在冷灰底上
/// 切出一条白带，看起来像"图挂了"；用冷灰底 + 虚线框，读起来是"这里本来该有图"。
class AppEmptyMediaBlock extends StatelessWidget {
  const AppEmptyMediaBlock({
    super.key,
    this.height,
    this.aspectRatio = 16 / 9,
    this.icon = AppIcon.image,
    required this.title,
    this.subtitle = '',
  });

  /// 固定高度；为 null 时按 [aspectRatio] 撑高
  final double? height;

  final double aspectRatio;

  /// 顶部线性图标（默认图片图标，与列表卡封面占位同一套）
  final IconData icon;

  /// 主文案（如「管理端还没上传商品图」）
  final String title;

  /// 补充说明（如「这个商品只有文字配置；下面这些字段都是真实下发的值」）
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      color: T.bgPage,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon.of(icon, size: 30, color: T.textTertiary.withValues(alpha: .55)),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: T.textSecondary)),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: T.textTertiary),
            ),
          ],
        ],
      ),
    );

    final dashed = CustomPaint(
      // 虚线色比设计稿的 `#CBD5E1` 深一档（用全站占位灰 = `AppColors.textTertiary` `#94A3B8`）：设计稿是 1x 稿，
      // 真机 2~3x 下浅灰虚线在冷灰蓝页底上几乎不可见
      // （第一轮出图实测："空态看着就是一片空白"）。深一档后它仍是"占位框"的语气，
      // 不是边框强调 —— 不越过 docs/21 的克制线。
      painter: _DashedBorderPainter(color: AppColors.textTertiary, radius: _kBlockRadius),
      child: content,
    );

    // 虚线框内缩 12：虚线贴到屏幕边会像"页面画歪了"，内缩后它是明确的"图片占位"
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: height != null
          ? SizedBox(height: height, width: double.infinity, child: dashed)
          : AspectRatio(aspectRatio: aspectRatio, child: dashed),
    );
  }
}

/// 虚线圆角边框（空态主图位用；Flutter 没有内置虚线 Border，自绘一段一段短划线）
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  /// 单段实线长 / 间隔长（设计稿的虚线观感：短划 + 等距空隙）
  static const double _dash = 5;
  static const double _gap = 4;

  /// 描边粗细
  ///
  /// 设计稿写的是 1px，但那是 **1x 稿**：真机 2~3x 下 1px 虚线在 `#F5F7FB` 冷灰底上
  /// 几乎不可见（第一轮出图实测："空态看着就是一片空白"）。1.4 在 2x/3x 下落在
  /// "能看见但不抢" 的区间 —— 它仍是一条占位提示线，不是边框强调。
  static const double _stroke = 1.4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    final inset = _stroke / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(inset, inset, size.width - _stroke, size.height - _stroke),
      Radius.circular(radius),
    );
    // 沿圆角矩形路径按「实线段 / 空隙」交替取子路径（Flutter 无内置虚线 Border）
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color || old.radius != radius;
}
