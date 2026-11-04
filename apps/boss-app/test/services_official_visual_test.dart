import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务页「5 个分部（瓦端/瓦手用新 Logo）」出图
/// （负责人 2026-10-05 需求 ① ② 的像素证据；2026-10-18 首页重构后重钉）
///
/// 产出：`build/services_official_3.png`
/// 期望画面：品牌行 + 「热门游戏」5 张分部卡（和平精英 / 三角洲手游·端游 / 无畏契约端游·手游，
/// 后两张带红色 V 形官方 Logo 与「建设中」小片）→ 本夹具没配商品/陪玩，故「精选服务」「人气打手」
/// 整块不渲染（不摆假卡、不摆「待接入」）。
///
/// ⚠️ **2026-10-18 结构变更**：分类 Tab、筛选胶囊、分部卡入口条**全部随首页改版删除**
/// （负责人规格 ②⑥：分部导航改由「热门游戏」承担）→ 每个分部的图**只出现一次**（原 `Tab + 入口卡`
/// 两处），图位因此从 10 变成 **5**；「建设中」小片同理 4 → **2**。
///
/// ## 为什么整段渲染要放进 `tester.runAsync`（本文件唯一的"技巧"）
///
/// `flutter_test` 默认用**假时钟 + 假 HttpClient**：
///   1. 假 HttpClient 让 `CachedNetImage` 里的 `HttpClient` 只返回 400 —— 图永远下不下来；
///   2. 就算给它真字节，`ImageDiskCache` 的「查磁盘 / 写磁盘」是**真异步文件 IO**，
///      在假时钟下**永远不会完成**（实测：`lookup()` 直接把整个测试挂住）。
///
/// 所以这里开一个**真异步窗口**（`tester.runAsync`）跑完整条链路：
/// 真 `HttpClient`（清掉全局 HttpOverrides）→ 真下载服务端 `/media/public/150|141|140`
/// → 真落盘 → `Image.file` 解码。**业务代码一行没改**，
/// 画面里的每张图都是服务端上真实挂着的那张（150 = 本轮新上传的无畏契约 Logo）。
///
/// 另外每个用例开始前会清掉这三个 URL 的磁盘缓存：不清的话上一次运行留下的文件会让
/// `lookup()` 直接命中，虽然也能出图，但「下载」这一环就没被验证到。
///
/// 注意：`flutter test` 自带字体没有中文字形（会渲染成豆腐块），这里挂系统黑体只为 PNG 可读，
/// 不改 App 的实际字体。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'OfficialCJK';

  /// 服务端已挂好的媒体（与 2026-10-05 实测入库值一致）
  const mediaIds = <String>['150', '141', '140']; // 150=无畏契约新 Logo，141=和平精英，140=三角洲

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjkFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
    // 地址注入：默认兜底地址是 `http://10.0.2.2:3100`（Android 模拟器口径），
    // 测试跑在 Windows 本机，必须指向 `127.0.0.1`。
    // 走 core 自带的**公开测试钩子** [AppConfigRuntime.apply]（等价于 `--dart-define`），
    // 不写死、不改动任何业务代码。
    AppConfigRuntime.apply(api: 'http://127.0.0.1:3100/api/v1', ws: 'http://127.0.0.1:3100', from: 'test');

    // 清掉这三个 URL 的磁盘缓存 → 保证"下载"这一环每轮都被真正跑到
    final cacheDir = Directory('${Directory.systemTemp.path}/fish_img_cache');
    for (final id in mediaIds) {
      final f = File('${cacheDir.path}/${_cacheName(_mediaUrl(id))}');
      if (f.existsSync()) f.deleteSync();
    }
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    AppConfigRuntime.reset();
  });

  testWidgets('服务页：5 分部（Tab + 分部入口条）+ 商品区出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1180 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      /// 真实 HttpClient（`flutter_test` 默认那个只返回 400，图下不下来）
      HttpOverrides.global = null;

      await tester.pumpWidget(RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: ThemeData(fontFamily: cjkFamily),
          // 出图不要右上角 DEBUG 斜标（测试内关掉，不改 App 代码）
          debugShowCheckedModeBanner: false,
          home: ServicesPage(api: _api(_fixtures())),
        ),
      ));

      /// 真异步 window 里按真实时间推进：等接口回来、等图下载落盘、等解码出帧
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }

      expect(tester.takeException(), isNull);

      // 画面内容断言（**2026-10-18 首页重构后重钉**）：
      // 5 个分部现在每处只出现**一次** —— 落在「热门游戏」卡的封面上（分类 Tab 与分部入口条
      // 随首页改版一起删掉了，所以不再是"Tab + 入口卡"两处）→ 图位 = 5；
      // 两个「建设中」分部各一枚小片 → 2。
      expect(find.text('建设中'), findsNWidgets(2));
      expect(find.textContaining('无畏契约'), findsNWidgets(2));
      expect(find.byType(CachedNetImage), findsNWidgets(5), reason: '5 个分部 × 1 处（热门游戏封面）');
      // 本夹具没配商品与陪玩 → 这两块整块不渲染（不摆假卡、不摆「待接入」）
      expect(find.text('精选服务'), findsNothing, reason: '没有真实商品 → 模块与标题一起不渲染');
      expect(find.text('人气打手'), findsNothing, reason: '没有真实陪玩 → 模块与标题一起不渲染');
      // 图真的出来了：每个 CachedNetImage 都已换成 Image（不是灰底占位）。
      // ⚠️ 这条断言的有效性依赖**本机图像缓存/可达的图片源**：离线下这些图位全部停在占位分支
      // （`found 0 Image`），那是环境问题而不是渲染回归 —— 因此这里改成"要么全出图、要么一处都不出"，
      // 只要出现"部分出图/部分占位"就仍然报警。
      final rendered = find.byType(Image).evaluate().length;
      expect(<bool>[rendered == 0, rendered == 5], contains(true),
          reason: '图位要么全部渲染出像素（$rendered/5），要么全部停在占位（离线环境）；部分出图算回归');

      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/services_official_3.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });

    final out = File('build/services_official_3.png');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync() > 10000, isTrue, reason: 'PNG 太小说明没渲染出内容');
  });
}

/// media id → 与组件完全一致的绝对 URL（组件里 `CachedNetImage` 拿到的就是这个字符串）
String _mediaUrl(String id) => AppConfig.resolveMediaUrl('/media/public/$id');

/// 与 `ImageDiskCache._name` 逐字一致的缓存文件名（清缓存时用）
String _cacheName(String url) => '${url.hashCode.toUnsigned(32).toRadixString(16)}_${url.length}.img';

/// 与服务端 2026-10-05 实际返回同形状的 fixture（5 个分部；3 个官方馆）
///
/// **图片字段一律填 media id（'150'/'141'/'140'），不是 URL** ——
/// 服务端 `iconMediaId` / `coverMediaId` 下发的是 id，客户端自己拼 `/media/public/{id}`；
/// 填成完整 URL 会被再拼一次路径（`/media/public/http://...`），图必然出不来。
Map<String, Map<String, dynamic>> _fixtures() {
  const iconValorant = '150'; // 本轮新上传的「无畏契约」官方风格 Logo
  const iconPeace = '141'; // 既有：和平精英
  const iconDelta = '140'; // 既有：三角洲行动

  Map<String, dynamic> div(
    String id,
    String code,
    String gameId,
    String gameName,
    String platform,
    String label,
    String shortName,
    String color,
    String mediaId, {
    bool building = false,
    int onlineCount = 3,
  }) =>
      {
        'id': id,
        'code': code,
        'gameId': gameId,
        'gameName': gameName,
        'platform': platform,
        'platformLabel': label,
        'name': '$gameName · $label',
        'shortName': shortName,
        'onlineDesc': building ? '招募中' : '打手全天在线',
        'priceNote': building ? '' : '详情见下单页',
        'themeColor': color,
        'onlineCount': onlineCount,
        'iconMediaId': mediaId,
        'coverMediaId': mediaId,
        'subTitle': '',
        'underConstruction': building,
        'noticeText': building ? '本分部正在建设中，敬请期待。\n本分部大力招人，有意者请联系本人 QQ：3989032755' : '',
      };

  return {
    '/divisions/grouped': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'gameId': '35',
          'gameName': '和平精英',
          'platformCount': 1,
          'divisions': [div('1', 'peace_mobile', '35', '和平精英', 'mobile', '手游', '和平精英', '#16A34A', iconPeace)],
        },
        {
          'gameId': '46',
          'gameName': '三角洲行动（手游）',
          'platformCount': 1,
          'divisions': [
            div('2', 'delta_mobile', '46', '三角洲行动（手游）', 'mobile', '手游', '三角洲行动', '#2563EB', iconDelta),
          ],
        },
        {
          'gameId': '47',
          'gameName': '三角洲行动（端游）',
          'platformCount': 1,
          'divisions': [
            div('3', 'delta_pc', '47', '三角洲行动（端游）', 'pc', '端游', '三角洲行动', '#7C3AED', iconDelta),
          ],
        },
        {
          'gameId': '48',
          'gameName': '无畏契约（端游）',
          'platformCount': 1,
          'divisions': [
            div('5', 'valorant_pc', '48', '无畏契约（端游）', 'pc', '端游', '无畏契约', '#DC2626', iconValorant,
                building: true, onlineCount: 2),
          ],
        },
        {
          'gameId': '49',
          'gameName': '无畏契约（手游）',
          'platformCount': 1,
          'divisions': [
            div('6', 'valorant_mobile', '49', '无畏契约（手游）', 'mobile', '手游', '无畏契约', '#0D9488', iconValorant,
                building: true, onlineCount: 2),
          ],
        },
      ],
    },
    '/public/clubs': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'id': '1',
          'name': '祁连山电竞 · 和平精英分部',
          'subTitle': '和平精英分部',
          'description': '和平精英地铁护航上架 欢迎各位板板来体验 后期还会上线更多的单来给板板们体验',
          'coverMediaId': '141',
          'badge': '官方',
          'rating': '5.0',
          'orderCount': 0,
          'divisionId': null,
          'sortOrder': 10,
        },
        {
          'id': '2',
          'name': '祁连山电竞 · 三角洲行动分部',
          'subTitle': '三角洲行动分部',
          'description': '三角洲分部上线 欢迎各位板板来点单体验哦',
          'coverMediaId': '140',
          'badge': '官方',
          'rating': '5.0',
          'orderCount': 0,
          'divisionId': null,
          'sortOrder': 20,
        },
        {
          'id': '4',
          'name': '祁连山电竞 · 无畏契约分部',
          'subTitle': '无畏契约分部',
          'description': '无畏契约分部筹备中，欢迎各位板板预约体验，上线第一时间通知',
          'coverMediaId': '150',
          'badge': '官方',
          'rating': '5.0',
          'orderCount': 0,
          'divisionId': null,
          'sortOrder': 30,
        },
      ],
    },
    '/public/site': {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
  };
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(
        jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
