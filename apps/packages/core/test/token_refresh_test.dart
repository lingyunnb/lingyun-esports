import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 令牌过期自动刷新（2026-09-25 修复"用一会儿就提示登录已过期，消息页打不开"）
///
/// 回归场景：access token 有效期 2 小时，此前只在 App 启动时刷新 →
/// 长时间使用后所有接口 401，页面显示"登录已过期，请重新登录"。
/// 现在 ApiClient 遇到该 401 会自动换新令牌并重试一次。
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  tearDown(() {
    ApiClient.onTokenExpired = null;
    ApiClient.onSessionKicked = null;
  });

  test('令牌过期：401 → 自动刷新 → 用新令牌重试成功', () async {
    final adapter = _ExpiredTokenAdapter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter);
    var refreshCalls = 0;
    ApiClient.onTokenExpired = () async {
      refreshCalls++;
      return 'NEW-TOKEN';
    };

    final resp = await api.request('GET', '/user/conversations', token: 'OLD-TOKEN');

    expect(adapter.calls, 2, reason: '第一次 401，刷新后重试一次');
    expect(refreshCalls, 1, reason: '只刷新一次');
    expect(adapter.tokens, ['Bearer OLD-TOKEN', 'Bearer NEW-TOKEN'], reason: '重试必须带新令牌');
    expect(resp['data']?['ok'], true);
  });

  test('刷新失败（返回 null）：把原始 401 抛给调用方，不无限重试', () async {
    final adapter = _ExpiredTokenAdapter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter);
    ApiClient.onTokenExpired = () async => null;

    await expectLater(
      api.request('GET', '/user/conversations', token: 'OLD-TOKEN'),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('登录已过期'))),
    );
    expect(adapter.calls, 1, reason: '没有新令牌就不该重试');
  });

  test('未注册刷新钩子：401 原样抛出（不影响未登录场景）', () async {
    final adapter = _ExpiredTokenAdapter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter);
    ApiClient.onTokenExpired = null;

    await expectLater(
      api.request('GET', '/user/conversations', token: 'OLD-TOKEN'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 401)),
    );
    expect(adapter.calls, 1);
  });

  test('正常请求不触发刷新', () async {
    final adapter = _ExpiredTokenAdapter(alwaysOk: true);
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fixture.local'))..httpClientAdapter = adapter);
    var refreshCalls = 0;
    ApiClient.onTokenExpired = () async {
      refreshCalls++;
      return 'NEW-TOKEN';
    };

    await api.request('GET', '/user/conversations', token: 'TOKEN');
    expect(refreshCalls, 0);
    expect(adapter.calls, 1);
  });
}

/// 假适配器：第一次返回 401「登录已过期」，带新令牌的请求返回 200
class _ExpiredTokenAdapter implements HttpClientAdapter {
  _ExpiredTokenAdapter({this.alwaysOk = false});

  final bool alwaysOk;
  int calls = 0;
  final List<String> tokens = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    final auth = options.headers['Authorization'] as String? ?? '';
    tokens.add(auth);
    // 旧令牌 → 401（模拟 access token 过期）；新令牌或 alwaysOk → 200
    if (!alwaysOk && auth == 'Bearer OLD-TOKEN') {
      return ResponseBody.fromString(
        jsonEncode({'code': 401, 'message': '登录已过期，请重新登录', 'data': null}),
        401,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'code': 0, 'message': 'ok', 'data': {'ok': true}}),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}
