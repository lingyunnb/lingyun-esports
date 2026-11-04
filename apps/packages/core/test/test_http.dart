/// 测试辅助：捕获 Dio 实际发出的请求头（2026-10-04）
///
/// 为什么需要它：ngrok 免费档会对**浏览器式**请求返回"警示插页"（HTTP 200 + HTML），
/// 客户端必须无条件带上 `ngrok-skip-browser-warning` 且保持非浏览器 UA
/// （见 `lib/src/api/api_client.dart` 的 `ApiClient.ngrokSkipWarningHeader` /
/// `ApiClient.appUserAgent`）。要断言"真的发出来了"，只能看适配器拿到的
/// `RequestOptions.headers`，而不是看我们自己的常量。
///
/// 本文件在 `test/` 下，不参与打包；core / boss-app / worker-app 各自的 test/ 目录
/// 是独立的，不跨包 import。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 记录最后一次请求的请求头 + 路径，并回一份固定 JSON。
class HeaderRecordingAdapter implements HttpClientAdapter {
  HeaderRecordingAdapter(this.body, {this.statusCode = 200});

  /// 回给 Dio 的响应体（JSON 字符串）
  final String body;
  final int statusCode;

  /// 最近一次请求的请求头（大小写不敏感查找用 [headerOf]）
  Map<String, dynamic> lastHeaders = <String, dynamic>{};

  /// 所有请求的路径（按顺序）
  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastHeaders = Map<String, dynamic>.from(options.headers);
    paths.add(options.path);
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 大小写不敏感地取一个请求头。
String? headerOf(Map<String, dynamic> headers, String name) {
  final String want = name.toLowerCase();
  for (final MapEntry<String, dynamic> e in headers.entries) {
    if (e.key.toLowerCase() == want) {
      final Object? v = e.value;
      if (v is List) return v.isEmpty ? null : '${v.first}';
      return v?.toString();
    }
  }
  return null;
}

/// 断言该头的值不是浏览器样式（浏览器 UA 会被 ngrok 判成浏览器 → 插页）
void expectNotBrowserUa(Map<String, dynamic> headers) {
  final String ua = headerOf(headers, 'user-agent') ?? '';
  for (final String m in const <String>[
    'Mozilla',
    'Chrome',
    'Safari',
    'Firefox',
    'Edge',
    'MSIE',
  ]) {
    if (ua.contains(m)) {
      throw StateError('User-Agent 看起来是浏览器，会被 ngrok 插页拦截: "$ua"');
    }
  }
}

/// 起一个固定回包的本地 HTTP 服务器，返回 (端口, 关闭函数)。
///
/// 用真实 socket 而不是 mock，是为了验证"默认 UA 到底是什么"
/// —— 这正是 ngrok 判定浏览器的依据，不能靠猜。
Future<LocalStub> startStubServer({
  int statusCode = 200,
  String body = '{"code":0,"message":"ok","data":{"status":"ok"}}',
  String contentType = 'application/json; charset=utf-8',
}) async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((HttpRequest request) {
    // 正文读掉，避免连接被客户端半关时抛错
    request.drain<void>().catchError((Object _) {});
    request.response
      ..statusCode = statusCode
      ..headers.set(HttpHeaders.contentTypeHeader, contentType)
      ..write(body);
    request.response.close();
  });
  return LocalStub('http://127.0.0.1:${server.port}', server);
}

/// 一个本地 stub 服务：`base` 形如 `http://127.0.0.1:53421`
class LocalStub {
  LocalStub(this.base, this._server);

  final String base;
  final HttpServer _server;

  Future<void> stop() => _server.close(force: true);
}

/// 用一个"会记录请求头"的本地服务器，请求它一次并返回实际发出的请求头。
Future<Map<String, String>> captureRequestHeaders(
  Future<void> Function(String base) fire, {
  int statusCode = 200,
  String body = '{"code":0,"message":"ok","data":{}}',
  String contentType = 'application/json; charset=utf-8',
}) async {
  final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final Completer<Map<String, String>> got = Completer<Map<String, String>>();
  final StreamSubscription<HttpRequest> sub = server.listen((HttpRequest request) {
    final Map<String, String> captured = <String, String>{
      '__port': '${server.port}',
    };
    request.headers.forEach((String name, List<String> values) {
      captured[name.toLowerCase()] = values.join(',');
    });
    request.drain<void>().catchError((Object _) {});
    request.response
      ..statusCode = statusCode
      ..headers.set(HttpHeaders.contentTypeHeader, contentType)
      ..write(body);
    request.response.close();
    if (!got.isCompleted) got.complete(captured);
  });
  try {
    await fire('http://127.0.0.1:${server.port}');
    return await got.future.timeout(const Duration(seconds: 8));
  } finally {
    await sub.cancel();
    await server.close(force: true);
  }
}
