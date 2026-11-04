/// **换图不转圈：新图下载中，旧图留在屏上**（2026-10-16 负责人「不要在等转圈」）
///
/// ## 病灶（真机现象）
/// 运营在管理端换完宣传图 → 客户端拿到新的 `imageMediaId` → **新地址不在磁盘缓存里** →
/// `CachedNetImage.didUpdateWidget` 的既有行为是**把已加载的文件丢掉、回到占位块**，
/// 而占位块在下载中会画 `CircularProgressIndicator`（见 `_CachedNetImageState.build`）。
/// 通栏是首屏最大的一块，于是用户看到的是「整条灰色通栏 + 转圈」，等新图下载完才变成图。
///
/// ## 修法（[CachedNetImage.keepPreviousOnUrlChange]）
/// URL 变化时**不丢**已加载的文件：旧图继续留屏上（同位、同 `BoxFit.cover`），新图就绪后**静默替换**。
/// 默认 `false` → 既有调用方行为**逐字不变**（本文件里有一条"对照组"用例把这件事也钉住）。
///
/// ## 为什么这几个断言能证明修好了
/// - `find.byType(Image)` 仍在 = 屏上是有内容的图，不是占位；
/// - `CircularProgressIndicator` findsNothing = **没有转圈**（这一条就是负责人的原话）；
/// - `FileImage.path` 先等于旧图、后变成新图 = **静默替换**真的发生了（不是"永远显示旧图"）。
library;

import 'dart:async';
import 'dart:convert' show base64;
import 'dart:io';
import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 1×1 的真实 PNG（能真解码，不是垃圾字节）
  final Uint8List tinyPng = base64DecodeTinyPng();

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  tearDown(() async {
    // 每个用例自带独立目录（绝不碰全机共享的 fish_img_cache），用完删掉；假客户端也还原
    await ImageDiskCache.instance.dispose();
    ImageDiskCache.instance.httpClientFactory = HttpClient.new;
  });

  Widget host(Widget child) => MaterialApp(
        home: Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(body: Center(child: SizedBox(width: 300, height: 260, child: child))),
        ),
      );

  /// 本用例专属的磁盘缓存目录（`useDir` 会把内存索引与在途请求一起重置）
  Future<void> useOwnDir() async {
    final dir = Directory(
      '${Directory.systemTemp.path}/fish_banner_swap_${DateTime.now().microsecondsSinceEpoch}',
    );
    await ImageDiskCache.instance.useDir(dir);
  }

  String uniqueUrl(String mediaId) =>
      'https://banner.test/api/v1/media/public/$mediaId?probe=${DateTime.now().microsecondsSinceEpoch}';

  /// 当前屏上那张图的磁盘路径（`Image.file` → `FileImage.file.path`）
  String shownPath(WidgetTester tester) {
    final img = tester.widget<Image>(find.byType(Image));
    final provider = img.image;
    expect(provider, isA<FileImage>(), reason: 'DiskCache 命中时应当画磁盘文件');
    return (provider as FileImage).file.path;
  }

  /// 等异步收尾（下载 / 查缓存）—— 必须在 `tester.runAsync` 里调用
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
    }
  }

  group('① 换图（URL 变化）时旧图留屏上、新图静默替换', () {
    testWidgets('keepPreviousOnUrlChange=true：全程无转圈，旧图 → 新图', (tester) async {
      final client = _SlowClient(bytes: tinyPng, delayMs: 220);
      ImageDiskCache.instance.httpClientFactory = () => client;
      final url1 = uniqueUrl('292');
      final url2 = uniqueUrl('293'); // 运营换图 → mediaId 变

      await tester.runAsync(() async {
        await useOwnDir();

        // 第一张图（当前线上的宣传图）
        await tester.pumpWidget(host(CachedNetImage(url: url1, keepPreviousOnUrlChange: true)));
        await settle(tester);
        expect(find.byType(Image), findsOneWidget);
        final path1 = shownPath(tester);

        // 运营换了图 → 同一个位置换成 url2（新地址不在磁盘缓存里）
        await tester.pumpWidget(host(CachedNetImage(url: url2, keepPreviousOnUrlChange: true)));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();

        // 下载中：屏上仍是**旧图**，没有灰块、没有转圈
        expect(find.byType(Image), findsOneWidget, reason: '下载期间旧图必须留在屏上（否则通栏空一块）');
        expect(find.byType(CircularProgressIndicator), findsNothing, reason: '负责人要的"不要在等转圈"就是这个');
        expect(shownPath(tester), path1, reason: '此刻显示的还是旧图');

        // 新图落地 → 静默替换
        await settle(tester);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(shownPath(tester), isNot(path1), reason: '新图就绪后必须真的换上去（不是永远拿旧图糊住）');
        expect(client.calls, 2, reason: '换图确实打了一次新地址（旧图不是"假装换过"）');
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('对照组：默认（不打开开关）仍会回到占位 + 转圈 —— 证明修的不是假象', (tester) async {
      final client = _SlowClient(bytes: tinyPng, delayMs: 220);
      ImageDiskCache.instance.httpClientFactory = () => client;
      final url1 = uniqueUrl('292');
      final url2 = uniqueUrl('293');

      await tester.runAsync(() async {
        await useOwnDir();

        await tester.pumpWidget(host(CachedNetImage(url: url1))); // 默认 false
        await settle(tester);
        expect(find.byType(Image), findsOneWidget);

        await tester.pumpWidget(host(CachedNetImage(url: url2)));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();

        expect(find.byType(Image), findsNothing, reason: '既有行为：URL 一变就把已加载的图丢掉');
        expect(find.byType(CircularProgressIndicator), findsOneWidget,
            reason: '既有行为会转圈 —— 这正是负责人报的现象（宣传图位置整条灰块 + 转圈）');
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('新图**真的失败**时不糊旧图：落到失败/占位分支（不骗用户）', (tester) async {
      final ok = _SlowClient(bytes: tinyPng, delayMs: 0);
      ImageDiskCache.instance.httpClientFactory = () => ok;
      final url1 = uniqueUrl('292');
      final url2 = uniqueUrl('999');

      await tester.runAsync(() async {
        await useOwnDir();
        await tester.pumpWidget(host(CachedNetImage(url: url1, keepPreviousOnUrlChange: true)));
        await settle(tester);
        expect(find.byType(Image), findsOneWidget);

        // 换成一张 404 的地址：失败必须被看见（默认回退占位，给了 errorBuilder 就画错误态）
        ImageDiskCache.instance.httpClientFactory = () => _SlowClient(status: 404, delayMs: 0);
        await tester.pumpWidget(host(CachedNetImage(
          url: url2,
          keepPreviousOnUrlChange: true,
          errorBuilder: (_, failure, retry) => Text('失败：${failure.describe}'),
        )));
        await settle(tester);

        expect(find.textContaining('失败：'), findsOneWidget, reason: '新图失败要说话，不许拿旧图假装成功');
        expect(find.byType(Image), findsNothing);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

/// 1×1 真实 PNG 的 base64（与 `cached_image_error_test.dart` 同一份，能真解码）
Uint8List base64DecodeTinyPng() => base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
    );

/// 假 `HttpClient`：可注入**延迟**（用来观察到"新图下载中"那一刻的状态）与状态码
class _SlowClient implements HttpClient {
  _SlowClient({this.status = 200, this.bytes, this.delayMs = 0});

  final int status;
  final Uint8List? bytes;
  final int delayMs;

  int calls = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    calls += 1;
    if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
    return _SlowRequest(this);
  }

  @override
  Duration? connectionTimeout;

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _SlowRequest implements HttpClientRequest {
  _SlowRequest(this._client);

  final _SlowClient _client;

  @override
  final HttpHeaders headers = _SlowHeaders();

  @override
  Future<HttpClientResponse> close() async => _SlowResponse(_client);

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _SlowResponse implements HttpClientResponse {
  _SlowResponse(this._client);

  final _SlowClient _client;

  @override
  int get statusCode => _client.status;

  @override
  String get reasonPhrase => _client.status == 200 ? 'OK' : 'Not Found';

  @override
  int get contentLength => _client.bytes?.length ?? 0;

  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;

  /// 生产代码用 `resp.fold(...)` 收字节 —— 必须显式实现（只靠 listen + noSuchMethod 会在 fold 上抛）
  @override
  Future<S> fold<S>(S initialValue, S Function(S previous, List<int> element) combine) async {
    final data = _client.bytes;
    if (data == null || data.isEmpty) return initialValue;
    return combine(initialValue, data);
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final data = _client.bytes;
    final stream = (data == null || data.isEmpty) ? const Stream<List<int>>.empty() : Stream<List<int>>.value(data);
    return stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _SlowHeaders implements HttpHeaders {
  final Map<String, List<String>> store = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    store[name.toLowerCase()] = ['$value'];
  }

  @override
  List<String>? operator [](String name) => store[name.toLowerCase()];

  @override
  String? value(String name) => store[name.toLowerCase()]?.first;

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}
