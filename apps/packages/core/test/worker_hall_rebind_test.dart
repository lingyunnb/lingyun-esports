/// **重新绑定 / 切换身份成功后，接单大厅的旧错误必须自己消失并重新拉取**（2026-10-06 体验修复）。
///
/// ## 负责人实测的问题
/// 会话过期 / 被解绑后，打手态接单大厅留下「分部列表加载失败（…）」；用户**重新绑定成功**回到大厅，
/// **那句话还挂在原地**，非得手点「重试」才消失。
///
/// ## 为什么旧实现自己好不了（本文件要钉住的机制）
/// 重新绑定换的是 companion **令牌**，`AuthStore.workerIdentity` **全程为 true** →
/// 宿主 `HomeShell` 的 `AnimatedSwitcher` 判定"同 key + 同 widget 类型"→ **复用整棵子树** →
/// 大厅页 State（含 `_divisionError`）原样留着，`_loadAll` 不会再跑第二次。
/// 也就是说：**页面上那句结论属于上一个会话，却没人通知它作废**。
///
/// 修法：`AuthStore.identityEpoch`（身份"代"，**每一次重新绑定/切换身份成功 +1**）——
/// 大厅页监听它，涨了就 ① 清 `_divisionError` ② 重置自动自愈预算 ③ 丢掉"已预取"标记
/// ④ `_loadAll(force: true)`（分部 + 大厅 + 在线数全部回源）。
///
/// ## 四条断言线（缺一不可）
///   ① **前置**：分部请求失败 → 中文提示 + 「重试」真的出现在屏上（错误是"看得见的"）；
///   ② **正向**：走**真实重绑路径**（`AuthStore.bindWorkerIdentity` + 假服务器签发新伴随令牌）
///      → 提示消失、胶囊出现，且**确实又发了一次分部请求**（计数 + 请求头用的是**新令牌**）；
///   ③ **负向**：**没有**重绑动作时（普通通知：拉一次绑定状态）**不许**自作主张重拉，
///      也**不许**把提示偷偷抹掉；
///   ④ **机制**：只有身份级成功动作才涨"代"，普通通知/资料刷新不涨（否则每次刷新都多一轮请求）。
///
/// ## 反向自证（为什么这条修复在本文件里是可证伪的）
/// 把 `worker_hall_page.dart` 里的 `AuthStore.instance.addListener(_onAuthChanged)` 去掉，
/// ② 立刻变红（提示不消失、计数不涨）——见提交说明里的变异验证记录。
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
const String kBind = 'POST /user/identity/bind';
const String kMe = 'GET /auth/me';
const String kIdentity = 'GET /user/identity';
const String kAnnouncements = 'GET /public/announcements';

/// 重绑前那枚（服务端已判定失效的）伴随令牌
const String kOldToken = 'companion-expired';

/// 重新绑定后服务端签发的新伴随令牌
const String kNewToken = 'companion-fresh';

/// 一次被记录的请求（key = "METHOD /path"，headers = 实际发出去的头）
typedef _Recorded = ({String key, Map<String, dynamic> headers});

/// 假服务器：**记录每个请求的头** + **执行真实守卫规则**（受保护接口缺/错令牌 → 401）
///
/// 与 `worker_hall_auth_token_test.dart` 同一套思路：**不校验令牌的假服务器抓不到这类 bug**。
/// 这里进一步让"会话"可切换 —— [kBind] 被调用时服务端签发新令牌（`sessionValid = true`），
/// 于是"重绑前 401 / 重绑后 200"这条因果链在一条测试里完整跑通。
class _RebindServer implements HttpClientAdapter {
  final List<_Recorded> log = <_Recorded>[];

  /// 伴随会话是否有效（重绑前 false → 受保护接口一律 401「未登录」）
  bool sessionValid = false;

  /// 当前服务端认可的伴随令牌
  String validToken = kOldToken;

  /// 分部接口的失败方式：null = 正常；否则返回该 (status, message)
  ({int status, String message})? permFailure = (status: 500, message: '服务端暂时不可用');

  int calls(String key) => log.where((_Recorded r) => r.key == key).length;

  Map<String, dynamic>? lastHeaders(String key) {
    final Iterable<_Recorded> hits = log.where((_Recorded r) => r.key == key);
    return hits.isEmpty ? null : hits.last.headers;
  }

  /// 该 key **最后一次**请求的 Authorization 头（没有 → null）
  String? authOf(String key) {
    final Map<String, dynamic>? h = lastHeaders(key);
    if (h == null) return null;
    for (final MapEntry<String, dynamic> e in h.entries) {
      if (e.key.toLowerCase() == 'authorization') return e.value is String ? e.value as String : null;
    }
    return null;
  }

  /// 服务端 `/worker/division-permissions` 的 `data.list` 形态（一个已授权分部）
  static List<Map<String, dynamic>> perms(List<String> ids) => ids
      .map((String id) => <String, dynamic>{
            'divisionId': id,
            'name': '分部$id',
            'shortName': '分区$id',
            'platformLabel': '手游',
            'canTakeOrder': true,
          })
      .toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String key = '${options.method} ${options.path}';
    log.add((key: key, headers: <String, dynamic>{...options.headers}));

    // ---- 受保护接口：守卫先看 Authorization（缺 / 过期 → 401「未登录」，与服务端同文案）----
    if (key == kPerm) {
      if (!sessionValid || authOf(kPerm) != 'Bearer $validToken') {
        return _json(<String, dynamic>{'code': 401, 'message': '未登录', 'data': null}, 401);
      }
      final ({int status, String message})? fail = permFailure;
      if (fail != null) {
        return _json(
          <String, dynamic>{'code': fail.status, 'message': fail.message, 'data': null},
          fail.status,
        );
      }
      return _json(<String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': perms(<String>['d1'])}});
    }

    // ---- 重绑：服务端签发**新的**伴随会话（这一刻起只有新令牌有效）----
    if (key == kBind) {
      sessionValid = true;
      validToken = kNewToken;
      // 重绑 = 会话与"当时的故障"一起翻篇：本次注入的 500 也要一起撤掉，
      // 否则「重绑后仍失败」就与"重绑后应该恢复"自相矛盾（那是夹具的 bug，不是页面的）。
      permFailure = null;
      return _json(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'bindingId': '42',
          'rebound': true,
          'companionToken': kNewToken,
          'companionRefreshToken': '$kNewToken-refresh',
          'worker': <String, dynamic>{
            'workerNo': 'W20260118',
            'nickname': '王野',
            'workerStatus': 1,
            'canTakeOrder': true,
            'divisionPermissions': perms(<String>['d1']),
          },
        },
      });
    }

    if (key == kMe) {
      return _json(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'id': '2',
          'username': 'wangye_go',
          'nickname': '王野',
          'role': 'worker',
          'worker': <String, dynamic>{
            'workerNo': 'W20260118',
            'canTakeOrder': true,
            'divisionPermissions': perms(<String>['d1']),
          },
        },
      });
    }

    if (key == kIdentity) {
      return _json(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <String, dynamic>{
          'bound': true,
          'activeCount': 1,
          'maxPerBoss': 1,
          'message': '',
          'bindings': <Map<String, dynamic>>[
            <String, dynamic>{
              'bindingId': '42',
              'status': 'active',
              'worker': <String, dynamic>{
                'workerNo': 'W20260118',
                'nickname': '王野',
                'workerStatus': 1,
                'canTakeOrder': true,
                'divisionPermissions': perms(<String>['d1']),
              },
            },
          ],
        },
      });
    }

    if (key == kDivisions) {
      return _json(<String, dynamic>{
        'code': 0,
        'message': 'ok',
        'data': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'd1', 'name': '分部d1', 'onlineCount': 3},
        ],
      });
    }

    if (key == kHall) {
      return _json(<String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': <Map<String, dynamic>>[], 'total': 0}});
    }

    if (key == kAnnouncements) {
      return _json(<String, dynamic>{'code': 0, 'message': 'ok', 'data': <String, dynamic>{'list': <Map<String, dynamic>>[]}});
    }

    return _json(<String, dynamic>{'code': 404, 'message': 'Not Found', 'data': null}, 404);
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
}

void main() {
  late _RebindServer server;
  late Dio dio;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    ApiCache.instance.clear();
    server = _RebindServer();
    dio = Dio(BaseOptions(baseUrl: 'http://hall-rebind.local'))
      ..httpClientAdapter = server;
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://hall-rebind.local'))
      ..httpClientAdapter = server;
    // 打手态：primary（老板）+ companion（打手，已过期）—— 页面用的就是 activeToken
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: 'boss-primary-token');
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: kOldToken,
      companionRefreshToken: '$kOldToken-refresh',
    );
    ApiCache.instance.beginSession('identity:worker');
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

  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (int i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpHall(WidgetTester tester) async {
    await tester.pumpWidget(host(IdentityWorkerHallPage(api: ApiClient(dio: dio))));
    await settle(tester);
  }

  /// 触发**真实重绑路径**（不是 debugSetIdentity 摆状态）：与「切换身份」弹层里那条一样，
  /// 走 `POST /user/identity/bind` → 装新伴随令牌 → `switchToWorker()`。
  ///
  /// ⚠️ 必须包在 `tester.runAsync` 里：`testWidgets` 的**假时钟区**里直接 `await` 一个真网络
  /// Future 会**挂住**（本项目实测过，见 `worker_hall_auth_token_test.dart` 的同类注记）——
  /// 假区里没人推进那条异步链。`runAsync` 让这一段跑在真异步区；页面随即发起的回源请求
  /// 由后面的 `settle()` 推进并落到屏上。
  ///
  /// 里面那次**真延时**是必需的：重绑成功后页面的回源是**脱离本 await 的**（`unawaited`），
  /// 它跑在真异步区 —— 不在这里给真事件循环一次机会，响应就永远落不到屏上
  /// （实测现象：请求确实发出去了，但"全部"胶囊一直不出现）。
  Future<void> rebind(WidgetTester tester) async {
    await tester.runAsync(() async {
      await AuthStore.instance.bindWorkerIdentity(
        username: 'wangye_go',
        password: 'pw-not-real',
        api: ApiClient(dio: dio),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120)); // 让脱离的回源链跑完（见上）
    });
    await settle(tester, times: 16);
  }

  /// 一次**普通通知**（不是身份级动作）：进身份页会拉一次绑定状态 → `AuthStore.notifyListeners`。
  /// 同样必须走 `runAsync`（理由见 [rebind]）。
  Future<void> plainNotification(WidgetTester tester) async {
    await tester.runAsync(() async {
      await AuthStore.instance.fetchIdentityStatus(api: ApiClient(dio: dio));
    });
  }

  // ==========================================================================
  // ① 前置：分部请求失败 → 提示（「重试」）真的在屏上
  // ==========================================================================
  group('① 前置：失败先"看得见"', () {
    testWidgets('分部接口 500 → 出现「分部列表加载失败（服务端暂时不可用）」+「重试」', (tester) async {
      server.sessionValid = true; // 会话本身有效，失败来自服务端 500（身份不会被吊销）
      await pumpHall(tester);

      expect(AuthStore.instance.workerIdentity, isTrue, reason: '前提：仍在打手态（本用例不动身份）');
      expect(server.calls(kPerm), greaterThanOrEqualTo(1));
      expect(find.textContaining('分部列表加载失败'), findsOneWidget, reason: '失败必须让人看见');
      expect(find.textContaining('服务端暂时不可用'), findsOneWidget, reason: '原因用服务端中文原文');
      expect(find.text('重试'), findsOneWidget, reason: '给出下一步（本次要修的就是"不该需要它"）');
      expect(find.text('全部'), findsNothing, reason: '胶囊整排不出现（失败的直接后果）');
      expect(tester.takeException(), isNull);
    });

    testWidgets('会话已失效（旧令牌 → 401「未登录」）同样看得见 —— 负责人实测原文', (tester) async {
      await pumpHall(tester);
      await settle(tester, times: 6);

      expect(find.textContaining('分部列表加载失败（未登录）'), findsOneWidget, reason: '一字不差');
      expect(find.text('重试'), findsOneWidget);
    });
  });

  // ==========================================================================
  // ② 正向：重新绑定成功 → 提示消失 + 重新拉取（计数 + 新令牌）
  // ==========================================================================
  group('② 重新绑定成功 → 旧错误消失 + 分部与大厅都重新拉', () {
    testWidgets('重绑（仍在打手态、只换令牌）→ 提示消失、胶囊出现、发起**新的**分部请求（带新令牌）', (tester) async {
      server.sessionValid = true;
      await pumpHall(tester);

      // 前置：屏上是失败态
      expect(find.textContaining('分部列表加载失败'), findsOneWidget, reason: '前置：先让失败留在屏上');
      final int permBefore = server.calls(kPerm);
      final int hallBefore = server.calls(kHall);
      final int epochBefore = AuthStore.instance.identityEpoch;

      // 用户重新绑定（真实路径）：服务端签发新伴随令牌
      await rebind(tester);

      expect(AuthStore.instance.identityEpoch, greaterThan(epochBefore),
          reason: '重绑成功必须涨"身份代" —— 否则页面无从知道"手上那份结论过期了"');
      expect(AuthStore.instance.workerIdentity, isTrue, reason: '仍在打手态（这正是旧实现好不了的原因）');
      expect(AuthStore.instance.companionToken, kNewToken, reason: '装上了新伴随令牌');

      // 核心三条
      expect(find.textContaining('分部列表加载失败'), findsNothing,
          reason: '重绑成功后旧错误**必须自己消失**（用户不该手点「重试」）');
      expect(find.text('重试'), findsNothing);
      expect(server.calls(kPerm), greaterThan(permBefore),
          reason: '必须**真的又发了一次**分部请求（只清提示不重拉 = 换了账号还显示上一个账号的分部）');
      expect(server.authOf(kPerm), 'Bearer $kNewToken',
          reason: '这一发必须用**新令牌**（用旧令牌重拉等于白拉，服务端只会再回 401）');
      expect(server.calls(kHall), greaterThan(hallBefore), reason: '大厅内容也要一起回源（要求：分部 + 大厅）');
      expect(find.text('全部'), findsOneWidget, reason: '胶囊行回来了');
      expect(find.text('分区d1 · 手游'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('**会话真的过期**（旧令牌 401 把身份打掉）后重绑 → 同样自己恢复', (tester) async {
      await pumpHall(tester); // sessionValid=false → 401，AuthStore 会因此丢掉打手身份
      await settle(tester, times: 6);
      expect(find.textContaining('分部列表加载失败（未登录）'), findsOneWidget);

      final int permBefore = server.calls(kPerm);
      await rebind(tester);

      expect(server.calls(kPerm), greaterThan(permBefore), reason: '重绑后回源确认一次');
      expect(find.textContaining('分部列表加载失败'), findsNothing, reason: '旧会话的失败提示不得残留');
      expect(find.text('分区d1 · 手游'), findsOneWidget, reason: '新会话的分部胶囊出现');
    });
  });

  // ==========================================================================
  // ③ 负向：没有重绑动作 → 不许自作主张重拉，也不许偷偷抹掉提示
  // ==========================================================================
  group('③ 负向：与身份无关的通知 → 不重拉、不改屏', () {
    testWidgets('拉一次绑定状态（普通 notifyListeners）→ 分部请求计数**不变**、提示**仍在**', (tester) async {
      server.sessionValid = true;
      await pumpHall(tester);
      expect(find.textContaining('分部列表加载失败'), findsOneWidget);

      final int permBefore = server.calls(kPerm);
      final int epochBefore = AuthStore.instance.identityEpoch;

      // 普通通知（进身份页就会拉一次；与"重绑"无关）
      await plainNotification(tester);
      await settle(tester, times: 8);

      expect(AuthStore.instance.identityEpoch, epochBefore, reason: '"代"没涨 = 这不是一次身份级成功动作');
      expect(server.calls(kPerm), permBefore,
          reason: '**负向**：没有重绑动作就不许重拉（否则每次资料刷新都多一轮请求）');
      expect(find.textContaining('分部列表加载失败'), findsOneWidget,
          reason: '也不许把提示偷偷抹掉 —— 问题还在，就必须还看得见');
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('重复通知（连续两次）同样不触发——防抖不是靠"只监听一次"', (tester) async {
      server.sessionValid = true;
      await pumpHall(tester);
      final int permBefore = server.calls(kPerm);

      await plainNotification(tester);
      await settle(tester, times: 4);
      await plainNotification(tester);
      await settle(tester, times: 8);

      expect(server.calls(kPerm), permBefore);
      expect(find.textContaining('分部列表加载失败'), findsOneWidget);
    });
  });

  // ==========================================================================
  // ④ 机制：只有身份级成功动作才涨"代"
  // ==========================================================================
  group('④ 机制：AuthStore.identityEpoch 的语义', () {
    test('切换身份 / 重绑 → +1；资料刷新与普通通知 → 不涨', () async {
      final epoch0 = AuthStore.instance.identityEpoch;

      // 普通通知：不涨
      AuthStore.instance.debugSetSession(accessToken: 'boss-primary-token');
      expect(AuthStore.instance.identityEpoch, epoch0, reason: '普通会话通知不是一次身份切换');

      // 身份级动作：切到打手态 → +1（本地已有 companion 令牌）
      await AuthStore.instance.switchToWorker();
      expect(AuthStore.instance.identityEpoch, epoch0 + 1, reason: '切换身份成功 = 一代');

      // 已经在打手态时**再切一次**（= 重新绑定换令牌的形状）→ 仍然 +1
      await AuthStore.instance.switchToWorker();
      expect(AuthStore.instance.identityEpoch, epoch0 + 2,
          reason: '重新绑定换的是令牌、身份标记不变 —— 只按"身份标记有没有变"判断就漏掉这条最重要的场景');

      // 切回老板态 → +1
      await AuthStore.instance.switchToBoss();
      expect(AuthStore.instance.identityEpoch, epoch0 + 3);

      // 已经是老板态时重复调用（幂等分支）→ 不涨
      await AuthStore.instance.switchToBoss();
      expect(AuthStore.instance.identityEpoch, epoch0 + 3, reason: '什么都没发生就不该涨代');
    });
  });
}
