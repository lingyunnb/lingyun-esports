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

/// 打手态 · 接单大厅「切分部瞬时」**出图**（真机尺寸 390 × 844，中文 + Material 图标都挂上）
///
/// 产出（`apps/boss-app/build/`）：
/// 1. `hall_switch_1_tap_instant.png` —— **切分部瞬间**：旧列表**仍在屏上** +
///    新 chip 已选中（实底白字）+ 事实行右侧 10dp 细进度（后台刷新中）+ 顶部 2dp 细进度线；
///    **没有整页转圈、没有骨架闪屏**（这正是负责人要的"感知延迟"）
/// 2. `hall_switch_2_prefetch_hit.png` —— **预取命中后**：数据瞬时替换成该分部的单子
///
/// ## 数据可复跑铁律（2026-10-06 负责人要求，务必遵守）
/// 本文件**全部数据都是注入的**（`_HallShotRouter` 这个假 ApiClient）：
/// 商品名 / 单号 / 金额 / 分部 / 公告文案一个都不来自线上目录。
/// 原因就是当天踩过的坑：负责人随时会在管理端删商品、改名字（当天 11:46 就删了 2 件、改了 1 件），
/// 任何"抓线上响应再断言"的出图用例都会**随运营数据变红**，那不是回归信号，是噪声。
/// 需要打真接口验证服务端契约的用例请去 `scripts/tmp/` 写脚本，别放进出图用例。
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（`flutter test` 自带字体没有 CJK 字形，不挂会变豆腐块）；
/// 同时挂 `MaterialIcons` 让图标正常 —— 两条都是本项目既有出图脚本的既有做法。
///
/// 关键技术点（本项目既有坑，别回退）：
/// - `toImage` 必须在 `tester.runAsync` 里调（假时钟下它不会自己回帧）；
/// - **不用 `pumpAndSettle()`**：细进度是无限动画，settle 会一直等下去 → 用有界 `settle()`；
/// - 假适配器里**不要** `Future.delayed`（假时钟下永不触发）→ 用"放行开关"控制响应时机；
/// - 断言**不要**用 `find.text('商品名')`：本文件出图 1 实测它偶发返回 0（同一帧
///   `widgetList<Text>` 明明有这条文本）→ 一律用 `find.byWidgetPredicate((w) => w is Text && w.data == x)`，
///   见 [_textCount]。
void main() {
  const cjk = 'HallShotCJK';
  final boundary = Key('hall-shot');
  final boundaryFinal = Key('hall-shot-final');

  /// 注入的假数据（**与线上目录无关**，可复跑）
  const pidAll = '雪山速通·双子峰';
  const pidDiv1 = '机密档案·长弓溪谷';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/msyh.ttf',
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
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
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
    // 出图用例把缓存关掉：避免"上一条用例留下的缓存条目"让画面随执行顺序变化
    ApiClient.cacheEnabled = false;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'shot-token',
      me: AuthMe.fromJson(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
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
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
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

  /// **有界**推进（见文件头：不用 pumpAndSettle）
  Future<void> settle(WidgetTester tester, {int frames = 30}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget stage(Key k, ApiClient api) => RepaintBoundary(
        key: k,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: Scaffold(body: IdentityWorkerHallPage(api: api)),
        ),
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  // =====================================================================================
  // 出图 1：切分部瞬间
  // =====================================================================================
  testWidgets('出图 1：切分部瞬间（旧列表 + 新 chip 选中 + 细进度）', (tester) async {
    phone(tester);
    // 本图刻意**关缓存**：证明"没有缓存也不会整页转圈"（顺带让本用例与顺序无关）
    ApiClient.cacheEnabled = false;
    final router = _HallShotRouter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://shot.local/api/v1'))..httpClientAdapter = router);

    await tester.pumpWidget(stage(boundary, api));
    await settle(tester);

    // 首屏（全部）已出内容 —— 注入的假数据
    expect(_textCount(tester, pidAll), 1, reason: '首屏（全部）已出内容');
    expect(_textCount(tester, '和平精英 · 手游'), greaterThanOrEqualTo(1), reason: '分部胶囊已渲染');

    /**
     * 拍"切过去那一瞬间"的办法：[_HallShotRouter.responsive] 关掉 → 之后所有大厅响应都挂起。
     * 于是点 chip 之后的真实画面是：
     *   · chip 选中态在**点击那一帧**就变了
     *   · 列表仍是上一份（旧列表还在屏上，没有空白、没有骨架）
     *   · 事实行右侧 10dp 细进度 + 顶部 2dp 进度线在动（后台静默回源中）
     * 这三条同时成立，才是负责人要的"感知延迟 ≤300ms、不出现整页转圈/骨架闪烁"。
     * 本用例同时把缓存关掉了，所以这还顺带证明了**没有缓存时也不会整页转圈**。
     */
    router.responsive = false;

    // 切分部：只推进 3 帧（≈120ms 假时钟，远在"感知延迟 ≤300ms"之内）
    await tester.tap(_chipFinder(tester, '和平精英 · 手游'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));

    // 出图前把设计事实断言掉（图是证据，断言是回归）
    expect(_chipTextColor(tester, '和平精英 · 手游'), Colors.white, reason: '① 新 chip 已选中（实底白字）');
    expect(_chipTextColor(tester, '全部'), isNot(Colors.white), reason: '① 旧 chip 已取消选中');
    expect(_textCount(tester, pidAll), 1, reason: '② 旧列表仍在屏上（没有空白/骨架）');
    expect(_bigSpinnerCount(tester), 0, reason: '③ 只允许 10dp 细进度，不允许 22dp 整页转圈');

    await shoot(tester, boundary, 'hall_switch_1_tap_instant.png');

    // **收尾必须做**：放掉挂起的响应并等它们结束，否则那条请求会一直挂在
    // `ApiClient._inflight` 里，污染下一个用例（见 `_HallShotRouter.quiesce` 注释）
    await tester.runAsync(router.quiesce);
    await settle(tester);
  });

  // =====================================================================================
  // 出图 2：预取命中后
  // =====================================================================================
  testWidgets('出图 2：预取命中后（数据瞬时替换）', (tester) async {
    phone(tester);
    // 本图必须**开缓存**：预取写缓存 → 切过去命中缓存 → 当帧铺屏（这就是要拍的效果）
    ApiClient.cacheEnabled = true;
    final router = _HallShotRouter();
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://shot.local/api/v1'))..httpClientAdapter = router);

    await tester.pumpWidget(stage(boundaryFinal, api));
    await settle(tester);

    // 预取已覆盖可用分部（注入的假接口，计数可断言）
    expect(_textCount(tester, pidAll), 1, reason: '首屏已出内容');
    expect(router.hallCount('1'), 1, reason: '分部 1 已被预取（进页面阶段 2）');
    expect(router.hallCount('2'), 1, reason: '分部 2 已被预取');

    // 切到已预取的分部：当帧就该出该分部的数据（预取命中 → 0 网络等待）
    await tester.tap(_chipFinder(tester, '和平精英 · 手游'));
    await tester.pump();
    expect(_textCount(tester, pidDiv1), 1, reason: '预取命中：切过去当帧就是该分部的单');

    await settle(tester);
    expect(_textCount(tester, pidDiv1), 1);
    expect(_textCount(tester, pidAll), 0, reason: '已经换成新分部的列表');

    await shoot(tester, boundaryFinal, 'hall_switch_2_prefetch_hit.png');
  });
}

// =======================================================================================
// 断言小工具
// =======================================================================================

/// 屏上是否有**恰好等于** [text] 的 Text
///
/// 刻意不用 `find.text(...)`：本文件出图 1 实测它偶发返回 0（同一帧 `widgetList<Text>`
/// 里明明有这条文本）—— 出图用例必须确定性，所以走显式谓词。
int _textCount(WidgetTester tester, String text) =>
    find.byWidgetPredicate((w) => w is Text && w.data == text).evaluate().length;

/// 有没有 **22dp 整页转圈**（10dp 细进度不算）
int _bigSpinnerCount(WidgetTester tester) => tester
    .widgetList<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
    .where((s) => tester.getSize(find.byWidget(s)).width >= 20)
    .length;

/// chip 的 Element（不用 `find.ancestor`：本项目实测它在本环境返回空集）
Element _chipElement(WidgetTester tester, String label) {
  final candidates = find.byWidgetPredicate((w) => w is GestureDetector && w.onTap != null).evaluate().toList();
  for (final e in candidates) {
    if (_findLabel(e, label) != null) return e;
  }
  throw StateError('chip「$label」不存在（候选 ${candidates.length} 个）');
}

Finder _chipFinder(WidgetTester tester, String label) {
  final el = _chipElement(tester, label);
  return find.byElementPredicate((e) => e == el);
}

Color? _chipTextColor(WidgetTester tester, String label) =>
    _findLabel(_chipElement(tester, label), label)!.style?.color;

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
void enterWorkerState() {
  AuthStore.instance.debugSetIdentity(
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
// 假 ApiClient：**全部数据注入**（不依赖线上目录），并用 [responsive] 控制响应时机
// =======================================================================================
class _HallShotRouter implements HttpClientAdapter {
  final List<String> halls = [];
  final List<Completer<void>> _gates = [];

  /// true（默认）= 立刻回答；false = 大厅响应**挂起**（用来拍"后台刷新中"的真态）
  bool responsive = true;

  int hallCount(String divisionId) =>
      halls.where((q) => q.split('&').any((kv) => kv == 'divisionId=$divisionId')).length;

  /// **收尾必须调用**：把挂起的响应放掉，并推进真实异步直到它们真的结束。
  ///
  /// 为什么非做不可（2026-10-06 实测到的坑）：`ApiClient` 有一张**跨页面共享的**
  /// `_inflight` 去重表，键 = 缓存键。本文件出图 1 故意挂起大厅响应 → 那条请求一直挂在
  /// `_inflight` 里；下一个用例请求**同一个键**（同账号 + 同地址 + 同参数）时会命中那条
  /// **永远不完成**的 future 而直接返回，于是"预取"这个请求根本没发出去
  /// （症状：单独跑出图 2 通过、两个一起跑就 `hallCount('1') == 0`）。
  /// 收尾把门放掉并等真实异步走完，`_inflight` 才会被清掉。
  Future<void> quiesce() async {
    responsive = true;
    for (final g in _gates) {
      if (!g.isCompleted) g.complete();
    }
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final q = options.queryParameters.entries.map((e) => '${e.key}=${e.value}').join('&');
    final key = '${options.method} ${options.path}';

    if (key == 'GET /worker/order-hall') {
      halls.add(q);
      if (!responsive) {
        // 挂起：页面就停在"后台刷新中"（细进度在动），这正是出图 1 要拍的画面。
        // 不用 Future.delayed —— 假时钟下它不会触发。
        final gate = Completer<void>();
        _gates.add(gate);
        await gate.future;
      }
      final divisionId = '${options.queryParameters['divisionId'] ?? ''}';
      final spec = switch (divisionId) {
        '1' => (pid: '机密档案·长弓溪谷', no: 'ORD2026100600011111', amount: 688, div: '1'),
        '2' => (pid: '烽火地带·零号大坝', no: 'ORD2026100600022222', amount: 366, div: '2'),
        _ => (pid: '雪山速通·双子峰', no: 'ORD2026100600099999', amount: 488, div: '1'),
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
              'quantity': 2,
              'createdAt': '2026-10-06T12:34:00Z',
              'productName': spec.pid,
              'divisionId': spec.div,
            },
            {
              'id': '10',
              'orderNo': 'ORD2026100600044473',
              'totalAmount': 250,
              'status': 'pending_take',
              'statusName': '待接单',
              'quantity': 1,
              'createdAt': '2026-10-06T12:12:00Z',
              'productName': '烽火地带·航天基地',
              'divisionId': spec.div,
            },
          ],
        }
      });
    }

    if (key == 'GET /worker/division-permissions') {
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
            {'divisionId': '2', 'name': '三角洲行动', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
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
        ]
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
