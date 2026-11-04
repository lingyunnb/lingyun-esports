import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart'; // IOHttpClientAdapter：显式设 maxConnectionsPerHost（见 dioFactory 注释）
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../config/app_config.dart';
import 'shard_plan.dart';

/// 云端更新服务（双端共用：老板端 boss / 工作端 worker，各走各的版本通道）：
/// - 检测：服务端做版本比较，返回 hasUpdate/force/latest（客户端传入真实构建版本号）
/// - 下载：**多连接分片并行 + 断点续传 + 单连接回退**（2026-10-06 提速专项）
/// - 校验：sha256 与服务器记录一致才允许安装；不一致删除文件并报错重下
/// - 地址：全部来自 AppConfig（--dart-define 注入），无任何硬编码域名
///
/// ## 为什么需要多连接（2026-10-06 实测结论）
/// ngrok 免费档对**单条连接**限速且抖动极大：同一 26MB 真包，单连接实测
/// 0.1 / 0.44 / 1.44 / 1.66 / 1.69 / 1.9 MB/s（多轮），而 4 连接 1.9–6.3 MB/s、
/// 8 连接 2.8–3.3 MB/s。**瓶颈在隧道单连接限速，不在服务器带宽**
/// （本机直连 3100 = 390MB/s 量级）。所以"开 N 条连接同时拉不同区间"是唯一
/// 能真正提速客户端的手段。
///
/// ## 三条路径（优先级从高到低）
/// 1. **分片并行**：探测到 `Accept-Ranges: bytes` 且文件 ≥ 阈值 → N 片并发，各写各的偏移
/// 2. **单连接续传**：不支持 Range 时保持历史行为（1 路流式 + Range 续传）
/// 3. **缺口回填（fallback）**：并行中途失败 → 用 1 条连接顺序补齐缺失区间
///    （不是从零重下：已下完的片仍然算数，只在"服务端不再支持 Range"时才整包重来）
///
/// ## 停滞判活（2026-10-17 修复线上故障：卡在 75% / 0.00 MB/s / 永不结束）
/// **下载不能只靠"空闲超时"判活，必须有"总进度看门狗"兜底**（理由见 [StallConfig]）。
///
/// 实测（dio 5.11.1 `response_stream_handler.dart`）：`receiveTimeout` 是**每条连接自己的
/// "两块数据之间"的空闲计时器**，而且**只要收到任何一个字节就重置**。于是有两个致命盲区：
///   1. **"零星到达"能把它无限续命** —— 每 60s 内挤进来几个字节就永远不报错，
///      而总进度几乎不涨（这就是负责人看到的 `75% · 0.00 MB/s · 计算中…`）；
///   2. **它只认单条连接**：4 片里 3 片死掉、只剩 1 片在慢慢挪，聚合进度还是"在动"，
///      没有任何一层能判定"这次下载已经废了"，也就永远不会给用户一个明确失败。
///
/// 判死后的处置：**退避重试（1s/3s/8s，上限 3 次，只补缺口）→ 仍卡死则降级单连接
/// 续传 → 再卡死就明确报错**（绝不允许无限期 0 MB/s 地挂着）。
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  /// 测试用实例（真实使用一律走 [instance] 单例）
  @visibleForTesting
  factory AppUpdater.forTesting() = AppUpdater._;

  ApiClient _api = ApiClient();

  /// 测试注入（默认真实 ApiClient）
  ApiClient get api => _api;
  set api(ApiClient c) => _api = c;

  /// 分片参数（调用方/测试可整体替换；默认值理由见 [ShardConfig]）
  ShardConfig shardConfig = const ShardConfig();

  /// 停滞判活参数（调用方/测试可整体替换；默认值理由见 [StallConfig]）
  StallConfig stallConfig = const StallConfig();

  /// 当前是否以分片并行方式在下载（诊断/展示用）
  bool _parallelActive = false;
  bool get parallelActive => _parallelActive;

  /// 停滞到上限后的失败文案（UI 直接展示；**已保留进度**，重试会续传补齐而不是重头下）
  static const String stalledMessage = '下载中断（网络长时间无数据），已保留进度，点击重试';

  /// 本次下载中被看门狗判死（停滞）并退避重试的次数。
  ///
  /// 为什么要有这个可读计数：停滞是**静默故障**（不报错、不重试、进度不涨），
  /// 排障时最需要回答的就是"到底判死过没有"。UI 不显示它，但日志/测试/现场诊断都要。
  int get stallDetections => _stallDetections;
  int _stallDetections = 0;

  /// **测试注入点**：造下载用的 Dio。
  ///
  /// 生产实现刻意**不复用 ApiClient.dio**：那个实例挂了鉴权拦截器、15s 全局
  /// receiveTimeout、以及"按路径缓存 GET"的逻辑，都不适合大文件流式下载
  /// （尤其 receiveTimeout 15s 会把慢速隧道的分片读打断）。这里每片独立成流，
  /// 只带"防 ngrok 插页"必需的两个头。
  Dio Function() dioFactory = _defaultDownloadDio;

  /// 每主机最大连接数（**必须显式设置**，2026-10-17 提速专项）。
  ///
  /// 实测口径：dio 5.11.1 的 IO 适配器默认只设 `idleTimeout = 3s`，
  /// **从不设置 `maxConnectionsPerHost`**；而 dart:io 的默认值是 `null` = **不限**。
  /// 也就是说"多片被上游排队成串行"这件事在 dart:io 上并不成立
  /// （那个"每域 6 连接"是**浏览器**的规矩，不是 dart:io 的）——调查结论如此，
  /// 但我们仍然**显式设成硬顶**：① 让"允许 N 片真并发"成为代码里可读的意图，
  /// 而不是依赖某个默认值；② 将来若有 HttpOverrides/中间层给 HttpClient 塞了
  /// 并发上限，这里能保证至少与我们的分片数一致（否则会静默退化成串行）。
  /// 注：用 `static final`（不能用 const —— 常量表达式里不允许读 const 实例的字段），
  /// 值直接跟随 [ShardConfig] 的硬顶，避免两处数字各写一遍后漂移。
  static final int downloadMaxConnectionsPerHost = const ShardConfig().hardMaxConnections;

  static Dio _defaultDownloadDio() {
    final Dio dio = Dio(
      BaseOptions(
        baseUrl: 'http://update.local',
        connectTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        // 连接级读空闲（dio 的 receiveTimeout 就是这一层：两块数据之间的空闲计时，
        // 收到任何一字节就重置 —— 所以"零星到达"永远打不响它）。60s 这个值只是
        // "完全静默"的兜底；真正的判活是 [StallConfig]/[ProgressWatchdog]（聚合进度）。
        receiveTimeout: const Duration(seconds: 60),
        headers: const <String, dynamic>{
          ApiClient.ngrokSkipWarningHeader: ApiClient.ngrokSkipWarningValue,
          'User-Agent': ApiClient.appUserAgent,
        },
      ),
    );
    // 显式给连接池放开并发（默认 null = 不限，这里写出数值 + 理由，见上）
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..maxConnectionsPerHost = downloadMaxConnectionsPerHost
        ..idleTimeout = const Duration(seconds: 3), // 与 dio 默认一致
    );
    return dio;
  }

  /// 检测更新：appType 由各端显式传入（boss / worker），避免误检另一端的版本通道；
  /// currentVersionCode 为构建注入的当前版本号
  Future<AppUpdateInfo?> checkUpdate({required String appType}) async {
    final resp = await _api.request(
      'GET',
      '/public/app-versions/latest',
      queryParameters: {'appType': appType, 'currentVersionCode': AppConfig.appVersionCode},
    );
    return AppUpdateInfo.fromJson(resp['data'] as Map<String, dynamic>);
  }

  /// 下载安装包（**流式写盘，绝不整包进内存**）：
  ///
  /// - 路径固定（按版本号）→ 失败重试 / 重新进入都能续传，不产生多份临时文件
  /// - [onProgress] 报**累计已完成字节**，且**单调不倒退**（并行下各片乱序完成也不会倒退）
  /// - [onSpeed] 报近期平均速度（字节/秒），供弹窗展示 MB/s 与剩余时间
  /// - [onStallRetry] 停滞判死要退避重试时回调 `(第几次, 上限)`：
  ///   **UI 必须据此告诉用户"正在重试"**（2026-10-17），否则那 20 秒起的等待窗口
  ///   在用户眼里和"卡死"没有区别（故障原文就是"网没问题但卡住不下了"）
  /// - [cancelToken] 取消 → 立即断流并清理临时文件（不留坏文件、不留残留片）
  ///
  /// 返回值：校验通过前**只是文件落盘**；sha256 由调用方经 [verifyHash] 确认。
  Future<String> download(
    AppUpdateInfo info, {
    void Function(int done, int total)? onProgress,
    void Function(double bytesPerSecond)? onSpeed,
    void Function(int attempt, int maxAttempts)? onStallRetry,
    CancelToken? cancelToken,
  }) async {
    final String url = info.downloadUrl;
    if (url.isEmpty) throw const ApiException(-1, '下载地址无效', '');

    _stallDetections = 0; // 每次下载独立计数（诊断/测试用）

    final Directory dir = Directory('${Directory.systemTemp.path}/fish_update');
    if (!await dir.exists()) await dir.create(recursive: true);
    final String savePath = '${dir.path}/fish_update_v${info.versionCode}.apk';
    final String partPath = '$savePath.part';
    final String sidecarPath = '$partPath${PartSidecar.suffix}';

    try {
      // ── 1. 探测：Accept-Ranges / Content-Length ─────────────────────────────
      final ProbeResult probe = await _probe(url, info: info, cancelToken: cancelToken);
      final int total = probe.total > 0 ? probe.total : info.fileSize;

      // ── 2. 分片并行（≥ 4MB 且支持 Range）────────────────────────────────────
      if (ShardPlanner.shouldShard(
        rangeSupported: probe.rangeSupported,
        fileSize: total,
        config: shardConfig,
      )) {
        try {
          _parallelActive = true;
          await _downloadParallel(
            url: url,
            partPath: partPath,
            sidecarPath: sidecarPath,
            total: total,
            onProgress: onProgress,
            onSpeed: onSpeed,
            onStallRetry: onStallRetry,
            cancelToken: cancelToken,
          );
        } catch (e) {
          // 取消：不算失败，直接向上抛（由 UpdateCenter 归入 failed，不自动重试）
          if (_isCancelled(e, cancelToken)) rethrow;
          // 并行失败 → 缺口回填（单连接顺序补齐缺失区间，已完成的片不重下）
          await _downloadGapFill(
            url: url,
            partPath: partPath,
            sidecarPath: sidecarPath,
            total: total,
            onProgress: onProgress,
            onSpeed: onSpeed,
            onStallRetry: onStallRetry,
            cancelToken: cancelToken,
          );
        } finally {
          _parallelActive = false;
        }
      } else {
        // ── 3. 单连接（不支持 Range 的小文件/服务端不支持时的历史行为）────────
        await _downloadSingleStream(
          url: url,
          partPath: partPath,
          sidecarPath: sidecarPath,
          total: total,
          onProgress: onProgress,
          onSpeed: onSpeed,
          onStallRetry: onStallRetry,
          cancelToken: cancelToken,
        );
      }

      // ── 4. 收尾：大小自检 → 改名 → 删 sidecar ───────────────────────────────
      final File part = File(partPath);
      if (!await part.exists()) throw const ApiException(-1, '下载失败，请检查网络后重试', '');
      final int got = await part.length();
      if (total > 0 && got != total) {
        // 只删 sidecar：保留 .part 供下次续传补齐（不是坏包，是没下完）
        await _deleteQuietly(sidecarPath);
        throw ApiException(-1, '安装包不完整（$got/$total 字节），请重试', '');
      }
      await _deleteQuietly(sidecarPath);
      await _promote(part, File(savePath));
      return savePath;
    } catch (e) {
      // 取消 ≠ 放弃：**保留 .part 与 sidecar**，这样用户重新点"立即更新"时
      // 能接着已下部分续传（下到 90% 时误取消失再去重下 26MB 是体验灾难）。
      // 真正的"放弃"由 [discard] 处理（校验失败、或调用方明确要清理时）。
      // 注意：取消时绝不会存在 .apk —— 改名只发生在下载完整之后。
      rethrow;
    }
  }

  // ───────────────────────────── 探测 ─────────────────────────────

  /// 用 `Range: bytes=0-0` 探测：能拿到 206 + `Content-Range: bytes 0-0/TOTAL`
  /// 即认为服务端支持 Range，且顺带拿到真实总大小（比 HEAD 可靠：
  /// 部分隧道/代理对 HEAD 处理不一致，而 GET+Range 是下载真实要走的路径）。
  Future<ProbeResult> _probe(
    String url, {
    required AppUpdateInfo info,
    CancelToken? cancelToken,
  }) async {
    final Dio dio = dioFactory();
    try {
      final Response<ResponseBody> resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: const <String, dynamic>{'Range': 'bytes=0-0', 'Accept-Encoding': 'identity'},
          validateStatus: (int? s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 20),
        ),
        cancelToken: cancelToken,
      );
      // 只读 1 字节就断开：探测不许拖流量
      unawaited(resp.data?.stream.drain<void>().catchError((Object _) {}) ?? Future<void>.value());
      final Map<String, dynamic> h = resp.headers.map;
      final String? acceptRanges = h['accept-ranges']?.first;
      final String? contentRange = h['content-range']?.first;
      final int fromRange = _totalFromContentRange(contentRange);
      if (resp.statusCode == 206 && fromRange > 0) {
        return ProbeResult(rangeSupported: true, total: fromRange);
      }
      // 200：服务端忽略了 Range（或本来就不支持）→ 走单连接
      final int len = int.tryParse('${h['content-length']?.first ?? ''}') ?? 0;
      return ProbeResult(
        rangeSupported: acceptRanges == 'bytes' && resp.statusCode == 206,
        total: len > 0 ? len : info.fileSize,
      );
    } catch (e) {
      if (_isCancelled(e, cancelToken)) rethrow;
      // 探测失败不算致命：退回"按已知 fileSize 单连接下载"（历史行为）
      return ProbeResult(rangeSupported: false, total: info.fileSize);
    } finally {
      dio.close(force: true);
    }
  }

  static int _totalFromContentRange(String? contentRange) {
    if (contentRange == null) return 0;
    final Match? m = RegExp(r'/\s*(\d+)\s*$').firstMatch(contentRange);
    return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
  }

  // ─────────────────────── 分片并行（主路径） ───────────────────────

  Future<void> _downloadParallel({
    required String url,
    required String partPath,
    required String sidecarPath,
    required int total,
    void Function(int done, int total)? onProgress,
    void Function(double bytesPerSecond)? onSpeed,
    void Function(int attempt, int maxAttempts)? onStallRetry,
    CancelToken? cancelToken,
  }) async {
    final File part = File(partPath);

    // ── 续传：复用 sidecar 里已完成的区间（URL + 总大小 + 文件长度三重一致才作数）──
    List<ByteRange> done = const <ByteRange>[];
    final PartSidecar? sidecar = await _readSidecar(sidecarPath);
    if (sidecar != null && sidecar.url == url && sidecar.total == total && await _ensurePadded(part, total)) {
      // 防御：sidecar 声称的完成区间不得超出 .part 实际长度（否则会跳过没写的字节）
      final int actual = await part.length();
      done = sidecar.done.where((ByteRange r) => r.end < actual).toList();
      if (done.length != sidecar.done.length) done = const <ByteRange>[];
    } else {
      // sidecar 不可用（换源/换版本/坏文件）→ 干净重来：截断 .part，避免旧数据混入
      await _resetPart(part);
      if (!await _ensurePadded(part, total)) {
        throw const ApiException(-1, '无法创建下载临时文件（存储空间不足？）', '');
      }
      done = const <ByteRange>[];
    }

    final List<ByteRange> shards = ShardPlanner.split(
      total: total,
      connections: shardConfig.maxConnections,
      config: shardConfig,
    );
    final List<ByteRange> mergedDone = ShardPlanner.mergeRanges(done);

    // 已下完的字节先报一次，让进度条从中断处接着走（不是从 0 重新涨）
    int completed = ShardPlanner.coveredBytes(mergedDone);
    final MonotonicProgress progress = MonotonicProgress(total)..report(completed);
    final SpeedMeter meter = SpeedMeter();
    meter.sample(completed);
    onProgress?.call(progress.done, total);
    onSpeed?.call(0);

    final Object lock = Object();
    final List<ByteRange> doneNow = List<ByteRange>.of(mergedDone);

    /// 原始分片号（用于给每个"计划片"独立的失败预算）。
    /// 为什么不能按"当前待下区间"计预算：服务端反复返回**很短的合法前缀**时，
    /// 每次都算"有进展"，区间被无限切小 → 永远重试不完（实测隧道抖动会触发）。
    /// 按计划片计预算后，无论切成多少段，同一片的失败总次数都有上限。
    int shardIndexOf(ByteRange r) {
      for (int i = 0; i < shards.length; i++) {
        if (r.start >= shards[i].start && r.start <= shards[i].end) return i;
      }
      return 0;
    }

    Future<void> persist() async {
      final PartSidecar s = PartSidecar(url: url, total: total, shards: shards, done: doneNow);
      await _writeSidecar(sidecarPath, s.encode());
    }

    /// 记录一段"确实写进盘了"的区间（含分片中途中止时的前缀）→ 进度 + 续传依据
    void registerProgress(ByteRange r) {
      completed = progress.report(ShardPlanner.coveredBytes(doneNow));
      meter.sample(progress.done);
      onProgress?.call(progress.done, total);
      onSpeed?.call(meter.bytesPerSecond);
      unawaited(persist());
    }

    // ── 停滞判活（2026-10-17）──────────────────────────────────────────────
    // 每轮带一个 [ProgressWatchdog]：连续 [StallConfig.stallTimeout] 总进度几乎不涨
    // → 判死本轮 → 退避 1s/3s/8s 重试（**续传**：只补缺口）→ 上限用尽则抛出，
    // 由 [download] 的 catch 降级到单连接缺口回填（既有能力，不重造）。
    int strikes = 0;
    int rounds = 0;
    while (true) {
      // 兜底刹车：正常最多"3 次停滞重试 + 1 次收尾"，多出来的轮次只可能来自
      // 病态服务端；到顶就抛出去降级单连接（绝不允许无限轮下去）。
      rounds++;
      if (rounds > stallConfig.maxStallRetries + 4) {
        throw const ApiException(-1, stalledMessage, '');
      }
      // 每轮按"当前已确认落盘的区间"重建待下队列：停滞重试 = 续传补齐，
      // 已下完的字节一个都不重下（.part 路径与 sidecar 设计原样保留）。
      final List<ByteRange> pending =
          ShardPlanner.pendingRanges(needed: shards, done: ShardPlanner.mergeRanges(doneNow));
      if (pending.isEmpty) {
        onProgress?.call(total, total);
        break; // 全部已下完（上次刚下完就崩在收尾）→ 交给上层做大小/哈希校验
      }

      final _StallGuard guard = _StallGuard(stallConfig);
      int connections = shardConfig.clampConnections(shardConfig.maxConnections);
      if (connections > pending.length) connections = pending.length;

      // 待下区间按"轮转"打散成一个队列，各连接用共享游标领活（动态负载均衡：
      // 某片慢/重试时其它连接继续领后面的片，不会出现"尾片拖尾"）。
      final List<ByteRange> ready = List<ByteRange>.of(pending);
      for (int i = 1; i < connections && i < pending.length; i++) {
        ready.add(ready.removeAt(0));
      }
      // 退避中的区间：(区间, 可重试时刻, 已失败次数)。**不 sleep 占住连接**——
      // 退避期间该连接可以去干别的活，只有整条队列都空时才等待。
      final List<_Retry> deferred = <_Retry>[];
      final List<Object> failures = <Object>[];
      final Map<int, int> failuresByShard = <int, int>{};
      int consecutiveFailures = 0;
      bool aborted = false;
      int requests = 0;
      // 请求预算 = 每片都能用完自己的尝试次数（片数已含"队列深度"，所以按片算而不是按连接算）。
      // 这是"病态服务端/极端抖动"下的兜底刹车：无论失败模式怎么组合，请求数都不会无限增长，
      // 到顶即放弃并行、交给缺口回填（单连接顺序补齐）。
      final int maxTotalRequests = shardConfig.maxAttemptsPerShard * shards.length;
      // 每轮一个新连接池，轮末强制回收：判死的那几条半开连接绝不跨轮残留
      final Dio dio = dioFactory();

      Future<void> worker() async {
        while (true) {
          // 本轮已被看门狗判死：立刻收工（由外层退避重试/降级，绝不在这里空转）
          if (guard.stalled) return;
          ByteRange? picked;
          var isRetry = false;
          _pendingWait = null;
          // 领活（这段是临界区：不含 await，单线程下天然原子，两个连接不会拿到同一片）
          synchronized(lock, () {
            if (aborted) return;
            if (ready.isNotEmpty) {
              picked = ready.removeAt(0);
              return;
            }
            // 就绪队列空：若还有退避中的区间且全局请求数没用完 → 取最近到期的那段
            if (deferred.isEmpty || requests >= maxTotalRequests) {
              aborted = failures.isNotEmpty;
              return;
            }
            deferred.sort((_Retry a, _Retry b) => a.at.compareTo(b.at));
            final _Retry next = deferred.removeAt(0);
            _pendingWait = next.at.difference(DateTime.now());
            picked = next.range;
            isRetry = true;
          });
          final Duration waitFor = _pendingWait ?? Duration.zero;
          _pendingWait = null;
          // 退避等待在临界区外（不占锁；Dart 单线程下"锁"只是语义标注）
          if (isRetry && waitFor > Duration.zero) {
            await Future<void>.delayed(waitFor);
          }
          if (guard.stalled) return; // 睡醒后同样要检查（等待期间可能已判死）
          final ByteRange? range = picked;
          if (range == null) return;
          final int shard = shardIndexOf(range);
          synchronized(lock, () => requests++);
          guard.begin(); // 有请求在飞 → 看门狗恢复计时（退避等待期不算停滞）
          try {
            final ByteRange got = await _fetchRange(
              url: url,
              partPath: partPath,
              range: range,
              dio: dio,
              cancelToken: cancelToken,
              guard: guard,
              onPartial: (ByteRange p) {
                synchronized(lock, () => doneNow.add(p));
                registerProgress(p);
              },
            );
            if (got.length < range.length) {
              // 只下到一半（隧道断流）：**已下部分照样记账**，剩下的重新排队
              synchronized(lock, () {
                doneNow.add(got);
                consecutiveFailures = 0;
              });
              registerProgress(got);
              if (got.length > 0) {
                // 有实质进展才允许继续（预算按"计划片"计，不会因切小而无上限）
                synchronized(lock, () => ready.add(ByteRange(got.end + 1, range.end)));
                continue;
              }
              throw ApiException(-1, '分片 ${range.start}-${range.end} 零字节返回', '');
            }
            synchronized(lock, () {
              doneNow.add(got);
              consecutiveFailures = 0;
              failuresByShard.remove(shard); // 该片已完整拿下 → 预算清零
            });
            registerProgress(got);
          } catch (e) {
            if (_isCancelled(e, cancelToken)) rethrow;
            // 停滞：总进度已长时间不涨 → 不再在死轮里徒劳重试，交给外层退避/降级
            if (guard.stalled) return;
            final bool giveUp = synchronized(lock, () {
              failures.add(e);
              consecutiveFailures++;
              final int used = (failuresByShard[shard] ?? 0) + 1;
              failuresByShard[shard] = used;
              // 弱网降级：连续失败到阈值就把并发砍半（对后续尝试生效）
              if (consecutiveFailures >= shardConfig.degradeAfterConsecutiveFailures) {
                final int half = (connections / 2).floor().clamp(1, connections);
                shardConfig = shardConfig.withConnections(half);
              }
              if (used >= shardConfig.maxAttemptsPerShard || requests >= maxTotalRequests) {
                aborted = true;
                return true;
              }
              final int backoffMs = 400 * (1 << (used - 1).clamp(0, 6));
              deferred.add(_Retry(range, DateTime.now().add(Duration(milliseconds: backoffMs)), used));
              return false;
            });
            if (giveUp) throw failures.first;
          } finally {
            guard.end();
          }
        }
      }

      Object? roundError;
      try {
        await Future.wait(List<Future<void>>.generate(connections, (_) => worker()));
      } catch (e) {
        // worker 主动放弃（`throw failures.first`）：既有语义不变 —— 交出去让调用方
        // 走缺口回填。**停滞走另一条路**（见下），两者都失败才会到用户面前。
        roundError = e;
      } finally {
        // 无论成功/失败/取消都把 sidecar 落盘：中断后重进据此续传
        await persist();
        dio.close(force: true); // 统一回收连接池（此时所有分片都已结束）
      }

      if (guard.stalled) {
        strikes++;
        _stallDetections++;
        if (strikes > stallConfig.maxStallRetries) {
          // 停滞重试用尽 → 抛出去降级单连接续传（外层 catch），而不是无限挂着
          throw const ApiException(-1, stalledMessage, '');
        }
        // UI 必须知道"正在重试"（否则这几十秒在用户眼里就是卡死）；进度不回退
        onStallRetry?.call(strikes, stallConfig.maxStallRetries);
        onSpeed?.call(0); // 停滞期间别把上一次的旧速度留在 UI 上
        await Future<void>.delayed(stallConfig.backoffFor(strikes));
        continue; // 退避后重试：只补缺口（doneNow / sidecar 都还在）
      }
      if (roundError != null) throw roundError;
      if (aborted) {
        throw failures.isEmpty ? const ApiException(-1, '下载失败，请检查网络后重试', '') : failures.first;
      }
    }
  }

  /// worker 内的跨临界区临时状态（Dart 单线程，不会并发访问）
  Duration? _pendingWait;

  /// 拉单个区间（**单次尝试**）。
  ///
  /// 返回"实际落盘的连续前缀"：等于 [range] 表示这一片下完了；短于它表示中途断流
  /// （调用方据此记账 + 只重下剩余部分 + 走指数退避）。
  ///
  /// [guard] 是**停滞看门狗**（2026-10-17 修复"卡在 75% 永不结束"）。它在这里做两件事：
  /// ① 给 body 流补一条**本层的读空闲守卫**（比 dio 的 `receiveTimeout` 更短，且单连接
  ///    路径的 5 分钟窗口也一并收口）——那条只会在"一字节都没有"时触发；
  /// ② 每个 chunk 给**总进度**打点并判活 —— 判活看的是聚合字节数，所以"零星到达"
  ///    （每个字节都会重置 dio 的空闲计时器）也能被抓死，那正是本故障的形态。
  Future<ByteRange> _fetchRange({
    required String url,
    required String partPath,
    required ByteRange range,
    required Dio dio,
    CancelToken? cancelToken,
    void Function(ByteRange got)? onPartial,
    _StallGuard? guard,
  }) async {
    RandomAccessFile? raf;
    var written = 0;
    var lastReported = 0;
    // 【取消竞态】一旦取消就停止上报：否则"已取消"的分片流还会继续喂 onPartial，
    // 把**并未落盘**的偏移写进 sidecar —— 下次续传就会跳过这些字节，产出坏包。
    // 双保险：闭合 raf 使后续 writeFrom 抛错，这里再用标志位掐断上报。
    var cancelled = false;
    try {
      final Response<ResponseBody> resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, dynamic>{
            'Range': 'bytes=${range.start}-${range.end}',
            'Accept-Encoding': 'identity',
          },
          validateStatus: (int? s) => s != null && s < 500,
        ),
        cancelToken: cancelToken,
      );
      if (resp.statusCode != 206) {
        // 服务端中途不再支持 Range：抛出去让上层走"缺口回填/整包重来"
        throw ApiException(-1, '服务端不支持分片下载（HTTP ${resp.statusCode}）', '');
      }
      final Stream<List<int>>? rawStream = resp.data?.stream;
      if (rawStream == null) throw const ApiException(-1, '下载流为空，请重试', '');
      // 每条连接自己的"读空闲"守卫（比 dio 的 receiveTimeout 更短、且单连接路径也覆盖）。
      // 它只负责**及时打断**一条卡住的读；是不是"整体卡死"由 [guard.onConnectionIdle] 判：
      // 这段时间里总进度也没涨 → 判死；别的连接还在正常给数据 → 只算这条连接失败。
      var bytesAtLastChunk = guard?.watchdog.bytes ?? 0;
      final Stream<List<int>> stream = guard == null
          ? rawStream
          : rawStream.timeout(
              guard.stallTimeout,
              onTimeout: (EventSink<List<int>> sink) {
                guard.onConnectionIdle(bytesAtLastChunk);
                sink.addError(const _StalledAttempt());
                sink.close();
              },
            );
      raf = await File(partPath).open(mode: FileMode.append);
      await raf.setPosition(range.start); // 关键：写到本片自己的偏移
      await for (final List<int> chunk in stream) {
        if (cancelled || cancelToken?.isCancelled == true) {
          cancelled = true;
          try {
            await raf.close(); // 立刻收走句柄 → 后续 writeFrom 必然失败
          } catch (_) {}
          throw const _Cancelled();
        }
        if (chunk.isEmpty) continue;
        if (written + chunk.length > range.length) {
          throw const ApiException(-1, '分片数据超出预期长度', '');
        }
        await raf.writeFrom(chunk);
        written += chunk.length;
        // 看门狗打点：按**真实字节流**计（不等到 1MB 上报），并用总进度判活。
        // 判死时直接中止这一片：未上报的零头不记账（下次续传会重下这一小段），
        // 因此绝不会出现"侧车跳过没写的字节"这种坏包。
        if (guard != null) {
          guard.addBytes(chunk.length);
          bytesAtLastChunk = guard.watchdog.bytes;
          if (guard.check()) throw const _StalledAttempt();
        }
        // 每 1MB 记一次"已落盘前缀"：取消/断流后这段不用重下（续传的关键）。
        // 必须先 flush 再上报 —— 否则"声称已完成"的区间可能还躺在缓冲区里，
        // 而取消时会关闭句柄丢掉未落盘数据，续传就会跳过这些字节 → 坏包。
        if (written - lastReported >= 1024 * 1024) {
          await raf.flush();
          lastReported = written;
          if (!cancelled && cancelToken?.isCancelled != true) {
            onPartial?.call(ByteRange(range.start, range.start + written - 1));
          }
        }
      }
      // 收尾也要 flush：让"整片完成"这件事在磁盘上成立（后续 registerProgress 会记账）
      await raf.flush();
      if (written > 0 && !cancelled && cancelToken?.isCancelled != true) {
        onPartial?.call(ByteRange(range.start, range.start + written - 1));
      }
      return ByteRange(range.start, range.start + written - 1);
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      // 注意：**不在这里 dio.close()** —— 同一个 Dio 被所有分片共享，
      // 单片收尾时强关会把其它分片正在读的流一起掐断（那样它们会"少收一截"却不报错）。
      // 连接池的清理交给 _downloadParallel 的收尾统一处理。
    }
  }

  /// 指数退避重试（用于缺口回填的单连接顺序补齐）：
  /// 普通失败 400ms → 800ms → 1600ms…（次数 = [ShardConfig.maxAttemptsPerShard]，≥3）；
  /// **停滞失败**另走 1s → 3s → 8s（次数 = [StallConfig.maxStallRetries]，用完即抛错）。
  ///
  /// 与旧实现的区别：**每次都把"已落盘前缀"记进 [onPartial]**，
  /// 所以断流后重试只补剩余部分，不会把同一段重复拉一遍。
  Future<ByteRange> _fetchRangeWithRetry({
    required String url,
    required String partPath,
    required ByteRange range,
    required Dio dio,
    CancelToken? cancelToken,
    void Function(ByteRange got)? onPartial,
    void Function(int attempt, int maxAttempts)? onStallRetry,
  }) async {
    ByteRange cursor = range;
    Object? last;
    int attempt = 0; // 普通失败次数
    int strikes = 0; // 停滞次数（看门狗判死）
    while (true) {
      if (cancelToken?.isCancelled == true) throw const _Cancelled();
      if (cursor.length <= 0) return range;
      final _StallGuard guard = _StallGuard(stallConfig)..begin();
      try {
        final ByteRange got = await _fetchRange(
          url: url,
          partPath: partPath,
          range: cursor,
          dio: dio,
          cancelToken: cancelToken,
          onPartial: onPartial,
          guard: guard,
        );
        if (got.length >= cursor.length) return ByteRange(range.start, got.end);
        if (got.length > 0) {
          cursor = ByteRange(got.end + 1, range.end);
          continue; // 有进展 → 立刻接着补，不等待
        }
        last = ApiException(-1, '分片 ${cursor.start}-${cursor.end} 零字节返回', '');
      } catch (e) {
        if (_isCancelled(e, cancelToken)) rethrow;
        last = e;
        if (guard.stalled) {
          // 停滞：按 1s/3s/8s 退避重试；用尽 → **明确失败**（不再无限等）
          strikes++;
          _stallDetections++;
          if (strikes > stallConfig.maxStallRetries) {
            throw const ApiException(-1, stalledMessage, '');
          }
          onStallRetry?.call(strikes, stallConfig.maxStallRetries);
          await Future<void>.delayed(stallConfig.backoffFor(strikes));
          continue;
        }
      } finally {
        guard.end();
      }
      attempt++;
      if (attempt >= shardConfig.maxAttemptsPerShard) throw last;
      await Future<void>.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
    }
  }

  // ─────────────────── 缺口回填（并行失败后的降级路径） ───────────────────

  /// 单连接顺序补齐缺失区间。**不是从零重下**：已完成的片仍然算数。
  ///
  /// 只有在"服务端连 Range 都不认了"（单个区间请求回 200）时才退回整包重下，
  /// 且那时必须把 .part 清空——否则新旧数据会在不同偏移上混起来，产出坏包。
  Future<void> _downloadGapFill({
    required String url,
    required String partPath,
    required String sidecarPath,
    required int total,
    void Function(int done, int total)? onProgress,
    void Function(double bytesPerSecond)? onSpeed,
    void Function(int attempt, int maxAttempts)? onStallRetry,
    CancelToken? cancelToken,
  }) async {
    final PartSidecar? sidecar = await _readSidecar(sidecarPath);
    final bool usable = sidecar != null && sidecar.url == url && sidecar.total == total;
    final List<ByteRange> done = usable ? sidecar.done : const <ByteRange>[];
    final int covered = ShardPlanner.coveredBytes(done);

    // 缺口 = 整包 与 已完成区间 的差集
    final List<ByteRange> gaps = ShardPlanner.pendingRanges(
      needed: <ByteRange>[ByteRange(0, total - 1)],
      done: done,
    );
    if (gaps.isEmpty) {
      onProgress?.call(total, total);
      return;
    }

    final MonotonicProgress progress = MonotonicProgress(total)..report(covered);
    final SpeedMeter meter = SpeedMeter();
    meter.sample(covered);
    onProgress?.call(progress.done, total);

    final File part = File(partPath);
    if (!await part.exists()) await part.writeAsBytes(const <int>[], flush: true);
    if (!await _ensurePadded(part, total)) {
      await _resetPart(part);
      return _downloadSingleStream(
        url: url,
        partPath: partPath,
        sidecarPath: sidecarPath,
        total: total,
        onProgress: onProgress,
        onSpeed: onSpeed,
        onStallRetry: onStallRetry,
        cancelToken: cancelToken,
      );
    }

    final List<ByteRange> doneNow = List<ByteRange>.of(done);
    final Dio dio = dioFactory();
    try {
      for (final ByteRange gap in gaps) {
        if (cancelToken?.isCancelled == true) throw const _Cancelled();
        await _fetchRangeWithRetry(
          url: url,
          partPath: partPath,
          range: gap,
          dio: dio,
          cancelToken: cancelToken,
          onStallRetry: onStallRetry,
          onPartial: (ByteRange got) {
            doneNow.add(got);
            progress.report(ShardPlanner.coveredBytes(doneNow));
            meter.sample(progress.done);
            onProgress?.call(progress.done, total);
            onSpeed?.call(meter.bytesPerSecond);
          },
        );
        doneNow.add(gap);
        progress.report(ShardPlanner.coveredBytes(doneNow));
        meter.sample(progress.done);
        onProgress?.call(progress.done, total);
        onSpeed?.call(meter.bytesPerSecond);
        // 每补完一段就更新 sidecar：中途再失败/取消时仍能续传
        await _writeSidecar(
          sidecarPath,
          PartSidecar(url: url, total: total, shards: const <ByteRange>[], done: doneNow).encode(),
        );
      }
    } finally {
      dio.close(force: true);
    }
    // 全部补齐：删除 sidecar，交给上层做大小/哈希校验
    await _deleteQuietly(sidecarPath);
  }

  // ───────────────────── 单连接整包（历史行为） ─────────────────────

  /// 单连接流式下载（支持 Range 时从断点续传）。这是**小文件与不支持 Range
  /// 的服务端的回退路径**，行为与提速改造前一致，只多了一层停滞判活
  /// （2026-10-17）：停滞 → 1s/3s/8s 退避后**续传重试** → 上限用尽 → 明确失败。
  /// **绝不允许无限期 0 MB/s**：这条路径同样会卡死（同样是 body 流没有超时）。
  Future<void> _downloadSingleStream({
    required String url,
    required String partPath,
    required String sidecarPath,
    required int total,
    void Function(int done, int total)? onProgress,
    void Function(double bytesPerSecond)? onSpeed,
    void Function(int attempt, int maxAttempts)? onStallRetry,
    CancelToken? cancelToken,
  }) async {
    int attempt = 0; // 普通失败次数
    int strikes = 0; // 停滞次数
    while (true) {
      final _StallGuard guard = _StallGuard(stallConfig)..begin();
      try {
        await _singleStreamAttempt(
          url: url,
          partPath: partPath,
          sidecarPath: sidecarPath,
          total: total,
          onProgress: onProgress,
          onSpeed: onSpeed,
          cancelToken: cancelToken,
          guard: guard,
        );
        return;
      } catch (e) {
        if (_isCancelled(e, cancelToken)) rethrow;
        if (guard.stalled) {
          strikes++;
          _stallDetections++;
          if (strikes > stallConfig.maxStallRetries) {
            throw const ApiException(-1, stalledMessage, '');
          }
          // 与分片路径同口径：让 UI 显示"正在重试（n/3）"，进度条不回退
          onStallRetry?.call(strikes, stallConfig.maxStallRetries);
          onSpeed?.call(0);
          await Future<void>.delayed(stallConfig.backoffFor(strikes));
          continue; // 退避后重试：.part 长度就是续传起点，只补缺口
        }
        attempt++;
        if (attempt >= shardConfig.maxAttemptsPerShard) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
      } finally {
        guard.end();
      }
    }
  }

  /// 单连接一次尝试（真正的流式读写）；重试/停滞由 [_downloadSingleStream] 负责。
  Future<void> _singleStreamAttempt({
    required String url,
    required String partPath,
    required String sidecarPath,
    required int total,
    void Function(int done, int total)? onProgress,
    void Function(double bytesPerSecond)? onSpeed,
    CancelToken? cancelToken,
    required _StallGuard guard,
  }) async {
    final File part = File(partPath);
    // 单连接路径下 .part 必须是"从 0 开始连续"的——所以先删掉可能存在的
    // 分片残留（否则续传偏移与文件内容对不上，会拼出坏包）
    if (await _readSidecar(sidecarPath) != null) {
      await _resetPart(part);
      await _deleteQuietly(sidecarPath);
    }
    int existing = await part.exists() ? await part.length() : 0;
    if (total > 0 && existing == total) {
      onProgress?.call(total, total);
      return;
    }
    if (total > 0 && existing > total) {
      await _resetPart(part);
      existing = 0;
    }

    final Dio dio = dioFactory();
    final SpeedMeter meter = SpeedMeter();
    final MonotonicProgress progress = MonotonicProgress(total > 0 ? total : existing);
    progress.report(existing);
    meter.sample(existing);
    onProgress?.call(progress.done, total > 0 ? total : existing);
    IOSink? sink;
    try {
      final Response<ResponseBody> resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, dynamic>{
            if (existing > 0) 'Range': 'bytes=$existing-',
            'Accept-Encoding': 'identity',
          },
          validateStatus: (int? s) => s == 200 || s == 206,
          // ⚠️ 单连接路径的历史值是 5 分钟（"大文件整包：单次读间隔放宽"）——对"完全静默"
          // 太钝（用户会盯着 0.00 MB/s 等 5 分钟）。真正的判活是 guard（总进度看门狗）。
          receiveTimeout: const Duration(minutes: 5),
        ),
        cancelToken: cancelToken,
      );
      // 服务端忽略了 Range（回 200）→ 它会把整包从头发过来，必须截断重写，
      // 否则"旧数据 + 新的整包"拼出坏文件
      final bool verify = resp.statusCode == 200 && existing > 0;
      if (verify) {
        await _resetPart(part);
        existing = 0;
        progress.reset();
        meter.reset();
        meter.sample(0);
      }
      final Stream<List<int>>? rawStream = resp.data?.stream;
      if (rawStream == null) throw const ApiException(-1, '下载流为空，请重试', '');
      // 读空闲守卫 + 总进度判活（口径与分片路径完全一致，见 _fetchRange）
      var bytesAtLastChunk = guard.watchdog.bytes;
      final Stream<List<int>> stream = rawStream.timeout(
        guard.stallTimeout,
        onTimeout: (EventSink<List<int>> sink) {
          guard.onConnectionIdle(bytesAtLastChunk);
          sink.addError(const _StalledAttempt());
          sink.close();
        },
      );
      sink = part.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      // 本片起点（续传时 = 已有字节数；服务端忽略 Range 时已归零）
      final int baseOffset = existing;
      await for (final List<int> chunk in stream) {
        if (cancelToken?.isCancelled == true) throw const _Cancelled();
        sink.add(chunk);
        guard.addBytes(chunk.length);
        bytesAtLastChunk = guard.watchdog.bytes;
        if (guard.check()) throw const _StalledAttempt();
        progress.report(baseOffset + chunk.length);
        meter.sample(progress.done);
        onProgress?.call(progress.done, total > 0 ? total : progress.done);
        onSpeed?.call(meter.bytesPerSecond);
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      dio.close(force: true);
    }
  }

  // ───────────────────────────── 工具 ─────────────────────────────

  /// 把校验完备的 `.part` 提升为最终 `.apk`。
  ///
  /// Windows 上"另一个句柄还开着"时 rename 会失败（ERROR_SHARING_VIOLATION，errno 32）——
  /// 典型场景是上一次取消/失败的下载留下一个尚未完全收尾的分片写句柄。
  /// 生产（Android/Linux）不会有这个问题，但**契约上不能依赖平台差异**：
  /// 这里先短暂重试，再退化为"复制内容 + 删原文件"，保证"下完了就一定能安装"。
  Future<void> _promote(File part, File save) async {
    if (await save.exists()) {
      try {
        await save.delete();
      } catch (_) {}
    }
    for (int i = 0; i < 10; i++) {
      try {
        await part.rename(save.path);
        return;
      } catch (_) {
        await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
    // 兜底：复制内容（此时 .part 至少可读），成功后再删临时文件
    await part.copy(save.path);
    await _deleteQuietly(part.path);
  }

  /// 把 .part 预分配到 [total] 字节（稀疏文件），保证各片能按偏移写入；
  /// 失败（磁盘满/不支持 seek）返回 false，由调用方决定降级。
  ///
  /// ⚠️ 必须用 [FileMode.append]：`FileMode.writeOnly` 打开时会**截断已有内容**
  /// （2026-10-06 实测确认），那会把上一轮的续传进度整个抹掉——表现为"续传后
  /// 已下区间变成全 0、sha256 不过"。append 模式既保留原数据，也仍受 setPosition
  /// 控制写入偏移（同样实测确认），因此是安全的扩展方式。
  Future<bool> _ensurePadded(File part, int total) async {
    try {
      if (!await part.exists()) await part.writeAsBytes(const <int>[], flush: true);
      final int len = await part.length();
      if (len >= total) return true; // 已经够长：绝不能再打开（避免任何截断风险）
      final RandomAccessFile raf = await part.open(mode: FileMode.append);
      try {
        await raf.setPosition(total - 1);
        await raf.writeFrom(const <int>[0]);
        await raf.flush();
      } finally {
        await raf.close();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _resetPart(File part) async {
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }

  Future<PartSidecar?> _readSidecar(String path) async {
    try {
      final File f = File(path);
      if (!await f.exists()) return null;
      return PartSidecar.tryDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// 原子写 sidecar：先写 `.tmp` 再 rename 覆盖。
  ///
  /// 为什么要重试：Windows 上目标/临时文件被别的句柄短暂占用时 rename 会失败
  /// （ERROR_SHARING_VIOLATION）。**失败必须重试**，否则 sidecar 会停留在旧版本
  /// ——"已下完的区间"没记上只是重下（能自愈），但配合"文件被截断"等异常就可能
  /// 记上并未落盘的字节（续传跳过 → 坏包）。失败时清掉 .tmp，不留垃圾。
  Future<void> _writeSidecar(String path, String body) async {
    final String tmpPath = '$path.tmp';
    try {
      await File(tmpPath).writeAsString(body, flush: true);
    } catch (_) {
      return;
    }
    for (int i = 0; i < 5; i++) {
      try {
        await File(tmpPath).rename(path);
        return;
      } catch (_) {
        await Future<void>.delayed(Duration(milliseconds: 60 * (i + 1)));
      }
    }
    await _deleteQuietly(tmpPath); // 最终失败：不影响已下数据，只丢一次进度记录
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static bool _isCancelled(Object e, CancelToken? token) {
    if (e is _Cancelled) return true;
    if (token?.isCancelled == true) return true;
    return e is DioException && e.type == DioExceptionType.cancel;
  }

  /// 校验下载文件 sha256（不一致抛异常，调用方删除文件并提示重新下载）
  Future<void> verifyHash(String filePath, String expectedSha256) async {
    final f = File(filePath);
    if (!await f.exists()) throw const ApiException(-1, '安装包文件不存在', '');
    final hash = await sha256.bind(f.openRead()).first;
    final actual = hash.toString();
    if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
      throw ApiException(-1, '安装包校验失败（文件损坏），请重新下载', '');
    }
  }

  /// 计算文件 sha256（测试/诊断用；流式，不进内存）
  Future<String> fileSha256(String filePath) async {
    final f = File(filePath);
    if (!await f.exists()) throw const ApiException(-1, '安装包文件不存在', '');
    return (await sha256.bind(f.openRead()).first).toString();
  }

  /// 删除下载产物（校验失败时调用，确保不安装坏包）
  Future<void> discard(String filePath) async {
    await _deleteQuietly(filePath);
    await _deleteQuietly('$filePath.part');
    await _deleteQuietly('$filePath.part${PartSidecar.suffix}');
  }
}

/// 退避中的待重试区间（含到期时刻与已失败次数）
class _Retry {
  _Retry(this.range, this.at, this.attempt);
  final ByteRange range;

  /// 早于此时刻不重试（指数退避）
  final DateTime at;

  /// 已失败次数（达到 [ShardConfig.maxAttemptsPerShard] 即放弃并行路径）
  final int attempt;
}

/// 一次 Range 探测的结果
class ProbeResult {  const ProbeResult({required this.rangeSupported, required this.total});

  /// 服务端是否支持 `Accept-Ranges: bytes`（拿得到 206 + Content-Range）
  final bool rangeSupported;

  /// 整包总字节数（Content-Range 的 TOTAL 优先，其次 Content-Length）
  final int total;

  @override
  String toString() => 'ProbeResult(range=$rangeSupported, total=$total)';
}

/// 内部取消哨兵（把"用户取消"与"网络失败"区分开：前者不重试、不降级）
class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => '下载已取消';
}

/// 停滞哨兵（看门狗判死；与用户取消严格区分：停滞要**退避重试/降级**，取消不重试）
class _StalledAttempt implements Exception {
  const _StalledAttempt();
  @override
  String toString() => '下载停滞（总进度长时间不增长）';
}

/// 停滞看门狗守卫：把"总进度看门狗 + 本轮是否已判死 + 在飞请求数"合成一个对象。
///
/// - [addBytes]/[check] 由 [_fetchRange] 每读到一个 chunk 调用（**细粒度**：
///   不是按 1MB 上报打点，否则慢到 50KB/s 也会被误判）；
/// - [begin]/[end] 由下载循环在请求前后调用：在飞请求数为 0（退避等待、收尾）
///   时**暂停计时**——"没人下载"不是"下载卡死"。
class _StallGuard {
  _StallGuard(StallConfig config)
      : watchdog = ProgressWatchdog(
          timeout: config.stallTimeout,
          minGrowthBytes: config.minGrowthBytes,
        ),
        _config = config;

  final StallConfig _config;
  final ProgressWatchdog watchdog;

  int _inFlight = 0;
  bool _stalled = false;

  Duration get stallTimeout => _config.stallTimeout;
  bool get stalled => _stalled;

  void begin() {
    _inFlight++;
    if (_inFlight == 1) watchdog.resume();
  }

  void end() {
    if (_inFlight > 0) _inFlight--;
    if (_inFlight == 0) watchdog.pause();
  }

  void addBytes(int n) => watchdog.addBytes(n);

  /// 判活：返回 true = **总进度已停滞**（本轮判死）
  bool check() {
    if (_stalled) return true;
    if (watchdog.check()) _stalled = true;
    return _stalled;
  }

  /// 某条连接已经"读空闲"满 [stallTimeout]（由流的空闲守卫判定）时调用。
  ///
  /// [bytesWhenIdleStarted] = 这条连接**最后一个字节到达时**的总进度。
  /// 判定口径（与"总进度"完全一致，且没有时钟竞态——两条超时可能同一毫秒到期）：
  /// 这段"这条连接一字节都没来"的窗口里，**总进度也没涨到阈值** → 全局判死。
  /// 反之（别的连接在正常供数据）说明只是这条连接掉队 → 交给既有单连接失败重试，
  /// **不拖垮整轮**。
  bool onConnectionIdle(int bytesWhenIdleStarted) {
    if (_stalled) return true;
    if (watchdog.bytes - bytesWhenIdleStarted < _config.minGrowthBytes) _stalled = true;
    return _stalled;
  }
}

/// 共享状态更新的临界区标注（**不是锁**）。
///
/// Dart 是单线程事件循环：只要临界区内**不含 `await`**，就是原子的。并行下载的
/// 共享状态（work 队列 / doneNow / 失败计数）全部只在同步块里改，所以不存在
/// 两个连接拿到同一片的竞态。这里保留一个具名包裹只是为了把"这段是临界区"
/// 标出来，便于 review —— 千万不要在闭包里加 await。
T synchronized<T>(Object lock, T Function() action) => action();

/// 更新信息（与 GET /public/app-versions/latest 返回结构对应）
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.hasUpdate,
    required this.force,
    required this.versionCode,
    required this.versionName,
    required this.updateDesc,
    required this.fileSize,
    required this.fileHash,
    required this.downloadUrl,
  });

  final bool hasUpdate;
  final bool force;
  final int versionCode;
  final String versionName;
  final String updateDesc;
  final int fileSize;
  final String fileHash;

  /// 相对路径（服务端返回 /api/v1/...）已解析为绝对地址；
  /// **绝对 URL（CDN/镜像）原样保留** —— 多源下载靠这一点（AppConfig.resolveMediaUrl）。
  final String downloadUrl;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final has = json['hasUpdate'] == true;
    final latest = (json['latest'] as Map<String, dynamic>?) ?? const {};
    return AppUpdateInfo(
      hasUpdate: has,
      force: json['force'] == true,
      versionCode: (latest['versionCode'] as num?)?.toInt() ?? 0,
      versionName: '${latest['versionName'] ?? ''}',
      updateDesc: '${latest['updateDesc'] ?? ''}',
      fileSize: (latest['fileSize'] as num?)?.toInt() ?? 0,
      fileHash: '${latest['fileHash'] ?? ''}',
      downloadUrl: has ? AppConfig.resolveMediaUrl('${latest['downloadUrl'] ?? ''}') : '',
    );
  }
}
