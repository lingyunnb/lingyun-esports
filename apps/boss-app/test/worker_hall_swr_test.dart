import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打手态 · **接单大厅延迟专项**（负责人 2026-10-06 反馈「抢单大厅切换延迟巨大」）
///
/// 把"切分部必须瞬时"钉成 6 条**可复跑**的断言，全部对着**用户能看见的东西**
/// （屏上的商品名 / chip 选中态 / 有没有整页转圈 / 发没发请求），而不是对着内部字段：
///
/// ① **切 chip 立即生效**：点完 chip 只 pump 一帧 → 选中态已变 + **旧列表仍在屏上**
///    （`_loading` 不再整页遮挡 —— 这是"不再出现整页转圈/骨架闪烁"的硬断言）
/// ② **进页面即预取**：全部可用分部各预取一次；切过去当帧就有内容
/// ③ **缓存键含 divisionId**（明确的**负向**断言）：切到分部 2 后屏上**绝不能出现**
///    分部 1 / 「全部」的单，反之亦然 —— 三个键互不串味
/// ④ **下拉刷新仍发强制请求**：用户主动刷新走 `force` 路径（预取缓存不得吸收它）
/// ⑤ **抢单动作仍走实时**：`POST /worker/orders/:id/grab` 真实发出，且成功后大厅**强制回源**
/// ⑥ **请求数**：权限 60s TTL —— 切三次分部也不会重复拉权限（原实现每切一次都重拉）
///
/// 纪律（本项目铁律）：**不用 `pumpAndSettle()`** —— 大厅里有
/// `CircularProgressIndicator` 这类无限动画，`pumpAndSettle` 会一直等下去。
/// 统一用有界 `settle()`（30 帧 × 50ms 假时钟），必然结束。
void main() {
  late _HallRouter router;
  late ApiClient api;

  /// 三个键各一份**互不相同**的商品名做指纹（串味一眼可见）
  const pidAll = '保2红单';
  const pid1 = '清图绝密';
  const pid2 = '博弈宝冠';

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
  });

  setUp(() {
    router = _HallRouter();
    // 注入 dio → 该实例保持调用方地址、不被运行期下发地址改写（与既有测试同一套路）
    api = ApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://hall.local/api/v1'))..httpClientAdapter = router,
    );
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'primary-token',
      me: AuthMe.fromJson(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U1',
        'nickname': '阿远',
        'role': 'user',
        'level': 1,
      }),
    );
    enterWorkerState();
    ApiCache.instance.endSession();
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
    ApiCache.instance.endSession();
  });

  /// 「全部」那个键：**不带** `divisionId` 参数的大厅请求
  ///
  /// 注意不能写成"query 传 null 就不筛"（那样会把带 divisionId 的三条一起数进来）——
  /// 必须**显式断言该参数不存在**（2026-10-06 首版就踩了这个坑，测试自己骗自己）。
  int hallRequestsForAll() => router
      .requestsFor('GET', '/worker/order-hall')
      .where((r) => !r.query.containsKey('divisionId'))
      .length;

  int hallRequestsFor(String divisionId) => router.requestsOf(
        'GET',
        '/worker/order-hall',
        query: {'divisionId': divisionId},
      );

  int hallRequestCount() => router.requestsFor('GET', '/worker/order-hall').length;

  /// **有界**推进（见文件头纪律）
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpHall(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: IdentityWorkerHallPage(api: api)),
    ));
  }

  /// chip 文字颜色：选中态是白色（与页面实现同源判据）
  Color? chipTextColor(WidgetTester tester, String label) =>
      labelText(chipElement(tester, label), label).style?.color;

  /// 点某个 chip
  Future<void> tapChip(WidgetTester tester, String label) async {
    final el = chipElement(tester, label);
    await tester.tap(find.byElementPredicate((e) => e == el));
  }

  // =====================================================================================
  // ① 切 chip 立即生效：选中态同帧变 + 旧列表仍在屏上（不整页转圈）
  // =====================================================================================
  testWidgets('① 切 chip：一帧内选中态已变 + 旧列表仍在屏上（无整页转圈）', (tester) async {
    await pumpHall(tester);
    await settle(tester);

    expect(find.text(pidAll), findsOneWidget, reason: '首屏（全部）已出内容');
    expect(chipTextColor(tester, '全部'), Colors.white, reason: '「全部」初始选中');

    // 切分部：只推进**一帧**
    await tapChip(tester, '和平精英 · 手游');
    await tester.pump();

    expect(chipTextColor(tester, '和平精英 · 手游'), Colors.white, reason: '点下去选中态必须当帧生效');
    expect(chipTextColor(tester, '全部'), isNot(Colors.white), reason: '旧 chip 必须同时取消选中');

    // 关键：首屏那个**整页**转圈（22dp 居中）不允许在切分部时出现（它就是"骨架闪烁"）。
    // 注意不能用 `findsNothing` —— 事实行右侧那个 10dp 细进度（后台刷新指示）本来就会在，
    // 那正是设计要的"列表保持可见 + 只有细进度在动"。所以要判的是"有没有**大的**转圈"。
    final spinners = tester.widgetList<CircularProgressIndicator>(find.byType(CircularProgressIndicator)).toList();
    for (final s in spinners) {
      final box = tester.getSize(find.byWidget(s));
      expect(box.width, lessThan(20), reason: '切分部只允许 10dp 细进度，不允许 22dp 整页转圈');
    }
    expect(
      find.text(pidAll).evaluate().isNotEmpty || find.text(pid1).evaluate().isNotEmpty,
      isTrue,
      reason: '要么缓存已把新分部铺上屏，要么旧列表还留着 —— 绝不能是空白',
    );

    await settle(tester);
    expect(find.text(pid1), findsOneWidget, reason: '后台回源后换成新分部数据');
    expect(find.text(pidAll), findsNothing);
  });

  // =====================================================================================
  // ② 进页面即预取 + 切过去不重复拉
  // =====================================================================================
  testWidgets('② 进页面即预取全部可用分部；切过去当帧出内容', (tester) async {
    await pumpHall(tester);
    await settle(tester);

    expect(hallRequestsForAll(), 1, reason: '「全部」首屏 1 次');
    expect(hallRequestsFor('1'), 1, reason: '阶段 2 预取分部 1');
    expect(hallRequestsFor('2'), 1, reason: '阶段 2 预取分部 2');
    expect(hallRequestCount(), 3, reason: '可用分部 = 全部 + 1 + 2，各一次');
    expect(hallRequestsFor('3'), 0, reason: '无权限分部（canTakeOrder=false）不该被预取');

    final before = hallRequestCount();

    await tapChip(tester, '三角洲行动 · 手游');
    await tester.pump();
    expect(find.text(pid2), findsOneWidget, reason: '预取命中：切过去当帧就有内容（0 网络等待）');

    await settle(tester);
    expect(find.text(pid2), findsOneWidget);
    expect(hallRequestCount(), before + 1, reason: '切过去只允许一次静默确认回源，不按次重复拉');
  });

  // =====================================================================================
  // ③ 负向断言：三个键的数据绝不串味
  // =====================================================================================
  testWidgets('③ 负向断言：分部之间数据不串味（缓存键含 divisionId）', (tester) async {
    await pumpHall(tester);
    await settle(tester);

    await tapChip(tester, '和平精英 · 手游');
    await settle(tester);
    expect(find.text(pid1), findsOneWidget);
    expect(find.text(pid2), findsNothing, reason: '分部 1 的屏上不能出现分部 2 的单');
    expect(find.text(pidAll), findsNothing, reason: '分部 1 的屏上不能出现「全部」的单');

    await tapChip(tester, '三角洲行动 · 手游');
    await settle(tester);
    expect(find.text(pid2), findsOneWidget);
    expect(find.text(pid1), findsNothing, reason: '分部 2 的屏上不能出现分部 1 的单');

    await tapChip(tester, '全部');
    await settle(tester);
    expect(find.text(pidAll), findsOneWidget);
    expect(find.text(pid1), findsNothing);
    expect(find.text(pid2), findsNothing);
  });

  // =====================================================================================
  // ④ 下拉刷新仍走 force
  // =====================================================================================
  testWidgets('④ 下拉刷新：发强制请求（force 路径保留）', (tester) async {
    await pumpHall(tester);
    await settle(tester);

    final before = hallRequestsForAll();
    await tester.fling(find.byType(RefreshIndicator), const Offset(0, 320), 1200);
    await settle(tester, frames: 60);

    expect(hallRequestsForAll(), greaterThan(before), reason: '用户主动下拉 = 强制回源，缓存不得吸收它');
  });

  // =====================================================================================
  // ⑤ 抢单动作仍走实时
  // =====================================================================================
  testWidgets('⑤ 抢单：真实 POST + 成功后大厅强制回源', (tester) async {
    await pumpHall(tester);
    await settle(tester);

    final hallBefore = hallRequestsForAll();
    await tester.tap(find.text('抢单').first);
    // 抢单成功会弹 AppToast（带 2s 自动消失定时器）→ 推进的假时钟必须**盖过它**，
    // 否则测试框架会在拆卸时报 "A Timer is still pending"（本项目既有坑）
    await settle(tester, frames: 60);

    expect(router.requestsFor('POST', '/worker/orders/9/grab').length, 1,
        reason: '抢单必须发真实请求（缓存只用于展示，写操作永远实时）');
    expect(hallRequestsForAll(), greaterThan(hallBefore), reason: '抢完必须回源：刚抢到的单不能还挂在屏上');
  });

  // =====================================================================================
  // ⑥ 请求数：权限不再被重复拉
  // =====================================================================================
  testWidgets('⑥ 请求数：权限 60s TTL，切三次分部只拉一次', (tester) async {
    await pumpHall(tester);
    await settle(tester);

    expect(router.requestsFor('GET', '/worker/division-permissions').length, 1, reason: '进页面拉一次权限');
    expect(router.requestsFor('GET', '/public/announcements').length, greaterThanOrEqualTo(1));
    expect(hallRequestsForAll(), 1);

    await tapChip(tester, '和平精英 · 手游');
    await settle(tester);
    await tapChip(tester, '三角洲行动 · 手游');
    await settle(tester);
    await tapChip(tester, '全部');
    await settle(tester);

    expect(router.requestsFor('GET', '/worker/division-permissions').length, 1,
        reason: '切分部与权限无关 —— 绝不能每切一次就重拉一次权限（原实现每次 _loadAll 都重拉）');
  });
}

/// chip 的 **Element**（点击与读样式都用它）
///
/// 为什么不写 `find.ancestor(of: find.text(x), matching: find.byType(GestureDetector))`：
/// 本项目实测（Flutter 3.47.2）它在本环境下**返回空集**，而把它喂给 `tester.widget<T>()` 时
/// 抛的是 `Bad state: No element`（栈落在 finders.dart 的 `allCandidates`）——
/// 极易误判成"UI 没渲染"。这里自己走一遍子树：行为确定、失败信息明确。
///
/// 放**顶层**而不是 `main()` 里：Dart 的局部函数必须先声明后使用，
/// 放在 `main()` 尾部会直接编译不过（2026-10-06 踩过）。
Element chipElement(WidgetTester tester, String label) {
  final candidates = find.byWidgetPredicate((w) => w is GestureDetector && w.onTap != null).evaluate().toList();
  for (final e in candidates) {
    if (_findLabel(e, label) != null) return e;
  }
  throw StateError('chip「$label」不存在（候选 ${candidates.length} 个）');
}

/// 该 Element 的子树里**恰好等于** [label] 的那个 Text
Text labelText(Element root, String label) {
  final found = _findLabel(root, label);
  if (found == null) throw StateError('子树里没有文本「$label」');
  return found;
}

Text? _findLabel(Element root, String label) {
  Text? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == label) {
      hit = w;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

/// 进入打手态（伴随会话 + 实时资料），与 `identity_switch_test.dart` 同一口径
void enterWorkerState() {  AuthStore.instance.debugSetIdentity(
    identity: AppIdentity.worker,
    companionToken: 'companion-token',
    companionRefreshToken: 'companion-refresh',
    status: IdentityBindingStatus.fromJson({
      'bound': true,
      'activeCount': 1,
      'maxPerBoss': 1,
      'bindings': [
        {
          'bindingId': '77',
          'status': 'active',
          'worker': {
            'workerNo': 'W20260118',
            'nickname': '王野',
            'workerStatus': 1,
            'divisionPermissions': const [
              {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            ],
          },
        }
      ],
    }),
    workerMe: AuthMe.fromJson(const {
      'id': '2',
      'username': 'wangye_go',
      'nickname': '王野',
      'role': 'worker',
      'worker': {
        'workerNo': 'W20260118',
        'canTakeOrder': true,
        'divisionPermissions': [
          {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
        ],
      },
    }),
  );
}

// =======================================================================================
// 假 ApiClient：按 (method, path, divisionId) 返回**互不相同**的指纹数据 + 请求计数
// =======================================================================================
class _HallRouter implements HttpClientAdapter {
  final List<_Req> requests = [];

  List<_Req> requestsFor(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path).toList();

  int requestsOf(String method, String path, {Map<String, String>? query}) =>
      requestsFor(method, path).where((r) {
        if (query == null) return true;
        for (final e in query.entries) {
          if ('${r.query[e.key]}' != e.value) return false;
        }
        return true;
      }).length;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final q = <String, String>{};
    options.queryParameters.forEach((k, v) => q[k.toString()] = v.toString());
    requests.add(_Req(options.method, options.path, q));

    final key = '${options.method} ${options.path}';

    if (key == 'GET /worker/division-permissions') {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '3', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': false},
          ]
        }
      });
    }

    if (key == 'GET /divisions') {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': '1', 'name': '和平精英', 'onlineCount': 3},
          {'id': '2', 'name': '三角洲行动', 'onlineCount': 2},
          {'id': '3', 'name': '三角洲行动', 'onlineCount': 1},
        ]
      });
    }

    if (key == 'GET /public/announcements') {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'title': '大厅公告', 'content': '新单进大厅'}
          ]
        }
      });
    }

    if (key == 'GET /worker/order-hall') {
      final divisionId = q['divisionId'];
      // 每个键一份**互不相同**的数据（串味断言就靠这个指纹）
      final spec = switch (divisionId) {
        '1' => (pid: '清图绝密', no: 'ORD2026100600011111', amount: 688, qty: 1),
        '2' => (pid: '博弈宝冠', no: 'ORD2026100600022222', amount: 366, qty: 1),
        '3' => (pid: '端游-包1000万', no: 'ORD2026100600033333', amount: 1497, qty: 3),
        _ => (pid: '保2红单', no: 'ORD2026100600099999', amount: 488, qty: 1),
      };
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'total': 1,
          'page': 1,
          'pageSize': 50,
          'list': [
            {
              'id': '9',
              'orderNo': spec.no,
              'totalAmount': spec.amount,
              'status': 'pending_take',
              'statusName': '待接单',
              'quantity': spec.qty,
              'createdAt': '2026-10-06T12:30:00Z',
              'productName': spec.pid,
              'divisionId': divisionId ?? '1',
            }
          ],
        }
      });
    }

    if (key == 'POST /worker/orders/9/grab') {
      return _json({'code': 0, 'message': 'ok', 'data': {'orderId': '9'}});
    }

    if (key == 'GET /user/conversation') {
      return _json({'code': 0, 'message': 'ok', 'data': {'id': '55'}});
    }

    return _json({'code': 404, 'message': 'Not Found', 'data': null}, status: 404);
  }

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}

class _Req {
  _Req(this.method, this.path, this.query);
  final String method;
  final String path;
  final Map<String, String> query;
}
