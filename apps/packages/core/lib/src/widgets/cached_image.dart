import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import 'app_icon.dart';

/// 网络图片**磁盘缓存**（负责人 2026-10-04：一步到位，图片也不要每次重下）
///
/// 为什么自己写：`cached_network_image` 要引依赖 + 三包 pub get（构建风险），
/// 而这里只需要「URL → 缓存文件」一层，用 `Directory.systemTemp`（Android 即应用缓存目录）
/// 落盘即可，零依赖、零插件、可离线复用。
///
/// 行为：
/// - 命中磁盘 → 直接 `Image.file`（冷启动也不打网络，**秒出**）
/// - 未命中 → 网络下载 → 写入磁盘 → 展示（下载中显示占位）
/// - 下载失败 → **有 [errorBuilder] 时交给调用方画错误态**；没给则回退占位（不崩、不白屏）
///
/// ## 【2026-10-07】为什么必须能画"失败原因 + 重试"
///
/// 付款凭证图加载不出来时，界面表现是**永远转圈**：下载早已失败（`_failed = true`），
/// 但调用方传的 `placeholder` 就是一个转圈指示器，而它同时被用在"失败"分支上 →
/// 转圈永不消失，用户既不知道为什么，也没有任何下一步可点。
///
/// 因此这里补一条**可选**错误态（默认行为逐字不变）：
/// [errorBuilder] 拿到 [ImageLoadFailure]（含 HTTP 状态码与中文原因）自绘错误态。
/// 约定口径（负责人定的通用规则）：**凡是失败，都要让人看见并给出下一步** ——
/// 不许静默吞掉，也不许只转圈不说话。
class CachedNetImage extends StatefulWidget {
  const CachedNetImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.radius,
    this.cacheWidth,
    this.cacheHeight,
    this.headers = const <String, String>{},
    this.keepPreviousOnUrlChange = false,
    this.errorBuilder,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final double? radius;

  /// 随图片请求一起发出的请求头。
  ///
  /// 【2026-10-07 修"付款凭证图一直转圈"】受保护媒体（`/api/v1/recharge/proof/:requestId`、
  /// `/api/v1/media/protected/:id`）只认 `Authorization: Bearer <token>`，
  /// 而 `dart:io` 的 `HttpClient` **不会自己带登录态** —— 之前这里没有 headers 参数，
  /// 受保护图只能拿到 401，界面表现就是占位/转圈永不消失。
  ///
  /// 默认空 Map：公开媒体（`/media/public/:id`、外部图床）行为**逐字不变**，零影响。
  final Map<String, String> headers;

  /// 解码宽度（像素）。
  ///
  /// 【2026-10-04 性能专项】加这两个参数的原因：组件虽然把图片**缓存到磁盘**了，
  /// 但 `Image.file` 默认按**原始分辨率**解码 —— 一张 1080×1920 的封面图塞进 96px 的
  /// 列表格子里，仍然要完整解码约 2MP 再缩放到屏幕，解码耗时与内存占用都是纯浪费，
  /// 表现为"图出来了但页面卡一下"。
  ///
  /// 约定用法：按**显示宽度 × 设备像素比**传（例如 96 宽的格子、dpr=3 → 288），
  /// 与 core 里 `AppAvatar` 既有做法一致（那里是 `(size * 2.5).round()`）。
  /// 不传则保持原行为（按原始尺寸解码），便于逐处灰度替换。
  final int? cacheWidth;
  final int? cacheHeight;

  /// **URL 变化时是否把"上一张图"留在屏上，直到新图就绪**（默认 `false` = 既有行为逐字不变）
  ///
  /// ## 为什么需要它（负责人 2026-10-16「不要在等转圈」）
  /// 默认行为是"URL 一变就把已加载的文件丢掉 → 回到占位块"：占位块在**下载中**会画一个
  /// `CircularProgressIndicator`（见 `_CachedNetImageState.build` 的 placeholder 分支），
  /// 于是**运营刚换的宣传图**会先以"整条灰色通栏 + 转圈"的形态出现，等新图下载完才换成图。
  /// 负责人要的不是这个 —— 换图时**旧图继续留在屏上**，新图就绪后静默替换（无灰块、无转圈、无布局跳动）。
  ///
  /// ## 为什么做成**开关**而不是直接改默认行为
  /// 有些位置"换成新图"本身就是要让用户看到变化的过程（例如重新上传后的凭证图、识别到的新头像），
  /// 而那些位置目前都依赖"URL 变 → 先占位、错了再画错误态"的既有链路。默认值保持 `false`，
  /// 既有调用方（含全部既有单测）行为**零变化**；需要"旧图兜住空窗"的地方显式打开
  /// （目前唯一调用方是首页宣传图轮播 `HomeBannerCarousel`）。
  ///
  /// 打开后的语义细节：新图**失败**时仍然会落到失败/占位分支（不会永远显示旧图），
  /// 因为失败时 `_failed = true` 且 `_resolve` 会把 `_file` 置空（见 `_resolve` 的收尾赋值）。
  final bool keepPreviousOnUrlChange;

  /// 失败态构建器（**可选**）：给了就在失败时画它，没给就沿用旧的"回退 placeholder"。
  ///
  /// [retry] 是**重新拉取**的回调（会清掉内存/磁盘里的失败结论并重回源；
  /// 点击前建议先 `setState` 到自己的 loading 值，本组件也会自动重画占位）。
  /// [failure] 带 HTTP 状态码与中文原因 —— **不要**把失败静默吞掉（见类注释）。
  final Widget Function(BuildContext context, ImageLoadFailure failure, VoidCallback retry)? errorBuilder;

  @override
  State<CachedNetImage> createState() => _CachedNetImageState();
}

/// 一次图片加载失败的**原因**（给用户看的中文 + 给排障看的原始信息）
///
/// [message] 由 [ImageDiskCache] 侧按"用户下一步该做什么"分类生成（与 `media_uploader.dart`
/// 的失败分类同一条口径），**不是**把 Dart 异常原文怼到屏幕上。
@immutable
class ImageLoadFailure {
  const ImageLoadFailure({required this.url, this.statusCode, this.reasonPhrase = '', this.message = ''});

  /// 出问题的地址（绝对 URL，便于用户/排障直接复制）
  final String url;

  /// HTTP 状态码（网络层异常时为 null）
  final int? statusCode;

  /// 服务端给的原因短语（如 `Unauthorized`；没有就是空串）
  final String reasonPhrase;

  /// 中文原因（空串 = 只有状态码可用）
  final String message;

  /// 上屏的一行中文：**原因 + 状态码**，例如
  /// `服务器返回 401（Unauthorized）` / `连不上服务器：请检查网络后重试`
  String get describe {
    final String detail = message.isNotEmpty ? message : '图片加载失败';
    final int? code = statusCode;
    if (code == null) return detail;
    final String rp = reasonPhrase.trim();
    return detail.contains('$code') ? detail : '$detail（$code${rp.isEmpty ? '' : ' $rp'}）';
  }

  @override
  bool operator ==(Object other) =>
      other is ImageLoadFailure &&
      other.url == url &&
      other.statusCode == statusCode &&
      other.reasonPhrase == reasonPhrase &&
      other.message == message;

  @override
  int get hashCode => Object.hash(url, statusCode, reasonPhrase, message);

  @override
  String toString() => 'ImageLoadFailure($url, status=$statusCode, reason=$reasonPhrase, msg=$message)';
}

/// 失败态**默认样式**（凭证图三处共用；守 docs/21）
///
/// 设计口径（与打手态接单大厅的"分部加载失败行"同一套语言）：
/// - 一行中文原因（**具体可验证**：带状态码，不写"加载失败"这种没有信息量的话）；
/// - 右侧主色**描边胶囊**「重试」（发丝线、不做大面积实色填充、无渐变、无 emoji）；
/// - 圆角 6（小控件档位），颜色只用 [AppColors.error]（图标）与既有灰阶。
///
/// [compact] = true 时只给一个红线图标（缩略图 48dp 塞不下文字；整格可点即重试）。
class ImageLoadError extends StatelessWidget {
  const ImageLoadError({
    super.key,
    required this.failure,
    required this.onRetry,
    this.compact = false,
    this.title,
  });

  final ImageLoadFailure failure;
  final VoidCallback onRetry;

  /// 缩略图/小格子用（无文字，点整格重试）
  final bool compact;

  /// 前缀标题（如「凭证图加载失败」）；为空时只显示原因
  final String? title;

  /// 「重试」按钮的 Key（出图/测试用：断言**确实有下一步可点**）
  static const Key retryKey = Key('image-load-error-retry');

  /// 中文原因文本的 Key
  static const Key textKey = Key('image-load-error-text');

  String get fullText {
    final String t = (title ?? '').trim();
    return t.isEmpty ? failure.describe : '$t（${failure.describe}）';
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      // 缩略图：整格可点 = 重试（旁边就是"详情"，不做两个小按钮挤在 48dp 里）
      return Semantics(
        button: true,
        label: '凭证图加载失败，点按重试',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onRetry,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.06),
                border: Border.all(color: T.divider),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const AppIcon.of(AppIcon.image, size: 20, color: AppColors.error),
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const AppIcon.of(AppIcon.image, size: 22, color: AppColors.error),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            fullText,
            key: textKey,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.45),
          ),
        ),
        const SizedBox(height: 12),
        // 重试：主色描边胶囊（与接单大厅的失败行同一种控件，不抢图的视觉重心）
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: retryKey,
            onTap: onRetry,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.primary),
              ),
              child: const Text(
                '重试',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CachedNetImageState extends State<CachedNetImage> {
  File? _file;
  bool _failed = false;
  bool _loading = false;

  /// 失败原因（`_failed` 为 true 时才有意义）
  ImageLoadFailure? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(CachedNetImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _failed = false;
      _failure = null;
      /**
       * 【2026-10-16「不要在等转圈」】默认（[CachedNetImage.keepPreviousOnUrlChange] = false）
       * 仍是既有行为：URL 一变就把已加载的文件丢掉 → 回到占位（下载中会画转圈）。
       * 打开开关的位置（首页宣传图轮播）**故意不丢**：旧图继续留屏上，新图就绪后静默替换。
       */
      if (!widget.keepPreviousOnUrlChange) _file = null;
      unawaited(_resolve());
    }
  }

  /// 重新拉取（用户点「重试」）：先清掉失败结论 → 重画占位 → 重新查缓存/回源
  void _retry() {
    if (widget.url.isEmpty) return;
    setState(() {
      _failed = false;
      _failure = null;
      _file = null;
    });
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    /**
     * 本次要解析的地址（**快照**）。
     *
     * 下面每个 `await` 之后都要拿它和 `widget.url` 比一次：图片下载是异步的，而 `url` 会变
     * （换图 / 换头像）—— 少了这道判定，**旧地址那一发慢下载回来时会覆盖新图**：
     * 成功时把新图换成旧图，失败时更糟（`_file=null` + `_failed=true` → 给一张**其实已经加载好**的新图
     * 画上"加载失败"）。这是"旧图留屏上"方案必须配的地基，不是可选优化。
     */
    final url = widget.url;
    if (url.isEmpty) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failure = const ImageLoadFailure(url: '', message: '图片地址为空');
        });
      }
      return;
    }
    final cached = await ImageDiskCache.instance.lookup(url, headers: widget.headers);
    if (!mounted || url != widget.url) return;
    if (cached != null) {
      setState(() {
        _file = cached;
        _failed = false;
        _failure = null;
      });
      return;
    }
    setState(() => _loading = true);
    final r = await ImageDiskCache.instance.downloadResult(url, headers: widget.headers);
    if (!mounted || url != widget.url) return;
    setState(() {
      _file = r.file;
      _loading = false;
      _failed = r.file == null;
      _failure = r.failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_file != null) {
      child = Image.file(
        _file!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        // 限制解码尺寸（不传则沿用原始尺寸解码）
        cacheWidth: widget.cacheWidth,
        cacheHeight: widget.cacheHeight,
        // 磁盘文件可能被系统清理 → 回退占位而不是抛错
        errorBuilder: (_, _, _) => _fallback(),
      );
    } else if (_failed) {
      child = _errorOrFallback();
    } else {
      child = widget.placeholder ??
          Container(
            width: widget.width,
            height: widget.height,
            color: AppColors.placeholderBg,
            alignment: Alignment.center,
            child: _loading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
          );
    }
    if (widget.radius != null) {
      child = ClipRRect(borderRadius: BorderRadius.circular(widget.radius!), child: child);
    }
    return child;
  }

  /// 失败：调用方给了 [CachedNetImage.errorBuilder] 就用它（能画"原因 + 重试"），
  /// 没给就**沿旧行为**回退占位 —— 既有调用方零影响。
  Widget _errorOrFallback() {
    final builder = widget.errorBuilder;
    if (builder == null) return _fallback();
    final failure = _failure ?? ImageLoadFailure(url: widget.url, message: '图片加载失败');
    return builder(context, failure, _retry);
  }

  Widget _fallback() => widget.placeholder ??
      Container(
        width: widget.width,
        height: widget.height,
        color: AppColors.placeholderBg,
        alignment: Alignment.center,
        child: const AppIcon.of(AppIcon.image, size: 18, color: AppColors.textPlaceholder),
      );
}

/// 图片磁盘缓存的**键**（URL + 请求头指纹）
///
/// 【2026-10-07】带 `Authorization` 的受保护媒体必须按"令牌"分桶：
/// 同一个 URL（如 `/api/v1/recharge/proof/48`）对**不同审核员**返回不同字节，
/// 若共用同一个磁盘文件，换个账号登录就会**看到上一个人的图**（串图）。
/// 公开媒体没有 headers（空 Map）→ 键就是 URL 本身，与改动前**逐字节一致**，
/// 既有缓存文件全部继续命中（零失效、零回归）。
String imageCacheKey(String url, {Map<String, String> headers = const <String, String>{}}) {
  if (headers.isEmpty) return url;
  final parts = headers.entries.map((e) => '${e.key}:${e.value}').toList()..sort();
  return '$url#h${parts.join('|').hashCode.toUnsigned(32).toRadixString(16)}';
}

/// 一次下载的结果：成功给文件，失败给**原因**（[ImageLoadFailure]）
///
/// 为什么不让 `download` 直接返回 `File?`：`null` 把"404 / 401 / 断网 / 图片解码不了"
/// 全糊成一种结果，界面只能转圈（2026-10-07 的事故就是这样被吞掉的）。
/// 旧签名 [ImageDiskCache.download] 保留不变（返回 `File?`），既有调用方零影响。
@immutable
class ImageDownloadResult {
  const ImageDownloadResult({this.file, this.failure});

  final File? file;
  final ImageLoadFailure? failure;

  bool get ok => file != null;
}

/// 磁盘缓存实现（单例）
class ImageDiskCache {
  ImageDiskCache._();
  static final ImageDiskCache instance = ImageDiskCache._();

  /// 出站 `HttpClient` 的**唯一构造点**（生产 = `HttpClient.new`）
  ///
  /// 【2026-10-07】为什么留这个钩子：失败态（404/401/断网 → 中文原因 + 重试）是本次修复的
  /// 核心验收项，而 `Image.network` 那套 `HttpOverrides` 对本组件的**磁盘下载路径无效**
  /// （`lookup` 是异步的，`HttpClient()` 不一定还在 override 的 Zone 里）。
  /// 有了它，单测可以注入一个假客户端，**确定性地**造出 404 / SocketException，
  /// 不必依赖真实网络或"这台机器恰好连不上某个地址"。
  ///
  /// 生产路径一行不变；只在测试里赋值（用完还原）。
  @visibleForTesting
  HttpClient Function() httpClientFactory = HttpClient.new;

  /// 最近一次网络层异常的原文（**仅排障/单测用**；上屏文案永远走 [ImageLoadFailure.describe]）
  @visibleForTesting
  String lastRawError = '';

  Directory? _dir;
  final Map<String, File> _memIndex = {};
  final Map<String, Future<ImageDownloadResult>> _inflight = {};

  /// 缓存键（URL + 请求头指纹）；[lookup]/[download]/[seed] 三处共用**同一份**实现
  String cacheKey(String url, {Map<String, String> headers = const <String, String>{}}) =>
      imageCacheKey(url, headers: headers);

  Future<Directory> _ensureDir() async {
    final d = _dir ??= Directory('${Directory.systemTemp.path}/fish_img_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _name(String url) {
    // 稳定短名：URL 的 hash + 长度，避免文件名过长/非法字符
    final h = url.hashCode.toUnsigned(32).toRadixString(16);
    return '${h}_${url.length}.img';
  }

  /// 查磁盘（内存索引优先）
  Future<File?> lookup(String url, {Map<String, String> headers = const <String, String>{}}) async {
    final key = imageCacheKey(url, headers: headers);
    final hit = _memIndex[key];
    if (hit != null && await hit.exists()) return hit;
    try {
      final f = File('${(await _ensureDir()).path}/${_name(key)}');
      if (await f.exists() && await f.length() > 0) {
        _memIndex[key] = f;
        return f;
      }
    } catch (_) {}
    return null;
  }

  /// 下载并落盘（同 URL 并发去重）—— **旧签名**：只看得到成功/失败
  Future<File?> download(String url, {Map<String, String> headers = const <String, String>{}}) async =>
      (await downloadResult(url, headers: headers)).file;

  /// 下载并落盘（同 URL 并发去重）—— **新签名**：失败时带上中文原因与状态码
  Future<ImageDownloadResult> downloadResult(String url,
      {Map<String, String> headers = const <String, String>{}}) {
    final key = imageCacheKey(url, headers: headers);
    final running = _inflight[key];
    if (running != null) return running;
    final fut = _download(url, headers: headers);
    _inflight[key] = fut;
    return fut.whenComplete(() => _inflight.remove(key));
  }

  Future<ImageDownloadResult> _download(String url, {Map<String, String> headers = const <String, String>{}}) async {
    final HttpClient client = httpClientFactory()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      /**
       * 【2026-10-04 性能专项：给图片请求也带上 gzip】
       *
       * `dart:io` 的 `HttpClient` **默认不发 `Accept-Encoding`**，而服务端
       * `compression()` 只看这个请求头决定是否压缩（实测：不带该头时
       * `/public/products` 2.5KB 原样返回，带上后 `Content-Encoding: gzip`）。
       * 图片（jpg/png/webp）本身已压缩，再 gzip 收益很小；但**这里同时承载了
       * JSON 之外的媒体响应**，且服务端 `/media/public/:id` 是同一套 compression 中间件，
       * SVG/部分 webp/带冗余元数据的图仍能受益，且 Dart 会自动解压（透明无副作用）。
       *
       * 更重要的是**与 api_client 保持一致**：两处 HTTP 出口行为一致，
       * 排查"为什么接口压缩了、图片没压缩"这类问题时不用再想第二遍。
       */
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip, deflate');
      // 受保护媒体：调用方给的鉴权头（公开媒体 headers 为空 → 行为与改动前一致）
      headers.forEach((k, v) {
        if (k.toLowerCase() == HttpHeaders.acceptEncodingHeader) return; // 上面已设
        req.headers.set(k, v);
      });
      final resp = await req.close();
      if (resp.statusCode != 200) {
        final int code = resp.statusCode;
        final String rp = resp.reasonPhrase;
        client.close();
        return ImageDownloadResult(
          failure: ImageLoadFailure(
            url: url,
            statusCode: code,
            reasonPhrase: rp,
            message: _httpFailureText(code),
          ),
        );
      }
      final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final key = imageCacheKey(url, headers: headers);
      final f = File('${(await _ensureDir()).path}/${_name(key)}');
      await f.writeAsBytes(bytes, flush: true);
      _memIndex[key] = f;
      client.close();
      return ImageDownloadResult(file: f);
    } catch (e) {
      // 网络层异常（DNS/连接/超时/TLS）：同样给中文原因，不静默
      lastRawError = '$e';
      return ImageDownloadResult(
        failure: ImageLoadFailure(url: url, message: _networkFailureText(e)),
      );
    } finally {
      try {
        client.close(force: true);
      } catch (_) {/* 已关或从未连上 */}
    }
  }

  /// HTTP 非 200 的**中文原因**（按"用户下一步该做什么"分类，与 `media_uploader.dart` 同口径）
  ///
  /// 关键是**别把状态码吞掉**：同一个"图出不来"，401（会话过期/没带令牌）、
  /// 403（没权限/受限会话白名单外）、404（路径错 —— 本次事故就是它）对排障是完全不同的结论。
  ///
  /// 单一实现点：生产代码与单测都调它（测试断言分类文案，不许各写一份）。
  static String failureTextForTest(int code) => _httpFailureText(code);
  static String _httpFailureText(int code) {
    if (code == 401) return '服务器拒绝了这次请求（登录状态可能已过期）';
    if (code == 403) return '没有查看这张图的权限';
    if (code == 404) return '服务器上没有这张图';
    if (code >= 500) return '服务端暂时不可用';
    return '服务器返回了非图片响应';
  }

  /// 网络层异常的中文原因（DNS / 连接 / 超时 / TLS 分开说）
  static String _networkFailureText(Object e) {
    final String s = '$e';
    if (s.contains('HandshakeException')) return '服务器证书校验失败';
    if (s.contains('TimeoutException') || s.contains('timeout')) return '请求超时：当前网络较慢';
    if (s.contains('SocketException')) return '连不上服务器：请检查网络后重试';
    if (s.contains('FormatException')) return '图片地址格式不对';
    return '图片加载失败：请检查网络后重试';
  }

  /// **测试/出图专用**：把磁盘缓存换个目录（并在换的时候丢掉内存索引与在途请求）。
  ///
  /// 【2026-10-07 出图事故】为什么需要它：`flutter test` **默认并行跑多个测试文件**
  /// （每个文件一个 isolate），而 `Directory.systemTemp/fish_img_cache` 是**全机共享**的路径
  /// —— 一个用例为了"每次从零开始"去删整个缓存目录时，**别的文件正在读的图就被删掉了**，
  /// 表现为互不相关的出图用例随机红（实测：`recharge_10_proof_ok.png` 那条被删掉了凭证图）。
  ///
  /// 正确做法是**各文件用各自的目录**，而不是去动共享目录：主进程里用进程 id 拼一个唯一目录即可。
  /// 生产路径不调用它（默认仍是 `systemTemp/fish_img_cache`）。
  @visibleForTesting
  Future<void> useDir(Directory dir) async {
    _memIndex.clear();
    _inflight.clear();
    _dir = dir;
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  /// **测试/出图专用**：清掉**本组件自己用过的那个目录**（只删 [useDir] 指定的目录；
  /// 没指定过就什么都不做 —— 绝不去删默认的共享目录，见 [useDir] 的说明）。
  @visibleForTesting
  Future<void> dispose() async {
    final d = _dir;
    _memIndex.clear();
    _inflight.clear();
    _dir = null;
    if (d == null) return;
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      /* 文件被占用/权限问题：内存索引已清，够用 */
    }
  }

  /// 预热（把常用图先拉到磁盘）
  ///
  /// 【2026-10-04 性能专项：改为并发预热】原实现是 `for + await`，一张一张串行下载 ——
  /// 预热 N 张图的耗时是 N × 单张耗时（每张都要独立建连）。改成**限流并发**
  /// （同时 4 条，避免把弱网带宽打成碎片、也避免耗尽连接数），
  /// 预热耗时降到约 1/4，且已缓存的图仍然直接跳过、零网络。
  ///
  /// [headers]：受保护媒体预热时带上鉴权头（键 = URL + 头指纹，与 [CachedNetImage] 完全同源）；
  /// 公开媒体不传 → 与改动前逐字一致。
  Future<void> warmUp(
    Iterable<String> urls, {
    int concurrency = 4,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final pending = <String>[];
    for (final u in urls) {
      if (u.isEmpty) continue;
      if (await lookup(u, headers: headers) != null) continue;
      pending.add(u);
    }
    for (var i = 0; i < pending.length; i += concurrency) {
      final batch = pending.skip(i).take(concurrency);
      await Future.wait(batch.map((u) => download(u, headers: headers)));
    }
  }

  /// **测试/出图专用**：把一张图的字节直接写进磁盘缓存（等价于"这张图已经下载过"）
  ///
  /// 为什么需要它：出图时必须看到**真的图片**（收款码 / 转账截图），而 `flutter test` 里
  /// 没有可用的图片服务器 —— 否则图位只能出占位灰块，等于没验收到"图能不能显示"。
  /// 生产路径一行不变：只在测试里显式调用它。
  ///
  /// [headers]：为受保护媒体的出图用例准备（键 = URL + 头指纹，与组件查找时一致）。
  @visibleForTesting
  Future<bool> seed(String url, List<int> bytes, {Map<String, String> headers = const <String, String>{}}) async {
    if (url.isEmpty || bytes.isEmpty) return false;
    try {
      final key = imageCacheKey(url, headers: headers);
      final f = File('${(await _ensureDir()).path}/${_name(key)}');
      await f.writeAsBytes(bytes, flush: true);
      _memIndex[key] = f;
      return true;
    } catch (_) {
      return false;
    }
  }
}
