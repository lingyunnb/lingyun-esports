/// 局域网优先（2026-10-06 上传体验专项）—— 地址解析策略的**唯一改动点**验证。
///
/// 背景（负责人实测，非推断）：
///   - 家里同一个 WiFi 下，App 却一直走 Cloudflare 快速隧道：322KB 图**上行 16KB/s、
///     20.7s**（用户体感 = 卡死）；而局域网直连 `http://192.168.1.145:3100`
///     **6.3MB/s、0.05s**。
///   - 根因是客户端策略：内置候选（含烧录的局域网 IP）**只在"所有隧道都失败"时**才启用
///     → 隧道活着就永远不试局域网。
///   - 本轮把优先级改成：**可达的局域网候选 > preferred（ngrok 固定域名）> 最快隧道候选**，
///     并且**任何情况下都保留既有回退与热切换语义**（`AddressWatchdog` 一字不改）。
///
/// 本文件的正负用例（负向必做）：
///   ① 局域网可达 + 隧道可达        → 选**局域网**（且不选 preferred）
///   ② 仅隧道可达（局域网不在同一内网）→ 选隧道，**不阻塞**（LAN 探活受 1.5s 上限约束）
///   ③ 局域网超时（永远不答）        → 不阻塞、回落隧道，且耗时 < LAN 上限 + 余量
///   ④ 局域网也不可达 + 无隧道       → 仍回退内置地址（**绝不抛异常、绝不空地址**）
///   ⑤ 运行期热切换：隧道死了、局域网活着 → watchdog 重取后切到局域网
///   ⑥ 纯函数：私网判定 / 地址类别 / 诊断行的 LAN 标识
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 局域网候选（**正是 APK 里烧录的那个内置候选**）
const String kLanApi = 'http://192.168.1.145:3100/api/v1';

/// 公网隧道候选（Cloudflare 快速隧道形态）
const String kTunnelApi = 'https://vista-bind-archives-components.trycloudflare.com/api/v1';

/// 固定域名（ngrok，`preferred` 用它）
const String kPreferredApi = 'https://<your-tunnel-domain>/api/v1';

void main() {
  setUp(() {
    AppConfigRuntime.reset();
    AppAddressResolver.debugFetchBootstrap = null;
    AppAddressResolver.debugFetchHealth = null;
    AppAddressResolver.debugBuiltinCandidates = null;
    AppAddressResolver.debugBootstrapSources = null;
    AppAddressResolver.debugEnabledOverride = null;
    AppAddressResolver.debugLog = null;
    AppAddressResolver.loadLastKnownGood = null;
    AppAddressResolver.saveLastKnownGood = null;
    AddressWatchdog.instance
      ..debugReset()
      ..uninstall()
      ..debugResolve = null
      ..debugSchedule = null
      ..debugLog = null
      ..onRefreshed = null;
    ApiCache.instance.clear();
  });

  tearDown(() {
    AppConfigRuntime.reset();
    AppAddressResolver.debugFetchBootstrap = null;
    AppAddressResolver.debugFetchHealth = null;
    AppAddressResolver.debugBuiltinCandidates = null;
    AppAddressResolver.debugBootstrapSources = null;
    AppAddressResolver.debugEnabledOverride = null;
    AppAddressResolver.debugLog = null;
    AppAddressResolver.loadLastKnownGood = null;
    AppAddressResolver.saveLastKnownGood = null;
    AddressWatchdog.instance
      ..debugReset()
      ..uninstall()
      ..debugResolve = null
      ..debugSchedule = null
      ..debugLog = null
      ..onRefreshed = null;
    ApiCache.instance.clear();
  });

  // ==========================================================================
  // ① 局域网可达 + 隧道可达 → 选局域网
  // ==========================================================================
  group('① 局域网优先', () {
    test('隧道可达 + 局域网可达 + preferred 可达 → **选局域网**（最快者）', () async {
      final List<String> logs = <String>[];
      AppAddressResolver.debugLog = logs.add;
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '''
{
  "api": "$kTunnelApi",
  "preferred": "$kPreferredApi",
  "candidates": ["$kTunnelApi", "$kPreferredApi"]
}''';
      // 局域网 9ms（实测值）、隧道 1188ms、preferred 300ms
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kLanApi) return 9;
        if (api == kTunnelApi) return 1188;
        if (api == kPreferredApi) return 300;
        return null;
      };

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.address.apiBaseUrl, kLanApi,
          reason: '局域网可达时必须赢下优先级 —— 这正是"在家连 WiFi 却走慢隧道"的修复点');
      expect(r.address.source, 'lan');
      expect(r.address.latencyMs, 9);
      expect(r.address.kind, AddressKind.lan);
      expect(r.address.kindLabel, 'LAN');
      expect(AppConfig.apiBase, kLanApi, reason: '解析结果必须真的写进运行期地址槽');
      expect(AppConfig.wsBase, 'http://192.168.1.145:3100',
          reason: 'ws 由 api 派生（同源同端口），不能沿用下发的隧道 ws');
      expect(logs.any((String l) => l.contains('局域网可达') && l.contains(kLanApi)), isTrue,
          reason: '必须留下"局域网优先生效"的可观测日志');
    });

    test('局域网有多个候选 → 取**最快**那个（不是第一个）', () async {
      const String lan2 = 'http://192.168.1.200:3100/api/v1';
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi, lan2];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kLanApi) return 40;
        if (api == lan2) return 12;
        if (api == kTunnelApi) return 500;
        return null;
      };

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, lan2);
      expect(r.address.latencyMs, 12);
    });

    test('局域网赢下时**不需要**任何引导源成功（隧道整条腿全挂也照样走局域网）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://dead.example.com/site/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String _) async => throw StateError('隧道引导不可达');
      AppAddressResolver.debugFetchHealth = (String api) async => api == kLanApi ? 8 : null;

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, kLanApi);
      expect(r.address.kind, AddressKind.lan);
    });
  });

  // ==========================================================================
  // ② 仅隧道可达 → 选隧道（负向：局域网不参与时不改变既有行为）
  // ==========================================================================
  group('② 仅隧道可达（不在同一内网）', () {
    test('局域网探活失败 → 回落隧道；preferred 仍优先于"最快的临时隧道"', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '''
{"api": "$kTunnelApi", "preferred": "$kPreferredApi",
 "candidates": ["$kTunnelApi", "$kPreferredApi"]}''';
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kTunnelApi) return 100; // 临时隧道今天恰好更快
        if (api == kPreferredApi) return 400; // 固定域名慢一点但活着
        return null; // 局域网不可达
      };

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.address.apiBaseUrl, kPreferredApi,
          reason: 'preferred（固定域名）活着就该赢 —— 既有语义一字不改');
      expect(r.address.source, 'bootstrap+preferred');
      expect(r.address.kind, AddressKind.tunnel);
    });

    test('局域网不可达 + 无 preferred → 取最快的隧道候选', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '''
{"api": "$kTunnelApi", "candidates": ["$kTunnelApi", "$kPreferredApi"]}''';
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kTunnelApi) return 900;
        if (api == kPreferredApi) return 220;
        return null;
      };

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, kPreferredApi);
      expect(r.address.source, 'bootstrap+probe');
      expect(r.error, isNull);
    });

    test('局域网不可达时**日志明确说明跳过**（不是静默）', () async {
      final List<String> logs = <String>[];
      AppAddressResolver.debugLog = logs.add;
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async => api == kTunnelApi ? 120 : null;

      await AppAddressResolver.resolve();
      expect(logs.any((String l) => l.contains('局域网候选均不可达')), isTrue);
      expect(logs.any((String l) => l.contains('kind=隧道')), isTrue, reason: '解析完成日志要标出地址类别');
    });
  });

  // ==========================================================================
  // ③ 局域网超时 → 不阻塞、回落隧道（负向关键用例）
  // ==========================================================================
  group('③ 局域网超时（挂死不答）', () {
    test('局域网探活挂死 → 1.5s 上限内放弃，隧道接管（**不阻塞冷启动**）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      // 局域网**永远不答**（模拟"不在同一内网"：SYN 出去没有响应）
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kTunnelApi) return 150;
        await Future<void>.delayed(const Duration(seconds: 30));
        return 5;
      };

      final Stopwatch sw = Stopwatch()..start();
      final AddressResolution r = await AppAddressResolver.resolve();
      sw.stop();

      expect(r.address.apiBaseUrl, kTunnelApi, reason: '局域网拿不到就必须回落隧道');
      expect(r.address.kind, AddressKind.tunnel);
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '局域网上限 ${AppAddressResolver.lanProbeGate.inMilliseconds}ms + 余量；'
              '绝不能等满探活超时（${AppAddressResolver.probeTimeout.inMilliseconds}ms）');
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('局域网超时后**不会**把隧道结果丢掉（解析仍成功、无 error）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kTunnelApi) return 180;
        await Future<void>.delayed(const Duration(seconds: 30));
        return 5;
      };

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.fromBootstrap, isTrue);
      expect(r.error, isNull);
      expect(AppConfig.apiBase, kTunnelApi);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // ==========================================================================
  // ④ 全不可达 → 回退内置（既有兜底不破）
  // ==========================================================================
  group('④ 兜底', () {
    test('局域网 + 隧道全部不可达 → 回退内置地址，**绝不抛异常、绝不空地址**', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('github-raw', 'https://raw.invalid/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String _) async => throw StateError('不可达');
      AppAddressResolver.debugFetchHealth = (String _) async => null;

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, isNotEmpty);
      expect(r.error, isNotNull);
      expect(AppConfig.apiBase, isNotEmpty, reason: 'App 必须一定起得来');
    });

    test('局域网候选为空（纯公网包）→ 行为与改动前一致：直接用隧道', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>['https://builtin.example.com/api/v1'];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async => api == kTunnelApi ? 200 : null;

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, kTunnelApi);
      expect(r.address.source, 'bootstrap+probe');
    });
  });

  // ==========================================================================
  // ⑤ 运行期热切换：隧道死 → 局域网接管（watchdog 语义不变）
  // ==========================================================================
  group('⑤ 热切换', () {
    test('watcher 重取时局域网活着 → 热切换到局域网，并触发 onRefreshed', () async {
      final List<String> logs = <String>[];
      AddressWatchdog.instance
        ..debugLog = logs.add
        ..maxRefreshes = 3
        ..failureThreshold = 3;

      // 第一次解析：只有隧道活着
      bool lanAlive = false;
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async =>
          lanAlive ? '{"api": "$kTunnelApi"}' : '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api == kTunnelApi) return 200;
        return lanAlive ? 7 : null;
      };

      final AddressResolution first = await AppAddressResolver.resolve();
      expect(first.address.apiBaseUrl, kTunnelApi);

      // 场景切换：用户回到家里的 WiFi（局域网活了），隧道因限流变慢/不可达
      lanAlive = true;
      bool refreshed = false;
      AddressWatchdog.instance.onRefreshed = (_) => refreshed = true;

      final AddressResolution? again = await AddressWatchdog.instance.refresh(reason: '测试：隧道失效');

      expect(again, isNotNull);
      expect(AppConfig.apiBase, kLanApi, reason: '运行中必须能热切换到局域网（不要求重启 App）');
      expect(refreshed, isTrue, reason: '切换成功要回调 onRefreshed（生产接 WS 重连）');
      expect(logs.any((String l) => l.contains('已热切换')), isTrue);
    });

    test('地址没变时**不**回调 onRefreshed（既有语义：只有真切换才回调）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async => api == kTunnelApi ? 200 : null;

      await AppAddressResolver.resolve();
      bool refreshed = false;
      AddressWatchdog.instance.onRefreshed = (_) => refreshed = true;

      await AddressWatchdog.instance.refresh(reason: '测试：地址不变');
      expect(AppConfig.apiBase, kTunnelApi);
      expect(refreshed, isFalse);
    });
  });

  // ==========================================================================
  // ⑥ 纯函数：私网判定 / 类别 / 诊断行
  // ==========================================================================
  group('⑥ 局域网识别与诊断', () {
    test('isPrivateHost：RFC1918 + 回环 + 链路本地 + .local；**不含**模拟器别名 10.0.2.2', () {
      for (final String ok in <String>[
        'http://192.168.1.145:3100/api/v1',
        'https://192.168.0.10/api/v1',
        'http://10.1.2.3/api/v1',
        'http://172.16.0.9:3100/api/v1',
        'http://172.31.255.254/api/v1',
        'http://127.0.0.1:3100/api/v1',
        'http://localhost:3100/api/v1',
        'http://fish-pc.local:3100/api/v1',
        'http://169.254.10.10:3100/api/v1',
      ]) {
        expect(AppAddressResolver.isPrivateHost(ok), isTrue, reason: '$ok 应判定为局域网');
      }
      for (final String no in <String>[
        'https://vista-bind-archives-components.trycloudflare.com/api/v1',
        'https://<your-tunnel-domain>/api/v1',
        'http://172.32.0.1/api/v1', // 出界（172.16–31 才是私网）
        'http://172.15.0.1/api/v1',
        'http://11.0.0.1/api/v1',
        'http://192.169.1.1/api/v1',
        'https://api.example.com/api/v1',
        '',
      ]) {
        expect(AppAddressResolver.isPrivateHost(no), isFalse, reason: '$no 不该判定为局域网');
      }
      // 开发专用别名：模拟器上它真的可达（= 开发机 localhost），
      // 但真机上它什么都不是 —— 当 LAN 候选只会白探一次，还会搅乱模拟器调试时的隧道优先级。
      expect(AppAddressResolver.isPrivateHost('http://10.0.2.2:3100/api/v1'), isFalse,
          reason: '${AppAddressResolver.emulatorHostAlias} 是编译期开发兜底，不是局域网候选');
    });

    test('addressKindOf：lan / tunnel / builtin / unknown 四态', () {
      expect(AppAddressResolver.addressKindOf(kLanApi), AddressKind.lan);
      expect(AppAddressResolver.addressKindOf(kTunnelApi), AddressKind.tunnel);
      expect(AppAddressResolver.addressKindOf(kPreferredApi), AddressKind.tunnel);
      expect(AppAddressResolver.addressKindOf('https://api.qilian.example/api/v1'), AddressKind.builtin);
      expect(AppAddressResolver.addressKindOf(''), AddressKind.unknown);
      // 四个类别都有可读标签（诊断行直接给人看）
      expect(AddressKind.lan.label, 'LAN');
      expect(AddressKind.tunnel.label, '隧道');
    });

    test('lanCandidates 只挑内置清单里的局域网项（候选来源唯一）', () {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi, kTunnelApi, kPreferredApi];
      expect(AppAddressResolver.lanCandidates, <String>[kLanApi]);
      AppAddressResolver.debugBuiltinCandidates = <String>[kTunnelApi];
      expect(AppAddressResolver.lanCandidates, isEmpty);
    });

    test('诊断行带地址类别标识（老板端「设置 → 诊断 → 当前服务器地址」）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[kLanApi];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async => api == kLanApi ? 9 : 400;

      await AppAddressResolver.resolve();
      final String line = AppConfig.serverAddressLine;
      expect(line, contains('192.168.1.145:3100'));
      expect(line, contains('LAN'), reason: '行首类别必须写明是局域网直连');
      expect(line, contains('lan'));
      expect(line, contains('9ms'));
    });

    test('诊断行在隧道下显示「隧道」（对照态）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>['https://builtin.example.com/api/v1'];
      AppAddressResolver.debugFetchBootstrap = (String _) async => '{"api": "$kTunnelApi"}';
      AppAddressResolver.debugFetchHealth = (String api) async => api == kTunnelApi ? 1188 : null;

      await AppAddressResolver.resolve();
      final String line = AppConfig.serverAddressLine;
      expect(line, contains('vista-bind-archives-components.trycloudflare.com'));
      expect(line, contains('隧道'));
      expect(line, contains('1188ms'));
    });

    test('未解析时**不贴类别标签**：显示编译期兜底地址 + 「未解析」（既有文案逐字不变）', () {
      AppConfigRuntime.reset();
      final String line = AppConfig.serverAddressLine;
      expect(line, contains('未解析'));
      expect(line.contains('null'), isFalse);
      // 未解析时地址是编译期兜底 `http://10.0.2.2:3100`（Android 模拟器别名，
      // 恰好落在私网段）—— 给它贴 LAN 标签会让人误以为"已确认走局域网"。
      expect(line.contains('LAN'), isFalse,
          reason: '没解析过就不该断言地址类别（避免误导报障排查）');
      expect(line, isNot(contains(' · LAN · ')));
    });
  });
}
