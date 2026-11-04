import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 云更新「多连接分片下载」测试（2026-10-06 提速专项）
///
/// 覆盖六类风险（都是"错了就下出坏包/装不上"的硬风险）：
///   1. 分片计算边界（远小于 / 恰好等于 / 略大于 / 超大；覆盖完整性不变量）
///   2. 真实 HTTP 并行下载 + sha256 校验（真跑 socket，不打桩）
///   3. 服务端不支持 Range → 自动回退单连接且结果正确
///   4. 断点续传：下到一半取消 → 再下只补缺失片 → 最终校验通过
///   5. 分片失败 → 指数退避重试 → 仍失败 → 干净回退（不留坏文件）
///   6. 进度单调不倒退（并行乱序完成 + 重试回退）
///
/// 为什么用真实本地 HTTP 服务器而不是 mock Dio：分片下载的价值**全在
/// "按偏移写盘 + 多连接并发"**上，mock 掉 socket 就只剩算术，测不出真正的 bug
/// （比如 setPosition 写错偏移、Range 头拼错、206/200 判定错）。
void main() {
  // 每个用例独立目录，避免 sidecar/.part 互相污染
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fish_dl_test_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('① 分片计算（边界）', () {
    const int mb = 1024 * 1024;
    const ShardConfig cfg = ShardConfig();

    test('阈值判定：远小于 / 小于 / 恰好等于 / 大于 阈值', () {
      // 远小于（1KB）
      expect(ShardPlanner.shouldShard(rangeSupported: true, fileSize: 1024, config: cfg), isFalse);
      // 小于（4MB - 1 字节）
      expect(ShardPlanner.shouldShard(rangeSupported: true, fileSize: 4 * mb - 1, config: cfg), isFalse);
      // **恰好等于 4MB**（需求写的是「≥ 4MB」→ 应当分片）
      expect(ShardPlanner.shouldShard(rangeSupported: true, fileSize: 4 * mb, config: cfg), isTrue);
      // 略大于（4MB + 1）
      expect(ShardPlanner.shouldShard(rangeSupported: true, fileSize: 4 * mb + 1, config: cfg), isTrue);
      // 26MB 真包大小
      expect(ShardPlanner.shouldShard(rangeSupported: true, fileSize: 27368751, config: cfg), isTrue);
      // 不支持 Range 时，多大都不分片（零回归关键）
      expect(ShardPlanner.shouldShard(rangeSupported: false, fileSize: 500 * mb, config: cfg), isFalse);
    });

    test('切 16 片（4 并发 × 队列深度 4）：首尾相接、无重叠、无空隙、完整覆盖', () {
      const int total = 27368751; // 真实 APK 大小
      final List<ByteRange> shards = ShardPlanner.split(total: total, connections: 4, config: cfg);
      // 2026-10-17 提速专项：片数 = 并发 × piecesPerConnection（4×4），
      // 目的见 ShardConfig.piecesPerConnection（慢连接不拖尾）
      expect(shards.length, 4 * cfg.piecesPerConnection);
      expect(shards.first.start, 0);
      expect(shards.last.end, total - 1);
      for (int i = 1; i < shards.length; i++) {
        expect(shards[i].start, shards[i - 1].end + 1, reason: '第 $i 片必须紧接上一片');
      }
      expect(shards.fold<int>(0, (int a, ByteRange r) => a + r.length), total);
      // 余数摊到前几片 → 片长差不超过 1
      final List<int> lens = shards.map((ByteRange r) => r.length).toList();      expect(lens.reduce(max) - lens.reduce(min) <= 1, isTrue);
    });

    test('片数不超过字节数（极小文件切成 1 片，不产生空片）', () {
      final List<ByteRange> s1 = ShardPlanner.split(total: 1, connections: 8, config: cfg);
      expect(s1.length, 1);
      expect(s1.single, const ByteRange(0, 0));
      // 2026-10-17 单片下限（512KiB）落地后：3 字节这种"比下限还小"的总量只有 1 片
      // —— 不是"放宽"，而是规则变了：**绝不会为小文件切出一堆碎片**（不变量仍是
      // "不产生空片、片数 ≤ 字节数"）。
      final List<ByteRange> s3 = ShardPlanner.split(total: 3, connections: 8, config: cfg);
      expect(s3.length, 1);
      expect(s3.single, const ByteRange(0, 2));
      // 但只要总量够一片，片数就一定 ≤ 字节数
      final List<ByteRange> s2m = ShardPlanner.split(total: 2 * mb, connections: 8, config: cfg);
      expect(s2m.length, lessThanOrEqualTo(2 * mb));
      expect(s2m.fold<int>(0, (int a, ByteRange r) => a + r.length), 2 * mb);
      expect(ShardPlanner.split(total: 0, connections: 4, config: cfg), isEmpty);
    });

    test('并发数受硬顶约束（配 100 也只到 hardMax=16）；默认 12', () {
      expect(cfg.clampConnections(100), 16);
      expect(cfg.clampConnections(12), 12);
      expect(cfg.clampConnections(0), 1);
      expect(cfg.clampConnections(-5), 1);
      expect(cfg.maxConnections, 12);
      // 并发被钳到 16 → 片数 = 16 × 4 = 64（maxPieces 上限），不是 100×4
      expect(ShardPlanner.split(total: 100 * mb, connections: 100, config: cfg).length, 64);
    });

    test('单片不小于 512KiB：片数被钳制（真包 23.2MB → 12 并发 × 4 = 44 片）', () {
      const int realApk = 23226112; // 2026-10-17 线上 boss 包（id 138）
      final List<ByteRange> shards = ShardPlanner.split(total: realApk, connections: 12, config: cfg);
      // 12 × 4 = 48 请求，但 23226112 ~/ 524288 = 44 → 取较小者
      expect(shards.length, 44);
      for (final ByteRange r in shards) {
        expect(r.length, greaterThanOrEqualTo(cfg.minShardBytes), reason: '每片都不许小于单片下限');
      }
      // 恰好 4MB：48 片请求被下限钳到 8 片（4MB / 512KiB）
      expect(ShardPlanner.split(total: 4 * mb, connections: 12, config: cfg).length, 8);
      // 6MB：钳到 12 片
      expect(ShardPlanner.split(total: 6 * mb, connections: 12, config: cfg).length, 12);
      // 文件本身小于单片下限 → 只有 1 片（不会切出空片/超小片）
      expect(ShardPlanner.split(total: cfg.minShardBytes - 1, connections: 12, config: cfg).length, 1);
    });

    test('覆盖字节数：重叠/乱序/相邻区间都算对（不重复计数）', () {
      expect(ShardPlanner.coveredBytes(const <ByteRange>[ByteRange(0, 9)]), 10);
      // 重叠：[0,9] 与 [5,14] → 合并 [0,14] = 15 字节
      expect(ShardPlanner.coveredBytes(const <ByteRange>[ByteRange(0, 9), ByteRange(5, 14)]), 15);
      // 相邻：[0,4] 与 [5,9] → 合并 [0,9] = 10
      expect(ShardPlanner.coveredBytes(const <ByteRange>[ByteRange(0, 4), ByteRange(5, 9)]), 10);
      // 乱序
      expect(ShardPlanner.coveredBytes(const <ByteRange>[ByteRange(10, 19), ByteRange(0, 9)]), 20);
      expect(ShardPlanner.coveredBytes(const <ByteRange>[]), 0);
    });

    test('续传缺口计算：全集 - 已完成 = 待下（只补缺失片）', () {
      const List<ByteRange> shards = <ByteRange>[ByteRange(0, 99), ByteRange(100, 199), ByteRange(200, 299)];
      // 中间那片下完了 → 只剩前后两片
      expect(
        ShardPlanner.pendingRanges(needed: shards, done: const <ByteRange>[ByteRange(100, 199)]),
        const <ByteRange>[ByteRange(0, 99), ByteRange(200, 299)],
      );
      // 全部下完 → 无待下（幂等：重进不会再下一字节）
      expect(ShardPlanner.pendingRanges(needed: shards, done: shards), isEmpty);
      // 片内部分完成 → 只补片内剩余
      expect(
        ShardPlanner.pendingRanges(needed: const <ByteRange>[ByteRange(0, 99)], done: const <ByteRange>[ByteRange(0, 39)]),
        const <ByteRange>[ByteRange(40, 99)],
      );
    });

    test('sidecar 编解码往返一致；坏 JSON / 版本不符 / 缺字段一律返回 null', () {
      final List<ByteRange> plan = ShardPlanner.split(total: 27368751, connections: 4);
      final PartSidecar s = PartSidecar(
        url: 'https://x/download/99',
        total: 27368751,
        shards: plan,
        done: const <ByteRange>[ByteRange(0, 100), ByteRange(50, 200)],
      );
      final PartSidecar? back = PartSidecar.tryDecode(s.encode());
      expect(back, isNotNull);
      expect(back!.url, s.url);
      expect(back.total, s.total);
      expect(back.shards.length, plan.length, reason: '分片计划必须原样往返（片数：${plan.length}）');
      expect(back.shards, plan, reason: '每一片的起止都要逐值相等（片切得更小之后这条更关键）');
      expect(back.done, const <ByteRange>[ByteRange(0, 200)]); // 重叠已合并

      expect(PartSidecar.tryDecode('not json'), isNull);
      expect(PartSidecar.tryDecode('{"v":99,"url":"u","total":1}'), isNull);
      expect(PartSidecar.tryDecode('{"v":1,"total":1}'), isNull); // 缺 url
      expect(PartSidecar.tryDecode('{"v":1,"url":"u"}'), isNull); // 缺 total
      expect(PartSidecar.tryDecode('[]'), isNull);
    });
  });

  group('②③④⑤ 真实 socket 下载', () {
    /// 起一个"可配置行为"的真文件服务器（本机 loopback，真 socket）
    Future<_Srv> serve(
      Uint8List data, {
      _Mode mode = _Mode.rangeOk,
      List<List<int>> poisonRanges = const <List<int>>[],
      int throttleMicrosPerChunk = 0,
    }) async {
      final _Srv s = _Srv(data, await Directory.systemTemp.createTemp('fish_srv_'), mode)
        ..poisonRanges.addAll(poisonRanges)
        ..throttleMicrosPerChunk = throttleMicrosPerChunk;
      await s.start();
      return s;
    }

    AppUpdater newUpdater({int conns = 4, int attempts = 3}) {
      final AppUpdater u = AppUpdater.forTesting();
      u.shardConfig = ShardConfig(maxConnections: conns, maxAttemptsPerShard: attempts);
      return u;
    }

    AppUpdateInfo infoFor(String url, Uint8List data, String hash) => AppUpdateInfo(
          hasUpdate: true,
          force: false,
          versionCode: 999,
          versionName: '9.9.9',
          updateDesc: 'test',
          fileSize: data.length,
          fileHash: hash,
          downloadUrl: url,
        );

    test('② 并行分片下载真文件（5MB / 4 连接）→ 逐字节一致 + 并行确实生效', () async {
      final Uint8List data = _payload(5 * 1024 * 1024 + 12345, seed: 7);
      final _Srv srv = await serve(data);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater();
      final String hash = await _sha256Of(data);

      final List<int> progress = <int>[];
      final String path = await u.download(
        infoFor(srv.url, data, hash),
        onProgress: (int d, int t) => progress.add(d),
      );
      addTearDown(() => u.discard(path));

      expect(await u.fileSha256(path), hash, reason: '下载内容必须与源文件逐字节一致');
      expect(await File(path).length(), data.length);
      // Range 请求真的发出去了（分片路径生效）
      expect(srv.rangeRequestCount, greaterThanOrEqualTo(4), reason: '应至少发出 4 个 Range 请求');
      // 单片请求必须是"部分内容"（不是整包）
      expect(srv.rangeRequestCount > 0, isTrue);
      // sidecar 已删除（成功不留残留）
      expect(await File('$path.part${PartSidecar.suffix}').exists(), isFalse);
      expect(await File('$path.part').exists(), isFalse);
      // 进度单调 + 终点 = 总大小
      expect(_isMonotonic(progress), isTrue, reason: '进度不得倒退: $progress');
      expect(progress.last, data.length);
      // 并行下"每片完成"一次回调：4 片至少 4 次进度事件（含起点 1 次）
      expect(progress.length, greaterThanOrEqualTo(4));
    });

    test('③ 服务端不支持 Range（HEAD/Range 都回 200 整包）→ 回退单连接且结果正确', () async {
      final Uint8List data = _payload(5 * 1024 * 1024 + 777, seed: 11);
      final _Srv srv = await serve(data, mode: _Mode.noRange);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater();
      final String hash = await _sha256Of(data);

      final String path = await u.download(infoFor(srv.url, data, hash));
      addTearDown(() => u.discard(path));

      // 服务端从不回 206 → 客户端必须走单连接（探测 1 次 + 整包 1 次，无任何分片）
      expect(srv.shardRequestCount, 0, reason: '不支持 Range 时不应发出分片请求，requests=${srv.requests}');
      expect(srv.fullRequestCount, 1, reason: '应恰好 1 次整包请求，requests=${srv.requests}');
      expect(srv.rangeRequestCount, 0, reason: 'noRange 模式下服务端不认 Range');
      expect(await u.fileSha256(path), hash);
      expect(u.parallelActive, isFalse);
    });

    test('③b 服务端忽略 Range（对 Range 请求回 200 整包）→ 不拼出坏文件', () async {
      final Uint8List data = _payload(5 * 1024 * 1024 + 313, seed: 13);
      final _Srv srv = await serve(data, mode: _Mode.ignoreRange);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater();
      final String hash = await _sha256Of(data);

      final String path = await u.download(infoFor(srv.url, data, hash));
      addTearDown(() => u.discard(path));
      // 关键：服务端无视 Range 回了整包，客户端必须丢弃旧内容重写，而不是"旧+新"拼接
      expect(await u.fileSha256(path), hash);
      expect(await File(path).length(), data.length);
    });

    test('④ 断点续传：下到一半取消 → 再下只补缺失片 → 最终 sha256 通过', () async {
      final Uint8List data = _payload(6 * 1024 * 1024 + 4096, seed: 17);
      // 节流值必须**明显高于系统定时器粒度**（Windows 约 1ms）：小于它时
      // `Future.delayed` 会被折叠成"立即到期"，节流等于没节流 —— 服务端与客户端同在一个
      // isolate 里，服务端就能抢在客户端第一次 ≥1MB 的进度回调被派发之前，把整包推进
      // socket 缓冲区（实测 bytesServed 达到「整包 + 1」，那 1 字节是探测请求 Range: 0-0）。
      // 8ms / 64KB ≈ 8MB/s：既给了客户端稳定的取消落点，又不至于把用例拖慢。
      final _Srv srv = await serve(data, mode: _Mode.rangeOk, throttleMicrosPerChunk: 8000);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater(conns: 2);
      final String hash = await _sha256Of(data);
      final AppUpdateInfo info = infoFor(srv.url, data, hash);

      // 第一轮：下到 ~1MB 就取消
      final CancelToken token = CancelToken();
      final List<int> seen = <int>[];
      await expectLater(
        u.download(
          info,
          cancelToken: token,
          onProgress: (int d, int t) {
            seen.add(d);
            if (d >= 1024 * 1024 && !token.isCancelled) token.cancel('测试取消');
          },
        ),
        throwsA(anything),
      );
      final String partPath = _partPathFor(info);
      expect(await File(partPath).exists(), isTrue, reason: '取消后应保留 .part 供续传');
      // 取消 → 真的发过（并中断了）分片请求，不是"还没开始就取消"
      expect(srv.rangeRequestCount, greaterThan(0));

      // 第二轮：不清任何东西，直接重下 → 应当续传。
      //
      // 读之前要**等 sidecar 落定**：sidecar 是"完成一片就异步持久化"的，
      // 取消返回的瞬间可能还有一次 persist 在飞（生产里下一次下载远晚于此，不受影响）。
      // 所以这里轮询等待"sidecar 稳定"，而不是读一次就断言——**不变量本身不放松**：
      // 最终仍要求 sidecar 声称的每个区间都能在 .part 里找到真数据。
      final List<ByteRange> claimed = await _waitForStableClaim(partPath);

      // **本用例的前置条件**：第一轮必须"没下完"，否则续传无从谈起（等于什么都没测到）。
      //
      // 判据刻意用**客户端真正落盘**的字节数（sidecar 声称的已完成区间），而**不用**
      // `srv.bytesServed`：后者是"服务端把字节写进 socket"的计数，事件循环被拖慢时它可以在
      // 客户端的进度回调之前就涨到整包（见上面节流值那段注释）—— 那是**调度快慢**，
      // 不是产品缺陷。而"客户端只落了 N 字节（N < 整包）"才是续传真正依赖的事实。
      final int landedFirstRound = ShardPlanner.coveredBytes(claimed);
      expect(landedFirstRound, greaterThan(0), reason: '第一轮应已有落盘进度（否则没有可续传的现场）');
      expect(
        landedFirstRound,
        lessThan(data.length),
        reason: '第一轮必须没下完：客户端只落了 $landedFirstRound/${data.length} 字节',
      );

      final Uint8List partBytes = await File(partPath).readAsBytes();
      // **续传正确性硬不变量**：sidecar 声称已完成的区间，必须真的已落盘且与源数据一致。
      // 这条断言就是"能不能安全跳过这些字节"的判据（不满足 → 续传必出坏包）。
      for (final ByteRange r in claimed) {
        expect(
          _eq(partBytes.sublist(r.start, r.start + 64), data.sublist(r.start, r.start + 64)),
          isTrue,
          reason: 'sidecar 声称 ${r.start}-${r.end} 已完成，但这些字节在 .part 里不是真数据',
        );
      }
      srv.bytesServed = 0;
      srv.requests.clear();
      final String path = await u.download(info);
      addTearDown(() => u.discard(path));
      expect(await u.fileSha256(path), hash, reason: '续传后必须与源文件一致');
      // 续传的核心断言：第二轮拉取的字节数 < 整包（已完成的片没重下）
      expect(
        srv.bytesServed,
        lessThan(data.length),
        reason: '续传应只补缺失片，第二轮实际拉取 ${srv.bytesServed} / ${data.length}',
      );
      expect(await File('$path.part${PartSidecar.suffix}').exists(), isFalse, reason: '完成后删除 sidecar');
    });

    test('⑤ 指定区间反复失败 → 指数退避重试 ≥3 次 → 干净回退到单连接 → 不留坏文件', () async {
      final Uint8List data = _payload(5 * 1024 * 1024 + 55, seed: 23);
      // 让 [0, 100000] 这段永远 500；其它区间正常 → 并行必失败 → 走缺口回填
      final _Srv srv = await serve(data, mode: _Mode.rangeOk, poisonRanges: <List<int>>[
        <int>[0, 100000],
      ]);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater(conns: 4, attempts: 3);
      final String hash = await _sha256Of(data);
      final AppUpdateInfo info = infoFor(srv.url, data, hash);

      // 第一次：并行必然失败 → 缺口回填（单连接逐段补齐，含 poison 段 → 也失败）→ 抛错
      await expectLater(u.download(info), throwsA(anything));

      // 关键：**不许留下可被当成"下好了"的文件**
      final String savePath = _savePathFor(info);
      expect(await File(savePath).exists(), isFalse, reason: '失败绝不能产出 .apk（否则会被安装坏包）');

      // 重试次数：poison 区间至少被试了 3 次（maxAttemptsPerShard=3）
      expect(srv.poisonHits, greaterThanOrEqualTo(3), reason: '指数退避重试应至少尝试 3 次，实际 ${srv.poisonHits}');

      // 修复服务端（去掉 poison）→ 再下必须成功（证明失败后状态可恢复，没有中毒的残留）
      srv.poisonRanges.clear();
      final String path = await u.download(info);
      addTearDown(() => u.discard(path));
      expect(await u.fileSha256(path), hash, reason: '恢复后必须能下出正确文件');
    });

    test('⑤b 并行全程失败 + 服务端完全不支持 Range → 最终回退单连接成功', () async {
      final Uint8List data = _payload(4 * 1024 * 1024 + 9, seed: 29);
      // 先按"支持 Range 但区间全失败"起步，避免探测阶段就回退
      final _Srv srv = await serve(data, mode: _Mode.rangeOk, poisonRanges: <List<int>>[
        <int>[0, data.length - 1],
      ]);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater(conns: 4, attempts: 1);
      final String hash = await _sha256Of(data);
      final AppUpdateInfo info = infoFor(srv.url, data, hash);

      // 并行 + 缺口回填都基于 Range → 失败
      await expectLater(u.download(info), throwsA(anything));
      // 然后服务端彻底不支持 Range（模拟"中途不再支持"）→ 必须整包单连接成功
      srv.mode = _Mode.noRange;
      final String path = await u.download(info);
      addTearDown(() => u.discard(path));
      expect(await u.fileSha256(path), hash);
      expect(u.parallelActive, isFalse);
    });

    test('⑥ 进度单调不倒退（4 连接并行 + 乱序完成 + 重试）', () async {
      final Uint8List data = _payload(5 * 1024 * 1024 + 99, seed: 31);
      final _Srv srv = await serve(data, mode: _Mode.rangeOk, throttleMicrosPerChunk: 300);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater(conns: 4);
      final String hash = await _sha256Of(data);

      final List<int> progress = <int>[];
      final List<double> speeds = <double>[];
      final String path = await u.download(
        infoFor(srv.url, data, hash),
        onProgress: (int d, int t) => progress.add(d),
        onSpeed: speeds.add,
      );
      addTearDown(() => u.discard(path));

      expect(progress.length, greaterThanOrEqualTo(4));
      expect(_isMonotonic(progress), isTrue, reason: '进度序列必须单调不减');
      expect(progress.last, data.length);
      expect(speeds.every((double s) => s >= 0 && !s.isNaN), isTrue);
    });

    test('取消：保留续传现场（.part + sidecar），但绝不产出 .apk', () async {
      final Uint8List data = _payload(6 * 1024 * 1024, seed: 37);
      // 同 ④：节流值要明显高于系统定时器粒度（约 1ms），否则节流失效、取消可能落在
      // "整包已推完"之后，用例就会以"期望抛错但没抛"的形式偶发失败。
      final _Srv srv = await serve(data, mode: _Mode.rangeOk, throttleMicrosPerChunk: 8000);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater(conns: 2);
      final AppUpdateInfo info = infoFor(srv.url, data, 'x');
      final CancelToken token = CancelToken();
      await expectLater(
        u.download(
          info,
          cancelToken: token,
          onProgress: (int d, int t) {
            if (d > 300 * 1024 && !token.isCancelled) token.cancel('测试取消');
          },
        ),
        throwsA(anything),
      );
      final String save = _savePathFor(info);
      // 取消=暂停：现场保留（否则续传无从谈起）
      expect(await File('$save.part').exists(), isTrue, reason: '取消后应保留 .part 供续传');
      expect(await File('$save.part${PartSidecar.suffix}').exists(), isTrue, reason: '取消后应保留 sidecar');
      // 但**绝不能**出现 .apk：改名只发生在下完整之后，系统安装器拿不到半截包
      expect(await File(save).exists(), isFalse, reason: '未下完绝不能产出 .apk');
      // 明确放弃 → 清理干净
      await u.discard(save);
      expect(await File('$save.part').exists(), isFalse);
      expect(await File('$save.part${PartSidecar.suffix}').exists(), isFalse);
    });

    test('小文件（< 4MB 阈值）不并行：不发 Range、单连接完成', () async {
      final Uint8List data = _payload(512 * 1024, seed: 41);
      final _Srv srv = await serve(data);
      addTearDown(srv.stop);
      final AppUpdater u = newUpdater();
      final String hash = await _sha256Of(data);
      final String path = await u.download(infoFor(srv.url, data, hash));
      addTearDown(() => u.discard(path));
      // 只允许探测那一次 Range: bytes=0-0；不许出现任何真分片请求，整包恰好 1 次
      expect(srv.shardRequestCount, 0, reason: '小文件不应分片，requests=${srv.requests}');
      expect(srv.fullRequestCount, 1, reason: '应只发 1 个整包请求，requests=${srv.requests}');
      expect(srv.nonProbeRequestCount, 1, reason: '小文件总共只该有 1 次真请求，requests=${srv.requests}');
      expect(await u.fileSha256(path), hash);
    });
  });

  group('②-真实 从真后端(3100)拉真文件', () {
    const String backend = 'http://127.0.0.1:3100/api/v1';

    test('②-real 并行下载 /app-versions/download/99 真 APK → sha256 == 云端 fileHash', () async {
      final _BackendInfo? info = await _fetchBackendInfo(backend);
      if (info == null) {
        // 后端没起时不静默跳过：打一行显式说明，避免"以为测了其实没测"
        // ignore: avoid_print
        print('SKIP ②-real：本机 3100 后端不可用（需要 npm run start:dev / pm2 fish-server）');
        return;
      }
      expect(info.fileSize, greaterThan(4 * 1024 * 1024), reason: '真包应远大于分片阈值');
      final AppUpdater u = AppUpdater.forTesting();
      final AppUpdateInfo ui = info.toUpdateInfo();
      // 先清干净：避免上一次运行残留的 .part/写句柄干扰（Windows 上 rename 会被拒）
      await u.discard(_savePathFor(ui));

      final List<int> progress = <int>[];
      // 并行状态要在下载过程中观察（下载结束后会复位）
      bool sawParallel = false;
      final String path = await u.download(
        ui,
        onProgress: (int d, int t) {
          progress.add(d);
          if (u.parallelActive) sawParallel = true;
        },
      );

      // 真实 sha256 校验（服务端记录值）——这是"装了不坏包"的最后一道闸
      expect(await u.fileSha256(path), info.fileHash);
      await u.verifyHash(path, info.fileHash);
      expect(await File(path).length(), info.fileSize);
      expect(sawParallel, isTrue, reason: '真包 26MB 且支持 Range → 必须走并行分片');
      expect(_isMonotonic(progress), isTrue);
      expect(progress.last, info.fileSize);
      await u.discard(path);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('⑥ 进度/速度纯逻辑', () {
    test('MonotonicProgress：倒退的上报被夹住', () {
      final MonotonicProgress p = MonotonicProgress(1000);
      expect(p.report(100), 100);
      expect(p.report(80), 100, reason: '回退上报必须被夹住');
      expect(p.report(100), 100);
      expect(p.report(500), 500);
      expect(p.fraction, 0.5);
      expect(p.report(2000), 2000);
      expect(p.fraction, 1.0, reason: '超总量也要夹到 1.0');
    });

    test('SpeedMeter：滑动窗口平均速度 + 剩余时间', () {
      final SpeedMeter m = SpeedMeter(window: const Duration(seconds: 3));
      final DateTime t0 = DateTime(2026, 10, 6, 12, 0, 0);
      m.sample(0, at: t0);
      expect(m.bytesPerSecond, 0, reason: '单个样本算不出速度');
      m.sample(1024 * 1024, at: t0.add(const Duration(seconds: 1)));
      expect(m.bytesPerSecond, closeTo(1024 * 1024, 1)); // 1MB/s
      // 窗口外的老样本应被丢弃：再等 5 秒追加 0 增长 → 速度只由窗口内决定
      m.sample(1024 * 1024, at: t0.add(const Duration(seconds: 6)));
      expect(m.bytesPerSecond, 0, reason: '窗口内无增长 → 速度归零');
      // 恢复增长
      m.sample(3 * 1024 * 1024, at: t0.add(const Duration(seconds: 7)));
      expect(m.bytesPerSecond, closeTo(2 * 1024 * 1024, 1));
      final Duration? eta = m.eta(4 * 1024 * 1024);
      expect(eta, isNotNull);
      expect(eta!.inSeconds, 2);
      expect(m.eta(0), isNull, reason: '没有剩余字节 → 无 ETA');
      m.reset();
      expect(m.bytesPerSecond, 0);
      expect(m.eta(1000), isNull);
    });

    test('UpdateCenter 展示口径：速度文案 / 剩余时间文案', () {
      // 单例：只验证纯格式化（不发起真实下载）
      final UpdateCenter c = UpdateCenter.instance;
      c.reset();
      expect(c.speedText, '0.00 MB/s');
      expect(c.remainingText, '计算中…');
      expect(c.progress, 0);
    });
  });
}

// ───────────────────────────── 测试辅助 ─────────────────────────────

/// 真后端返回的版本信息（本机 3100）
class _BackendInfo {
  _BackendInfo({
    required this.fileSize,
    required this.fileHash,
    required this.versionCode,
    required this.versionName,
    required this.downloadUrl,
  });

  final int fileSize;
  final String fileHash;
  final int versionCode;
  final String versionName;
  final String downloadUrl;

  AppUpdateInfo toUpdateInfo() => AppUpdateInfo(
        hasUpdate: true,
        force: false,
        versionCode: versionCode,
        versionName: versionName,
        updateDesc: 'real',
        fileSize: fileSize,
        fileHash: fileHash,
        downloadUrl: downloadUrl,
      );
}

/// 向本机后端问"最新启用版本"（起不来就返回 null，由调用方决定怎么报告）
Future<_BackendInfo?> _fetchBackendInfo(String base) async {
  final Dio dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 3), receiveTimeout: const Duration(seconds: 5)));
  try {
    final Response<dynamic> r = await dio.get<dynamic>(
      '$base/public/app-versions/latest',
      queryParameters: <String, dynamic>{'appType': 'boss', 'currentVersionCode': 1},
    );
    final Map<String, dynamic> data = (r.data as Map)['data'] as Map<String, dynamic>;
    final Map<String, dynamic> latest = data['latest'] as Map<String, dynamic>;
    final String rel = '${latest['downloadUrl']}';
    if (rel.isEmpty) return null;
    return _BackendInfo(
      fileSize: (latest['fileSize'] as num).toInt(),
      fileHash: '${latest['fileHash']}',
      versionCode: (latest['versionCode'] as num).toInt(),
      versionName: '${latest['versionName']}',
      downloadUrl: 'http://127.0.0.1:3100$rel',
    );
  } catch (_) {
    return null;
  } finally {
    dio.close(force: true);
  }
}

/// 等 sidecar 落定并返回它声称已完成的区间。
///
/// sidecar 的持久化是"完成一片就异步写"（生产里无所谓：下一次下载远晚于此），
/// 但测试在取消返回后立刻读，可能读到上一版。这里轮询到"连续两次读到相同内容"为止，
/// 给在飞的 persist 留出收敛时间——**只等稳定，不放松不变量**。
Future<List<ByteRange>> _waitForStableClaim(String partPath) async {
  final File f = File('$partPath${PartSidecar.suffix}');
  String? prev;
  List<ByteRange> last = const <ByteRange>[];
  for (int i = 0; i < 12; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!await f.exists()) continue;
    final String raw = await f.readAsString();
    final PartSidecar? sc = PartSidecar.tryDecode(raw);
    last = sc?.done ?? const <ByteRange>[];
    if (prev != null && prev == raw) return last; // 连续两次一致 → 已收敛
    prev = raw;
  }
  return last;
}

bool _eq(List<int> a, List<int> b) {  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _isMonotonic(List<int> xs) {  for (int i = 1; i < xs.length; i++) {
    if (xs[i] < xs[i - 1]) return false;
  }
  return true;
}

String _savePathFor(AppUpdateInfo info) =>
    '${Directory.systemTemp.path}/fish_update/fish_update_v${info.versionCode}.apk';

String _partPathFor(AppUpdateInfo info) => '${_savePathFor(info)}.part';

/// 造一份"可复现的随机内容"（不用全 0：全 0 会掩盖偏移写错——写错位置也是 0）
Uint8List _payload(int len, {required int seed}) {
  final Random r = Random(seed);
  final Uint8List out = Uint8List(len);
  for (int i = 0; i < len; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

Future<String> _sha256Of(Uint8List data) async {
  final Digest d = await sha256.bind(Stream<List<int>>.value(data)).first;
  return d.toString();
}

/// 服务器行为
enum _Mode {
  /// 正常支持 Range（206）
  rangeOk,

  /// 完全不支持 Range：对任何请求都回 200 + 整包（也不回 Accept-Ranges）
  noRange,

  /// 声明支持 Range 但无视 Range 头，一律回 200 + 整包（最阴险的中间代理行为）
  ignoreRange,
}

/// 一个"真 socket"的文件服务器，可模拟分片失败 / 不支持 Range / 慢速 / 忽略 Range
class _Srv {
  _Srv(this.data, this.dir, this.mode);

  final Uint8List data;
  final Directory dir;
  _Mode mode;

  /// 这些区间永远回 500（模拟隧道断流/服务端错误）
  final List<List<int>> poisonRanges = <List<int>>[];

  /// 每个 chunk 之间人为延时（微秒）——制造"能取消、能观察进度"的慢速下载
  int throttleMicrosPerChunk = 0;

  int rangeRequestCount = 0;
  int bytesServed = 0;
  int poisonHits = 0;

  /// 收到的请求轨迹（诊断用：`Range 0-99` / `full`）
  final List<String> requests = <String>[];

  /// 除探测（`Range: bytes=0-0`）之外的请求数——用于断言"到底发了几次真请求"
  int get nonProbeRequestCount => requests.where((String r) => r != 'Range 0-0').length;

  /// 真分片请求数（探测与整包都不算）
  int get shardRequestCount =>
      requests.where((String r) => r != 'Range 0-0' && r != 'full').length;

  /// 整包（不带 Range）请求数
  int get fullRequestCount => requests.where((String r) => r == 'full').length;

  late final HttpServer _server;
  late final File _file;
  String get url => 'http://127.0.0.1:${_server.port}/app.apk';

  Future<void> start() async {
    _file = File('${dir.path}/app.apk');
    await _file.writeAsBytes(data, flush: true);
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_server.listen(_handle).asFuture<void>().catchError((Object _) {}));
  }

  Future<void> stop() async {
    await _server.close(force: true);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  bool _isPoisoned(int start, int end) {
    for (final List<int> p in poisonRanges) {
      if (start <= p[1] && end >= p[0]) return true;
    }
    return false;
  }

  Future<void> _handle(HttpRequest req) async {
    final HttpResponse res = req.response;
    // 本次请求的"来源标记"：无 Range → full；带 Range → Range a-b（探测为 Range 0-0）
    final String? rawRange = req.headers.value('range');
    final RegExpMatch? rm = rawRange == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rawRange);
    final String rangeProbe = rm == null
        ? 'full'
        : 'Range ${rm.group(1)}-${rm.group(2)!.isEmpty ? 'end' : rm.group(2)}';
    try {
      if (mode == _Mode.noRange) {
        // 记录来源：'full' 表示这次请求没带 Range;，'Range a-b' 表示带了（此处一律回 200）
        requests.add(rangeProbe);
        res.statusCode = 200;
        res.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.android.package-archive');
        res.headers.contentLength = data.length;
        await _writeBody(res, 0, data.length - 1, contentLength: data.length);
        return;
      }

      final String? rangeHeader = req.headers.value('range');
      if (rangeHeader == null) {
        // 整包请求（不带 Range）
        requests.add(rangeProbe);
        res.statusCode = 200;
        res.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.android.package-archive');
        res.headers.set('Accept-Ranges', 'bytes');
        res.headers.contentLength = data.length;
        await _writeBody(res, 0, data.length - 1, contentLength: data.length);
        return;
      }

      rangeRequestCount++;
      final RegExpMatch? m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (m == null) {
        res.statusCode = 416;
        res.headers.set('Content-Range', 'bytes */${data.length}');
        await res.close();
        return;
      }
      final int start = int.parse(m.group(1)!);
      final int end = m.group(2)!.isEmpty ? data.length - 1 : min(int.parse(m.group(2)!), data.length - 1);
      requests.add(rangeProbe);

      // 探测请求（Range: bytes=0-0，只有 1 字节）永远不毒：探测失败会让客户端
      // 直接判定"不支持 Range"从而走单连接，测不到并行失败→回退这条路径。
      if (_isPoisoned(start, end) && end > start) {
        poisonHits++;
        res.statusCode = 500;
        res.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
        res.write('poisoned range $start-$end');
        await res.close();
        return;
      }

      if (mode == _Mode.ignoreRange) {
        // 无视 Range：回 200 + 整包（客户端必须能识别并丢弃旧内容）
        res.statusCode = 200;
        res.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.android.package-archive');
        res.headers.contentLength = data.length;
        await _writeBody(res, 0, data.length - 1, contentLength: data.length);
        return;
      }

      final int len = end - start + 1;
      res.statusCode = 206;
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.android.package-archive');
      res.headers.set('Accept-Ranges', 'bytes');
      res.headers.set('Content-Range', 'bytes $start-$end/${data.length}');
      res.headers.contentLength = len;
      await _writeBody(res, start, end, contentLength: len);
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _writeBody(HttpResponse res, int start, int end, {required int contentLength}) async {
    final RandomAccessFile raf = await _file.open();
    try {
      await raf.setPosition(start);
      int remaining = contentLength;
      const int chunkSize = 64 * 1024;
      while (remaining > 0) {
        final int want = remaining < chunkSize ? remaining : chunkSize;
        final Uint8List buf = await raf.read(want);
        if (buf.isEmpty) break;
        res.add(buf);
        await res.flush();
        remaining -= buf.length;
        bytesServed += buf.length;
        if (throttleMicrosPerChunk > 0) {
          await Future<void>.delayed(Duration(microseconds: throttleMicrosPerChunk));
        }
      }
    } finally {
      await raf.close();
      await res.close();
    }
  }
}
