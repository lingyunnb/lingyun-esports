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

/// 服务页顶部欢迎文案出图（负责人 2026-10-04 指定文案后的人眼复核）
///
/// 与 `ai_entry_visual_test.dart` 同一用途：① 渲染烟雾（布局/溢出异常在这里抛出）；
/// ② 产出可读像素证据：`build/services_headline.png`（整屏）+ `build/services_headline_top_zoom.png`（顶部 2 倍放大）。
///
/// 注意：`flutter test` 自带字体**没有中文字形**（会渲染成豆腐块），所以这里挂一份系统黑体，
/// 只为让 PNG 里的中文可读；不改 App 的实际字体。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'HeadlineCJK';

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
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
  });

  testWidgets('服务页顶栏（品牌字标 + 20dp 搜索图标）出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: ServicesPage(api: _api()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 【方案 G 2026-10-17】顶栏 = 左「祁连山电竞」字标 + 右侧 20dp 搜索图标
    // （原「欢迎文案 + 24 位在线」那一行随首页结构改版整块移除；
    //  负责人指定原文仍以常量形式保留在 `ServicesPage.headlineText`，见 services_page_test 的断言）
    final brand = find.text('${ServicesPage.brandInkText}${ServicesPage.brandAccentText}');
    expect(brand, findsOneWidget);
    expect(tester.renderObject<RenderParagraph>(brand).didExceedMaxLines, isFalse, reason: '字标不许被截断');
    final search = find.byWidgetPredicate((w) => w is AppIcon && w.icon == AppIcons.search);
    expect(search, findsOneWidget, reason: '搜索图标（20dp）');
    expect(tester.widget<AppIcon>(search).size, 20);

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('build/services_headline.png').writeAsBytesSync(bytes!.buffer.asUint8List());

      // 顶部区域 2 倍放大：肉眼确认折行行数、行距、右侧在线数不与文案重叠
      const src = Rect.fromLTWH(0, 0, 780, 300);
      const zoom = 2.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(0, 0, src.width * zoom, src.height * zoom),
        Paint()..filterQuality = FilterQuality.high,
      );
      final zoomed = await recorder
          .endRecording()
          .toImage((src.width * zoom).round(), (src.height * zoom).round());
      final zbytes = await zoomed.toByteData(format: ui.ImageByteFormat.png);
      File('build/services_headline_top_zoom.png').writeAsBytesSync(zbytes!.buffer.asUint8List());
      image.dispose();
      zoomed.dispose();
    });
  });
}

ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(const {
    '/public/clubs': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'id': '1',
          'name': '祁连山电竞 · 和平精英分部',
          'subTitle': '和平精英分部',
          'description': '全段位上分与护航',
          'coverMediaId': null,
          'badge': '官方',
          'rating': '4.9',
          'orderCount': 2847,
          'divisionId': '1',
        },
      ],
    },
    '/divisions/grouped': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'gameId': '35',
          'gameName': '和平精英',
          'platformCount': 1,
          'divisions': [
            {
              'id': '1',
              'code': 'peace_mobile',
              'gameId': '35',
              'gameName': '和平精英',
              'platform': 'mobile',
              'platformLabel': '手游',
              'name': '和平精英 · 手游',
              'shortName': '和平精英',
              'onlineDesc': '平均 3 分钟内接单',
              'priceNote': '按局计费',
              'themeColor': '#16A34A',
              'sortOrder': 10,
              'onlineCount': 12,
            },
          ],
        },
        {
          'gameId': '36',
          'gameName': '三角洲行动',
          'platformCount': 2,
          'divisions': [
            {
              'id': '2',
              'code': 'delta_mobile',
              'gameId': '36',
              'gameName': '三角洲行动',
              'platform': 'mobile',
              'platformLabel': '手游',
              'name': '三角洲行动 · 手游',
              'shortName': '三角洲行动',
              'onlineDesc': '平均 5 分钟内接单',
              'themeColor': '#2563EB',
              'sortOrder': 20,
              'onlineCount': 8,
            },
            {
              'id': '3',
              'code': 'delta_pc',
              'gameId': '36',
              'gameName': '三角洲行动',
              'platform': 'pc',
              'platformLabel': '端游',
              'name': '三角洲行动 · 端游',
              'shortName': '三角洲行动',
              'onlineDesc': '平均 6 分钟内接单',
              'themeColor': '#7C3AED',
              'sortOrder': 30,
              'onlineCount': 4,
            },
          ],
        },
      ],
    },
    '/public/home': {
      'code': 0,
      'message': 'ok',
      'data': {
        'clubTitle': '和平精英分部',
        'clubParagraphs': ['手游全段位上分与护航；客服 9:00-次日 2:00 在线'],
      },
    },
  });
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
