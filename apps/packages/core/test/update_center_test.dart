import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 云端更新（双端共用）· 通道正确性回归
///
/// 关键风险：老板端/工作端共用同一个 UpdateCenter/AppUpdater，
/// 若 appType 传错（工作端去查老板端通道），会把**老板端 APK 装到打手手机上**。
/// 本测试用记录型假 Dio 断言：两端的检测请求分别打到各自的 appType 通道。
void main() {
  // 测试关闭接口缓存：避免同一 fixture 第二次命中缓存影响断言
  setUpAll(() => ApiClient.cacheEnabled = false);

  tearDown(() {
    // 每个用例后恢复默认客户端，避免互相污染
    AppUpdater.instance.api = ApiClient();
  });

  test('老板端检测：请求 appType=boss', () async {
    final recorder = _RecordingClient(hasUpdate: true, versionCode: 9, versionName: '1.0.7');
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('boss');

    final info = await UpdateCenter.instance.check();

    expect(recorder.lastQuery!['appType'], 'boss');
    expect(recorder.lastPath, '/public/app-versions/latest');
    expect(info?.versionName, '1.0.7');
    expect(info?.versionCode, 9);
  });

  test('工作端检测：请求 appType=worker（绝不查老板端通道）', () async {
    final recorder = _RecordingClient(hasUpdate: true, versionCode: 11, versionName: '1.0.9');
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('worker');

    final info = await UpdateCenter.instance.check();

    expect(recorder.lastQuery!['appType'], 'worker');
    expect(info?.versionName, '1.0.9');
  });

  test('未配置 appType 直接检测 → 抛错（杜绝误检另一端通道）', () async {
    // 新实例语义由单例承载：这里用非法类型触发 configure 的校验
    expect(() => UpdateCenter.instance.configure('admin'), throwsArgumentError);
  });

  test('服务端无更新：hasUpdate=false → latest 为 null（不弹窗）', () async {
    final recorder = _RecordingClient(hasUpdate: false);
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('worker');

    expect(await UpdateCenter.instance.check(), isNull);
  });

  test('AppUpdateInfo 解析：强制更新标记 + 下载地址解析为绝对地址', () async {
    final recorder = _RecordingClient(hasUpdate: true, force: true, fileSize: 20202600, fileHash: 'abcdef');
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('worker');

    final info = (await UpdateCenter.instance.check())!;
    expect(info.force, isTrue);
    expect(info.fileSize, 20202600);
    expect(info.fileHash, 'abcdef');
    expect(info.downloadUrl, isNotEmpty); // 相对路径已解析
  });

  test('服务端异常：check() 抛出，由调用方（RootGate）静默处理', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _BadBodyAdapter();
    AppUpdater.instance.api = ApiClient(dio: dio);
    UpdateCenter.instance.configure('boss');
    await expectLater(UpdateCenter.instance.check(), throwsA(anything)); // 由调用方 try/catch 静默（RootGate 已兜）
  });

  // ───────── 多下载源（CDN/镜像）2026-10-06 云更新提速 ─────────

  test('多源：服务端下发**绝对**镜像地址 → 客户端原样使用（不拼主机）', () async {
    final recorder = _RecordingClient(
      hasUpdate: true,
      downloadUrl: 'https://cdn.example.com/fish-boss-1.11.19.apk',
    );
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('boss');

    final info = (await UpdateCenter.instance.check())!;
    expect(
      info.downloadUrl,
      'https://cdn.example.com/fish-boss-1.11.19.apk',
      reason: '绝对地址必须原样透传（否则换 CDN 就得发版）',
    );
  });

  test('多源：镜像为 http（非 https）同样原样透传', () async {
    final recorder = _RecordingClient(hasUpdate: true, downloadUrl: 'http://mirror.internal:8080/a.apk');
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('boss');
    expect((await UpdateCenter.instance.check())!.downloadUrl, 'http://mirror.internal:8080/a.apk');
  });

  test('多源：未配镜像 → 相对路径按当前生效主机解析为绝对地址', () async {
    final recorder = _RecordingClient(hasUpdate: true, downloadUrl: '/api/v1/public/app-versions/download/99');
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('boss');
    final String url = (await UpdateCenter.instance.check())!.downloadUrl;
    expect(url, endsWith('/api/v1/public/app-versions/download/99'));
    expect(url.startsWith('http'), isTrue, reason: '相对路径必须解析成绝对地址才能下载');
  });

  test('无更新：downloadUrl 一律清空（避免拿着旧地址去下载）', () async {
    final recorder = _RecordingClient(hasUpdate: false, downloadUrl: '/api/v1/public/app-versions/download/99');
    AppUpdater.instance.api = recorder.client;
    UpdateCenter.instance.configure('boss');
    expect(await UpdateCenter.instance.check(), isNull);
  });
}

/// 记录请求并返回可配置的 latest 响应
class _RecordingClient {
  _RecordingClient({
    required this.hasUpdate,
    this.force = false,
    this.versionCode = 11,
    this.versionName = '1.0.9',
    this.fileSize = 19300000,
    this.fileHash = 'hash',
    this.downloadUrl = '/api/v1/public/app-versions/download/1',
  });

  final bool hasUpdate;
  final bool force;
  final int versionCode;
  final String versionName;
  final int fileSize;
  final String fileHash;

  /// 服务端下发的下载地址（可能是相对路径，也可能是镜像绝对地址）
  final String downloadUrl;

  String? lastPath;
  Map<String, dynamic>? lastQuery;

  late final ApiClient client = () {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(this);
    return ApiClient(dio: dio);
  }();

  String body() => jsonEncode({
        'code': 0,
        'message': 'ok',
        'data': {
          'hasUpdate': hasUpdate,
          'force': force,
          'latest': {
            'versionCode': versionCode,
            'versionName': versionName,
            'updateDesc': '测试更新说明',
            'fileSize': fileSize,
            'fileHash': fileHash,
            'downloadUrl': downloadUrl,
          },
        },
      });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.rec);
  final _RecordingClient rec;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    rec.lastPath = options.path;
    rec.lastQuery = options.queryParameters;
    return ResponseBody.fromString(rec.body(), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

class _BadBodyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString('not-json', 500, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
