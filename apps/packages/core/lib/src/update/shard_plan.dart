/// 云更新「多连接分片下载」的**纯逻辑层**（无 IO、无 Dio）——分片计算 / 续传区间 /
/// 进度速度聚合三段都可单测，网络与磁盘细节留在 AppUpdater。
///
/// 为什么单独成文件（而不是写进 app_updater.dart）：
/// 一是这几段是"算错了就下出坏包"的关键逻辑，必须能脱离网络单测边界值；
/// 二是 AppUpdater 里已有单连接整包逻辑，混在一起会看不清两条路径的边界。
library;

import 'dart:convert';

/// 分片下载参数（默认值 + 取值理由见各类注释；调用方可整体替换以便调优）
class ShardConfig {
  const ShardConfig({
    this.maxConnections = 12,
    this.hardMaxConnections = 16,
    this.thresholdBytes = 4 * 1024 * 1024,
    this.maxAttemptsPerShard = 3,
    this.degradeAfterConsecutiveFailures = 2,
    this.minShardBytes = 512 * 1024,
    this.piecesPerConnection = 4,
    this.maxPieces = 64,
  });

  /// 默认并发连接数。
  ///
  /// **2026-10-17 由 4 提到 12**（负责人反馈"下载速度巨慢"后实测，同一台机器/同一条出口，
  /// 云端 id 138 / 23,226,112 B，20 秒窗口聚合）：
  ///
  /// | 连接数 | 聚合速度 | 预计整包 |
  /// |---|---|---|
  /// | 1 | 17.3 KB/s | 21.8 分钟 |
  /// | 4 | 243.9 KB/s | 93 秒 |
  /// | 8 | 281.3 KB/s | 81 秒 |
  /// | **12** | **480.6 KB/s** | **47 秒** |
  /// | 16 | 490.6 KB/s | 46 秒 |
  /// | 24 | 520.8 KB/s | 44 秒 |
  ///
  /// 关键事实：**每条连接被单独限速**（1 条 17.3 KB/s，而 12 条时聚合 480.6 KB/s
  /// ≈ 28×，单条仍有 40 KB/s），所以"多开连接"是唯一能真正提速的杠杆；
  /// 12 条已到拐点（12→16 只 +2%、12→24 只 +8%，落在测量噪声里），
  /// 再多只是把并发压力和弱网降级风险翻倍。故取 **12**（硬顶 16 留给将来调优）。
  /// 旧的 4（2026-10-06 在 ngrok 免费档上测得"8 不一定比 4 快"）已随云服务器
  /// 直连链路作废：那时的瓶颈是隧道**总吞吐天花板**，现在瓶颈是**单连接限速**。
  final int maxConnections;

  /// 并发上限硬顶（服务端/中间设备可能对并发有隐性限制；配置再大也不超过它）
  ///
  /// 取 16：① 实测 16 条仍全部 206 且速度是 12 的 1.02 倍（无崩塌迹象）；
  /// ② HTTP/1.1 下每条 Range 连接 = 一条独占 TCP（没有多路复用），并发数就是
  ///    socket 数 —— 移动端 16 条 socket + 64KiB 级缓冲完全吃得下；
  /// ③ 再往上（24 条）聚合只 +8%，但家用/移动 NAT 的**每流限速与连接配额**
  ///    风险明显上升，服务端每客户端连接数也线性增长 ⇒ 16 是"收益已兑现"的位置。
  final int hardMaxConnections;

  /// 分片下载阈值：小于此大小**不并行**。
  ///
  /// 取值 4MB 的理由：分片收益来自"用并发换单连接限速"，而小文件（几百 KB～几 MB）
  /// 的耗时主要花在**建连/隧道握手**上（实测 ngrok 隧道 TTFB 0.45–0.85s，Cloudflare 约 1.0–1.6s），
  /// 开 N 条连接只是把握手成本乘以 N，反而更慢；且小文件整包一个流就完事了。
  /// 4MB 在隧道上单连接约 2–40s，此时并行收益明确为正。
  final int thresholdBytes;

  /// 单片最大尝试次数（含首次）；失败按指数退避重试后仍失败 → 触发整包回退
  final int maxAttemptsPerShard;

  /// 连续失败达到该次数 → 并发数减半（弱网降级），最少降到 1
  final int degradeAfterConsecutiveFailures;

  /// **单片最小字节**（钳制）：把片切得比它更小没有收益。
  ///
  /// 取 512KiB：① 每片都要付一次"建连 + 首字节"成本（本链路实测 TTFB 0.49s，
  /// 而单条连接履约速率最低约 10–17 KB/s），512KiB 在这种速率下要传 ~30–50s，
  /// 握手成本占比 <5%；再小（如 128KiB）占比就升到 15–20%，纯粹浪费；
  /// ② 512KiB 也远大于"一次 Range 请求"的报文开销，且让看门狗（20s 窗口）
  /// 能在一片之内观察到"到底有没有在动"。文件本身比它小则不切（只有 1 片）。
  final int minShardBytes;

  /// **每连接的队列深度**：片数 = 并发 × 该系数（再受 [minShardBytes] / [maxPieces] 约束）。
  ///
  /// 为什么片数要**多于**并发数（2026-10-17 实测）：同一时刻各条连接的速率差到
  /// **7.6 倍**（20 秒窗口里最慢 10.2 KB/s、最快 77.3 KB/s）。片数 = 并发数时，
  /// 每条连接被钉死在一片 5.8MB 上 → **最慢那条决定整体耗时**（实测按聚合速度
  /// 该 1.3 分钟下完，按尾片要 4.75 分钟，这就是"巨慢"的第二层原因）。
  /// 片数远多于并发后，快的连接领完自己的片会继续领后面的，尾片从 5.8MB 缩到
  /// 单片大小（~0.5MB）⇒ 整体耗时回到"聚合速度"决定。取 4 是队列深度的常规拐点
  /// （再多只是把队列拉长，收益递减）。
  final int piecesPerConnection;

  /// 片数上限（内存/队列/请求预算的兜底刹车）
  final int maxPieces;

  /// 只改并发数（弱网降级用）——**必须走这个方法**：直接 new 一个 ShardConfig
  /// 会把 [minShardBytes]/[piecesPerConnection]/[maxPieces] 悄悄退回默认值
  /// （那是 2026-10-17 之前真实的写法 bug 风险）。
  ShardConfig withConnections(int n) => ShardConfig(
        maxConnections: n,
        hardMaxConnections: hardMaxConnections,
        thresholdBytes: thresholdBytes,
        maxAttemptsPerShard: maxAttemptsPerShard,
        degradeAfterConsecutiveFailures: degradeAfterConsecutiveFailures,
        minShardBytes: minShardBytes,
        piecesPerConnection: piecesPerConnection,
        maxPieces: maxPieces,
      );

  /// 生效并发数（受硬顶约束，且至少 1）
  int clampConnections(int n) {
    if (n < 1) return 1;
    return n > hardMaxConnections ? hardMaxConnections : n;
  }
}

/// 「停滞判活」参数（2026-10-17 修复线上故障：**下载卡在 75%、0.00 MB/s、永不结束**）。
///
/// ## 为什么必须有它（真根因，实测 dio 5.11.1 源码）
/// dio 的 `receiveTimeout` 是**每条连接"两块数据之间"的空闲计时器**，而且
/// **收到任何一个字节就重置**（`response_stream_handler.dart`）。于是有两个盲区：
///   1. **"零星到达"把它无限续命**：每 60s 内挤进几个字节就永不报错，而聚合进度几乎
///      不涨 —— 用户看到的就是 `75% · 0.00 MB/s · 计算中…`（负责人真机截图）；
///   2. **它只认单条连接**：4 片里 3 片死掉、只剩 1 片慢慢挪，聚合进度"还在动"，
///      没有任何一层能判定"这次下载已经废了"。
/// 所以判活必须建立在**总进度**上（而不是单连接空闲上），这也是本类存在的唯一理由。
///
/// ## 取值理由
/// - [stallTimeout] = **20 秒**：判活窗口必须**远大于**建连/首字节成本（实测隧道 TTFB
///   0.45–0.85s、Cloudflare 1.0–1.6s），又要远小于"用户以为死机"的耐心。20s 是
///   ~80 个跨境 RTT（实测香港服务器本机 RTT 245ms）——链路有 80 次往返机会送数据；
///   反过来，一旦真的停滞，用户最多等 ~20s + 退避就能看到明确结果（而不是永远等）。
/// - [minGrowthBytes] = **16 KiB**：窗口内总增量低于它即视为"没有实质进展"，等价于
///   持续速率 < 0.8 KB/s（UI 上就是「0.00 MB/s」）。**取值用真机实测标定**
///   （2026-10-17，本机 → 香港 YOUR_SERVER_HOST，同一分片同一条连接）：
///   t=5s 拿到 106,137B（段均速 20.7 KB/s）／t=10s 133,497B（13.0）／t=15s 176,697B（11.5）
///   ／t=20s 228,537B（11.2）—— 每 5 秒窗口的**瞬时**速度只有 5.5 / 8.6 / 10.4 KB/s。
///   也就是说这条跨境链路本来就常在 10 KB/s 上下徘徊：门槛必须**远低于**它才不误杀，
///   16 KiB/20s（0.8 KB/s）留出 7–13 倍余量，同时仍能抓死真正的故障态
///   （0.8 KB/s ⇒ 22MB 要 7.8 小时 = 事实上就是"永远下不完"）。
/// - [maxStallRetries] = 3 + [retryBackoff] = 1s/3s/8s：先给 3 次**续传式**重试机会
///   （跨境链路抖动是常态，重试就能补上），仍卡死才降级单连接；退避递增是为了不把
///   已经拥塞的链路再打满。
class StallConfig {
  const StallConfig({
    this.stallTimeout = const Duration(seconds: 20),
    this.minGrowthBytes = 16 * 1024,
    this.maxStallRetries = 3,
    this.retryBackoff = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
    ],
  });

  /// 判死窗口：连续这么久"总进度几乎不增长"即判定本次尝试卡死
  final Duration stallTimeout;

  /// 窗口内至少要涨这么多字节才算"有进展"（否则算停滞）
  final int minGrowthBytes;

  /// 停滞重试上限（用完即降级单连接续传）
  final int maxStallRetries;

  /// 第 n 次停滞后的退避（n 从 1 开始；超出表长取最后一个）
  final List<Duration> retryBackoff;

  Duration backoffFor(int strike) {
    if (retryBackoff.isEmpty) return Duration.zero;
    final int i = (strike - 1).clamp(0, retryBackoff.length - 1);
    return retryBackoff[i];
  }
}

/// 进度看门狗（纯逻辑、可注入时钟）——判活口径：**总字节数在窗口内几乎不增长**。
///
/// 与"空闲超时"的区别（本故障的关键）：空闲超时会被"零星到几个字节"无限续命
/// （每个字节都算一次事件），而这里比的是**窗口内累计增量**：
/// 1 字节/10 秒 也会被判定为停滞，因为 20 秒里只涨了 2 字节 < [minGrowthBytes]。
///
/// 用法：`addBytes(每 chunk)` 持续打点；`check()` 判活；`pause()/resume()` 在
/// "没有任何请求在飞"（退避等待/收尾）期间暂停计时——等待不算停滞。
class ProgressWatchdog {
  ProgressWatchdog({
    this.timeout = const Duration(seconds: 20),
    this.minGrowthBytes = 16 * 1024,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now {
    _anchorAt = _now();
  }

  /// 判死窗口
  final Duration timeout;

  /// 窗口内最小增量
  final int minGrowthBytes;

  final DateTime Function() _now;

  /// 累计已落盘字节（含尚未按 MB 上报的零头）
  int _bytes = 0;

  DateTime? _anchorAt;
  int _anchorBytes = 0;
  bool _paused = false;

  /// 累计字节（诊断/测试用）
  int get bytes => _bytes;

  /// 打点：把新落盘的字节计入总进度（不判活）
  void addBytes(int n) {
    if (n > 0) _bytes += n;
  }

  /// 暂停计时（在飞请求数归零时调用）：退避等待期间不算停滞
  void pause() {
    _paused = true;
  }

  /// 恢复计时（重新有请求在飞时调用）：以此刻为新基准
  void resume({DateTime? at}) {
    _paused = false;
    _anchorAt = at ?? _now();
    _anchorBytes = _bytes;
  }

  /// 判活：返回 true = **已停滞**（窗口内增量 < [minGrowthBytes]）
  ///
  /// 增量够了就把基准推到此刻（滑动窗口），所以"慢而稳"的下载永远不会被判死
  /// —— 只要平均速率 ≥ [minGrowthBytes] / [timeout]（默认 0.8 KB/s）。
  bool check({DateTime? at}) {
    final DateTime now = at ?? _now();
    if (_paused) {
      _anchorAt = now;
      _anchorBytes = _bytes;
      return false;
    }
    final DateTime? anchor = _anchorAt;
    if (anchor == null) {
      _anchorAt = now;
      _anchorBytes = _bytes;
      return false;
    }
    if (_bytes - _anchorBytes >= minGrowthBytes) {
      _anchorAt = now;
      _anchorBytes = _bytes;
      return false;
    }
    return now.difference(anchor) >= timeout;
  }

  /// 距上次"有实质进展"已经过去多久（诊断/日志用）
  Duration idleFor({DateTime? at}) {
    final DateTime? anchor = _anchorAt;
    if (anchor == null) return Duration.zero;
    return (at ?? _now()).difference(anchor);
  }
}

/// 一个字节区间（左闭右闭，与 HTTP Range 语义一致）
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start + 1;
  bool get isEmpty => end < start;

  @override
  String toString() => '$start-$end';

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// 分片计算（纯函数，重点覆盖边界：远小于阈值 / 恰好等于阈值 / 略大于阈值 / 超大）
class ShardPlanner {
  const ShardPlanner._();

  /// 是否满足分片下载条件：支持 Range + 已知大小 + 大于等于阈值。
  ///
  /// 注意用 `>=`：需求写的是"文件 ≥ 4MB 且支持 Range 时切 N 片"，
  /// "远小于"和"小于"都走单连接。
  static bool shouldShard({
    required bool rangeSupported,
    required int fileSize,
    ShardConfig config = const ShardConfig(),
  }) {
    if (!rangeSupported) return false;
    if (fileSize < config.thresholdBytes) return false;
    return true;
  }

  /// 把 [total] 字节切成至多 [connections] × [ShardConfig.piecesPerConnection] 片
  /// （每片长度基本相等，余数摊到前几片）。
  ///
  /// 关键不变量（续传与最终校验都依赖它）：
  ///   1. 各片首尾相接、无重叠、无空隙；
  ///   2. 覆盖 [0, total-1] 全部字节；
  ///   3. 每片长度 ≥ 1。
  ///
  /// 片数 = `min(并发 × 队列深度, maxPieces, total ~/ minShardBytes, total)`
  /// 且 ≥ 1（见 [ShardConfig.minShardBytes] / [ShardConfig.piecesPerConnection]：
  /// 片数**多于**并发是为了让慢连接不拖尾）。
  static List<ByteRange> split({
    required int total,
    required int connections,
    ShardConfig config = const ShardConfig(),
  }) {
    if (total <= 0) return const <ByteRange>[];
    final int n = _effectiveShards(total: total, connections: connections, config: config);
    final int base = total ~/ n;
    final int remainder = total % n;
    final List<ByteRange> out = <ByteRange>[];
    int cursor = 0;
    for (int i = 0; i < n; i++) {
      final int len = base + (i < remainder ? 1 : 0);
      out.add(ByteRange(cursor, cursor + len - 1));
      cursor += len;
    }
    return out;
  }

  /// 实际片数：并发 × 队列深度，再受"单片下限 / 片数上限 / 字节数"三重约束
  static int _effectiveShards({
    required int total,
    required int connections,
    required ShardConfig config,
  }) {
    final int live = config.clampConnections(connections);
    int n = live * (config.piecesPerConnection < 1 ? 1 : config.piecesPerConnection);
    // 单片下限：片数不超过 total ~/ minShardBytes（保证每片 ≥ 下限；文件本身比下限还小
    // 就只有 1 片 —— 绝不会为小文件切出一堆碎片）。
    if (config.minShardBytes > 0) {
      final int byFloor = total ~/ config.minShardBytes;
      n = byFloor < 1 ? 1 : (byFloor < n ? byFloor : n);
    }
    if (config.maxPieces > 0 && n > config.maxPieces) n = config.maxPieces;
    if (n > total) n = total;
    return n < 1 ? 1 : n;
  }

  /// 续传用：从 [needed] 中剔除 [done] 已完成的区间，返回还缺的区间。
  ///
  /// 输出按 start 升序，用于"中断后重进只补缺失片"。
  static List<ByteRange> pendingRanges({
    required List<ByteRange> needed,
    required List<ByteRange> done,
  }) {
    if (needed.isEmpty) return const <ByteRange>[];
    final List<ByteRange> merged = mergeRanges(done);
    final List<ByteRange> out = <ByteRange>[];
    for (final ByteRange want in needed) {
      if (want.isEmpty) continue;
      int cursor = want.start;
      for (final ByteRange d in merged) {
        if (d.end < cursor) continue; // 完全在游标左侧
        if (d.start > want.end) break; // 已越过本片
        if (d.start > cursor) {
          out.add(ByteRange(cursor, (d.start - 1).clamp(cursor, want.end)));
        }
        if (d.end + 1 > cursor) cursor = d.end + 1;
        if (cursor > want.end) break;
      }
      if (cursor <= want.end) out.add(ByteRange(cursor, want.end));
    }
    return out;
  }

  /// 合并重叠/相邻区间（sidecar 里区间可能因并发追加而乱序重叠）
  static List<ByteRange> mergeRanges(List<ByteRange> raw) {
    final List<ByteRange> sorted = raw.where((ByteRange r) => !r.isEmpty).toList()
      ..sort((ByteRange a, ByteRange b) => a.start.compareTo(b.start));
    final List<ByteRange> out = <ByteRange>[];
    for (final ByteRange r in sorted) {
      if (out.isEmpty) {
        out.add(r);
        continue;
      }
      final ByteRange last = out.last;
      if (r.start <= last.end + 1) {
        out[out.length - 1] = ByteRange(last.start, r.end > last.end ? r.end : last.end);
      } else {
        out.add(r);
      }
    }
    return out;
  }

  /// 已完成字节数（合并区间后求和，避免重叠重复计算）
  static int coveredBytes(List<ByteRange> ranges) =>
      mergeRanges(ranges).fold<int>(0, (int a, ByteRange r) => a + r.length);
}

/// 续传 sidecar（`xxx.apk.part.json`）的序列化模型。
///
/// 为什么需要它：`.part` 文件只能告诉我们"文件有多大"，无法告诉我们
/// **哪些区间是真的下完了**。并行分片下每片分布在不同偏移，缺一段就是坏包，
/// 所以必须把"已完成区间"落盘；下载成功即删除，不留残留。
class PartSidecar {
  PartSidecar({
    required this.url,
    required this.total,
    required this.shards,
    required this.done,
  });

  /// 下载源 URL（换源/换版本时 sidecar 失效，必须重下）
  final String url;

  /// 整包总字节数
  final int total;

  /// 本次分片计划（用来验证 sidecar 与当前计划一致）
  final List<ByteRange> shards;

  /// 已完成区间（按需合并）
  final List<ByteRange> done;

  static const String suffix = '.part.json';
  static const int _version = 1;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': _version,
        'url': url,
        'total': total,
        'shards': shards.map((ByteRange r) => <int>[r.start, r.end]).toList(),
        'done': ShardPlanner.mergeRanges(done).map((ByteRange r) => <int>[r.start, r.end]).toList(),
      };

  String encode() => jsonEncode(toJson());

  /// 解析；**任何异常/字段缺失/版本不符都返回 null**（宁可重下，不可信任坏 sidecar）
  static PartSidecar? tryDecode(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != _version) return null;
      final int total = (decoded['total'] as num?)?.toInt() ?? 0;
      final String url = '${decoded['url'] ?? ''}';
      if (total <= 0 || url.isEmpty) return null;
      return PartSidecar(
        url: url,
        total: total,
        shards: _ranges(decoded['shards']),
        done: _ranges(decoded['done']),
      );
    } catch (_) {
      return null;
    }
  }

  static List<ByteRange> _ranges(Object? raw) {
    if (raw is! List) return const <ByteRange>[];
    final List<ByteRange> out = <ByteRange>[];
    for (final Object? e in raw) {
      if (e is List && e.length >= 2) {
        final int? s = (e[0] as num?)?.toInt();
        final int? t = (e[1] as num?)?.toInt();
        if (s != null && t != null && t >= s && s >= 0) out.add(ByteRange(s, t));
      }
    }
    return out;
  }
}

/// 速度/剩余时间聚合（弹窗展示"实时速度 + 预计剩余时间"）。
///
/// 速度用**滑动窗口**而非"总字节/总耗时"：后者在隧道抖动时反应迟钝，
/// 用户会看到"速度一直不变"。窗口内取平均，既能反映当前速率又不至于数字乱跳。
class SpeedMeter {
  SpeedMeter({this.window = const Duration(seconds: 3)});

  /// 滑动窗口长度
  final Duration window;

  final List<_Sample> _samples = <_Sample>[];

  /// 记录一次累计进度采样（[at] 仅供测试注入时钟）
  void sample(int bytes, {DateTime? at}) {
    final DateTime now = at ?? DateTime.now();
    _samples.add(_Sample(now, bytes));
    final DateTime edge = now.subtract(window);
    while (_samples.length > 1 && _samples.first.at.isBefore(edge)) {
      _samples.removeAt(0);
    }
  }

  /// 最近窗口内的平均速度（字节/秒）；样本不足或时间跨度为 0 → 0
  double get bytesPerSecond {
    if (_samples.length < 2) return 0;
    final _Sample first = _samples.first;
    final _Sample last = _samples.last;
    final int ms = last.at.difference(first.at).inMilliseconds;
    if (ms <= 0) return 0;
    final int delta = last.bytes - first.bytes;
    if (delta <= 0) return 0;
    return delta * 1000 / ms;
  }

  /// 预计剩余时间；速度为 0 时返回 null（弹窗显示"计算中"）
  Duration? eta(int remainingBytes) {
    final double v = bytesPerSecond;
    if (v <= 0 || remainingBytes <= 0) return null;
    final double secs = remainingBytes / v;
    if (secs.isNaN || secs.isInfinite || secs > 86400) return null;
    return Duration(milliseconds: (secs * 1000).round());
  }

  void reset() => _samples.clear();
}

class _Sample {
  _Sample(this.at, this.bytes);
  final DateTime at;
  final int bytes;
}

/// 单调进度护栏：并行分片下各片完成顺序不定、且有重试导致的回退，
/// 直接报"当前累计字节"会让进度条**倒退**。这里保证对外数值只增不减。
class MonotonicProgress {
  MonotonicProgress(this.total);

  /// 总字节数（服务端 Content-Length / Range 探测得到）
  final int total;

  int _done = 0;
  int get done => _done;

  /// 上报累计完成字节，返回**修正后**的单调值
  int report(int value) {
    if (value > _done) _done = value;
    return _done;
  }

  double get fraction => total > 0 ? (_done / total).clamp(0.0, 1.0) : 0.0;

  void reset() => _done = 0;
}
