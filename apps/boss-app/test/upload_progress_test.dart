/// 编辑资料的上传（2026-10-06 上传体验专项）：**压缩参数 + 真实进度 + 中文失败 + 可重试**。
///
/// 这条链路上原来有三个坑（都在本轮修掉，本文件逐条钉住）：
///   ① 压缩太松（背景 2000/80、头像 800/85）→ 弱网上传时间长；
///   ② 上传只有一个无限转圈（弱网 16KB/s 下 0.3–1MB 要 20 秒~1 分钟，用户以为卡死）；
///   ③ `uploadMedia()` 每次 new 一个 Dio（新连接池 → 每次重付 TLS 握手）。
///
/// 测试口径（为什么这样测才有效）：
///   - **压缩参数**：`ImagePicker` 最终落到 `ImagePickerPlatform.instance.getImageFromSource(...
///     maxWidth/maxHeight/imageQuality ...)` —— 假实现能**逐字**拿到 App 传下去的参数，
///     所以"压缩有没有真的收紧"是可断言的（而不是靠读代码）。
///   - **真实进度**：注入 [ImagePickerPlatform] 假实现 + 把 `ApiClient.sharedDio` 的
///     adapter 换成假实现（并**在假实现里真的调用 `options.onSendProgress`**）——
///     于是 `uploadMedia → MediaUploadTile` 这条链是真跑的，包括节流与百分比口径。
///   - **连接池复用**：直接断言 `ApiClient.sharedDio` 在这次上传里被用到（而不是新 Dio）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:boss_app/pages/edit_profile_page.dart';

/// 假选图器：记录 App 传下来的压缩参数，返回**内存里的**假图片。
///
/// ⚠️ 为什么不用临时文件（实测踩过）：widget 测试的 fake-async 下
/// `XFile.readAsBytes()` 这类**真异步文件 IO** 永远不会完成 —— 测试会挂到超时
/// （`tester.runAsync` 里跑才行，但那等于绕过被测的那条路径）。
/// `XFile.fromData(...)` 让 `readAsBytes()` 直接返回内存字节，既不挂、也更贴近
/// "ImagePicker 已经把文件读出来了"的真实时序。
class _FakePicker extends ImagePickerPlatform {
  final List<({double? maxWidth, double? maxHeight, int? quality})> calls =
      <({double? maxWidth, double? maxHeight, int? quality})>[];

  Uint8List? bytes;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    calls.add((maxWidth: options.maxWidth, maxHeight: options.maxHeight, quality: options.imageQuality));
    final Uint8List? b = bytes;
    if (b == null) return null;
    return XFile.fromData(b, name: 'probe.jpg', mimeType: 'image/jpeg');
  }
}

/// 假上传通道：返回结果 / 抛错。
///
/// 进度**不在这里伪造**：进度由 Dio 在 multipart 请求体流上真实驱动
/// （本适配器消费请求体，Dio 就按已消费字节回调 `onSendProgress`）——
/// 所以用例里断言的"已传/总大小"是真实读数，而不是我编的一个数。
class _UploadAdapter implements HttpClientAdapter {
  _UploadAdapter({
    this.statusCode = 201,
    this.failWith,
  });

  final int statusCode;

  /// 非 null → 直接抛这个异常（模拟连不上/超时）
  final DioExceptionType? failWith;

  int fetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetches += 1;
    // 消费请求体（真实 Dio 也会把它发出去）→ 进度回调随之触发
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    final DioExceptionType? fail = failWith;
    if (fail != null) {
      throw DioException(requestOptions: options, type: fail);
    }
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{'id': 'media-9', 'mimeType': 'image/jpeg'},
      }),
      statusCode,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 假资料接口（PUT /user/profile 与 /auth/me 之外的最小面）
class _ProfileAdapter implements HttpClientAdapter {
  _ProfileAdapter(this.upload);

  final _UploadAdapter upload;
  final List<String> requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    if (options.path.contains('/media/upload')) {
      return upload.fetch(options, requestStream, cancelFuture);
    }
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{}}),
      200,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _FakePicker picker;
  late Uint8List jpegBytes;
  late HttpClientAdapter originalAdapter;

  setUpAll(() {
    // 1×1 的真实 JPEG（magic 正确、可解码；服务端白名单/解码都吃得下）
    jpegBytes = Uint8List.fromList(const <int>[
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
      0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
      0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
      0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20,
      0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
      0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
      0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0xC4, 0x00, 0x14,
      0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x37, 0xFF, 0xD9,
    ]);
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'primary-token',
      me: AuthMe.fromJson(const <String, dynamic>{
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
        'level': 1,
      }),
    );
    picker = _FakePicker()..bytes = jpegBytes;
    // 上传走的是 **ApiClient.sharedDio**（这正是"复用连接池"的实现）→
    // 只换它的 adapter，其余（超时/头部/拦截器）保持生产配置。
    originalAdapter = ApiClient.sharedDio.httpClientAdapter;
  });

  tearDown(() {
    ApiClient.sharedDio.httpClientAdapter = originalAdapter;
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 收尾（两个必须做的事）：
  ///   1. 排掉 `AppToast` 的 2 秒自动消失定时器 —— 否则被测框架判
  ///      "A Timer is still pending even after the widget tree was disposed"；
  ///   2. 把上传页持有的 [MediaUploadState] 收掉（它排了慢网提示定时器）。
  ///      慢网提示读**真实墙钟**，所以假时钟推 20 秒也不会让它触发（只是把定时器排空）。
  Future<void> drainToast(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    AppToast.dismiss();
    // 把 dio 连接池的 idle 定时器排空（sharedDio 的 idleTimeout/连接回收）
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 10));
    }
    for (final String key in <String>['bg-upload-tile', 'avatar-upload-tile']) {
      final Finder f = find.byKey(Key(key));
      if (f.evaluate().isNotEmpty) {
        tester.widget<MediaUploadTile>(f).state.dispose();
      }
    }
    // 把整棵树拆掉 → 页面 dispose() 会收掉自己排的定时器
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  /// 取进度条右侧那行「已传/总大小 · 速度」的文本
  String byteLabelOf(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((Text t) => t.data ?? '')
      .firstWhere((String d) => d.contains(' · ') && (d.contains('B') || d.contains('KB')), orElse: () => '');

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: EditProfilePage()));
    await settle(tester, frames: 8);
  }

  testWidgets('上传链路自检：内存 XFile 的字节能被读到（XFile.fromData）', (tester) async {
    final XFile f = XFile.fromData(jpegBytes, name: 'p.jpg');
    final Uint8List bytes = await f.readAsBytes();
    expect(bytes.length, jpegBytes.length);
  });

  // ==========================================================================
  // ① 压缩参数收紧（逐字断言传给平台的值）
  // ==========================================================================
  group('① 压缩再收紧一档', () {
    testWidgets('头像：maxWidth 800/85 → **640/80**', (tester) async {
      final _UploadAdapter upload = _UploadAdapter();
      ApiClient.sharedDio.httpClientAdapter = _ProfileAdapter(upload);
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.byIcon(Icons.camera_alt));
      await settle(tester);

      expect(picker.calls, hasLength(1));
      expect(picker.calls.single.maxWidth, 640, reason: '头像宽度收到 640');
      expect(picker.calls.single.quality, 80, reason: '头像质量 85 → 80');
      expect(upload.fetches, 1, reason: '选完图要真的上传');
      await drainToast(tester);
    });

    testWidgets('背景：maxWidth 2000/80 → **1600/72**', (tester) async {
      final _UploadAdapter upload = _UploadAdapter();
      ApiClient.sharedDio.httpClientAdapter = _ProfileAdapter(upload);
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.text('更换个人背景'));
      await settle(tester, frames: 20);

      expect(picker.calls, hasLength(1));
      expect(picker.calls.single.maxWidth, 1600, reason: '背景宽度 2000 → 1600');
      expect(picker.calls.single.quality, 72, reason: '背景质量 80 → 72');
      expect(upload.fetches, 1);
      await drainToast(tester);
    });

    testWidgets('用户取消选图（平台返回 null）→ 不发请求、不报错', (tester) async {
      final _UploadAdapter upload = _UploadAdapter();
      ApiClient.sharedDio.httpClientAdapter = _ProfileAdapter(upload);
      picker.bytes = null; // 取消
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.byIcon(Icons.camera_alt));
      await settle(tester);

      expect(upload.fetches, 0, reason: '取消不该产生任何上传');
      expect(tester.takeException(), isNull);
    });
  });

  // ==========================================================================
  // ② 真实进度（百分比 + 速度 + 已传/总大小）
  // ==========================================================================
  group('② 上传进度上屏', () {
    testWidgets('上传中：出现「背景 上传中 x%」+ 已传/总大小 + 速度（**真实链路**）', (tester) async {
      // 响应挂住不返回 → 界面停在"上传中"这一态（请求体已真的发完）
      final Completer<void> hold = Completer<void>();
      final _UploadAdapter upload = _UploadAdapter();
      ApiClient.sharedDio.httpClientAdapter = _HoldingAdapter(upload, hold);
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.text('更换个人背景'));
      await settle(tester, frames: 12);

      expect(find.textContaining('背景 上传中'), findsWidgets, reason: '上传中必须有百分比文案');
      expect(find.byType(LinearProgressIndicator), findsWidgets, reason: '进度条');
      /**
       * 进度数字是**真的**：`uploadMedia` 的 `onSendProgress` 由 Dio 的 multipart
       * 请求体流自己驱动（本文件的假 adapter 只负责"挂住响应"，不伪造进度）——
       * 所以这里断言的是"屏幕上的读数与真实字节数一致"，而不是我编的一个数。
       */
      final String label = byteLabelOf(tester);
      expect(label, isNotEmpty, reason: '必须显示"已传 / 总大小"');
      final RegExpMatch? m = RegExp(r'^(.+?) / (.+)$').firstMatch(label.split(' · ').first);
      expect(m, isNotNull, reason: '格式形如 `401 B / 401 B`，实际：$label');
      expect(m!.group(1), m.group(2), reason: '小文件一帧发完 → 已传 == 总大小');
      expect(find.textContaining('%'), findsWidgets);
      expect(label.contains('/s') || label.contains('-'), isTrue, reason: '速度（>0 时是 x/s，取整为 0 时是 -）');

      hold.complete();
      await settle(tester, frames: 12);
      // 完成后进度条收起、给成功提示
      expect(find.textContaining('背景 上传中'), findsNothing, reason: '成功后进度条必须收起');
      await drainToast(tester);
    });

    testWidgets('已传超过阈值 → 出现「当前网络较慢，正在上传 x%」', (tester) async {
      final Completer<void> hold = Completer<void>();
      final _UploadAdapter upload = _UploadAdapter();
      ApiClient.sharedDio.httpClientAdapter = _HoldingAdapter(upload, hold);
      ImagePickerPlatform.instance = picker;

      // 阈值压到 400ms（生产恒 15 秒，见 kMediaUploadSlowAfter）—— 必须在 `begin()`
      // **之前**设：定时器是按开始那一刻的阈值排的。
      MediaUploadSlowHint.debugAfter = const Duration(milliseconds: 400);
      addTearDown(() => MediaUploadSlowHint.debugAfter = null);

      await pumpPage(tester);
      await tester.tap(find.text('更换个人背景'));
      // 只推进 200ms：还在阈值内 → 不该提示慢网（负向：不做无病呻吟）
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('上传中'), findsWidgets, reason: '上传中状态');
      expect(find.textContaining('网络较慢'), findsNothing, reason: '未到阈值不该提示慢网');

      /**
       * 越过阈值（假时钟直接推）→ 定时器回调必须让提示上屏。
       *
       * 这条同时钉住"慢网提示为什么必须由定时器驱动"：慢网时十几秒没有一帧进度回调，
       * 光靠"下次进度到来时重建"永远等不到提示（此前实测：推 16 秒后界面仍是旧一帧）。
       */
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester, frames: 4);

      expect(
        tester.widget<MediaUploadTile>(find.byKey(const Key('bg-upload-tile'))).state.slow,
        isTrue,
        reason: '越过阈值后状态要置位',
      );
      expect(find.textContaining('当前网络较慢，正在上传'), findsOneWidget,
          reason: '弱网下必须有一行"在传但慢"的明确信号（消灭无限转圈的观感）');
      expect(find.textContaining('当前网络较慢，正在上传 100%'), findsOneWidget,
          reason: '提示里带当前百分比（具体可验证，不是"请稍候"）');

      hold.complete();
      await settle(tester, frames: 16);
      await drainToast(tester);
    });
  });

  // ==========================================================================
  // ③ 失败：中文原因 + 可重试（不重新选图）
  // ==========================================================================
  group('③ 上传失败', () {
    testWidgets('连不上 → 中文提示 + 「重新上传背景」；点重试**不重新选图**且能成功', (tester) async {
      final _UploadAdapter failing = _UploadAdapter(failWith: DioExceptionType.connectionError);
      final _ProfileAdapter first = _ProfileAdapter(failing);
      ApiClient.sharedDio.httpClientAdapter = first;
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.text('更换个人背景'));
      await settle(tester);

      expect(find.textContaining('连不上服务器'), findsOneWidget, reason: '失败必须是中文可读的原因');
      expect(find.text('重新上传背景'), findsOneWidget, reason: '必须给出重试入口');
      expect(picker.calls, hasLength(1), reason: '失败后还没重试 → 只选过一次图');

      // 重试：网络恢复
      final _UploadAdapter ok = _UploadAdapter();
      ApiClient.sharedDio.httpClientAdapter = _ProfileAdapter(ok);
      await tester.tap(find.text('重新上传背景'));
      await settle(tester, frames: 20);

      expect(picker.calls, hasLength(1), reason: '「重新上传」用的是上次那份字节，**不重新弹选图**');
      expect(ok.fetches, 1);
      expect(find.text('重新上传背景'), findsNothing, reason: '成功后重试按钮消失');
      expect(find.text('背景已更新'), findsOneWidget, reason: '成功提示');
      await drainToast(tester);
    });

    testWidgets('上传超时 → 提示切到与电脑同一 WiFi（弱网可执行的动作）', (tester) async {
      final _UploadAdapter failing = _UploadAdapter(failWith: DioExceptionType.sendTimeout);
      ApiClient.sharedDio.httpClientAdapter = _ProfileAdapter(failing);
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.byIcon(Icons.camera_alt));
      await settle(tester);

      expect(find.textContaining('上传超时'), findsOneWidget);
      expect(find.textContaining('WiFi'), findsOneWidget);
      expect(find.text('重新上传头像'), findsOneWidget);
      await drainToast(tester);
    });

    testWidgets('服务端明确拒绝（业务码非 0）→ 用服务端中文原文', (tester) async {
      final _UploadAdapter rejecting = _UploadAdapter(statusCode: 400);
      ApiClient.sharedDio.httpClientAdapter = _RejectingAdapter(rejecting, '只支持图片类型（jpg/png/webp）');
      ImagePickerPlatform.instance = picker;

      await pumpPage(tester);
      await tester.tap(find.byIcon(Icons.camera_alt));
      await settle(tester);

      expect(find.text('只支持图片类型（jpg/png/webp）'), findsOneWidget);
      expect(find.text('重新上传头像'), findsOneWidget);
      await drainToast(tester);
    });
  });
}

/// **让响应挂住不返回**（把界面钉在"上传中"这一态）。
///
/// 进度不在这里伪造：消费掉请求体就会让 Dio 自己回调真实进度（已传 = 真实字节数），
/// 这里只负责"响应还没回来"。
class _HoldingAdapter implements HttpClientAdapter {
  _HoldingAdapter(this.inner, this.hold);

  final _UploadAdapter inner;
  final Completer<void> hold;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    inner.fetches += 1;
    if (requestStream != null) await requestStream.drain<void>();
    await hold.future;
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{'id': 'media-9', 'mimeType': 'image/jpeg'},
      }),
      201,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 返回 HTTP 400 + 业务中文 message（模拟服务端白名单拒绝）
class _RejectingAdapter implements HttpClientAdapter {
  _RejectingAdapter(this.upload, this.message);

  final _UploadAdapter upload;
  final String message;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    upload.fetches += 1;
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(<String, dynamic>{'code': 400, 'message': message, 'data': null}),
      400,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}
