import 'dart:io';
import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 受保护媒体取图：**地址 + 令牌**两件事一起钉死（2026-10-07 任务 2/3 的 core 侧验收）
///
/// ## 为什么要单开这一个文件
/// 出图那套（`boss-app/test/visual/chat_complaint_image_visual_test.dart`）跑在 widget 测试的
/// **fake-async 时区**里：`dart:io` 的真异步下载能不能推进取决于 `runAsync` 窗口，
/// 于是"图有没有画出来"会变得看运气（实测踩过，来回红了三轮）。
/// 这里用**真异步 + 真 HTTP**（起一个 `HttpServer` 监听回环口）把**请求层**的证据钉死：
///   - 真的往 `/api/v1/media/protected/:id` 发请求（不是 `/media/chat/:id`、也不是少前缀的 `/media/protected/:id`）；
///   - 真的带 `Authorization: Bearer <当前身份令牌>`；
///   - 服务端 401/404 时组件进失败态（而不是无声的空块）。
///
/// 这三条正是本次两个 bug 的**全部成因**（一个路径错、一个少前缀+没令牌），所以它们必须各有独立断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token = 'core-protected-token';
  late HttpServer server;
  late String origin;

  /// 服务端收到的请求（断言"发出去的到底是什么"）
  late List<({String path, String? auth, String method})> seen;
  late int status;

  /// 本文件必须打**真 HTTP**（回环口的本地服务），而 `flutter_test` 默认给 `HttpClient`
  /// 装了一个"一律返回 400 的假实现"（`HttpOverrides.global`）—— 它在这里只会把
  /// "地址对不对 / 有没有带令牌"这两件事全糊成 400（实测：断言全红、原因却是 400）。
  /// 因此本文件**临时摘掉它**，`tearDownAll` 原样装回。
  HttpOverrides? savedOverrides;

  setUpAll(() async {
    savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    // 1×1 透明 PNG（真实图片字节 → 组件会真的解码，不是"200 但一堆 HTML"）
    final bytes = Uint8List.fromList(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
    server.listen((req) async {
      seen.add((path: req.uri.path, auth: req.headers.value('authorization'), method: req.method));
      final int code = status;
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.parse(code == 200 ? 'image/png' : 'text/plain');
      req.response.add(code == 200 ? bytes : Uint8List.fromList('no'.codeUnits));
      await req.response.close();
    });
  });

  tearDownAll(() async {
    await ImageDiskCache.instance.dispose(); // 删掉刚用的那个测试目录（只删 useDir 指定的）
    await server.close(force: true);
    HttpOverrides.global = savedOverrides; // 原样装回（别把别的测试文件的网络行为改掉）
  });

  setUp(() async {
    seen = [];
    status = 200;
    /**
     * 【2026-10-07 修：本文件此前**整个编译不过**，core 套件因此常红】
     *
     * 上一批（75fcb68）把 `ImageDiskCache.clear()` 换成了 `useDir()` / `dispose()`
     * 两个测试钩子，但这个文件仍在调 `clear()` → `Error: The method 'clear' isn't defined
     * for the type 'ImageDiskCache'`（加载失败，整个文件的用例一个都不跑）。
     * 这里改用**当时的同一套钩子**，语义与旧 `clear()` 的意图一致：每条用例从空缓存开始。
     * 用一个**本文件专属**的临时子目录（[useDir] 只动它指定的目录，绝不去删默认共享目录）。
     */
    await ImageDiskCache.instance.useDir(
      Directory('${Directory.systemTemp.path}/fish_img_cache_protected_test/${DateTime.now().microsecondsSinceEpoch}'),
    );
    AppConfigRuntime.reset();
    AppConfigRuntime.apply(api: '$origin/api/v1', ws: origin, from: 'bootstrap');
  });

  tearDown(() {
    AppConfigRuntime.reset();
  });

  group('① 地址（唯一出处）', () {
    test('protectedMediaUrl 逐字等于真实路由 /api/v1/media/protected/:id', () {
      expect(AppConfig.protectedMediaUrl('148'), '$origin/api/v1/media/protected/148');
      // 反面：这两个就是本次两个 bug 拼出来的坏地址（服务端没有这两条路由）
      expect(AppConfig.protectedMediaUrl('148'), isNot('$origin/media/protected/148'));
      expect(AppConfig.protectedMediaUrl('148'), isNot('$origin/media/chat/148'));
    });

    test('鉴权头：空令牌 → 空 Map（公开图行为不变）；有令牌 → Bearer', () {
      expect(authImageHeaders(null), isEmpty);
      expect(authImageHeaders(''), isEmpty);
      expect(authImageHeaders(token), {'Authorization': 'Bearer $token'});
      // 历史名字（充值凭证那条链路）必须与它同源
      expect(proofImageHeaders(token), authImageHeaders(token));
    });
  });

  group('② 取图（真 HTTP，请求层证据）', () {
    test('命中真实路由 200 → 拿到图片字节，且请求**带 Authorization**', () async {
      final url = AppConfig.protectedMediaUrl('90201');
      final r = await ImageDiskCache.instance.downloadResult(url, headers: authImageHeaders(token));

      expect(r.ok, isTrue, reason: '必须真的下到图（不是 200 但 HTML）');
      expect(r.file!.lengthSync(), greaterThan(0));
      expect(seen, hasLength(1));
      expect(seen.first.path, '/api/v1/media/protected/90201', reason: '地址必须是真实受保护路由（带 /api/v1）');
      expect(seen.first.auth, 'Bearer $token', reason: '受保护媒体必须带令牌，否则 401');
    });

    test('服务端 401（没带令牌的后果）→ 失败原因说清是"登录状态可能已过期"', () async {
      status = 401;
      final r = await ImageDiskCache.instance.downloadResult(
        AppConfig.protectedMediaUrl('90202'),
        headers: const <String, String>{}, // 刻意不带令牌：这就是修复前投诉页/聊天页的形态
      );
      expect(r.ok, isFalse);
      expect(r.failure!.statusCode, 401);
      expect(r.failure!.describe.contains('401'), isTrue, reason: '状态码必须上屏（排障抓手）');
      expect(r.failure!.message.contains('登录状态'), isTrue);
    });

    test('服务端 404（路径写错时的真实表现）→ 失败原因说清"服务器上没有这张图"', () async {
      status = 404;
      final r = await ImageDiskCache.instance.downloadResult(
        '$origin/media/chat/90203', // 旧代码拼出来的那条不存在的路由
        headers: authImageHeaders(token),
      );
      expect(r.ok, isFalse);
      expect(r.failure!.statusCode, 404);
      expect(r.failure!.message.contains('服务器上没有这张图'), isTrue,
          reason: '404 与 401 必须能区分 —— 它们指向完全不同的修法');
    });

    test('公开媒体路径不需要令牌（/media/public/:id 不在全局前缀下，行为逐字不变）', () async {
      final r = await ImageDiskCache.instance.downloadResult('$origin/media/public/7');
      expect(r.ok, isTrue);
      expect(seen.first.path, '/media/public/7');
      expect(seen.first.auth, isNull, reason: '公开图不带令牌（带与不带都必须能拿到，这里钉的是"不带"）');
    });
  });
}
