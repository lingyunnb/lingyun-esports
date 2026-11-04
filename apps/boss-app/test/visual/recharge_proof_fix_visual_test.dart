import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/settings_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 出图：① 凭证图**真的显示出来**（带 `/api/v1` 前缀的新地址）② 失败态（中文原因 + 重试）
/// ③ 「我的 → 设置 → 诊断」里的版本行 `v<版本名>（<版本码>）`
///
/// ## 这三张图各自要证明什么
///
/// 1. `recharge_10_proof_ok.png` —— **事故本体**：凭证大图真的画出来了。
///    地址必须逐字等于 `AppConfig.resolveMediaUrl('/api/v1/recharge/proof/9')`
///    （少一段前缀时，这个断言与图一起红）。
/// 2. `recharge_11_proof_failed.png` —— **让用户能自己判断**：图出不来时给中文原因 + 「重试」，
///    而不是永远转圈。用假 `HttpClient`（`ImageDiskCache.httpClientFactory`）确定性地造出
///    "连不上服务器"，因此这张图在任何机器上都可复现，不依赖真实网络。
/// 3. `settings_12_version.png` —— 版本行上屏（`v1.11.29（85）`，值来自注入，不是写死）。
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（`msyh` 放最前，与仓库既有出图脚本同一做法），
/// 否则中文是豆腐块、图标是方块，等于没验收。
void main() {
  const cjk = 'RechargeCJK';
  const pageKey = Key('shot-page');
  const adminTokenValue = 'recharge-token';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
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

  tearDown(() {
    // 假客户端用完即还原（同进程还有其它出图用例）
    ImageDiskCache.instance.httpClientFactory = HttpClient.new;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  setUp(() {
    // **跨用例的接口缓存必须清掉**：`ApiCache` 的键不含 query，
    // 上一个用例缓存的 `/recharge/requests` 会被下一个用例直接命中 →
    // 拿到的是上一个用例的凭证地址（实测：失败态用例因此永远看不到失败）。
    ApiCache.instance.clear();
  });

  /// 出图。[target] 指向某个 widget 时，**就地往上找最近的 RepaintBoundary** 再截图
  /// （这样能只截"这张卡片"，又不必把卡片从 Material/约束里抠出来单挂 —— 那样会布局报错）。
  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2, Finder? target}) async {
    await tester.runAsync(() async {
      final Finder boundaryFinder = target == null
          ? find.byKey(pageKey)
          : find.ancestor(of: target, matching: find.byType(RepaintBoundary)).first;
      final boundary = tester.renderObject<RenderRepaintBoundary>(boundaryFinder);
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget stage(Widget page) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: page,
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

  /// 让图片真的解码出来（真异步必须进 runAsync；见 recharge_visual_test 的同一说明）
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 拟真转账凭证（微信账单卡片样式；与既有出图脚本同一套画法）
  Future<Uint8List> proofPng() async {
    const w = 440.0;
    const h = 600.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFEDEDED));

    void text(String s, double x, double y, double size, Color color, {FontWeight weight = FontWeight.w400}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontFamily: cjk, fontWeight: weight)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
    }

    canvas.drawRect(const Rect.fromLTWH(0, 0, w, 56), Paint()..color = Colors.white);
    text('账单详情', w / 2 - 28, 18, 17, const Color(0xFF14202E), weight: FontWeight.w700);
    canvas.drawRect(const Rect.fromLTWH(16, 72, w - 32, 104), Paint()..color = Colors.white);
    text('转账金额', 36, 92, 12, const Color(0xFF4A5A6E));
    text('¥ 68.00', 36, 112, 26, const Color(0xFF14202E), weight: FontWeight.w700);
    text('已收款', w - 110, 118, 13, const Color(0xFF0E7C7B), weight: FontWeight.w600);
    canvas.drawRect(const Rect.fromLTWH(16, 190, w - 32, 250), Paint()..color = Colors.white);
    text('付款方', 36, 212, 12, const Color(0xFF4A5A6E));
    text('麻药', w - 120, 212, 13, const Color(0xFF14202E));
    text('收款方', 36, 252, 12, const Color(0xFF4A5A6E));
    text('祁连山电竞', w - 150, 252, 13, const Color(0xFF14202E));
    text('转账时间', 36, 292, 12, const Color(0xFF4A5A6E));
    text('2026-10-07 12:34', w - 210, 292, 13, const Color(0xFF14202E));
    text('转账单号', 36, 332, 12, const Color(0xFF4A5A6E));
    text('1000050001202610071234567', 36, 360, 12.5, const Color(0xFF14202E));
    canvas.drawRect(const Rect.fromLTWH(16, 456, w - 32, 96), Paint()..color = Colors.white);
    text('备注', 36, 476, 12, const Color(0xFF4A5A6E));
    text('充值 68 元，请核对后发放积分', 36, 500, 13, const Color(0xFF14202E));

    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  Future<void> enterAdmin() async {
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.admin,
      adminToken: adminTokenValue,
      adminMe: RechargeAdminMe.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }),
    );
    await AuthStore.instance.switchToAdmin();
  }

  // =====================================================================================
  // ① 凭证大图真的显示出来（新地址 = 带 /api/v1）
  // =====================================================================================
  testWidgets('出图 10：审核详情 · 付款凭证图**显示出来了**（新地址 /api/v1/recharge/proof/9）', (tester) async {
    phone(tester);
    final router = _Router('9');
    final proof = await tester.runAsync(proofPng);
    // 与页面**同源**的地址才可能命中磁盘缓存（这就是"两边一起错还一直绿"的那个坑）
    final url = router.proofUrl();
    await tester.runAsync(
        () => ImageDiskCache.instance.seed(url, proof!, headers: proofImageHeaders(adminTokenValue)));
    await enterAdmin();
    await tester.pumpWidget(stage(RechargeAdminShell(api: api(router))));
    await settle(tester);
    await tester.tap(find.text('详情').first);
    await settle(tester);
    await settleImages(tester);

    expect(find.text('审核详情'), findsOneWidget);
    final big = tester
        .widgetList<CachedNetImage>(find.descendant(
          of: find.byKey(RechargeReviewDetailPage.proofKey),
          matching: find.byType(CachedNetImage),
        ))
        .single;
    // 逐字断言（旧写法只有 endsWith → 少一段前缀照样绿，正是本次事故漏掉的那一类）
    expect(big.url, router.proofUrl());
    expect(big.url, contains('/api/v1/recharge/proof/9'), reason: '前缀 /api/v1 必须真的在地址里');
    expect(find.descendant(of: find.byKey(RechargeReviewDetailPage.proofKey), matching: find.byType(Image)),
        findsWidgets);
    // 失败态**不**出现（图真的出来了）
    expect(find.byKey(ImageLoadError.retryKey), findsNothing);
    await shoot(tester, 'recharge_10_proof_ok.png');
  });

  // =====================================================================================
  // ② 失败态：中文原因 + 「重试」（确定性复现：假 HttpClient 直接断连）
  // =====================================================================================
  testWidgets('出图 11：凭证图加载失败 → 中文原因 + 「重试」（不再无限转圈）', (tester) async {
    phone(tester);
    // 确定性造失败：连不上服务器（任何机器上结果一致，不依赖网络）
    ImageDiskCache.instance.httpClientFactory = () => _DeadClient();
    final router = _Router('11');
    await enterAdmin();
    await tester.pumpWidget(stage(RechargeAdminShell(api: api(router))));
    await settle(tester);
    await tester.tap(find.text('详情').first);
    await settle(tester);
    await settleImages(tester);

    // 详情大图：中文原因 + 重试按钮
    expect(find.byKey(ImageLoadError.retryKey), findsOneWidget);
    final text = tester.widget<Text>(find.byKey(ImageLoadError.textKey)).data ?? '';
    expect(text, startsWith('凭证图加载失败（'));
    expect(text.contains('连不上服务器'), isTrue, reason: '必须说清是连不上，而不是只给个转圈');
    expect(find.text('重试'), findsOneWidget);

    // 点重试 = 真的再来一次（这里仍然断连 → 失败态保持，但按钮可点、有反馈）
    await tester.tap(find.byKey(ImageLoadError.retryKey));
    await settle(tester);
    await settleImages(tester);
    expect(find.byKey(ImageLoadError.retryKey), findsOneWidget);
    await shoot(tester, 'recharge_11_proof_failed.png');

    // 列表缩略图：紧凑失败态（整格可点重试）—— 返回列表再拍一张
    //（这页头是自绘的 AppPageHeader，没有 BackButton，直接 pop 路由）
    final ctx = tester.element(find.byType(RechargeReviewDetailPage));
    Navigator.of(ctx).pop();
    await settle(tester);
    await settleImages(tester);
    expect(find.byType(RechargeProofThumb), findsOneWidget);
    expect(find.bySemanticsLabel('凭证图加载失败，点按重试'), findsOneWidget,
        reason: '缩略图不许继续转圈：必须给出"没出来 + 可点重试"');
    await shoot(tester, 'recharge_11b_thumb_failed.png');
  });

  // =====================================================================================
  // ③ 设置页版本行（注入假版本值 → 断言渲染的就是注入值）
  // =====================================================================================
  testWidgets('出图 12：设置 · 诊断 · 当前版本 v1.11.29（85）', (tester) async {
    phone(tester);
    AppConfigRuntime.reset();
    AppConfigRuntime.apply(
      api: 'https://example.test/api/v1',
      ws: 'https://example.test',
      from: 'bootstrap',
      bootstrapFrom: 'self-hosted',
      latencyMs: 18,
      candidateCount: 3,
    );
    addTearDown(AppConfigRuntime.reset);

    await tester.pumpWidget(stage(const SettingsPage(versionOverride: 'v1.11.29（85）')));
    await settle(tester);

    // 版本行上屏 = **注入值**（真实构建里由 --dart-define 注入，页面不写死）
    expect(find.text('当前版本'), findsOneWidget);
    final versionText = tester.widget<Text>(find.text('v1.11.29（85）')).data ?? '';
    expect(versionText, 'v1.11.29（85）', reason: '必须逐字渲染出注入的版本（含全角括号与码）');
    expect(find.text('v1.11.29（85）'), findsOneWidget);
    // 真实默认值来自构建期注入；测试进程里是兜底值，但**格式**必须是同一套
    expect(AppConfig.versionLine, matches(RegExp(r'^v\d+\.\d+\.\d+（\d+）$')));

    // 只截"诊断"这两行的卡片（版本号看得清），不带整屏：
    // 就地往上找最近的 RepaintBoundary（卡片自己在 ListView 里，约束/材质都还活着）
    await shoot(tester, 'settings_12_version.png', target: find.text('当前版本'));
  });
}

/// 假服务器：只喂这一屏要用的字段（与 recharge_visual_test 的 _Router 同源简化）
class _Router implements HttpClientAdapter {
  _Router(this.reqId);

  /// 本用例用的申请 id（**每个出图用例不同** —— 磁盘缓存按 URL 分文件，
  /// 复用同一个 id 会让失败态用例直接命中上一张成功图，永远测不到失败；实测踩过）
  final String reqId;

  /// 凭证地址：带全局前缀 `/api/v1`（服务端真实路由；少写它就是本次事故）
  String proofUrl() => AppConfig.resolveMediaUrl('/api/v1/recharge/proof/$reqId');

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

    if (key == 'GET /recharge/requests') {
      return body({
        'list': [
          {
            'id': reqId,
            'nickname': '麻药',
            'uid': 'U8471209365',
            'amountYuan': 68,
            'points': 68,
            'proofMediaId': '201',
            'proofUrl': '/api/v1/media/protected/201',
            'note': '微信转账，付款人昵称与账号一致',
            'createdAt': '2026-10-07T12:34:00Z',
            'status': 'pending',
          },
        ],
        'total': 1,
      });
    }
    if (key == 'GET /recharge/me') {
      return body({
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 1,
        'expiresIn': 43200,
      });
    }
    if (key.contains('/recharge/requests/$reqId')) {
      return body({'id': reqId, 'status': 'pending', 'points': 680});
    }
    return body(const <String, dynamic>{});
  }

  @override
  void close({bool force = false}) {}
}

ApiClient api(HttpClientAdapter adapter) => ApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = adapter,
    );

/// 断连假客户端：`getUrl` 直接抛 `SocketException`（等价于"连不上服务器"）
class _DeadClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => throw const SocketException('Connection refused (shot)');

  @override
  Duration? connectionTimeout;

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName} 用不到');
}
