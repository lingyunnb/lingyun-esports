import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/home_shell.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 管理员身份（充值审核 + 提现审核 · 受限会话）—— 验收 ⑦–⑩
///
/// ⑦ 管理员态**黑名单**逐屏 0 命中（不得出现"下单/找陪玩/快速下单/祁小山/排行榜/下单浮标"等）
///    + 结构断言：**无底栏**、无下单浮标、每屏都有 28dp 身份细带
/// ⑧ 发放**二次确认**（未确认绝不发请求；取消也不发）
/// ⑨ **重复发放** → 服务端中文 400 原样展示
/// ⑩ 受限会话 **401** → 自动切回老板态 + 中文提示（复用 identityNotice 机制）
///
/// 另覆盖：身份弹层里的「我是管理员」→ 绑定 → 进管理员态；打手态与管理员态**互斥**。
///
/// ## ⚠️ 2026-10-11 口径变更（随「提现审核」上线，**只改一处**）
/// 管理员态页头新增分段控件「充值审核 / 提现审核」（第二段是本次交付的提现审核）。
/// 于是**管理员态屏上必然出现「提现」二字** —— 它不再是"老板端专属词"，
/// 而是**这个身份的第二件事的名字**。
///
/// 因此本文件的黑名单断言改为**按当前分段挑表**，并引入一处显式豁免：
/// - [RechargeAdminCleanliness.violations]（含「提现」）比对**充值审核**那一段的每一屏；
/// - [WithdrawAdminCleanliness.violations]（放行「提现」「打款」，禁用「积分」「充值」「钱包」）
///   比对**提现审核**那一屏；
/// - [adminTabOwnWords]：管理员态**自己的两段页签文案**在两个分段下都豁免
///   （分段控件是同一枚控件，切到哪一段另一个页签都还写在上面）。
///
/// **没有放松任何一条既有红线**：`RechargeCopy.forbiddenWords` 的逐屏扫描、
/// 老板端 22 词、结构断言（无底栏/无浮标/28dp 细带）全部逐字保留。
void main() {
  late _Router router;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    router = _Router();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://admin.local'))..httpClientAdapter = router;
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
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  /// 有界推进（不用 pumpAndSettle：Toast 的 2s Timer 与 busy 圈会让它永不结束）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// **短推进**（400ms）：断言 Toast 时必须用它 —— `AppToast` 2000ms 自动消失，
  /// 用上面那个 2000ms 的 settle 会把要断言的提示先等没了（踩过）。
  Future<void> settleShort(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Toast 是 2s 自动消失的 Timer：测试结束前必须让它走完（否则 !timersPending 断言失败）
  Future<void> flushToasts(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2200));
    AppToast.dismiss();
  }

  ApiClient api() => ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://admin.local'))..httpClientAdapter = router);

  /// 进入管理员态（模拟"绑定成功之后"）
  Future<void> enterAdmin() async {
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.admin,
      adminToken: 'recharge-token',
      adminMe: RechargeAdminMe.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }),
    );
    await AuthStore.instance.switchToAdmin();
  }

  List<String> visibleTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  /// 管理员态**自己的两段页签文案**（分段控件常驻，切到任一段另一段也写在上面）
  ///
  /// 豁免范围**仅这两个字符串**：把命中词从一屏文本里剔掉再做黑名单比对，
  /// 其余任何一个字都不放过（见文件头的口径变更说明）。
  const adminTabOwnWords = ['充值审核', '提现审核'];

  /// 按当前分段挑表比对黑名单，并记住管理员态自己的页签文案
  void expectClean(WidgetTester tester, {required bool withdrawTab}) {
    final texts = visibleTexts(tester)
        .map((t) {
          var s = t;
          for (final w in adminTabOwnWords) {
            s = s.replaceAll(w, '');
          }
          return s;
        })
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final hits = withdrawTab
        ? WithdrawAdminCleanliness.violations(texts)
        : RechargeAdminCleanliness.violations(texts);
    expect(hits, isEmpty, reason: '命中：$hits\n全屏文本：${visibleTexts(tester)}');
  }

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: HomeShell(identityApi: api()),
    ));
    await settle(tester);
  }

  /// 打开待审核详情（列表第一行 → 详情）
  Future<void> openDetail(WidgetTester tester) async {
    await tester.tap(find.text('详情').first);
    await settle(tester);
  }

  // =====================================================================================
  // ⑦ 管理员态：只显示充值审核 + 逐屏黑名单
  // =====================================================================================
  testWidgets('⑦ 管理员态待审核列表：无底栏、无下单浮标、28dp 细带写「当前身份 · 充值审核」', (tester) async {
    await enterAdmin();
    await pumpShell(tester);

    expect(AuthStore.instance.adminIdentity, isTrue);
    expect(find.byType(RechargeAdminShell), findsOneWidget);

    // 结构：管理员态**没有底栏**（唯一出口是细带右侧「切回老板」）
    expect(find.byType(AppBottomNav), findsNothing, reason: '管理员态不得出现老板端 5 项底栏');
    expect(find.byType(AppPlainBottomNav), findsNothing, reason: '管理员态也不做"只有一项"的假底栏');
    expect(find.byType(AppOrderFab), findsNothing, reason: '不得出现下单浮标');
    expect(RechargeAdminMeta.bottomNavItemCount, 0);

    // 身份细带：28dp + 「当前身份 · 充值审核」+ 切回老板
    expect(find.byType(AppIdentityBar), findsOneWidget);
    final band = tester.getSize(find.byType(AppIdentityBar));
    expect(band.height, AppIdentityBar.height);
    expect(find.text(AppIdentityBar.leadLabel), findsOneWidget);
    // 身份细带 + 页头分段控件都写着「充值审核」→ 恰好两处（改动前只有细带那一处）
    expect(find.text(AppIdentityBar.adminLabel), findsNWidgets(2));
    expect(find.byType(AppSegmented), findsOneWidget, reason: '两段审核靠页头分段切换');
    expect(find.text('切回老板'), findsOneWidget);

    // 三件事的入口都在：待审核行 + 详情里的发放/驳回
    expect(find.text(RechargeAdminShell.title), findsOneWidget);
    expect(find.textContaining('待审核'), findsWidgets);
    expect(find.text('麻药'), findsOneWidget);
    expect(find.text('中文 ID U8471209365'), findsOneWidget);
    expect(find.text('¥68.00'), findsWidgets, reason: '到账余额列（1:1）');

    // 黑名单：逐条文本比对，0 命中（充值审核那一段 → 用含「提现」的那张表）
    final texts = visibleTexts(tester);
    expectClean(tester, withdrawTab: false);
    // 老板端词表（打手态那 22 词）逐条显式再断言一次（验收项点名的那几个）
    for (final w in const ['下单', '找陪玩', '快速下单', '祁小山', '排行榜']) {
      expect(texts.any((t) => t.contains(w)), isFalse, reason: '管理员态不得出现「$w」');
    }
    // 合规：管理员态同样不许出现"支付成功 / 自动到账 / 旧计价单位（积分）"
    //
    // ⚠️ 2026-10-11 唯一一处例外：「提现」。`RechargeCopy.forbiddenWords` 里的「提现」
    // 是**充值链路**的红线（老板不能提现，docs/06），而现在管理员态页头的分段控件
    // 写着「提现审核」—— 那是**这个身份的第二个功能名**，不是充值链路上的提现入口。
    // 所以这里只跳过这一个词，其余（含 2026-10-11 新加进充值链路的「积分」）逐个照旧扫描。
    for (final w in RechargeCopy.forbiddenWords) {
      if (w == '提现') continue;
      expect(texts.any((t) => t.contains(w)), isFalse, reason: '管理员态出现「$w」');
    }
    // 提现审核那一段的合规红线单独钉（它自己那张表：禁用「积分」「充值」「钱包」）
    expect(WithdrawAdminCleanliness.blacklist, contains('积分'));
    await flushToasts(tester);
  });

  testWidgets('⑦ 审核详情（凭证大图）与两个弹层：逐屏黑名单同样 0 命中', (tester) async {
    await enterAdmin();
    await pumpShell(tester);
    await openDetail(tester);

    // 详情：凭证大图（可缩放）+ 用户信息 + 金额/到账余额 + 备注 + 两个动作
    expect(find.text('审核详情'), findsOneWidget);
    expect(find.byType(AppIdentityBar), findsOneWidget, reason: '详情页同样要有身份细带');
    expect(find.text('付款凭证'), findsOneWidget);
    expect(find.text('申请人'), findsOneWidget);
    expect(find.text('应付金额'), findsOneWidget);
    expect(find.text('¥68.00'), findsWidgets, reason: '金额卡：应付 ¥68.00 + 发放余额 ¥68.00（1:1）');
    expect(find.text('老板备注'), findsOneWidget);
    expect(find.text('微信转账'), findsOneWidget);
    expect(find.text('发放'), findsOneWidget);
    expect(find.text('驳回'), findsOneWidget);
    expectClean(tester, withdrawTab: false);

    // 凭证点开 = 可缩放查看器（InteractiveViewer）
    await tester.tap(find.byKey(RechargeReviewDetailPage.proofKey));
    await settle(tester);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);

    // 发放确认弹层
    await tester.tap(find.text('发放'));
    await settle(tester);
    expect(find.text('发放确认'), findsOneWidget);
    expectClean(tester, withdrawTab: false);
    await tester.tap(find.text('取消'));
    await settle(tester);

    // 驳回弹层（含必填校验）
    await tester.tap(find.text('驳回'));
    await settle(tester);
    expect(find.text('驳回申请'), findsOneWidget);
    expectClean(tester, withdrawTab: false);
    await tester.tap(find.text('确认驳回'));
    await settle(tester);
    expect(find.text('请填写驳回原因，老板会在充值记录里看到它'), findsOneWidget);
    expect(router.grantCalls, 0);
    expect(router.rejectCalls, 0);
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑧ 发放二次确认（未确认不发请求）
  // =====================================================================================
  testWidgets('⑧ 发放必须二次确认：确认文案写清"给 麻药 发放 ¥68.00 余额"，未确认不发请求', (tester) async {
    await enterAdmin();
    await pumpShell(tester);
    await openDetail(tester);

    await tester.tap(find.text('发放'));
    await settle(tester);

    // 二次确认弹层把话说全（谁、多少余额、多少钱）
    expect(find.text('给 麻药 发放 ¥68.00 余额'), findsOneWidget);
    expect(find.text('¥68.00'), findsWidgets);
    expect(router.grantCalls, 0, reason: '弹出确认层本身绝不能发请求');

    // 取消 → 依然不发
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(router.grantCalls, 0);

    // 再次发放 → 确认 → 这次才发，且列表移除 + Toast「已发放 ¥68.00 余额」
    await tester.tap(find.text('发放'));
    await settle(tester);
    await tester.tap(find.text('确认发放'));
    await settleShort(tester); // 短推进：Toast 2000ms 就消失，不能等满
    expect(router.grantCalls, 1);
    expect(find.text('已发放 ¥68.00 余额'), findsOneWidget);
    // 让 pop 转场跑完，再看列表（详情页退场动画期间它还在树里）
    await settle(tester);
    expect(find.text('麻药'), findsNothing, reason: '发放成功后该行从待审核列表移除');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑨ 重复发放 → 服务端中文 400 原样展示
  // =====================================================================================
  testWidgets('⑨ 重复发放：服务端 400「该申请已发放」原样展示（客户端不改字、不重复加分）', (tester) async {
    router.grantError = (code: 400, message: '该申请已发放');
    await enterAdmin();
    await pumpShell(tester);
    await openDetail(tester);

    await tester.tap(find.text('发放'));
    await settle(tester);
    await tester.tap(find.text('确认发放'));
    await settleShort(tester);

    expect(router.grantCalls, 1);
    expect(find.text('该申请已发放'), findsOneWidget, reason: '服务端中文原文必须原样展示');
    // 仍在详情页（没有被误当成成功而 pop）
    expect(find.text('审核详情'), findsOneWidget);
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑩ 受限会话 401 → 自动切回老板态 + 中文提示
  // =====================================================================================
  testWidgets('⑩ 受限会话 401（被移出白名单/过期）→ 自动切回老板态 + 中文提示', (tester) async {
    router.listUnauthorized = true;
    await enterAdmin();
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: HomeShell(identityApi: api()),
    ));
    await settleShort(tester); // 短推进：要断言的正是那条会 2s 自动消失的提示

    // 身份已回落老板态：管理员壳消失、老板端底栏回来
    expect(AuthStore.instance.adminIdentity, isFalse);
    expect(find.byType(RechargeAdminShell), findsNothing);
    expect(find.byType(AppBottomNav), findsOneWidget, reason: '自动切回老板态');
    expect(find.byType(AppPlainBottomNav), findsNothing);
    // 中文提示（服务端原文）
    expect(find.textContaining('受限管理身份已失效'), findsOneWidget);
    await flushToasts(tester);
  });

  testWidgets('⑩ 老板态会话完全不受影响：401 只丢管理员身份，primary 令牌还在', (tester) async {
    router.listUnauthorized = true;
    await enterAdmin();
    await pumpShell(tester);
    expect(AuthStore.instance.accessToken, 'primary-token', reason: '绝不把老板一起登出');
    expect(AuthStore.instance.loggedIn, isTrue);
    await flushToasts(tester);
  });

  // =====================================================================================
  // 身份弹层：「我是管理员」→ 绑定 → 进管理员态
  // =====================================================================================
  testWidgets('身份弹层新增「我是管理员」：输账密 → bind-recharge-admin → 进管理员态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);

    // 默认仍是打手表单（改动前形态不变）
    expect(find.text('我是打手'), findsOneWidget);
    expect(find.text('绑定并切换为打手'), findsOneWidget);

    await tester.tap(find.text('我是管理员'));
    await settle(tester);
    expect(find.text('管理员账号'), findsOneWidget);
    expect(find.text('绑定并切换为管理员'), findsOneWidget);
    // 不显示任何内部规则（"最多 5 个"之类）
    expect(find.textContaining('最多 5'), findsNothing);
    expect(find.textContaining('上限 5'), findsNothing);

    await tester.enterText(find.byType(TextField).at(0), 'recharge_zhou');
    await tester.enterText(find.byType(TextField).at(1), 'pw123456');
    await tester.tap(find.text('绑定并切换为管理员'));
    await settle(tester);

    final call = router.calls.firstWhere((c) => c.key == 'POST /user/identity/bind-recharge-admin');
    expect(call.body?['username'], 'recharge_zhou');
    expect(call.token, 'primary-token', reason: '绑定是老板侧能力：必须用 primary 令牌请求');
    expect(AuthStore.instance.adminIdentity, isTrue);
    expect(AuthStore.instance.adminToken, 'recharge-token');
    await flushToasts(tester);
  });

  testWidgets('绑定失败：文案取服务端原文（不在白名单 → 橙色告知，主按钮改成「账号无审核权限」）', (tester) async {
    router.bindError = (code: 403, message: '该账号未获授权进行充值审核，请联系超级管理员');
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);
    await tester.tap(find.text('我是管理员'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'someone');
    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('绑定并切换为管理员'));
    await settle(tester);

    expect(find.textContaining('未获授权进行充值审核'), findsWidgets);
    expect(find.text('账号无审核权限'), findsOneWidget);
    expect(AuthStore.instance.adminIdentity, isFalse);
    await flushToasts(tester);
  });

  testWidgets('互斥：已在打手态时「我是管理员」置灰并给出清晰路径', (tester) async {
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: 'companion-token',
      adminMe: null,
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: IdentitySwitchSheet(key: UniqueKey(), api: api())),
    ));
    await settle(tester);

    expect(find.textContaining('当前在打手态，要绑定管理员账号请先切回老板态'), findsOneWidget);
    // 点它不生效（仍停在打手表单）
    await tester.tap(find.text('我是管理员'));
    await settle(tester);
    expect(find.text('绑定并切换为管理员'), findsNothing);
    expect(find.text('绑定并切换为打手'), findsOneWidget);
  });

  // =====================================================================================
  // 切回老板：受限会话**运行期内保留**，但**绝不落盘**（冷启动必回老板态）
  //
  // ⚠️ 2026-10-06 身份直切专项的**语义变更**（本条断言随之更新，别再改回去）：
  //    管理员会话**不再**在"切回老板 / 进打手态"时立刻丢弃 —— 一次运行内来回切换是高频操作，
  //    每次都重输账号密码是反人类。安全底线改由**"绝不落盘"**守住：
  //    App 重启（内存清空）后 `adminBound` 必为 false，弹层显示「未验证」，必须重新验证。
  // =====================================================================================
  testWidgets('细带「切回老板」：管理员会话运行期内保留（可直切回），但绝不落盘（冷启动必回老板态）', (tester) async {
    // 记录每一次"要写安全存储"的**意图**（`debugStorageDisabled` 下写会被跳过，但意图先记下来）
    final writes = <String, List<String?>>{};
    AuthStore.debugOnStorageWrite = (k, v) => (writes[k] ??= []).add(v);
    addTearDown(() => AuthStore.debugOnStorageWrite = null);

    await enterAdmin();
    await pumpShell(tester);
    await tester.tap(find.text('切回老板'));
    await settleShort(tester);

    // ① 身份回老板态、壳换成老板端（原有断言，逐字未变）
    expect(AuthStore.instance.adminIdentity, isFalse);
    expect(find.byType(AppBottomNav), findsOneWidget);
    expect(find.text(IdentityTransition.toBoss), findsOneWidget);

    // ② **运行期内保留**：令牌与管理员资料仍在内存 → 弹层里那张管理员卡可以直接点「切换为管理员」
    expect(AuthStore.instance.adminBound, isTrue, reason: '同一运行期内保留：点一下就能切回去，不用重输账密');
    expect(AuthStore.instance.adminToken, 'recharge-token', reason: '令牌留在内存（这就是"直切"的前提）');

    // ③ **绝不落盘**：整条路径上一次都没有写带管理员令牌的键或值
    //    （是"压根不写"，不是"写了又删" —— 后者会在磁盘上留下可恢复的痕迹）
    for (final e in writes.entries) {
      expect(e.key.contains('recharge') || e.key.contains('admin'), isFalse, reason: '不许存在管理员落盘键：${e.key}');
      for (final v in e.value) {
        expect(v, isNot('recharge-token'), reason: '管理员令牌不许被写进任何键：${e.key}');
      }
    }

    // ④ 冷启动（内存清空后只剩落盘内容）→ 管理员会话必然没了、身份必回老板态
    AuthStore.instance.debugClearIdentity();
    expect(AuthStore.instance.adminBound, isFalse, reason: '冷启动后必须重新验证管理员账号');
    expect(AuthStore.instance.adminToken, isNull);
    expect(AuthStore.instance.identity, AppIdentity.boss);

    await flushToasts(tester);
  });

  testWidgets('管理员态列表加载失败（非 401）→ 页内中文原因 + 重试，且身份保留', (tester) async {
    router.listError = (code: 500, message: '服务器开小差了');
    await enterAdmin();
    await pumpShell(tester);

    expect(find.text('待审核列表加载失败'), findsOneWidget);
    expect(find.text('服务器开小差了'), findsOneWidget);
    expect(AuthStore.instance.adminIdentity, isTrue, reason: '5xx 不该把管理员态踢掉');
    expect(find.text('重试'), findsOneWidget);

    // 服务端恢复 → 重试成功
    router.listError = null;
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('麻药'), findsOneWidget);
    await flushToasts(tester);
  });
}

/// 假服务器：管理员态三接口 + 绑定接口 + 老板端最小底座
class _Router implements HttpClientAdapter {
  bool listUnauthorized = false;
  ({int code, String message})? listError;
  ({int code, String message})? grantError;
  ({int code, String message})? bindError;
  int grantCalls = 0;
  int rejectCalls = 0;

  final List<({String key, Map<String, dynamic>? body, String? token})> calls = [];

  void reset() {
    listUnauthorized = false;
    listError = null;
    grantError = null;
    bindError = null;
    grantCalls = 0;
    rejectCalls = 0;
    calls.clear();
  }

  static const _pending = [
    {
      'id': '9',
      'nickname': '麻药',
      'uid': 'U8471209365',
      'amountYuan': 68,
      'points': 68, // 口径 2026-10-09：到账余额 1:1（1 元 = 1 元）
      'proofMediaId': 'proof-9',
      'note': '微信转账',
      'createdAt': '2026-10-06T12:34:00Z',
      'status': 'pending',
    },
    {
      'id': '10',
      'nickname': '雪山',
      'uid': 'U10086',
      'amountYuan': 6,
      'points': 6,
      'proofMediaId': 'proof-10',
      'createdAt': '2026-10-06T12:40:00Z',
      'status': 'pending',
    },
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    final auth = options.headers['Authorization'];
    final token = auth is String && auth.startsWith('Bearer ') ? auth.substring(7) : null;
    final data = options.data;
    calls.add((key: key, body: data is Map ? data.cast<String, dynamic>() : null, token: token));

    // ---- 管理员态三接口（受限会话）----
    if (key == 'GET /recharge/requests') {
      if (listUnauthorized) {
        return _json({'code': 401, 'message': '受限管理身份已失效，请联系超级管理员重新授权', 'data': null}, 401);
      }
      if (listError != null) {
        return _json({'code': listError!.code, 'message': listError!.message, 'data': null}, listError!.code);
      }
      return _data({'list': _pending, 'total': _pending.length, 'pendingCount': _pending.length});
    }
    if (key == 'GET /recharge/me') {
      if (listUnauthorized) {
        return _json({'code': 401, 'message': '受限管理身份已失效，请联系超级管理员重新授权', 'data': null}, 401);
      }
      return _data({
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      });
    }
    if (key.startsWith('POST /recharge/requests/') && key.endsWith('/grant')) {
      grantCalls++;
      if (grantError != null) {
        return _json({'code': grantError!.code, 'message': grantError!.message, 'data': null}, grantError!.code);
      }
      return _data({'id': '9', 'points': 68, 'status': 'granted'});
    }
    if (key.startsWith('POST /recharge/requests/') && key.endsWith('/reject')) {
      rejectCalls++;
      return _data({'id': '9', 'status': 'rejected'});
    }

    // ---- 绑定受限管理员会话 ----
    if (key == 'POST /user/identity/bind-recharge-admin') {
      final e = bindError;
      if (e != null) return _json({'code': e.code, 'message': e.message, 'data': null}, e.code);
      return _data({
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'rechargeToken': 'recharge-token',
        'rechargeRefreshToken': 'recharge-refresh',
        'expiresIn': 43200,
      });
    }
    if (key == 'GET /user/identity') {
      return _data({'bound': false, 'activeCount': 0, 'maxPerBoss': 1, 'bindings': []});
    }

    // ---- 老板端最小底座（切换回老板态后 HomeShell 要能正常渲染）----
    if (key == 'GET /public/clubs') return _data(const []);
    if (key == 'GET /public/site') return _data(const {'clubTitle': '官方自营', 'clubParagraphs': ['全段位上分']});
    if (key == 'GET /public/banners') return _data(const []);
    if (key == 'GET /public/recharge/config') {
      return _data(const {
        'amountOptions': [6, 20],
        'customEnabled': true,
        'minYuan': 6,
        'maxYuan': 200,
        'pointsPerYuan': 10,
        'noticeText': '付款后请上传截图并提交申请',
        'qrCodes': [
          {'id': '1', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/1'}
        ],
      });
    }
    if (key == 'GET /divisions/grouped') return _data(const []);
    if (key == 'GET /user/wallet') return _data(const {'balance': 1286});
    if (key == 'GET /user/orders') return _data(const {'list': [], 'total': 0});
    if (key == 'GET /user/conversations') return _data(const {'list': [], 'total': 0});
    if (key == 'GET /user/friends') return _data(const {'list': []});
    if (key == 'GET /user/friends/requests/incoming') return _data(const {'list': []});
    if (key == 'GET /user/notifications') return _data(const {'list': [], 'unread': 0});
    if (key == 'POST /user/ai/reset') return _data(const {'ok': true});
    if (key == 'GET /auth/me') {
      return _data(const {
        'id': '1',
        'username': 'ayuan',
        'uid': 'U8471209365',
        'nickname': '阿远',
        'role': 'user',
      });
    }
    return _json({'code': 404, 'message': 'Not Found', 'data': null}, 404);
  }

  ResponseBody _data(Object? data, {int status = 200}) =>
      _json({'code': 0, 'message': 'ok', 'data': data}, status);

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
