import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/home_shell.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// **身份直切**（负责人 2026-10-06 截图反馈）—— 弹层里一键在
/// 「打手态 ↔ 管理员态」之间来回切，不重输账密、不先切回老板态。
///
/// 本次唯一的语义变更：**管理员受限会话在同一 App 运行期内保留在内存**
/// （**仍然绝不落盘** —— 冷启动后必须重新验证，这是安全底线）。
///
/// 覆盖负责人点名的 7 组：
/// ① 两身份都在时弹层出现两张卡片 + 两个切换按钮；当前身份那颗显示「正在使用」且不可点
/// ② 点「切换为管理员」→ **不发任何绑定请求**、进管理员态（管理员壳挂载 / 打手壳卸载 / 打手态 WS 已断开）
/// ③ 点「切换为打手」→ 回打手态（管理员壳卸载、切走时不断言建连 → 打手态 WS 建立）
/// ④ 冷启动后仍在老板态 + **管理员令牌未落盘**（弹层显示"未验证"而不是「正在使用」）
/// ⑤ 目标令牌失效（401）→ **留在原身份** + 中文提示 + 不出现"两边都不是"的空白态
/// ⑥ 12h 过期（续期通道 401）→ 按既有逻辑丢弃 + 中文提示
/// ⑦ 「绑定上限」提示**不影响切换按钮可用性**（负向断言）
void main() {
  late _Router router;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    router = _Router();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://direct.local'))..httpClientAdapter = router;
  });

  setUp(() {
    router.reset();
    ApiCache.instance.clear();
    RealtimeClient.shared.debugResetCounters();
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
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
    AppIdentityBar.onBandTap = null;
  });

  /// 有界推进（不用 pumpAndSettle：Toast 的 2s Timer 会让它永不结束）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// **把"会打接口"的那一步推进到完成**（本文件唯一允许的"等网络"方式）
  ///
  /// 为什么不能直接 `await store.bindRechargeAdmin(...)`（2026-10-06 修挂起时实测）：
  /// `testWidgets` 的测试体跑在 **fake async** 里 —— 假时钟只在 `tester.pump()` 时才走一格、
  /// 顺带 flush 微任务；而一个"裸 await 真异步"会把测试体挂在一个**只有 pump 才会推进**的
  /// 未来上，于是谁都不动 → **整个用例永久挂起**（表现为 `flutter test` 卡到天荒地老，
  /// 不是失败、没有超时提示，正是前一位同学踩到的那 2 分钟）。
  /// 实测证据：同一个 `ApiClient.request`，`test()`（真异步）通过、`tester.runAsync(...)` 通过、
  /// `testWidgets` 里裸 await **挂死**。
  ///
  /// 因此统一走"起任务 → 有界 pump 到标志位翻转 → 出错照抛"：
  /// 既不依赖假时钟的推进细节，也**永远不会**挂在没有帧推进的等待上。
  Future<void> drive(WidgetTester tester, Future<void> future, {int frames = 60}) async {
    var done = false;
    Object? failure;
    StackTrace? trace;
    unawaited(future.then<void>(
      (_) => done = true,
      onError: (Object e, StackTrace s) {
        failure = e;
        trace = s;
        done = true;
      },
    ));
    for (var i = 0; i < frames && !done; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (!done) {
      throw StateError('drive：${frames * 50}ms 假时钟内没有完成（是不是又裸 await 真异步了？）');
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  /// 短推进（400ms）：断言 Toast 必须用它 —— `AppToast` 2000ms 自动消失
  Future<void> settleShort(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> flushToasts(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2200));
    AppToast.dismiss();
  }

  /// **有界推进直到某段文字上屏**（返回是否出现）——断言 Toast 时必须用它
  ///
  /// 为什么不能"推完 40 帧再断言"（2026-10-06 实测）：`AppToast` 2000ms 后自动消失，
  /// 而失败回退这条路径的提示**是在这 2000ms 窗口内某处出现的** —— 推完整个窗口再断言，
  /// 提示早没了（本条用例首版就是这样拿到 `Found 0 widgets`，而日志里那句 Toast 明明弹过）。
  /// 这里改成"出现即停"，既不等满窗口，也不依赖"第几帧弹"这种脆断言。
  Future<bool> pumpUntilText(WidgetTester tester, String text, {int frames = 40}) async {
    for (var i = 0; i < frames; i++) {
      if (find.textContaining(text).evaluate().isNotEmpty) return true;
      await tester.pump(const Duration(milliseconds: 50));
    }
    return find.textContaining(text).evaluate().isNotEmpty;
  }

  ApiClient api() => ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://direct.local'))..httpClientAdapter = router);

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// 打手 + 管理员**两个受限会话同时在内存**（本次功能的前提）
  ///
  /// ⚠️ 必须**一次调用**把两套都摆好：`debugSetIdentity` 对每个槽位是"传了才改、没传就清"
  /// 的语义（它会把未传的 `companionToken` 置 null），分两次调用会互相抹掉。
  ///
  /// ⚠️ **绑定上限还要同步给假接口**：弹层里那张卡的数据源是 `GET /user/identity`
  /// （弹层 initState 自己拉一次，见 `_loadStatus`），注入的 `status` 只够撑住"注入即可见"的
  /// 那几处断言。首版漏了这一步 → ⑦「已达上限」用例拿到的永远是 router 里写死的 maxPerBoss:2，
  /// 上限说明压根不出现（这就是那条失败的真实原因，不是实现的问题）。
  void bindBothSessions({int maxPerBoss = 2, int activeCount = 1, int pending = 2}) {
    router
      ..maxPerBoss = maxPerBoss
      ..activeCount = activeCount;
    AuthStore.instance.debugSetIdentity(
      companionToken: 'companion-token',
      companionRefreshToken: 'companion-refresh',
      status: IdentityBindingStatus.fromJson({
        'bound': true,
        'activeCount': activeCount,
        'maxPerBoss': maxPerBoss,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '小云',
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
        'username': 'lingyun_go',
        'nickname': '小云',
        'role': 'worker',
        'worker': {
          'workerNo': 'W20260118',
          'canTakeOrder': true,
          'divisionPermissions': [
            {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
          ],
        },
      }),
      adminToken: 'recharge-token',
      adminRefreshToken: 'recharge-refresh',
      adminMe: RechargeAdminMe.fromJson({
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': pending,
        'expiresIn': 43200,
      }),
    );
  }

  /// 只摆打手会话（用于"冷启动/未验证管理员"的场景）
  void bindWorkerSession({int maxPerBoss = 2, int activeCount = 1}) {
    AuthStore.instance.debugSetIdentity(
      companionToken: 'companion-token',
      companionRefreshToken: 'companion-refresh',
      status: IdentityBindingStatus.fromJson({
        'bound': true,
        'activeCount': activeCount,
        'maxPerBoss': maxPerBoss,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '小云',
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
        'username': 'lingyun_go',
        'nickname': '小云',
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

  Future<void> pumpShell(WidgetTester tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: HomeShell(identityApi: api()),
    ));
    await settle(tester);
  }

  /// 打开身份弹层（点细带 → 宿主注册的弹层；这里直接从宿主入口走，等价于"点细带"）
  Future<void> openSheetFromBand(WidgetTester tester) async {
    expect(find.byKey(AppIdentityBar.bandTapKey), findsOneWidget, reason: '细带主体可点（宿主已注册）');
    await tester.tap(find.byKey(AppIdentityBar.bandTapKey));
    await settle(tester);
    expect(find.byType(IdentitySwitchSheet), findsOneWidget);
  }

  /// 卡片里的那颗切换按钮（按文案定位；「正在使用」= 当前身份那颗）
  ///
  /// [frames] 用来控制"点完之后推进多久"：断言 Toast 的用例要传小值，
  /// 再用 [pumpUntilText] "出现即停"（推满 2000ms 会把要断言的提示等没）。
  Future<void> tapSwitch(WidgetTester tester, String label, {int frames = 40}) async {
    await tester.ensureVisible(find.text(label));
    await settle(tester);
    await tester.tap(find.text(label));
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // =====================================================================================
  // ① 两张卡片 + 两个切换按钮 + 当前身份标识
  // =====================================================================================
  testWidgets('① 两身份都在时：弹层两张卡片 + 两个切换按钮，当前身份「正在使用」且不可点', (tester) async {
    bindBothSessions();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);

    // 两张卡片：打手（工号/昵称/已授权分部） + 管理员（昵称/账号）
    expect(find.text('小云'), findsOneWidget);
    expect(find.textContaining('W20260118'), findsOneWidget);
    expect(find.text('周砚'), findsOneWidget);
    expect(find.text('recharge_zhou'), findsOneWidget);

    // 两个切换按钮（当前是老板态 → 两颗都可点，都不是「正在使用」）
    expect(find.text('切换为打手'), findsOneWidget);
    expect(find.text('切换为管理员'), findsOneWidget);
    expect(find.text('正在使用'), findsNothing, reason: '老板态下两个都不是"当前"');
    expect(find.text('当前'), findsNothing, reason: '老板态下没有身份卡是"当前"');

    // 上限提示只在"想新增绑定"处出现，且写明不影响切换
    expect(find.text('绑定新的打手账号'), findsOneWidget);
    expect(find.textContaining('不影响上面的身份切换'), findsNothing, reason: '未达上限时不该出现上限说明');

    // 两颗按钮都可点（都还不是当前身份）
    final buttons = tester.widgetList<AppIdentityPrimaryButton>(find.byType(AppIdentityPrimaryButton)).toList();
    expect(buttons.where((b) => b.label == '切换为打手').single.onPressed, isNotNull);
    expect(buttons.where((b) => b.label == '切换为管理员').single.onPressed, isNotNull);
    await flushToasts(tester);
  });

  testWidgets('① 当前在打手态时：打手卡带「当前」徽标 + 「正在使用」置灰，管理员卡仍可点', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToWorker();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);

    expect(find.text('当前'), findsOneWidget, reason: '只有当前身份那张卡带徽标');
    expect(find.text('正在使用'), findsOneWidget);
    final buttons = tester.widgetList<AppIdentityPrimaryButton>(find.byType(AppIdentityPrimaryButton)).toList();
    expect(buttons.where((b) => b.label == '正在使用').single.onPressed, isNull, reason: '当前身份那颗不可点');
    expect(buttons.where((b) => b.label == '切换为管理员').single.onPressed, isNotNull);
    expect(find.text('切换为打手'), findsNothing, reason: '已在打手态 → 不再显示"切换为打手"');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ② 点「切换为管理员」→ 不发绑定请求 + 进管理员态 + 打手态 WS 断开
  // =====================================================================================
  testWidgets('② 打手态 → 点「切换为管理员」：不发绑定请求、管理员壳挂载、打手壳卸载、打手 WS 断开', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToWorker(); // 当前在打手态
    await pumpShell(tester);
    expect(find.byType(IdentityWorkerShell), findsOneWidget);

    final connectBefore = RealtimeClient.shared.debugConnectCount;
    final disconnectBefore = RealtimeClient.shared.debugDisconnectCount;
    router.bindCalls = 0;

    await openSheetFromBand(tester);
    expect(find.text('正在使用'), findsOneWidget, reason: '当前是打手态 → 打手卡显示"正在使用"');
    await tapSwitch(tester, '切换为管理员');

    // ① 不发任何**绑定**请求（令牌已在内存）
    expect(router.bindCalls, 0, reason: '直切不该打任何绑定接口');
    // ② 身份已切到管理员 + 壳换掉了
    expect(AuthStore.instance.identity, AppIdentity.admin);
    expect(AuthStore.instance.adminIdentity, isTrue);
    await settle(tester);
    expect(find.byType(RechargeAdminShell), findsOneWidget, reason: '管理员壳已挂载');
    expect(find.byType(IdentityWorkerShell), findsNothing, reason: '打手壳已卸载');
    // ③ 打手态的 WS 已断开，且**管理员态不再新建连接**（服务端握手直接拒绝 kind=recharge）
    expect(RealtimeClient.shared.debugDisconnectCount, disconnectBefore + 1, reason: '切走时断开打手态 WS');
    expect(RealtimeClient.shared.debugConnectCount, connectBefore, reason: '管理员态不建 WS');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ③ 点「切换为打手」→ 回打手态（管理员壳卸载 + 打手 WS 建立）
  // =====================================================================================
  testWidgets('③ 管理员态 → 点「切换为打手」：管理员壳卸载、打手态 WS 用 companion 令牌建立', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToAdmin(); // 当前在管理员态
    await pumpShell(tester);
    expect(find.byType(RechargeAdminShell), findsOneWidget);

    RealtimeClient.shared.debugResetCounters();
    router.bindCalls = 0;

    await openSheetFromBand(tester);
    expect(find.text('正在使用'), findsOneWidget, reason: '当前是管理员态 → 管理员卡显示"正在使用"');
    await tapSwitch(tester, '切换为打手');

    expect(router.bindCalls, 0);
    expect(AuthStore.instance.adminIdentity, isFalse);
    expect(AuthStore.instance.workerIdentity, isTrue);
    await settle(tester);
    expect(find.byType(IdentityWorkerShell), findsOneWidget, reason: '打手壳已挂载');
    expect(find.byType(RechargeAdminShell), findsNothing, reason: '管理员壳已卸载');
    // 先断（离开管理员态）再连（打手态用 companion 令牌）
    expect(RealtimeClient.shared.debugDisconnectCount >= 1, isTrue);
    expect(RealtimeClient.shared.debugConnectCount >= 1, isTrue);
    expect(RealtimeClient.shared.debugLastConnectToken, 'companion-token');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ④ 冷启动：回老板态 + 管理员令牌未落盘
  // =====================================================================================
  testWidgets('④ 冷启动后仍在老板态，且**管理员令牌未落盘**（弹层显示"未验证"而不是「正在使用」）', (tester) async {
    // 记录所有"要写安全存储"的意图（debugStorageDisabled 下写会被跳过，但意图会被记下来）
    final writes = <String, List<String?>>{};
    AuthStore.debugOnStorageWrite = (k, v) => (writes[k] ??= []).add(v);
    addTearDown(() => AuthStore.debugOnStorageWrite = null);

    bindWorkerSession();
    await AuthStore.instance.switchToWorker();
    // ⚠️ 这两步**会打接口** → 必须走 drive（裸 await 会挂死，见 drive 注释）
    await drive(
      tester,
      AuthStore.instance.bindRechargeAdmin(username: 'recharge_zhou', password: 'pw', api: api()),
    );
    expect(AuthStore.instance.adminIdentity, isTrue);
    await AuthStore.instance.switchToBoss();
    // 本次运行内仍保留（这是本次要的体验）
    expect(AuthStore.instance.adminBound, isTrue, reason: '运行期内保留内存会话');

    // —— 不落盘的直接证据：管理员令牌（键或值）从未被写过 ——
    for (final entry in writes.entries) {
      expect(entry.key.contains('recharge'), isFalse, reason: '管理员令牌不许有落盘键：${entry.key}');
      for (final v in entry.value) {
        expect(v, isNot('recharge-token'), reason: '管理员令牌的值不许被写进任何键：${entry.key}');
      }
    }
    expect(writes.keys.contains('identity_active'), isTrue, reason: '只有身份标记/伴随令牌那几项会落盘');

    // —— 模拟冷启动：内存清空后重新 init（读到的只有落盘内容）——
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(accessToken: 'primary-token');
    // init() 内部会 `GET /auth/me`（真网络）→ 同样必须 drive
    await drive(tester, AuthStore.instance.init());

    expect(AuthStore.instance.identity, AppIdentity.boss, reason: '冷启动必回老板态');
    expect(AuthStore.instance.adminBound, isFalse, reason: '管理员会话必须没了（内存不落盘）');
    expect(AuthStore.instance.adminIdentity, isFalse);

    // 弹层里体现为"未验证"，而不是「正在使用」
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);
    expect(find.text('未验证'), findsOneWidget);
    expect(find.text('验证管理员账号'), findsOneWidget);
    expect(find.text('正在使用'), findsNothing);
    expect(find.text('切换为管理员'), findsNothing, reason: '没有会话时不给"切换"，只给"去验证"');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑤ 目标令牌失效（401）→ 留在原身份 + 中文提示 + 不出现空白态
  // =====================================================================================
  testWidgets('⑤ 打手态 → 切管理员失败（401）：留在打手态 + 中文提示 + 不出空白态', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToWorker();
    await pumpShell(tester);
    expect(find.byType(IdentityWorkerShell), findsOneWidget);

    // 管理员会话已被移出白名单：切过去之后第一条请求 401
    router.rechargeUnauthorized = true;

    await openSheetFromBand(tester);
    // 点完只推 100ms（够弹层收起 + 管理员壳挂载），随后"出现即停"地等那句中文提示
    await tapSwitch(tester, '切换为管理员', frames: 2);
    // 管理员态起壳 → 第一条请求 401 → AuthStore 回退到**切换前的身份**
    final noticed = await pumpUntilText(tester, '受限管理身份已失效');
    // 回退是"请求 401 → 丢会话 → 换壳"三步，第三步要等壳的切换过渡动画走完
    // （中途会同时存在新旧两层壳，`findsOneWidget` 会在那一刻误报"找到 2 个"）
    await settle(tester);

    expect(AuthStore.instance.adminIdentity, isFalse);
    expect(AuthStore.instance.adminBound, isFalse, reason: '失效会话被丢弃');
    expect(AuthStore.instance.workerIdentity, isTrue, reason: '回退到切换前的打手态（不是被扔回老板态）');
    expect(find.byType(IdentityWorkerShell), findsOneWidget, reason: '不出现"两边都不是"的空白态');
    expect(find.byType(RechargeAdminShell), findsNothing);
    // 中文提示（服务端原文）
    expect(noticed, isTrue, reason: '回退时必须给出中文原因（提示在 2s 内出现即为通过）');
    await flushToasts(tester);
  });

  testWidgets('⑤ 管理员态 → 切打手失败（companion 401）：留在管理员态 + 中文提示', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToAdmin();
    await pumpShell(tester);
    expect(find.byType(RechargeAdminShell), findsOneWidget);

    // 打手绑定已被解绑：切过去后 companion 令牌 401
    router.companionUnauthorized = true;

    await openSheetFromBand(tester);
    await tapSwitch(tester, '切换为打手', frames: 2);
    final noticed = await pumpUntilText(tester, '打手身份已失效');
    // 同 ⑤ 前一条：等"丢会话 + 换壳"彻底落地再断言最终状态
    await settle(tester);

    expect(AuthStore.instance.workerIdentity, isFalse);
    expect(AuthStore.instance.adminIdentity, isTrue, reason: '回退到切换前的管理员态');
    expect(find.byType(RechargeAdminShell), findsOneWidget, reason: '壳还在，不是空白态');
    expect(find.byType(IdentityWorkerShell), findsNothing);
    expect(noticed, isTrue, reason: '回退时必须给出中文原因（提示在 2s 内出现即为通过）');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑥ 12h 过期 → 按既有逻辑丢弃 + 提示
  // =====================================================================================
  testWidgets('⑥ 12h 到期（续期通道 401）→ 丢弃管理员会话 + 中文提示，老板态不受影响', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToAdmin();
    await pumpShell(tester);

    // 模拟"用着用着到期"：受限令牌 401 → 客户端走它的续期通道 → 续期也被拒（12h 硬上限）
    router.refreshRechargeUnauthorized = true;
    await tester.runAsync(() async {
      ApiClient.lastFailedToken = 'recharge-token';
      await AuthStore.instance.refreshAccessToken();
      ApiClient.lastFailedToken = null;
    });
    await settleShort(tester);

    expect(AuthStore.instance.adminIdentity, isFalse);
    expect(AuthStore.instance.adminBound, isFalse, reason: '到期后必须重新验证');
    expect(AuthStore.instance.accessToken, 'primary-token', reason: '老板态会话分毫不动');
    expect(find.textContaining('管理员身份已过期'), findsOneWidget);
    expect(find.byType(RechargeAdminShell), findsNothing);
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑦ 上限提示不影响切换按钮可用性（负向断言）
  // =====================================================================================
  testWidgets('⑦ 已达绑定上限时：上限说明出现，但两个切换按钮**仍然可点**（负向断言）', (tester) async {
    bindBothSessions(maxPerBoss: 1, activeCount: 1); // 上限=1 且已用满
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);

    // 上限提示确实在（且写明不影响切换）
    expect(find.textContaining('本机最多绑定 1 个打手账号'), findsOneWidget);
    expect(find.textContaining('不影响上面的身份切换'), findsOneWidget);
    // 「绑定新的打手账号」置灰
    final buttons = tester.widgetList<AppIdentityPrimaryButton>(find.byType(AppIdentityPrimaryButton)).toList();
    expect(buttons.where((b) => b.label == '绑定新的打手账号').single.onPressed, isNull);

    // 但切换按钮**可用**（这是本组的负向断言：上限 ≠ 不能切换）
    expect(buttons.where((b) => b.label == '切换为打手').single.onPressed, isNotNull);
    expect(buttons.where((b) => b.label == '切换为管理员').single.onPressed, isNotNull);

    // 真点一下也能切（不是只看按钮属性）
    await tapSwitch(tester, '切换为管理员');
    expect(AuthStore.instance.adminIdentity, isTrue, reason: '上限不影响切换');
    await flushToasts(tester);
  });

  // =====================================================================================
  // 附：细带主体可点 → 打开同一个弹层（从打手态/管理员态直达切换）
  // =====================================================================================
  testWidgets('附：打手态点细带主体 → 直接打开身份弹层（一次点击，不必先回老板态）', (tester) async {
    bindBothSessions();
    await AuthStore.instance.switchToWorker();
    await pumpShell(tester);

    await openSheetFromBand(tester);
    expect(find.text('切换为管理员'), findsOneWidget, reason: '弹层里直接给出另一身份的切换入口');
    await flushToasts(tester);
  });
}

/// 假服务器：身份/充值相关接口 + 老板端最小底座
class _Router implements HttpClientAdapter {
  bool rechargeUnauthorized = false;
  bool companionUnauthorized = false;
  bool refreshRechargeUnauthorized = false;
  int bindCalls = 0;

  /// `GET /user/identity` 下发的绑定上限（按用例设置；弹层卡片的数据源）
  int maxPerBoss = 2;
  int activeCount = 1;

  void reset() {
    rechargeUnauthorized = false;
    companionUnauthorized = false;
    refreshRechargeUnauthorized = false;
    bindCalls = 0;
    maxPerBoss = 2;
    activeCount = 1;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};
    if (key == 'POST /user/identity/bind' || key == 'POST /user/identity/bind-recharge-admin') {
      bindCalls += 1;
    }
    if (key == 'POST /user/identity/bind-recharge-admin') {
      return _body(envelope({
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'rechargeToken': 'recharge-token',
        'rechargeRefreshToken': 'recharge-refresh',
        'expiresIn': 43200,
      }));
    }
    if (key == 'POST /user/identity/refresh-recharge-admin') {
      if (refreshRechargeUnauthorized) {
        return _body({'code': 401, 'message': '管理员身份已过期，请重新验证管理员账号', 'data': null}, status: 401);
      }
      return _body(envelope({'rechargeToken': 'recharge-token-2', 'rechargeRefreshToken': 'r2', 'expiresIn': 43200}));
    }
    if (key == 'GET /user/identity') {
      return _body(envelope({
        'bound': true,
        'activeCount': activeCount,
        'maxPerBoss': maxPerBoss,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '小云',
              'workerStatus': 1,
              'divisionPermissions': [
                {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
              ],
            },
          }
        ],
      }));
    }
    if (key == 'POST /user/identity/unbind') return _body(envelope({'ok': true}));

    // ---- 管理员态（受限会话）----
    if (key == 'GET /recharge/requests') {
      if (rechargeUnauthorized) {
        return _body({'code': 401, 'message': '受限管理身份已失效，请联系超级管理员重新授权', 'data': null}, status: 401);
      }
      return _body(envelope({'list': const [], 'total': 0, 'pendingCount': 0}));
    }
    if (key == 'GET /recharge/me') {
      if (rechargeUnauthorized) {
        return _body({'code': 401, 'message': '受限管理身份已失效，请联系超级管理员重新授权', 'data': null}, status: 401);
      }
      return _body(envelope({
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }));
    }

    // ---- 打手态三屏 ----
    if (key == 'GET /worker/order-hall') {
      if (companionUnauthorized) {
        return _body({'code': 401, 'message': '打手身份已失效，请重新绑定打手账号', 'data': null}, status: 401);
      }
      return _body(envelope({'list': const [], 'total': 0, 'page': 1, 'pageSize': 50}));
    }
    if (key == 'GET /worker/division-permissions') return _body(envelope(const {'list': []}));
    if (key == 'GET /worker/orders') return _body(envelope(const {'list': [], 'total': 0}));
    if (key == 'GET /worker/my-wallet') {
      return _body(envelope(const {'balance': 0, 'totalIncome': 0, 'settlementCount': 0}));
    }
    if (key == 'GET /worker/cs/conversations') return _body(envelope(const {'list': [], 'unread': 0}));
    if (key == 'GET /auth/me') {
      if (companionUnauthorized) {
        return _body({'code': 401, 'message': '打手身份已失效，请重新绑定打手账号', 'data': null}, status: 401);
      }
      return _body(envelope(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
      }));
    }

    // ---- 老板端最小底座 ----
    if (key == 'GET /public/clubs') return _body(envelope(const []));
    if (key == 'GET /public/site') return _body(envelope(const {'clubTitle': '官方自营', 'clubParagraphs': ['全段位上分']}));
    if (key == 'GET /public/banners') return _body(envelope(const []));
    if (key == 'GET /public/recharge/config') {
      return _body(envelope(const {
        'amountOptions': [6, 20],
        'customEnabled': true,
        'minYuan': 6,
        'maxYuan': 200,
        'pointsPerYuan': 10,
        'noticeText': '付款后请上传截图并提交申请',
        'qrCodes': [
          {'id': '1', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/1'}
        ],
      }));
    }
    if (key == 'GET /divisions/grouped') return _body(envelope(const []));
    // 等级规则：服务端给的是**数组**（LevelRulesStore 直接按 List 解析）
    if (key == 'GET /public/levels') return _body(envelope(const []));
    if (key == 'GET /user/wallet') return _body(envelope(const {'balance': 0}));
    if (key == 'GET /user/orders') return _body(envelope(const {'list': [], 'total': 0}));
    if (key == 'GET /user/conversations') return _body(envelope(const {'list': [], 'total': 0}));
    if (key == 'GET /user/friends') return _body(envelope(const {'list': []}));
    if (key == 'GET /user/friends/requests/incoming') return _body(envelope(const {'list': []}));
    if (key == 'GET /user/notifications') return _body(envelope(const {'list': [], 'unread': 0}));
    if (key == 'POST /user/ai/reset') return _body(envelope(const {'ok': true}));
    return _body(envelope(const {'list': [], 'total': 0}));
  }

  ResponseBody _body(Object body, {int status = 200}) => ResponseBody.fromString(
        body is String ? body : jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
