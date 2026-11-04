import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打手态「提现」验收 ①–⑦ —— 假 ApiClient（假 Dio 适配器）+ 假选图/上传，绝不发真网络。
///
/// | 项 | 断言 |
/// |---|---|
/// | ① | 未绑定 → 提现页显著提示「提现前需先绑定收款信息」+「去绑定」，且金额输入/提交都不可用 |
/// | ② | 金额 < 最低 → 中文「低于最低提现金额」，且**不发**申请请求 |
/// | ③ | 金额 > 上限 → 中文「超过单笔上限」，且**不发**申请请求 |
/// | ④ | 金额 > 余额 → 中文「**余额不足**」（本地当场拦下，服务端仍是权威） |
/// | ⑤ | 正常申请 → 请求形状 `{amount}` + **余额刷新**（提现页余额就地减少 + 「我的」收益卡回源） |
/// | ⑥ | **防连点**：连点提交只发一次请求 |
/// | ⑦ | 记录页三状态（处理中 / 已打款 / 已驳回 + 打款时间 + 驳回原因）与空态 |
///
/// 另覆盖：收款信息绑定表单（本地校验 + 服务端中文原文 + 收款码上传 `withdraw_qr`）。
void main() {
  late _WithdrawRouter router;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    router = _WithdrawRouter();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://wd.local'))..httpClientAdapter = router;
  });

  setUp(() {
    router.reset();
    ApiCache.instance.clear();
    WithdrawRefreshNotifier.instance.debugReset();
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
    // 进入打手态（companion 令牌）
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.worker,
      companionToken: 'companion-token',
    );
  });

  tearDown(() {
    AppToast.dismiss();
    WithdrawMedia.reset();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  ApiClient api() => ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://wd.local'))..httpClientAdapter = router);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settleShort(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> flushToasts(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2200));
    AppToast.dismiss();
  }

  Future<void> pumpPage(WidgetTester tester, Widget page,
      {Size size = const Size(390 * 3, 844 * 3)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      // 页面在真机上总是挂在 Scaffold 里（打手态外壳本身就是 Scaffold）；
      // 少这一层的话「我的」页里既有的 InkWell 会因缺 Material 祖先而报错
      // （与本次改动无关的既有约束，测试侧补齐即可）
      home: Scaffold(body: page),
    ));
    await settle(tester);
  }

  /// 一张**合法**的 1×1 PNG
  ///
  /// `Image.memory` 会真的去解码：拿随便几个字节会抛 "Invalid image data"，
  /// 把测试拖进与断言无关的异常里（本地预览位是必测项，不能为了绕开它而不测）。
  final validPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  );

  List<String> visibleTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  // =====================================================================================
  // ① 未绑定 → 提现页引导绑定
  // =====================================================================================
  testWidgets('① 未绑定：显著提示「提现前需先绑定收款信息」+「去绑定」，金额输入与提交都不可用', (tester) async {
    router.bound = false;
    await pumpPage(tester, WorkerWithdrawPage(api: api()));

    expect(find.text(WorkerWithdrawCopy.needBind), findsOneWidget, reason: '必须显著提示');
    expect(find.text(WorkerWithdrawCopy.goBind), findsWidgets, reason: '必须给出绑定出路');

    // 金额输入框不可编辑（未绑定填了也没用）
    final amount = tester.widget<TextField>(find.byKey(WorkerWithdrawPage.amountKey));
    expect(amount.enabled, isFalse, reason: '未绑定时金额输入不可用');
    // 提交按钮置灰
    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WorkerWithdrawPage.submitKey));
    expect(btn.onPressed, isNull, reason: '未绑定时提交按钮必须置灰');

    // 点「去绑定」进收款信息页（含收款码上传位）
    await tester.tap(find.text(WorkerWithdrawCopy.goBind).first);
    await settle(tester);
    expect(find.text(WorkerWithdrawCopy.bindTitle), findsOneWidget);
    expect(find.byKey(WorkerWithdrawAccountPage.qrTileKey), findsOneWidget, reason: '收款码上传位必须在');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ②③④ 金额当场校验（低于最低 / 超过上限 / 余额不足）
  // =====================================================================================
  testWidgets('② 低于最低 → 中文「低于最低提现金额」，且不发申请请求', (tester) async {
    await pumpPage(tester, WorkerWithdrawPage(api: api()));

    await tester.enterText(find.byKey(WorkerWithdrawPage.amountKey), '5');
    await settle(tester);

    expect(find.text(WorkerWithdrawCopy.errBelowMin(10)), findsWidgets);
    // 按钮置灰（判定未通过）
    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WorkerWithdrawPage.submitKey));
    expect(btn.onPressed, isNull);
    // 即便强行触发提交入口也不会发请求（按钮 onPressed 为 null）
    await tester.tap(find.byKey(WorkerWithdrawPage.submitKey), warnIfMissed: false);
    await settle(tester);
    expect(router.applyCalls, 0, reason: '低于最低不发申请请求');
    await flushToasts(tester);
  });

  testWidgets('③ 超过单笔上限 → 中文「超过单笔上限」', (tester) async {
    await pumpPage(tester, WorkerWithdrawPage(api: api()));

    await tester.enterText(find.byKey(WorkerWithdrawPage.amountKey), '3000');
    await settle(tester);

    expect(find.text(WorkerWithdrawCopy.errAboveMax(2000)), findsWidgets);
    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WorkerWithdrawPage.submitKey));
    expect(btn.onPressed, isNull);
    expect(router.applyCalls, 0);
    await flushToasts(tester);
  });

  testWidgets('④ 超过余额 → 中文「余额不足」（本地当场拦下）', (tester) async {
    await pumpPage(tester, WorkerWithdrawPage(api: api()));

    // 余额 320.5，上限 2000 → 500 只在"余额不足"上失败
    await tester.enterText(find.byKey(WorkerWithdrawPage.amountKey), '500');
    await settle(tester);

    final insufficient = WorkerWithdrawCopy.errInsufficient(320.5);
    expect(insufficient, contains('余额不足'));
    expect(find.text(insufficient), findsWidgets, reason: '必须显示含「余额不足」的中文提示');
    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WorkerWithdrawPage.submitKey));
    expect(btn.onPressed, isNull, reason: '余额不足时不许提交');
    expect(router.applyCalls, 0, reason: '余额不足不发请求（服务端仍是权威，客户端只少跑一趟）');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑤ 正常申请：请求形状 + 余额刷新
  // =====================================================================================
  testWidgets('⑤ 正常申请：POST {amount} + 余额就地减少 + 三处余额页面一起回源', (tester) async {
    await pumpPage(tester, WorkerWithdrawPage(api: api()));

    await tester.enterText(find.byKey(WorkerWithdrawPage.amountKey), '120');
    await settle(tester);
    await tester.tap(find.byKey(WorkerWithdrawPage.submitKey));
    await settleShort(tester);

    // 请求形状：只有 amount + 幂等键（契约 body `{amount, idempotencyKey?}`；
    // 幂等键让"网络重试"不会重复扣款 —— 服务端按它返回首次结果）
    final call = router.calls.firstWhere((c) => c.key == 'POST /worker/withdraw/requests');
    expect(call.body?['amount'], 120);
    expect(call.body?['idempotencyKey'], isA<String>());
    expect((call.body?['idempotencyKey'] as String).isNotEmpty, isTrue);
    expect(call.token, 'companion-token', reason: '打手态必须用 companion 令牌');

    // 申请请求只发一次
    expect(router.applyCalls, 1);

    // 成功文案（**唯一**成功文案）+ 服务端 balanceAfter 就地生效
    expect(find.text(WorkerWithdrawCopy.applied), findsOneWidget);
    expect(find.textContaining('可用余额 ¥200.50'), findsOneWidget, reason: '320.50 − 120.00 = 200.50');

    // **余额刷新**：广播带上了金额与服务端权威余额
    expect(WithdrawRefreshNotifier.instance.lastAppliedAmount, 120);
    expect(WithdrawRefreshNotifier.instance.lastBalanceAfter, 200.5);
    await flushToasts(tester);
  });

  testWidgets('⑤b 「我的」页收益卡：提现成功后余额立刻回源（不是只刷提现页）', (tester) async {
    // 真页面：打手态「我的」（含收益卡 + 提现入口）
    await pumpPage(tester, IdentityWorkerMinePage(api: api()));
    expect(find.text('¥320.50'), findsWidgets, reason: '收益卡先显示 320.50');

    // 模拟"提现申请成功"：服务端余额已变成 200.50 → 广播
    router.walletBalance = 200.5;
    WithdrawRefreshNotifier.instance.refresh(amount: 120, balanceAfter: 200.5);
    await settle(tester);

    expect(find.text('¥200.50'), findsWidgets, reason: '「我的」页余额必须回源');
    expect(find.text('¥320.50'), findsNothing, reason: '不许还留着旧余额（钱已扣但界面说没扣）');
    // 「我的」页必须有提现入口
    expect(find.byKey(WorkerWithdrawEntry.entryKey), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.entryTitle), findsWidgets);
  });

  // =====================================================================================
  // ⑥ 防连点
  // =====================================================================================
  testWidgets('⑥ 防连点：连点提交只发一次请求', (tester) async {
    router.applyDelay = const Duration(milliseconds: 220);
    await pumpPage(tester, WorkerWithdrawPage(api: api()));

    await tester.enterText(find.byKey(WorkerWithdrawPage.amountKey), '120');
    await settle(tester);

    // 连点 5 次（不含中间的 settle：模拟真实连点）
    final btn = find.byKey(WorkerWithdrawPage.submitKey);
    for (var i = 0; i < 5; i++) {
      await tester.tap(btn, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester);
    await settle(tester);

    expect(router.applyCalls, 1, reason: '连点只发一次');
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑦ 记录页三状态 + 空态
  // =====================================================================================
  testWidgets('⑦ 提现记录：三状态标签 + 申请时间 + 打款时间 / 驳回原因', (tester) async {
    await pumpPage(tester, WorkerWithdrawRecordsPage(api: api()));

    // 三状态
    expect(find.text(WorkerWithdrawCopy.statusPending), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.statusPaid), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.statusRejected), findsOneWidget);
    // 金额一律 ¥ 两位小数
    expect(find.text('¥120.00'), findsOneWidget);
    expect(find.text('¥68.00'), findsOneWidget);
    expect(find.text('¥300.00'), findsOneWidget);
    // 申请时间 + 打款时间
    expect(find.textContaining('申请 '), findsWidgets);
    expect(find.textContaining('打款 '), findsOneWidget);
    // 驳回原因
    expect(find.textContaining('驳回原因：收款信息与本人不一致'), findsOneWidget);

    // 提现链路禁用词（含旧单位「积分」）逐屏 0 命中
    final texts = visibleTexts(tester);
    for (final w in WorkerWithdrawCopy.forbiddenWords) {
      expect(texts.any((t) => t.contains(w)), isFalse, reason: '提现记录页出现「$w」');
    }
    await flushToasts(tester);
  });

  testWidgets('⑦b 提现记录空态：文案具体（不是白屏）', (tester) async {
    router.records = const [];
    await pumpPage(tester, WorkerWithdrawRecordsPage(api: api()));

    expect(find.text(WorkerWithdrawCopy.recordsEmpty), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.recordsEmptyDetail), findsOneWidget);
  });

  // =====================================================================================
  // 收款信息（绑定/换绑页）
  // =====================================================================================
  testWidgets('绑定页：本地校验（手机号 11 位 / 姓名 / 微信号）+ 收款码上传用 withdraw_qr', (tester) async {
    WithdrawMedia.configure(
      picker: () async => PickedWithdrawImage(bytes: validPng, name: 'qr.png'),
    );
    await pumpPage(
      tester,
      WorkerWithdrawAccountPage(
        api: api(),
        uploader: ({required type, required bytes, required filename, required token}) async {
          router.uploadTypes.add(type);
          return const MediaUploadResult(id: 'qr-media-9', mimeType: 'image/png');
        },
        picker: () async => PickedWithdrawImage(bytes: validPng, name: 'qr.png'),
      ),
    );

    // ① 空表单 + 没图 → 第一个错是姓名
    await tester.tap(find.text('保存收款信息'));
    await settle(tester);
    expect(find.textContaining('请填写收款人姓名'), findsOneWidget);
    expect(router.accountCalls, 0);

    // ② 姓名填好、手机号非法 → 手机号错误（且必须是 11 位）
    await tester.enterText(find.byKey(const Key('withdraw-real-name')), '张三');
    await tester.enterText(find.byKey(const Key('withdraw-phone')), '1380000');
    await tester.enterText(find.byKey(const Key('withdraw-wechat')), 'zhangsan_88');
    await tester.tap(find.text('保存收款信息'));
    await settle(tester);
    expect(find.textContaining('手机号请填 11 位数字'), findsOneWidget);
    expect(router.accountCalls, 0);

    // ③ 手机号合法但没上传收款码 → 提示上传
    await tester.enterText(find.byKey(const Key('withdraw-phone')), '13800001234');
    await tester.tap(find.text('保存收款信息'));
    await settle(tester);
    expect(find.textContaining('请上传微信收款码'), findsOneWidget);
    expect(router.accountCalls, 0);

    // ④ 上传收款码（用途必须是 withdraw_qr）→ 保存 → 成功
    await tester.tap(find.byKey(WorkerWithdrawAccountPage.qrTileKey));
    await settle(tester);
    expect(router.uploadTypes, contains(WithdrawMedia.qrType));

    await tester.tap(find.text('保存收款信息'));
    await settleShort(tester);
    final call = router.calls.firstWhere((c) => c.key == 'POST /worker/withdraw/account');
    expect(call.body?['realName'], '张三');
    expect(call.body?['phone'], '13800001234');
    expect(call.body?['wechatId'], 'zhangsan_88');
    expect(call.body?['qrMediaId'], 'qr-media-9');
    expect(find.text(WorkerWithdrawCopy.bound), findsOneWidget);
    await flushToasts(tester);
  });

  testWidgets('绑定提交失败：服务端中文原文原样展示（不改写、不吞掉）', (tester) async {
    router.accountError = (code: 400, message: '这个手机号已被其它账号绑定');
    await pumpPage(
      tester,
      WorkerWithdrawAccountPage(
        api: api(),
        picker: () async => PickedWithdrawImage(bytes: validPng, name: 'qr.png'),
        uploader: ({required type, required bytes, required filename, required token}) async =>
            const MediaUploadResult(id: 'qr-1', mimeType: 'image/png'),
      ),
    );
    await tester.enterText(find.byKey(const Key('withdraw-real-name')), '张三');
    await tester.enterText(find.byKey(const Key('withdraw-phone')), '13800001234');
    await tester.enterText(find.byKey(const Key('withdraw-wechat')), 'zhangsan_88');
    await tester.tap(find.byKey(WorkerWithdrawAccountPage.qrTileKey));
    await settle(tester);
    await tester.tap(find.text('保存收款信息'));
    await settle(tester);

    expect(find.text('这个手机号已被其它账号绑定'), findsOneWidget);
    await flushToasts(tester);
  });

  testWidgets('换绑页：明确提示「换绑后新收款信息用于后续打款」', (tester) async {
    await pumpPage(
      tester,
      WorkerWithdrawAccountPage(
        api: api(),
        account: const WorkerWithdrawAccount(
          bound: true,
          realName: '张*山',
          phone: '138****8888',
          wechatId: 'zhangsan_88',
          qrUrl: '/media/public/7',
          updatedAt: null,
        ),
        rebind: true,
      ),
    );

    expect(find.text(WorkerWithdrawAccountPage.titleOf(rebind: true)), findsOneWidget);
    expect(find.text('换绑后新收款信息用于后续打款'), findsOneWidget);
    expect(find.textContaining('正在处理中的提现仍按原信息打款'), findsOneWidget);
    // 脱敏值不能原样提交（否则服务端会把 * 存成姓名）
    await tester.tap(find.text('保存收款信息'));
    await settle(tester);
    expect(find.textContaining('请重新填写完整姓名'), findsOneWidget);
    expect(router.accountCalls, 0);
  });

  // =====================================================================================
  // ⑩（负向扫描）提现链路文案不含「积分」
  // =====================================================================================
  testWidgets('⑩ 提现链路全部文案不含「积分」（负向扫描，含各页可见文本）', (tester) async {
    // 常量层
    final copy = <String>[
      WorkerWithdrawCopy.entryTitle,
      WorkerWithdrawCopy.entrySubtitle,
      WorkerWithdrawCopy.needBind,
      WorkerWithdrawCopy.goBind,
      WorkerWithdrawCopy.boundHint,
      WorkerWithdrawCopy.rebindNotice,
      WorkerWithdrawCopy.bound,
      WorkerWithdrawCopy.rebound,
      WorkerWithdrawCopy.pageTitle,
      WorkerWithdrawCopy.recordsTitle,
      WorkerWithdrawCopy.bindTitle,
      WorkerWithdrawCopy.allAmount,
      WorkerWithdrawCopy.submit,
      WorkerWithdrawCopy.submitting,
      WorkerWithdrawCopy.applied,
      WorkerWithdrawCopy.appliedDetail,
      WorkerWithdrawCopy.recordsEmpty,
      WorkerWithdrawCopy.recordsEmptyDetail,
      WorkerWithdrawCopy.auditEmpty,
      WorkerWithdrawCopy.auditEmptyDetail,
      WorkerWithdrawCopy.pickQr,
      WorkerWithdrawCopy.pickPayoutProof,
      WorkerWithdrawCopy.payConfirmWarning,
      WorkerWithdrawCopy.rejectConfirmWarning,
      WorkerWithdrawCopy.forbidden,
      WorkerWithdrawCopy.errBadAmount,
      WorkerWithdrawCopy.errTooManyDecimals,
      WorkerWithdrawCopy.errInsufficient(320.5),
      WorkerWithdrawCopy.errBelowMin(10),
      WorkerWithdrawCopy.errAboveMax(2000),
      WorkerWithdrawCopy.statusPending,
      WorkerWithdrawCopy.statusPaid,
      WorkerWithdrawCopy.statusRejected,
      WorkerWithdrawCopy.payButton,
      WorkerWithdrawCopy.rejectButton,
      WorkerWithdrawCopy.paid,
      WorkerWithdrawCopy.rejected,
      WithdrawReviewDetailPage.payNeedProof,
      WithdrawRejectSheet.reasonRequired,
      WithdrawMedia.unavailableMessage,
      '我的收益',
    ];
    for (final t in copy) {
      for (final w in WorkerWithdrawCopy.forbiddenWords) {
        expect(t.contains(w), isFalse, reason: '文案「$t」不得出现「$w」');
      }
    }
    // 提现链路禁用词表本身必须含旧计价单位「积分」（负责人硬要求）
    expect(WorkerWithdrawCopy.forbiddenWords, contains('积分'));

    // 页面层：提现页（已绑定态）
    await pumpPage(tester, WorkerWithdrawPage(api: api()));
    for (final w in WorkerWithdrawCopy.forbiddenWords) {
      expect(visibleTexts(tester).any((t) => t.contains(w)), isFalse, reason: '提现页出现「$w」');
    }
    // 页面层：收款信息页
    await pumpPage(tester, WorkerWithdrawAccountPage(api: api()));
    for (final w in WorkerWithdrawCopy.forbiddenWords) {
      expect(visibleTexts(tester).any((t) => t.contains(w)), isFalse, reason: '收款信息页出现「$w」');
    }
    await flushToasts(tester);
  });

  // =====================================================================================
  // 打手态「我的」页仍只有三处 + 提现入口在其中
  // =====================================================================================
  testWidgets('打手态底栏仍是三项；提现入口在「我的」里（不新增 tab）', (tester) async {
    await pumpPage(
      tester,
      IdentityWorkerShell(api: api(), canServeCustomer: false),
    );
    expect(find.byType(AppPlainBottomNav), findsOneWidget);
    expect(IdentityWorkerShell.navItems.length, 3, reason: '打手态底栏固定三项');
    for (final label in ['接单', '消息', '我的']) {
      expect(find.text(label), findsWidgets);
    }
    // 切到「我的」（底栏第 3 项）
    await tester.tap(find.text('我的').last);
    await settle(tester);
    expect(find.byKey(WorkerWithdrawEntry.entryKey), findsOneWidget, reason: '提现入口必须在「我的」页');
    await flushToasts(tester);
  });
}

/// 假服务器：打手端提现族接口 + 打手态最小底座；并记录每一次请求（key / body / token）
class _WithdrawRouter implements HttpClientAdapter {
  bool bound = true;
  num walletBalance = 320.5;
  Duration? applyDelay;
  ({int code, String message})? accountError;

  int applyCalls = 0;
  int accountCalls = 0;
  final List<String> uploadTypes = [];

  /// 已发请求（key = `METHOD path`）
  final List<({String key, Map<String, dynamic>? body, String? token})> calls = [];

  /// 提现记录（可改：空态用例用）
  List<Map<String, dynamic>> records = [
    {
      'id': '101',
      'amount': 120,
      'status': 'pending',
      'balanceAfter': 200.5,
      'appliedAt': '2026-10-11T09:12:00Z',
    },
    {
      'id': '102',
      'amount': 68,
      'status': 'paid',
      'appliedAt': '2026-10-10T14:03:00Z',
      'paidAt': '2026-10-10T16:40:00Z',
    },
    {
      'id': '103',
      'amount': 300,
      'status': 'rejected',
      'appliedAt': '2026-10-09T11:20:00Z',
      'rejectReason': '收款信息与本人不一致',
    },
  ];

  void reset() {
    bound = true;
    walletBalance = 320.5;
    applyDelay = null;
    accountError = null;
    applyCalls = 0;
    accountCalls = 0;
    uploadTypes.clear();
    calls.clear();
    records = [
      {
        'id': '101',
        'amount': 120,
        'status': 'pending',
        'balanceAfter': 200.5,
        'appliedAt': '2026-10-11T09:12:00Z',
      },
      {
        'id': '102',
        'amount': 68,
        'status': 'paid',
        'appliedAt': '2026-10-10T14:03:00Z',
        'paidAt': '2026-10-10T16:40:00Z',
      },
      {
        'id': '103',
        'amount': 300,
        'status': 'rejected',
        'appliedAt': '2026-10-09T11:20:00Z',
        'rejectReason': '收款信息与本人不一致',
      },
    ];
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

    // ---- 提现族（打手端）----
    if (key == 'GET /worker/withdraw/account') {
      if (!bound) return _data(const {'bound': false});
      return _data(const {
        'bound': true,
        'realName': '张*山',
        'phone': '138****8888',
        'wechatId': 'zhangsan_88',
        'qrUrl': '/media/public/7',
        'updatedAt': '2026-10-08T10:00:00Z',
      });
    }
    if (key == 'POST /worker/withdraw/account') {
      accountCalls++;
      final e = accountError;
      if (e != null) return _json({'code': e.code, 'message': e.message, 'data': null}, e.code);
      return _data({'bound': true, 'realName': '张*山', 'phone': '138****8888', 'wechatId': 'zhangsan_88'});
    }
    if (key == 'GET /worker/withdraw/config') {
      return _data({
        'minAmount': 10,
        'maxAmount': 2000,
        'dailyLimit': 1,
        'feeRate': 0,
        'noticeText': '提现会在 1 个工作日内处理，请确认收款信息无误。',
        'balance': walletBalance,
        'todayUsed': 0,
      });
    }
    if (key == 'POST /worker/withdraw/requests') {
      applyCalls++;
      final delay = applyDelay;
      if (delay != null) await Future<void>.delayed(delay);
      final amount = (data is Map ? data['amount'] as num? : null) ?? 0;
      return _data({
        'id': '200',
        'amount': amount,
        'status': 'pending',
        'balanceAfter': walletBalance - amount,
        'appliedAt': '2026-10-11T10:00:00Z',
      });
    }
    if (key == 'GET /worker/withdraw/requests') {
      return _data({'list': records, 'total': records.length});
    }

    // ---- 打手态最小底座 ----
    if (key == 'GET /worker/my-wallet') {
      return _data({
        'balance': walletBalance,
        'totalIncome': 1860.5,
        'settlementCount': 24,
        'tipIncome': 66,
        'totalGranted': 100,
      });
    }
    if (key == 'GET /worker/wallet/transactions') return _data(const {'list': [], 'total': 0});
    if (key == 'GET /auth/me') {
      return _data(const {
        'id': '9',
        'username': 'wangye_go',
        'uid': 'U20260118',
        'nickname': '王野',
        'role': 'worker',
        'worker': {'workerNo': 'W20260118', 'nickname': '王野', 'canTakeOrder': true},
      });
    }
    if (key == 'GET /worker/me') {
      return _data(const {'workerNo': 'W20260118', 'nickname': '王野', 'canTakeOrder': true});
    }
    if (key == 'GET /user/identity') {
      return _data(const {'bound': true, 'activeCount': 1, 'maxPerBoss': 1, 'bindings': []});
    }
    if (key == 'GET /worker/order-hall') return _data(const {'list': [], 'total': 0});
    if (key == 'GET /user/conversations') return _data(const {'list': [], 'total': 0});
    if (key == 'GET /user/friends') return _data(const {'list': []});

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
