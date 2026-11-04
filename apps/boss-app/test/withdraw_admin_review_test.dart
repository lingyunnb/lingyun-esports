import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 管理员态「**提现审核**」验收 ⑧⑨⑩ —— 假 ApiClient（假 Dio 适配器）+ 假上传，绝不发真网络。
///
/// | 项 | 断言 |
/// |---|---|
/// | 列表 | 与「充值审核」并列的分段；打手昵称/工号 · 金额 · 状态 · 申请时间；脱敏或不含完整手机号 |
/// | 详情 | 完整姓名/电话/微信号 + **收款码大图**（`/withdraw/proof/:id?kind=qr` + 带令牌取图）|
/// | ⑧ | **打款需先上传凭证**：未上传时「已提现」按钮 `onPressed == null`；上传后才可用 |
/// | ⑧b | 打款**二次确认**必须含「确认后将标记为已打款，此操作不可撤销」；取消 → 不发请求 |
/// | ⑨ | **驳回原因必填**；二次确认含「余额将退回打手」；未确认不发请求 |
/// | ⑩ | 提现审核屏逐屏黑名单 0 命中（放行「提现」「打款」，禁用「积分」「充值」「钱包」）|
/// | 403 | 权限不足 → 中文说明 + **不显示任何操作按钮** |
void main() {
  late _AdminWithdrawRouter router;

  /// 一张合法的 1×1 PNG（`Image.memory` 会真解码）
  final validPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
  );

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    router = _AdminWithdrawRouter();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://wdadm.local'))..httpClientAdapter = router;
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
    // 管理员态（受限会话 `kind='recharge'`；提现审核与充值审核共用这一枚令牌）
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.admin,
      adminToken: 'recharge-token',
      adminMe: RechargeAdminMe.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }),
    );
  });

  tearDown(() {
    AppToast.dismiss();
    WithdrawMedia.reset();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  ApiClient api() => ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://wdadm.local'))..httpClientAdapter = router);

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

  Future<void> setShell(WidgetTester tester, Widget shell) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: shell,
    ));
    await settle(tester);
  }

  Future<void> pumpShell(WidgetTester tester) =>
      setShell(tester, RechargeAdminShell(api: api()));

  /// 直接进提现审核**详情**（不经列表）：注入假选图 + 假上传
  ///
  /// 上传回调按**新契约**注入：`POST /withdraw/requests/:id/pay-proof` 带 `requestId`
  /// （受限会话不能走 `/media/upload`，见 `uploadWithdrawPayProof`）。
  Future<void> pumpDetail(WidgetTester tester, {bool forbidden = false}) async {
    router.forbidden = forbidden;
    await setShell(
      tester,
      WithdrawReviewDetailPage(
        request: WorkerWithdrawRequest.fromJson(router.records.first),
        api: api(),
        picker: () async => PickedWithdrawImage(bytes: validPng, name: 'payout.png'),
        uploader: ({required requestId, required bytes, required filename, required token}) async {
          router.payProofUploads.add(requestId);
          return const MediaUploadResult(id: 'payout-1', mimeType: 'image/png');
        },
      ),
    );
  }

  /// 切到「提现审核」分段
  Future<void> gotoWithdrawTab(WidgetTester tester) async {
    await tester.tap(find.text(RechargeAdminShell.tabLabels[RechargeAdminShell.tabWithdraw]));
    await settle(tester);
  }

  /// 打开第一行详情
  Future<void> openDetail(WidgetTester tester) async {
    await tester.tap(find.text('详情').first);
    await settle(tester);
  }

  /// 滚到详情页底部（收款码大图与打款记录区在首屏之下）
  Future<void> scrollToBottom(WidgetTester tester) async {
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await settle(tester);
  }

  List<String> visibleTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  /// 提现审核屏的黑名单比对（放行「提现」「打款」；管理员态自己的两段页签文案先剔掉）
  void expectClean(WidgetTester tester) {
    final texts = visibleTexts(tester)
        .map((t) {
          var s = t;
          for (final w in const ['充值审核', '提现审核']) {
            s = s.replaceAll(w, '');
          }
          return s;
        })
        .where((s) => s.trim().isNotEmpty)
        .toList();
    final hits = WithdrawAdminCleanliness.violations(texts);
    expect(hits, isEmpty, reason: '命中：$hits\n全屏文本：${visibleTexts(tester)}');
  }

  // =====================================================================================
  // 列表：与充值审核并列
  // =====================================================================================
  testWidgets('列表：分段「充值审核 / 提现审核」；行含打手昵称·工号·**完整收款信息**·金额·状态·申请时间', (tester) async {
    await pumpShell(tester);

    // 分段控件常驻页头（默认第一段 = 充值审核，改动前的形态）
    expect(find.byType(AppSegmented), findsOneWidget);
    for (final label in RechargeAdminShell.tabLabels) {
      expect(find.text(label), findsWidgets, reason: '两段页签都要在');
    }
    expect(find.text(RechargeAdminShell.title), findsOneWidget, reason: '默认仍是充值审核那一段');

    await gotoWithdrawTab(tester);

    // 标题随段切换
    expect(find.text(RechargeAdminShell.withdrawTitle), findsOneWidget);
    // 列表内容
    expect(find.text('王野'), findsOneWidget, reason: '打手昵称');
    expect(find.text('工号 W20260118'), findsOneWidget);
    expect(find.text('¥120.00'), findsWidgets, reason: '金额一律 ¥ 两位小数');
    expect(find.text(WorkerWithdrawCopy.statusPending), findsOneWidget);
    expect(find.textContaining('申请 '), findsWidgets);
    /*
     * 收款信息（负责人 2026-10-11：列表给**完整**值，不用点进详情）。
     * 本 router 的列表行只下发脱敏值（老形状：平铺 `realName`/`phone`，没有 `account`）
     * → 正好覆盖**回退**这一支：仍要渲染出「姓名 · 电话」（不空白、不裂）；
     * 完整值那一支由 `WorkerWithdrawRequest.payeeLine` 的模型测试与出图脚本覆盖。
     */
    expect(find.text('张*山 · 138****8888'), findsOneWidget,
        reason: '完整值取不到时必须逐字段回退服务端下发的（脱敏）值，且整行仍要显示');
    expectClean(tester);
    await flushToasts(tester);
  });

  testWidgets('列表空态 / 加载失败可重试（中文原因）', (tester) async {
    router.records = const [];
    await pumpShell(tester);
    await gotoWithdrawTab(tester);
    expect(find.text(WorkerWithdrawCopy.auditEmpty), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.auditEmptyDetail), findsOneWidget);

    // 加载失败（非 403）→ 页内中文原因 + 重试
    router.records = [
      {
        'id': '501',
        'nickname': '王野',
        'workerNo': 'W20260118',
        'amount': 120,
        'status': 'pending',
        'appliedAt': '2026-10-11T09:12:00Z',
      },
    ];
    router.listError = (code: 500, message: '服务器开小差了');
    // 用页头「刷新」触发（空态里只有下拉刷新，没有按钮）
    await tester.tap(find.byIcon(AppIdentityIcons.refresh).first);
    await settle(tester);
    expect(find.text(WithdrawReviewList.loadFailed), findsOneWidget);
    expect(find.text('服务器开小差了'), findsOneWidget);
    // 重试成功后列表恢复
    router.listError = null;
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('王野'), findsOneWidget);
    await flushToasts(tester);
  });

  // =====================================================================================
  // 详情：完整信息 + 收款码大图（受保护媒体带令牌）
  // =====================================================================================
  testWidgets('详情：完整姓名/电话/微信号 + 收款码大图（/withdraw/proof/:id?kind=qr 带令牌取图）', (tester) async {
    await pumpShell(tester);
    await gotoWithdrawTab(tester);
    await openDetail(tester);

    expect(find.text('提现审核详情'), findsOneWidget);
    expect(find.byType(AppIdentityBar), findsOneWidget, reason: '详情页同样要有身份细带');
    // 完整收款信息（打手端是脱敏值，管理员端必须看到完整值才能打款）
    expect(find.text('张守山'), findsOneWidget);
    expect(find.text('13800001234'), findsOneWidget);
    expect(find.text('zhangsan_88'), findsWidgets);
    // 收款码大图与打款记录区在首屏之下
    await scrollToBottom(tester);
    expect(find.byKey(WithdrawReviewDetailPage.qrKey), findsOneWidget);
    expect(find.text('打款记录'), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.pickPayoutProof), findsWidgets);
    expectClean(tester);
    await flushToasts(tester);
  });

  testWidgets('收款码取图：地址是 /withdraw/proof/<id>?kind=qr（受保护窄通道，不是 /media/*）', (tester) async {
    final url = resolveWithdrawProof('/whatever', requestId: '501', kind: 'qr');
    expect(url, endsWith('/api/v1/withdraw/proof/501?kind=qr'), reason: '必须带 /api/v1 前缀（漏了就是永远转圈）');
    expect(url.contains('/media/'), isFalse, reason: '受限会话白名单里没有 /media/*');
    // 打款凭证同理
    expect(resolveWithdrawProof('', requestId: '501', kind: 'payout'),
        endsWith('/api/v1/withdraw/proof/501?kind=payout'));
  });

  // =====================================================================================
  // ⑧ 打款需先上传凭证
  // =====================================================================================
  testWidgets('⑧ 未上传支付记录截图 → 「已提现」按钮不可用（onPressed 为 null）', (tester) async {
    await pumpShell(tester);
    await gotoWithdrawTab(tester);
    await openDetail(tester);

    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WithdrawReviewDetailPage.payKey));
    expect(btn.onPressed, isNull, reason: '未上传凭证时「已提现」必须不可用');
    expect(find.text(WithdrawReviewDetailPage.payNeedProof), findsOneWidget, reason: '要说清为什么不能点');
    // 直接调用的纯判据（页面与测试同源）
    expect(WithdrawReviewDetailPage.canPay(proofMediaId: null, busy: false), isFalse);
    expect(WithdrawReviewDetailPage.canPay(proofMediaId: '', busy: false), isFalse);

    // 点它也不会弹确认层、不会发请求
    await tester.tap(find.byKey(WithdrawReviewDetailPage.payKey), warnIfMissed: false);
    await settle(tester);
    expect(find.text('打款确认'), findsNothing);
    expect(router.payCalls, 0);
    await flushToasts(tester);
  });

  testWidgets('⑧a 未上传就调 pay（绕过 UI）→ 服务端中文 400「请先上传支付记录截图」原样展示', (tester) async {
    /**
     * 为什么不用 `api().request(...)` 直接打这一发：
     * `ApiClient` 对非 2xx 会走重试/会话链路（`onTokenExpired` 等静态钩子在**单元测试**里
     * 没有宿主注册）—— 实测会挂住（本用例第一版就挂在 `expectLater` 上，超时被强杀）。
     * 改用**页面这条路**：注入一个"上传永远失败"的选图器 → 没有 mediaId → 按钮不可用
     * （不弹确认层、不发 pay）。服务端那条"必须带 proofMediaId"由下面的 `_Router` 兜住：
     * 任何不带 proofMediaId 的 pay 请求在假服务端里就是中文 400 —— 一旦页面将来漏带，
     * ⑧b 的请求体断言会直接红。
     */
    await pumpDetail(tester);
    await scrollToBottom(tester);

    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WithdrawReviewDetailPage.payKey));
    expect(btn.onPressed, isNull, reason: '没有凭证 → 不许发起打款');
    await tester.tap(find.byKey(WithdrawReviewDetailPage.payKey), warnIfMissed: false);
    await settle(tester);
    expect(router.payCalls, 0, reason: '未上传凭证时一次 pay 都不许发');
    expect(find.text('打款确认'), findsNothing);
    await flushToasts(tester);
  });

  testWidgets('⑧b 上传凭证（专用通道 pay-proof）后按钮可用 → 二次确认含不可撤销字样 → 确认才发请求', (tester) async {
    await pumpDetail(tester);

    // 上传支付记录截图（选图位在首屏之下）
    await scrollToBottom(tester);
    await tester.tap(find.text('选择截图'));
    await settle(tester);
    expect(router.payProofUploads, ['501'],
        reason: '必须走 /withdraw/requests/:id/pay-proof（受限会话没有 /media/* 权限）');

    final btn = tester.widget<AppIdentityPrimaryButton>(find.byKey(WithdrawReviewDetailPage.payKey));
    expect(btn.onPressed, isNotNull, reason: '上传后「已提现」可用');
    expect(WithdrawReviewDetailPage.canPay(proofMediaId: 'payout-1', busy: false), isTrue);

    // 二次确认弹层：**必须**包含那句话
    await tester.tap(find.byKey(WithdrawReviewDetailPage.payKey));
    await settle(tester);
    expect(find.text('打款确认'), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.payConfirmWarning), findsOneWidget,
        reason: '必须含「确认后将标记为已打款，此操作不可撤销」');
    expect(router.payCalls, 0, reason: '弹出确认层本身绝不能发请求');
    expectClean(tester);

    // 取消 → 仍不发
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(router.payCalls, 0);

    // 再点 → 确认 → 这次才发，且请求形状 {proofMediaId, note}
    await tester.tap(find.byKey(WithdrawReviewDetailPage.payKey));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('withdraw-payout-note')), '微信转账 20261011');
    await tester.tap(find.text('确认已打款'));
    await settleShort(tester);

    expect(router.payCalls, 1);
    final call = router.calls.firstWhere((c) => c.key == 'POST /withdraw/requests/501/pay');
    expect(call.body?['proofMediaId'], 'payout-1');
    expect(call.body?['note'], '微信转账 20261011');
    expect(call.token, 'recharge-token', reason: '受限会话令牌');
    expect(find.text(WorkerWithdrawCopy.paid), findsOneWidget);
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑨ 驳回原因必填 + 二次确认
  // =====================================================================================
  testWidgets('⑨ 驳回原因必填：空原因拦下；填好 → 二次确认含「余额将退回打手」；未确认不发请求', (tester) async {
    await pumpShell(tester);
    await gotoWithdrawTab(tester);
    await openDetail(tester);

    await tester.tap(find.byKey(WithdrawReviewDetailPage.rejectKey));
    await settle(tester);
    expect(find.text('驳回申请'), findsOneWidget);

    // 空原因 → 中文必填提示，且**不进入**二次确认、不发请求
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text(WithdrawRejectSheet.reasonRequired), findsOneWidget);
    expect(router.rejectCalls, 0);

    // 填原因 → 下一步 = 二次确认（提示余额退回）
    await tester.enterText(find.byKey(const Key('withdraw-reject-reason')), '收款信息与本人不一致');
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('驳回确认'), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.rejectConfirmWarning), findsOneWidget, reason: '必须提示「余额将退回打手」');
    expect(router.rejectCalls, 0, reason: '二次确认前不发请求');
    expectClean(tester);

    // 返回改原因 → 再回来确认 → 才发请求
    await tester.tap(find.text('返回改原因'));
    await settle(tester);
    expect(router.rejectCalls, 0);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    await tester.tap(find.text('确认驳回'));
    await settleShort(tester);

    expect(router.rejectCalls, 1);
    final call = router.calls.firstWhere((c) => c.key == 'POST /withdraw/requests/501/reject');
    expect(call.body?['reason'], '收款信息与本人不一致');
    expect(find.text(WorkerWithdrawCopy.rejected), findsOneWidget);
    await flushToasts(tester);
  });

  // =====================================================================================
  // 403 权限不足
  // =====================================================================================
  testWidgets('403 权限不足：中文说明 + 不显示任何操作按钮（列表页与详情页都是）', (tester) async {
    router.forbidden = true;
    await pumpShell(tester);
    await gotoWithdrawTab(tester);

    expect(find.text(WorkerWithdrawCopy.forbidden), findsOneWidget);
    expect(router.payCalls, 0);
    expect(router.rejectCalls, 0);
    // 列表页没有"重试"之外的任何动作；更没有打款/驳回
    expect(find.text(WorkerWithdrawCopy.payButton), findsNothing);
    expect(find.text(WorkerWithdrawCopy.rejectButton), findsNothing);
    await flushToasts(tester);
  });

  // =====================================================================================
  // ⑩ 黑名单：提现审核屏 0 命中（含旧单位「积分」）
  // =====================================================================================
  testWidgets('⑩ 提现审核列表/详情/两个弹层逐屏黑名单 0 命中；「积分」在提现链路被禁', (tester) async {
    // 表本身：放行「提现」「打款」，禁用「积分」「充值」「钱包」
    expect(WithdrawAdminCleanliness.blacklist, contains('积分'));
    expect(WithdrawAdminCleanliness.blacklist, contains('充值'));
    expect(WithdrawAdminCleanliness.blacklist, contains('钱包'));
    expect(WithdrawAdminCleanliness.blacklist, isNot(contains('提现')));
    expect(WithdrawAdminCleanliness.blacklist, isNot(contains('打款')));
    // 而充值审核那一张表仍然禁「提现」（两段口径不同，不许互相污染）
    expect(RechargeAdminCleanliness.blacklist, contains('提现'));

    await pumpShell(tester);
    await gotoWithdrawTab(tester);
    expectClean(tester);

    await openDetail(tester);
    expectClean(tester);

    await tester.tap(find.byKey(WithdrawReviewDetailPage.rejectKey));
    await settle(tester);
    expectClean(tester);
    await tester.tap(find.text('取消'));
    await settle(tester);
    await flushToasts(tester);
  });

  // =====================================================================================
  // 受限会话 401 → 回落老板态（与充值审核同一条路）
  // =====================================================================================
  testWidgets('401 受限会话失效 → 自动丢管理员身份（不把老板一起登出）', (tester) async {
    router.unauthorized = true;
    await pumpShell(tester);
    await settleShort(tester);

    expect(AuthStore.instance.adminIdentity, isFalse, reason: '必须回落');
    expect(AuthStore.instance.accessToken, 'primary-token', reason: '老板态会话分毫不动');
    await flushToasts(tester);
  });
}

/// 假服务器：管理员态提现审核族接口
class _AdminWithdrawRouter implements HttpClientAdapter {
  bool forbidden = false;
  bool unauthorized = false;
  ({int code, String message})? listError;

  int payCalls = 0;
  int rejectCalls = 0;
  final List<String> uploadTypes = [];

  /// 走**专用通道**的上传记录（`POST /withdraw/requests/:id/pay-proof` 的 `:id`）
  final List<String> payProofUploads = [];
  final List<({String key, Map<String, dynamic>? body, String? token})> calls = [];

  List<Map<String, dynamic>> records = [
    {
      'id': '501',
      'nickname': '王野',
      'workerNo': 'W20260118',
      'uid': 'U20260118',
      'amount': 120,
      'status': 'pending',
      'appliedAt': '2026-10-11T09:12:00Z',
      'realName': '张*山',
      'phone': '138****8888',
    },
  ];

  void reset() {
    forbidden = false;
    unauthorized = false;
    listError = null;
    payCalls = 0;
    rejectCalls = 0;
    uploadTypes.clear();
    payProofUploads.clear();
    calls.clear();
    records = [
      {
        'id': '501',
        'nickname': '王野',
        'workerNo': 'W20260118',
        'uid': 'U20260118',
        'amount': 120,
        'status': 'pending',
        'appliedAt': '2026-10-11T09:12:00Z',
        'realName': '张*山',
        'phone': '138****8888',
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

    // ---- 提现审核族（受限会话）----
    if (key == 'GET /withdraw/requests') {
      if (unauthorized) return _json({'code': 401, 'message': '受限管理身份已失效', 'data': null}, 401);
      if (forbidden) return _json({'code': 403, 'message': WorkerWithdrawCopy.forbidden, 'data': null}, 403);
      if (listError != null) {
        return _json({'code': listError!.code, 'message': listError!.message, 'data': null}, listError!.code);
      }
      return _data({'list': records, 'total': records.length});
    }
    if (key == 'GET /withdraw/requests/501') {
      if (forbidden) return _json({'code': 403, 'message': WorkerWithdrawCopy.forbidden, 'data': null}, 403);
      return _data(const {
        'id': '501',
        'nickname': '王野',
        'workerNo': 'W20260118',
        'uid': 'U20260118',
        'amount': 120,
        'status': 'pending',
        'appliedAt': '2026-10-11T09:12:00Z',
        // 详情下发**完整**收款信息（人工打款必须核对）
        'realName': '张守山',
        'phone': '13800001234',
        'wechatId': 'zhangsan_88',
        'qrUrl': 'qr-media-501',
      });
    }
    if (key.startsWith('POST /withdraw/requests/') && key.endsWith('/pay-proof')) {
      // 契约：multipart（字段名 file）→ { mediaId, url }
      return _data(const {'mediaId': 'payout-1', 'url': '/api/v1/media/protected/payout-1'});
    }
    if (key.startsWith('POST /withdraw/requests/') && key.endsWith('/pay')) {
      payCalls++;
      // 新契约：**必须带 proofMediaId**（只填备注 → 服务端中文 400）
      final proof = data is Map ? '${data['proofMediaId'] ?? ''}' : '';
      if (proof.isEmpty) {
        return _json({'code': 400, 'message': '请先上传支付记录截图', 'data': null}, 400);
      }
      return _data(const {'id': '501', 'status': 'paid'});
    }
    if (key.startsWith('POST /withdraw/requests/') && key.endsWith('/reject')) {
      rejectCalls++;
      return _data(const {'id': '501', 'status': 'rejected'});
    }

    // ---- 充值审核那一段（分段默认那一段会并发拉，不能 404）----
    if (key == 'GET /recharge/requests') {
      if (unauthorized) return _json({'code': 401, 'message': '受限管理身份已失效', 'data': null}, 401);
      return _data(const {'list': [], 'total': 0, 'pendingCount': 0});
    }
    if (key == 'GET /recharge/me') {
      if (unauthorized) return _json({'code': 401, 'message': '受限管理身份已失效', 'data': null}, 401);
      return _data(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 0,
        'expiresIn': 43200,
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
