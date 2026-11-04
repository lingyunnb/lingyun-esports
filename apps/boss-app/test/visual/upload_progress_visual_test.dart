/// 出图（2026-10-06 上传体验专项）：**上传中（带百分比）** 与 **诊断行显示当前地址（LAN/隧道）**。
///
/// 产出（`apps/boss-app/build/`）：
///   1. `upload_1_progress.png` —— 编辑资料页上传背景**进行中**：
///      百分比（`背景 上传中 62%`）+ 已传/总大小 + 速度 + 进度条（**不再是一个无限转圈**）
///   2. `upload_2_slow.png`     —— 慢网态：额外出现「当前网络较慢，正在上传 62%」
///      （弱网下"在传但慢"的明确信号）
///   3. `upload_3_failed.png`   —— 失败态：中文原因 + 「重新上传背景」按钮
///   4. `upload_4_diag_lan.png` —— 设置页诊断行：`192.168.1.145:3100 · LAN · lan 9ms`
///   5. `upload_5_diag_tunnel.png` —— 对照：隧道地址 `… · 隧道 · bootstrap+probe`
///
/// 数据全部**注入**（假 adapter + 内存 XFile），与线上目录无关 —— 负责人随时改数据都不会让出图失败。
///
/// ⚠️ 中文与 Material 图标都要手动挂字体（`flutter test` 自带字体没有 CJK 字形，
/// 不挂会变豆腐块）—— 见本项目既有出图脚本的既有做法。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:boss_app/pages/edit_profile_page.dart';
import 'package:boss_app/pages/settings_page.dart';

const String cjk = 'UploadShotCJK';

/// 假选图器（内存字节，避免真文件 IO 在 fake-async 下挂住）
class _ShotPicker extends ImagePickerPlatform {
  _ShotPicker(this.bytes);

  final Uint8List bytes;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async =>
      XFile.fromData(bytes, name: 'bg.jpg', mimeType: 'image/jpeg');
}

/// 假上传通道。
///
/// 关键点：**请求体真的被分块消费**（`onSendProgress` 是 Dio 在请求体流上驱动出来的），
/// 只有这样"上传中 x%"才是真实读数、也才能把界面**停在中间某一帧**（出图用）。
///
/// 读满 [pauseAfterChunks] 块就挂住不读 → 进度停在那一档（响应也还没回）。
class _ShotUpload implements HttpClientAdapter {
  _ShotUpload({
    this.hold,
    this.fail = false,
    this.pauseAfterBytes = 0,
    this.chunk = 512,
  });

  final Completer<void>? hold;
  final bool fail;

  /// 读满这么多字节就暂停（0 = 不暂停，读完全部）→ 界面停在那一档进度
  final int pauseAfterBytes;
  final int chunk;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) {
      final Stream<List<int>> chunks = requestStream.map((Uint8List b) => b.cast<int>());
      if (pauseAfterBytes > 0) {
        int sent = 0;
        await for (final List<int> c in chunks) {
          sent += c.length;
          if (sent >= pauseAfterBytes) break; // 停止读取 → 进度停在当前档位
        }
        final Completer<void>? h = hold;
        if (h != null && !h.isCompleted) await h.future;
      } else {
        await chunks.drain<void>();
      }
    }
    final Completer<void>? h = hold;
    if (h != null && !h.isCompleted && pauseAfterBytes == 0) await h.future;
    if (fail) {
      throw DioException(requestOptions: options, type: DioExceptionType.connectionError);
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{'id': 'm1', 'mimeType': 'image/jpeg'},
      }),
      201,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final boundary = Key('upload-shot');
  late HttpClientAdapter originalAdapter;
  late Uint8List jpegBytes;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final String path in const <String>[
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final File f = File(path);
      if (!f.existsSync()) continue;
      final FontLoader loader = FontLoader(cjk)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final String iconPath in const <String>[
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf',
    ]) {
      final File f = File(iconPath);
      if (!f.existsSync()) continue;
      final FontLoader loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    // 真图片 fixture（`test/fixtures/upload-probe.jpg`，15.3KB 高噪声 JPEG）：
    // 用它才能让请求体**分多块**被消费 → 进度回调有中间帧。
    // `readAsBytesSync` 是同步读，fake-async 下不会挂住（异步 `readAsBytes` 会，实测踩过）。
    jpegBytes = File('test/fixtures/upload-probe.jpg').readAsBytesSync();
    expect(jpegBytes.length, greaterThan(10000), reason: 'fixture 必须真的存在且有一定大小');
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    AppToast.dismiss();
    ApiCache.instance.clear();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'primary-token',
      me: AuthMe.fromJson(const <String, dynamic>{
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
        'level': 3,
      }),
    );
    originalAdapter = ApiClient.sharedDio.httpClientAdapter;
  });

  tearDown(() {
    ApiClient.sharedDio.httpClientAdapter = originalAdapter;
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
    AppConfigRuntime.reset();
  });

  Future<void> shoot(WidgetTester tester, Key key, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final RenderRepaintBoundary b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final ui.Image image = await b.toImage(pixelRatio: ratio);
      final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> settle(WidgetTester tester, {int frames = 24}) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 收尾：先让上传**真的结束**（否则在飞的 HTTP 请求会留下连接池定时器），
  /// 再拆树（`EditProfilePage.dispose` 收掉慢网定时器），最后把 dio 的 idle 定时器排空。
  ///
  /// 出图用例拍了图就结束，若不收尾会被测框架判
  /// "A Timer is still pending even after the widget tree was disposed"。
  Future<void> teardownShot(WidgetTester tester, {Completer<void>? hold}) async {
    AppToast.dismiss();
    hold?.complete();
    await settle(tester, frames: 30);
    await tester.pumpWidget(const SizedBox.shrink());
    for (int i = 0; i < 24; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Widget stage(Key k, Widget child) => RepaintBoundary(
        key: k,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: child,
        ),
      );

  // =====================================================================================
  // 出图 1 / 2：上传中（百分比）、慢网
  // =====================================================================================
  testWidgets('出图 1：上传背景中（百分比 + 速度 + 已传/总大小）', (tester) async {
    phone(tester);
    final Completer<void> hold = Completer<void>();
    ApiClient.sharedDio.httpClientAdapter = _ShotUpload(hold: hold, pauseAfterBytes: 12288, chunk: 512);
    ImagePickerPlatform.instance = _ShotPicker(jpegBytes);

    await tester.pumpWidget(stage(boundary, const EditProfilePage()));
    await settle(tester, frames: 8);
    await tester.tap(find.text('更换个人背景'));
    await settle(tester, frames: 10);
    expect(find.textContaining('背景 上传中'), findsWidgets, reason: '先确认真的停在上传态');

    /**
     * 定格到 55% —— 真实进度由 Dio 在请求体流上驱动，而请求体是**一口气推完**的
     * （哪怕 260KB 也只在一帧内走完），中间帧在 widget 测试里抓不到。
     * 进度链路本身（单调不减 / 节流 / 真实字节数 / 慢网）由 core 与 boss 的用例句断言，
     * 这张图只负责"界面长什么样"。
     */
    // ignore: avoid_dynamic_calls
    (tester.state(find.byType(EditProfilePage)) as dynamic).debugSetUploadProgress(0.55);
    await settle(tester, frames: 4);

    expect(find.textContaining('背景 上传中 55%'), findsOneWidget, reason: '截图必须落在"上传中 55%"这一态');
    await shoot(tester, boundary, 'upload_1_progress.png');
    await teardownShot(tester, hold: hold);
  });

  testWidgets('出图 2：慢网态（当前网络较慢，正在上传 x%）', (tester) async {
    phone(tester);
    MediaUploadSlowHint.debugAfter = const Duration(milliseconds: 200);
    addTearDown(() => MediaUploadSlowHint.debugAfter = null);
    final Completer<void> hold = Completer<void>();
    ApiClient.sharedDio.httpClientAdapter = _ShotUpload(hold: hold, pauseAfterBytes: 12288, chunk: 512);
    ImagePickerPlatform.instance = _ShotPicker(jpegBytes);

    await tester.pumpWidget(stage(boundary, const EditProfilePage()));
    await settle(tester, frames: 8);
    await tester.tap(find.text('更换个人背景'));
    await settle(tester, frames: 10);
    // 定格 55% + 慢网态（阈值已压到 200ms，且真的越过了一次定时器回调）
    // ignore: avoid_dynamic_calls
    (tester.state(find.byType(EditProfilePage)) as dynamic).debugSetUploadProgress(0.55, slow: true);
    await settle(tester, frames: 4);

    expect(find.textContaining('当前网络较慢，正在上传'), findsOneWidget, reason: '慢网提示必须上屏');
    await shoot(tester, boundary, 'upload_2_slow.png');
    await teardownShot(tester, hold: hold);
  });

  // =====================================================================================
  // 出图 3：上传失败（中文原因 + 重试）
  // =====================================================================================
  testWidgets('出图 3：上传失败（中文原因 + 「重新上传背景」）', (tester) async {
    phone(tester);
    ApiClient.sharedDio.httpClientAdapter = _ShotUpload(fail: true);
    ImagePickerPlatform.instance = _ShotPicker(jpegBytes);

    await tester.pumpWidget(stage(boundary, const EditProfilePage()));
    await settle(tester, frames: 8);
    await tester.tap(find.text('更换个人背景'));
    await settle(tester, frames: 12);

    await shoot(tester, boundary, 'upload_3_failed.png');
    await settle(tester, frames: 8);
    await teardownShot(tester);
  });

  // =====================================================================================
  // 出图 4 / 5：诊断行（LAN / 隧道）
  // =====================================================================================
  testWidgets('出图 4：诊断行显示局域网直连（LAN）', (tester) async {
    phone(tester);
    // 直接写运行期地址槽：模拟"局域网优先生效"之后的真实状态
    AppConfigRuntime.apply(
      api: 'http://192.168.1.145:3100/api/v1',
      ws: 'http://192.168.1.145:3100',
      from: 'lan',
      latencyMs: 9,
      candidateCount: 3,
    );
    await tester.pumpWidget(stage(boundary, const SettingsPage()));
    await settle(tester, frames: 10);
    expect(find.textContaining('LAN'), findsWidgets, reason: '诊断行必须标出 LAN');
    await shoot(tester, boundary, 'upload_4_diag_lan.png');
    await teardownShot(tester);
  });

  testWidgets('出图 5：诊断行显示隧道（对照）', (tester) async {
    phone(tester);
    AppConfigRuntime.apply(
      api: 'https://vista-bind-archives-components.trycloudflare.com/api/v1',
      ws: 'https://vista-bind-archives-components.trycloudflare.com',
      from: 'bootstrap+probe',
      bootstrapFrom: 'self-hosted',
      latencyMs: 1188,
      candidateCount: 2,
    );
    await tester.pumpWidget(stage(boundary, const SettingsPage()));
    await settle(tester, frames: 10);
    expect(find.textContaining('隧道'), findsWidgets, reason: '诊断行必须标出隧道');
    await shoot(tester, boundary, 'upload_5_diag_tunnel.png');
    await teardownShot(tester);
  });

  // =====================================================================================
  // 出图 6：接单大厅 · 分部加载失败态（失败不再静默）
  // =====================================================================================
  testWidgets('出图 6：接单大厅分部加载失败（中文提示 + 重试，不再是空屏）', (tester) async {
    phone(tester);
    enterWorkerState();
    ApiClient.cacheEnabled = false;
    addTearDown(() => ApiClient.cacheEnabled = true);

    // 分部权限 500（会话被吊销的典型表现），大厅本身 200（辅助失败不影响内容）
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://shot.local/api/v1'))
      ..httpClientAdapter = _HallFailAdapter();
    await tester.pumpWidget(stage(boundary, Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: IdentityWorkerHallPage(api: ApiClient(dio: dio)),
    )));
    await settle(tester, frames: 20);

    expect(find.textContaining('分部列表加载失败'), findsOneWidget, reason: '失败必须让人看见');
    expect(find.text('重试'), findsOneWidget, reason: '必须给出下一步');
    await shoot(tester, boundary, 'upload_6_hall_division_error.png');
    await teardownShot(tester);
  });
}

/// 大厅出图用假通道：`/worker/division-permissions` 500，其余 200（+ 一条待接单）
class _HallFailAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    Object body;
    if (options.path.contains('division-permissions')) {
      body = <String, dynamic>{'code': 500, 'message': '登录已过期，请重新登录', 'data': null};
    } else if (options.path.contains('order-hall')) {
      body = <String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'list': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': '9101',
              'orderNo': 'F202610060009101',
              'productName': '三角洲行动 · 烽火地带 护航 3 局',
              'quantityText': '1',
              'amountText': '128.00',
              'divisionId': '2',
              'createdAt': DateTime.now().subtract(const Duration(minutes: 12)).toIso8601String(),
            },
          ],
          'total': 1,
        },
      };
    } else {
      body = <String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': <Object>[]}};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      body is Map && body['code'] == 500 ? 500 : 200,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 进入打手态（与 `hall_switch_visual_test.dart` 同一口径）
void enterWorkerState() {
  AuthStore.instance.debugSetIdentity(
    identity: AppIdentity.worker,
    companionToken: 'companion-token',
    companionRefreshToken: 'companion-refresh',
    status: IdentityBindingStatus.fromJson(<String, dynamic>{
      'bound': true,
      'activeCount': 1,
      'maxPerBoss': 1,
      'bindings': <Map<String, dynamic>>[
        <String, dynamic>{
          'bindingId': '77',
          'status': 'active',
          'worker': <String, dynamic>{
            'workerNo': 'W20260118',
            'nickname': '王野',
            'workerStatus': 1,
          },
        },
      ],
    }),
  );
}
