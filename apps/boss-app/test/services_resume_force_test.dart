/// **服务页（首页）三条回源路径的 force 口径**（2026-10-08 运营同步专项）
///
/// 缺陷现场（负责人反馈）：管理端**下架了分部**，服务端 `/api/v1/divisions/grouped` 当场只剩 1 条，
/// 但 App 首页**仍然显示那几张分部卡**。客户端有两个成因，缺一不可：
///   ① `/divisions`、`/public/*` 等运营数据挂在 `ttlDict`（10 分钟）——已在 core 修为
///      `ttlOps`（60s），见 `apps/packages/core/test/ops_ttl_test.dart`；
///   ② **回前台**（`didChangeAppLifecycleState`）与**切回本 tab 的刷新信号**（`refreshSignal`）
///      两条路径都只调 `_load()`（默认 `force: false`）→ 命中 SWR 缓存就把旧卡片又亮出来。
///
/// 本文件把②钉死（首屏仍允许吃缓存，保住秒开）：
/// - ③ 恢复前台 → 发给服务端的必须是 **forceRefresh = true** 的请求；
/// - ④ 收到 `refreshSignal` → 同上；
/// - ⑤ **负向**：首次进入（initState）**不走 force**（首屏秒开的来源，不能一起砍掉）；
/// 另有一条走**真 ApiCache** 的行为级用例：下架后回前台，旧卡片必须真的消失
/// （把 `_load(force: true)` 改回 `_load()` 时它会红 —— 见报告里的变异验证）。
///
/// ## 2026-10-18 换靶（本文件为什么改了一遍）
/// 原题面用的是 `/public/clubs`（官方馆）。负责人 2026-10-18 把首页「祁连山官方 · 官方馆」整块删了
/// （它与「精选服务」下的分部卡同屏各列一张和平精英卡 = 冗余块），本页**不再请求 `/public/clubs`** ——
/// 这条守卫的题面因此换成同样属于"运营数据"的 **`/divisions/grouped`**：
/// 管理端下架一个分部 → 回前台必须真的绕过缓存把它从首页抹掉。
/// **口径一个字没变**：三条路径的 force 语义、负向断言、监听不泄漏、真缓存行为级验证全部保留。
library;

import 'dart:convert';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 分部 fixture（与真机现场同构：3 个分部，其中「无畏契约 · 手游」是被下架的那个）
///
/// 注意 [title] / [label] 都带平台后缀：首页**分部入口卡显示完整名**（`d.name`），
/// Tab 显示 `shortName` —— 断言用完整名，才能区分"卡还在不在"。
Map<String, dynamic> _division(String id, String code, String gameId, String gameName, String label, String color) =>
    <String, dynamic>{
      'id': id,
      'code': code,
      'gameId': gameId,
      'gameName': gameName,
      'platform': 'mobile',
      'platformLabel': label,
      'name': '$gameName · $label',
      'shortName': gameName,
      'onlineDesc': '平均 3 分钟内接单',
      'themeColor': color,
      'onlineCount': 12,
    };

const String _firstDivisionName = '和平精英 · 手游';
const String _secondDivisionName = '三角洲行动 · 手游';
const String _thirdDivisionName = '无畏契约 · 手游';

/// `take` = 当前"上架"的分部条数（模拟管理端下架）
List<Map<String, dynamic>> _divisions(int take) => <Map<String, dynamic>>[
      _division('1', 'peace_mobile', '35', '和平精英', '手游', '#16A34A'),
      _division('2', 'delta_mobile', '36', '三角洲行动', '手游', '#2563EB'),
      _division('3', 'valorant_mobile', '48', '无畏契约', '手游', '#DC2626'),
    ].take(take).toList();

/// `/divisions/grouped` 信封（按游戏分组）
Map<String, dynamic> _grouped(int take) => <String, dynamic>{
      'code': 0,
      'message': 'ok',
      'data': <dynamic>[
        for (final d in _divisions(take))
          <String, dynamic>{
            'gameId': d['gameId'],
            'gameName': d['gameName'],
            'platformCount': 1,
            'divisions': <dynamic>[d],
          },
      ],
    };

Map<String, dynamic> _ok(Object? data) => <String, dynamic>{'code': 0, 'message': 'ok', 'data': data};

void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    // 页面与用例共用同一个 baseUrl：不清缓存就分不清"命中缓存"与"真的回源了"
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  testWidgets('⑤ 首次进入（initState）不强制回源 —— 首屏秒开的来源，不能一起砍掉', (tester) async {
    final api = _RecordingApi();
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
    await tester.pumpAndSettle();

    expect(api.divisionCalls, isNotEmpty, reason: '首屏当然要真拉一次（缓存未命中时）');
    expect(api.divisionCalls.every((c) => c.force), isFalse,
        reason: '首次进入允许先吃缓存（SWR 命中即同步上屏）→ 不得带 forceRefresh');
    expect(api.calls.where((c) => c.force), isEmpty,
        reason: '负向断言：initState 这一跳如果有任何请求带了 force，就等于把"秒开"取消了');
    // 首屏内容照常渲染（缓存/网络两条路径都能上屏）
    expect(find.text(_thirdDivisionName), findsOneWidget);
  });

  testWidgets('③ 恢复前台（resumed）→ 强制回源（forceRefresh=true）', (tester) async {
    final api = _RecordingApi();
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
    await tester.pumpAndSettle();

    api.calls.clear();
    // 模拟运营在这期间下架了两个分部（服务端立刻只返回 1 条）
    api.divisionCount = 1;

    await _resumeForeground(tester);

    expect(api.divisionCalls, isNotEmpty, reason: '回前台必须真的再打一次服务端');
    expect(api.divisionCalls.last.force, isTrue,
        reason: '回前台这条路径必须 forceRefresh=true —— 否则命中 SWR 缓存就把刚下架的分部又亮出来');
    expect(api.calls.every((c) => c.force), isTrue,
        reason: '回前台触发的全部并发请求（聚合/分部/宣传图/播报/商品/分类）必须全部强制回源');
    // 行为层：拿到的是新数据（下架的分部不再渲染）
    expect(find.text(_thirdDivisionName), findsNothing);
    expect(find.text(_secondDivisionName), findsNothing);
    expect(find.text(_firstDivisionName), findsOneWidget);
  });

  testWidgets('④ 收到 refreshSignal（切回服务页 tab）→ 强制回源（forceRefresh=true）', (tester) async {
    final api = _RecordingApi();
    final signal = ValueNotifier<int>(0);
    addTearDown(signal.dispose);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api, refreshSignal: signal)));
    await tester.pumpAndSettle();

    api.calls.clear();
    signal.value++; // HomeShell._switchTab(pageServices) / 下单页返回时递增
    await tester.pumpAndSettle();

    expect(api.divisionCalls, isNotEmpty, reason: '刷新信号必须真的再打一次服务端');
    expect(api.divisionCalls.last.force, isTrue,
        reason: '刷新信号必须 forceRefresh=true（原实现直接挂 _load，force 默认 false → 吃缓存）');
    expect(api.calls.every((c) => c.force), isTrue);
  });

  testWidgets('refreshSignal 的监听取用同一个函数引用（dispose 后不留悬挂监听）', (tester) async {
    final api = _RecordingApi();
    final signal = _TrackingSignal(0);
    addTearDown(signal.dispose);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api, refreshSignal: signal)));
    await tester.pumpAndSettle();
    expect(signal.liveListeners, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(signal.liveListeners, 0,
        reason: 'removeListener 必须与 addListener 是同一个引用（内联闭包会让监听永远摘不掉 → 页面重建即泄漏）');
  });

  testWidgets('走真 ApiCache 的行为级用例：下架分部后回前台，旧卡片必须消失', (tester) async {
    final adapter = _DivisionsAdapter();
    final api = ApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://services-ops-swr.test/api/v1'))..httpClientAdapter = adapter,
    );

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api)));
    await tester.pumpAndSettle();
    expect(adapter.divisionRequests, 1);
    expect(find.text(_thirdDivisionName), findsOneWidget);

    // 管理端下架（服务端立刻只返回 2 条；此刻客户端 SWR 缓存里还是 3 条、TTL 内新鲜）
    adapter.divisionCount = 2;

    await _resumeForeground(tester);

    expect(adapter.divisionRequests, 2,
        reason: '回前台必须真的绕过 SWR 缓存再发一次；改回 _load() 时这里会停在 1 次 → 红');
    expect(find.text(_thirdDivisionName), findsNothing,
        reason: '已下架的分部卡片必须消失（这正是负责人报障的现象）');
    expect(find.text(_firstDivisionName), findsOneWidget);
  });
}

/// 模拟"App 从后台切回前台"：走 `flutter/lifecycle` 平台通道（框架自身的做法），
/// 不直接调 `@protected` 的 `handleAppLifecycleStateChanged`（analyze 会报 protected 成员越界）。
///
/// 先发 `inactive` 再发 `resumed`：保证无论测试初始生命周期状态是什么，
/// `inactive → resumed` 这条边都必然产生一次 `didChangeAppLifecycleState(resumed)`。
Future<void> _resumeForeground(WidgetTester tester) async {
  final messenger = tester.binding.defaultBinaryMessenger;
  await messenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage('AppLifecycleState.inactive'),
    (_) {},
  );
  await messenger.handlePlatformMessage(
    'flutter/lifecycle',
    const StringCodec().encodeMessage('AppLifecycleState.resumed'),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// **假 ApiClient**：记录每次请求的 `forceRefresh`（本文件的核心证据）。
///
/// 为什么不复用真 ApiClient + 假适配器：本文件要断言的是**页面传下去的 force 参数**
/// （"该回源却吃缓存"是页面侧的缺口），不是缓存实现本身；适配器只能看到"发了几次请求"，
/// 分不清是 force 还是缓存过期。真缓存的行为级验证由最后一条用例负责。
class _RecordingApi extends ApiClient {
  _RecordingApi() : super(dio: Dio(BaseOptions(baseUrl: 'http://services-force.test/api/v1')));

  /// 按顺序记录的全部请求（path + 是否 forceRefresh）
  final List<({String path, bool force})> calls = <({String path, bool force})>[];

  /// 服务端当前"上架"的分部条数（模拟管理端下架）
  int divisionCount = 3;

  List<({String path, bool force})> get divisionCalls =>
      calls.where((c) => c.path.startsWith('/divisions')).toList();

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? token,
    bool forceRefresh = false,
  }) async {
    calls.add((path: path, force: forceRefresh));
    if (path.startsWith('/divisions')) return Map<String, dynamic>.from(_grouped(divisionCount));
    if (path.startsWith('/public/products')) {
      return _ok(<String, dynamic>{'list': <dynamic>[], 'total': 0, 'page': 1, 'pageSize': 50});
    }
    if (path.startsWith('/public/site')) {
      return _ok(<String, dynamic>{});
    }
    if (path.startsWith('/public/banners')) return _ok(const <dynamic>[]);
    if (path.startsWith('/public/categories')) return _ok(const <dynamic>[]);
    if (path.startsWith('/public/announcements')) return _ok(const <dynamic>[]);
    if (path.startsWith('/public/recharge/config')) return _ok(null);
    return _ok(const <dynamic>[]);
  }
}

/// 假通道（**真 ApiClient + 真 ApiCache**）：`/divisions/grouped` 的返回**可变**，
/// 用来复现"管理端下架分部 → 服务端立刻变少 → 客户端回前台该看到新的"。
class _DivisionsAdapter implements HttpClientAdapter {
  /// 服务端当前"上架"的分部条数
  int divisionCount = 3;

  int divisionRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    late final Map<String, dynamic> envelope;
    if (options.path.startsWith('/divisions')) {
      divisionRequests += 1;
      envelope = _grouped(divisionCount);
    } else if (options.path.startsWith('/public/products')) {
      envelope = _ok(<String, dynamic>{'list': <dynamic>[], 'total': 0, 'page': 1, 'pageSize': 50});
    } else if (options.path.startsWith('/public/site')) {
      envelope = _ok(<String, dynamic>{});
    } else if (options.path.startsWith('/public/banners')) {
      envelope = _ok(const <dynamic>[]);
    } else if (options.path.startsWith('/public/categories')) {
      envelope = _ok(const <dynamic>[]);
    } else if (options.path.startsWith('/public/announcements')) {
      envelope = _ok(const <dynamic>[]);
    } else if (options.path.startsWith('/public/recharge/config')) {
      envelope = _ok(null);
    } else {
      envelope = _ok(const <dynamic>[]);
    }
    return ResponseBody.fromString(jsonEncode(envelope), 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 会**如实记账**的刷新信号：`removeListener` 传进来的若不是当初注册的那个引用，
/// 这里就摘不掉 → [liveListeners] 不掉。用公开 API 复现"内联闭包导致监听泄漏"
/// （`ValueNotifier.hasListeners` 是 `@protected`，测试里不能碰）。
class _TrackingSignal extends ValueNotifier<int> {
  _TrackingSignal(super.value);

  final Set<VoidCallback> _registered = <VoidCallback>{};

  int get liveListeners => _registered.length;

  @override
  void addListener(VoidCallback listener) {
    _registered.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _registered.remove(listener);
    super.removeListener(listener);
  }
}
