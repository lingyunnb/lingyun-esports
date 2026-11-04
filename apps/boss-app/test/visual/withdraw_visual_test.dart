import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打手提现（打手态三页 + 管理员态提现审核）—— **验收出图 8 张**
///
/// 产出（`apps/boss-app/build/withdraw/`）：
/// 1. `withdraw_1_worker_mine.png`        打手态「我的」含「我的收益 / 提现」入口
/// 2. `withdraw_2_need_bind.png`          未绑定 → 提现页引导绑定（★「提现前需先绑定收款信息」+「去绑定」）
/// 3. `withdraw_3_bind_form.png`          收款信息绑定页（姓名/电话/微信号 + **收款码上传位**）
/// 4. `withdraw_4_amount_insufficient.png` 提现页 **「余额不足」态**（金额当场校验）
/// 5. `withdraw_5_records.png`            提现记录三状态（处理中 / 已打款 / 已驳回 + 时间/原因）
/// 6. `withdraw_6_admin_list.png`         管理员态「提现审核」列表（与「充值审核」并列的分段）
/// 7. `withdraw_7_admin_detail.png`       审核详情（**收款码大图** + 完整收款信息 + 打款记录区）
/// 8. `withdraw_8_pay_confirm.png`        打款**二次确认**弹窗（含"确认后将标记为已打款，此操作不可撤销"）
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体，同时挂 `MaterialIcons`（与仓库既有出图脚本同一做法：
/// 不挂 CJK 会变豆腐块、不挂图标字体会变方块）。
/// 收款码是**真的 PNG**（`ImageDiskCache.seed` 预置到磁盘缓存）—— 否则图位只能出灰块，
/// 等于没验收到"收款码大图显示得出来"。受保护图（收款码/打款凭证）的缓存键 = URL + 令牌指纹，
/// 所以 seed 用的令牌必须与 `AuthStore` 里那枚**逐字相同**。
void main() {
  const cjk = 'WithdrawCJK';
  const pageKey = Key('withdraw-page');

  /// 受限会话（管理员态）令牌（与 `enterAdmin()` 写入 AuthStore 的必须同一个）
  const adminToken = 'recharge-token';

  /// 打手态伴随令牌
  const companionToken = 'companion-token';

  const realName = '张守山';
  const realPhone = '13800001234';
  const realWechat = 'zhangsan_88';

  late _VisualRouter router;

  ApiClient api() => ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://wd-visual.local'))..httpClientAdapter = router);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjk)..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final iconPath in const [
      'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
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

  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pageKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build/withdraw').createSync(recursive: true);
      File('build/withdraw/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// 舞台：`IdentityWorkerMinePage` 这类"页头 + 滚动体"的页面**不自带 Scaffold**
  /// （真机上它挂在 `IdentityWorkerShell` 的 Scaffold 里）→ 这里补一层，
  /// 否则页内既有的 `InkWell` 会因缺 Material 祖先直接报错、出图全废。
  Widget stage(Widget page) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: page is Scaffold ? page : Scaffold(body: page),
        ),
      );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 让图片**真的解码出屏**（假时钟推不动真异步解码；见充值出图脚本同一注记）
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 生成一张**拟真**的微信收款码（居中二维码点阵 + 三个定位角 + 一行"微信支付"字样）
  Future<Uint8List> qrPng() async {    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 360.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
    final dark = Paint()..color = const Color(0xFF14202E);
    const n = 24;
    const cell = size / (n + 10);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final on = ((x * 7 + y * 13) % 5 == 0) || ((x * 3 + y * 11) % 7 == 2);
        if (!on) continue;
        canvas.drawRect(Rect.fromLTWH(5 * cell + x * cell, 5 * cell + y * cell, cell * 0.9, cell * 0.9), dark);
      }
    }
    for (final p in const [Offset(5, 5), Offset(21, 5), Offset(5, 21)]) {
      canvas.drawRect(Rect.fromLTWH(p.dx * cell, p.dy * cell, cell * 4, cell * 4), dark);
      canvas.drawRect(
        Rect.fromLTWH(p.dx * cell + cell * 0.7, p.dy * cell + cell * 0.7, cell * 2.6, cell * 2.6),
        Paint()..color = Colors.white,
      );
      canvas.drawRect(Rect.fromLTWH(p.dx * cell + cell * 1.1, p.dy * cell + cell * 1.1, cell * 1.8, cell * 1.8), dark);
    }
    // 底部一行拟真提示（微信收款码的样子）
    final tp = TextPainter(
      text: TextSpan(
        text: '微信支付 · 收款码',
        style: TextStyle(fontSize: 15, color: const Color(0xFF576B95), fontFamily: cjk),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, size - 30));
    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  /// 生成一张**拟真的微信转账成功截图**（打款凭证要长这样：金额/时间/收款方）
  Future<Uint8List> payoutPng() async {
    const w = 420.0;
    const h = 560.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFEDEDED));
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, 96), Paint()..color = const Color(0xFF07C160));
    void text(String s, double x, double y, double size, Color c, {FontWeight weight = FontWeight.w400}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, color: c, fontFamily: cjk, fontWeight: weight)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
    }

    text('转账成功', 24, 34, 22, Colors.white, weight: FontWeight.w700);
    canvas.drawRect(const Rect.fromLTWH(20, 120, w - 40, 300), Paint()..color = Colors.white);
    text('转账金额', 40, 146, 14, const Color(0xFF888888));
    text('¥120.00', 40, 172, 30, const Color(0xFF14202E), weight: FontWeight.w700);
    canvas.drawRect(const Rect.fromLTWH(40, 228, w - 80, 1), Paint()..color = const Color(0xFFE5E5E5));
    text('收款方', 40, 246, 14, const Color(0xFF888888));
    text('张守山', 150, 246, 15, const Color(0xFF14202E));
    text('收款微信号', 40, 284, 14, const Color(0xFF888888));
    text(realWechat, 150, 284, 15, const Color(0xFF14202E));
    text('转账时间', 40, 322, 14, const Color(0xFF888888));
    text('2026-10-11 10:38', 150, 322, 15, const Color(0xFF14202E));
    text('转账单号', 40, 360, 14, const Color(0xFF888888));
    text('1000050001202610110038', 150, 360, 13, const Color(0xFF14202E));
    text('微信支付', 24, 448, 14, const Color(0xFF888888));
    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  setUp(() {
    router = _VisualRouter();
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://wd-visual.local'))..httpClientAdapter = router;
    ApiCache.instance.clear();
    WithdrawRefreshNotifier.instance.debugReset();
    AuthStore.instance.debugClearIdentity();
  });

  tearDown(() {
    AppToast.dismiss();
    WithdrawMedia.reset();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  void enterWorker() {
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
    AuthStore.instance.debugSetIdentity(identity: AppIdentity.worker, companionToken: companionToken);
  }

  void enterAdmin() {
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
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.admin,
      adminToken: adminToken,
      adminMe: RechargeAdminMe.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }),
    );
  }

  // =====================================================================================
  // 1 打手态「我的」含提现入口
  // =====================================================================================
  testWidgets('出图 1：打手态「我的」（含「我的收益 / 提现」入口）', (tester) async {
    enterWorker();
    phone(tester);
    // 恢复打手资料（工号/昵称/分部权限）
    await tester.runAsync(() async {
      await AuthStore.instance.fetchWorkerMe(api: api()).catchError((_) => AuthStore.instance.workerMe!);
    });
    await tester.pumpWidget(stage(const IdentityWorkerMinePage(api: null)));
    await settle(tester);
    expect(find.byKey(WorkerWithdrawEntry.entryKey), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.entryTitle), findsWidgets);
    await shoot(tester, 'withdraw_1_worker_mine.png');
  });

  // =====================================================================================
  // 2 未绑定 → 引导绑定
  // =====================================================================================
  testWidgets('出图 2：未绑定 → 提现页显著提示「提现前需先绑定收款信息」+「去绑定」', (tester) async {
    enterWorker();
    router.bound = false;
    phone(tester);
    await tester.pumpWidget(stage(WorkerWithdrawPage(api: api())));
    await settle(tester);
    expect(find.text(WorkerWithdrawCopy.needBind), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.goBind), findsWidgets);
    await shoot(tester, 'withdraw_2_need_bind.png');
  });

  // =====================================================================================
  // 3 绑定页（含收款码上传位）
  // =====================================================================================
  testWidgets('出图 3：收款信息绑定页（姓名/电话/微信号 + 收款码上传位）', (tester) async {
    enterWorker();
    phone(tester);
    await tester.pumpWidget(stage(WorkerWithdrawAccountPage(api: api())));
    await settle(tester);
    // 填一部分（拟真：真实用户在填表中）
    await tester.enterText(find.byKey(const Key('withdraw-real-name')), realName);
    await tester.enterText(find.byKey(const Key('withdraw-phone')), realPhone);
    await settle(tester);
    expect(find.byKey(WorkerWithdrawAccountPage.qrTileKey), findsOneWidget);
    await shoot(tester, 'withdraw_3_bind_form.png');
  });

  // =====================================================================================
  // 4 提现页「余额不足」态
  // =====================================================================================
  testWidgets('出图 4：提现页「余额不足」态（余额 ¥320.50，想提 ¥500.00）', (tester) async {
    enterWorker();
    phone(tester);
    await tester.pumpWidget(stage(WorkerWithdrawPage(api: api())));
    await settle(tester);
    await tester.enterText(find.byKey(WorkerWithdrawPage.amountKey), '500');
    await settle(tester);
    final msg = WorkerWithdrawCopy.errInsufficient(320.5);
    expect(find.text(msg), findsOneWidget, reason: '必须出「余额不足」那一句');
    await shoot(tester, 'withdraw_4_amount_insufficient.png');
  });

  // =====================================================================================
  // 5 提现记录三状态
  // =====================================================================================
  testWidgets('出图 5：提现记录三状态（处理中 / 已打款 / 已驳回）', (tester) async {
    enterWorker();
    phone(tester);
    await tester.pumpWidget(stage(WorkerWithdrawRecordsPage(api: api())));
    await settle(tester);
    for (final s in const [
      WorkerWithdrawCopy.statusPending,
      WorkerWithdrawCopy.statusPaid,
      WorkerWithdrawCopy.statusRejected,
    ]) {
      expect(find.text(s), findsOneWidget);
    }
    await shoot(tester, 'withdraw_5_records.png');
  });

  // =====================================================================================
  // 6 管理员态提现审核列表
  // =====================================================================================
  testWidgets('出图 6：管理员态「提现审核」列表（与「充值审核」并列的分段）', (tester) async {
    enterAdmin();
    phone(tester);
    final qr = await tester.runAsync(() => qrPng());
    // 列表行的收款码缩略图走**受保护通道**：缓存键 = URL（含申请 id）+ 令牌指纹
    // → 两行各 seed 一次（不 seed 的那行只会出"图加载失败"的红块，等于没验收到图位）
    for (final id in const ['501', '502']) {
      await tester.runAsync(() => ImageDiskCache.instance.seed(
            resolveWithdrawProof('qr-media-$id', requestId: id, kind: 'qr'),
            qr!,
            headers: withdrawImageHeaders(adminToken),
          ));
    }
    await tester.pumpWidget(stage(RechargeAdminShell(api: api())));
    await settle(tester);
    await tester.tap(find.text(RechargeAdminShell.tabLabels[RechargeAdminShell.tabWithdraw]));
    await settle(tester);
    await settleImages(tester);
    expect(find.text('王野'), findsOneWidget);
    // 列表行直接给**完整**收款信息（负责人 2026-10-11）：姓名 · 电话 · 微信号
    expect(find.text('张守山 · 13800001234 · zhangsan_88'), findsOneWidget,
        reason: '列表行必须显示完整收款信息（不再只有收款码缩略图与工号）');
    expect(find.textContaining('138****8888'), findsNothing, reason: '列表不许再出现打码手机号');
    await shoot(tester, 'withdraw_6_admin_list.png');
  });

  // =====================================================================================
  // 7 管理员态审核详情（收款码大图 + 打款记录区）
  // =====================================================================================
  testWidgets('出图 7：审核详情（收款码大图 + 完整收款信息 + 打款记录区）', (tester) async {
    enterAdmin();
    phone(tester);
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(
          resolveWithdrawProof('qr-media-501', requestId: '501', kind: 'qr'),
          qr!,
          headers: withdrawImageHeaders(adminToken),
        ));
    await tester.pumpWidget(stage(WithdrawReviewDetailPage(
      request: WorkerWithdrawRequest.fromJson(router.records.first),
      api: api(),
    )));
    await settle(tester);
    await settleImages(tester);
    // 滚到收款码大图 + 打款记录区
    await tester.drag(find.byType(ListView).first, const Offset(0, -520));
    await settle(tester);
    await settleImages(tester);
    expect(find.byKey(WithdrawReviewDetailPage.qrKey), findsOneWidget);
    expect(find.text('打款记录'), findsOneWidget);
    await shoot(tester, 'withdraw_7_admin_detail.png');
  });

  // =====================================================================================
  // 8 打款二次确认弹窗
  // =====================================================================================
  testWidgets('出图 8：打款二次确认弹窗（含「确认后将标记为已打款，此操作不可撤销」）', (tester) async {
    enterAdmin();
    phone(tester);
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(
          resolveWithdrawProof('qr-media-501', requestId: '501', kind: 'qr'),
          qr!,
          headers: withdrawImageHeaders(adminToken),
        ));
    // 本地预览位要真的解出一张图（`Image.memory` 拿随便几个字节会抛 "Invalid image data"）
    final payout = await tester.runAsync(() => payoutPng());
    await tester.pumpWidget(stage(WithdrawReviewDetailPage(
      request: WorkerWithdrawRequest.fromJson(router.records.first),
      api: api(),
      picker: () async => PickedWithdrawImage(bytes: payout!, name: 'payout.png'),
      uploader: ({required requestId, required bytes, required filename, required token}) async =>
          const MediaUploadResult(id: 'payout-501', mimeType: 'image/png'),
    )));
    await settle(tester);
    // 上传凭证（让「已提现」可用）→ 打开二次确认
    await tester.drag(find.byType(ListView).first, const Offset(0, -520));
    await settle(tester);
    await tester.tap(find.text('选择截图'));
    await settle(tester);
    await tester.tap(find.byKey(WithdrawReviewDetailPage.payKey));
    await settle(tester);

    expect(find.text('打款确认'), findsOneWidget);
    expect(find.text(WorkerWithdrawCopy.payConfirmWarning), findsOneWidget);

    // 打款凭证也会被显示（已打款态）——缓存键同样要预置（这次 seed 过，无需再下）
    await settleImages(tester);
    await shoot(tester, 'withdraw_8_pay_confirm.png');
  });
}

/// 出图用的假服务器（打手端 + 管理员端提现族接口；数据拟真：非整数、长短不一）
class _VisualRouter implements HttpClientAdapter {
  bool bound = true;

  List<Map<String, dynamic>> records = [
    {
      'id': '501',
      'workerNickname': '王野',
      'workerNo': 'W20260118',
      'uid': 'U20260118',
      'amount': 120,
      'amountYuan': 120,
      'status': 'pending',
      'appliedAt': '2026-10-11T09:12:00Z',
      // 列表下发**完整**收款信息（2026-10-11 起；`accountMasked` 同时保留做兼容/回退）
      'account': {'realName': '张守山', 'phone': '13800001234', 'wechatId': 'zhangsan_88'},
      'accountMasked': {'realName': '张*山', 'phone': '138****8888', 'wechatId': 'zha***88'},
      'hasAccount': true,
    },
    {
      'id': '502',
      'workerNickname': '雪山飞狐',
      'workerNo': 'W20260302',
      'uid': 'U20260302',
      'amount': 68.5,
      'amountYuan': 68.5,
      'status': 'pending',
      'appliedAt': '2026-10-11T08:40:00Z',
      'account': {'realName': '李墨白', 'phone': '13902223344', 'wechatId': 'xue_2233'},
      'accountMasked': {'realName': '李*', 'phone': '139****2233', 'wechatId': 'xue***02'},
      'hasAccount': true,
    },
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.path}';

    // ---- 提现审核（管理员态）----
    if (key == 'GET /withdraw/requests') {
      return _data({'list': records, 'total': records.length, 'pendingTotal': records.length});
    }
    if (key == 'GET /withdraw/requests/501') {
      return _data(const {
        'id': '501',
        'workerNickname': '王野',
        'workerNo': 'W20260118',
        'uid': 'U20260118',
        'amount': 120,
        'status': 'pending',
        'appliedAt': '2026-10-11T09:12:00Z',
        'account': {
          'realName': '张守山',
          'phone': '13800001234',
          'wechatId': 'zhangsan_88',
          'qrMediaId': 'qr-media-501',
          'qrUrl': '/api/v1/media/protected/qr-media-501',
        },
      });
    }
    if (key == 'GET /recharge/requests') return _data(const {'list': [], 'total': 0, 'pendingCount': 0});
    if (key == 'GET /recharge/me') {
      return _data(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 0,
        'expiresIn': 43200,
      });
    }

    // ---- 打手端提现 ----
    if (key == 'GET /worker/withdraw/account') {
      if (!bound) return _data(const {'bound': false, 'realName': '', 'phone': '', 'wechatId': '', 'qrUrl': null});
      return _data(const {
        'bound': true,
        'realName': '张*山',
        'phone': '138****8888',
        'wechatId': 'zhangsan_88',
        'qrUrl': '/api/v1/media/protected/qr-media-501',
        'updatedAt': '2026-10-08T10:00:00Z',
      });
    }
    if (key == 'GET /worker/withdraw/config') {
      return _data(const {
        'minAmount': 10,
        'maxAmount': 2000,
        'dailyLimit': 1,
        'feeRate': 0,
        'noticeText': '提现会在 1 个工作日内处理；打款前请确认收款信息无误，'
            '换绑只影响后续打款。',
        'balance': 320.5,
        'todayUsed': 0,
      });
    }
    if (key == 'GET /worker/withdraw/requests') {
      return _data({
        'list': [
          {
            'id': '601',
            'amount': 120,
            'status': 'pending',
            'appliedAt': '2026-10-11T09:12:00Z',
          },
          {
            'id': '602',
            'amount': 68.5,
            'status': 'paid',
            'appliedAt': '2026-10-10T20:31:00Z',
            'paidAt': '2026-10-11T10:38:00Z',
          },
          {
            'id': '603',
            'amount': 300,
            'status': 'rejected',
            'appliedAt': '2026-10-09T11:20:00Z',
            'rejectedAt': '2026-10-09T15:02:00Z',
            'rejectReason': '收款信息与本人不一致，请重新绑定后再提交',
          },
        ],
        'total': 3,
        'pendingCount': 1,
        'balance': 200.5,
      });
    }

    // ---- 打手态最小底座 ----
    if (key == 'GET /worker/my-wallet') {
      return _data(const {
        'balance': 320.5,
        'totalIncome': 1860.5,
        'settlementCount': 24,
        'tipIncome': 66,
        'totalGranted': 100,
      });
    }
    if (key == 'GET /worker/me') {
      return _data(const {
        'workerNo': 'W20260118',
        'nickname': '王野',
        'canTakeOrder': true,
        'canServeCustomer': false,
        'divisionPermissions': [
          {'divisionId': '1', 'divisionName': '和平精英 · 手游', 'canTakeOrder': true},
        ],
      });
    }
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
    if (key == 'GET /user/identity') {
      return _data(const {'bound': true, 'activeCount': 1, 'maxPerBoss': 1, 'bindings': []});
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
