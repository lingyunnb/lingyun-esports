/// **真实演练**（端到端，走真网络）：ngrok 不可用 → App 自动切到 Cloudflare 隧道
///
/// 这条用例刻意**不 mock 任何东西**：真 bootstrap、真探活、真 HTTP 请求，
/// 直接打生产入口（Cloudflare 快速隧道 + ngrok 固定域名）。
///
/// 默认**跳过**（真实网络用例不该拖累常规回归），显式开启：
/// ```
/// cd apps/packages/core
/// $env:FISH_LIVE_DRILL='1'; flutter test test/address_live_drill_test.dart
/// ```
///
/// 演练场景（与负责人要求逐条对应）：
///   1. "当前地址"指向一个**必然失败**的地址（模拟 ngrok 额度耗尽后的 403/不可达）；
///   2. 引导源 = **服务端自托管族**，同时列出
///      ① ngrok 固定域名（真实不可用）② Cloudflare 隧道（真实可用）；
///   3. 运行中 3 次真实请求失败 → 看门狗自动重取 → 探活淘汰 ngrok、选中 Cloudflare
///      → **热切换**（同一个 ApiClient 实例，不用重启）；
///   4. 随后一次真实请求成功，贴出响应证据。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 演练开关：环境变量 `FISH_LIVE_DRILL=1`（或 `--dart-define=FISH_LIVE_DRILL=1`）
final bool kLiveDrill = Platform.environment['FISH_LIVE_DRILL'] == '1' ||
    const bool.fromEnvironment('FISH_LIVE_DRILL', defaultValue: false);

/// 必然连不上的地址（端口 1，连接被立即拒绝）
const String kDeadApi = 'http://127.0.0.1:1/api/v1';

/// ngrok 固定域名（2026-10-06 实测 403 ERR_NGROK_725：账号月度流量耗尽）
const String kNgrokApi = 'https://<your-tunnel-domain>/api/v1';

/// 真实发布出来的那份配置（由 scripts/publish-address.ps1 写）
const String kConfigFile = r'D:\fish\config\client-config.json';

void main() {
  test('真实演练：必然失败主候选 + 真实 Cloudflare 隧道备选 → 自动探活切换 + 后续请求成功', () async {
    // ---------------- 0. 读真实发布配置（演练的输入就是线上那一份） ----------------
    final File f = File(kConfigFile);
    if (!f.existsSync()) {
      fail('找不到 $kConfigFile —— 请先跑 scripts/publish-address.ps1');
    }
    final Map<String, dynamic> cfg =
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final String cfOrigin =
        Uri.parse(cfg['ws'] as String).origin; // 当前 Cloudflare 隧道
    final List<String> published =
        (cfg['candidates'] as List).map((Object? e) => '$e').toList();

    stdout.writeln('================ 真实演练 ================');
    stdout.writeln('[drill] 线上配置 api=${cfg['api']}');
    stdout.writeln('[drill] 线上配置 preferred=${cfg['preferred']}');
    stdout.writeln('[drill] 线上配置 candidates=$published');
    expect(cfOrigin, contains('trycloudflare.com'),
        reason: '演练要求备选是真实可用的 Cloudflare 隧道');

    // ---------------- 1. 起手：当前地址 = 必然失败（模拟 ngrok 挂掉） ----------------
    AppConfigRuntime.reset();
    AppConfigRuntime.apply(
      api: kDeadApi,
      ws: 'http://127.0.0.1:1',
      from: 'builtin',
    );

    // 同一个 ApiClient 实例贯穿全程 —— 用来证明"热切换"真的生效
    final ApiClient api = ApiClient();

    // ---------------- 2. 引导源：自托管族（真网络）----------------
    // ① ngrok 固定域名（真实 403）② Cloudflare 隧道（真实 200）
    AppAddressResolver.debugBuiltinCandidates = <String>[kNgrokApi, '$cfOrigin/api/v1'];
    AppAddressResolver.debugBootstrapSources = null; // 真·多源清单
    AppAddressResolver.debugFetchBootstrap = null; // 真 HTTP
    AppAddressResolver.debugFetchHealth = null; // 真探活
    AppAddressResolver.loadLastKnownGood = () async => kNgrokApi; // 本机记住的是 ngrok（最真实的场景）
    final List<String> addressLog = <String>[];
    AppAddressResolver.debugLog = (String m) {
      addressLog.add('[address] $m');
      stdout.writeln('[address] $m');
    };

    // ---------------- 3. 看门狗：3 次真实失败 → 自动重取 ----------------
    final AddressWatchdog w = AddressWatchdog.instance;
    final List<Duration> delays = <Duration>[];
    final List<void Function()> fires = <void Function()>[];
    w.debugSchedule = (Duration d, void Function() fire) {
      delays.add(d);
      fires.add(fire);
      stdout.writeln('[drill] 已排定重取：退避 ${d.inMilliseconds}ms');
    };
    AddressResolution? switched;
    w.onRefreshed = (AddressResolution r) {
      switched = r;
      RealtimeClient.shared.rebind(); // 与 main.dart 的线上接线一致
    };
    w.install();

    try {
      for (int i = 0; i < 3; i++) {
        await expectLater(
          api.request('POST', '/drill-touch'),
          throwsA(isA<ApiException>()),
          reason: '第 ${i + 1} 次请求应当真的失败（死地址）',
        );
      }
      stdout.writeln('[drill] 连续失败计数=${w.consecutiveFailures} 排定重取=${delays.length}');
      expect(delays.length, 1);

      // ---------------- 4. 触发自动重取（真 bootstrap + 真探活 + 热切换）----------------
      fires.removeAt(0)();
      final Stopwatch sw = Stopwatch()..start();
      while (w.refreshing || !AppConfig.apiBase.contains('trycloudflare')) {
        if (sw.elapsed > const Duration(seconds: 40)) {
          fail('重取超时（40s）—— 隧道/网络是否可用？当前 api=${AppConfig.apiBase}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      sw.stop();

      stdout.writeln('================ 切换结果 ================');
      stdout.writeln('[drill] 新地址 = ${AppConfig.apiBase}');
      stdout.writeln('[drill] 来源   = ${AppConfig.addressSource} '
          '(引导源=${AppConfigRuntime.bootstrapFrom})');
      stdout.writeln('[drill] 探活延迟 = ${AppConfigRuntime.latencyMs}ms  '
          '候选数=${AppConfigRuntime.candidateCount}  耗时=${sw.elapsedMilliseconds}ms');
      stdout.writeln('[drill] 诊断行 = ${AppConfig.serverAddressLine}');

      expect(AppConfig.addressSource, 'bootstrap+probe',
          reason: 'preferred(ngrok) 探活失败 → 退回最快者胜');
      expect(AppConfigRuntime.bootstrapFrom, 'self-hosted',
          reason: '走的必须是"服务端自托管"那条腿（不需要第三方账号）');
      expect(AppConfig.wsBase, cfOrigin, reason: 'ws 跟着换成同一个隧道');
      expect(AppConfigRuntime.switchCount, 1);
      expect(switched, isNotNull, reason: '必须上报切换事件（线上用它 rebind WS）');
      expect(w.consecutiveFailures, 0);

      // ---------------- 5. 同一个 ApiClient，后续请求真的成功 ----------------
      final Map<String, dynamic> grouped =
          await api.request('GET', '/divisions/grouped');
      final List<dynamic> groups = grouped['data'] as List<dynamic>;
      final int divisionCount = groups.fold<int>(
          0, (int a, dynamic g) => a + ((g as Map)['divisions'] as List).length);
      stdout.writeln('[drill] GET /divisions/grouped → code=${grouped['code']} '
          '分组=${groups.length} 分部=$divisionCount');

      final Map<String, dynamic> p1 = await api
          .request('GET', '/public/products', queryParameters: <String, dynamic>{'page': 1, 'pageSize': 1, 'divisionId': 1});
      final Map<String, dynamic> p2 = await api
          .request('GET', '/public/products', queryParameters: <String, dynamic>{'page': 1, 'pageSize': 1, 'divisionId': 2});
      final Map<String, dynamic> p3 = await api
          .request('GET', '/public/products', queryParameters: <String, dynamic>{'page': 1, 'pageSize': 1, 'divisionId': 3});
      stdout.writeln('[drill] 商品总数 divisionId=1|2|3 → '
          '${(p1['data'] as Map)['total']} | ${(p2['data'] as Map)['total']} | ${(p3['data'] as Map)['total']}');

      expect(grouped['code'], 0);
      expect(divisionCount, 5, reason: '冒烟：5 分部');
      expect((p1['data'] as Map)['total'], 11);
      expect((p2['data'] as Map)['total'], 11);
      expect((p3['data'] as Map)['total'], 11);

      // ---------------- 6. 断言"ngrok 确实被探活淘汰了" ----------------
      final bool ngrokMentioned = addressLog.any((String l) => l.contains('ngrok-free'));
      stdout.writeln('[drill] 日志里是否出现过 ngrok 引导源尝试：$ngrokMentioned');
      stdout.writeln('================ 演练通过 ================');
    } finally {
      AppAddressResolver.debugBuiltinCandidates = null;
      AppAddressResolver.debugBootstrapSources = null;
      AppAddressResolver.debugFetchBootstrap = null;
      AppAddressResolver.debugFetchHealth = null;
      AppAddressResolver.debugLog = null;
      AppAddressResolver.loadLastKnownGood = null;
      w
        ..debugReset()
        ..uninstall()
        ..debugSchedule = null
        ..onRefreshed = null;
      ApiCache.instance.clear();
    }
  }, skip: kLiveDrill ? false : '真实网络演练：加 --dart-define=FISH_LIVE_DRILL=1 开启');
}
