import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/division_construction_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 分部「建设中」出图（负责人 2026-10-05：瓦端 / 瓦手）
///
/// 与 `services_headline_visual_test.dart` 同一用途：① 渲染烟雾（布局/溢出在这里抛）；
/// ② 产出可读像素证据，放在 `build/`：
///    - `build/services_divisions_5.png`：服务页（5 个分部 = 1 通栏 + 2 行半宽卡，含 2 个「建设中」标识）
///    - `build/division_under_construction.png`：建设中页（分部名 + 雪山标 + 服务端下发的招人文案）
///
/// 注意：`flutter test` 自带字体没有中文字形（会渲染成豆腐块），这里挂系统黑体只为 PNG 可读，
/// 不改 App 的实际字体。
void main() {
  const captureKey = Key('capture');
  const cjkFamily = 'ConstructionCJK';

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

  Future<void> shoot(WidgetTester tester, String file) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$file').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('服务页 5 个分部（含瓦端/瓦手「建设中」标识）出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: ServicesPage(api: _api(_fixtures())),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 【负责人 2026-10-17】分部卡列表也带「建设中」小片 → 2 个建设中分部 × 2 处（Tab + 分部卡）= 4
    expect(find.text('建设中'), findsNWidgets(4));
    expect(find.text('无畏契约'), findsNWidgets(2));

    await shoot(tester, 'services_divisions_5.png');
  });

  testWidgets('建设中页（服务端文案，含 QQ 号）出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 780 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        theme: ThemeData(fontFamily: cjkFamily),
        home: const DivisionUnderConstructionPage(
          name: '无畏契约 · 端游',
          shortName: '无畏契约',
          platform: 'pc',
          platformLabel: '端游',
          gameKey: 'valorant_pc 无畏契约（端游）',
          themeColor: '#DC2626',
          noticeText: '本分部正在建设中，敬请期待。\n本分部大力招人，有意者请联系本人 QQ：3989032755',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      contains('3989032755'),
    );

    await shoot(tester, 'division_under_construction.png');
  });
}

/// 与服务端实际返回同形状的 fixture（5 个分部：3 旧 + 瓦端 + 瓦手，后两个建设中）
Map<String, Map<String, dynamic>> _fixtures() => {
      '/public/clubs': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '1',
            'name': '祁连山电竞 · 官方自营',
            'subTitle': '平台直营',
            'description': '和平精英与三角洲行动全段位上分与护航',
            'coverMediaId': null,
            'badge': '官方',
            'rating': null,
            'orderCount': 0,
            'divisionId': null,
          },
        ],
      },
      '/public/site': {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
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
                'themeColor': '#16A34A',
                'sortOrder': 10,
                'onlineCount': 6,
                'underConstruction': false,
              },
            ],
          },
          {
            'gameId': '46',
            'gameName': '三角洲行动（手游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '2',
                'code': 'delta_mobile',
                'gameId': '46',
                'gameName': '三角洲行动（手游）',
                'platform': 'mobile',
                'platformLabel': '手游',
                'name': '三角洲行动 · 手游',
                'shortName': '三角洲行动',
                'onlineDesc': '平均 5 分钟内接单',
                'themeColor': '#2563EB',
                'sortOrder': 20,
                'onlineCount': 4,
                'underConstruction': false,
              },
            ],
          },
          {
            'gameId': '47',
            'gameName': '三角洲行动（端游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '3',
                'code': 'delta_pc',
                'gameId': '47',
                'gameName': '三角洲行动（端游）',
                'platform': 'pc',
                'platformLabel': '端游',
                'name': '三角洲行动 · 端游',
                'shortName': '三角洲行动',
                'onlineDesc': '平均 6 分钟内接单',
                'themeColor': '#7C3AED',
                'sortOrder': 30,
                'onlineCount': 2,
                'underConstruction': false,
              },
            ],
          },
          {
            'gameId': '48',
            'gameName': '无畏契约（端游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '5',
                'code': 'valorant_pc',
                'gameId': '48',
                'gameName': '无畏契约（端游）',
                'platform': 'pc',
                'platformLabel': '端游',
                'name': '无畏契约 · 端游',
                'shortName': '无畏契约',
                'onlineDesc': '招募中',
                'themeColor': '#DC2626',
                'sortOrder': 40,
                'onlineCount': 0,
                'underConstruction': true,
                'noticeText': '本分部正在建设中，敬请期待。\n本分部大力招人，有意者请联系本人 QQ：3989032755',
              },
            ],
          },
          {
            'gameId': '49',
            'gameName': '无畏契约（手游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '6',
                'code': 'valorant_mobile',
                'gameId': '49',
                'gameName': '无畏契约（手游）',
                'platform': 'mobile',
                'platformLabel': '手游',
                'name': '无畏契约 · 手游',
                'shortName': '无畏契约',
                'onlineDesc': '招募中',
                'themeColor': '#0D9488',
                'sortOrder': 50,
                'onlineCount': 0,
                'underConstruction': true,
                'noticeText': '本分部正在建设中，敬请期待。\n本分部大力招人，有意者请联系本人 QQ：3989032755',
              },
            ],
          },
        ],
      },
    };

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
