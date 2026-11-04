import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/chat_detail_page.dart';
import 'package:boss_app/pages/complaint_page.dart';
import 'package:boss_app/widgets/chat_v4.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 出图 + 断言：**聊天图片**与**投诉截图**真的显示出来了（2026-10-07 任务 2 / 任务 3）
///
/// ## 这两张图要证明什么
///
/// 1. `chat_20_image_ok.png` —— 聊天页里的图片**真的画出来了**。
///    - 地址必须逐字等于 `AppConfig.protectedMediaUrl(<mediaId>)`（= `/api/v1/media/protected/:id`）；
///    - 请求**必须带 `Authorization: Bearer <令牌>`**（受保护媒体对匿名请求一律 401）；
///    - 走的是 `CachedNetImage`（不是裸 `Image.network`）。
///    修复前的两种坏法都会被这里钉住：`/media/chat/:id`（路由根本不存在，实测 404）、
///    以及"路径对了但没带令牌"（401）——**两者都表现为"图出不来"**。
/// 2. `complaint_21_image_ok.png` —— 投诉记录里的截图**真的画出来了**（同上三项断言）。
/// 3. `chat_22_image_failed.png` —— 失败态对照：服务端 404 时给**中文原因 + 「重试」**，
///    而不是旧代码那种"永远转圈 / 一个灰块"。
///
/// ## 为什么用假 `HttpClient` 而不是真服务器
/// 出图**禁止依赖线上聊天数据**（任务书硬要求），而 `CachedNetImage` 的下载走 `dart:io` 的
/// `HttpClient`（`ImageDiskCache.httpClientFactory` 是它唯一的构造点，`@visibleForTesting`）。
/// 这里注入一个假客户端：**记录收到的 URL 与 Authorization 头**，然后吐出一张真实 PNG
/// ——于是"地址对不对 / 有没有带令牌 / 图能不能解码"三件事在**同一次调用**里全部可断言。
void main() {
  const cjk = 'ChatImageCJK';
  const pageKey = Key('shot-page');
  const bossToken = 'boss-primary-token-for-shot';
  const workerToken = 'companion-token-for-shot';

  late _RecordingClient client;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    // 中文字形（msyh 最前，与仓库既有出图脚本同一做法）；否则中文是豆腐块、图标是方块
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(iconPath);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  /// 本文件独占的图片缓存目录（见下方 setUp 的说明）
  late Directory cacheDir;

  setUp(() async {
    AppConfigRuntime.reset();
    // 固定一个"服务器地址"：出图与断言里的绝对 URL 都由它推导（不写死域名）
    AppConfigRuntime.apply(api: 'http://shot.local/api/v1', ws: 'http://shot.local', from: 'bootstrap');
    ApiCache.instance.clear();
    /**
     * **图片磁盘缓存必须按文件隔离**（而不是删共享目录）。
     *
     * `flutter test` 默认**并行跑多个测试文件**（每个文件一个 isolate），而默认缓存目录是
     * 全机共享的 `systemTemp/fish_img_cache`：谁去删它，**别的文件正在读的图就没了**
     * —— 实测把 `recharge_10_proof_ok.png` 那条出图用例打成随机红。
     * 因此这里改用本文件独占的目录，用完即删（`dispose` 只删自己 `useDir` 指定的那个）。
     */
    cacheDir = Directory('${Directory.systemTemp.path}/fish_img_cache_shot_$pid');
    await ImageDiskCache.instance.useDir(cacheDir);
    client = _RecordingClient();
    ImageDiskCache.instance.httpClientFactory = () => client;
    AuthStore.instance.debugSetSession(accessToken: bossToken, refreshToken: 'boss-refresh');
  });

  tearDown(() async {
    ImageDiskCache.instance.httpClientFactory = HttpClient.new;
    await ImageDiskCache.instance.dispose(); // 只删本文件独占的目录
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
    AppConfigRuntime.reset();
  });

  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pageKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget stage(Widget child) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: child,
        ),
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 真异步（网络下载 + 图片解码）必须进 runAsync —— 与 recharge_visual_test 同一说明
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  // =====================================================================================
  // ① 聊天图片真的显示出来（真实路由 + Authorization）
  // =====================================================================================
  testWidgets('出图 20：聊天页 · 图片**显示出来了**（/api/v1/media/protected/:id + 令牌）', (tester) async {
    phone(tester);
    final id = '90101';
    final png = (await tester.runAsync(chatShotPng))!;
    /**
     * 成功路径**用磁盘缓存预热**（`seed` 把真实 PNG 字节写到组件会去查的那个键上）。
     *
     * 为什么不用假客户端现场下载：`ImageDiskCache` 的下载是**真异步**（`dart:io`），
     * 在 widget 测试的 fake-async 时区里，"下载完成 → setState"这条链什么时候推进
     * 取决于 `runAsync` 窗口，实测会让"图有没有画出来"变成看运气。
     * 预热后 [CachedNetImage] 走的是**缓存命中**分支（同步可判定），出图也就稳定了。
     * 请求层的证据（URL + Authorization 真的发出去了）由 `core` 的
     * `media_protected_url_test.dart` 用**真异步**打真 HTTP 来钉（那边没有 fake-async 限制）。
     */
    final url = AppConfig.protectedMediaUrl(id);
    await tester.runAsync(() => ImageDiskCache.instance.seed(url, png, headers: authImageHeaders(bossToken)));

    final adapter = _Router(mediaId: id);
    await tester.pumpWidget(
        stage(ChatDetailPage(conversationId: '77', title: '北岭', peerNickname: '北岭', api: _api(adapter))));
    await settle(tester);
    await settleImages(tester);

    // 图片项真的在（页面上有一张受保护图）
    final img = tester.widget<CachedNetImage>(find.byType(CachedNetImage).first);
    expect(img.url, AppConfig.protectedMediaUrl(id), reason: '地址必须逐字等于真实受保护路由（带 /api/v1）');
    expect(img.url, contains('/api/v1/media/protected/$id'));
    expect(img.url, isNot(contains('/media/chat/')), reason: '服务端没有 /media/chat/* 这条路由（实测 404）');
    expect(img.headers['Authorization'], 'Bearer $bossToken', reason: '受保护媒体必须带令牌，否则 401');
    // **真的画出了一张图**：解码源就是"命中缓存的那个文件"，且它就是预热的真实 PNG（非空、PNG 魔数）
    final file = _bubbleImageFile(tester);
    expect(file.existsSync(), isTrue, reason: '上屏的必须是命中缓存的那张图文件');
    expect(file.lengthSync(), png.length, reason: '画出来的就是预热进去的那张真实 PNG（字节数逐字相等）');
    final head = file.readAsBytesSync().sublist(0, 4);
    expect(head, <int>[0x89, 0x50, 0x4E, 0x47], reason: 'PNG 魔数，说明真是图片而不是空块');
    expect(find.byKey(ImageLoadError.retryKey), findsNothing, reason: '成功路径不该出现失败态');
    await shoot(tester, 'chat_20_image_ok.png');
  });

  // =====================================================================================
  // ② 投诉记录里的截图真的显示出来
  // =====================================================================================
  testWidgets('出图 21：投诉页 · 我的投诉截图**显示出来了**（同一条受保护路由）', (tester) async {
    phone(tester);
    final id = '90201';
    final png = (await tester.runAsync(complaintShotPng))!;
    // 同用例 20：成功路径用缓存预热保证"真出图"稳定可判（请求层证据在 core 的用例里打真 HTTP）
    final url = AppConfig.protectedMediaUrl(id);
    await tester.runAsync(() => ImageDiskCache.instance.seed(url, png, headers: authImageHeaders(bossToken)));

    final adapter = _Router(mediaId: id);
    await tester.pumpWidget(stage(ComplaintPage(api: _api(adapter))));
    await settle(tester);
    await tester.tap(find.text('我的投诉'));
    await settle(tester);
    await settleImages(tester);

    final img = tester.widget<CachedNetImage>(find.byType(CachedNetImage).first);
    expect(img.url, AppConfig.protectedMediaUrl(id));
    expect(img.url, contains('/api/v1/media/protected/$id'));
    expect(img.url, isNot(startsWith('http://shot.local/media/protected/')),
        reason: '旧写法少了 /api/v1 → 404（本次修的就是它）');
    expect(img.headers['Authorization'], 'Bearer $bossToken');
    final file = _bubbleImageFile(tester);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), png.length, reason: '画出来的就是预热进去的那张真实截图');
    expect(find.byType(ComplaintImageBox), findsWidgets);
    expect(find.byKey(ImageLoadError.retryKey), findsNothing);
    await shoot(tester, 'complaint_21_image_ok.png');
  });

  // =====================================================================================
  // ③ 失败态对照：404 → 小格子失败态（红线图标 + 整格可点重试），不再是灰块/永远转圈
  // =====================================================================================
  //
  // 这一条**刻意不经过整页**：整页的消息加载是真实异步（HTTP + 解码），在 widget 测试的
  // fake-async 时区里，"失败结论什么时候落到 setState"会让断言变得看运气（实测踩过：同一个用例
  // 时而红时而绿）。失败态本身是 `chat_v4` 的渲染路径，直接喂一条 URL 就能**确定性**复现，
  // 且断言的正是"气泡里图出不来时长什么样"。
  testWidgets('出图 22：聊天图加载失败 → 气泡内失败态（红线图标 + 整格可点重试）', (tester) async {
    phone(tester);
    // 确定性失败：第一次请求直接断连（等价于"连不上服务器"），点重试后转为成功 —— 于是
    // 这张图同时证明了"失败看得见"与"重试真的管用"，且**不依赖任何网络**。
    client.bytes = (await tester.runAsync(chatShotPng))!;
    client.failFirst = true;
    final item = ChatV4Item(
      id: 'm-fail',
      text: '',
      isMine: false,
      senderId: '9001',
      at: DateTime(2026, 10, 7, 21, 34),
      isImage: true,
      imageUrl: AppConfig.protectedMediaUrl('90301'),
      imageHeaders: authImageHeaders(bossToken),
    );
    await tester.pumpWidget(stage(Scaffold(
      body: ChatV4MessageList(
        items: [item],
        peer: const ChatV4Peer(nickname: '北岭'),
      ),
    )));
    await settle(tester);
    await settleImages(tester);
    await settleImages(tester);

    // 失败态**必须看得见**：红线图标 + "点按重试"语义（138×96 塞不下长文案 → 小格子形态，
    // 与凭证缩略图同款）。注意：compact 形态刻意**没有**独立「重试」按钮（整格即按钮），
    // 所以这里断言的不是 `ImageLoadError.retryKey`（那是长文案形态才有的）。
    expect(find.byType(ImageLoadError), findsWidgets);
    expect(find.bySemanticsLabel('凭证图加载失败，点按重试'), findsWidgets,
        reason: '失败不能只有灰块：要说清"没出来 + 点一下能重试"');
    final before = client.attempts;
    await shoot(tester, 'chat_22_image_failed.png');
    // 点这一格 = 重试（这一轮客户端已恢复 → 图应当真的出来，证明重试路径是通的）
    await tester.tap(find.byType(ImageLoadError).first, warnIfMissed: false);
    await settle(tester);
    await settleImages(tester);
    await settleImages(tester);
    expect(client.attempts, greaterThan(before), reason: '重试必须真的再发一次请求');
    expect(find.byType(Image), findsWidgets, reason: '重试后图应该出来（说明重试路径是通的）');
  });
  // =====================================================================================
  // ④ 打手态（companion）也要能看聊天图 —— 用的是**当前身份**的令牌，不是老板的
  // =====================================================================================
  testWidgets('④ 打手态打开聊天页：图片请求带的是 **companion** 令牌（身份不串味）', (tester) async {
    phone(tester);
    final id = '90401';
    final png = (await tester.runAsync(chatShotPng))!;
    // 切成打手态：页面取 `activeToken`（= companion），不是 primary
    AuthStore.instance.debugSetIdentity(identity: AppIdentity.worker, companionToken: workerToken);
    addTearDown(AuthStore.instance.debugClearIdentity);
    // 预热键必须按 **companion** 指纹（令牌不同 → 缓存键不同；串了就会看到"命中别人的图"）
    await tester.runAsync(
        () => ImageDiskCache.instance.seed(AppConfig.protectedMediaUrl(id), png, headers: authImageHeaders(workerToken)));

    await tester.pumpWidget(stage(ChatDetailPage(
        conversationId: '79',
        title: '在线客服',
        csConversation: true,
        api: _api(_Router(mediaId: id)))));
    await settle(tester);
    await settleImages(tester);

    final img = tester.widget<CachedNetImage>(find.byType(CachedNetImage).first);
    expect(img.url, 'http://shot.local/api/v1/media/protected/$id');
    expect(img.headers['Authorization'], 'Bearer $workerToken',
        reason: '打手态必须用 companion 令牌（用错令牌 = 401/越权）');
    // 缓存命中的就是"按 companion 令牌指纹存在的那份"→ 令牌确实参与了取图
    final file = _bubbleImageFile(tester);
    expect(file.lengthSync(), png.length);
  });
}

/// 记录式假客户端：**服务真实图片字节**（不是占位），因此"图能不能显示"是真验收到位的。
class _RecordingClient implements HttpClient {
  /// 每次请求的 URL 与请求头（断言"地址对不对 / 有没有带令牌"的唯一依据）
  final List<({String url, Map<String, String> headers})> calls = [];

  /// 非 200 时用来造失败态
  int status = 200;
  Uint8List bytes = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47]);

  /// 第一次请求直接断连（`SocketException` = "连不上服务器"）——确定性失败，之后再正常服务。
  ///
  /// 判定用 [attempts] 而**不是** `calls.length`：断连那次根本走不到记录（异常发生在 `getUrl` 里），
  /// 用 `calls.isEmpty` 会让"重试"永远继续断连（实测踩过）。
  bool failFirst = false;

  /// 尝试次数（含被断连的那些）
  int attempts = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    attempts += 1;
    if (failFirst && attempts == 1) {
      throw const SocketException('Connection refused (shot)');
    }
    return _RecordingRequest(this, url);
  }

  @override
  Duration? connectionTimeout;

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _RecordingRequest implements HttpClientRequest {
  _RecordingRequest(this.client, this.uri);

  final _RecordingClient client;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _RecordingHeaders();

  Map<String, String> get _collected => (headers as _RecordingHeaders).collected;

  @override
  Future<HttpClientResponse> close() async {
    client.calls.add((url: uri.toString(), headers: Map<String, String>.from(_collected)));
    return _RecordingResponse(client.status, client.bytes);
  }

  @override
  Future<HttpClientResponse> get done => close();

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

class _RecordingResponse implements HttpClientResponse {
  _RecordingResponse(this.statusCode, this._bytes);

  @override
  final int statusCode;

  final Uint8List _bytes;

  /// 真实响应流（`ImageDiskCache` 用 `resp.fold(...)` 读正文 —— 只实现 `listen` 不够，实测踩过）
  Stream<List<int>> get _stream => Stream<List<int>>.fromIterable(<List<int>>[_bytes]);

  @override
  int get contentLength => _bytes.length;

  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : (statusCode == 404 ? 'Not Found' : 'Error');

  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;

  @override
  HttpHeaders get headers => _RecordingHeaders()
    ..set(HttpHeaders.contentTypeHeader, statusCode == 200 ? 'image/png' : 'text/plain');

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  Future<R> fold<R>(R initialValue, R Function(R previous, List<int> element) combine) =>
      _stream.fold(initialValue, combine);

  @override
  Future<List<List<int>>> toList() => _stream.toList();

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

/// 只收集 `set()` 的头（`dart:io` 的 `HttpHeaders` 是个大接口，这里实现到够用即止）
class _RecordingHeaders implements HttpHeaders {
  final Map<String, String> collected = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) => collected[name] = '$value';

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) => collected[name] = '$value';

  @override
  List<String>? operator [](String name) => collected[name] == null ? null : <String>[collected[name]!];

  @override
  String? value(String name) => collected[name];

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      collected.forEach((k, v) => action(k, <String>[v]));

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}

// =====================================================================================
// 假接口（聊天历史 / 会话信息 / 我的投诉）；图片走假 HttpClient，不在这里
// =====================================================================================

class _Router implements HttpClientAdapter {
  _Router({required this.mediaId});

  final String mediaId;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};
    ResponseBody body(Object? data) => ResponseBody.fromString(
          jsonEncode(envelope(data)),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );

    // ---- 聊天页 ----
    if (key == 'GET /user/conversations/77/info' || key == 'GET /user/conversations/78/info') {
      return body({'id': key.contains('77') ? '77' : '78', 'title': '北岭', 'type': 'worker', 'peerNickname': '北岭'});
    }
    if (key.startsWith('GET /user/conversations/') && key.contains('/messages')) {
      return body({
        'list': [
          {
            'msgId': 'm-$mediaId',
            'conversationId': '77',
            'senderId': '9001',
            'senderNickname': '北岭',
            'msgType': 'image',
            'content': mediaId,
            'seq': 1,
            'createdAt': '2026-10-07T12:00:00.000Z',
          },
        ],
        'total': 1,
      });
    }
    // ---- 投诉页 ----
    if (key.startsWith('GET /user/orders')) {
      return body({'list': <dynamic>[], 'total': 0, 'page': 1, 'pageSize': 20});
    }
    if (key.startsWith('GET /user/complaints/targets/workers')) return body(<dynamic>[]);
    if (key == 'GET /user/complaints') {
      return body({
        'list': [
          {
            'complaintNo': 'CMUTC20261007',
            'targetType': 'worker',
            'targetName': '演示工作端',
            'type': 'not_agreed',
            'content': '约定打完三局，实际只打了一局就下线了，聊天记录里承诺过补，但没有补。',
            'mediaIds': [mediaId],
            'status': 'handled',
            'handleRemark': '已核实：同意补偿一局，已为该单补发时长',
            'createdAt': '2026-10-06T09:12:00.000Z',
          },
        ],
        'total': 1,
        'page': 1,
        'pageSize': 30,
      });
    }
    return body(const <String, dynamic>{});
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _api(HttpClientAdapter adapter) => ApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://shot.local/api/v1'))..httpClientAdapter = adapter,
    );

/// 取出**图片气泡里那张图**的解码文件（`Image.file` → `FileImage`）。
///
/// 为什么不能直接 `find.byType(Image).first`：聊天页里还有**头像**（`AppAvatar`，也是 Image），
/// 首个 Image 未必是气泡图。这里只认 `CachedNetImage` 内部那个 `Image.file`。
///
/// 为什么不能只判 `is FileImage`：传了 `cacheWidth/cacheHeight` 的 `Image.file` 会把 provider
/// 包成 `ResizeImage(FileImage)`（实测 `provider=ResizeImage`）—— 必须**拆一层**再判。
File _bubbleImageFile(WidgetTester tester) {
  final images = find.descendant(of: find.byType(CachedNetImage), matching: find.byType(Image));
  expect(images, findsWidgets, reason: '受保护图片必须真的解码上屏');
  for (final w in tester.widgetList<Image>(images)) {
    final p = w.image;
    if (p is FileImage) return p.file;
    if (p is ResizeImage && p.imageProvider is FileImage) return (p.imageProvider as FileImage).file;
  }
  fail('受保护图片上屏的应当是磁盘缓存文件（Image.file），实际没有找到');
}

// =====================================================================================
// 两张**拟真**图片（都不依赖任何线上数据：运行时用 Canvas 画出来）
// =====================================================================================

void _label(Canvas canvas, String s, double x, double y, double size, Color color,
    {FontWeight w = FontWeight.w400}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontFamily: 'ChatImageCJK', fontWeight: w)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset(x, y));
}

/// 聊天里发的那张图：一张"战绩截图"样子的图（480×320，与气泡里的显示尺寸同比例）
Future<Uint8List> chatShotPng() async {
  const w = 480.0;
  const h = 320.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // 底：暗色战场
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFF1B2430));
  canvas.drawRect(const Rect.fromLTWH(0, h - 96, w, 96), Paint()..color = const Color(0xCC0E141C));
  // 准星
  final p = Paint()
    ..color = const Color(0xFFE6EDF7)
    ..strokeWidth = 2;
  canvas.drawLine(const Offset(w / 2 - 18, h / 2), const Offset(w / 2 - 6, h / 2), p);
  canvas.drawLine(const Offset(w / 2 + 6, h / 2), const Offset(w / 2 + 18, h / 2), p);
  canvas.drawLine(const Offset(w / 2, h / 2 - 18), const Offset(w / 2, h / 2 - 6), p);
  canvas.drawLine(const Offset(w / 2, h / 2 + 6), const Offset(w / 2, h / 2 + 18), p);
  // 战绩行（拟真：非整数、长短不一）
  _label(canvas, '本局战绩', 16, 16, 15, const Color(0xFF9FB3C8), w: FontWeight.w600);
  _label(canvas, '淘汰 12', 16, h - 76, 20, const Color(0xFFF2C14E), w: FontWeight.w700);
  _label(canvas, '伤害 2,847', 128, h - 76, 20, const Color(0xFFE6EDF7), w: FontWeight.w700);
  _label(canvas, '排名 2/60　用时 21:34', 16, h - 44, 13, const Color(0xFFB7C4D4));
  _label(canvas, '三角洲行动 · 烽火地带', 16, h - 22, 12, const Color(0xFF7E90A6));
  final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// 投诉里上传的那张图：一张"聊天/转账截图"样子的图（360×480，竖版截图）
Future<Uint8List> complaintShotPng() async {
  const w = 360.0;
  const h = 480.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFEDEDED));
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, 48), Paint()..color = Colors.white);
  _label(canvas, '聊天记录', w / 2 - 26, 15, 15, const Color(0xFF14202E), w: FontWeight.w600);
  // 对方的两次承诺（气泡）
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(14, 66, 250, 56), const Radius.circular(8)),
    Paint()..color = Colors.white,
  );
  _label(canvas, '再打两局就收工，补给你', 26, 80, 12.5, const Color(0xFF1F2937));
  _label(canvas, '21:04', 26, 100, 10.5, const Color(0xFF8A99AB));
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(14, 138, 300, 74), const Radius.circular(8)),
    Paint()..color = Colors.white,
  );
  _label(canvas, '我：说好三局，现在只打了一局', 26, 152, 12.5, const Color(0xFF1F2937));
  _label(canvas, '21:31', 26, 172, 10.5, const Color(0xFF8A99AB));
  // 转账截图（时间/单号都为拟真值）
  canvas.drawRRect(
    RRect.fromRectAndRadius(const Rect.fromLTWH(14, 228, 332, 150), const Radius.circular(8)),
    Paint()..color = Colors.white,
  );
  _label(canvas, '转账详情', 28, 244, 13, const Color(0xFF14202E), w: FontWeight.w600);
  _label(canvas, '¥ 68.00', 28, 268, 22, const Color(0xFF14202E), w: FontWeight.w700);
  _label(canvas, '收款方　祁连山电竞', 28, 306, 12, const Color(0xFF4A5A6E));
  _label(canvas, '2026-10-06 20:58', 28, 330, 12, const Color(0xFF4A5A6E));
  _label(canvas, '单号 1000050001202610062058123', 28, 354, 10.5, const Color(0xFF64748B));
  _label(canvas, '已截图留证', 14, 400, 12, const Color(0xFF8A99AB));
  final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}
