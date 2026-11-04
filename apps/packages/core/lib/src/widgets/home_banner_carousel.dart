import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';
import 'cached_image.dart';

/// 首页宣传图轮播（设计稿 `site/design/home-banner/c-immersive.html` 方案 C「顶部通栏沉浸」）
///
/// ## 位置与框体（照稿；圆角 2026-10-14 定为 0；高度 2026-10-16 二次定案 = 恒 156）
/// - 紧贴顶部导航正下方、**三宫格（分部卡）之前**（负责人已明确认可这次例外）
/// - 满宽、**左右 0 边距**、**高度恒 [height] = 156dp**（设计稿 390 : 156 ≈ 2.5 : 1），
///   与图片真实宽高比**无关**（图片尺寸有值、没值、脏值，高度都是 156）。
/// - 图片用 **`BoxFit.fill`（拉伸铺满）**：整张图都看得见、不裁切。
///
///   ⚠️ 这段口径在 2026-10-16 当天改过两轮，别再改回去：
///   ① 最初写死 156 + `cover` → 运营的 1920×1080（16:9）图上下各裁一块；
///   ② 随后改成**框体按图比例定高**（16:9 → 219.375dp）+ `cover` → 负责人复核后原话
///      「图片展示大小**还是原来的**、上传的图片**自动拉伸**，现在改完之后的**太大了**」；
///   ③ **当前 = ① 的框体（恒 156）+ `fill`**：框体尺寸保持"原来的"，改的只是图片怎么填进去。
///   ⚠️ 代价（负责人已知情并在这几个方案里选定了它）：`fill` 会**拉伸变形** ——
///   1.78 : 1 的图塞进 ≈2.5 : 1 的框 → **纵向压扁约 29%**，图上的**文字会一起被压扁**。
///   备选（负责人反悔时用）：① 156 + `contain`（不变形，但左右/上下露页面底色边）；
///   ② 按图比例定高（= 上面的 ②，219.375dp：不变形不裁切，但框体更高）。
/// - 圆角 [radius] = **0（通栏直角）**：见 [radius] 的取值理由（负责人 2026-10-14「把圆角去掉」）
///
/// ## 为什么满宽 + 左右 0 边距（决策与理由）
/// 设计稿的整条理由链是"顶部导航自带 16dp 左右内边距，通栏**直接接上**才不会出现
/// '一条 10pt 的灰缝把活动位和导航切开'"。若给通栏补 16dp 左右边距：
/// ① 页面背景（`#F5F7FB` 冷灰蓝）会在左右两侧各露一条 16dp 竖边，
///    通栏视觉上退回"一张大卡片"，于是 156 高的大图与紧跟其后的三宫格卡片挤在同一段
///    留白节奏里，"沉浸"这个方案的全部意义（与导航连成一块）就没了；
/// ② 与"上接导航 0 间距"这个已经定下的规则**互相矛盾** —— 左右缩进、上下却要贴死，
///    四个边里三个是通的、两个是断的，说不出统一规则。
/// 因此这里选 **满宽 + 左右 0 + 只加圆角**：圆角负责"柔和"，通栏负责"沉浸"，
/// 两者不冲突（圆角是四角的处理，不是边距的处理）。
///
/// ## 空态（硬要求）
/// 管理端一张都没配 → **零占位**：整块直接 `SizedBox.shrink()`，
/// 不显示灰块、不显示"暂无活动"、不占高度。列表里"这一项不存在"而不是"这一项是空的"。
///
/// ## 指示器（照稿）
/// 图内底部居中、细短条：选中 14 × 3 实色白、未选中 6 × 3 半透明白（`rgba(255,255,255,.55)`）。
/// **只有 ≥2 张才显示**（1 张时不渲染指示器 —— 单张图没有"第几张"的信息量）。
///
/// ## 自动播放 / 循环（按负责人要求，默认最保守）
/// - 自动播放 **[autoPlay] = false 默认关闭**：视频无法证实自动播放体验（看不清用户是不是
///   正在读这张活动图），后台可开；开启后每 [autoPlayInterval] 秒前进一张，
///   **到末张停住**（不循环）。
/// - 循环 **[loop] = false 默认不循环**：运营把 3 张按优先级排好，转一圈回到第 1 张
///   会让"最重要的那张"被反复顶到用户面前，反而像广告轰炸。
class HomeBannerCarousel extends StatefulWidget {
  const HomeBannerCarousel({
    super.key,
    required this.items,
    this.onTap,
    this.autoPlay = false,
    this.loop = false,
    this.autoPlayInterval = const Duration(seconds: 4),
    this.frameHeight,
    this.frameRadius = HomeBannerCarousel.radius,
    this.ctaLabel = '',
  });

  /// 宣传图列表（服务端 `GET /public/banners` 已按 `sortOrder` 排好序，客户端不再排）
  final List<HomeBannerItem> items;

  /// 点击某一张（null = 不做任何事；页面注入时按 `linkType` 分发）
  final ValueChanged<HomeBannerItem>? onTap;

  /// 自动播放（**默认关闭**，后台可开）
  final bool autoPlay;

  /// 是否循环（**默认不循环**）
  final bool loop;

  final Duration autoPlayInterval;

  /// **框体高度覆盖**（null = 用 [HomeBannerCarousel.height] = 156，**逐像素与改动前一致**）
  ///
  /// 2026-10-17「方案 G 首页」新增：稿内首页宣传图是 **16:9 通栏**（390 × 219.375），
  /// 而本组件的历史定案（2026-10-16 负责人二次定案）是**恒 156**。两者都要成立 → 只开一个
  /// **可选**参数：
  /// - 不传（默认）：恒 156，行为与既有出图/几何用例**逐像素相同**
  ///   （core 的 `banner_aspect_ratio_test` / `banner_carousel_test` / `banner_refresh_ttl_test`
  ///   都是在断言 156）；
  /// - 传了：老板端首页按 16:9 传入（见 `services_page.dart` 的 `bannerHeightOf`）。
  ///
  /// 为什么不做成"自动按图比例"：图片比例由运营上传决定（9:16 竖图会 693dp 吃光首屏），
  /// 而这里要的是**与图无关的固定框体** —— 16:9 是框体的比例，不是图片的比例。
  final double? frameHeight;

  /// **框体圆角覆盖**（默认 [HomeBannerCarousel.radius] = 0，逐像素与改动前一致）
  ///
  /// 2026-10-18「首页大改」新增：负责人给的参考图里，轮播是**大圆角卡片**（左右各留页边、
  /// 四角 16），而本组件的历史定案是**通栏直角**。两者都要成立 → 只开一个**可选**参数：
  /// - 不传（默认 0）：通栏直角，core 的 `banner_carousel_test` / `banner_aspect_ratio_test`
  ///   对 `HomeBannerCarousel.radius == 0` 的断言**一行不用改**；
  /// - 传了：老板端首页传 16（卡片化），遮罩/文案/指示器几何全部随框体圆角一起裁切。
  final double frameRadius;

  /// **图上右下角的胶囊行动点文案**（空串 = 不渲染，默认空）
  ///
  /// 参考图的活动图上有一个「进入服务」胶囊按钮。它**不是第二个跳转目标**：
  /// 整张卡（含这枚胶囊）共用同一个 [onTap] —— 胶囊是"这里可以点"的可见提示，
  /// 不会出现"点图跳 A、点胶囊跳 B"的两套语义。
  final String ctaLabel;

  /// 框体高度：**恒 156dp**（设计稿 390 : 156 ≈ 2.5 : 1）
  ///
  /// 【2026-10-16 负责人二次定案】原话「图片展示大小**还是原来的**、上传的图片**自动拉伸**，
  /// 现在改完之后的**太大了**」→ 框体**退回这个固定值**。当天早些时候曾把它降级为
  /// "无尺寸时的回落值"、让框体跟着图片真实宽高比走（1920×1080 → 219.375dp），**已被这轮推翻**：
  /// 框体尺寸保持"原来的"，改的是图片怎么填进去（[BoxFit.fill]，见 `_image`）。
  ///
  /// 因此**框体与图片尺寸彻底解耦**：`imageWidth/imageHeight` 有值 / 没值 / 是脏值，
  /// 高度都是 156 —— 运营换任何比例的图都不会再把首屏撑高或压矮
  /// （旧口径里"9:16 竖图 693dp 吃光首屏、5:1 横条 78dp 压住文案"那一类风险随之消失，
  /// 原来给它们兜底的 `minAspectRatio` / `maxAspectRatio` 钳制与 `aspectRatioOf()` 已整体删除）。
  static const double height = 156;

  /// 圆角：**0（通栏直角）**
  ///
  /// ⚠️ **2026-10-14 负责人修订**：「把圆角去掉」→ 由 **10 改为 0**。
  ///
  /// 取代此前「加一点圆角」的口径，理由（三条）：
  /// - **语义矛盾**：这张图上方**0 间距贴死导航**（既定规则），左右也是满宽；
  ///   只有四角是圆的 → 三个边通、圆角处却把页面底色（`#F5F7FB`）露出来，
  ///   视觉上自动"缩"成一张大卡片，"通栏沉浸"的意义被抵消；
  /// - **层次反而更清楚**：直角让图**真正通栏**，与紧随其后的三宫格卡片形成
  ///   「通栏大图 vs 卡片」的明确对比 —— 这正是负责人要的首页层次；
  /// - **与卡片语言不再打架**：全 App 的圆角语言是给**卡片/控件**用的，
  ///   通栏大图不参与那套语言（此前取 10 的理由是"别与卡片语言脱节"，实测反而更含混）。
  ///
  /// 保留 [radius] 常量（而非删掉圆角代码）：换回圆角只需改这一个值，
  /// `DecoratedBox` / `ClipRRect` 的调用路径一字不动，零结构改动。
  static const double radius = 0;

  /// 图片上文字遮罩：底部 72dp 从透明渐到 `rgba(15,23,42,.42)`
  ///
  /// 设计稿的活动图是纯色底、文字天然可读；真实运营图（照片/亮色海报）不能保证这一点，
  /// 白色标题压在亮图上会直接看不见。遮罩只在下半部分，且**不改变任何布局**，
  /// 是"照稿 + 真实数据可用"的最小妥协。
  static const double scrimHeight = 72;

  // ---- 指示器（照稿：图内底部居中细短条） ----

  /// 选中条宽（14 × 3 实色白）
  static const double indicatorActiveWidth = 14;

  /// 未选中条宽（6 × 3 半透明白 `rgba(255,255,255,.55)`）
  static const double indicatorWidth = 6;

  /// 条高
  static const double indicatorHeight = 3;

  /// 条底边距图片底边的距离（照稿 `bottom: 10`）
  static const double indicatorBottom = 10;

  /// 条间距（照稿 `gap: 4` → 两侧各 2）
  static const double indicatorGap = 2;

  @override
  State<HomeBannerCarousel> createState() => _HomeBannerCarouselState();
}

class _HomeBannerCarouselState extends State<HomeBannerCarousel> {
  final PageController _controller = PageController();
  int _page = 0;
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  @override
  void didUpdateWidget(covariant HomeBannerCarousel old) {
    super.didUpdateWidget(old);
    if (old.items.length != widget.items.length || old.autoPlay != widget.autoPlay) {
      _autoTimer?.cancel();
      _autoTimer = null;
      if (_page >= widget.items.length) _page = 0;
      _startAutoPlay();
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 自动播放：到末张**停住**（不循环）
  void _startAutoPlay() {
    if (!widget.autoPlay || widget.items.length < 2) return;
    _autoTimer = Timer.periodic(widget.autoPlayInterval, (_) {
      if (!mounted || !_controller.hasClients) return;
      final last = widget.items.length - 1;
      final next = _page >= last ? (widget.loop ? 0 : last) : _page + 1;
      if (next == _page) return; // 已在末张且不循环 → 不再动
      _controller.animateToPage(next, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 空态：零占位（连高度都不占）
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final stack = Stack(
      children: [
        PageView.builder(
          controller: _controller,
          itemCount: widget.items.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (context, i) => _buildPage(widget.items[i], dpr),
        ),
        // 指示器：仅 ≥2 张（1 张时不渲染）
        //
        // 定位基准一直是**框体底边**：`Positioned(bottom: …)` 相对的是这个 `Stack` 的底边，
        // 而 Stack 由下面的框体 `SizedBox(156)` 定高 —— 距底恒 10dp。底部遮罩同理（`bottom: 0`）。
        if (widget.items.length > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: HomeBannerCarousel.indicatorBottom,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.items.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: HomeBannerCarousel.indicatorGap),
                    constraints: BoxConstraints(
                      minWidth: i == _page
                          ? HomeBannerCarousel.indicatorActiveWidth
                          : HomeBannerCarousel.indicatorWidth,
                      maxWidth: i == _page
                          ? HomeBannerCarousel.indicatorActiveWidth
                          : HomeBannerCarousel.indicatorWidth,
                      minHeight: HomeBannerCarousel.indicatorHeight,
                      maxHeight: HomeBannerCarousel.indicatorHeight,
                    ),
                    decoration: BoxDecoration(
                      color: i == _page ? Colors.white : const Color(0x8CFFFFFF),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    // 框体定高：**默认恒 156**（三轮口径的来龙去脉见 [HomeBannerCarousel.height]）。
    // 这里已经没有 AspectRatio 分支 —— 图片尺寸（有 / 无 / 脏值）都不影响框体，
    // 于是恒走这个 SizedBox（与"高度跟图走"那版相比，只少了那一行三目表达式）。
    // 2026-10-17：框体允许由调用方覆盖（方案 G 首页传 16:9）；不传时**逐像素不变**。
    final frame = widget.frameHeight ?? HomeBannerCarousel.height;
    return SizedBox(height: frame, child: stack);
  }

  Widget _buildPage(HomeBannerItem item, double dpr) {
    final content = Stack(
      fit: StackFit.expand,
      children: [
        _image(item, dpr),
        // 文字遮罩（真实运营图的可读性兜底；不影响布局）
        if (item.title.isNotEmpty || item.subtitle.isNotEmpty)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: HomeBannerCarousel.scrimHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x000F172A), Color(0x6B0F172A)],
                ),
              ),
            ),
          ),
        // 文案：左下对齐（docs/21：左对齐为主，不做居中对称）
        if (item.title.isNotEmpty || item.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 22),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.title.isNotEmpty)
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1.25,
                    ),
                  ),
                if (item.subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Color(0xD9FFFFFF), height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
        // 图片缺失时的兜底图标（管理端只配了标题没配图 → 仍是可点的活动位，不白屏）。
        // 出图/演示传入 [HomeBannerItem.placeholderGradient] 时不画它 —— 那是在模拟"有图"。
        if (!item.hasImage && item.placeholderGradient == null)
          Center(
            child: AppIcon.of(AppIcon.image, size: 26, color: const Color(0x66FFFFFF)),
          ),
        // 右下角胶囊行动点（默认空串 → 一个像素都不占）。与整张卡共用 [onTap]。
        if (widget.ctaLabel.trim().isNotEmpty)
          Positioned(
            right: 12,
            bottom: 12,
            child: _cta(),
          ),
      ],
    );

    final wrapped = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.frameRadius),
        // 图未加载出来时的底：默认主色浅档（避免"白闪"）；出图可传渐变模拟真实海报
        gradient: item.placeholderGradient,
        color: item.placeholderGradient == null ? T.primarySoft : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.frameRadius),
        child: content,
      ),
    );

    if (widget.onTap == null) return wrapped;
    return GestureDetector(
      // 只认 tap：横向拖动留给 PageView（手势竞技场里 drag 胜出后 tap 被取消）
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap!(item),
      child: wrapped,
    );
  }

  /// 右下角胶囊行动点（文案来自 [ctaLabel]）
  ///
  /// 它是**可见的点击提示**，不是独立按钮：点击落到外面那层 `GestureDetector`（整卡同一个 onTap）。
  /// 用实色主色 + 白字：压在任意运营海报上都能读清（半透明底在浅色图上会糊掉）。
  Widget _cta() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: T.primary,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        widget.ctaLabel,
        maxLines: 1,
        softWrap: false,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _image(HomeBannerItem item, double dpr) {
    final url = item.imageUrl.startsWith('http')
        ? item.imageUrl
        : (item.imageUrl.isNotEmpty ? AppConfig.resolveMediaUrl(item.imageUrl) : item.mediaUrl);
    if (url.isEmpty) return const SizedBox.shrink();
    return CachedNetImage(
      url: url,
      /**
       * **拉伸铺满**（2026-10-16 负责人二次定案原话：「上传的图片**自动拉伸**」）
       *
       * `BoxFit.fill` = 不保持宽高比、横纵各自缩放到框体尺寸 → **整张图都看得见、不裁切**
       * （旧的 `cover` 在 156 高的框里会把 16:9 的图上下各裁掉约 29%）。
       *
       * ⚠️ 代价（负责人已知情并选定）：图会被**拉伸变形** —— 1920×1080（1.78 : 1）
       * 塞进 156/390 ≈ 2.5 : 1 的通栏框，**纵向压扁约 29%**，图上的**文字会一起被压扁**
       * （线上那两张就有「祁连山电竞 小云本人：3989032757」这类文字）。
       * 不变形的两个备选见文件顶部的框体说明（156 + `contain` / 按图比例定高 219dp）。
       */
      fit: BoxFit.fill,
      /**
       * **换图时旧图留屏上**（负责人 2026-10-16「不要在等转圈」的第二处）。
       *
       * 运营换完图后 `mediaId` 会变 → 新地址没进磁盘缓存 → 默认行为是把已加载的文件丢掉、
       * 回到占位块，而占位块在下载中是**整条通栏的灰块 + 转圈**（`cached_image.dart` 的
       * placeholder 分支）。通栏图是首屏最大的一块，那个转圈在小带宽下会停好几秒。
       *
       * 打开这个开关后：旧图继续留屏上（同一位置、同一 `BoxFit.fill`），新图就绪后**静默替换**
       * —— 用户感知是"图变了"，不是"图没了又回来"。新图真失败时仍会落到失败/占位分支
       * （不会永远拿旧图糊住，见该参数的文档）。
       */
      keepPreviousOnUrlChange: true,
      // 按显示宽度 × 像素比解码：满宽 390 × dpr，别按原图 1080 宽解码（省内存也省一次缩放）
      cacheWidth: (MediaQuery.of(context).size.width * dpr).round(),
    );
  }
}

/// 宣传图数据项（`GET /public/banners` 单条）
///
/// 客户端只做展示与"点了去哪"的分发，**不含任何业务判定**：
/// 上下架、投放时间区间全部由服务端过滤（见 `HomeService.publicBanners`）。
class HomeBannerItem {
  const HomeBannerItem({
    required this.id,
    this.title = '',
    this.subtitle = '',
    this.imageMediaId,
    this.imageUrl = '',
    this.imageWidth,
    this.imageHeight,
    this.linkType = BannerLinkType.none,
    this.linkValue = '',
    this.placeholderGradient,
  });

  final String id;
  final String title;
  final String subtitle;

  /// 图片媒体 id（走 `/media/public/:id`，阶段 13 起的正规通道）
  final String? imageMediaId;

  /// 图片 URL（历史兼容字段；新数据为空串）
  final String imageUrl;

  /**
   * 图片**原始**宽 / 高（像素；服务端 2026-10-16 起随宣传图下发，来自 `media.width` / `media.height`）
   *
   * ⚠️ **当前渲染不用**（框体恒 [HomeBannerCarousel.height] = 156，图片走 [BoxFit.fill] 拉伸铺满，
   * 与比例无关）—— **保留以便回退**：服务端继续返回、[fromJson] 继续解析、[aspectRatio] 继续给值；
   * 将来若又要做"框体按图比例定高"，不必重新加字段与解析链路（删字段还会连锁改一堆测试）。
   * 服务端在**媒体缺失 / 尺寸未登记**时给 `null`，客户端解析时再兜一层：
   * 非数、`null`、`0`、负数一律归 `null`（口径与服务端 `HomeService` 的清洗一致）。
   */
  final int? imageWidth;
  final int? imageHeight;

  final BannerLinkType linkType;

  /// 跳转值（按类型：商品 id / 分部 id / 公告 id / 外链地址；none 时为空）
  final String linkValue;

  /// 是否配了图（两个字段任一有值）。都没配 → 只画兜底图标 + 文案，不做白屏
  bool get hasImage => (imageMediaId != null && imageMediaId!.isNotEmpty) || imageUrl.isNotEmpty;

  /**
   * 图片真实宽高比（`w / h`）——**未钳制**的原始值；`null` = 没有可用尺寸
   *
   * ⚠️ **当前渲染不用**（框体恒 156，与图片比例无关；配套的框体钳制 `aspectRatioOf()` 与
   * `minAspectRatio` / `maxAspectRatio` 已随口径改回而删除，见 [HomeBannerCarousel.height]）。
   * 保留它以配合上面两个字段的"保留以便回退"：它是"尺寸字段解析是否正确"的可断言入口
   * （脏值一律 `null`，见 banner_aspect_ratio_test.dart），也是将来回退"按比例定高"的缺件。
   */
  double? get aspectRatio {
    final w = imageWidth;
    final h = imageHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  /// **出图/演示用**：无图时的底（`null` = 走默认主色浅档）
  ///
  /// 只影响"两个图片字段都空"的那一格：真实运营图会盖住它。
  /// 用途是让设计稿/回归出图里能画出"有图"的样子，而不必往仓库塞测试图片资源。
  final Gradient? placeholderGradient;

  /// 图片地址：`imageMediaId` 优先，其次 `imageUrl`
  String get mediaUrl =>
      imageMediaId == null || imageMediaId!.isEmpty ? '' : AppConfig.resolveMediaUrl('/media/public/$imageMediaId');

  /// 正整数才认（`null` / 非数 / `0` / 负数 → `null`，与 `HomeService` 服务端清洗口径一致）
  static int? _positiveInt(Object? raw) {
    if (raw == null) return null;
    final n = raw is num ? raw.toInt() : int.tryParse('$raw'.trim());
    if (n == null || n <= 0) return null;
    return n;
  }

  factory HomeBannerItem.fromJson(Map json) => HomeBannerItem(
        id: '${json['id']}',
        title: (json['title'] as String?) ?? '',
        subtitle: (json['subtitle'] as String?) ?? '',
        imageMediaId: json['imageMediaId'] == null ? null : '${json['imageMediaId']}',
        imageUrl: (json['imageUrl'] as String?) ?? '',
        imageWidth: _positiveInt(json['imageWidth']),
        imageHeight: _positiveInt(json['imageHeight']),
        linkType: BannerLinkType.parse(json['linkType']),
        linkValue: (json['linkValue'] as String?) ?? '',
      );
}

/// 跳转类型（**与服务端 DTO 的白名单逐字对应**）
///
/// `tab` 是历史值：服务端白名单保留它以兼容存量数据，管理端新页面不再提供；
/// 客户端不认它（解析成 [none] 而不是猜一个 tab 出来 —— 猜错会把用户丢到无关页面）。
enum BannerLinkType {
  none('none'),
  product('product'),
  division('division'),
  announcement('announcement'),
  url('url'),
  tab('tab');

  const BannerLinkType(this.wire);

  /// 与后端 `linkType` 字段一致的字符串值
  final String wire;

  static BannerLinkType parse(Object? raw) {
    final s = '${raw ?? ''}'.trim();
    for (final t in BannerLinkType.values) {
      if (t.wire == s) return t;
    }
    return BannerLinkType.none;
  }

  /// 是否需要 `linkValue`（管理端据此禁用/启用"跳转目标"输入框）
  bool get needsValue => this != BannerLinkType.none;
}

/// 跳转动作：把「宣传图点了一下」翻译成客户端**具体要做什么**
///
/// 为什么要在 core 里做这层翻译（而不是直接在页面里 switch）：
/// 它是纯函数、零依赖、可单测（4 个分支各一条断言），页面只负责"照着动作执行"。
/// 同时把"目标为空"的坑收在这一处：管理端可能选了"商品"却没填 id，
/// 这时返回 [none] 而不是带着空 id 去 push 一个必然 404 的详情页。
class BannerLinkAction {
  const BannerLinkAction(this.type, this.value);

  final BannerLinkType type;
  final String value;

  static const BannerLinkAction none = BannerLinkAction(BannerLinkType.none, '');

  bool get isNone => type == BannerLinkType.none || value.isEmpty;

  /// 解析（纯函数）：`linkType` + `linkValue` → 动作
  static BannerLinkAction resolve(HomeBannerItem item) {
    final v = item.linkValue.trim();
    if (item.linkType == BannerLinkType.none || v.isEmpty) return none;
    // tab 是历史值，客户端不支持 → 当作无跳转（不猜）
    if (item.linkType == BannerLinkType.tab) return none;
    return BannerLinkAction(item.linkType, v);
  }
}
