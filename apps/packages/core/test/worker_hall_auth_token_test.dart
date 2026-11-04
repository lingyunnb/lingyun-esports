/// **受保护接口必须带令牌** —— 2026-10-06 紧急修复的回归测试（打手态接单大厅分部胶囊永远加载失败）。
///
/// ## 事故（负责人实测）
/// 打手态接单大厅的分部胶囊**永远加载失败**，报「分部列表加载失败（未登录）」，点「重试」无效。
/// 根因：`worker_hall_page.dart` 的 `_loadDivisions()` 里
/// `_api.request('GET', '/worker/division-permissions', forceRefresh: force)` **漏了 `token:`**；
/// `ApiClient.buildHeaders()` 是 `if (token != null) 'Authorization': ...` →
/// **不传就真的不带 Authorization 头** → 服务端守卫 401「未登录」→ 胶囊永远出不来。
/// 该行由大厅提速改造（两个请求串行改并发）引入。
///
/// ## 为什么原来的测试抓不住（本文件的立身之本）
/// `worker_hall_divisions_test.dart` 的假服务器**只看 method+path，不校验令牌** ——
/// 于是"漏传 token"在组件测试里是**完全隐形**的：请求照样打到路由、照样回 200、胶囊照样出现。
/// 本文件把两件事补上：
///   ① 假服务器**记录每个请求的 headers**，并**执行真实守卫规则**（受保护接口缺 Authorization → 401）；
///   ② 直接断言"机制"：`ApiClient.buildHeaders(token: null)` **没有** Authorization 键。
///
/// ## 三条断言线（缺一不可）
///   - **机制**：`buildHeaders(token: null)` 无 `Authorization`、`buildHeaders(token: 'x')` 有
///     —— 把"不传就真不带上"这条根因机制钉死（这是本次 bug 的本质，不是页面写错了字符串）；
///   - **正向**：页面打 `/worker/division-permissions` 时**确实带上了非空令牌**（Bearer + companion 值）；
///   - **负向**：页面打 `/divisions` 时**不带** Authorization（公开接口，保持与 `ApiClient.prefetch`
///     同一缓存口径 —— 带上就会另建一份 `auth|...` 缓存，让预取白跑）；
///   - **因果链**：同一台假服务器下，缺 Authorization → 401「未登录」→ 页面出现失败提示、胶囊消失；
///     带 Authorization → 200 → 胶囊正常出现（把"漏 token ⇒ 胶囊消失"整条链钉死）。
///
/// 【反向自证】最后一组用**老写法**（不带 token 直接请求受保护接口）打同一台服务器，
/// 断言它**确实**拿到 401 —— 证明这套夹具**有能力**抓住本次 bug（若夹具本身抓不住，
/// 前三条断言就只是"自我感觉良好"）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String kPerm = 'GET /worker/division-permissions';
const String kDivisions = 'GET /divisions';
const String kHall = 'GET /worker/order-hall';

/// 打手态用的 companion 令牌（真机上由绑定打手账密换得，见 docs/04「伴随会话」）
const String kCompanionToken = 'companion-token-for-hall';

/// 一次被记录的请求（key = "METHOD /path"，headers = 该请求实际发出去的头）
typedef _Recorded = ({String key, Map<String, dynamic> headers});

/// 假服务器：**记录 headers** + **执行受保护接口的守卫规则**
///
/// [guarded] 里的接口在**缺少 Authorization** 时直接返回 401「未登录」
/// —— 与服务端 `JwtAuthGuard` 的行为一致（`server/src/common/guards/jwt-auth.guard.ts`）。
/// 这正是原测试夹具缺的那一环。
class _GuardedServer implements HttpClientAdapter {
  final List<_Recorded> log = <_Recorded>[];
  final Map<String, ({String body, int status})> route = <String, ({String body, int status})>{};

  /// 需要登录态的受保护接口（模拟守卫）。
  ///
  /// 默认**只护 `/worker/division-permissions`**：这正是事故的形状 ——
  /// 负责人实测时大厅列表是好好的（那个请求带了 token），只有分部胶囊失败。
  Set<String> guarded = <String>{kPerm};

  /// "闸门"：把某个 key 的**响应**挂住，直到测试放行。
  ///
  /// 用途只有一个 —— 断言两个辅助请求是**并发**发出的：串行实现会在这里被闸门卡死
  /// （第一个请求不返回，第二个请求根本不会发），并发实现则照发不误。
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  void ok(String key, Object? data) => route[key] = (
        body: jsonEncode(<String, dynamic>{'code': 0, 'message': 'ok', 'data': data}),
        status: 200,
      );

  void fail(String key, {int code = 500, String message = '服务端暂时不可用'}) => route[key] = (
        body: jsonEncode(<String, dynamic>{'code': code, 'message': message, 'data': null}),
        status: code,
      );

  /// 该 key 的请求次数
  int calls(String key) => log.where((_Recorded r) => r.key == key).length;

  /// 该 key 的**最后一次**请求头（找不到返回 null）
  Map<String, dynamic>? lastHeaders(String key) {
    final Iterable<_Recorded> hits = log.where((_Recorded r) => r.key == key);
    return hits.isEmpty ? null : hits.last.headers;
  }

  /// 大小写不敏感取头（dio 用 caseInsensitiveKeyMap 合并，但断言不该依赖它）
  static dynamic headerOf(Map<String, dynamic>? headers, String name) {
    if (headers == null) return null;
    final String want = name.toLowerCase();
    for (final MapEntry<String, dynamic> e in headers.entries) {
      if (e.key.toLowerCase() == want) return e.value;
    }
    return null;
  }

  /// 该 key 最后一次请求的 Authorization 头（没有 → null）
  String? authOf(String key) {
    final dynamic v = headerOf(lastHeaders(key), 'Authorization');
    return v is String ? v : null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String key = '${options.method} ${options.path}';
    // 先把这一发的头原样记下来 —— 断言的全部依据
    log.add((key: key, headers: <String, dynamic>{...options.headers}));

    // ⓪ 闸门（并发断言用）：挂住响应直到测试放行
    final Completer<void>? gate = gates[key];
    if (gate != null) await gate.future;

    // ① 守卫：受保护接口没有 Authorization → 401「未登录」（与服务端同文案）
    if (guarded.contains(key) && headerOf(options.headers, 'Authorization') == null) {
      return _json(<String, dynamic>{'code': 401, 'message': '未登录', 'data': null}, 401);
    }
    // ② 正常路由
    final ({String body, int status})? resp = route[key];
    if (resp == null) {
      return _json(<String, dynamic>{'code': 404, 'message': 'Not Found', 'data': null}, 404);
    }
    return _json(resp.body, resp.status, raw: true);
  }

  static ResponseBody _json(Object body, int status, {bool raw = false}) => ResponseBody.fromString(
        raw ? body as String : jsonEncode(body),
        status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

void main() {
  late _GuardedServer server;
  late Dio dio;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    server = _GuardedServer();
    dio = Dio(BaseOptions(baseUrl: 'http://hall-token.local'))..httpClientAdapter = server;
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://hall-token.local'))
      ..httpClientAdapter = server;
    // 打手态会话：primary（老板）+ companion（打手）= 页面用的 activeToken
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: 'boss-primary-token');
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: kCompanionToken,
    );
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiClient.debugDefaultDio = null;
    ApiClient.onUnauthorized = null;
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: null);
  });

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 有权限的分部（服务端 `/worker/division-permissions` 的 data.list 形态）
  List<Map<String, dynamic>> perms(List<String> ids) => ids
      .map((String id) => <String, dynamic>{
            'divisionId': id,
            'name': '分部$id',
            'shortName': '分区$id',
            'platformLabel': '手游',
            'canTakeOrder': true,
          })
      .toList();

  String chipLabel(String id) => '分区$id · 手游';

  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (int i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpHall(WidgetTester tester) async {
    await tester.pumpWidget(host(IdentityWorkerHallPage(api: ApiClient(dio: dio))));
    await settle(tester);
  }

  // ==========================================================================
  // ① 机制：不传 token 就真的不带 Authorization（本次 bug 的**根因机制**）
  // ==========================================================================
  group('① 机制：ApiClient.buildHeaders 的 token 语义', () {
    test('buildHeaders(token: null) **没有** Authorization 键；token: "x" **有**（Bearer x）', () {
      final Map<String, dynamic> noToken = ApiClient.buildHeaders(token: null);
      expect(noToken.containsKey('Authorization'), isFalse,
          reason: '这就是本次 bug 的机制：不传 token 时 buildHeaders 真的**一个 Authorization 都不带** '
              '（不是带空值、不是自动补登录态）→ 服务端只能当未登录');
      expect(noToken.values.where((Object? v) => v is String && v.contains('Bearer')), isEmpty,
          reason: '任何位置都不该出现 Bearer');

      final Map<String, dynamic> withToken = ApiClient.buildHeaders(token: 'x');
      expect(withToken['Authorization'], 'Bearer x',
          reason: '传了 token 才有 Authorization（键名与格式就是这一份）');

      // 省略参数的默认值同样是"没有"（防止将来把默认值改成"自动取当前会话"而悄悄破坏这条语义）
      expect(ApiClient.buildHeaders().containsKey('Authorization'), isFalse);
    });

    test('**负向** 令牌为空字符串 ≠ 合法令牌（空串会带上一个无用的 Authorization）', () {
      // 记录这条边界的目的：页面一律传 `AuthStore.instance.activeToken`，
      // 它要么是 null（不带）、要么是真令牌；**不要**在别处用 `?? ''` 兜底，
      // 那会发出 "Bearer " 让服务端 401 且更难排查。
      expect(ApiClient.buildHeaders(token: null).containsKey('Authorization'), isFalse);
      expect(ApiClient.buildHeaders(token: '').containsKey('Authorization'), isTrue,
          reason: '空串不是 null —— 这正是"别用 ?? \'\' 兜底"的理由');
    });
  });

  // ==========================================================================
  // ② 页面真的带令牌了（正向 + 负向）
  // ==========================================================================
  group('② 大厅发出的请求：受保护接口带令牌 / 公开接口不带', () {
    testWidgets('`GET /worker/division-permissions` 请求头带 Authorization: Bearer <companion 令牌>', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);

      expect(server.calls(kPerm), greaterThanOrEqualTo(1), reason: '页面必须先请求权限（胶囊的数据源）');
      expect(server.authOf(kPerm), 'Bearer $kCompanionToken',
          reason: '受保护接口**必须**带上打手态令牌（companion）。'
              '这条断言就是本次 bug 的照妖镜：漏传 token 时它是 null → 直接红');
      expect(find.text(chipLabel('d1')), findsOneWidget, reason: '带令牌 → 胶囊正常出现');
      expect(find.textContaining('分部列表加载失败'), findsNothing);
    });

    testWidgets('**负向** `GET /divisions` **不带** Authorization（公开接口，保持预取共用同一缓存口径）', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);

      expect(server.calls(kDivisions), greaterThanOrEqualTo(1));
      expect(server.authOf(kDivisions), isNull,
          reason: '`/divisions` 是公开接口：带上 token 会在 auth 域另建一份缓存，'
              '让 ApiClient.prefetch 预取的那份白白闲置（同一个接口被拉两次）—— 代码注释已写明，'
              '这条负向断言把"别顺手给它加 token"钉住');
      expect(_GuardedServer.headerOf(server.lastHeaders(kDivisions), 'Authorization'), isNull);
    });

    testWidgets('两个辅助请求是**并发**发出的（提速改造不能被回退成串行）', (tester) async {
      // 闸门卡住权限请求的**响应**：串行实现（先 await 权限、再发 /divisions）
      // 会在这里被卡住 —— 第二个请求压根发不出去；并发实现则两个都已发出。
      server.gates[kPerm] = Completer<void>();
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await tester.pumpWidget(host(IdentityWorkerHallPage(api: ApiClient(dio: dio))));
      await settle(tester, times: 3);

      expect(server.calls(kPerm), greaterThanOrEqualTo(1));
      expect(server.calls(kDivisions), greaterThanOrEqualTo(1),
          reason: '权限请求**还没返回**（被闸门卡着），`/divisions` 就已经发出去了 —— '
              '只有并发才可能这样（串行实现永远到不了这一行）');

      server.gates[kPerm]!.complete();
      await settle(tester);
      expect(find.text(chipLabel('d1')), findsOneWidget);
    });
  });

  // ==========================================================================
  // ③ 因果链（端到端形状）：缺 Authorization ⇒ 401 ⇒ 胶囊消失；有 ⇒ 200 ⇒ 胶囊出现
  // ==========================================================================
  group('③ 因果链：Authorization 决定胶囊生死', () {
    testWidgets('会话**有**令牌（打手态正常）→ 200 → 胶囊出现', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1', 'd2'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
        <String, dynamic>{'id': 'd2', 'onlineCount': 5},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      await pumpHall(tester);

      expect(find.text('全部'), findsOneWidget);
      expect(find.text(chipLabel('d1')), findsOneWidget);
      expect(find.text(chipLabel('d2')), findsOneWidget);
      expect(find.textContaining('分部列表加载失败'), findsNothing);
    });

    testWidgets('会话**没有**令牌（等价于漏传 token 的线上形状）→ 401「未登录」→ 精确复现负责人实测现象', (tester) async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});
      server.ok(kDivisions, <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'onlineCount': 3},
      ]);
      server.ok(kHall, <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0});

      // 把会话摆成"没有可用令牌"——页面于是发出**不带 Authorization**的请求，
      // 与线上漏传 token 时**在网线上完全同一形状**（这正是能复现的原因）
      AuthStore.instance
        ..debugClearIdentity()
        ..debugSetSession(accessToken: null);
      expect(AuthStore.instance.activeToken, isNull, reason: '前提：这一发真的没有令牌');

      await pumpHall(tester);
      await settle(tester, times: 6); // 等自动自愈那一轮也跑完（它同样没有令牌 → 仍失败）

      expect(server.calls(kPerm), greaterThanOrEqualTo(1));
      expect(server.authOf(kPerm), isNull, reason: '确认真的是"没带头"发出的（而不是被别的路径补上了）');
      // 负责人实测原文：「分部列表加载失败（未登录）」——一字不差
      expect(find.textContaining('分部列表加载失败（未登录）'), findsOneWidget,
          reason: '缺 Authorization → 服务端 401「未登录」→ 页面必须把它显示出来');
      expect(find.text('重试'), findsOneWidget, reason: '给出下一步（虽然漏 token 时重试不会好 —— 这正是要修的）');
      expect(find.text('全部'), findsNothing, reason: '胶囊整排不出现（事故现象）');
      expect(tester.takeException(), isNull);
    });

    // 注意：这一条**必须**是 `test` 而不是 `testWidgets` ——
    // `testWidgets` 的假时钟区里 await 真实异步 I/O 会**挂住**（实测：整个测试进程不退出）。
    test('**反向自证**：老写法（不带 token 直接请求受保护接口）在同一夹具下**确实**拿到 401', () async {
      server.ok(kPerm, <String, dynamic>{'list': perms(<String>['d1'])});

      ApiException? caught;
      try {
        // 这一行就是修复前的原代码形状：没有 `token:`
        await ApiClient(dio: dio).request('GET', '/worker/division-permissions');
      } on ApiException catch (e) {
        caught = e;
      }
      expect(caught?.code, 401, reason: '证明本夹具**有能力**抓住本次 bug：不传 token 就真的 401'
          '（旧夹具不校验令牌，所以它抓不住）');
      expect(caught?.message, '未登录');
    });
  });
}
