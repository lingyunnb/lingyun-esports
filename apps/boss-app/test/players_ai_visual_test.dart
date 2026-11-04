import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:boss_app/pages/players_page.dart';
import 'package:boss_app/services/ai_recommend_service.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 找陪玩 × 祁小山 出图复核（人眼那一道关）：把真机尺寸的找陪玩页渲染成 PNG 落到 `build/`
///
/// 与 `ai_entry_visual_test.dart` 同一用途：① 渲染烟雾（布局/溢出异常在这里抛出来）；
/// ② 给负责人看真实像素：`build/players_ai_recommend.png`（入口行 + 祁小山 reply + 推荐卡）。
void main() {
  const captureKey = Key('capture');

  setUp(() {
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.instance.debugSetSession();
  });

  testWidgets('找陪玩页（入口行 + AI 推荐结果）出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        home: PlayersPage(
          api: _api(),
          recommendSource: _FakeRecommendSource(
            const AiRecommendResult(
              reply: '你说的"带我上分、话多"我记下了，挑了两个，你看看合不合适：',
              picks: [
                AiPick(
                  workerId: '116',
                  name: '祁小测·夜航',
                  intro: '三角洲行动端游，主玩突击位，晚上 9 点以后有空，接了就先陪你打三局，不接急单。',
                  divisionName: '三角洲行动 · 端游',
                  reason: '晚上 9 点后有空，节奏带得住新手',
                ),
                AiPick(
                  workerId: '117',
                  name: '祁小测·话筒',
                  intro: '和平精英手游，话多能带节奏，新手局也接，打不过就换战术慢慢磨。',
                  divisionName: '和平精英 · 手游',
                  reason: '介绍里写着话多、接新手局',
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byKey(const Key('players-ai-need')), '想找个晚上 9 点后有空、能带我上分的，我新手');
    await tester.pump();
    await tester.tap(find.byKey(const Key('players-ai-submit')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/players_ai_recommend.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

class _FakeRecommendSource implements AiRecommendSource {
  _FakeRecommendSource(this.result);

  final AiRecommendResult result;

  @override
  Future<AiRecommendResult> recommend(String token, {required String need, String? divisionId}) async => result;
}

ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(const {
    '/divisions': {
      'code': 0,
      'message': 'ok',
      'data': [
        {'id': '3', 'name': '三角洲行动 · 端游'},
        {'id': '2', 'name': '三角洲行动 · 手游'},
        {'id': '1', 'name': '和平精英 · 手游'},
      ],
    },
    '/public/players': {
      'code': 0,
      'message': 'ok',
      'data': {
        'list': [
          {
            'workerId': '201',
            'nickname': '演示工作端',
            'intro': '和平精英手游，白天在线，适合新手局慢慢磨。',
            'avatarMediaId': null,
            'divisionId': '1',
          },
          {
            'workerId': '202',
            'nickname': 'E2E打手',
            'intro': '三角洲行动端游，只跑验收流程，不接急单。',
            'avatarMediaId': null,
            'divisionId': '3',
          },
        ],
        'total': 2,
        'page': 1,
        'pageSize': 50,
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
