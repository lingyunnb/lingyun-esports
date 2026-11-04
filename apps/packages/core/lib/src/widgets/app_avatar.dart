import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../theme/app_colors.dart';
import 'cached_image.dart';

/// 统一头像组件：真实媒体 ID → 网络图（带缩略加载/占位/失败兜底）；无头像用昵称首字
/// 头像/背景为公开媒体（/media/public/:id）；聊天图片等受保护资源请用带 token 的 Image.network
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.nickname,
    this.mediaId,
    this.size = 40,
    this.token,
    this.color,
    this.square = false,
    this.gradient = false,
    this.allowAnimation = false,
  });

  final String nickname;
  final String? mediaId;
  final double size;

  /// 受保护资源（如头像为 protected 通道时）传 token；头像/背景公开，默认 null
  final String? token;

  /// 主题色（无头像时的首字底色/字色）。默认主色；列表按分部/品类区分时传入
  final Color? color;

  /// 方形圆角头像（详情页/大卡片用）
  final bool square;

  /// 是否用品牌渐变底（榜单等强调场景）
  final bool gradient;

  /// 允许动图（GIF）播放（负责人 2026-10-18：「让头像支持动态」）
  ///
  /// ⚠️ **为 true 时必须绕开 `cacheWidth`**：Flutter 传 `cacheWidth` 会触发
  /// 缩放解码，动图只会渲染**第一帧**（这是本项目此前"GIF 头像不动"的真正原因，
  /// 不是上传坏了）。同时也不能走 `CachedNetImage`（它缓存的是静态 bitmap）。
  ///
  /// 代价：这一路不走磁盘缓存，每次冷启动重新下载。可接受 ——
  /// ① 只有主动设了动图头像的用户才走这条；② 服务端 `/media/public/:id` 下发了
  /// 30 天 `immutable` 缓存头，HTTP 层仍会命中。
  ///
  /// 列表页保持默认 false：一屏十几张动图同时解码会明显掉帧，
  /// 且 20dp 的图标里看不出动画。
  final bool allowAnimation;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primary;
    final shape = square ? BoxShape.rectangle : BoxShape.circle;
    final radius = square ? BorderRadius.circular(size * 0.34) : null;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: gradient ? null : c.withValues(alpha: 0.12),
        gradient: gradient
            ? LinearGradient(
                colors: [Color.lerp(c, Colors.white, .45)!, Color.lerp(c, Colors.white, .05)!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        shape: radius == null ? shape : BoxShape.rectangle,
        borderRadius: radius,
      ),
      child: Text(
        nickname.isNotEmpty ? nickname.characters.first : '?',
        style: TextStyle(
          fontSize: size * 0.42,
          color: gradient ? Colors.white : c,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (mediaId == null || mediaId!.isEmpty) return fallback;
    // 受保护头像**必须带全局前缀**（真实路由 `/api/v1/media/protected/:id`）；
    // 公开头像恰恰**不能**带（`main.ts` 把 `media/public/(.*)` 排除在全局前缀之外）。
    final path = token == null ? '/media/public/$mediaId' : '/api/v1/media/protected/$mediaId';
    final url = AppConfig.resolveMediaUrl(path);

    /**
     * 【2026-10-04 性能专项：公开头像改走磁盘缓存】
     *
     * 原来这里一律用 `Image.network` —— 只有 Flutter 的**内存**图片缓存（LRU），
     * App 一冷启动就全空，于是首页/榜单/找陪玩的每个头像都要**重新下载一次**。
     * 找陪玩列表 20 行 = 20 张头像 = 20 次请求，弱网下就是
     * "列表出来了、头像一片灰、过几秒才一个个蹦出来"。
     *
     * 现在公开头像（`/media/public/:id`）走 core 的 `CachedNetImage`（磁盘缓存，
     * 冷启动直接读文件、零网络），并传 `cacheWidth` 限制解码尺寸。
     *
     * **受保护头像（token != null）刻意保持 `Image.network`**：服务端对
     * `/media/protected/:id` 下发的是 `Cache-Control: no-store`，语义就是不允许落盘缓存。
     * 把它写进共享磁盘目录，会在"同一台手机换账号"时留下上一个账号的头像，
     * 属于隐私问题 —— 不能为了这点性能去换。
     */
    // ── 动图（GIF）专用分支（负责人 2026-10-18「让头像支持动态」）────────────
    //
    // 为什么必须先判这个再走下面的缓存分支：
    // · `CachedNetImage` 缓存的是**静态 bitmap** → 动图只剩一帧；
    // · `cacheWidth` 会触发 Flutter 的缩放解码 → 动图同样只剩一帧。
    // 两者只要命中一个，GIF 就不会动 —— 这就是"支持动图"真正要绕开的地方。
    // 所以这里**既不传 cacheWidth，也不走磁盘缓存**，直接 `Image.network` 解原图。
    if (allowAnimation) {
      return ClipRRect(
        borderRadius: radius ?? BorderRadius.circular(size / 2),
        child: Image.network(
          // 头像更换后立即刷新：媒体 id 变化即重建组件，不残留旧图
          key: ValueKey(mediaId),
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // ⚠️ 千万不要加 cacheWidth —— 加了动图就变静止
          headers: token == null ? null : {'Authorization': 'Bearer $token'},
          gaplessPlayback: true,
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : Container(width: size, height: size, color: AppColors.bgPage),
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }

    if (token == null) {
      return ClipRRect(
        borderRadius: radius ?? BorderRadius.circular(size / 2),
        child: CachedNetImage(
          // 头像更换后立即刷新：媒体 id 变化即换 key，组件重建、不残留旧图
          key: ValueKey(mediaId),
          url: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 头像缩略：限制解码尺寸，避免原图直接上屏（负责人需求 #35）
          cacheWidth: (size * 2.5).round(),
          placeholder: Container(width: size, height: size, color: AppColors.bgPage),
        ),
      );
    }

    return ClipRRect(
      borderRadius: radius ?? BorderRadius.circular(size / 2),
      child: Image.network(
        // 头像更换后立即刷新：媒体 id 变化即重建组件，不残留旧图
        key: ValueKey(mediaId),
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 头像缩略：限制解码尺寸，避免原图直接上屏（负责人需求 #35）
        cacheWidth: (size * 2.5).round(),
        headers: {'Authorization': 'Bearer $token'},
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : Container(width: size, height: size, color: AppColors.bgPage),
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}
