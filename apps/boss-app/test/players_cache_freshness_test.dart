import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/players_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「找陪玩」页 × 名单时效（2026-10-05 夜间收尾）
///
/// 背景（真实残留风险）：服务端 `/public/players` 已改为按分部实时查库
/// （`worker_division_permission`，管理端授权/撤销 3ms 内生效），但客户端 core 把它
/// 配成了 **ttlDict（10 分钟）**，且「找陪玩」页拼请求时**没带 forceRefresh** ——
/// 于是管理端刚改完权限，老板进「找陪玩」页最长 10 分钟仍可能看到旧名单。
///
/// 本文件钉死客户端这一侧的两条修法（只增不减，不回退既有行为）：
/// 1) **进入页面强制回源**：即使上一次进入留下的缓存还在 TTL 内（键完全相同），
///    第二次进入也必须真的再发一次请求 —— 权限变更后切个页回来就能看到新名单。
/// 2) **下拉刷新强制回源**：RefreshIndicator 触发的 `_loadPlayers(force: true)`
///    必须把 force 透传到 `ApiClient.request(forceRefresh:)`（同一场景同一口径）。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    // 页面与用例共用同一个 baseUrl：不清缓存就分不清"命中缓存"与"真的请求了"
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  testWidgets('进入「找陪玩」页强制回源：缓存还在 TTL 内也必须再发一次请求', (tester) async {
    final adapter = _PlayersAdapter(<String, List<dynamic>>{
      '2': [
        {'workerId': '11', 'nickname': '手游打手A', 'intro': '只接三角洲手游', 'avatarMediaId': null},
      ],
    });
    final api = _api(adapter);

    // 第一次进入：真实请求 + 落缓存
    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: api)));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('手游打手A'), findsOneWidget);
    expect(adapter.playersQueries, ['2'], reason: '首次进入必须真的拉一次名单');
    expect(adapter.playersQueries.length, 1);

    // 模拟"管理端刚撤销权限"：服务端名单空了（同一个 key，缓存里还是旧的那份）
    adapter.playersByDivision['2'] = const <dynamic>[];

    // 第二次进入（全新页面、同一个 ApiClient）：TTL 内若有缓存，不加 force 就会直接吃缓存
    await tester.pumpWidget(MaterialApp(home: PlayersPage(key: const ValueKey('reenter'), api: api)));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(adapter.playersQueries.length, 2,
        reason: '进入页面必须 forceRefresh 回源：否则权限刚改完，老板看到的是上一次进入时的旧名单');
    expect(find.text('手游打手A'), findsNothing, reason: '回源拿到的是新名单（旧名单不能残留）');
    expect(find.textContaining('还没有陪玩'), findsOneWidget,
        reason: '回源后是空名单 → 空态文案（A 套设计稿：说清是哪个分部空，不再让用户"换个分部看看"——线上只有 1 个分部）');
  });

  testWidgets('下拉刷新强制回源：force 必须透传到 forceRefresh（不空转）', (tester) async {
    final adapter = _PlayersAdapter(<String, List<dynamic>>{
      '2': [
        {'workerId': '11', 'nickname': '手游打手A', 'intro': '只接三角洲手游', 'avatarMediaId': null},
      ],
    });
    final api = _api(adapter);

    await tester.pumpWidget(MaterialApp(home: PlayersPage(api: api)));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(adapter.playersQueries.length, 1);

    // 下拉刷新（RefreshIndicator 的 onRefresh → _loadPlayers(force: true)）
    await tester.fling(find.byType(Scrollable).first, const Offset(0, 320), 1000);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(adapter.playersQueries.length, 2,
        reason: '下拉刷新带 forceRefresh=true → 必须真的再发一次（此前没带 force 时会被 45s/10min 缓存吃掉）');
    expect(adapter.playersQueries, ['2', '2'], reason: '同一个分部刷新，键没变，靠 force 才绕过缓存');
  });
}

ApiClient _api(_PlayersAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://players-fresh.test/api/v1'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 假数据源：`/divisions` 返回两个分部（页面默认选第一个 = 分部 2），
/// `/public/players?divisionId=N` 返回该分部当前的名单（**可变** → 模拟管理端改权限后服务端结果变化）。
class _PlayersAdapter implements HttpClientAdapter {
  _PlayersAdapter(this.playersByDivision);

  final Map<String, List<dynamic>> playersByDivision;

  /// 每次 `GET /public/players` 实际带的 divisionId（按顺序）—— 请求次数就是"有没有回源"的证据
  final List<String> playersQueries = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    late final Map<String, dynamic> envelope;
    if (options.path.startsWith('/public/players')) {
      final div = '${options.queryParameters['divisionId'] ?? ''}';
      playersQueries.add(div);
      final list = playersByDivision[div] ?? const <dynamic>[];
      envelope = _envelope({'list': list, 'total': list.length, 'page': 1, 'pageSize': 50});
    } else if (options.path.startsWith('/divisions')) {
      envelope = _envelope(const [
        {'id': '2', 'name': '三角洲行动 · 手游'},
        {'id': '3', 'name': '三角洲行动 · 端游'},
      ]);
    } else {
      envelope = _envelope(const {'list': [], 'total': 0});
    }
    return ResponseBody.fromString(jsonEncode(envelope), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  static Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  @override
  void close({bool force = false}) {}
}
