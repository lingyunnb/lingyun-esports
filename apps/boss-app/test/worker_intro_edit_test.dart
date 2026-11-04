import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打手简介（陪玩介绍）· **打手自己写**（负责人 2026-10-17 改定）—— 客户端一侧验收
///
/// | 项 | 断言 |
/// |---|---|
/// | ① | 打手态「我的」**有且只有一处**简介入口：卡片直接显示当前简介原文 |
/// | ② | 点开 → 编辑弹层回填当前值；保存 = `PUT /worker/profile` + **companion 令牌** + 只带 `{intro}`（**没有 workerId**）；成功后卡片立刻变新文案 |
/// | ③ | 实时字数 `N/120`；少于 2 个字 → 保存不可用且**不发请求** |
/// | ④ | 服务端中文原文原样显示（「简介里不能留联系方式」），弹层不关、可继续改 |
/// | ⑤ | 首尾空白就地拦下（中文提示 + 不发请求） |
/// | ⑥ | **老板态「我的」页没有这个入口**（客户端一侧的身份隔离；真正边界在服务端 403） |
/// | ⑦ | 新增卡片的文案不引入打手态 22 词黑名单（设计稿硬规则） |
///
/// 假 ApiClient（假 Dio 适配器），**绝不发真网络**：这条链路的权威校验在服务端
/// （`server/src/modules/worker/worker-intro.rules.ts`），本文件只验证"客户端怎么用这个接口"。
void main() {
  late _IntroRouter router;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    router = _IntroRouter();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://intro.local'))..httpClientAdapter = router;
  });

  setUp(() {
    router.reset();
    ApiCache.instance.clear();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'primary-token',
      me: AuthMe.fromJson(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
        'level': 1,
      }),
    );
    // 进入打手态（companion 令牌）—— 打手态页面一律用 activeToken
    AuthStore.instance.debugSetIdentity(identity: AppIdentity.worker, companionToken: 'companion-token');
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  ApiClient api() => ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://intro.local'))..httpClientAdapter = router);

  /// **有界**推进（项目硬要求：用例必须能终止，不用 pumpAndSettle）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> flushToasts(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2200));
    AppToast.dismiss();
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      // 打手态外壳本身就是 Scaffold；单独 pump「我的」页时补一层，否则 InkWell 缺 Material 祖先
      home: Scaffold(body: page),
    ));
    await settle(tester);
  }

  List<String> visibleTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  /// 只保留本文件的请求（页面还会顺带拉钱包/资料）
  List<({String key, Map<String, dynamic>? body, String? token})> introCalls() =>
      router.calls.where((c) => c.key == 'PUT /worker/profile').toList();

  // =====================================================================================
  // ① 入口只有一处 + 卡片显示当前简介原文
  // =====================================================================================
  testWidgets('① 打手态「我的」有且只有一处简介入口，卡片直接显示当前简介原文', (tester) async {
    router.intro = '和平精英双排老手，稳定上分不墨迹。';
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));

    expect(find.text('个人介绍'), findsOneWidget, reason: '分区标题只有一处（结构规则 1：同一入口只出现一次）');
    expect(find.text('和平精英双排老手，稳定上分不墨迹。'), findsOneWidget, reason: '卡片要直接显示简介原文（打手需要看到"我在外面长什么样"）');
    expect(find.text('编辑'), findsOneWidget);
    // 数据来自 `GET /worker/profile`（不是本地猜的）
    expect(router.calls.map((c) => c.key), contains('GET /worker/profile'));
    await flushToasts(tester);
  });

  // =====================================================================================
  // ② 保存链路：companion 令牌、只带 intro、成功后卡片立刻更新
  // =====================================================================================
  testWidgets('② 保存 = PUT /worker/profile（companion 令牌，只带 intro，无 workerId）→ 卡片立刻变新文案', (tester) async {
    router.intro = '';
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));

    // 没写过简介 → 占位文案，点开就是空的输入框
    expect(find.textContaining('还没有写介绍'), findsOneWidget);
    await tester.tap(find.text('去填写'));
    await settle(tester);

    expect(find.text('个人介绍'), findsWidgets, reason: '弹层标题');
    await tester.enterText(find.byType(TextField), '三角洲端游老手，工作日 20:00 后在线');
    await settle(tester);

    router.intro = '三角洲端游老手，工作日 20:00 后在线';
    await tester.tap(find.text('保存'));
    await settle(tester);

    final calls = introCalls();
    expect(calls.length, 1, reason: '只发一次保存请求');
    expect(calls.single.token, 'companion-token', reason: '打手态必须用伴随令牌（activeToken），不能用老板 primary');
    expect(calls.single.body, {'intro': '三角洲端游老手，工作日 20:00 后在线'}, reason: '请求体只有 intro');
    expect(calls.single.body!.containsKey('workerId'), isFalse, reason: '**绝不接受请求体里的 workerId**（主体只从 JWT sub 取）');

    // 弹层已关、卡片立刻显示新文案（不等下一次拉取）
    expect(find.byType(TextField), findsNothing, reason: '保存成功必须关闭弹层');
    expect(find.text('三角洲端游老手，工作日 20:00 后在线'), findsOneWidget, reason: '「我的」页立刻可见新简介');
    expect(find.text('简介已保存'), findsOneWidget, reason: '要有成功反馈');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ③ 字数边界：实时计数 + 少于 2 个字不发请求
  // =====================================================================================
  testWidgets('③ 实时字数 N/120；不足 2 个字保存不可用且不发请求', (tester) async {
    router.intro = '';
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));
    await tester.tap(find.text('去填写'));
    await settle(tester);

    expect(find.text('0/120'), findsOneWidget, reason: '空输入时计数 0/120');

    await tester.enterText(find.byType(TextField), '好');
    await settle(tester);
    expect(find.text('1/120'), findsOneWidget, reason: '实时字数');
    expect(find.text('至少写 2 个字'), findsOneWidget, reason: '少于 2 个字要有就近提示');

    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(introCalls(), isEmpty, reason: '本地就能判定的长度问题不该发请求（服务端仍是权威）');

    // 补到 2 个字 → 计数变化
    await tester.enterText(find.byType(TextField), '好手');
    await settle(tester);
    expect(find.text('2/120'), findsOneWidget);
    expect(find.text('至少写 2 个字'), findsNothing, reason: '达标后提示消失');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ④ 服务端中文原文原样显示（联系方式拦截）
  // =====================================================================================
  testWidgets('④ 服务端拒绝（简介里不能留联系方式）→ 原文显示在弹层里，弹层不关', (tester) async {
    router.intro = '';
    router.putError = (code: 400, message: '简介里不能留联系方式');
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));
    await tester.tap(find.text('去填写'));
    await settle(tester);

    await tester.enterText(find.byType(TextField), '加我微信一起玩');
    await settle(tester);
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(introCalls().length, 1, reason: '真的要打到服务端才知道（客户端不复刻过滤规则）');
    expect(find.text('简介里不能留联系方式'), findsOneWidget, reason: '服务端中文原文照原样显示');
    expect(find.byType(TextField), findsOneWidget, reason: '失败时不能关弹层，用户要能就地改');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑤ 首尾空白就地拦下
  // =====================================================================================
  testWidgets('⑤ 首尾空白：就地拦下并给中文提示，不发请求', (tester) async {
    router.intro = '';
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));
    await tester.tap(find.text('去填写'));
    await settle(tester);

    await tester.enterText(find.byType(TextField), ' 前面有空格');
    await settle(tester);
    // 输入时就要说清楚为什么存不了（不是点了保存才报）
    expect(find.text('简介首尾不能有空格或换行'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(find.text('简介首尾不能有空格或换行'), findsOneWidget);
    expect(introCalls(), isEmpty, reason: '纯展示性问题，不必往返一次');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑥ 老板态没有这个入口（客户端一侧的身份隔离）
  // =====================================================================================
  testWidgets('⑥ 老板态「我的」页没有简介入口（只有打手态能编辑）', (tester) async {
    // 先确认打手态有：入口属于身份，不属于页面
    router.intro = '和平精英双排老手';
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));
    expect(find.text('个人介绍'), findsOneWidget);

    // 老板态「我的」页（真页面，不是替身）
    await tester.pumpWidget(MaterialApp(home: ProfilePage()));
    await settle(tester);
    expect(find.text('个人介绍'), findsNothing, reason: '老板态不许有编辑入口');
    expect(find.text('老板会看到这段话'), findsNothing, reason: '老板态不许有编辑入口');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑦ 新卡片不引入打手态黑名单词
  // =====================================================================================
  testWidgets('⑦ 新增「个人介绍」卡片的文案：打手态 22 词黑名单 0 命中', (tester) async {
    router.intro = '稳定上分不墨迹，工作日 20:00 后在线。';
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));

    final hits = IdentityWorkerCleanliness.violations(visibleTexts(tester));
    expect(hits, isEmpty, reason: '打手态出现老板端词：$hits\n${visibleTexts(tester)}');
    await flushToasts(tester);
  });
}

/// 假服务器：`/worker/profile` 读写 + 打手态「我的」页的最小底座
class _IntroRouter implements HttpClientAdapter {
  String intro = '';
  ({int code, String message})? putError;

  /// 已发请求（key = `METHOD path`）
  final List<({String key, Map<String, dynamic>? body, String? token})> calls = [];

  void reset() {
    intro = '';
    putError = null;
    calls.clear();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.path}';
    final auth = options.headers['Authorization'];
    final token = auth is String && auth.startsWith('Bearer ') ? auth.substring(7) : null;
    final data = options.data;
    calls.add((key: key, body: data is Map ? data.cast<String, dynamic>() : null, token: token));

    if (key == 'GET /worker/profile') {
      return _data({'intro': intro});
    }
    if (key == 'PUT /worker/profile') {
      final e = putError;
      if (e != null) return _json({'code': e.code, 'message': e.message, 'data': null}, e.code);
      final body = data is Map ? data['intro'] : null;
      intro = '${body ?? ''}';
      return _data({'ok': true, 'intro': intro});
    }

    // ---- 打手态「我的」页底座 ----
    if (key == 'GET /worker/my-wallet') {
      return _data(const {
        'balance': 320.5,
        'totalIncome': 1860.5,
        'settlementCount': 24,
        'tipIncome': 66,
      });
    }
    if (key == 'GET /auth/me') {
      return _data(const {
        'id': '9',
        'username': 'wangye_go',
        'uid': 'U20260118',
        'nickname': '王野',
        'role': 'worker',
        'worker': {'workerNo': 'W20260118', 'canTakeOrder': true},
      });
    }
    if (key == 'GET /user/identity') {
      return _data(const {'bound': true, 'activeCount': 1, 'maxPerBoss': 1, 'bindings': []});
    }

    // ---- 老板态「我的」页底座（⑥ 用真页面，需要这两条）----
    if (key == 'GET /user/wallet') {
      return _data(const {'balance': 1286.5});
    }
    if (key == 'GET /user/orders') {
      return _data(const {'list': [], 'total': 0});
    }
    if (key == 'GET /public/levels') {
      // `LevelRulesStore._fetch` 把 data 当 `List<dynamic>?` 解析 → 这里必须给数组
      return _data(const <dynamic>[]);
    }

    return _json({'code': 404, 'message': 'Not Found', 'data': null}, 404);
  }

  ResponseBody _data(Object? data, {int status = 200}) => _json({'code': 0, 'message': 'ok', 'data': data}, status);

  ResponseBody _json(Object? body, int status) => ResponseBody.fromString(
        body is String ? body : jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
