import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';

/// ============================================================================
/// 图片加载**失败态**：中文原因 + 「重试」（2026-10-07 真事故的"让用户能自己判断"部分）
/// ============================================================================
///
/// ## 背景（负责人实测）
///
/// 充值审核详情页的付款凭证图**一直转圈**。地址少 `/api/v1` 前缀是根因（见
/// `recharge_proof_url_test.dart`），但**为什么表现是"转圈"而不是"报错"**是第二个问题：
///
/// `CachedNetImage` 下载失败时（`_failed = true`）走的是**调用方传的 `placeholder`**，
/// 而三处调用方传的都是转圈指示器 → 失败与加载中**长得一模一样**，转圈永不消失：
/// 审核员既不知道是 404 还是 401，也没有任何下一步可点。
///
/// 本文件锁两件事：
/// 1. **失败必须说话**：中文原因（含状态码）+ 「重试」按钮（[ImageLoadError]）；
/// 2. **重试真的重新拉取**：第二次成功就不再是错误态（不是把转圈又画一遍）。
///
/// 顺带锁住"默认行为不变"：没传 `errorBuilder` 的既有调用方仍然回退 `placeholder`（零影响）。
///
/// ## 实现注记（踩过的坑，勿回退）
///
/// - 真实文件 I/O（磁盘缓存读写）必须在 `tester.runAsync` 里跑：`testWidgets` 默认是
///   **假时钟**环境，`HttpClient`/`File` 这类真实异步不推进就会**挂住整轮测试**（实测）。
///   因此每个用例都整段包在 `runAsync` 里，并各自带 `timeout`，卡住就红而不是等。
/// - 出站 `HttpClient` 走 `ImageDiskCache.httpClientFactory`（生产 = `HttpClient.new`）：
///   `HttpOverrides` 对这条路径不可靠（`lookup()` 之后 `HttpClient()` 未必还在那个 Zone 里）。
void main() {
  const String cjkFamily = 'CoreCjkProbe';
  const String cjkPath = 'C:/Windows/Fonts/msyh.ttc';

  /// 1×1 的真实 PNG（重试用例第二次请求成功时落盘用；能真解码，不是垃圾字节）
  final Uint8List tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final f = File(cjkPath);
    if (!f.existsSync()) return;
    final loader = FontLoader(cjkFamily)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
    await loader.load();
  });

  tearDown(() {
    // 每个用例留的假客户端用完即还原，绝不污染同进程其它用例（出图用例也跑在这个进程里）
    ImageDiskCache.instance.httpClientFactory = HttpClient.new;
  });

  Widget host(Widget child) => MaterialApp(
        home: Directionality(
          textDirection: TextDirection.ltr,
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: cjkFamily, fontSize: 12),
            child: Scaffold(body: Center(child: SizedBox(width: 300, height: 260, child: child))),
          ),
        ),
      );

  String uniqueUrl(String path) =>
      'https://example.test$path?probe=${DateTime.now().microsecondsSinceEpoch}';

  group('① 失败必说人话：中文原因（含状态码）+ 「重试」', () {
    testWidgets('404（本次事故的真实响应）→ 中文原因 + 状态码 + 重试按钮', (tester) async {
      final client = _FakeClient(status: 404);
      ImageDiskCache.instance.httpClientFactory = () => client;
      final url = uniqueUrl('/api/v1/recharge/proof/48');

      await tester.runAsync(() async {
        await tester.pumpWidget(host(CachedNetImage(
          url: url,
          errorBuilder: (_, failure, retry) =>
              ImageLoadError(failure: failure, onRetry: retry, title: '凭证图加载失败'),
        )));
        await settle(tester);

        final text = tester.widget<Text>(find.byKey(ImageLoadError.textKey)).data ?? '';
        expect(text, startsWith('凭证图加载失败（'));
        expect(text.contains('404'), isTrue, reason: '状态码必须上屏 —— 排障全靠它区分 401/403/404');
        expect(text.contains('服务器上没有这张图'), isTrue, reason: '中文原因要说人话，不许只丢一个状态码');
        expect(find.text('重试'), findsOneWidget, reason: '失败必须给下一步，不许无声转圈');
        expect(client.calls, 1);
        expect(_tofuLines(text, cjkFamily), isEmpty, reason: '中文必须是真字形，不能是豆腐块');

        // 重试一次：确实又打了一次网络（不是只重画转圈）
        await tester.tap(find.byKey(ImageLoadError.retryKey));
        await settle(tester);
        expect(client.calls, 2);
        expect(find.text('重试'), findsOneWidget, reason: '这次仍失败 → 仍要给出重试');
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('401（没带/过期的受限会话令牌）→ 中文原因 + 状态码', (tester) async {
      final client = _FakeClient(status: 401);
      ImageDiskCache.instance.httpClientFactory = () => client;

      await tester.runAsync(() async {
        await tester.pumpWidget(host(CachedNetImage(
          url: uniqueUrl('/api/v1/recharge/proof/48'),
          headers: const {'Authorization': 'Bearer expired'},
          errorBuilder: (_, failure, retry) => ImageLoadError(failure: failure, onRetry: retry),
        )));
        await settle(tester);

        final text = tester.widget<Text>(find.byKey(ImageLoadError.textKey)).data ?? '';
        expect(text, contains('401'));
        expect(text, contains('登录状态可能已过期'));
        expect(find.text('重试'), findsOneWidget);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('连不上服务器（SocketException）→ 中文原因，无状态码时不硬凑括号', (tester) async {
      final client = _FakeClient(throwSocket: true);
      ImageDiskCache.instance.httpClientFactory = () => client;

      await tester.runAsync(() async {
        await tester.pumpWidget(host(CachedNetImage(
          url: uniqueUrl('/media/public/9'),
          errorBuilder: (_, failure, retry) => ImageLoadError(failure: failure, onRetry: retry),
        )));
        await settle(tester);

        final text = tester.widget<Text>(find.byKey(ImageLoadError.textKey)).data ?? '';
        expect(text, '连不上服务器：请检查网络后重试');
        expect(text.contains('('), isFalse);
        expect(find.text('重试'), findsOneWidget);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('② 重试真的能救回来：第二次成功 → 错误态消失', () {
    testWidgets('底层：downloadResult 第二次 200 真的落盘（先排除网络/落盘层的问题）', (tester) async {
      final client = _FakeClient(status: 404, thenStatus: 200, bytes: tinyPng);
      ImageDiskCache.instance.httpClientFactory = () => client;

      await tester.runAsync(() async {
        expect(tinyPng.length, greaterThan(50), reason: 'PNG 字节必须是真的（base64 解出来要够长）');
        expect(tinyPng.sublist(1, 4), <int>[0x50, 0x4E, 0x47], reason: 'PNG magic 必须正确');

        final url = uniqueUrl('/api/v1/recharge/proof/raw');
        final first = await ImageDiskCache.instance.downloadResult(url);
        expect(first.ok, isFalse);
        expect(first.failure?.statusCode, 404);

        final second = await ImageDiskCache.instance.downloadResult(url);
        expect(second.ok, isTrue,
            reason: '第二次必须拿到文件（HTTP 200）；实际 failure=${second.failure}'
                ' raw=${ImageDiskCache.instance.lastRawError}');
        expect(second.file?.existsSync(), isTrue);
        expect(client.calls, 2);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('第一次 404 → 显示错误；点重试 → 第二次 200 → 图落盘、错误态消失', (tester) async {
      final client = _FakeClient(status: 404, thenStatus: 200, bytes: tinyPng);
      ImageDiskCache.instance.httpClientFactory = () => client;

      await tester.runAsync(() async {
        final url = uniqueUrl('/api/v1/recharge/proof/9');
        await tester.pumpWidget(host(CachedNetImage(
          url: url,
          errorBuilder: (_, failure, retry) =>
              ImageLoadError(failure: failure, onRetry: retry, title: '凭证图加载失败'),
        )));
        await settle(tester);
        expect(find.byKey(ImageLoadError.retryKey), findsOneWidget);

        await tester.tap(find.byKey(ImageLoadError.retryKey));
        await settle(tester);
        await tester.pump();

        // 诊断锚点：先确认"第二次真的拿到了 200 且落盘了"，
        // 再看 UI（否则"UI 没变"到底是网络没救回来还是界面没重建，分不清）
        expect(client.calls, 2);
        expect(client.lastStatus, 200);
        File? onDisk;
        for (var i = 0; i < 40 && onDisk == null; i++) {
          onDisk = await ImageDiskCache.instance.lookup(url);
          if (onDisk == null) await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(onDisk, isNotNull, reason: '重试成功必须落盘');
        expect(find.byKey(ImageLoadError.retryKey), findsNothing, reason: '成功之后错误态必须消失');
        expect(find.textContaining('凭证图加载失败'), findsNothing);
      });
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('③ 默认行为不变：没传 errorBuilder 的既有调用方零影响', () {
    testWidgets('失败 → 回退调用方的 placeholder（旧行为逐字保留）', (tester) async {
      final client = _FakeClient(status: 404);
      ImageDiskCache.instance.httpClientFactory = () => client;

      await tester.runAsync(() async {
        await tester.pumpWidget(host(CachedNetImage(
          url: uniqueUrl('/media/public/9'),
          placeholder: const Text('OLD_PLACEHOLDER'),
        )));
        await settle(tester);

        expect(find.text('OLD_PLACEHOLDER'), findsOneWidget);
        expect(find.byKey(ImageLoadError.retryKey), findsNothing);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('缩略图态（compact）：整格可点即重试，不塞文字按钮', (tester) async {
      final client = _FakeClient(status: 403);
      ImageDiskCache.instance.httpClientFactory = () => client;

      await tester.runAsync(() async {
        await tester.pumpWidget(host(SizedBox(
          width: 48,
          height: 48,
          child: CachedNetImage(
            url: uniqueUrl('/api/v1/recharge/proof/9'),
            errorBuilder: (_, failure, retry) =>
                ImageLoadError(failure: failure, onRetry: retry, compact: true),
          ),
        )));
        await settle(tester);

        expect(find.text('重试'), findsNothing, reason: '48dp 塞不下文字按钮');
        expect(find.bySemanticsLabel('凭证图加载失败，点按重试'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('凭证图加载失败，点按重试'));
        await settle(tester);
        expect(client.calls, 2);
      });
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('④ 失败原因本身（分类文案，单一实现点）', () {    test('404/401/403/5xx 各说各的（同一句"加载失败"等于没说）', () {
      expect(ImageDiskCache.failureTextForTest(404), '服务器上没有这张图');
      expect(ImageDiskCache.failureTextForTest(401), '服务器拒绝了这次请求（登录状态可能已过期）');
      expect(ImageDiskCache.failureTextForTest(403), '没有查看这张图的权限');
      expect(ImageDiskCache.failureTextForTest(500), '服务端暂时不可用');
    });

    test('describe：有状态码带括号与原因短语；无状态码只有中文', () {
      expect(
        const ImageLoadFailure(url: 'u', statusCode: 404, reasonPhrase: 'Not Found', message: '服务器上没有这张图')
            .describe,
        '服务器上没有这张图（404 Not Found）',
      );
      expect(
        const ImageLoadFailure(url: 'u', statusCode: 403, reasonPhrase: '', message: '没有查看这张图的权限').describe,
        '没有查看这张图的权限（403）',
      );
      expect(const ImageLoadFailure(url: 'u', message: '连不上服务器：请检查网络后重试').describe,
          '连不上服务器：请检查网络后重试');
    });

    test('ImageLoadError 的中文标题拼接（上屏那一行就是它）', () {
      const f = ImageLoadFailure(url: 'u', statusCode: 404, reasonPhrase: 'Not Found', message: '服务器上没有这张图');
      const w = ImageLoadError(failure: f, onRetry: _noop, title: '凭证图加载失败');
      expect(w.fullText, '凭证图加载失败（服务器上没有这张图（404 Not Found））');
      const w2 = ImageLoadError(failure: f, onRetry: _noop);
      expect(w2.fullText, '服务器上没有这张图（404 Not Found）');
    });
  });
}

void _noop() {}

/// 等所有异步收尾（下载 + 重试回源）—— 必须在 `tester.runAsync` 里调用
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
    if (i % 4 == 3) await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 找出会渲染成"豆腐块"（缺字形）的行 —— 用来证明上屏的是真中文
List<String> _tofuLines(String text, String family) {
  final missing = <String>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    double width(String fam) {
      final tp = TextPainter(
        text: TextSpan(text: line, style: TextStyle(fontFamily: fam, fontSize: 12)),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.computeLineMetrics().fold<double>(0, (a, m) => a + m.width);
    }

    final painted = width(family);
    final withoutFont = width('NoSuchFontFamilyXYZ');
    if (painted == 0 || painted == withoutFont) missing.add(line);
  }
  return missing;
}

/// 假 `HttpClient`：确定性地造出 404/401/403/断网（第一次响应 [status]，
/// 之后（重试）响应 [thenStatus]，用于验证"重试真的能救回来"）
class _FakeClient implements HttpClient {
  _FakeClient({this.status = 404, this.thenStatus, this.bytes, this.throwSocket = false});

  final int status;
  final int? thenStatus;
  final Uint8List? bytes;
  final bool throwSocket;

  int calls = 0;

  /// 最近一次真正返回给调用方的状态码（诊断/断言用）
  int lastStatus = 0;

  int get statusNow => (calls > 1 && thenStatus != null) ? thenStatus! : status;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    calls += 1;
    lastStatus = statusNow;
    if (throwSocket) {
      throw const SocketException('Connection refused (fake)');
    }
    return _FakeRequest(this);
  }

  @override
  Duration? connectionTimeout;

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._client);

  final _FakeClient _client;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(_client);

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _FakeResponse implements HttpClientResponse {
  _FakeResponse(this._client);

  final _FakeClient _client;

  @override
  int get statusCode => _client.statusNow;

  @override
  String get reasonPhrase => switch (_client.statusNow) {
        200 => 'OK',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not Found',
        _ => '',
      };

  @override
  int get contentLength => _client.bytes?.length ?? 0;

  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;

  /// 生产代码用 `resp.fold(...)` 收字节（`cached_image.dart`），这里**显式实现** ——
  /// 只靠 `listen` + `noSuchMethod` 会在 `fold` 上抛 `UnimplementedError`，
  /// 被下载层的 `catch` 兜成"网络异常"，测出来的是假失败（实测踩过）。
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
    final stream = (data == null || data.isEmpty)
        ? const Stream<List<int>>.empty()
        : Stream<List<int>>.value(data);
    return stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _FakeHeaders implements HttpHeaders {
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
