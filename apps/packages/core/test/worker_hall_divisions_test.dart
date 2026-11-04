/// 接单大厅 · **分部加载失败不再静默**（2026-10-06 专项，负责人实测）。
///
/// 事故链（负责人截图：分部胶囊整排消失，只剩「大厅暂无可接订单」）：
///   重置打手密码 → companion 会话被吊销 → `/worker/division-permissions` 失败 →
///   原实现 `catch (_) {}` **静默吞掉** → `_divisions` 空 → `if (_divisions.isNotEmpty) _chips()`
///   整排不渲染 → **既没有原因、也没有可点的下一步**（直到用户手动下拉才恢复）。
///
/// 修的三点（本文件逐条断言）：
///   ① **不许静默**：失败时在原位置给一行中文提示 + 「重试」（大厅内容仍然照常出）
///   ② **自动自愈**：大厅**成功**但分部仍为空 → 自动重拉一次（**且只一次**）
///   ③ **下拉刷新同时重拉两个接口**（走真回源，不吃 60s TTL 缓存）
///
/// 负向用例（同样必做）：
///   - 大厅**失败**时**不**触发分部自愈（hallOk 为假）
///   - 打手本来就没有任何分部权限（200 + 空列表）**不**被当成故障反复重拉
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录"打到了哪些请求"的假服务器（按 "METHOD /path" 路由）
class _FakeServer implements HttpClientAdapter {
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};
  final List<String> requests = <String>[];

  void ok(String key, Object? data) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}), status: 200);

  void fail(String key, {int code = 500, String message = '服务端暂时不可用'}) =>
      route[key] = (body: jsonEncode(<String, dynamic>{'code': code, 'message': message, 'data': null}), status: code);

  int calls(String key) => requests.where((String r) => r == key).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String key = '${options.method} ${options.path}';
    requests.add(key);
    final ({String body, int status})? resp = route[key];
    if (resp == null) {
      return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
      );
    }
    return ResponseBody.fromString(
      resp.body,
      resp.status,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

const String kPerm = 'GET /worker/division-permissions';
const String kDivisions = 'GET /divisions';
const String kHall = 'GET /worker/order-hall';

void main() {
  late _FakeServer server;
  late Dio dio;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    server = _FakeServer();
    dio = Dio(BaseOptions(baseUrl: 'http://hall.local'))
      ..httpClientAdapter = server;
    // 让页面内所有走 sharedDio 的请求也落到假通道
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://hall.local'))
      ..httpClientAdapter = server;
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiClient.debugDefaultDio = null;
  });

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 有权限的分部（服务端 /worker/division-permissions 的 data.list 形态）
  ///
  /// 字段名与服务端契约一致（`shortName` + `platformLabel` → 展示名「简称 · 平台」）
  List<Map<String, dynamic>> perms(List<String> ids) => ids
      .map((String id) => <String, dynamic>{
            'divisionId': id,
            'name': '分部$id',
            'shortName': '分区$id',
            'platformLabel': '手游',
            'canTakeOrder': true,
          })
      .toList();

  /// 有权限分部的**展示名**（胶囊上的字）
  String chipLabel(String id) => '分区$id · 手游';

  Future<void> settle(WidgetTester tester, {int times = 6}) async {
    for (int i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpHall(WidgetTester tester) async {
    await tester.pumpWidget(host(IdentityWorkerHallPage(api: ApiClient(dio: dio))));
    await settle(tester, times: 8);
  }

  // ==========================================================================
  // ① 失败不再静默
  // ==========================================================================
  group('① 分部加载失败 → 中文提示 + 重试（不再是空屏）', () {
    testWidgets('分部接口 500 → 出现「分部列表加载失败…」+「重试」按钮，且**大厅内容照常可出**', (tester) async {
      server.fail(kPerm, code: 500, message: '服务端暂时不可用');
      server.ok(kDivisions, <Map<String, dynamic>>[]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);

      expect(find.textContaining('分部列表加载失败'), findsOneWidget,
          reason: '失败必须让人看见（原实现整段静默吞掉）');
      expect(find.textContaining('服务端暂时不可用'), findsOneWidget, reason: '原因用服务端中文原文');
      expect(find.text('重试'), findsOneWidget, reason: '必须给出下一步');
      // 辅助请求失败**不得**影响大厅内容出屏（这条原则不变）
      expect(find.textContaining('大厅暂无待接订单'), findsWidgets,
          reason: '大厅本身 200，所以空态照常出现（不是报错页）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('网络异常（路由缺失 → 404）也翻成中文提示', (tester) async {
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);
      expect(find.textContaining('分部列表加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('点「重试」→ 胶囊出现（提示消失、happy path 恢复）', (tester) async {
      server.fail(kPerm, code: 500, message: '服务端暂时不可用');
      server.ok(kDivisions, <Map<String, dynamic>>[]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);
      expect(find.text('重试'), findsOneWidget);

      // 会话恢复：下次请求 200
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1', 'd2'])});
      await tester.tap(find.text('重试'));
      await settle(tester, times: 8);

      expect(find.textContaining('分部列表加载失败'), findsNothing, reason: '成功后提示必须消失');
      expect(find.text('重试'), findsNothing);
      expect(find.text('全部'), findsOneWidget, reason: '胶囊行回来了（第一个永远是「全部」）');
      expect(find.text(chipLabel('d1')), findsOneWidget);
      expect(find.text(chipLabel('d2')), findsOneWidget);
    });
  });

  // ==========================================================================
  // ② 自动自愈（防抖：最多 1 次）
  // ==========================================================================
  group('② 大厅成功但分部为空 → 自动重拉一次且只一次', () {
    testWidgets('进页面：分部第一次失败 → 自动重拉一次 → 胶囊自己回来（无需用户操作）', (tester) async {
      // 第一次 500，之后 200 —— 模拟"会话刚恢复"
      server.fail(kPerm, code: 500, message: '登录已过期');
      server.ok(kDivisions, <Map<String, dynamic>>[]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});
      final Dio switching = Dio(BaseOptions(baseUrl: 'http://hall.local'))
        ..httpClientAdapter = _SwitchingAdapter(server, () {
          if (server.calls(kPerm) >= 1) {
            server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
          }
        });

      await tester.pumpWidget(host(IdentityWorkerHallPage(api: ApiClient(dio: switching))));
      await settle(tester, times: 12);

      expect(server.calls(kPerm), 2, reason: '失败后**自动重拉一次**（首屏 1 次 + 自愈 1 次）');
      expect(find.text(chipLabel('d1')), findsOneWidget, reason: '会话恢复后页面自己好起来，用户不用下拉');
      expect(find.textContaining('分部列表加载失败'), findsNothing);
    });

    testWidgets('**负向**：打手本来就没有任何分部权限（200 + 空列表）→ 不重拉、不当故障', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': <Map<String, dynamic>>[]}); // 合法空
      server.ok(kDivisions, <Map<String, dynamic>>[]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);

      expect(server.calls(kPerm), 1, reason: '合法空不是故障 —— 不该被自动重拉（否则每次刷新都多一个请求）');
      expect(find.textContaining('分部列表加载失败'), findsNothing, reason: '没失败就不该有错误提示');
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('**负向**：大厅本身失败 → 不触发分部自愈（hallOk 为假）', (tester) async {
      server.fail(kPerm, code: 500, message: '服务端暂时不可用');
      server.ok(kDivisions, <Map<String, dynamic>>[]);
      server.fail(kHall, code: 500, message: '网络异常');

      await pumpHall(tester);

      expect(server.calls(kPerm), 1, reason: '大厅都失败了，重拉分部没有意义（也不该偷偷发）');
      expect(find.textContaining('网络异常'), findsWidgets, reason: '大厅失败照旧走既有的错误态');
    });

    testWidgets('自动重拉**最多一次**：一直失败也不会重试风暴', (tester) async {
      server.fail(kPerm, code: 500, message: '服务端暂时不可用');
      server.ok(kDivisions, <Map<String, dynamic>>[]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);

      expect(server.calls(kPerm), 2, reason: '首屏 1 次 + 自愈 1 次 = 2；不能再多');
    });
  });

  // ==========================================================================
  // ③ 下拉刷新：两个接口都回源
  // ==========================================================================
  group('③ 下拉刷新同时重拉大厅与分部', () {
    testWidgets('下拉 → /worker/order-hall 与 /worker/division-permissions 都被重打', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);
      final int hallBefore = server.calls(kHall);
      final int permBefore = server.calls(kPerm);
      expect(hallBefore, greaterThanOrEqualTo(1));

      // 下拉（RefreshIndicator）：直接对 RefreshIndicator 本体做慢拖
      // （`fling` 会被当成惯性滚动不触发；对 ListView 做 `drag` 会落在列表项之外的空白区域）
      final Offset center = tester.getCenter(find.byType(RefreshIndicator));
      final TestGesture gesture = await tester.startGesture(center);
      for (int i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, 32));
        await tester.pump(const Duration(milliseconds: 32));
      }
      await gesture.up();
      await tester.pump();
      await settle(tester, times: 16);

      expect(server.calls(kHall), greaterThan(hallBefore), reason: '大厅必须回源');
      expect(server.calls(kPerm), greaterThan(permBefore),
          reason: '分部权限也必须回源（原来只 force 大厅，分部吃 60s TTL 缓存 → 会话恢复后下拉仍看到失败结果）');
    });

    testWidgets('页头刷新按钮（与下拉同一实现 _refreshAll）→ 两个接口都被重打', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);
      final int hallBefore = server.calls(kHall);
      final int permBefore = server.calls(kPerm);

      await tester.tap(find.byTooltip('刷新'));
      await settle(tester, times: 12);

      expect(server.calls(kHall), greaterThan(hallBefore), reason: '大厅必须回源（force）');
      expect(server.calls(kPerm), greaterThan(permBefore), reason: '分部权限也必须回源（force）');
    });
  });
}

/// 包一层：每次请求前先让 [before] 有机会改路由（模拟"会话在两次请求之间恢复"）
class _SwitchingAdapter implements HttpClientAdapter {
  _SwitchingAdapter(this.inner, this.before);

  final HttpClientAdapter inner;
  final void Function() before;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    before();
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}
