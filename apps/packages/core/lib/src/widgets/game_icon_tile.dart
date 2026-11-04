import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../theme/app_colors.dart';
import 'app_icon.dart';
import 'cached_image.dart';

/// 游戏图标块（负责人 2026-10-04 需求）
///
/// ## 为什么要有这个组件
/// 首页「分部封面」与下单链路「商品/订单封面」此前各自用**通用图标塞进渐变色块**
/// （`AppColors.categoryGradient` + `AppIcon.orders` / `AppIcon.shield`），
/// 结果三个分部、十个商品长得一模一样，用户分不清自己在买哪个游戏。
///
/// 负责人要求：这些位置**统一用「游戏图标」**呈现，**端游**的图标底部额外贴一个很小的
/// 「端」字角标。管理端已上传的自定义图（`division.iconMediaId` / `club.coverMediaId` /
/// `product.coverUrl|coverMediaId`）**优先级最高**，调用点在有图时仍渲染图片，本组件只负责
/// 「没有图」时的兜底。
///
/// ## 版权与素材红线（CLAUDE.md / docs/21）
/// 本组件**自带的自绘图标**不使用任何真实游戏 Logo 或版权素材，只做语义化的图标映射：
/// Flutter 内置 Material outlined 图标（经 [AppIcon] 常量）+ 分部 `themeColor`（或品类稳定色）。
/// 新增游戏时**不需要改客户端**：映射不到的游戏自动落到兜底图标，仍是同一套线性语言。
///
/// **例外（负责人 2026-10-04 明确指示）**：负责人自行提供了「三角洲行动」「和平精英」两张官方图，
/// 要求首页与下单链路直接用它们 —— 即图片来自**管理端上传**（`division.iconMediaId`），
/// 客户端只负责"有图就用图"。素材来源与合规由负责人决定，客户端不内置任何游戏 Logo 资源。
///
/// ## 有图就用图（负责人 2026-10-04 后续要求）
/// 管理端已在 `division.iconMediaId` / `division.coverMediaId` 挂上官方游戏图，
/// 调用点通过 [mediaId]（或已解析好的 [imageUrl]）传进来后：
/// - **有图 → 渲染图片**（[CachedNetImage]，圆角沿用调用点的 `radius` 分档，磁盘缓存、离线秒开）
/// - **无图 / 图空 → 保持上面的"自绘游戏图标"回退**（行为与之前完全一致）
/// - 端游角标在**图片底部居中**叠加，几何与自绘分支完全相同（高 `size*0.30`、字号 `size*0.18`）
///
/// ## 视觉规则
/// - 圆角方块，默认 `radius = 12`（列表内小尺寸调用点传 8/10，见各调用点注释）
/// - 底色：优先用传入 `color`（分部 themeColor / 品类色）；为空时按 gameKey 取
///   [AppColors.categoryColors] 里的**稳定色**（同一游戏每次都是同一个颜色，不随机）
/// - 图标：白色居中，边长 = `size * 0.46`
/// - 端游角标（`platform == 'pc'` 且 `badge == true`）：**底部居中**（色块或图片上都一样），
///   高 `size * 0.30`、圆角 4、底色 `Colors.black.withValues(alpha: 0.42)`、文字「端」字号 `size * 0.18`
///   （白色 w600），与底边留约 3px 内边距，不遮挡图标主体（图标居中，且 size=60 时角标总高 18+3=21 < 上方留白）
/// - 深色模式：角标是半透明黑 + 白字，与主题无关，天然通用
class GameIconTile extends StatelessWidget {
  const GameIconTile({
    super.key,
    required this.gameKey,
    required this.platform,
    this.size = 60,
    this.radius = 12,
    this.color,
    this.badge = true,
    this.mediaId,
    this.imageUrl,
  });

  /// 游戏标识：分部 code（`peace_mobile` / `delta_pc`）、gameName（和平精英/三角洲行动）、
  /// name（三角洲行动 · 端游）任一皆可；为空或不认识时用兜底图标
  final String? gameKey;

  /// 平台：`pc` / `端游` 视为端游（显示「端」角标）；空 / `mobile` / 其他不显示
  final String? platform;

  /// 色块边长（宽 = 高）
  final double size;

  /// 圆角
  final double radius;

  /// 底色（调用点传分部 themeColor）；为空时按 gameKey 取稳定品类色
  final Color? color;

  /// 是否允许显示端游角标（子卡片等极小尺寸调用点可传 false）
  final bool badge;

  /// 服务端媒体 id（分部 `iconMediaId` / `coverMediaId`）——
  /// 有值即按 `/media/public/{id}` 取图渲染（[CachedNetImage] 走磁盘缓存）
  final String? mediaId;

  /// 已解析的图片地址（绝对 URL 或 `/media/...` 相对路径）；
  /// **优先级高于 [mediaId]**，两者都为空/空白时回退自绘游戏图标
  final String? imageUrl;

  /// 实际生效的图片地址：`imageUrl` 优先，其次由 `mediaId` 拼公开媒体路径；都没有 → null（走自绘图标）
  String? get resolvedImageUrl {
    final direct = (imageUrl ?? '').trim();
    if (direct.isNotEmpty) return AppConfig.resolveMediaUrl(direct);
    final id = (mediaId ?? '').trim();
    if (id.isEmpty) return null;
    return AppConfig.resolveMediaUrl('/media/public/$id');
  }

  @override
  Widget build(BuildContext context) {
    final blockColor = color ?? gameIconColor(gameKey);
    // 角标总占用高度（含底部 3px 内边距）—— 仅在真的需要显示角标时压缩图标居中区域
    final showBadge = badge && isPcPlatform(platform);
    final badgePad = showBadge ? size * 0.30 + _badgeGap(size) : 0.0;
    final img = resolvedImageUrl;
    return Semantics(
      label: gameIconSemanticLabel(gameKey, platform, badge: badge),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            if (img == null)
              // 无图：自绘游戏图标（底色块 + 白色线性图标）
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: blockColor,
                    borderRadius: BorderRadius.circular(radius),
                  ),
                  child: Stack(
                    children: [
                      // 图标：水平居中；角色块底部给角标让位，避免视觉重心被压低
                      Positioned.fill(
                        bottom: badgePad,
                        child: Center(
                          child: AppIcon.of(
                            gameKeyIcon(gameKey),
                            size: size * 0.46,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              // 有图就用图（管理端上传的官方游戏图）；圆角沿用调用点的分档，与无图分支一致
              Positioned.fill(
                child: CachedNetImage(
                  url: img,
                  fit: BoxFit.cover,
                  radius: radius,
                  // 【2026-10-04 性能专项】限制解码尺寸：按"显示边长 × 设备像素比"解码，
                  // 避免把管理端上传的整张大图按原始分辨率解码后塞进 size 大小的格子
                  // （服务页有 3 个分部卡 + 游戏图标，是首页第一屏，解码浪费会直接表现为卡顿）。
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                ),
              ),
            if (showBadge)
              Positioned(
                left: 0,
                right: 0,
                bottom: _badgeGap(size),
                child: Center(child: _pcBadge(size)),
              ),
          ],
        ),
      ),
    );
  }

  /// 角标与色块底边的间距（约 3px，按尺寸等比缩放，极小尺寸下不小于 2px）
  static double _badgeGap(double size) => (size * 0.05).clamp(2.0, 3.0);

  Widget _pcBadge(double size) {
    // 两端留白的下界：避免水平 padding 太窄导致「端」被换行（中文两侧本就自带空隙）
    final sideMin = (size * 0.10).clamp(1.0, 4.0);
    return Container(
      height: size * 0.30,
      padding: EdgeInsets.symmetric(horizontal: size * 0.10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // 半透明黑：任何底色上都可读，深色模式同样成立（docs/21 反 AI 味：角标是小片、不描边铺满）
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: sideMin * 2),
        child: Text(
          '端',
          maxLines: 1,
          softWrap: false,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: size * 0.18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// 平台是否端游：`pc` 优先，兼容服务端直接下发中文标签「端游」
bool isPcPlatform(String? platform) {
  final p = platform?.trim().toLowerCase() ?? '';
  if (p.isEmpty) return false;
  return p == 'pc' || p.startsWith('pc_') || p.startsWith('pc-') || p.contains('端游');
}

/// 游戏标识 → 图标（**不用任何真实游戏 Logo**，只用 Flutter 内置 Material outlined）
///
/// | 匹配（gameKey 含） | 图标 | 语义 |
/// |---|---|---|
/// | `peace` / `和平` | [AppIcon.players] | 和平精英（射击/玩家） |
/// | `delta` / `三角洲` | [AppIcon.shield] | 三角洲行动（行动/护航） |
/// | 其他 / 空 | [AppIcon.orders] | 兜底（新游戏零客户端改动） |
IconData gameKeyIcon(String? gameKey) {
  final k = _norm(gameKey);
  if (k.contains('peace') || k.contains('和平')) return AppIcon.players;
  if (k.contains('delta') || k.contains('三角洲')) return AppIcon.shield;
  return AppIcon.orders;
}

/// 游戏标识 → 稳定底色（未传 themeColor 时使用）
///
/// 用**固定映射**而不是 `hashCode % n`：同一游戏在首页、商品列表、订单页必须是同一个颜色，
/// 且不能在 App 重启（hash 随机种子）后变色。
Color gameIconColor(String? gameKey) {
  final k = _norm(gameKey);
  if (k.contains('peace') || k.contains('和平')) return AppColors.categoryColors[0]; // 蓝
  if (k.contains('delta') || k.contains('三角洲')) return AppColors.categoryColors[2]; // 紫
  return AppColors.categoryColors[4]; // 青（兜底）
}

/// 无障碍语义标签（读屏用；纯装饰场景不影响视觉）
String gameIconSemanticLabel(String? gameKey, String? platform, {bool badge = true}) {
  final k = _norm(gameKey);
  final String game;
  if (k.contains('peace') || k.contains('和平')) {
    game = '和平精英';
  } else if (k.contains('delta') || k.contains('三角洲')) {
    game = '三角洲行动';
  } else {
    game = '服务';
  }
  final pc = badge && isPcPlatform(platform);
  return pc ? '$game 端游' : game;
}

/// 从任意文本（俱乐部名称/简介、商品名）推断游戏标识
///
/// 只做**已知游戏名单**的包含匹配，不认识就返回 null（→ 兜底图标），
/// 绝不猜、绝不硬编码商品数据；新游戏上市时改这一处即可。
String? inferGameKeyFromText(String? text) {
  final t = _norm(text);
  if (t.isEmpty) return null;
  if (t.contains('peace') || t.contains('和平')) return 'peace';
  if (t.contains('delta') || t.contains('三角洲')) return 'delta';
  return null;
}

/// 分部展示图 id 的选择规则（**有图就用图**，负责人 2026-10-04）
///
/// 管理端有两个图字段，服务端公开接口 `/divisions` 都会下发：
/// - `iconMediaId`：专区圆形图（商品列表顶部胶囊行、分部卡）
/// - `coverMediaId`：分部卡封面图
///
/// 两个字段当前由管理端挂**同一张**官方游戏图；只要**任意一个**有值就返回它，
/// 客户端不必关心管理端用的是哪一个（都为空 → null → [GameIconTile] 回退自绘游戏图标）。
String? divisionMediaId({String? iconMediaId, String? coverMediaId}) {
  final icon = (iconMediaId ?? '').trim();
  if (icon.isNotEmpty) return icon;
  final cover = (coverMediaId ?? '').trim();
  if (cover.isNotEmpty) return cover;
  return null;
}

/// 归一化：去空白 + 转小写（中文不受影响）
String _norm(String? v) => (v ?? '').trim().toLowerCase();
