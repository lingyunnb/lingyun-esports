// 端到端隧道实测：改造前（单连接）vs 改造后（多连接分片），**走真实隧道 + 真实 26MB APK**。
//
// 为什么放在 flutter test 里跑：fish_core 依赖 Flutter（dart:ui），纯 `dart run` 编译不过；
// 而 `flutter test` 既有 VM 又有完整依赖，还能顺带断言 sha256。
//
// 两条路径都调用**生产代码** AppUpdater.download，背靠背交替执行（否则隧道抖动会淹没结论）：
//   before = maxConnections=1  → 等价于改造前的单连接整包（+ Range 续传）
//   after  = maxConnections=4  → 生产默认的多连接分片
//
// 运行：flutter test test/update_e2e_tunnel_test.dart
//   可传 --dart-define=TUNNEL=https://xxx 覆盖隧道地址
//
// ⚠️ 本文件带 `e2e-tunnel` 标签（见 dart_test.yaml），**默认 `flutter test` 不跑**：
// 它要经公网隧道下载 26MB×4 次（ngrok 免费档有限速/月流量），既慢又吃配额，
// 不适合放进日常回归。要测提速效果时显式加 `--tags e2e-tunnel`。
@Tags(<String>['e2e-tunnel'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

const String tunnel = String.fromEnvironment(
  'TUNNEL',
  defaultValue: 'https://<your-tunnel-domain>',
);

Future<Map<String, dynamic>?> fetchLatest(String base) async {
  final Dio dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 40)));
  try {
    final Response<dynamic> r = await dio.get<dynamic>(
      '$base/api/v1/public/app-versions/latest',
      queryParameters: <String, dynamic>{'appType': 'boss', 'currentVersionCode': 1},
      options: Options(headers: <String, dynamic>{
        ApiClient.ngrokSkipWarningHeader: ApiClient.ngrokSkipWarningValue,
        'User-Agent': ApiClient.appUserAgent,
      }),
    );
    return ((r.data as Map)['data'] as Map)['latest'] as Map<String, dynamic>;
  } catch (e) {
    // ignore: avoid_print
    print('探测隧道失败：$e');
    return null;
  } finally {
    dio.close(force: true);
  }
}

void main() {
  test('端到端：真实隧道 26MB APK 改造前 vs 改造后（2 轮）+ sha256 一致', () async {
    final Map<String, dynamic>? latest = await fetchLatest(tunnel);
    if (latest == null) {
      // ignore: avoid_print
      print('SKIP：隧道 $tunnel 不可用');
      return;
    }
    final String url = '$tunnel${latest['downloadUrl']}';
    final int fileSize = (latest['fileSize'] as num).toInt();
    final String fileHash = '${latest['fileHash']}';
    // ignore: avoid_print
    print('源=$url');
    // ignore: avoid_print
    print('大小=$fileSize 字节 (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB) 云端fileHash=$fileHash');

    final AppUpdateInfo info = AppUpdateInfo(
      hasUpdate: true,
      force: false,
      versionCode: 76,
      versionName: '1.11.19',
      updateDesc: 'bench',
      fileSize: fileSize,
      fileHash: fileHash,
      downloadUrl: url,
    );

    final Map<String, List<double>> secs = <String, List<double>>{'before(1连接)': <double>[], 'after(4连接)': <double>[]};
    final Map<String, List<bool>> hashOk = <String, List<bool>>{'before(1连接)': <bool>[], 'after(4连接)': <bool>[]};
    bool sawParallel = false;

    for (int round = 1; round <= 2; round++) {
      for (final MapEntry<String, int> arm in <String, int>{'before(1连接)': 1, 'after(4连接)': 4}.entries) {
        final AppUpdater u = AppUpdater.forTesting();
        u.shardConfig = ShardConfig(maxConnections: arm.value);
        await u.discard('${Directory.systemTemp.path}/fish_update/fish_update_v76.apk');

        final Stopwatch sw = Stopwatch()..start();
        String path;
        try {
          path = await u
              .download(info, onProgress: (int d, int t) => print('  ${arm.key} 进度 $d/$t'))
              .timeout(const Duration(seconds: 100));
        } on TimeoutException {
          // 单臂超时不能让整轮没有数据：记录下来继续跑另一臂
          print('  ${arm.key} 单臂超时（100 秒）——隧道当前吞吐过低');
          sw.stop();
          secs[arm.key]!.add(sw.elapsedMilliseconds / 1000);
          hashOk[arm.key]!.add(false);
          await u.discard('${Directory.systemTemp.path}/fish_update/fish_update_v76.apk');
          continue;
        }
        sw.stop();
        final String got = await u.fileSha256(path);
        final double s = sw.elapsedMilliseconds / 1000;
        secs[arm.key]!.add(s);
        hashOk[arm.key]!.add(got == fileHash);
        // ignore: avoid_print
        print('round$round ${arm.key}: ${s.toStringAsFixed(2)}s  '
            '${(fileSize / 1024 / 1024 / s).toStringAsFixed(2)} MB/s  sha256一致=${got == fileHash}');
        await u.discard(path);
      }
    }

    // ignore: avoid_print
    print('=== 汇总 ===');
    for (final String arm in <String>['before(1连接)', 'after(4连接)']) {
      final List<double> xs = secs[arm]!;
      final double avgS = xs.reduce((double a, double b) => a + b) / xs.length;
      final List<String> parts = <String>[];
      for (final double x in xs) {
        parts.add('${x.toStringAsFixed(2)}s/${(fileSize / 1024 / 1024 / x).toStringAsFixed(2)}MBps');
      }
      // ignore: avoid_print
      print('$arm: 平均 ${avgS.toStringAsFixed(2)}s / ${(fileSize / 1024 / 1024 / avgS).toStringAsFixed(2)} MB/s'
          '  [${parts.join(', ')}]  sha256全一致=${hashOk[arm]!.every((bool b) => b)}');
    }
    final double before = secs['before(1连接)']!.reduce((double a, double b) => a + b) / 2;
    final double after = secs['after(4连接)']!.reduce((double a, double b) => a + b) / 2;
    // ignore: avoid_print
    print('耗时缩短 ${(before / after).toStringAsFixed(2)}x（等效提速）');

    expect(hashOk['after(4连接)']!.every((bool b) => b), isTrue, reason: '改造后 sha256 必须与云端一致');
    expect(hashOk['before(1连接)']!.every((bool b) => b), isTrue, reason: '改造前路径也必须正确（零回归）');
    expect(sawParallel, isTrue, reason: '26MB 真包必须走分片并行');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
