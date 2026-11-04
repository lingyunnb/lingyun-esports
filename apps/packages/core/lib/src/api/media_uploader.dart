import 'dart:async';

import 'package:dio/dio.dart';

import 'api_client.dart';

/// 媒体上传结果（与 /media/upload 返回一致）
class MediaUploadResult {
  const MediaUploadResult({required this.id, required this.mimeType});

  final String id;
  final String mimeType;
}

/// 一次上传的**实时进度快照**（2026-10-06 上传体验专项）。
///
/// 为什么要有这个类而不是裸传 `(sent, total)`：上传界面要同时显示
/// **百分比 + 已传/总大小 + 速度**三样，而"速度"必须由时间差算出来 ——
/// 把这段算术收在这里，三个上传入口（头像/背景/付款凭证）就都只有一份实现。
class MediaUploadProgress {
  MediaUploadProgress({
    required this.sent,
    required this.total,
    required this.elapsed,
    required this.speedBytesPerSecond,
  });

  /// 已发送字节
  final int sent;

  /// 总字节（`-1` = 服务端没给 Content-Length，此时百分比取不到）
  final int total;

  /// 从开始上传到现在的耗时
  final Duration elapsed;

  /// **平均**上行速度（字节/秒）—— 平均值而非瞬时值：瞬时值抖动大，
  /// 用户看到的数字会乱跳，"平均 1.2MB/s" 才是可解释的读数。
  final double speedBytesPerSecond;

  /// 是否拿得到总大小
  bool get hasTotal => total > 0;

  /// 百分比（0–100 整数）；拿不到总大小时返回 0（界面按"已传 x"显示，不显示假百分比）
  int get percent => mediaUploadPercent(sent, total);

  /// 人类可读的字节数（`322 KB` / `1.2 MB`）
  static String formatBytes(int bytes) {
    if (bytes < 0) return '-';
    if (bytes < 1024) return '$bytes B';
    final double kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final double mb = kb / 1024;
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  /// 人类可读的速度（`16 KB/s` / `6.3 MB/s`）
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '-';
    return '${formatBytes(bytesPerSecond.round())}/s';
  }

  /// 已传/总大小（拿不到总大小时只给已传）
  String get sizeLabel =>
      hasTotal ? '${formatBytes(sent)} / ${formatBytes(total)}' : formatBytes(sent);

  @override
  String toString() => 'MediaUploadProgress($percent%, $sizeLabel, '
      '${formatSpeed(speedBytesPerSecond)})';
}

/// 上传进度的**界面状态**（页面自己 new 一个，传给 `MediaUploadTile`）。
///
/// 为什么不放在页面 State 里各写一份：头像/背景/付款凭证三处的状态机完全相同
/// （开始 → 进度 → 成功清空 / 失败留错误 + 可重试），三份复制品必然漂移
/// （这正是"同一规则只有一份实现"的要求）。
///
/// 【慢网提示为什么要一个 Timer】进度回调只在**有字节在传**时才来。真正慢的链路上
/// 分片之间可能隔很久（隧道限速 16KB/s 时，一帧之间可以静默十几秒）——
/// 光靠"下一次进度回调时顺便重建"会让慢网提示**永远不出现**（单测实测抓到：
/// 推进 16 秒后界面仍是旧一帧，提示压根没机会渲染）。
/// 于是在 [begin] 排一个一次性定时器，到点主动通知界面重绘一次。
class MediaUploadState {
  MediaUploadState();

  /// 当前进度（null = 还没有任何进度事件）
  MediaUploadProgress? progress;

  /// 是否正在上传
  bool uploading = false;

  /// 开始时刻（墙钟）—— 慢网提示与"已传多久"都基于它
  DateTime? startedAt;

  /// 失败原因（中文，可直接上屏）
  String? error;

  /// **是否已越过慢网阈值**（由定时器置位，见 [begin]）
  ///
  /// 为什么用"定时器置的标志位"而不是"每次 build 比一次墙钟"：后者在**假时钟**下
  /// 推不动（`DateTime.now()` 不随 `tester.pump` 走 → 单测根本造不出这个状态），
  /// 而真实链路上又没有别的重绘时机（慢网时十几秒没有一帧进度回调）。
  /// 定时器置位 = 一次 `Timer(after, …)` 同时负责"到点重绘"和"到点算慢"，
  /// 两件事发生在同一时刻，不会漂。
  bool slow = false;

  Timer? _slowTimer;

  /// 慢网提示到点时的回调（页面 `setState` 用；null = 不排定时器）
  void Function()? onTick;

  /// 上传开始（清掉上一次的错误与进度，并排一个慢网提示定时器）
  void begin({DateTime? now}) {
    uploading = true;
    error = null;
    progress = null;
    slow = false;
    startedAt = now ?? DateTime.now();
    _slowTimer?.cancel();
    final void Function()? tick = onTick;
    if (tick != null) {
      _slowTimer = Timer(MediaUploadSlowHint.after, () {
        // 已经结束/失败就别再触发重绘（页面可能已 dispose，由页面自己判 mounted）
        if (!uploading) return;
        slow = true;
        tick();
      });
    }
  }

  /// 收到一帧进度
  void update(MediaUploadProgress p) {
    progress = p;
  }

  /// 上传成功（进度与错误一起清掉 —— 成功后不该再留一条错误）
  void succeed() {
    _cancelTimer();
    uploading = false;
    slow = false;
    error = null;
    progress = null;
    startedAt = null;
  }

  /// 上传失败：**保留最后进度**（用户能看到"传到 43% 断了"），错误交给界面显示
  void fail(String message) {
    _cancelTimer();
    uploading = false;
    slow = false;
    error = message;
  }

  /// 失败后重试（错误清掉，正常重新 begin）
  void retry({DateTime? now}) => begin(now: now);

  /// 释放（页面 dispose 时调用 —— 定时器不悬空）
  void dispose() => _cancelTimer();

  void _cancelTimer() {
    _slowTimer?.cancel();
    _slowTimer = null;
  }
}

/// 慢网阈值（2026-10-06 上传体验专项）：**上传超过这个时长就提示「当前网络较慢」**。
///
/// 为什么是 15 秒：局域网直传 0.3–1MB 实测 0.05–0.2s；隧道限速 16KB/s 时同一张图要
/// 20 秒以上 —— 15 秒正好卡在"用户开始怀疑卡死"的那条线上，而不是等到超时。
///
/// 测试改这个值请走 [MediaUploadSlowHint.debugAfter]（生产恒等于它）。
const Duration kMediaUploadSlowAfter = Duration(seconds: 15);

/// 慢网阈值的**可测包装**。
///
/// 为什么要包装：判定读的是**真实墙钟**（`DateTime.now()`），假时钟推不动它 ——
/// 单测里等真 15 秒不可接受（本项目硬要求"不用无界等待/pumpAndSettle"）。
/// `debugAfter` 只在测试里被赋值，生产恒为 null → 取值等于 [kMediaUploadSlowAfter]。
class MediaUploadSlowHint {
  MediaUploadSlowHint._();

  /// 测试钩子：缩短阈值（null = 用生产值）
  static Duration? debugAfter;

  /// 生效的慢网阈值
  static Duration get after => debugAfter ?? kMediaUploadSlowAfter;
}

/// 上传超时策略（慢网不早退，但也不会无限挂）：
///   - `sendTimeout` 180s —— 隧道 16KB/s 下 1MB 图约 64s，必须给够余量（原 120s 也够，但
///     叠加重连重发会顶到边）；
///   - `receiveTimeout` 60s —— 服务端只回一个很小的 JSON，超过 1 分钟必是链路坏了；
///   - `connectTimeout` 15s —— 与 `ApiClient` 口径一致。
const Duration kMediaUploadSendTimeout = Duration(seconds: 180);
const Duration kMediaUploadReceiveTimeout = Duration(seconds: 60);
const Duration kMediaUploadConnectTimeout = Duration(seconds: 15);

/// 把任意上传异常翻成**中文可上屏**文案（2026-10-06）。
///
/// 原实现把 `DioException` 原文（英文类名 + 内部 URI/堆栈）抛给页面，页面只能写
/// "上传失败，请重试" 这种没有信息量的话；这里按"用户下一步该做什么"分类：
///   - 连不上 / 超时 → **网络**（换网/走局域网）
///   - 413 / 服务端说太大 → **图片太大**
///   - 401 / 403 → **登录或权限**
///   - 5xx → **服务端**（稍后再试）
///   - 其余 → 兜底中文
String mediaUploadErrorMessage(Object error) {
  // 服务端业务码非 0 → 我们的 message 就是中文原文（见 uploadMedia），直接透传
  if (error is ApiException) return error.message;
  if (error is DioException) {
    /**
     * 【真实链路上最先命中的分支】`ApiClient` 的错误拦截器会把
     * `connectionError / connectionTimeout / receiveTimeout` **统一归一**成
     * `DioException(error: ApiException(-1, '网络连接失败，请检查网络'))`
     * （见 api_client.dart 的 onError）—— 于是分享给用户的那句话是**归一后的通用文案**，
     * "超时还是连不上""该不该切 WiFi"这些**可执行信息全丢了**。
     *
     * 这里把它还原成上传场景的说法：uploads 走的就是 `sharedDio`（同一条拦截器链），
     * 所以这不处理的话，本函数精心写的中文分类**在真机上永远命中不到**（单测实测抓到）。
     * 类型被拦掉了，但 `error` 里那枚 `ApiException(-1)` 就是拦截器留下的指纹 —— 按它判定。
     */
    final Object? inner = error.error;
    if (error.type == DioExceptionType.unknown &&
        inner is ApiException &&
        inner.code == -1 &&
        inner.message.contains('网络连接失败')) {
      return '连不上服务器：请确认手机与电脑在同一 WiFi（局域网直连最快），或换网络后重试';
    }
    final int? status = error.response?.statusCode;
    if (status != null) {
      if (status == 401 || status == 403) return '登录已过期或无上传权限，请重新登录后再试';
      if (status == 413) return '图片太大，服务端拒绝接收，请换一张更小的图';
      if (status >= 500) return '服务端暂时不可用（$status），请稍后重试';
      final Object? body = error.response?.data;
      if (body is Map && body['message'] is String) {
        final String msg = (body['message'] as String).trim();
        if (msg.isNotEmpty) return msg;
      }
      return '上传失败（HTTP $status），请重试';
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '上传超时：当前网络较慢，请切到与电脑同一 WiFi 后重试';
      case DioExceptionType.connectionError:
        return '连不上服务器：请确认手机与电脑在同一 WiFi（局域网直连最快），或换网络后重试';
      case DioExceptionType.cancel:
        return '上传已取消';
      case DioExceptionType.badCertificate:
        return '服务器证书校验失败，请稍后重试';
      case DioExceptionType.badResponse:
        return '上传失败，请重试';
      case DioExceptionType.unknown:
        return '网络异常，上传失败，请重试';
      // dio 5.x 新增（图片转码超时）—— 上传路径实际不会触发，但 switch 必须穷尽
      case DioExceptionType.transformTimeout:
        return '上传超时：当前网络较慢，请切到与电脑同一 WiFi 后重试';
    }
  }
  if (error is MediaUploadException) return error.message;
  final String raw = error.toString();
  // 兜底：异常里若带中文（服务端/自定义文案），去掉 `Exception:` 前缀直接用
  if (RegExp(r'[\u4e00-\u9fa5]').hasMatch(raw)) {
    return raw.replaceFirst(RegExp(r'^Exception:\s*'), '').trim();
  }
  return '上传失败，请重试';
}

/// 服务端明确拒绝（业务码非 0）时的异常别名 —— 复用 [ApiException]，
/// 这样既有的 `on ApiException catch (e) { e.message }`（充值页）无需任何改动。
typedef MediaUploadException = ApiException;

/// 百分比取整口径（**唯一**）：四舍五入，且只在 100% 封顶。
///
/// `(sent*100/total).round()` —— 用它而不是 `floor()`：50.6% 显示成 `51%` 比 `50%` 更贴合
/// 用户对进度条位置的直觉，也和 [MediaUploadProgress.percent] 完全同源
/// （两处不一致会让"节流放行的档次"与"屏上显示的数字"对不上）。
int mediaUploadPercent(int sent, int total) {
  if (total <= 0) return 0;
  final int p = (sent * 100 / total).round();
  return p < 0 ? 0 : (p > 100 ? 100 : p);
}

/// 上传进度的**节流器**（纯逻辑，无 IO）—— 同一份规则的**唯一实现**。
///
/// 为什么必须节流：Dio 的分片进度回调在快网上能到**上千次/秒**，每次都 `setState`
/// 会把上传页面自己拖慢（反而让上传更慢）。1% + 120ms 的上限对肉眼已是连续动画。
///
/// 为什么单独抽成类：这是"进度是否单调、节流是否生效、速度怎么算"最该被断言的地方，
/// 抽出来就能直接喂合成的 `(sent,total)` 序列做单测，不必真的发一次网络请求
/// （也不必依赖 Dio 内部回调时序 —— 那种断言很脆）。
///
/// **时间只有一个来源**：注入的 [clock]（默认 `DateTime.now`）—— 节流的 120ms 判定与
/// `elapsed`/速度都从它算。不用 `Stopwatch`：两个时间源会让"假时钟推进 2 秒、
/// Stopwatch 仍是 0"这种不一致悄悄发生（第一版就踩到，实测速度算成 2×10⁹ B/s）。
class MediaUploadProgresser {
  MediaUploadProgresser({this.emit, DateTime Function()? clock, this.stepPercent = 1})
      : _now = clock ?? DateTime.now;

  /// 放行后的回调出口
  final void Function(MediaUploadProgress progress)? emit;

  /// 百分比步长（默认 1%）
  final int stepPercent;

  final DateTime Function() _now;

  DateTime? _startedAt;
  DateTime? _lastEmitAt;
  int _lastPercent = -1;
  int _lastSent = -1;
  int _emitted = 0;

  /// 已真正放行的回调次数（测试断言节流生效用）
  int get emitted => _emitted;

  /// 开始（重置全部节流状态）
  void start() {
    _startedAt = _now();
    _lastEmitAt = null;
    _lastPercent = -1;
    _lastSent = -1;
    _emitted = 0;
  }

  /// 从开始到现在的耗时
  Duration get elapsed {
    final DateTime? s = _startedAt;
    if (s == null) return Duration.zero;
    return _now().difference(s);
  }

  /// 收到一帧 Dio 进度。**首帧必发**；此后按「1% 或 120ms 或已传完」放行；
  /// **已传字节回退的帧一律丢弃**（进度条绝不能倒退）。
  void onSend(int sent, int total) {
    if (sent < 0) return;
    final int percent = mediaUploadPercent(sent, total);
    final bool isFirst = _lastEmitAt == null;
    final bool finished = total > 0 && sent >= total;
    final bool percentMoved = percent - _lastPercent >= stepPercent;
    final bool timeMoved = _lastEmitAt != null &&
        _now().difference(_lastEmitAt!) >= kMediaUploadProgressInterval;
    if (!isFirst && !(percentMoved || timeMoved || finished)) return;
    if (sent < _lastSent) return;
    _lastPercent = percent;
    _lastSent = sent;
    _lastEmitAt = _now();
    _emitted += 1;
    final Duration spent = elapsed;
    final double seconds = spent.inMilliseconds / 1000;
    emit?.call(MediaUploadProgress(
      sent: sent,
      total: total,
      elapsed: spent,
      speedBytesPerSecond: seconds <= 0 ? 0 : sent / seconds,
    ));
  }
}

/// 上传进度的节流阈值：**百分比每变 1% 或距上次至少 120ms** 才回调一次。
const int kMediaUploadProgressStepPercent = 1;
const Duration kMediaUploadProgressInterval = Duration(milliseconds: 120);

/// 媒体上传（docs/08）：multipart 走 `/media/upload`；类型由服务端白名单校验。
///
/// 【2026-10-06 上传体验专项 · 两处改动】
/// 1. **不再每次 new 一个 Dio**：改为复用 [ApiClient.sharedDio]（全进程唯一连接池）。
///    原实现每次调用新建 Dio → 新 `IOHttpClientAdapter` → 新 `dart:io HttpClient` →
///    **新连接池**，于是每次上传都要重付一次 DNS + TCP + **TLS 握手**（隧道下实测
///    0.5–0.8s/次），而上传本身可能只有 0.05s。
/// 2. **真实进度**：`onSendProgress` 回调 + [MediaUploadProgress]（百分比/速度/已传/总大小），
///    上传界面从此能显示"传到哪了"，而不是一个无限转圈。
///
/// 语义边界（三条，保证既有调用方零影响）：
///   1. `onProgress` 是**可选**参数 —— `chat_image` / `complaint_image` / `recharge_proof`
///      等既有调用点一行不改，但**自动受益**于连接池复用；
///   2. 超时策略：只在上传时临时放宽 `sendTimeout`（180s），**不改 `sharedDio` 的全局超时**
///      （普通接口 15s 快速失败的口径保持不变）；
///   3. 异常仍照旧抛出（`ApiException` 语义未变），只是新增 [mediaUploadErrorMessage]
///      供页面翻中文。
Future<MediaUploadResult> uploadMedia({
  required String type,
  required List<int> bytes,
  required String filename,
  required String token,
  void Function(MediaUploadProgress progress)? onProgress,
}) async {
  final dio = ApiClient.sharedDio;
  final fd = FormData.fromMap({
    'type': type,
    'file': MultipartFile.fromBytes(bytes, filename: filename),
  });

  // 节流 + 单调性由 [MediaUploadProgresser] 收口（见其类注释）
  final MediaUploadProgresser progresser = MediaUploadProgresser(emit: onProgress)
    ..start();

  final resp = await dio.post<Map<String, dynamic>>(
    '/media/upload',
    data: fd,
    onSendProgress: progresser.onSend,
    options: Options(
      headers: {'Authorization': 'Bearer $token'},
      sendTimeout: kMediaUploadSendTimeout,
      receiveTimeout: kMediaUploadReceiveTimeout,
    ),
  );

  final body = resp.data ?? const {};
  final code = body['code'] as int? ?? -1;
  if (code != 0) {
    final String msg = (body['message'] as String?)?.trim() ?? '';
    throw ApiException(
      code,
      msg.isEmpty ? '上传失败' : msg,
      '${body['requestId'] ?? ''}',
      errorCode: '${body['errorCode'] ?? body['code'] ?? ''}',
    );
  }
  final data = body['data'] as Map<String, dynamic>? ?? const {};
  return MediaUploadResult(id: '${data['id'] ?? ''}', mimeType: '${data['mimeType'] ?? ''}');
}
