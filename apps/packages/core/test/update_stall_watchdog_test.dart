import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 云更新「下载停滞看门狗」测试（2026-10-17，修复线上故障）
///
/// ## 故障现场（负责人真机截图）
/// `更新弹窗：正在下载安装包…｜75% · 16.6 MB / 22.1 MB｜0.00 MB/s · 计算中…`
/// 网络本身正常，但**永不结束也永不失败**，弹窗一直挂着。
///
/// ## 真根因（本文件 ② 组用可复现实验钉死）
/// 分片是"每片独立成流"，而 dio 的 `receiveTimeout` **只覆盖"响应头到达"那一段**
/// （io_adapter 里它包在 `request.close()` 上，不是 body 流）——body 一旦开始，
/// 客户端就再没有任何超时。服务端/跨境链路只要静默停住（TCP 半开、代理悄悄丢包），
/// 分片就无限期挂着：不报错、不重试、进度不涨。
/// 更阴的是"零星到达"：每隔几十秒挤进来几个字节，任何"空闲即超时"的实现都会被
/// 无限续命 —— 所以判活必须建立在**总进度**上。
///
/// ## 本文件证明的四件事（对应任务 A/B 两条硬要求）
///   ① 停滞 N 秒 → 判死（`stallDetections`）
///   ② 判死后**退避重试**（实测"停止时刻 → 续传请求时刻"≥ 判死窗口 + 退避）
///   ③ 重试**续传补齐**（重试请求的起点落在分片中间，不是从片头重下），补齐后 sha256 一致
///   ④ 超过上限 → **有界时间内明确失败**（精确文案 + 保留 .part/sidecar 供再次续传）
///
/// 用真 socket + 真文件（`_StallServer` 会"发一半就静默停住"）：停滞这件事的本质
/// 就是"连接还在、字节不来"，mock 掉 socket 就什么都测不出来了。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fish_stall_test_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // ───────────────────────── ① 看门狗纯逻辑 ─────────────────────────

  group('① 看门狗纯逻辑（可注入时钟，零等待）', () {
    test('窗口内不增长 → 判死；差一点点不判死', () {
      DateTime now = DateTime(2026, 10, 17, 0, 11, 0);
      final ProgressWatchdog w = ProgressWatchdog(
        timeout: const Duration(seconds: 20),
        minGrowthBytes: 64 * 1024,
        clock: () => now,
      );
      expect(w.check(), isFalse);
      now = now.add(const Duration(seconds: 19, milliseconds: 900));
      expect(w.check(), isFalse, reason: '没到窗口就该活着');
      now = now.add(const Duration(milliseconds: 200));
      expect(w.check(), isTrue, reason: '连续 20 秒零增长必须判死（线上 75% 卡死就是这个形态）');
    });

    test('"慢而稳"绝不误杀：窗口内累计增量 ≥ 阈值 → 一直不判死', () {
      DateTime now = DateTime(2026, 10, 17, 0, 11, 0);
      final ProgressWatchdog w = ProgressWatchdog(
        timeout: const Duration(seconds: 20),
        minGrowthBytes: 64 * 1024,
        clock: () => now,
      );
      // 1KB / 100ms = 10KB/s：20 秒涨 200KB > 64KiB → 每一拍都必须活着
      for (int i = 0; i < 200; i++) {
        now = now.add(const Duration(milliseconds: 100));
        w.addBytes(1024);
        expect(w.check(), isFalse, reason: '第 ${i + 1} 拍：慢但在动，不许判死');
      }
      expect(w.bytes, 200 * 1024);
    });

    test('"零星到达"（1 字节/5 秒）→ 20 秒内也判死（空闲超时救不了这种）', () {
      DateTime now = DateTime(2026, 10, 17, 0, 11, 0);
      final ProgressWatchdog w = ProgressWatchdog(
        timeout: const Duration(seconds: 20),
        minGrowthBytes: 64 * 1024,
        clock: () => now,
      );
      bool stalled = false;
      for (int i = 0; i < 8; i++) {
        now = now.add(const Duration(seconds: 5));
        w.addBytes(1); // 每 5 秒来 1 个字节：任何"读空闲 60s 超时"都不会触发
        if (w.check()) {
          stalled = true;
          break;
        }
      }
      expect(stalled, isTrue, reason: '总进度几乎为零就必须判死（这正是 0.00 MB/s 的形态）');
      expect(w.bytes, lessThan(64 * 1024));
    });

    test('没有请求在飞（退避等待）时暂停计时：等待不算停滞', () {
      DateTime now = DateTime(2026, 10, 17, 0, 11, 0);
      final ProgressWatchdog w = ProgressWatchdog(
        timeout: const Duration(seconds: 20),
        minGrowthBytes: 64 * 1024,
        clock: () => now,
      );
      w.pause();
      now = now.add(const Duration(seconds: 120));
      expect(w.check(), isFalse, reason: '没有任何人在下载，谈不上卡死');
      w.resume();
      now = now.add(const Duration(seconds: 19));
      expect(w.check(), isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(w.check(), isTrue, reason: '恢复下载后又静默 20 秒 → 判死');
    });

    test('停滞参数：判死窗口 20s / 最小增量 16KiB / 重试 3 次 · 退避 1s·3s·8s', () {
      const StallConfig c = StallConfig();
      expect(c.stallTimeout, const Duration(seconds: 20));
      expect(c.minGrowthBytes, 16 * 1024);
      expect(c.maxStallRetries, 3);
      expect(c.backoffFor(1), const Duration(seconds: 1));
      expect(c.backoffFor(2), const Duration(seconds: 3));
      expect(c.backoffFor(3), const Duration(seconds: 8));
      expect(c.backoffFor(4), const Duration(seconds: 8), reason: '超出退避表取最后一档（不无限增长）');
      expect(c.backoffFor(0), const Duration(seconds: 1));
      // 判死线的含义：等价于持续速率 < 0.8 KB/s —— 真机实测同分片同连接 5 秒窗口最慢 5.5 KB/s
      expect(c.minGrowthBytes / c.stallTimeout.inSeconds, lessThan(1024));
    });

    test('真机链路实测最慢窗口（5.5 KB/s）在默认门槛下绝不误杀', () {
      // 2026-10-17 实测：本机→香港同一条 Range 连接，t=5/10/15/20s 的 5 秒窗口速度
      // 只有 5.5 / 8.6 / 10.4 KB/s（累计 106K/133K/176K/228K 字节）。
      // 取最慢那一档灌进看门狗：20 秒 = 110KB > 16KiB → 必须一直活着。
      DateTime now = DateTime(2026, 10, 17, 0, 11, 0);
      final ProgressWatchdog w = ProgressWatchdog(clock: () => now);
      for (int i = 0; i < 40; i++) {
        now = now.add(const Duration(milliseconds: 500));
        w.addBytes(2750); // 2750B / 500ms = 5.5 KB/s
        expect(w.check(), isFalse, reason: '第 ${i + 1} 拍：真机最慢实测速度，不许判死');
      }
      expect(w.bytes, 110 * 1000);
    });
  });

  // ─────────────────── ② 根因复现（空闲超时的两个盲区）───────────────────

  group('② 根因复现：单连接空闲超时救不了"零星到达"', () {
    test('②a 完全静默：dio 的 receiveTimeout 会在窗口后报错（所以"全断流"本身有兜底）', () async {
      final Uint8List data = _payload(3 * 1024 * 1024, seed: 91);
      final _StallServer srv = _StallServer(data, await Directory.systemTemp.createTemp('fish_hold_a_'));
      srv.stallRequests = 100;
      srv.stallAfterBytes = 64 * 1024;
      await srv.start();
      addTearDown(srv.stop);

      final Dio dio = Dio(BaseOptions(
        connectTimeout: const Duration(milliseconds: 500),
        receiveTimeout: const Duration(milliseconds: 300),
      ));
      addTearDown(() => dio.close(force: true));

      final Response<ResponseBody> resp = await dio.get<ResponseBody>(
        srv.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: const <String, dynamic>{'Range': 'bytes=0-1048575', 'Accept-Encoding': 'identity'},
          validateStatus: (int? s) => s != null && s < 500,
        ),
      );
      expect(resp.statusCode, 206);

      int received = 0;
      Object? error;
      final StreamSubscription<List<int>> sub = resp.data!.stream.listen(
        (List<int> c) => received += c.length,
        onError: (Object e) => error = e,
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(received, greaterThan(0), reason: '前 64KB 应该已经收到');
      expect(error, isA<DioException>(), reason: '一个字节都不来 → 空闲计时器到点报错（这条线是通的）');
      expect((error! as DioException).type, DioExceptionType.receiveTimeout);
      await sub.cancel();
    });

    test('②b 零星到达：每个字节都重置空闲计时器 → 永不报错、流也不结束（= 线上 0.00 MB/s 形态）', () async {
      final Uint8List data = _payload(512 * 1024, seed: 92);
      final _StallServer srv = _StallServer(data, await Directory.systemTemp.createTemp('fish_hold_b_'));
      srv.trickleMicrosPerByte = 250000; // 1 字节 / 250ms（远密于下面的空闲窗口）
      await srv.start();
      addTearDown(srv.stop);

      final Dio dio = Dio(BaseOptions(
        connectTimeout: const Duration(milliseconds: 500),
        // 2 秒窗口：实测"零星到达"的到达间隔可能因 OS/流缓冲被合并到几百毫秒，
        // 但仍远密于 2 秒 —— 这就是生产上 60 秒窗口被无限续命的同一个机制。
        receiveTimeout: const Duration(seconds: 2),
      ));
      addTearDown(() => dio.close(force: true));

      final Response<ResponseBody> resp = await dio.get<ResponseBody>(
        srv.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: const <String, dynamic>{'Accept-Encoding': 'identity'},
          validateStatus: (int? s) => s != null && s < 500,
        ),
      );
      expect(resp.statusCode, 200);

      int received = 0;
      Object? error;
      bool finished = false;
      final StreamSubscription<List<int>> sub = resp.data!.stream.listen(
        (List<int> c) => received += c.length,
        onError: (Object e) => error = e,
        onDone: () => finished = true,
      );
      // 等 4 秒（= 2 倍空闲超时窗口）：按 250ms/字节，理论上只该收到个位数字节
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(received, greaterThanOrEqualTo(3), reason: '确实在"零星到达"（实测 $received 字节）');
      expect(received, lessThan(64 * 1024), reason: '几十秒也到不了分片阈值 —— 总进度等于没动（实测 $received）');
      expect(error, isNull, reason: '每个字节都重置了计时器 → 空闲超时永远打不响');
      expect(finished, isFalse, reason: '流既不报错也不结束 → 没有"总进度"看门狗就会永远等下去（75% 卡死）');
      await sub.cancel();
    });
  });

  // ─────────────── ③ 停滞 → 判死 → 退避重试 → 续传补齐 ───────────────

  group('③ 真 socket：停滞判死 → 退避重试 → 续传补齐', () {
    test('分片中途静默停住 → 看门狗判死 → 退避后从片中间续传 → 最终 sha256 一致', () async {
      const int conns = 4;
      final Uint8List data = _payload(9 * 1024 * 1024 + 12345, seed: 7);
      final _StallServer srv = _StallServer(data, await Directory.systemTemp.createTemp('fish_stall_'));
      // 第 1 轮的 4 个分片请求**全部**"发 1.5MB 后静默停住"（= 聚合进度完全冻结，
      // 这才是线上"卡在 75%"的形态：不是某一条连接掉队，而是整条链路不再给数据）；
      // 之后的请求（第 2 轮的续传）恢复正常。
      srv.stallRequests = conns;
      srv.stallAfterBytes = 1536 * 1024;
      await srv.start();
      addTearDown(srv.stop);

      const int watchdogMs = 400;
      const int backoffMs = 300;
      final AppUpdater u = _newUpdater(
        conns: conns,
        watchdogMs: watchdogMs,
        backoffMs: backoffMs,
        // 这条用例专门验"片内续传"：必须让片足够大（>1.5MB 停住点 + 1MB 上报粒度），
        // 所以队列深度设为 1（片数 = 并发数）。片数/队列深度专项见 ⑥ 组。
        piecesPerConnection: 1,
      );
      final AppUpdateInfo info = _infoFor(srv.url, data, await _sha256Of(data), versionCode: 9001);
      addTearDown(() => u.discard(_savePathFor(info)));

      final Stopwatch sw = Stopwatch()..start();
      final String path = await u.download(info);
      sw.stop();

      // 内容正确：停滞 + 续传这一整条路必须"拼得对"（错一字节就是装机坏包）
      expect(await u.fileSha256(path), info.fileHash, reason: '续传补齐后必须与源文件逐字节一致');
      expect(await File(path).length(), data.length);
      expect(await File('$path.part').exists(), isFalse, reason: '完成后不留 .part');
      expect(await File('$path.part${PartSidecar.suffix}').exists(), isFalse, reason: '完成后不留 sidecar');

      // ① 判死确实发生了（否则这些请求会一直挂着）
      expect(u.stallDetections, greaterThanOrEqualTo(1), reason: '看门狗必须判死过（stallDetections=${u.stallDetections}）');
      expect(srv.stalledRequests, greaterThanOrEqualTo(1), reason: '服务端确实制造过"发一半停住"');

      // ② 退避重试：重试请求早于"判死窗口 + 退避"到达在物理上不可能
      expect(srv.firstHoldAt, isNotNull, reason: '服务端记录到了停住时刻');
      // 用**本次下载真实生效的那份配置**算片边界（不能拿默认配置算：片数不同，
      // 否则"起点不是片头"这个断言会在错误的集合上成立）
      final List<ByteRange> shards =
          ShardPlanner.split(total: data.length, connections: conns, config: u.shardConfig);
      final Set<int> shardStarts = shards.map((ByteRange r) => r.start).toSet();
      DateTime? resumeAt;
      int? resumeStart;
      for (int i = 0; i < srv.requestStarts.length; i++) {
        final int s = srv.requestStarts[i];
        if (s != 0 && !shardStarts.contains(s)) {
          resumeStart = s;
          resumeAt = srv.requestTimes[i];
          break;
        }
      }
      // ③ 续传：重试的起点落在分片**中间**（已落盘前缀之后），不是从片头重下
      expect(resumeStart, isNotNull, reason: '重试必须从片中间续传，实测所有起点=${srv.requestStarts}');
      final int gapMs = resumeAt!.difference(srv.firstHoldAt!).inMilliseconds;
      expect(gapMs, greaterThanOrEqualTo(watchdogMs + backoffMs - 120),
          reason: '重试必须在"判死窗口 ${watchdogMs}ms + 退避 ${backoffMs}ms"之后（实测 ${gapMs}ms）');
      // 只补缺口：总拉取量必须小于"整包 × 2"（没有把下过的东西整包重拉）
      expect(srv.bytesServed, lessThan(data.length * 2));
      // 有界：不该出现任何"慢慢熬"的迹象
      expect(sw.elapsed, lessThan(const Duration(seconds: 20)), reason: '实测 ${sw.elapsed.inMilliseconds}ms');
    });
  });

  // ─────────────── ④ 一直停滞 → 有界时间内明确失败 ───────────────

  group('④ 真 socket：停滞到上限 → 明确失败（不是永远等）', () {
    test('服务端永远"发一半停住" → 抛明确文案 + 保留 .part/sidecar 供续传，且绝不产出 .apk', () async {
      final Uint8List data = _payload(5 * 1024 * 1024 + 777, seed: 23);
      final _StallServer srv = _StallServer(data, await Directory.systemTemp.createTemp('fish_dead_'));
      srv.stallRequests = 1 << 20; // 永远停住
      srv.stallAfterBytes = 64 * 1024; // 每次只发 64KB 就静默
      await srv.start();
      addTearDown(srv.stop);

      final AppUpdater u = _newUpdater(conns: 4, watchdogMs: 300, backoffMs: 60);
      final AppUpdateInfo info = _infoFor(srv.url, data, await _sha256Of(data), versionCode: 9002);
      final String savePath = _savePathFor(info);
      addTearDown(() => u.discard(savePath));

      final Stopwatch sw = Stopwatch()..start();
      Object? thrown;
      try {
        await u.download(info);
      } catch (e) {
        thrown = e;
      }
      sw.stop();

      // ④ 明确失败：**不是永远等**（这就是修复前永不到达的终点）
      expect(thrown, isA<ApiException>(), reason: '必须抛出可展示的异常，而不是挂着');
      final ApiException ex = thrown! as ApiException;
      expect(ex.message, AppUpdater.stalledMessage, reason: '失败文案必须具体（UI 直接展示）：${ex.message}');
      expect(u.stallDetections, greaterThanOrEqualTo(2),
          reason: '并行阶段与降级单连接阶段都判死过（实测 ${u.stallDetections} 次）');
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)),
          reason: '必须有界：实测 ${sw.elapsed.inMilliseconds}ms');

      // 断点续传现场必须保留（重试能接着下，而不是从零开始）
      expect(await File(savePath).exists(), isFalse, reason: '没下完绝不能产出 .apk（否则会被安装坏包）');
      expect(await File('$savePath.part').exists(), isTrue, reason: '失败必须保留 .part（已下部分算数）');
      expect(await File('$savePath.part${PartSidecar.suffix}').exists(), isTrue, reason: '失败必须保留 sidecar');
    });
  });

  // ──── ⑤ 线上真实形态：字节"零星到达"，只有总进度看门狗能抓到 ────

  group('⑤ 真 socket：零星到达（线上 0.00 MB/s 的形态）', () {
    test('每 250ms 才来 1 个字节（读空闲超时永远不触发）→ 仍然判死并明确失败', () async {
      final Uint8List data = _payload(512 * 1024, seed: 41); // < 4MB → 走单连接路径
      final _StallServer srv = _StallServer(data, await Directory.systemTemp.createTemp('fish_trickle_'));
      srv.trickleMicrosPerByte = 250000; // 1 字节 / 250ms（< 判死窗口，故"空闲超时"型实现永不触发）
      await srv.start();
      addTearDown(srv.stop);

      final AppUpdater u = _newUpdater(conns: 1, watchdogMs: 300, backoffMs: 60, minGrowthBytes: 8 * 1024);
      final AppUpdateInfo info = _infoFor(srv.url, data, await _sha256Of(data), versionCode: 9003);
      addTearDown(() => u.discard(_savePathFor(info)));

      final Stopwatch sw = Stopwatch()..start();
      Object? thrown;
      try {
        await u.download(info);
      } catch (e) {
        thrown = e;
      }
      sw.stop();

      expect(thrown, isA<ApiException>());
      final ApiException ex = thrown! as ApiException;
      expect(ex.message, AppUpdater.stalledMessage);
      expect(u.stallDetections, greaterThanOrEqualTo(1), reason: '零星到达也必须判死（这正是"0.00 MB/s"）');
      expect(srv.bytesServed, lessThan(64 * 1024), reason: '确实只到过零星几个字节');
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)), reason: '实测 ${sw.elapsed.inMilliseconds}ms');
    });
  });

  // ─────────────────── ⑥ UI：失败必须可见 + 可重试 ───────────────────
  //
  // 放在 `update_ui_test.dart`（弹窗渲染契约那份）：**本文件绝不能出现 testWidgets**
  // —— Flutter 的 widget 测试绑定会给整个 isolate 装上"HTTP 一律回 400"的
  // HttpOverrides，同一文件里的真 socket 用例会全部失效（实测踩过）。
  //

  // ─────────── ⑦ 提速专项（2026-10-17）：真并发 + 队列深度 ───────────

  group('⑦ 提速：多片真的同时在飞，且片数多于并发（慢连接不拖尾）', () {
    test('12 并发：实测峰值同时在飞 ≥ 12（证明没被排队成串行）+ 片数=队列深度', () async {
      const int conns = 12;
      final Uint8List data = _payload(12 * 1024 * 1024 + 4096, seed: 71);
      final _StallServer srv = _StallServer(data, await Directory.systemTemp.createTemp('fish_conc_'));
      await srv.start();
      addTearDown(srv.stop);

      final AppUpdater u = _newUpdater(conns: conns, watchdogMs: 5000, backoffMs: 50);
      final AppUpdateInfo info = _infoFor(srv.url, data, await _sha256Of(data), versionCode: 9007);
      addTearDown(() => u.discard(_savePathFor(info)));

      final String path = await u.download(info);

      // ① 真并发：服务端亲口报告"同时在处理多少条请求"的峰值
      expect(srv.maxInFlight, greaterThanOrEqualTo(conns),
          reason: '必须真的同时开 $conns 条连接（实测峰值 ${srv.maxInFlight}）——'
              '若这里只有 1，就是被 maxConnectionsPerHost 之类的上游限制排队成串行了');
      // ② 片数 = 并发 × 队列深度（12MB：12×4=48 片请求被 minShardBytes=512KiB 钳到 24 片）
      const int expectPieces = 24;
      expect(srv.rangeRequests, greaterThanOrEqualTo(expectPieces),
          reason: '片数应达队列深度（实测 ${srv.rangeRequests} 片）');
      // ③ 只补缺口：总拉取量不超过"整包 + 一片"（没有把同一段重复拉两遍）
      expect(srv.bytesServed, lessThan(data.length + 512 * 1024),
          reason: '不该重复拉取（实测 ${srv.bytesServed} / ${data.length}）');
      // ④ 内容正确（片切得更小之后最容易出的错就是偏移写错）
      expect(await u.fileSha256(path), info.fileHash);
      expect(await File(path).length(), data.length);
    });
  });

  // ─────── ⑧ 云端真实链路实测（默认 SKIP；只有显式设了 base 才跑）───────
  //
  // 为什么要它：分片提速这件事**必须用真链路数据说话**（单测只能证明逻辑对）。
  // 默认不跑（不设 FISH_CLOUD_E2E_BASE 就 SKIP），避免日常/CI 依赖外网。
  // 用法（幂等，可复现）：
  //   $env:FISH_CLOUD_E2E_BASE="http://<云端>:3100/api/v1"; flutter test test/update_stall_watchdog_test.dart --plain-name 云端
  group('⑧ 云端真实链路实测：改造前 vs 改造后（默认 SKIP）', () {
    test('真下载器实测：4 并发×1 片（改造前配置）vs 12 并发×队列深度4（改造后）', () async {
      final String base = Platform.environment['FISH_CLOUD_E2E_BASE'] ?? '';
      if (base.isEmpty) {
        // ignore: avoid_print
        print('SKIP ⑧ 云端实测：未设 FISH_CLOUD_E2E_BASE（例：http://HOST:3100/api/v1）');
        return;
      }
      final _CloudInfo? info = await _fetchCloudInfo(base);
      expect(info, isNotNull, reason: '取不到云端版本信息：$base');
      final _CloudInfo ci = info!;

      // ── 改造前：4 并发 × 1 片（旧的默认）+ 只观察 20 秒 ──
      // 不跑完是有意的：片数 = 并发数时**最慢那条连接决定整包耗时**（实测尾片要
      // 5–10 分钟），跑完会把用例拖到不可接受；聚合速度 + 尾片效应分开描述更诚实。
      final AppUpdater uOld = AppUpdater.forTesting();
      uOld.shardConfig = const ShardConfig(maxConnections: 4, piecesPerConnection: 1);
      final AppUpdateInfo oldInfo = ci.toUpdateInfo(versionCodeDelta: 0);
      final CancelToken kill = CancelToken();
      final Timer window = Timer(const Duration(seconds: 20), () {
        if (!kill.isCancelled) kill.cancel('实测窗口到');
      });
      int oldBytes = 0;
      final Stopwatch swOld = Stopwatch()..start();
      try {
        await uOld.download(oldInfo, cancelToken: kill, onProgress: (int d, int _) => oldBytes = d);
      } catch (_) {
        // 预期：20 秒窗口到点被取消
      }
      window.cancel();
      swOld.stop();
      final double oldSecs = swOld.elapsedMilliseconds / 1000;
      // ignore: avoid_print
      print('⑧ 改造前（4 并发 × 1 片）：${oldSecs.toStringAsFixed(1)}s 拿到 $oldBytes 字节'
          ' = ${(oldBytes / 1024 / oldSecs).toStringAsFixed(1)} KB/s；'
          '按此聚合速度整包需 ${(ci.fileSize / (oldBytes / oldSecs)).toStringAsFixed(0)}s，'
          '但片数=并发数时实际由最慢片决定 ⇒ 尾片会显著更久');
      await uOld.discard(_savePathFor(oldInfo));

      // ── 改造后：默认配置（12 并发 × 队列深度 4）→ **跑完**并验 sha256 ──
      final AppUpdater uNew = AppUpdater.forTesting();
      final AppUpdateInfo newInfo = ci.toUpdateInfo(versionCodeDelta: 1);
      final Stopwatch swNew = Stopwatch()..start();
      final List<int> seen = <int>[];
      final String path = await uNew.download(newInfo, onProgress: (int d, int _) => seen.add(d));
      swNew.stop();
      addTearDown(() => uNew.discard(path));
      final double newSecs = swNew.elapsedMilliseconds / 1000;
      // ignore: avoid_print
      print('⑧ 改造后（12 并发 × 队列深度 4）：${newSecs.toStringAsFixed(1)}s 下完 ${ci.fileSize} 字节'
          ' = ${(ci.fileSize / 1024 / newSecs).toStringAsFixed(1)} KB/s；'
          '片数=${ShardPlanner.split(total: ci.fileSize, connections: uNew.shardConfig.maxConnections, config: uNew.shardConfig).length}'
          '；进度事件=${seen.length} 次');

      expect(await uNew.fileSha256(path), ci.fileHash, reason: '真链路下载必须与云端 sha256 一致');
      expect(await File(path).length(), ci.fileSize);
      expect(uNew.stallDetections, 0, reason: '链路正常时不该出现停滞判死（实测 ${uNew.stallDetections}）');
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}

// ───────────────────────────── 测试辅助 ─────────────────────────────

AppUpdater _newUpdater({
  required int conns,
  required int watchdogMs,
  required int backoffMs,
  int minGrowthBytes = 16 * 1024,
  int piecesPerConnection = 4,
  int minShardBytes = 512 * 1024,
}) {
  final AppUpdater u = AppUpdater.forTesting();
  u.shardConfig = ShardConfig(
    maxConnections: conns,
    maxAttemptsPerShard: 3,
    piecesPerConnection: piecesPerConnection,
    minShardBytes: minShardBytes,
  );
  u.stallConfig = StallConfig(
    stallTimeout: Duration(milliseconds: watchdogMs),
    minGrowthBytes: minGrowthBytes,
    maxStallRetries: 3,
    retryBackoff: <Duration>[
      Duration(milliseconds: backoffMs),
      Duration(milliseconds: backoffMs),
      Duration(milliseconds: backoffMs),
    ],
  );
  return u;
}

AppUpdateInfo _infoFor(String url, Uint8List data, String hash, {required int versionCode}) => AppUpdateInfo(
      hasUpdate: true,
      force: false,
      versionCode: versionCode,
      versionName: 'test',
      updateDesc: 'test',
      fileSize: data.length,
      fileHash: hash,
      downloadUrl: url,
    );

String _savePathFor(AppUpdateInfo info) =>
    '${Directory.systemTemp.path}/fish_update/fish_update_v${info.versionCode}.apk';

/// 造一份"可复现的随机内容"（不用全 0：全 0 会掩盖偏移写错）
Uint8List _payload(int len, {required int seed}) {
  final Random r = Random(seed);
  final Uint8List out = Uint8List(len);
  for (int i = 0; i < len; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

Future<String> _sha256Of(Uint8List data) async =>
    (await sha256.bind(Stream<List<int>>.value(data)).first).toString();

/// 云端版本信息（⑧ 组用；见 `_fetchCloudInfo`）
class _CloudInfo {
  _CloudInfo({
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

  /// [versionCodeDelta] 用来把同一次实测的两轮（改造前/后）落到不同临时文件上，
  /// 避免互相踩 .part/sidecar（生产里 versionCode 天然不同）。
  AppUpdateInfo toUpdateInfo({int versionCodeDelta = 0}) => AppUpdateInfo(
        hasUpdate: true,
        force: false,
        versionCode: versionCode + versionCodeDelta,
        versionName: versionName,
        updateDesc: 'cloud-e2e',
        fileSize: fileSize,
        fileHash: fileHash,
        downloadUrl: downloadUrl,
      );
}

/// 向云端问"最新启用版本"（⑧ 组用；不打桩，真接口）
Future<_CloudInfo?> _fetchCloudInfo(String base) async {
  final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 15),
  ));
  try {
    final Response<dynamic> r = await dio.get<dynamic>(
      '$base/public/app-versions/latest',
      queryParameters: <String, dynamic>{'appType': 'boss', 'currentVersionCode': 0},
    );
    final Map<String, dynamic> data = (r.data as Map)['data'] as Map<String, dynamic>;
    final Map<String, dynamic> latest = data['latest'] as Map<String, dynamic>;
    final String rel = '${latest['downloadUrl']}';
    if (rel.isEmpty) return null;
    final Uri baseUri = Uri.parse(base.endsWith('/') ? base : '$base/');
    // 服务端下发的是"从根开始"的相对路径（/api/v1/...），所以要用**站点根**去拼，
    // 不能拿 base（它自带 /api/v1）去拼 —— 否则会拼成 /api/v1/api/v1/...（实测踩过）
    final Uri root = baseUri.replace(path: '/', query: '', fragment: '');
    final String abs = rel.startsWith('http')
        ? rel
        : root.resolve(rel.startsWith('/') ? rel.substring(1) : rel).toString();
    return _CloudInfo(
      fileSize: (latest['fileSize'] as num).toInt(),
      fileHash: '${latest['fileHash']}',
      versionCode: (latest['versionCode'] as num).toInt(),
      versionName: '${latest['versionName']}',
      downloadUrl: abs,
    );
  } catch (_) {
    return null;
  } finally {
    dio.close(force: true);
  }
}

/// 会在传输中途**静默停住**的真 socket 文件服务器（复现线上故障的服务器侧行为）。
///
/// 关键点：停住时**既不关连接也不发数据** —— 这正是"不报错、不结束、进度不涨"
/// 的形态；只有服务端在 RST/正常结束的情况下客户端才可能自愈。
class _StallServer {
  _StallServer(this.data, this.dir);

  final Uint8List data;
  final Directory dir;

  /// 前 N 个"真"请求（探测 `Range: bytes=0-0` 不算）会停住，之后恢复正常
  int stallRequests = 0;

  /// 停住之前先发多少字节（0 = 一个字节都不发）
  int stallAfterBytes = 0;

  /// 每字节之间的延时（微秒）——造"零星到达"
  int trickleMicrosPerByte = 0;

  /// 真请求（非探测）收到的区间起点，按到达顺序
  final List<int> requestStarts = <int>[];
  final List<DateTime> requestTimes = <DateTime>[];

  int stalledRequests = 0;
  int bytesServed = 0;
  DateTime? firstHoldAt;

  /// 同时在处理的真请求数（用来证明"多片真的同时在飞"，而不是被排队成串行）
  int inFlight = 0;
  int maxInFlight = 0;

  /// 真（非探测）区间请求总数 = 实际发出的分片请求数
  int rangeRequests = 0;

  int _stallsUsed = 0;
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
    try {
      await _server.close(force: true);
    } catch (_) {}
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest req) async {
    final HttpResponse res = req.response;
    // 关掉输出缓冲：默认 bufferOutput=true 时，小写入**不会**被发出去（要等缓冲区满），
    // 那样"零星到达"就退化成"完全静默"，测不出我们要测的东西（实测踩过）。
    res.bufferOutput = false;
    try {
      final String? raw = req.headers.value('range');
      final RegExpMatch? m = raw == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(raw);
      final bool isProbe = m != null && m.group(1) == '0' && m.group(2) == '0';
      if (m == null) {
        // 整包请求（单连接路径）
        res.statusCode = 200;
        res.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.android.package-archive');
        res.headers.set('Accept-Ranges', 'bytes');
        res.headers.contentLength = data.length;
        await _send(res, 0, data.length - 1, stallable: true);
        return;
      }
      final int start = int.parse(m.group(1)!);
      final int end = m.group(2)!.isEmpty ? data.length - 1 : min(int.parse(m.group(2)!), data.length - 1);
      if (!isProbe) {
        requestStarts.add(start);
        requestTimes.add(DateTime.now());
        rangeRequests++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight; // 观察真并发峰值
      }
      final int len = end - start + 1;
      res.statusCode = 206;
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/vnd.android.package-archive');
      res.headers.set('Accept-Ranges', 'bytes');
      res.headers.set('Content-Range', 'bytes $start-$end/${data.length}');
      res.headers.contentLength = len;
      try {
        await _send(res, start, end, stallable: !isProbe);
      } finally {
        if (!isProbe) inFlight--;
      }
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _send(HttpResponse res, int start, int end, {required bool stallable}) async {
    final bool stall = stallable && _stallsUsed < stallRequests;
    if (stall) {
      _stallsUsed++;
      stalledRequests++;
    }
    final RandomAccessFile raf = await _file.open();
    try {
      await raf.setPosition(start);
      int remaining = end - start + 1;
      int sent = 0;
      const int chunk = 64 * 1024;
      while (remaining > 0) {
        if (stall && sent >= stallAfterBytes) {
          // 静默停住：不关连接、不报错、不发数据（很久之后由 stop() 强制收走）
          firstHoldAt ??= DateTime.now();
          await Future<void>.delayed(const Duration(seconds: 20));
          return;
        }
        final int want = trickleMicrosPerByte > 0 ? 1 : (remaining < chunk ? remaining : chunk);
        final Uint8List buf = await raf.read(want);
        if (buf.isEmpty) break;
        res.add(buf);
        await res.flush();
        sent += buf.length;
        remaining -= buf.length;
        bytesServed += buf.length;
        if (trickleMicrosPerByte > 0) {
          await Future<void>.delayed(Duration(microseconds: trickleMicrosPerByte));
        }
      }
    } finally {
      await raf.close();
      try {
        await res.close();
      } catch (_) {}
    }
  }
}
