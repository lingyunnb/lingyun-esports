/// 服务地址动态下发测试（2026-10-04）
///
/// 覆盖负责人要求的三条：
///   1) 下发地址优先（有下发就用下发，且写回 AppConfig）
///   2) 解析失败回退内置（坏 JSON / 拉取失败 / 探测全失败都不崩）
///   3) 多候选并行探活取最快
///
/// 2026-10-04 追加（ngrok 固定域名上线）：
///   4) 请求统一带 `ngrok-skip-browser-warning` + 非浏览器 UA（防警示插页假 200）
///   5) 探活不再"只看状态码"：插页（200 + HTML）必须判为不可用
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_http.dart';

void main() {
  setUp(() {
    AppConfigRuntime.reset();
    AppAddressResolver.debugFetchBootstrap = null;
    AppAddressResolver.debugFetchHealth = null;
  });

  tearDown(() {
    AppConfigRuntime.reset();
    AppAddressResolver.debugFetchBootstrap = null;
    AppAddressResolver.debugFetchHealth = null;
  });

  group('地址规范化', () {
    test('补 /api/v1 前缀并去尾斜杠', () {
      expect(AppAddressResolver.normalizeApiBase('https://a.example.com'),
          'https://a.example.com/api/v1');
      expect(AppAddressResolver.normalizeApiBase('https://a.example.com/'),
          'https://a.example.com/api/v1');
      expect(AppAddressResolver.normalizeApiBase('https://a.example.com/api/v1/'),
          'https://a.example.com/api/v1');
      expect(AppAddressResolver.normalizeApiBase('http://192.168.1.145:3100'),
          'http://192.168.1.145:3100/api/v1');
      expect(AppAddressResolver.normalizeApiBase('a.example.com'), 'https://a.example.com/api/v1');
      expect(AppAddressResolver.normalizeApiBase('   '), '');
    });

    test('ws 地址去掉 /api/v1 后缀', () {
      expect(AppAddressResolver.normalizeWsBase('https://a.example.com/api/v1'),
          'https://a.example.com');
      expect(AppAddressResolver.normalizeWsBase('https://a.example.com/'), 'https://a.example.com');
      expect(AppAddressResolver.normalizeWsBase('http://192.168.1.145:3100'),
          'http://192.168.1.145:3100');
    });
  });

  group('下发 JSON 解析', () {
    test('api 单条 + ws 派生 + updatedAt', () {
      final cfg = AddressBootstrap.parse(
          '{"api":"https://t.example.com","updatedAt":"2026-10-04T00:00:00Z"}');
      expect(cfg.apiBaseUrl, 'https://t.example.com/api/v1');
      expect(cfg.candidates, ['https://t.example.com/api/v1']);
      expect(cfg.wsBaseUrl, isNull, reason: '未显式给 ws 时由 api 派生');
      expect(cfg.updatedAt, '2026-10-04T00:00:00Z');
    });

    test('candidates 支持字符串与对象混排，去重且保序', () {
      final cfg = AddressBootstrap.parse('{"api":"https://a.example.com","candidates":'
          '["https://a.example.com/","http://192.168.1.145:3100",'
          '{"api":"https://b.example.com/api/v1"}]}');
      expect(cfg.candidates, [
        'https://a.example.com/api/v1',
        'http://192.168.1.145:3100/api/v1',
        'https://b.example.com/api/v1',
      ]);
      expect(cfg.apiBaseUrl, 'https://a.example.com/api/v1', reason: '首个候选即主地址');
    });

    test('显式 ws 优先于派生', () {
      final cfg = AddressBootstrap.parse(
          '{"api":"https://a.example.com","ws":"wss://ws.example.com/"}');
      expect(cfg.wsBaseUrl, 'wss://ws.example.com');
    });

    test('坏 JSON / 空候选 / 非对象 一律 FormatException（由调用方回退）', () {
      expect(() => AddressBootstrap.parse('not json'), throwsFormatException);
      expect(() => AddressBootstrap.parse('[]'), throwsFormatException);
      expect(() => AddressBootstrap.parse('{}'), throwsFormatException);
      expect(() => AddressBootstrap.parse('{"candidates":[]}'), throwsFormatException);
    });
  });

  group('下发优先 / 回退内置', () {
    test('拉取成功 → 用下发地址，写回 AppConfig', () async {
      AppAddressResolver.debugFetchBootstrap =
          (url) async => '{"api":"https://dispatch.example.com"}';
      AppAddressResolver.debugFetchHealth =
          (api) async => api.contains('dispatch') ? 42 : null;

      final r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isTrue);
      expect(r.address.apiBaseUrl, 'https://dispatch.example.com/api/v1');
      expect(r.address.wsBaseUrl, 'https://dispatch.example.com');
      expect(r.address.latencyMs, 42);
      expect(r.address.source, 'bootstrap+probe');
      expect(r.error, isNull);
      // 写回后 ApiClient()/RealtimeClient() 立即使用新地址（单一真相）
      expect(AppConfig.apiBase, 'https://dispatch.example.com/api/v1');
      expect(AppConfig.wsBase, 'https://dispatch.example.com');
      expect(AppConfig.usingDispatchedAddress, isTrue);
    });

    test('下发站不可达 → 回退打包内置地址，并给出原因', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async => throw const SocketExceptionStub();

      final r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isFalse);
      expect(r.address.source, 'builtin');
      expect(r.address.apiBaseUrl, AppAddressResolver.builtinApiBase);
      expect(r.address.wsBaseUrl, AppAddressResolver.builtinWsBase);
      expect(r.error, contains('下发不可用'));
      // 回退后 AppConfig 仍指向内置地址（App 起得来）
      expect(AppConfig.apiBase, AppAddressResolver.builtinApiBase);
    });

    test('下发内容不是合法 JSON → 回退内置', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async => '<html>404</html>';
      final r = await AppAddressResolver.resolve();
      expect(r.fromBootstrap, isFalse);
      expect(AppConfig.apiBase, AppAddressResolver.builtinApiBase);
    });

    test('候选全部探活失败 → 仍用首条下发地址（比过期内置地址新），并标注原因', () async {
      AppAddressResolver.debugFetchBootstrap =
          (url) async => '{"candidates":["https://dead1.example.com","https://dead2.example.com"]}';
      AppAddressResolver.debugFetchHealth = (api) async => null;

      final r = await AppAddressResolver.resolve();

      expect(r.fromBootstrap, isTrue);
      expect(r.probed, isTrue);
      expect(r.address.apiBaseUrl, 'https://dead1.example.com/api/v1');
      expect(r.address.latencyMs, isNull);
      expect(r.address.source, 'bootstrap');
      expect(r.error, contains('选择'));
    });

    test('单候选探活失败也算下发成功（不退回更旧的内置地址）', () async {
      AppAddressResolver.debugFetchBootstrap =
          (url) async => '{"api":"https://only.example.com"}';
      AppAddressResolver.debugFetchHealth = (api) async => null;
      final r = await AppAddressResolver.resolve();
      expect(r.fromBootstrap, isTrue);
      expect(AppConfig.apiBase, 'https://only.example.com/api/v1');
    });
  });

  group('多候选取最快', () {
    test('取延迟最低的候选，慢的丢弃', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async =>
          '{"candidates":["https://slow.example.com","https://fast.example.com","https://mid.example.com"]}';
      AppAddressResolver.debugFetchHealth = (api) async {
        if (api.contains('slow')) return 900;
        if (api.contains('fast')) return 30;
        if (api.contains('mid')) return 120;
        return null;
      };

      final r = await AppAddressResolver.resolve();

      expect(r.probed, isTrue);
      expect(r.address.apiBaseUrl, 'https://fast.example.com/api/v1');
      expect(r.address.latencyMs, 30);
      expect(r.address.wsBaseUrl, 'https://fast.example.com');
      expect(r.address.candidates.length, 3, reason: '候选清单留档便于排查');
    });

    test('不可达候选被跳过，可用候选即使慢也胜出', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async =>
          '{"candidates":["https://down.example.com","https://up.example.com"]}';
      AppAddressResolver.debugFetchHealth =
          (api) async => api.contains('up') ? 800 : null;

      final r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, 'https://up.example.com/api/v1');
      expect(r.address.latencyMs, 800);
    });

    test('并列延迟时取候选顺序靠前者（结果稳定）', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async =>
          '{"candidates":["https://first.example.com","https://second.example.com"]}';
      AppAddressResolver.debugFetchHealth = (api) async => 50;

      final r = await AppAddressResolver.resolve();
      expect(r.address.apiBaseUrl, 'https://first.example.com/api/v1');
    });

    test('候选（含死地址）互不阻塞：全部失败也能在下发超时上限内返回', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async =>
          '{"candidates":["https://h1.example.com","https://h2.example.com","https://h3.example.com"]}';
      AppAddressResolver.debugFetchHealth = (api) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return null;
      };

      final sw = Stopwatch()..start();
      final r = await AppAddressResolver.resolve();
      sw.stop();

      expect(r.fromBootstrap, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: '并行探活：总耗时约等于单条，不是三条累加');
    });
  });

  group('开发/离线开关', () {
    test('debugFetchHealth = null 的候选不会被写进 AppConfig（回退路径干净）', () async {
      AppAddressResolver.debugFetchBootstrap = (url) async => '{"api":"https://x.example.com"}';
      await AppAddressResolver.resolve();
      AppConfigRuntime.reset();
      expect(AppConfig.usingDispatchedAddress, isFalse);
      expect(AppConfig.addressSource, isNull);
    });

    test('RealtimeClient.shared 单例不会把地址钉死在"首次访问"那一刻', () {
      // 回归护栏：shared 是静态单例，若在构造时就固化 ws 地址，
      // 下发成功也永远连不上（本轮改成连接时惰性读取 AppConfig.wsBase）。
      final singleton = RealtimeClient.shared;
      AppConfigRuntime.apply(
        api: 'https://later.example.com/api/v1',
        ws: 'https://later.example.com',
        from: 'bootstrap+probe',
      );
      expect(AppConfig.wsBase, 'https://later.example.com');
      // 单例本身没有把地址存成字段，仍跟着 AppConfig 走
      expect(singleton.connected, isFalse, reason: '未连接时不建连（构造不触发网络）');
    });
  });

  // ==========================================================================
  // ngrok 免费档"浏览器警示插页"防护（2026-10-04 实测踩坑，详见 docs/11）
  //
  // 现象：ngrok 固定域名下，浏览器式请求（UA = Mozilla/...）拿到的是
  //       HTTP **200** + `text/html` 的"你即将访问 xxx"插页，正文不是 JSON。
  //       影响：① 只看状态码的探活会**假通过**；② 引导 JSON 解析失败 → 静默回退内置地址。
  // ==========================================================================
  group('ngrok 警示插页防护', () {
    test('探活请求带 ngrok-skip-browser-warning + 非浏览器 UA（真实 socket 抓包）', () async {
      final Map<String, String> sent = await captureRequestHeaders(
        (String base) => AppAddressResolver.fetchHealth('$base/api/v1'),
      );

      expect(sent[AppAddressResolver.ngrokSkipWarningHeader], 'true',
          reason: '没有这个头，ngrok 免费档会回插页而不是我们的 JSON');
      final String ua = sent['user-agent'] ?? '';
      expect(ua, isNotEmpty, reason: 'UA 必须存在且为非浏览器样式');
      expect(ua, isNot(contains('Mozilla')));
      expect(ua, isNot(contains('Chrome')));
      expect(ua.toLowerCase(), contains('dart'),
          reason: 'Dart HttpClient 系出站流量，ngrok 据此放行');
    });

    test('下发（bootstrap）拉取走同一个贴头实现 —— 引导 JSON 不能吃插页', () async {
      // resolve() 拉的 bootstrapUrl 是编译期常量（GitHub），测试里不便重定向，
      // 因此验证"唯一实现点"：下发用的 HttpClient 与探活共用 createHttpClient/applyCommonHeaders。
      final LocalStub stub = await startStubServer(
        body: '{"api":"https://stub.example.com"}',
      );
      try {
        final Map<String, String> sent = await captureRequestHeaders((String base) async {
          final client = AppAddressResolver.createHttpClient(
              const Duration(seconds: 3));
          try {
            final req = await client.getUrl(Uri.parse('$base/client-config.json'));
            AppAddressResolver.applyCommonHeaders(req);
            final res = await req.close();
            await res.drain<void>();
          } finally {
            client.close(force: true);
          }
        });
        expect(sent[AppAddressResolver.ngrokSkipWarningHeader], 'true',
            reason: '引导文件请求必须带 skip 头，否则拿到插页 → JSON 解析失败 → 静默回退内置');
        expect(sent['user-agent'], AppAddressResolver.appUserAgent);
        expect(sent['user-agent'], isNot(contains('Mozilla')));
      } finally {
        await stub.stop();
      }
    });

    test('200 + 插页 HTML → 探活判为不可用（不再只看状态码）', () async {
      final LocalStub stub = await startStubServer(
        statusCode: 200,
        contentType: 'text/html',
        body: '<!DOCTYPE html><html><body>You are about to visit '
            '<your-tunnel-domain>, served by ...</body></html>',
      );
      try {
        final int? ms = await AppAddressResolver.fetchHealth('${stub.base}/api/v1');
        expect(ms, isNull, reason: '插页是 200 但不是我们的 JSON → 必须视为不可用');
      } finally {
        await stub.stop();
      }
    });

    test('200 + 真 JSON → 探活可用（加固没有误杀正常后端）', () async {
      final LocalStub stub = await startStubServer(
        body: '{"code":0,"message":"ok","data":{"status":"ok",'
            '"services":{"database":"up","redis":"up"}}}',
      );
      try {
        final int? ms = await AppAddressResolver.fetchHealth('${stub.base}/api/v1');
        expect(ms, isNotNull, reason: '统一响应（code=0 + data.status）应判为可用');
      } finally {
        await stub.stop();
      }
    });

    test('isHealthBody：空体/非 JSON/缺 data.status/非 0 code 一律 false', () {
      expect(AppAddressResolver.isHealthBody(''), isFalse);
      expect(AppAddressResolver.isHealthBody('<html>插页</html>'), isFalse);
      expect(AppAddressResolver.isHealthBody('[]'), isFalse);
      expect(AppAddressResolver.isHealthBody('{"code":0}'), isFalse,
          reason: '缺 data.status');
      expect(AppAddressResolver.isHealthBody('{"code":500,"data":{"status":"ok"}}'),
          isFalse);
      expect(
          AppAddressResolver.isHealthBody(
              '{"code":0,"data":{"status":"ok","services":{"database":"up"}}}'),
          isTrue);
    });

    test('探活选到的是"真后端"候选，插页候选被淘汰', () async {
      // 一个候选只回插页（200 + HTML），另一个回真 JSON：必须选后者
      final LocalStub bad = await startStubServer(
        contentType: 'text/html',
        body: '<html>You are about to visit x.ngrok-free.dev</html>',
      );
      final LocalStub good = await startStubServer(
        body: '{"code":0,"message":"ok","data":{"status":"ok","services":'
            '{"database":"up","redis":"up"}}}',
      );
      try {
        AppAddressResolver.debugFetchBootstrap = (url) async => jsonEncode({
              'api': '${bad.base}/api/v1',
              'candidates': ['${bad.base}/api/v1', '${good.base}/api/v1'],
            });
        final r = await AppAddressResolver.resolve();
        expect(r.address.apiBaseUrl, '${good.base}/api/v1',
            reason: '插页候选必须被淘汰（否则 App 拿到的是警告页地址）');
        expect(r.address.latencyMs, isNotNull);
      } finally {
        await bad.stop();
        await good.stop();
      }
    });
  });

  group('ApiClient 请求头（防插页 + 兼容非 ngrok 地址）', () {
    test('默认构造的 ApiClient 每个请求都带 skip 头与非浏览器 UA', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":null}');
      final dio = Dio(BaseOptions(baseUrl: 'https://<your-tunnel-domain>/api/v1'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio: dio);
      await api.request('GET', '/public/games');

      expect(headerOf(adapter.lastHeaders, ApiClient.ngrokSkipWarningHeader), 'true',
          reason: '断言真正发出去的请求头（不是只看常量）');
      expectNotBrowserUa(adapter.lastHeaders);
      expect(headerOf(adapter.lastHeaders, 'user-agent'), ApiClient.appUserAgent);
    });

    test('buildHeaders 无条件带 skip 头，且不破坏 token 透传', () {
      final h = ApiClient.buildHeaders(token: 'tok-123');
      expect(h[ApiClient.ngrokSkipWarningHeader], 'true');
      expect(h['Authorization'], 'Bearer tok-123');

      final anon = ApiClient.buildHeaders();
      expect(anon[ApiClient.ngrokSkipWarningHeader], 'true',
          reason: '未登录（登录页/探活）也要带头');
      expect(anon.containsKey('Authorization'), isFalse);
    });

    test('非 ngrok 地址（Cloudflare / 局域网）同样带头，不影响既有能力', () async {
      for (final String base in const <String>[
        'https://abc-def.trycloudflare.com/api/v1',
        'http://192.168.1.145:3100/api/v1',
      ]) {
        final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":null}');
        final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
        await ApiClient(dio: dio).request('GET', '/divisions');
        expect(headerOf(adapter.lastHeaders, ApiClient.ngrokSkipWarningHeader), 'true',
            reason: '$base 也要带（Cloudflare/局域网一律忽略未知头，无副作用）');
        expectNotBrowserUa(adapter.lastHeaders);
      }
    });

    test('请求级 headers 仍可覆盖同名键（不锁死调用方）', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":null}');
      final dio = Dio(BaseOptions(
        baseUrl: 'https://x.example.com/api/v1',
        headers: const <String, dynamic>{
          ApiClient.ngrokSkipWarningHeader: ApiClient.ngrokSkipWarningValue,
        },
      ))..httpClientAdapter = adapter;
      await dio.request<Map<String, dynamic>>(
        '/x',
        options: Options(
            method: 'GET',
            headers: const <String, dynamic>{
              ApiClient.ngrokSkipWarningHeader: 'custom',
            }),
      );
      expect(headerOf(adapter.lastHeaders, ApiClient.ngrokSkipWarningHeader), 'custom');
    });
  });
}

/// 便于在测试里抛"网络异常"而不 import dart:io
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: 测试用网络不可达';
}
