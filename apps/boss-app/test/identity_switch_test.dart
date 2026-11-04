import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/home_shell.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合并双端 · 客户端身份切换（A 套「同 App 双态」+ A+ 稿身份显示）
///
/// 覆盖负责人点名的 8 条验收 + A+ 清单的正向断言：
/// ① 未绑定时「我的」显示「当前身份：老板」+ 切换入口，打手态不可达
/// ② 绑定成功后**立即**切到打手态、底栏只有 3 项、无凸起、无浮标
/// ③ 打手态不出现任何老板端元素（设计稿 22 词黑名单逐屏断言）
/// ④ 打手态**每屏**都能找到身份细带（A+ ID-A：28dp、页头正下方、含工号与「切回老板」）
/// ⑤ 消息页**单页三分区**（老板 · 官方客服 · 好友；好友段**条件显示**：该打手账号确有好友会话时才出现）
/// ⑥ 切回老板态：导航恢复 5 项、打手态缓存与未读被清空
/// ⑦ 解绑需二次确认；解绑后回到老板态且入口显示「未绑定」
/// ⑧ 各错误态中文文案来自服务端（把假接口文案换掉 → 页面跟着换）
void main() {
  late _Router router;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://identity.local'));
    router = _Router();
    ApiClient.debugDefaultDio!.httpClientAdapter = router;
    _installBaseRoutes(router);
  });

  setUp(() {
    router.resetErrors();
    router.requests.clear();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession(
      accessToken: 'primary-token',
      me: AuthMe.fromJson(const {'id': '1', 'username': 'ayuan', 'uid': 'U8471209365', 'nickname': '阿远', 'role': 'user', 'level': 1}),
    );
    ApiCache.instance.endSession();
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  /// 进入打手态（模拟"绑定成功后"）
  Future<void> enterWorkerState({bool bound = true}) async {
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
    // 走一遍真实的身份切换（缓存维度 + WS 断开/重建都按生产路径执行）
    await AuthStore.instance.switchToWorker();
  }

  /// **有界**推进（本项目硬要求：用例必须能终止）
  ///
  /// 为什么不用 `pumpAndSettle()`：身份切换里有两类**无限动画** ——
  /// 过渡 Toast 的自动消失链、以及主按钮 busy 态的 `CircularProgressIndicator`。
  /// 只要有一帧被它们持续排进管线，`pumpAndSettle` 就会一直等下去
  /// （本项目此前已踩过 `toImage` 在假时钟下永不返回的同类坑）。
  /// 这里改成"最多 40 帧 × 50ms 假时钟"：既能把 HTTP future / 动画推进到位，又**必然结束**。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 切到老板态「我的」页
  ///
  /// 【2026-10-17 六项平铺改版】原来靠 `find.byIcon(AppIcon.mine)`（`AppIcon.of` 会镜像一枚
  /// 不可见 `Icon`，所以 byIcon 找得到）。新底栏直接用 `AppIcons.navMine` 画 filled 图标、
  /// **不再镜像旧 IconData** → byIcon 找不到。改成"在底栏组件内按标签点"，语义更稳
  /// （全局 `find.text('我的')` 会同时命中「我的」页标题，必须限定在 [AppBottomNav] 内）。
  Future<void> gotoBossMine(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(AppBottomNav),
      matching: find.text('我的'),
    ));
    await settle(tester);
  }

  /// 点打手态底栏的第 [index] 项（IndexedStack 会把三页的文本都留在树里，
  /// 所以必须**限定在底栏组件内**找，不能全局 find.text）
  Future<void> tapWorkerNav(WidgetTester tester, int index) async {
    await tester.tap(find.descendant(
      of: find.byType(AppPlainBottomNav),
      matching: find.text(IdentityWorkerMeta.navLabels[index]),
    ));
    await settle(tester);
  }

  /// 过渡 Toast 是 2s 自动消失的 **Timer**；测试结束前必须让它走完，
  /// 否则 flutter_test 会以 `!timersPending` 断言失败（踩过）。
  Future<void> flushToasts(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2200));
    AppToast.dismiss();
  }

  /// 弹层里的输入框（老板端消息页也有搜索框，全局 find.byType(TextField) 会抓错）
  Finder sheetField(int i) => find.descendant(
        of: find.byType(IdentitySwitchSheet),
        matching: find.byType(TextField),
      ).at(i);

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: HomeShell(identityApi: ApiClient()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 屏幕上所有可见文本（黑名单断言与"身份标识在哪一屏"都用它）
  List<String> visibleTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  // =====================================================================================
  // ① 未绑定：老板态显示「当前身份：老板」+ 切换入口；打手态不可达
  // =====================================================================================
  testWidgets('① 未绑定时「我的」页显示「当前身份：老板」+ 绑定入口（无「切换身份」），打手态不可达', (tester) async {
    router.identityBound = false;
    await pumpShell(tester);

    // 底部导航是老板态 5 项（含凸起），打手态底栏不存在
    expect(find.byType(AppBottomNav), findsOneWidget);
    expect(find.byType(AppPlainBottomNav), findsNothing, reason: '未绑定 → 打手态不可达');

    // 切到「我的」（底栏未选中态图标是 outlined）
    await gotoBossMine(tester);

    // 2026-10-13 方案 B（负责人批准）：**未绑定 = 没有可切换的第二身份** →
    // 入口文案退化为「绑定打手账号」，「切换身份」整行不出现（结构规则 2「不存在的东西不出现」）
    expect(find.text('绑定打手账号'), findsOneWidget, reason: '身份区块必须有唯一入口（未绑定时是绑定）');
    expect(find.text('切换身份'), findsNothing, reason: '未绑定 → 不存在"切换身份"这件事');
    expect(find.textContaining('当前身份：老板'), findsWidgets, reason: '必须显示当前身份');
    // ID-D / ID-E：可见标签（不只副标题文字）
    expect(find.byType(AppIdentityTag), findsNWidgets(2), reason: '资料头昵称行 + 身份分组行各一枚');
    expect(find.text('当前身份：老板'), findsNWidgets(2));
    // A+：老板态**不得**出现打手态细带
    expect(find.byType(AppIdentityBar), findsNothing);
  });

  // =====================================================================================
  // ② 绑定成功 → 立即切到打手态；底栏 3 项、无凸起、无浮标
  // =====================================================================================
  testWidgets('② 绑定成功后立即切到打手态：底栏只有 3 项、无凸起、无下单浮标', (tester) async {
    router.identityBound = false;
    await pumpShell(tester);
    await gotoBossMine(tester);

    await tester.ensureVisible(find.text('绑定打手账号'));
    await settle(tester);
    await tester.tap(find.text('绑定打手账号'));
    await settle(tester);

    // 弹层：账号 + 密码
    expect(find.text('切换身份'), findsWidgets);
    await tester.enterText(sheetField(0), 'wangye_go');
    await tester.enterText(sheetField(1), 'pw123456');
    await tester.tap(find.text('绑定并切换为打手'));
    await settle(tester);

    // 已进入打手态
    expect(find.byType(AppPlainBottomNav), findsOneWidget);
    expect(find.byType(AppBottomNav), findsNothing, reason: '打手态没有凸起位');
    expect(find.byType(AppOrderFab), findsNothing, reason: '打手态没有快速下单浮标');
    expect(IdentityWorkerMeta.navLabels, ['接单', '消息', '我的']);
    for (final label in ['接单', '消息', '我的']) {
      expect(find.text(label), findsWidgets);
    }
    // 老板端五项的文案一个都不该在底栏出现
    expect(find.text('祁小山'), findsNothing);
    expect(AuthStore.instance.workerIdentity, isTrue);
    expect(AuthStore.instance.activeToken, 'companion-token');
    expect(router.lastBearer('POST /user/identity/bind'), 'primary-token');
    // Toast 是 2s Timer：测试结束前让它走完，否则 !timersPending 断言失败
    await flushToasts(tester);
  });

  // =====================================================================================
  // ③ 打手态不出现任何老板端元素（22 词黑名单，三个 tab 逐屏）
  // =====================================================================================
  testWidgets('③ 打手态三屏逐屏黑名单 0 命中（设计稿 22 词）', (tester) async {
    await enterWorkerState();
    await pumpShell(tester);

    for (var tab = 0; tab < 3; tab++) {
      if (tab > 0) {
        await tapWorkerNav(tester, tab);
      }
      final texts = visibleTexts(tester);
      final hits = IdentityWorkerCleanliness.violations(texts);
      expect(hits, isEmpty, reason: '第 ${tab + 1} 屏命中老板端词：$hits\n全屏文本：$texts');
      // 反向：打手态不得出现「当前身份：老板」
      expect(texts.any((t) => t.contains(AppIdentityTag.bossLabel)), isFalse);
    }
    expect(IdentityWorkerCleanliness.bossOnlyWords.length, 22);
  });

  // =====================================================================================
  // ④ 打手态每屏都能找到身份细带（A+ ID-A / ID-B 正向断言）
  // =====================================================================================
  testWidgets('④ 打手态每屏都有身份细带：28dp、页头之下、含工号与「切回老板」', (tester) async {
    await enterWorkerState();
    await pumpShell(tester);

    for (var tab = 0; tab < 3; tab++) {
      if (tab > 0) {
        await tapWorkerNav(tester, tab);
      }
      expect(find.byType(AppIdentityBar), findsOneWidget, reason: '第 ${tab + 1} 屏必须有身份细带');
      final texts = visibleTexts(tester);
      expect(texts, contains('当前身份'));
      expect(texts, contains('打手 · 工号 W20260118'));
      expect(texts, contains('切回老板'));
      // 高度 28dp（A+ 清单 ID-A）
      final size = tester.getSize(find.byType(AppIdentityBar));
      expect(size.height, 28, reason: '细带高度必须是 28dp');
      // 位置：在页头**之下**（顶边 > 页面标题所在行的底边）
      final title = ['接单大厅', '消息', '我的'][tab];
      final barTop = tester.getTopLeft(find.byType(AppIdentityBar)).dy;
      // 「消息」既是页面标题也是底栏标签 → 必须限定在页头内找
      final titleBottom = tester
          .getBottomLeft(find.descendant(of: find.byType(IdentityWorkerPageHeader), matching: find.text(title)))
          .dy;
      expect(barTop, greaterThanOrEqualTo(titleBottom), reason: '细带必须在页头之下（不贴状态栏）');
      // 通栏且无圆角：宽度 == 屏宽
      expect(size.width, 390);
    }
  });

  // =====================================================================================
  // ⑤ 消息页单页三分区（无好友会话时**不出现**第三段）
  // =====================================================================================
  testWidgets('⑤ 无好友会话时消息页只有老板/官方客服两段，好友段完全不出现', (tester) async {
    await enterWorkerState();
    await pumpShell(tester);
    await tapWorkerNav(tester, 1);

    // 【2026-10-17 重钉】负责人定案「消息页去掉上方胶囊，改为单页三分区」：
    // 段名「客服」正名为「官方客服」，且两段**一页并列**（不再有分段控件可点）。
    // 旧断言是"点「客服」之后老板会话消失"；新断言改成"纵向顺序 + 各归其位"——
    // 原来靠切换隐藏的东西，现在必须靠分区标题与位置证明（不比原来松）。
    expect(IdentityWorkerMessagesPage.segments, ['老板', '官方客服']);
    expect(IdentityWorkerMessagesPage.friendSegment, '好友');

    expect(find.text('老板'), findsWidgets);
    expect(find.text('官方客服'), findsWidgets);
    // 好友段：没有好友会话 → **不显示**（不是显示空段）
    expect(find.text('好友'), findsNothing);
    expect(find.text('好友私聊'), findsNothing);
    expect(find.text('雪山'), findsNothing);

    // 老板段的会话照常渲染
    expect(find.text('麻药'), findsOneWidget);
    expect(find.text('老板消息1'), findsOneWidget);
    // 客服段的会话同页并列（旧口径要点开才出现）
    expect(find.text('祁连山客服'), findsWidgets);

    // 各归其位：老板标题 < 老板会话 < 官方客服标题 < 客服会话
    final double bossHeaderY = tester.getTopLeft(find.text('老板').first).dy;
    final double workerRowY = tester.getTopLeft(find.text('麻药')).dy;
    final double csHeaderY = tester.getTopLeft(find.text('官方客服').first).dy;
    final double csRowY = tester.getTopLeft(find.text('祁连山客服').first).dy;
    expect(workerRowY, greaterThan(bossHeaderY), reason: '老板会话必须落在「老板」分区内');
    expect(csHeaderY, greaterThan(workerRowY), reason: '「官方客服」段排在老板段之后');
    expect(csRowY, greaterThan(csHeaderY), reason: '客服会话必须落在「官方客服」分区内');
    await flushToasts(tester);
  });

  // =====================================================================================
  // 追加 1：好友段**条件显示**（老板 · 官方客服 · 好友；没有就不出现）
  // =====================================================================================
  testWidgets('追加1 有好友会话时显示第三段【好友】（老板 · 官方客服 · 好友，且好友在最后）', (tester) async {
    router.friendConvs = true;
    await enterWorkerState();
    await pumpShell(tester);
    await tapWorkerNav(tester, 1);

    // 【2026-10-17 重钉】单页三分区：三段**同页并列**，顺序固定 老板 → 官方客服 → 好友。
    // 旧断言是"点开好友段后老板/客服会话消失"（切换式不串段）；新口径下改为按纵向位置逐段归位，
    // 三段一条都不许少、也不许串（比原来更严：原来一次只看一段）。
    expect(find.text('好友'), findsOneWidget, reason: '有好友会话 → 必须显示第三段');

    // 第三段由 `/user/conversations` 判定（**不调 /user/friends**）
    expect(router.requests, contains('GET /user/conversations'), reason: '判定口径只按会话列表');
    expect(router.requests.any((r) => r.startsWith('GET /user/friends')), isFalse,
        reason: '不得自己调 /user/friends（放行与否不归本页管）');

    // 三段内容都在同一页
    expect(find.text('雪山'), findsOneWidget);
    expect(find.text('今晚打两把？'), findsOneWidget);
    expect(find.text('麻药'), findsOneWidget);
    expect(find.text('祁连山客服'), findsWidgets);
    // 未读徽标沿用同一套规则（好友会话 unread=5）
    expect(find.text('5'), findsWidgets);

    // 顺序：老板标题 < 老板行 < 官方客服标题 < 客服行 < 好友标题 < 好友行
    final double bossHeaderY = tester.getTopLeft(find.text('老板').first).dy;
    final double workerRowY = tester.getTopLeft(find.text('麻药')).dy;
    final double csHeaderY = tester.getTopLeft(find.text('官方客服').first).dy;
    final double csRowY = tester.getTopLeft(find.text('祁连山客服').first).dy;
    final double friendHeaderY = tester.getTopLeft(find.text('好友')).dy;
    final double friendRowY = tester.getTopLeft(find.text('雪山')).dy;
    expect(workerRowY, greaterThan(bossHeaderY));
    expect(csHeaderY, greaterThan(workerRowY), reason: '官方客服段在老板段之后');
    expect(csRowY, greaterThan(csHeaderY));
    expect(friendHeaderY, greaterThan(csRowY), reason: '好友段（边缘功能）排在最后');
    expect(friendRowY, greaterThan(friendHeaderY));
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑥ 切回老板态：导航恢复 5 项 + 打手态缓存/未读清空
  // =====================================================================================
  testWidgets('⑥ 切回老板态彻底：导航恢复 5 项、打手态缓存与未读被清空', (tester) async {
    await enterWorkerState();
    await pumpShell(tester);
    await tapWorkerNav(tester, 1);
    // 打手态消息页上报了未读（会话列表里有 2 条未读）
    expect(ApiCache.instance.sessionId, 'identity:worker');
    final workerKey = ApiCache.instance.keyOf('/worker/order-hall', null, apiBase: 'http://identity.local');
    ApiCache.instance.put(workerKey, const {'code': 0, 'data': {'list': []}});
    expect(ApiCache.instance.get(workerKey, ApiCache.ttlList), isNotNull, reason: '打手态缓存已就位');

    // 细带右侧「切回老板」= 直接切回（不是打开弹层）
    await tester.tap(find.text('切回老板').last);
    await settle(tester);

    expect(AuthStore.instance.workerIdentity, isFalse);
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '老板态 5 项导航回来');
    expect(find.byType(AppPlainBottomNav), findsNothing);
    expect(find.text('祁小山'), findsOneWidget, reason: '老板态凸起位的 AI 分支标签回来');
    // 打手态缓存被清空 + 身份维度回到老板
    expect(ApiCache.instance.get(workerKey, ApiCache.ttlList), isNull, reason: '打手态缓存必须被清空');
    expect(ApiCache.instance.sessionId, 'identity:boss');
    // Toast 是 2s Timer：测试结束前让它走完，否则 !timersPending 断言失败
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑦ 解绑需二次确认；解绑后回老板态且入口显示「未绑定」
  // =====================================================================================
  testWidgets('⑦a 已绑定（未达上限）：切换弹层是免密切换，不再要求输入打手账密', (tester) async {
    router.identityBound = true;
    router.maxPerBoss = 2; // 还能再绑 → 免密切换态（上限态见 ⑦c）
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: ApiClient())),
    ));
    await settle(tester);

    expect(find.text('切换为打手'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: '已绑定不需要再输密码');
    expect(find.text('解除绑定'), findsOneWidget);
    await flushToasts(tester);
  });

  testWidgets('⑦c 已绑定且达上限：上限说明条 + 「绑定新的」置灰 + 点向唯一可行动作（SW-C）', (tester) async {
    router.identityBound = true;
    router.maxPerBoss = 1; // activeCount=1 == maxPerBoss → 已达上限
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: ApiClient())),
    ));
    await settle(tester);

    // 2026-10-06 定案：上限提示**只在"想新增绑定"时出现**，且必须写明"不影响身份切换"，
    // 所以文案从「已达绑定上限：本机只能绑定 N 个打手账号」改成「本机最多绑定 N 个…」
    expect(find.textContaining('本机最多绑定 1 个打手账号'), findsOneWidget);
    expect(find.textContaining('不影响上面的身份切换'), findsOneWidget);
    expect(find.text('绑定新的打手账号'), findsOneWidget, reason: '上限已满 → 主按钮置灰');
    expect(find.text('解除绑定'), findsOneWidget, reason: '把用户推向唯一可行动作');
    await flushToasts(tester);
  });

  testWidgets('⑦b 解绑需二次确认；解绑后回到老板态且入口显示「未绑定」', (tester) async {
    router.identityBound = true;
    router.maxPerBoss = 2;
    // 本机手上有伴随令牌（"已绑定"的真实形态）
    AuthStore.instance.debugSetIdentity(companionToken: 'companion-token');
    await pumpShell(tester);
    // 已绑定：老板态「我的」页身份分组里就有「解除绑定」入口（与切换弹层同一个二次确认）
    unawaited(AuthStore.instance.fetchIdentityStatus(api: ApiClient()));
    await settle(tester);
    await gotoBossMine(tester);
    expect(find.textContaining('已绑定'), findsWidgets);

    await tester.ensureVisible(find.text('解除绑定'));
    await settle(tester);
    await tester.tap(find.text('解除绑定'));
    await settle(tester);

    // 二次确认弹层：必须写明影响面（不影响工作端 App 的登录）
    expect(find.byType(IdentityUnbindSheet), findsOneWidget);
    expect(find.text('不影响两件事'), findsOneWidget);
    expect(router.requests.any((r) => r.startsWith('POST /user/identity/unbind')), isFalse,
        reason: '未点确认前不得真的解绑');

    // 先取消：什么事都不该发生
    await tester.tap(find.descendant(of: find.byType(IdentityUnbindSheet), matching: find.text('取消')));
    await settle(tester);
    expect(router.requests.any((r) => r.startsWith('POST /user/identity/unbind')), isFalse);
    expect(AuthStore.instance.companionToken, isNotNull, reason: '取消后绑定关系与令牌都不该动');

    // 真正确认解绑（弹层里「解除绑定」既是标题也是按钮 → 取按钮那个）
    await tester.tap(find.text('解除绑定'));
    await settle(tester);
    await tester.tap(find.descendant(
      of: find.byType(IdentityUnbindSheet),
      matching: find.byType(AppIdentityPrimaryButton),
    ));
    await settle(tester);

    expect(router.requests.any((r) => r.startsWith('POST /user/identity/unbind')), isTrue);
    expect(AuthStore.instance.companionToken, isNull);
    expect(AuthStore.instance.workerIdentity, isFalse);
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '解绑后回到老板态');

    // 入口文案回到「未绑定」（把解除绑定那一行也从页面上撤掉）
    unawaited(AuthStore.instance.fetchIdentityStatus(api: ApiClient()));
    await settle(tester);
    expect(find.textContaining('未绑定打手端账号'), findsOneWidget);
    expect(find.text('解除绑定'), findsNothing, reason: '未绑定 → 不该再有解绑入口');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑧ 错误态中文文案来自服务端
  // =====================================================================================
  testWidgets('⑧ 错误态文案来自服务端：换掉假接口文案 → 页面跟着换', (tester) async {
    Future<void> pumpSheet() async {
      await tester.pumpWidget(MaterialApp(
        // 每次都要**全新 State**（同类型同 key 会复用 State → _failure 残留，第二次点不到主按钮）
        home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: ApiClient())),
      ));
      await settle(tester);
    }

    Future<void> attempt(String serverMessage, int code, {String errorCode = ''}) async {
      router.bindError = (code: code, message: serverMessage, errorCode: errorCode);
      await tester.enterText(sheetField(0), 'somebody');
      await tester.enterText(sheetField(1), 'pw');
      await tester.tap(find.textContaining('绑定并切换为打手').last);
      await settle(tester);
      expect(find.textContaining(serverMessage), findsWidgets, reason: '页面必须原样显示服务端文案');
    }

    // ① 账密错误（400）→ 行内错误行 + 主按钮「重新绑定」
    await pumpSheet();
    await attempt('账号或密码错误-甲', 400);
    expect(find.text('重新绑定'), findsOneWidget);

    // ② 角色不符（403）→ 橙色告知条 + 主按钮置灰改文案 + 副按钮「联系客服」
    await pumpSheet();
    await attempt('这个账号是老板账号，不是打手账号-乙', 403);
    expect(find.text('账号角色不符'), findsOneWidget);
    expect(find.text('联系客服'), findsOneWidget);

    // ③ 已停用（403 ACCOUNT_BANNED）→ 主按钮「账号已停用」+ 副按钮「联系客服处理」
    // （2026-10-06 文案清理：原「联系管理员」是内部称呼，改成用户视角；与 ② 的「联系客服」区分开）
    await pumpSheet();
    await attempt('该打手账号已被停用-丙', 403, errorCode: 'ACCOUNT_BANNED');
    expect(find.text('账号已停用'), findsOneWidget);
    expect(find.text('联系客服处理'), findsOneWidget);

    // ④ 已被其他老板绑定 / 超上限（400）→ 主按钮「无法绑定」+ 副按钮「先不绑定」
    await pumpSheet();
    await attempt('该打手账号已被其他老板绑定-丁', 400);
    expect(find.text('无法绑定'), findsOneWidget);
    expect(find.text('先不绑定'), findsOneWidget);

    // ⑤ 限流（429）→ 主按钮「稍后再试」
    await pumpSheet();
    await attempt('绑定尝试过于频繁，请稍后再试-戊', 429, errorCode: 'RATE_LIMITED');
    expect(find.text('稍后再试'), findsOneWidget);

    // ⑥ 把文案再换一次 → 页面必须跟着换（证明不是写死在客户端）
    await pumpSheet();
    await attempt('服务端第二版文案-己', 403);
    expect(find.textContaining('服务端第二版文案-己'), findsWidgets);
    expect(find.textContaining('账号角色不符-乙'), findsNothing);
  });

  // =====================================================================================
  // 附：绑定成功但零分部权限 → 提示但仍可进入大厅看空态（用户任务书要求）
  // =====================================================================================
  testWidgets('附：零分部权限时提示「没有任何分部的接单权限」且仍可进入大厅', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: IdentitySwitchSheet(api: ApiClient()))));
    await settle(tester);
    router.bindNoPermission = true;
    await tester.enterText(sheetField(0), 'newbie');
    await tester.enterText(sheetField(1), 'pw');
    await tester.tap(find.textContaining('绑定并切换为打手').last);
    await settle(tester);

    expect(find.textContaining('没有任何分部的接单权限'), findsWidgets);
    expect(find.text('仍然进入接单大厅'), findsOneWidget, reason: '任务书：提示但仍可进入大厅看空态');
    expect(find.text('留在老板态'), findsOneWidget);
    expect(AuthStore.instance.workerIdentity, isFalse, reason: '未点进入前不得切身份');
  });

  // =====================================================================================
  // 附：区块顺序钉住 —— 「身份切换」在资产卡/余额**之后**（负责人 2026-10-13），
  // 且**在服务卡之后**（负责人 2026-10-17 ⑥：服务放到我的订单下面，身份退到最后）
  // =====================================================================================
  testWidgets('附：老板态「我的」页 = 余额 → 服务卡 → 身份区块（身份在服务之后）', (tester) async {
    router.identityBound = true;
    router.maxPerBoss = 2;
    await pumpShell(tester);
    unawaited(AuthStore.instance.fetchIdentityStatus(api: ApiClient()));
    await settle(tester);
    await gotoBossMine(tester);

    // 用**树序**断言（y 坐标会受视口高度影响）
    final order = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').toList();
    final balance = order.indexOf('余额');
    final identity = order.indexOf('切换身份');
    final service = order.indexOf('系统通知');
    expect(balance, greaterThanOrEqualTo(0), reason: '资产卡必须在树里（余额）\n全屏文本：$order');
    expect(identity, greaterThan(balance),
        reason: '身份区块必须在资产卡（余额）之后（负责人 2026-10-13 调整）\n全屏文本：$order');
    // 负责人 2026-10-17 ⑥：服务要放到我的订单下面，身份退到服务后面
    expect(service, lessThan(identity),
        reason: '**服务卡必须在身份区块之前** —— 负责人 2026-10-17 ⑥\n全屏文本：$order');
  });
}

// =========================================================================================
// 假服务器（可变路由；记录请求顺序与 Authorization）
// =========================================================================================

typedef _Err = ({int code, String message, String errorCode});

class _Router implements HttpClientAdapter {
  final List<String> requests = [];
  final Map<String, String?> _auth = {};
  final Map<String, ({int status, String body})> routes = {};

  /// `GET /user/identity` 的绑定状态
  bool identityBound = false;

  /// `POST /user/identity/bind` 的失败注入（null = 成功）
  _Err? bindError;

  /// 绑定成功但零分部权限（noperm 路径）
  bool bindNoPermission = false;

  /// 该打手账号是否有好友会话（决定消息页是否显示第三段【好友】）
  bool friendConvs = false;

  /// 绑定上限（1 = 已达上限 → SW-C 上限态；2 = 还能再绑 → 免密切换态）
  int maxPerBoss = 1;

  void resetErrors() {
    bindError = null;
    bindNoPermission = false;
    friendConvs = false;
    maxPerBoss = 1;
    identityBound = false;
  }

  String? lastBearer(String key) => _auth[key];

  void on(String methodPath, Object? data, {int status = 200}) {
    routes[methodPath] = (status: status, body: jsonEncode({'code': status == 200 ? 0 : status, 'message': status == 200 ? 'ok' : 'err', 'data': data}));
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.path}';
    requests.add(key);
    final auth = options.headers['Authorization'];
    _auth[key] = auth is String && auth.startsWith('Bearer ') ? auth.substring(7) : null;

    // 动态路由
    if (key == 'GET /user/identity') {
      return _data(identityBound ? _boundBody : {'bound': false, 'activeCount': 0, 'maxPerBoss': 1, 'bindings': []});
    }
    if (key == 'POST /user/identity/bind') {
      final e = bindError;
      if (e != null) {
        return _json({'code': e.code, 'message': e.message, 'errorCode': e.errorCode, 'data': null}, status: e.code);
      }
      return _data({
        'bindingId': '77',
        'rebound': false,
        'bossTokenUnchanged': true,
        'companionToken': 'companion-token',
        'companionRefreshToken': 'companion-refresh',
        'maxPerBoss': 1,
        'worker': {
          'workerNo': 'W20260118',
          'nickname': '王野',
          'workerStatus': 1,
          'canTakeOrder': !bindNoPermission,
          'divisionPermissions': bindNoPermission
              ? const []
              : [
                  {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
                ],
        },
      });
    }
    if (key == 'POST /user/identity/unbind') {
      identityBound = false;
      return _data({'ok': true, 'bindingId': '77', 'workerNo': 'W20260118', 'message': '已解绑，打手态登录已失效'});
    }
    if (key == 'GET /worker/division-permissions') {
      return _data({
        'list': [
          {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
        ]
      });
    }
    if (key == 'GET /worker/cs/conversations') return _data({'list': _convs, 'unread': 2});
    if (key == 'GET /user/conversations') {
      // 好友段的存在依据：**只看会话列表里有没有 type=friend**（负责人追加裁决）
      return _data({'list': friendConvs ? _friendConvs : const []});
    }
    if (key == 'GET /worker/my-wallet') {
      return _data({
        'balance': 268.4,
        'totalIncome': 1847.2,
        'settlementCount': 23,
        'tipIncome': 96.4,
        'totalGranted': 0,
      });
    }
    if (key == 'GET /worker/wallet/transactions') return _data({'list': [], 'total': 0});
    if (key == 'GET /worker/orders') return _data({'list': [], 'total': 0});
    if (key == 'GET /worker/order-hall') {
      return _data({
        'total': 1,
        'page': 1,
        'pageSize': 50,
        'list': [
          {
            'id': '9',
            'orderNo': 'ORD2026100600018241',
            'totalAmount': 488,
            'status': 'pending_take',
            'statusName': '待接单',
            'quantity': 1,
            'createdAt': DateTime.now().subtract(const Duration(minutes: 3)).toIso8601String(),
            'productName': '保2红单48.8',
            'divisionId': '1',
          }
        ],
      });
    }
    final r = routes[key];
    if (r == null) {
      return _json({'code': 404, 'message': 'Not Found', 'data': null}, status: 404);
    }
    return ResponseBody.fromString(r.body, r.status, headers: _headers);
  }

  Map<String, dynamic> get _boundBody => {
        'bound': true,
        'activeCount': 1,
        'maxPerBoss': maxPerBoss,
        'bindings': [
          {
            'bindingId': '77',
            'status': 'active',
            'worker': {
              'workerNo': 'W20260118',
              'nickname': '王野',
              'workerStatus': 1,
              'canTakeOrder': true,
              'divisionPermissions': [
                {'divisionId': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': true},
              ],
            },
          }
        ],
      };

  /// 会话列表：老板直聊 + 客服（**好友另外走 `/user/conversations`**，见 [_friendConvs]）
  static final List<Map<String, dynamic>> _convs = [
    {
      'id': '75',
      'type': 'worker',
      'unread': 2,
      'lastSeq': 3,
      'status': 'open',
      'updatedAt': '2026-10-06T12:40:00Z',
      'peer': {'id': '31', 'nickname': '麻药'},
      'lastMessage': {'content': '老板消息1', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-06T12:34:00Z'},
    },
    {
      'id': '74',
      'type': 'cs',
      'unread': 0,
      'lastSeq': 23,
      'status': 'open',
      'updatedAt': '2026-10-06T12:30:00Z',
      'lastMessage': {'content': '结算问题找客服', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-06T12:30:00Z'},
    },
  ];

  /// 好友会话（只在 [friendConvs]=true 时由 `/user/conversations` 返回 → 决定第三段是否出现）
  static final List<Map<String, dynamic>> _friendConvs = [
    {
      'id': '76',
      'type': 'friend',
      'unread': 5,
      'lastSeq': 9,
      'status': 'open',
      'updatedAt': '2026-10-06T12:41:00Z',
      'peer': {'id': '9', 'nickname': '雪山'},
      'lastMessage': {'content': '今晚打两把？', 'msgType': 'text', 'recalled': false, 'createdAt': '2026-10-06T12:41:00Z'},
    },
  ];

  @override
  void close({bool force = false}) {}
}

final Map<String, List<String>> _headers = {
  Headers.contentTypeHeader: [Headers.jsonContentType],
};

/// 成功响应（统一响应体：`{code,message,data}` —— 客户端读的是 `resp['data']`）
ResponseBody _data(Object? data, {int status = 200}) =>
    _json({'code': 0, 'message': 'ok', 'data': data}, status: status);

ResponseBody _json(Object? body, {int status = 200}) => ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: _headers,
    );

/// 公共路由：HomeShell 会同时挂载老板端五个分支，这里把它们的读接口都喂上
void _installBaseRoutes(_Router r) {
  r.on('GET /user/wallet', {'balance': 1286, 'totalSpent': 0});
  r.on('GET /user/orders', {'list': [], 'total': 0});
  r.on('GET /user/conversations', {'list': [], 'total': 0});
  r.on('GET /user/friends', {'list': []});
  r.on('GET /user/friends/requests/incoming', {'list': []});
  r.on('GET /user/notifications', {'list': [], 'unread': 0});
  r.on('GET /user/conversation', {'id': '74'});
  r.on('GET /public/levels', const <Object>[]);
  r.on('GET /public/announcements', {
    'list': [
      {'id': '1', 'title': '欢迎来到 祁连山电竞', 'content': '祁连山电竞俱乐部正式上线，快来体验专业陪玩服务。', 'createdAt': '2026-10-04T16:15:00Z'},
    ]
  });
  r.on('GET /public/clubs', {'list': []});
  r.on('GET /public/order-form', {'list': []});
  r.on('GET /public/games', {'list': []});
  r.on('GET /public/categories', {'list': []});
  r.on('GET /public/products', {'list': [], 'total': 0});
  r.on('GET /public/players', {'list': [], 'total': 0});
  r.on('GET /public/leaderboard', {'list': [], 'total': 0});
  r.on('GET /public/banners', {'list': []});
  r.on('GET /divisions', [
    {'id': '1', 'name': '和平精英', 'shortName': '和平精英', 'platformLabel': '手游', 'onlineCount': 3},
  ]);
  r.on('GET /divisions/grouped', {'list': []});
  r.on('POST /user/ai/reset', {'ok': true});
  r.on('GET /auth/me', {
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
  });
}
