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

/// 打手态 · 接单大厅**重新绑定后自动恢复**的出图（2026-10-06 体验修复）。
///
/// 产出（`apps/boss-app/build/`）：
///   `rebind_hall_recovered.png` —— **重绑成功后**的大厅：残留的「分部列表加载失败（未登录）」
///   已经自己消失、分部胶囊行正常、订单列表正常（用户全程**没有点过「重试」**）。
///
/// ## 这张图为什么这么拍
/// 假服务器 `_RebindHallRouter` **执行真实的服务端守卫规则**（受保护接口缺/错令牌 → 401「未登录」），
/// 并且**会话在重绑那一刻才被签发**：
///   ① 进入页面时旧伴随令牌已失效 → 401 → 屏上出现「分部列表加载失败（未登录）」（出图前先断言它真的在）；
///   ② 走**真实重绑路径**（`AuthStore.bindWorkerIdentity` → 服务端签发新伴随令牌）；
///   ③ 页面**自己**清掉旧结论并回源 → 提示消失、胶囊出现、列表出内容。
/// 也就是说：这张图证明的不是"画得好不好看"，而是**"没人点重试，它自己好了"**。
///
/// ## 数据可复跑铁律（2026-10-06 负责人要求）
/// 全部数据**注入**（不抓线上目录）：商品名/单号/金额/公告/在线数都不来自线上。
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（**msyh 放最前**，标点覆盖最广）；
/// 同时挂 `MaterialIcons`（否则 `Icons.*` / `AppIcon.*` 全是空心方框）—— 两条都是本项目既有做法。
void main() {
  const cjk = 'RebindHallShotCJK';
  final boundary = Key('rebind-hall-shot');

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
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
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
    // 打手态：primary（老板）+ companion（打手，**已失效**，等重绑换新）
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
      companionToken: kExpiredToken,
      companionRefreshToken: '$kExpiredToken-refresh',
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

  testWidgets('出图：重绑成功后大厅自动恢复正常 —— 残留错误提示消失、胶囊与列表回来（全程未点重试）', (tester) async {
    phone(tester);
    final router = _RebindHallRouter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://rebind-shot.local/api/v1'))..httpClientAdapter = router);

    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
        home: Scaffold(body: IdentityWorkerHallPage(api: api)),
      ),
    ));
    await settle(tester);

    // ---- 出图前：① 先把"失败态"钉住（否则这张图证明不了"恢复"）----
    expect(textCount(tester, '重试'), 1, reason: '重绑前：屏上确实挂着失败提示与「重试」（会话已过期）');
    expect(find.textContaining('分部列表加载失败（未登录）'), findsOneWidget, reason: '负责人实测原文');
    expect(textCount(tester, '全部'), 0, reason: '重绑前：分部胶囊整排不出现');
    final int permBefore = router.calls(kPermKey);

    // ---- ② 走真实重绑路径（服务端签发新的伴随令牌）----
    // ⚠️ 必须 runAsync：testWidgets 的假时钟区里直接 await 真网络 Future 会挂住（本项目实测过）
    await tester.runAsync(() async {
      await AuthStore.instance.bindWorkerIdentity(
        username: 'wangye_go',
        password: 'shot-not-real',
        api: api,
      );
      // 页面**自己**发起的回源是脱离本 await 的（`unawaited`），跑在真异步区 ——
      // 这里必须给真事件循环一次机会，否则请求发出去了、响应却永远落不到屏上
      // （实测现象：断言"没残留提示"过、但"全部"胶囊不出现）。
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await settle(tester);

    // ---- ③ 出图前把"这张图证明了什么"全部断言掉（图是证据，断言是回归）----
    expect(AuthStore.instance.companionToken, kFreshToken, reason: '装上了新伴随令牌');
    expect(router.calls(kPermKey), greaterThan(permBefore),
        reason: '页面**自己**又发了一次分部请求（用户没点「重试」）');
    expect(router.authOf(kPermKey), 'Bearer $kFreshToken', reason: '这一发用的是**新令牌**');
    expect(textCount(tester, '重试'), 0, reason: '残留的「重试」提示必须自己消失');
    expect(find.textContaining('分部列表加载失败'), findsNothing, reason: '不许残留任何"上一个会话的结论"');
    expect(textCount(tester, '全部'), 1, reason: '分部胶囊行回来了（第一个永远是「全部」）');
    expect(textCount(tester, '和平精英 · 手游'), greaterThanOrEqualTo(1));
    expect(textCount(tester, '三角洲行动 · 手游'), greaterThanOrEqualTo(1));
    expect(textCount(tester, pid1), 1, reason: '大厅列表正常出内容');
    expect(textCount(tester, pid2), 1);
    expect(tester.takeException(), isNull);

    await shoot(tester, boundary, 'rebind_hall_recovered.png');

    // 收尾：放掉可能挂起的请求，避免污染同一进程里的其它出图用例
    await tester.runAsync(router.quiesce);
    await settle(tester, frames: 5);
  });

  // ---------------------------------------------------------------------------
  // 负向：**没有**重绑动作时，同样的失败态必须原样留着（不许被"顺手抹掉"）
  // 这一条不额外出图，只把"提示消失 = 真的换了会话"这条因果钉死。
  // ---------------------------------------------------------------------------
  testWidgets('**负向**：不重绑 → 提示与「重试」原样留着（不会莫名其妙自己消失）', (tester) async {
    phone(tester);
    final router = _RebindHallRouter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://rebind-shot.local/api/v1'))..httpClientAdapter = router);

    await tester.pumpWidget(RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
        home: Scaffold(body: IdentityWorkerHallPage(api: api)),
      ),
    ));
    await settle(tester);
    final int permBefore = router.calls(kPermKey);

    // 只做一次"普通刷新"（拉绑定状态；与重绑无关）
    await tester.runAsync(() async {
      await AuthStore.instance.fetchIdentityStatus(api: api);
    });
    await settle(tester);

    expect(router.calls(kPermKey), permBefore, reason: '没有重绑动作就不许重拉');
    expect(find.textContaining('分部列表加载失败（未登录）'), findsOneWidget, reason: '问题还在，就必须还看得见');
    expect(textCount(tester, '重试'), 1);

    await tester.runAsync(router.quiesce);
  });
}

const String kExpiredToken = 'companion-shot-expired';
const String kFreshToken = 'companion-shot-fresh';
const String kPermKey = 'GET /worker/division-permissions';
const String kDivisionsKey = 'GET /divisions';
const String kHallKey = 'GET /worker/order-hall';
const String kBindKey = 'POST /user/identity/bind';
const String kMeKey = 'GET /auth/me';
const String kIdentityKey = 'GET /user/identity';

/// 假服务器：**记录 headers** + **执行服务端守卫规则**（受保护接口缺/错令牌 → 401「未登录」）
///
/// [kBindKey] 被调用时"服务端签发新的伴随会话"：这一刻起只有 [kFreshToken] 有效。
class _RebindHallRouter implements HttpClientAdapter {
  final List<({String key, Map<String, dynamic> headers})> log = <({String key, Map<String, dynamic> headers})>[];
  final List<Completer<void>> _gates = <Completer<void>>[];

  /// 服务端当前认可的伴随令牌：**重绑前一个都没有**（旧令牌已被服务端吊销），
  /// 重绑那一刻起只有 [kFreshToken] 有效 —— 这正是"会话过期 → 重新绑定"的形状。
  String validToken = '';

  int calls(String key) => log.where((r) => r.key == key).length;

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

  static List<Map<String, dynamic>> _divisions() => <Map<String, dynamic>>[
        <String, dynamic>{'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
        <String, dynamic>{'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
      ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    log.add((key: key, headers: <String, dynamic>{...options.headers}));

    // 守卫：受保护接口的令牌不对 → 401「未登录」（与服务端同文案、同状态码）
    if (key == kPermKey) {
      if (authOf(kPermKey) != 'Bearer $validToken') {
        return _json({'code': 401, 'message': '未登录', 'data': null}, status: 401);
      }
      return _json({'code': 0, 'message': 'ok', 'data': {'list': _divisions()}});
    }

    // 重绑：签发新伴随会话
    if (key == kBindKey) {
      validToken = kFreshToken;
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'bindingId': '77',
          'rebound': true,
          'companionToken': kFreshToken,
          'companionRefreshToken': '$kFreshToken-refresh',
          'worker': {
            'workerNo': 'W20260118',
            'nickname': '王野',
            'workerStatus': 1,
            'canTakeOrder': true,
            'divisionPermissions': _divisions(),
          },
        }
      });
    }

    if (key == kMeKey) {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'id': '2',
          'username': 'wangye_go',
          'nickname': '王野',
          'role': 'worker',
          'worker': {'workerNo': 'W20260118', 'canTakeOrder': true, 'divisionPermissions': _divisions()},
        }
      });
    }

    if (key == kIdentityKey) {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'bound': true,
          'activeCount': 1,
          'maxPerBoss': 1,
          'message': '',
          'bindings': [
            {
              'bindingId': '77',
              'status': 'active',
              'worker': {
                'workerNo': 'W20260118',
                'nickname': '王野',
                'workerStatus': 1,
                'canTakeOrder': true,
                'divisionPermissions': _divisions(),
              },
            }
          ],
        }
      });
    }

    if (key == kDivisionsKey) {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': '1', 'name': '和平精英', 'onlineCount': 7},
          {'id': '2', 'name': '三角洲行动', 'onlineCount': 4},
        ]
      });
    }

    if (key == kHallKey) {
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
              'divisionId': '2',
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
