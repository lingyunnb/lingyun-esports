import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打手态 · 接单大厅**修复后出图**（2026-10-06 紧急修复：分部胶囊永远加载失败／未登录）。
///
/// 产出（`apps/boss-app/build/`）：
///   `hall_division_fixed.png` —— 修复后的大厅：**分部胶囊行正常出现** + 订单列表正常。
///
/// ## 这张图为什么这么拍（与别的出图用例的关键差别）
/// 假服务器 `_GuardedHallRouter` **执行真实的服务端守卫规则**：
/// `/worker/division-permissions` 缺 `Authorization` → **401「未登录」**。
/// 于是这张图不只是"好看"，它同时是一条**因果链证据**：
///   - 请求带令牌（本文件先断言 `Bearer companion-shot-token` 真的发出去了）→ 200 → 胶囊出屏；
///   - 若把 `worker_hall_page.dart` 里那行 `token:` 删掉（修复前形状）→ 401 → 胶囊整排消失。
/// 别的出图用例的假服务器不校验令牌，所以它们对本次 bug **完全无感** —— 这正是本次事故的教训。
///
/// ## 数据可复跑铁律（2026-10-06 负责人要求）
/// 全部数据**注入**（不抓线上目录）：商品名/单号/金额/公告都是一个字都不来自线上。
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（**msyh 放最前**，标点覆盖最广）；
/// 同时挂 `MaterialIcons`（否则 `Icons.*` / `AppIcon.*` 全是空心方框）—— 两条都是本项目既有做法。
void main() {
  const cjk = 'HallDivisionShotCJK';
  final boundary = Key('hall-division-shot');

  /// 注入的假数据（**与线上目录无关**，可复跑）
  const pid1 = '雪山速通·双子峰';
  const pid2 = '烽火地带·零号大坝';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // ① 中文：msyh 放最前
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/msyhbd.ttc',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    // ② 图标：MaterialIcons（不挂 → 图标全是方框）
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      'D:/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(iconPath);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  setUp(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false; // 出图与执行顺序无关
    // 打手态：primary（老板）+ companion（打手）—— 页面用的就是 activeToken
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(
        accessToken: 'boss-shot-token',
        me: AuthMe.fromJson(const {
          'id': '1',
          'username': 'ayuan',
          'uid': 'U8471209365',
          'nickname': '阿远',
          'role': 'user',
          'level': 1,
        }),
      );
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: kCompanionToken,
      companionRefreshToken: 'companion-shot-refresh',
      status: IdentityBindingStatus.fromJson(const {
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
              'divisionPermissions': [
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
    ApiCache.instance.endSession();
  });

  tearDown(() {
    AppToast.dismiss();
    ApiClient.cacheEnabled = true;
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession();
    ApiCache.instance.endSession();
  });

  Future<void> shoot(WidgetTester tester, Key key, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      final image = await b.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// **有界**推进（不用 `pumpAndSettle`：细进度是无限动画，settle 会一直等）
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// 屏上是否有**恰好等于** [text] 的 Text（本项目实测 `find.text` 在出图用例里偶发返回 0）
  int textCount(WidgetTester tester, String text) =>
      find.byWidgetPredicate((w) => w is Text && w.data == text).evaluate().length;

  testWidgets('出图：修复后的大厅 —— 分部胶囊正常出现 + 列表正常（令牌真的带上了）', (tester) async {
    phone(tester);
    final router = _GuardedHallRouter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://hall-shot.local/api/v1'))..httpClientAdapter = router);

    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
        home: Scaffold(body: IdentityWorkerHallPage(api: api)),
      ),
    ));
    await settle(tester);

    // ---- 出图前把"这张图证明了什么"断言掉（图是证据，断言是回归）----
    // ① 受保护接口**真的带上了打手态令牌**（本次 bug 的照妖镜）
    expect(router.authOf(kPermKey), 'Bearer $kCompanionToken',
        reason: '`/worker/division-permissions` 必须带 Authorization —— 不带就是 401「未登录」（本次事故）');
    // ② 公开接口**不带**令牌（缓存口径）
    expect(router.authOf(kDivisionsKey), isNull, reason: '`/divisions` 是公开接口，带上会破坏预取共用的缓存键');
    // ③ 胶囊行正常出现（含"全部"）
    expect(textCount(tester, '全部'), 1, reason: '胶囊行第一个永远是「全部」');
    expect(textCount(tester, '和平精英 · 手游'), greaterThanOrEqualTo(1), reason: '授权分部胶囊出现');
    expect(textCount(tester, '三角洲行动 · 手游'), greaterThanOrEqualTo(1), reason: '第二个授权分部胶囊出现');
    // ④ 失败提示**不存在**（修复后的正常态）
    expect(textCount(tester, '重试'), 0, reason: '正常态不该出现「重试」');
    expect(find.textContaining('分部列表加载失败'), findsNothing);
    // ⑤ 列表正常（注入的两条单）
    expect(textCount(tester, pid1), 1, reason: '大厅列表正常出内容');
    expect(textCount(tester, pid2), 1);
    expect(tester.takeException(), isNull);

    await shoot(tester, boundary, 'hall_division_fixed.png');

    // 收尾：放掉可能挂起的请求，避免污染同一进程里的其它出图用例
    await tester.runAsync(router.quiesce);
    await settle(tester, frames: 5);
  });

  // ---------------------------------------------------------------------------
  // 反向：同一台假服务器下，**不带令牌**就是 401 → 胶囊消失（因果链的另一半）
  // 这一条不额外出图，只把"图里那条因果"钉死。
  // ---------------------------------------------------------------------------
  testWidgets('**因果链**：同一夹具下没有令牌 → 401「未登录」→ 胶囊整排消失（复现事故现象）', (tester) async {
    phone(tester);
    final router = _GuardedHallRouter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://hall-shot.local/api/v1'))..httpClientAdapter = router);

    // 把会话摆成"没有可用令牌"——页面于是发出不带 Authorization 的请求（与线上漏传 token 同一形状）
    AuthStore.instance
      ..debugClearIdentity()
      ..debugSetSession(accessToken: null);
    expect(AuthStore.instance.activeToken, isNull);

    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
        home: Scaffold(body: IdentityWorkerHallPage(api: api)),
      ),
    ));
    await settle(tester, frames: 40);

    expect(router.authOf(kPermKey), isNull, reason: '确认真的是"没带头"发出的');
    expect(find.textContaining('分部列表加载失败（未登录）'), findsOneWidget, reason: '负责人实测原文，一字不差');
    expect(textCount(tester, '全部'), 0, reason: '胶囊整排不出现（事故现象）');
  });
}

const String kCompanionToken = 'companion-shot-token';
const String kPermKey = 'GET /worker/division-permissions';
const String kDivisionsKey = 'GET /divisions';

/// 假服务器：**记录 headers** + **执行服务端守卫规则**（受保护接口缺 Authorization → 401「未登录」）
class _GuardedHallRouter implements HttpClientAdapter {
  final List<({String key, Map<String, dynamic> headers})> log = <({String key, Map<String, dynamic> headers})>[];
  final List<Completer<void>> _gates = <Completer<void>>[];

  Map<String, dynamic>? lastHeaders(String key) {
    final hits = log.where((r) => r.key == key);
    return hits.isEmpty ? null : hits.last.headers;
  }

  String? authOf(String key) {
    final h = lastHeaders(key);
    if (h == null) return null;
    for (final e in h.entries) {
      if (e.key.toLowerCase() == 'authorization') return e.value is String ? e.value as String : null;
    }
    return null;
  }

  /// 收尾：放掉挂起响应（见既有出图用例的 `_inflight` 坑）
  Future<void> quiesce() async {
    for (final g in _gates) {
      if (!g.isCompleted) g.complete();
    }
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    log.add((key: key, headers: <String, dynamic>{...options.headers}));

    // 守卫：受保护接口没有 Authorization → 401「未登录」（与服务端同文案、同状态码）
    if (key == kPermKey && authOf(kPermKey) == null) {
      return _json({'code': 401, 'message': '未登录', 'data': null}, status: 401);
    }

    if (key == kPermKey) {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '2', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
          ]
        }
      });
    }

    if (key == kDivisionsKey) {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': '1', 'name': '和平精英', 'onlineCount': 7},
          {'id': '2', 'name': '三角洲行动 · 手游', 'onlineCount': 4},
        ]
      });
    }

    if (key == 'GET /worker/order-hall') {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'total': 2,
          'page': 1,
          'pageSize': 50,
          'list': [
            {
              'id': '9',
              'orderNo': 'ORD2026100600011111',
              'totalAmount': 688,
              'status': 'pending_take',
              'statusName': '待接单',
              'quantity': 2,
              'createdAt': '2026-10-06T12:34:00Z',
              'productName': '雪山速通·双子峰',
              'divisionId': '1',
            },
            {
              'id': '10',
              'orderNo': 'ORD2026100600044473',
              'totalAmount': 250,
              'status': 'pending_take',
              'statusName': '待接单',
              'quantity': 1,
              'createdAt': '2026-10-06T12:12:00Z',
              'productName': '烽火地带·零号大坝',
              'divisionId': '1',
            },
          ],
        }
      });
    }

    if (key == 'GET /public/announcements') {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'title': '派单规则更新', 'content': '晚间 8 点后加价 10%'}
          ]
        }
      });
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
