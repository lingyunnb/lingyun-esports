/// 地址发现韧性测试（2026-10-06 专项）
///
/// 背景（已实测，不是推测）：
///   - ngrok 固定域名 `<your-tunnel-domain>` 返回 **403 ERR_NGROK_725**
///     （账号月度流量耗尽），本地 3100 正常；
///   - 已发布的 1.11.21 APK 只烧录了该 ngrok 域名 + bootstrap=`raw.githubusercontent.com`，
///     而 GitHub raw 本机 **http=000 不可达** → 存量用户无法自动换址、远程不可用；
///   - 实测可达：Cloudflare 快速隧道 200 ✅ / Gitee 0.33s ✅ / jsDelivr ✅ / Sakura 官网 ✅；
///     GitHub raw 000 ❌。
///
/// 因此本轮把"地址发现"从"单源 + 一次性"改成"**多源 + 可自愈**"，本文件逐条验证：
///   ① 多源 bootstrap 顺序（第一个失败自动下一个）
///   ② 全部候选不可达：不死循环、退避且有上限
///   ③ 运行中切换：当前 base 失败 → 自动重取 bootstrap → 切到健康候选
///      （断言 `ApiClient` / WS 的 base 真的变了、且旧地址缓存不串味）
///   ④ 内置多候选并行探活取最快
///   ⑤ `ADDRESS_BOOTSTRAP_ENABLED=false` 时行为不变
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个会记录"收到过哪些请求"的真 HTTP 服务器（用于端到端证明请求真的打到了新地址）
class _RecordingStub {
  _RecordingStub(this.base, this._server, this._paths);

  final String base;
  final HttpServer _server;
  final List<String> _paths;

  List<String> get paths => List<String>.unmodifiable(_paths);

  Future<void> stop() => _server.close(force: true);

  static Future<_RecordingStub> start(String body) async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final List<String> paths = <String>[];
    server.listen((HttpRequest req) {
      paths.add(req.uri.path);
      req.drain<void>().catchError((Object _) {});
      req.response
        ..statusCode = 200
        ..headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
        ..write(body);
      req.response.close();
    });
    return _RecordingStub('http://127.0.0.1:${server.port}', server, paths);
  }
}

/// 轮询等待条件成立（地址重取是异步的；最多等 [timeout]）
Future<void> _until(bool Function() ready, {Duration timeout = const Duration(seconds: 4)}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!ready()) {
    if (sw.elapsed > timeout) {
      throw StateError('等待条件超时（${timeout.inMilliseconds}ms）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// 一个必然连不上的地址（端口 1，连接被立即拒绝 → 不依赖网速，确定性失败）
const String kDeadApi = 'http://127.0.0.1:1/api/v1';

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
  // ① 多源 bootstrap 顺序：第一个失败自动下一个
  // ==========================================================================
  group('① 多源 bootstrap 顺序', () {
    test('默认多源清单顺序 = Gitee > 自托管 > jsDelivr > GitHub raw（末位兼容）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>['https://builtin.example.com/api/v1'];

      final List<AddressBootstrapSource> sources = await AppAddressResolver.bootstrapSources();
      final List<String> names = sources.map((AddressBootstrapSource s) => s.name).toList();

      // Gitee 未配置（预留常量默认空）→ 整条跳过；配置后应排在**第一位**
      expect(names, isNot(contains('gitee')),
          reason: 'ADDRESS_BOOTSTRAP_GITEE 默认空 = 未配置，不该产生一个必然 404 的源');
      expect(names.first, 'self-hosted', reason: '自托管是"不需要第三方账号"的那条腿，未配 Gitee 时排第一');
      expect(names, contains('jsdelivr'));
      expect(names.last, 'github-raw', reason: 'GitHub raw 保留但必须垫底（实测 http=000 不可达）');
      expect(
        sources.where((AddressBootstrapSource s) => s.name == 'self-hosted').first.url,
        'https://builtin.example.com/site/client-config.json',
        reason: '自托管 URL = <候选根>/site/client-config.json（服务端把 site/ 挂在 /site）',
      );
    });

    test('显式钉死 ADDRESS_BOOTSTRAP 时只用它（保持 pin 语义，不被多源稀释）', () async {
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('override', 'https://pinned.example.com/client-config.json'),
      ];
      final List<AddressBootstrapSource> sources = await AppAddressResolver.bootstrapSources();
      expect(sources.length, 1);
      expect(sources.single.name, 'override');
    });

    test('第一个源失败 → 自动下一个；命中源名被记录（source=X + bootstrapFrom）', () async {
      final List<String> tried = <String>[];
      AppAddressResolver.debugLog = tried.add;
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('gitee', 'https://gitee.example.com/raw/client-config.json'),
        const AddressBootstrapSource('self-hosted', 'https://self.example.com/site/client-config.json'),
        const AddressBootstrapSource('github-raw', 'https://raw.example.com/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async {
        if (url.contains('gitee')) {
          throw const SocketException('测试：Gitee 不可达');
        }
        if (url.contains('self')) {
          return '{"api":"https://self.example.com"}';
        }
        throw StateError('不该走到 github-raw：第二个源就应该命中');
      };
      AppAddressResolver.debugFetchHealth = (String api) async => 17;

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isTrue);
      expect(r.address.apiBaseUrl, 'https://self.example.com/api/v1');
      expect(r.address.bootstrapFrom, 'self-hosted',
          reason: '必须能说清"这次到底是从哪条腿拿到的地址"');
      expect(r.address.source, 'bootstrap+probe');
      expect(r.address.latencyMs, 17);
      expect(AppConfig.apiBase, 'https://self.example.com/api/v1');
      expect(AppConfigRuntime.bootstrapFrom, 'self-hosted');
      // 失败的那条必须留下日志（可观测性）
      expect(tried.any((String s) => s.contains('引导源失败：gitee')), isTrue,
          reason: '失败原因要写日志，否则线上只能看到"用了内置地址"，查不出为什么');
      expect(tried.any((String s) => s.contains('引导源命中：self-hosted')), isTrue);
    });

    test('全部源都返回坏 JSON → 逐个试完，回退内置且原因里列出每一条源', () async {
      final List<String> tried = <String>[];
      AppAddressResolver.debugLog = tried.add;
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('gitee', 'https://gitee.example.com/c.json'),
        const AddressBootstrapSource('jsdelivr', 'https://cdn.example.com/c.json'),
        const AddressBootstrapSource('github-raw', 'https://raw.example.com/c.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async => '<html>404</html>';

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isFalse);
      expect(r.error, contains('下发不可用'));
      // 三条源都要被真的试过（不能"第一个失败就放弃"）
      for (final String name in <String>['gitee', 'jsdelivr', 'github-raw']) {
        expect(r.error, contains(name), reason: '$name 的失败原因必须出现在回退原因里');
      }
      expect(tried.where((String s) => s.contains('引导源失败')).length, 3);
    });

    test('自托管族（多个 host）并行竞争：慢的不用等，先答应的胜', () async {
      final Stopwatch sw = Stopwatch()..start();
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://hostA.example.com/site/client-config.json',
            parallel: true),
        const AddressBootstrapSource('self-hosted', 'https://hostB.example.com/site/client-config.json',
            parallel: true),
        const AddressBootstrapSource('self-hosted', 'https://hostC.example.com/site/client-config.json',
            parallel: true),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async {
        if (url.contains('hostB')) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return '{"api":"https://hostB.example.com"}';
        }
        // A/C 都是"慢死"：会挂满超时
        await Future<void>.delayed(const Duration(seconds: 30));
        throw const SocketException('测试：慢死');
      };
      AppAddressResolver.debugFetchHealth = (String api) async => 9;

      final AddressResolution r = await AppAddressResolver.resolve();
      sw.stop();

      expect(r.address.apiBaseUrl, 'https://hostB.example.com/api/v1');
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '并行族：总耗时 ≈ 最快那条，不是三条串行累加');
    });

    test('引导源总预算用尽 → 停止尝试剩余源（不让冷启动无限等）', () async {
      final List<String> tried = <String>[];
      AppAddressResolver.debugLog = tried.add;
      // 4 条源、每条都挂满单源超时（3.5s）→ 8s 总预算在第 3 条之后用尽，第 4 条必须被跳过
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('gitee', 'https://gitee.example.com/c.json'),
        const AddressBootstrapSource('jsdelivr', 'https://cdn.example.com/c.json'),
        const AddressBootstrapSource('github-raw', 'https://raw.example.com/c.json'),
        const AddressBootstrapSource('override', 'https://never-tried.example.com/c.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        throw const SocketException('测试：超预算');
      };
      AppAddressResolver.debugBuiltinCandidates = <String>['http://127.0.0.1:1/api/v1'];

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isFalse);
      expect(tried.any((String s) => s.contains('总预算用尽')), isTrue,
          reason: '预算用尽要留下日志（排查"为什么没用上第三条源"）');
      expect(tried.any((String s) => s.contains('never-tried')), isFalse,
          reason: '预算用尽后不该再去试后面的源');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ==========================================================================
  // ② 全部候选不可达：不死循环、退避且有上限
  // ==========================================================================
  group('② 全部不可达时的退避与上限', () {
    test('退避指数增长且封顶（5s→10s→20s…上限 5min）', () {
      final AddressWatchdog w = AddressWatchdog.instance;
      w.baseBackoff = const Duration(seconds: 5);
      w.maxBackoff = const Duration(minutes: 5);

      final List<int> secs = <int>[
        for (int attempt = 1; attempt <= 8; attempt++)
          w.debugBackoffFor(attempt).inSeconds,
      ];
      expect(secs, <int>[5, 10, 20, 40, 80, 160, 300, 300],
          reason: '指数退避 + 封顶 5 分钟（300s 之后不再增长，杜绝"越失败等越久到天荒地老"）');
    });

    test('全部候选不可达：重取次数撞上限后彻底停手（不死循环、不疯狂重试）', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      w.maxRefreshes = 3;
      w.baseBackoff = const Duration(seconds: 5);
      w.onRefreshed = null;

      final List<Duration> delays = <Duration>[];
      final List<void Function()> fires = <void Function()>[];
      w.debugSchedule = (Duration d, void Function() f) {
        delays.add(d);
        fires.add(f);
      };
      // 重取永远失败（什么都解析不出来 → 地址不变）
      AppAddressResolver.debugBuiltinCandidates = <String>[kDeadApi];
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('gitee', 'https://gitee.example.com/c.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async =>
          throw const SocketException('测试：全部不可达');
      AppAddressResolver.debugFetchHealth = (String api) async => null;

      // 连续失败（每次失败都重新计数：noteFailure 达到阈值就排一次重取）
      for (int i = 0; i < 20; i++) {
        w.noteFailure('测试失败 $i');
        if (fires.isNotEmpty) {
          final void Function() f = fires.removeAt(0);
          f();
          await _until(() => !w.refreshing);
        }
      }

      expect(w.refreshCount, 3, reason: '重取次数必须撞到上限就停（maxRefreshes=3）');
      expect(w.exhausted, isTrue);
      expect(delays.length, 3, reason: '只排了 3 次退避，之后不再排');
      expect(delays.map((Duration d) => d.inSeconds).toList(), <int>[5, 10, 20],
          reason: '每次重取前都真的退避了（不是立刻打）');
      // 再失败也不会排新的重取
      for (int i = 0; i < 10; i++) {
        w.noteFailure('上限之后的失败 $i');
      }
      expect(delays.length, 3, reason: '上限之后绝不再自动重取');
    });

    test('地址真的切换成功后重取预算回满（自愈成功 ≠ 永久吃掉额度）', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      w.maxRefreshes = 1;
      w.debugSchedule = (Duration d, void Function() f) => f();

      AppConfigRuntime.apply(
        api: 'https://old.example.com/api/v1',
        ws: 'https://old.example.com',
        from: 'bootstrap+probe',
      );
      AddressResolution ok() => const AddressResolution(
            address: ResolvedAddress(
              apiBaseUrl: 'https://new.example.com/api/v1',
              wsBaseUrl: 'https://new.example.com',
              source: 'bootstrap+probe',
              bootstrapFrom: 'self-hosted',
            ),
            fromBootstrap: true,
            probed: true,
          );
      w.debugResolve = () async {
        AppConfigRuntime.apply(
          api: 'https://new.example.com/api/v1',
          ws: 'https://new.example.com',
          from: 'bootstrap+probe',
          bootstrapFrom: 'self-hosted',
        );
        return ok();
      };

      w.noteFailure('a');
      w.noteFailure('b');
      w.noteFailure('c');
      await _until(() => !w.refreshing && AppConfig.apiBase.contains('new'));

      expect(AppConfig.apiBase, 'https://new.example.com/api/v1');
      expect(AppConfigRuntime.switchCount, 1);
      expect(w.refreshCount, 0, reason: '真切换成功 = 自愈成功 → 预算回满');
      expect(w.exhausted, isFalse);
    });

    test('启动解析失败（回退内置）会排一次重取', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      final List<Duration> delays = <Duration>[];
      w.debugSchedule = (Duration d, void Function() _) => delays.add(d);

      w.noteStartup(const AddressResolution(
        address: ResolvedAddress(
          apiBaseUrl: 'http://10.0.2.2:3100/api/v1',
          wsBaseUrl: 'http://10.0.2.2:3100',
          source: 'builtin',
        ),
        fromBootstrap: false,
        probed: false,
        error: '下发不可用：gitee:SocketException | github-raw:HttpException',
      ));

      expect(delays.length, 1, reason: '启动就没拿到下发地址 → 必须排一次重取');
      expect(delays.single.inSeconds, 5);
    });

    test('启动解析成功时不排重取（不做无谓的自愈）', () {
      final AddressWatchdog w = AddressWatchdog.instance;
      final List<Duration> delays = <Duration>[];
      w.debugSchedule = (Duration d, void Function() _) => delays.add(d);

      w.noteStartup(const AddressResolution(
        address: ResolvedAddress(
          apiBaseUrl: 'https://ok.example.com/api/v1',
          wsBaseUrl: 'https://ok.example.com',
          source: 'bootstrap+probe',
        ),
        fromBootstrap: true,
        probed: true,
      ));

      expect(delays, isEmpty);
    });
  });

  // ==========================================================================
  // ③ 运行中切换：base 失败 → 自动重取 → 切到健康候选
  // ==========================================================================
  group('③ 运行中失败 → 自动重取 → 热切换', () {
    test('真 ApiClient（切换前构造）后续请求打到新地址；旧地址缓存不串味；WS base 同步变', () async {
      final _RecordingStub live = await _RecordingStub.start(
        '{"code":0,"message":"ok","data":"from-live-stub"}',
      );
      final AddressWatchdog w = AddressWatchdog.instance;
      w.baseBackoff = const Duration(seconds: 5);
      final List<Duration> delays = <Duration>[];
      final List<void Function()> fires = <void Function()>[];
      w.debugSchedule = (Duration d, void Function() f) {
        delays.add(d);
        fires.add(f);
      };

      // 起手：地址是"必死"的（模拟 ngrok 403/隧道换域名后的旧地址）
      AppConfigRuntime.apply(api: kDeadApi, ws: 'http://127.0.0.1:1', from: 'bootstrap+probe');

      // 关键顺序：ApiClient 在**切换之前**构造 —— 若地址没真的热切换，它只会打旧地址
      final ApiClient api = ApiClient();

      // 旧地址的缓存里塞一条"诱饵"：热切换后若还命中它，就是串味
      final String staleKey =
          ApiCache.instance.keyOf('/divisions', null, apiBase: kDeadApi);
      ApiCache.instance.put(staleKey, <String, dynamic>{'code': 0, 'data': 'STALE-FROM-OLD-ADDRESS'});

      // 引导源：自托管（真 HTTP，指向活着的 stub）
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        AddressBootstrapSource(
            'self-hosted', '${live.base}/site/client-config.json', parallel: true),
      ];
      final List<String> askedBootstrapUrls = <String>[];
      AppAddressResolver.debugFetchBootstrap = (String url) async {
        askedBootstrapUrls.add(url);
        return jsonEncode(<String, dynamic>{
          'api': '${live.base}/api/v1',
          'ws': live.base,
          'candidates': <String>['${live.base}/api/v1', 'https://other-dead.example.com/api/v1'],
        });
      };
      AppAddressResolver.debugFetchHealth = (String api) async =>
          api.startsWith(live.base) ? 12 : null;

      AddressResolution? switched;
      w.onRefreshed = (AddressResolution r) => switched = r;
      w.install();

      try {
        // --- 3 次真实请求失败（端口 1，连接被立即拒绝）---
        for (int i = 0; i < 3; i++) {
          await expectLater(
            api.request('POST', '/touch'),
            throwsA(isA<ApiException>()),
            reason: '第 ${i + 1} 次请求应当真的失败（旧地址已死）',
          );
        }
        expect(w.consecutiveFailures, 3, reason: 'ApiClient 的网络失败必须真的报给看门狗');
        expect(delays.length, 1, reason: '达到阈值 → 排一次带退避的重取');
        expect(delays.single.inSeconds, 5);
        expect(fires.length, 1);

        // --- 退避到点 → 自动重取（多源 bootstrap + 探活 + 热切换）---
        fires.removeAt(0)();
        await _until(() => !w.refreshing && AppConfig.apiBase.startsWith(live.base));

        // 1) AppConfig 真的换了
        expect(AppConfig.apiBase, '${live.base}/api/v1');
        expect(AppConfig.wsBase, live.base, reason: 'ws 也跟着换（取下发里显式声明的 ws）');
        // 2) 切换事件被上报（main.dart 用它 rebind WS）
        expect(switched, isNotNull, reason: 'onRefreshed 必须被调用一次，否则 WS 还连着旧地址');
        expect(switched!.address.apiBaseUrl, '${live.base}/api/v1');
        expect(AppConfigRuntime.switchCount, 1);
        expect(w.consecutiveFailures, 0, reason: '重取完成后计数归零');

        // 3) **同一个**（切换前构造的）ApiClient 后续请求真的打到了新地址
        final Map<String, dynamic> resp = await api.request('GET', '/divisions');
        expect(resp['data'], 'from-live-stub',
            reason: '拿到的必须是新服务器的新数据，不是旧地址的缓存诱饵');
        expect(live.paths, contains('/api/v1/divisions'),
            reason: '请求必须真的到达新地址（新服务器收到了这条路径）');
        expect(askedBootstrapUrls, <String>['${live.base}/site/client-config.json'],
            reason: '重取时走的必须是"服务端自托管"那条腿（不需要任何第三方账号）');

        // 4) 旧地址的缓存不串味：键本身带 apiBase，新旧键必然不同
        expect(
          ApiCache.instance.keyOf('/divisions', null, apiBase: kDeadApi),
          isNot(ApiCache.instance.keyOf('/divisions', null, apiBase: '${live.base}/api/v1')),
          reason: '缓存键含地址维度 → 换址后旧缓存不可能被命中',
        );
        expect(ApiCache.instance.get(staleKey, const Duration(days: 1)), isNull,
            reason: '重取会清空缓存（旧地址的诱饵条目必须没了）');

        // 5) WS：连接时真正会用的地址跟着 AppConfig 走（socket.io 自动重连只会重连旧 URL，
        //    所以 main.dart 在 onRefreshed 里调 RealtimeClient.shared.rebind()）
        final RealtimeClient ws = RealtimeClient();
        expect(ws.debugWsBaseUrl, live.base);
        ws.rebind(); // 从未连接过 → 必须是安全 no-op（不抛、不建连）
        expect(ws.connected, isFalse);
        expect(AddressWatchdog.instance.installed, isTrue);
      } finally {
        await live.stop();
      }
    });

    test('WS 首次连不上 = 严重信号：不等累计阈值，立刻排一次重取', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      final List<Duration> delays = <Duration>[];
      w.debugSchedule = (Duration d, void Function() _) => delays.add(d);
      w.install();

      RealtimeClient.onConnectFailed!();

      expect(delays.length, 1);
      expect(w.consecutiveFailures, w.failureThreshold);
    });

    test('服务端答话（4xx/5xx）不算地址失效 —— 看门狗不该被业务错误触发', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      final List<Duration> delays = <Duration>[];
      w.debugSchedule = (Duration d, void Function() _) => delays.add(d);
      w.install();

      final _FakeApiAdapter adapter = _FakeApiAdapter(
        statusCode: 400,
        body: '{"code":400,"message":"参数错误","data":null}',
      );
      final Dio dio = Dio(BaseOptions(baseUrl: 'https://live.example.com/api/v1'))
        ..httpClientAdapter = adapter;
      final ApiClient api = ApiClient(dio: dio);

      for (int i = 0; i < 6; i++) {
        await expectLater(api.request('POST', '/x'), throwsA(isA<ApiException>()));
      }

      expect(w.consecutiveFailures, 0,
          reason: '400 说明服务器活着（地址没失效）→ 绝不能触发换址');
      expect(delays, isEmpty);
    });

    test('一次成功请求把连续失败计数清零（避免"零星失败"累积成误切换）', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      final List<Duration> delays = <Duration>[];
      w.debugSchedule = (Duration d, void Function() _) => delays.add(d);
      w.install();

      w.noteFailure('a');
      w.noteFailure('b');
      expect(w.consecutiveFailures, 2);
      w.noteSuccess();
      expect(w.consecutiveFailures, 0);
      w.noteFailure('c');
      w.noteFailure('d');
      expect(w.consecutiveFailures, 2);
      expect(delays, isEmpty, reason: '中间成功过 → 不算"连续"失败，不该排重取');
    });

    test('refresh 并发去重：同一时刻只跑一次', () async {
      final AddressWatchdog w = AddressWatchdog.instance;
      int calls = 0;
      final Completer<void> gate = Completer<void>();
      w.debugResolve = () async {
        calls += 1;
        await gate.future;
        return const AddressResolution(
          address: ResolvedAddress(
            apiBaseUrl: 'https://x.example.com/api/v1',
            wsBaseUrl: 'https://x.example.com',
            source: 'bootstrap+probe',
          ),
          fromBootstrap: true,
          probed: true,
        );
      };

      final Future<AddressResolution?> first = w.refresh(reason: '第一次');
      final Future<AddressResolution?> second = w.refresh(reason: '第二次');
      gate.complete();
      await Future.wait(<Future<AddressResolution?>>[first, second]);

      expect(calls, 1, reason: '并发调用只应真正解析一次');
      expect(w.refreshCount, 1);
    });
  });

  // ==========================================================================
  // ④ 内置多候选并行探活取最快
  // ==========================================================================
  group('④ 内置多候选并行探活', () {
    test('引导源全挂 → 内置候选并行探活，最快者胜（慢的不用等）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[
        'https://dead-ngrok.example.com/api/v1',
        'https://fast-cf.example.com/api/v1',
        'http://192.168.1.145:3100/api/v1',
      ];
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('gitee', 'https://gitee.example.com/c.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async =>
          throw const SocketException('测试：引导站全挂');
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api.contains('dead-ngrok')) return null; // 403 → 探活判不可用
        if (api.contains('fast-cf')) return 88;
        await Future<void>.delayed(const Duration(seconds: 30)); // LAN 慢死
        return null;
      };

      final Stopwatch sw = Stopwatch()..start();
      final AddressResolution r = await AppAddressResolver.resolve();
      sw.stop();

      expect(r.fromBootstrap, isFalse);
      expect(r.address.source, 'builtin+probe');
      expect(r.address.apiBaseUrl, 'https://fast-cf.example.com/api/v1');
      expect(r.address.latencyMs, 88);
      expect(r.address.wsBaseUrl, 'https://fast-cf.example.com',
          reason: '内置候选顶上时 ws 必须由该候选派生（不能沿用死掉的 ws）');
      expect(r.error, contains('下发不可用'));
      expect(sw.elapsedMilliseconds, lessThan(3500),
          reason: '并行探活：总耗时 ≈ 最快那条，不是三条累加');
    });

    test('内置候选全不可达 → 落到打包内置首选地址，且不死等', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[
        'https://a.example.com/api/v1',
        'https://b.example.com/api/v1',
      ];
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('gitee', 'https://gitee.example.com/c.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async =>
          throw const SocketException('测试：引导站全挂');
      AppAddressResolver.debugFetchHealth = (String api) async => null;

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.address.source, 'builtin');
      expect(r.address.apiBaseUrl, AppAddressResolver.builtinApiBase);
      expect(r.probed, isTrue, reason: '确实探过活（只是全部失败）');
    });

    test('下发候选全挂但内置候选活着 → 用内置候选顶上（不硬用一个已死的下发地址）', () async {
      AppAddressResolver.debugBuiltinCandidates = <String>[
        'http://127.0.0.1:1/api/v1',
        'https://alive-cf.example.com/api/v1',
      ];
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://self.example.com/site/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async =>
          '{"api":"https://stale-ngrok.example.com","candidates":["https://stale-ngrok.example.com"]}';
      AppAddressResolver.debugFetchHealth = (String api) async =>
          api.contains('alive-cf') ? 41 : null;

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isTrue, reason: '下发本身是拿到的（只是内容过期）');
      expect(r.address.source, 'bootstrap+builtin');
      expect(r.address.apiBaseUrl, 'https://alive-cf.example.com/api/v1');
      expect(r.address.latencyMs, 41);
      expect(r.address.wsBaseUrl, 'https://alive-cf.example.com');
      expect(r.error, contains('内置候选'));
    });

    test('内置候选清单：API_BASE_URL 打头、额外候选去重后保序', () {
      AppAddressResolver.debugBuiltinCandidates = null;
      final List<String> list = AppAddressResolver.builtinCandidates;
      expect(list.first, AppAddressResolver.builtinApiBase);
      expect(list.toSet().length, list.length, reason: '必须去重');
    });
  });

  // ==========================================================================
  // ⑤ ADDRESS_BOOTSTRAP_ENABLED=false：行为完全不变（离线包/调试用）
  // ==========================================================================
  group('⑤ 下发开关关闭时行为不变', () {
    test('关闭时不下发、不探活，直接用打包内置地址', () async {
      AppAddressResolver.debugEnabledOverride = false;
      bool fetched = false;
      bool probed = false;
      AppAddressResolver.debugFetchBootstrap = (String url) async {
        fetched = true;
        return '{"api":"https://should-not-be-used.example.com"}';
      };
      AppAddressResolver.debugFetchHealth = (String api) async {
        probed = true;
        return 5;
      };
      AppAddressResolver.debugBuiltinCandidates = <String>[
        'https://a.example.com/api/v1',
        'https://b.example.com/api/v1',
      ];

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(fetched, isFalse, reason: '关闭下发 → 一次网络都不该发');
      expect(probed, isFalse, reason: '关闭下发 → 连探活都不做（离线包场景）');
      expect(r.fromBootstrap, isFalse);
      expect(r.probed, isFalse);
      expect(r.address.source, 'builtin');
      expect(r.address.apiBaseUrl, AppAddressResolver.builtinApiBase);
      expect(r.address.wsBaseUrl, AppAddressResolver.builtinWsBase);
      expect(AppConfig.apiBase, AppAddressResolver.builtinApiBase);
      expect(AppConfig.wsBase, AppAddressResolver.builtinWsBase);
      expect(AppConfig.usingDispatchedAddress, isTrue, reason: '内置也算"已解析"（source=builtin）');
      expect(r.error, isNull, reason: '关闭是主动选择，不是失败，不该报错');
    });

    test('关闭时看门狗也不会把地址改掉（离线包不被自愈流程打扰）', () async {
      AppAddressResolver.debugEnabledOverride = false;
      final AddressWatchdog w = AddressWatchdog.instance;
      final List<void Function()> fires = <void Function()>[];
      w.debugSchedule = (Duration d, void Function() f) => fires.add(f);

      await AppAddressResolver.resolve();
      expect(AppConfig.apiBase, AppAddressResolver.builtinApiBase);

      w.debugResolve = AppAddressResolver.resolve;
      w.noteFailure('a');
      w.noteFailure('b');
      w.noteFailure('c');
      expect(fires.length, 1);
      fires.removeAt(0)();
      await _until(() => !w.refreshing);

      expect(AppConfig.apiBase, AppAddressResolver.builtinApiBase,
          reason: '开关关闭时重取也只能得到内置地址，地址不会漂');
      expect(w.refreshCount, 1, reason: '地址没变 → 不算自愈成功 → 预算不重置（连续不可达会累积到上限）');
      expect(w.exhausted, isFalse);
      expect(w.consecutiveFailures, 0, reason: '重取跑完就归零，重新按阈值计数');
    });
  });

  // ==========================================================================
  // 附加：自托管引导的"已知入口"持久化（不需要第三方账号的那条腿）
  // ==========================================================================
  group('自托管引导的已知入口', () {
    test('本机记住的上次可用地址排在打包内置候选之前，且 URL 是 <根>/site/client-config.json', () async {
      AppAddressResolver.loadLastKnownGood = () async => 'https://last-good.trycloudflare.com/api/v1';
      AppAddressResolver.debugBuiltinCandidates = <String>['https://builtin.example.com/api/v1'];

      final List<String> hosts = await AppAddressResolver.bootstrapHostCandidates();
      expect(hosts.first, 'https://last-good.trycloudflare.com/api/v1');
      expect(hosts, contains('https://builtin.example.com/api/v1'));

      final List<AddressBootstrapSource> sources = await AppAddressResolver.bootstrapSources();
      final List<String> selfHosted = sources
          .where((AddressBootstrapSource s) => s.name == 'self-hosted')
          .map((AddressBootstrapSource s) => s.url)
          .toList();
      expect(selfHosted.first, 'https://last-good.trycloudflare.com/site/client-config.json');
      expect(selfHosted, contains('https://builtin.example.com/site/client-config.json'));
    });

    test('读"上次可用地址"失败/超时 → 完全不影响解析（只是少一条入口）', () async {
      AppAddressResolver.loadLastKnownGood = () async =>
          throw StateError('测试：安全存储不可用');
      AppAddressResolver.debugBuiltinCandidates = <String>['https://builtin.example.com/api/v1'];

      final List<String> hosts = await AppAddressResolver.bootstrapHostCandidates();
      expect(hosts, <String>['https://builtin.example.com/api/v1']);
    });

    test('解析成功后把生效地址写回本机（下次冷启动的自托管入口）', () async {
      String? saved;
      AppAddressResolver.saveLastKnownGood = (String api) async => saved = api;
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://s.example.com/site/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async => '{"api":"https://s.example.com"}';
      AppAddressResolver.debugFetchHealth = (String api) async => 11;

      await AppAddressResolver.resolve();
      await _until(() => saved != null);
      expect(saved, 'https://s.example.com/api/v1');
    });
  });

  // ==========================================================================
  // 附加：preferred（"固定域名活着就用它"，2026-10-06 发布链配套）
  //
  // 为什么需要：Quick Tunnel 域名**每次重启都会变**，ngrok 固定域名不变。
  // 只按"最快者胜"会把今天恰好更快的临时隧道选成主入口，隧道一重启又得重来。
  // ==========================================================================
  group('preferred：固定域名优先', () {
    test('preferred 探活通过 → 即使比别的候选慢也用它（source=bootstrap+preferred）', () async {
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://s.example.com/site/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async => jsonEncode(<String, dynamic>{
            'api': 'https://temporary.trycloudflare.com',
            'preferred': 'https://<your-tunnel-domain>',
            'candidates': <String>[
              'https://temporary.trycloudflare.com',
              'https://<your-tunnel-domain>',
            ],
          });
      AppAddressResolver.debugFetchHealth = (String api) async {
        if (api.contains('ngrok-free')) return 900; // 固定域名慢
        return 20; // 临时隧道快
      };

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.address.apiBaseUrl, 'https://<your-tunnel-domain>/api/v1',
          reason: '固定域名活着就该当主入口（临时域名重启就变，不该被"今天更快"顶上来）');
      expect(r.address.source, 'bootstrap+preferred');
      expect(r.address.latencyMs, 900);
      expect(r.address.wsBaseUrl, 'https://<your-tunnel-domain>',
          reason: '未显式给 ws 时由选中的 api 派生');
    });

    test('preferred 死掉（ngrok 额度耗尽 403）→ 退回最快者胜，切换到临时隧道', () async {
      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://s.example.com/site/client-config.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async => jsonEncode(<String, dynamic>{
            'api': 'https://temporary.trycloudflare.com',
            'preferred': 'https://<your-tunnel-domain>',
            'candidates': <String>[
              'https://temporary.trycloudflare.com',
              'https://<your-tunnel-domain>',
            ],
          });
      AppAddressResolver.debugFetchHealth = (String api) async =>
          api.contains('ngrok-free') ? null : 33; // 403/限流 → 探活判不可用

      final AddressResolution r = await AppAddressResolver.resolve();

      expect(r.address.apiBaseUrl, 'https://temporary.trycloudflare.com/api/v1',
          reason: 'preferred 不可用 = 当没写，退回最快者胜（而不是硬用一个死地址）');
      expect(r.address.source, 'bootstrap+probe');
      expect(r.address.latencyMs, 33);
    });

    test('preferred 不在 candidates 里 → 忽略该字段（防止下发写了个没人探过的地址）', () async {
      final AddressBootstrap cfg = AddressBootstrap.parse(jsonEncode(<String, dynamic>{
        'api': 'https://a.example.com',
        'preferred': 'https://not-in-candidates.example.com',
        'candidates': <String>['https://a.example.com', 'https://b.example.com'],
      }));
      expect(cfg.preferred, isNull);
      expect(cfg.candidates.length, 2);
    });

    test('老 JSON 没有 preferred 字段 → 行为逐字不变（纯新增，向后兼容）', () async {
      final AddressBootstrap cfg = AddressBootstrap.parse(
          '{"api":"https://a.example.com","candidates":["https://a.example.com","https://b.example.com"]}');
      expect(cfg.preferred, isNull);

      AppAddressResolver.debugBootstrapSources = <AddressBootstrapSource>[
        const AddressBootstrapSource('self-hosted', 'https://s.example.com/c.json'),
      ];
      AppAddressResolver.debugFetchBootstrap = (String url) async =>
          '{"api":"https://a.example.com","candidates":["https://a.example.com","https://b.example.com"]}';
      AppAddressResolver.debugFetchHealth = (String api) async =>
          api.contains('b.example') ? 10 : 200;

      final AddressResolution r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, 'https://b.example.com/api/v1',
          reason: '没有 preferred → 仍然纯粹最快者胜');
      expect(r.address.source, 'bootstrap+probe');
    });
  });

  // ==========================================================================
  // 附加：诊断行（「我的 → 设置」展示 + 用户报障截图）
  // ==========================================================================
  group('诊断行（当前服务器地址）', () {
    test('展示主机 + **地址类别** + 来源 + 引导源 + 延迟 + 候选数 + 切换次数', () {
      AppConfigRuntime.apply(
        api: 'https://<your-tunnel-domain>/api/v1',
        ws: 'https://<your-tunnel-domain>',
        from: 'bootstrap+probe',
        bootstrapFrom: 'self-hosted',
        latencyMs: 123,
        candidateCount: 3,
      );
      AppConfigRuntime.noteSwitch(DateTime.now());

      final String line = AppConfig.serverAddressLine;
      // 【2026-10-06 局域网优先专项】行内新增"地址类别"一格（`LAN` / `隧道` / …）：
      // 上传卡不卡，先看这一格。主机仍必须完整（含 scheme），只是后面多了类别。
      expect(line, startsWith('https://<your-tunnel-domain> · 隧道 · bootstrap+probe'),
          reason: '主机要完整（含 scheme）+ 类别要写明（ngrok 固定域名 = 隧道）');
      expect(line, contains('(self-hosted)'));
      expect(line, contains('123ms'));
      expect(line, contains('候选3'));
      expect(line, contains('已切换1次'));
      expect(line, isNot(contains('/api/v1')),
          reason: '「当前服务器地址」这一行不该带接口前缀噪音');
    });

    test('局域网地址在诊断行里标成 LAN（同一 WiFi 快百倍的那条路）', () {
      AppConfigRuntime.apply(
        api: 'http://192.168.1.145:3100/api/v1',
        ws: 'http://192.168.1.145:3100',
        from: 'lan',
        latencyMs: 9,
      );
      final String line = AppConfig.serverAddressLine;
      expect(line, startsWith('http://192.168.1.145:3100 · LAN · lan'),
          reason: '报障时一眼能看出"当前走的是局域网直连"');
      expect(line, contains('9ms'));
    });

    test('未解析时显示"未解析"（不崩、不空白）', () {
      expect(AppConfig.serverAddressLine, contains('未解析'));
    });
  });
}

/// 一个指定状态码 + 指定正文的假适配器（模拟"服务器活着但拒绝"）
class _FakeApiAdapter implements HttpClientAdapter {
  _FakeApiAdapter({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        body,
        statusCode,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
