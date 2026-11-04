import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/recharge_page.dart';
import 'package:boss_app/pages/recharge_records_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 充值（入口 + 两步式充值页 + 记录）+ 管理员态（待审核 / 详情 / 发放确认）—— **出图**
///
/// 产出（`apps/boss-app/build/`，共 10 张；按设计审批定案后的几何与版式）：
/// 1. `recharge_1_entry.png`              首页入口（C 套通栏条：44dp / 圆角 6 / 紧贴导航），1.0× 字号
/// 2. `recharge_1b_entry_scale1_3.png`    同一屏 **1.3× 系统字号**（副文案不截断的实拍证据）
/// 3. `recharge_2_step1_amounts.png`      **Step 1 选金额**（10 档 + 自定义 + 「下一步」）
/// 4. `recharge_3_step2_pay.png`          **Step 2 扫码付款**（步骤指示 + 收款码大图 + 应付/可得 + 上传）
/// 5. `recharge_4_submitted.png`          提交成功态（「申请已提交，等待审核」）
/// 6. `recharge_5_records.png`            我的充值记录（待审核 / 已到账 / 已驳回+原因）
/// 7. `recharge_6_identity_admin.png`     身份弹层（打手 / **管理员** 二选一 + 管理员表单）
/// 8. `recharge_7_admin_pending.png`      管理员态待审核列表（28dp 细带「当前身份 · 充值审核」）
/// 9. `recharge_8_review_detail.png`      审核详情（凭证大图 + 申请人 + 金额/到账余额 + 备注）
/// 10. `recharge_9_grant_confirm.png`     发放**二次确认**（给 麻药 发放 ¥68.00 余额）
///
/// ⚠️ 中文字形靠 `FontLoader` 挂系统黑体（`msyh` 放最前），同时挂 `MaterialIcons` ——
/// 与仓库既有出图脚本同一做法（不挂 CJK 会变豆腐块、不挂图标字体会变方块）。
/// 收款码与转账凭证是**真的 PNG**（用 `ImageDiskCache.seed` 预置到磁盘缓存），
/// 否则图位只能出灰块，等于没验收到"图显示得出来"。
void main() {
  const cjk = 'RechargeCJK';
  const pageKey = Key('recharge-page');

  /// 受限会话（管理员态）令牌 —— 与 `enterAdmin()` 写进 AuthStore 的那枚**必须同一个**，
  /// 因为受保护凭证的磁盘缓存键 = URL + 请求头指纹（令牌不同 → 键不同 → 命中不到）。
  const adminTokenValue = 'recharge-token';

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

  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pageKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget stage(Widget page) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          home: page,
        ),
      );

  /// 指定系统字号的舞台（入口副文案的 1.0× / 1.3× 实拍证据）
  Widget stageScaled(Widget page, double scale) => RepaintBoundary(
        key: pageKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: cjk, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF4F6F9)),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: page,
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

  /// 滚动到目标并点它（长表单懒构建：先滚进来，再 ensureVisible 保证**完整可见**在视口内，
  /// 否则点到视口外的坐标上会 "would not hit test"）
  Future<void> scrollToAndTap(WidgetTester tester, Finder f) async {
    final scrollable = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(f, 220, scrollable: scrollable);
    }
    await tester.ensureVisible(f);
    await settle(tester);
    await tester.tap(f);
    await settle(tester);
  }

  /// **只滚不点**（出图 Step 2 下半屏时要停在提交区，不能真提交）
  Future<void> scrollToOnly(WidgetTester tester, Finder f) async {
    final scrollable = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    if (f.evaluate().isEmpty) {
      await tester.scrollUntilVisible(f, 220, scrollable: scrollable);
    }
    await tester.ensureVisible(f);
    await settle(tester);
  }

  /// **让图片真的解码出来**（出图的关键一步）
  ///
  /// `Image.file` / `Image.memory` 的解码是**真异步**，而 `flutter test` 的假时钟不会推进它 ——
  /// 只 `pump` 的话图位永远是占位灰块/转圈（等于没验收到"图能不能显示"）。
  /// 所以必须进 `runAsync` 给真实时间，再 pump 一帧把解码结果画上屏。
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 生成一张**拟真**的收款码（居中二维码方块 + 一行提示）
  Future<Uint8List> qrPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 320.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, size, size), Paint()..color = Colors.white);
    final dark = Paint()..color = const Color(0xFF14202E);
    // 22×22 伪二维码点阵（真实二维码的样子：定位角 + 随机点）
    const n = 22;
    const cell = size / (n + 6);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final on = ((x * 7 + y * 13) % 5 == 0) || ((x * 3 + y * 11) % 7 == 2);
        if (!on) continue;
        canvas.drawRect(Rect.fromLTWH(3 * cell + x * cell, 3 * cell + y * cell, cell * 0.92, cell * 0.92), dark);
      }
    }
    // 三个定位角
    final finder = Paint()..color = const Color(0xFF14202E);
    for (final p in const [Offset(3, 3), Offset(19, 3), Offset(3, 19)]) {
      canvas.drawRect(Rect.fromLTWH(p.dx * cell, p.dy * cell, cell * 4, cell * 4), finder);
      canvas.drawRect(
        Rect.fromLTWH(p.dx * cell + cell * 0.7, p.dy * cell + cell * 0.7, cell * 2.6, cell * 2.6),
        Paint()..color = Colors.white,
      );
      canvas.drawRect(Rect.fromLTWH(p.dx * cell + cell * 1.1, p.dy * cell + cell * 1.1, cell * 1.8, cell * 1.8), finder);
    }
    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  /// 生成一张**拟真的转账凭证截图**（微信账单卡片样式 + 金额 + 时间）
  Future<Uint8List> proofPng(String fontFamily) async {
    const w = 440.0;
    const h = 600.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFEDEDED));

    void text(String s, double x, double y, double size, Color color, {FontWeight weight = FontWeight.w400}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontFamily: fontFamily, fontWeight: weight)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
    }

    // 顶部条
    canvas.drawRect(const Rect.fromLTWH(0, 0, w, 56), Paint()..color = Colors.white);
    text('账单详情', w / 2 - 28, 18, 17, const Color(0xFF14202E), weight: FontWeight.w700);
    // 金额卡
    canvas.drawRect(const Rect.fromLTWH(16, 72, w - 32, 104), Paint()..color = Colors.white);
    text('转账金额', 36, 92, 12, const Color(0xFF4A5A6E));
    text('¥ 68.00', 36, 112, 26, const Color(0xFF14202E), weight: FontWeight.w700);
    text('已收款', w - 110, 118, 13, const Color(0xFF0E7C7B), weight: FontWeight.w600);
    // 明细卡
    canvas.drawRect(const Rect.fromLTWH(16, 190, w - 32, 250), Paint()..color = Colors.white);
    final rows = <List<String>>[
      ['收款方', '祁连山电竞（小云）'],
      ['付款方', '阿远'],
      ['支付方式', '微信零钱'],
      ['转账时间', '2026-10-06 12:31'],
      ['交易单号', '1000050001202610061231'],
    ];
    for (var i = 0; i < rows.length; i++) {
      final y = 212 + i * 46.0;
      text(rows[i][0], 36, y, 13, const Color(0xFF4A5A6E));
      text(rows[i][1], 150, y, 13, const Color(0xFF14202E));
      canvas.drawRect(Rect.fromLTWH(36, y + 30, w - 72, 0.8), Paint()..color = const Color(0xFFE3E8EF));
    }
    text('微信支付', w / 2 - 26, h - 46, 14, const Color(0xFF4A5A6E), weight: FontWeight.w600);
    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  setUp(() {
    AppToast.dismiss();
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
        'level': 3,
        'totalSpent': 1286,
      }),
    );
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  ApiClient api(_Router router) => ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://shot.local'))..httpClientAdapter = router,
      );

  // =====================================================================================
  // 1. 首页（含充值入口）· 1.0× / 1.3× 两档系统字号
  //    【方案 G 2026-10-17】入口从"导航正下方通栏条"改为**三宫格第三格「充值」**
  // =====================================================================================
  testWidgets('出图 1：首页 · 三宫格第三格就是充值入口（投诉客服 / 打赏 / 充值，1.0× 字号）', (tester) async {
    phone(tester);
    await tester.pumpWidget(stage(ServicesPage(api: api(_Router()))));
    await settle(tester);
    expect(find.text('充值'), findsOneWidget);
    expect(find.text('投诉客服'), findsOneWidget);
    expect(find.text('打赏'), findsOneWidget);
    await shoot(tester, 'recharge_1_entry.png');
  });

  testWidgets('出图 1b：同一屏 1.3× 系统字号（三宫格标签仍完整、不溢出）', (tester) async {
    phone(tester);
    await tester.pumpWidget(stageScaled(ServicesPage(api: api(_Router())), 1.3));
    await settle(tester);
    final para = tester.renderObject<RenderParagraph>(find.text('充值'));
    expect(para.didExceedMaxLines, isFalse, reason: '1.3× 下入口标签不得被省略号截断');
    await shoot(tester, 'recharge_1b_entry_scale1_3.png');
  });

  // =====================================================================================
  // 2. 两步式充值页 · Step 1（选金额）
  // =====================================================================================
  testWidgets('出图 2：Step 1 选金额（10 档网格 + 自定义 + 「下一步」）', (tester) async {
    phone(tester);
    final router = _Router();
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr!));
    await tester.pumpWidget(stage(RechargePage(api: api(router))));
    await settle(tester);
    await settleImages(tester);
    expect(find.text('选择充值金额'), findsOneWidget);
    expect(find.text('¥648.00'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('上传付款截图'), findsNothing, reason: 'Step 1 不该有扫码/上传区');
    await shoot(tester, 'recharge_2_step1_amounts.png');
  });

  // =====================================================================================
  // 3. 两步式充值页 · Step 2（扫码付款 + 上传）
  // =====================================================================================
  testWidgets('出图 3：Step 2 扫码付款（步骤指示 + 收款码大图 + 应付/可得）', (tester) async {
    phone(tester);
    final router = _Router();
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr!));
    await tester.pumpWidget(stage(RechargePage(api: api(router))));
    await settle(tester);

    // Step 1 选 68 元 → Step 2
    await tester.tap(find.text('¥68.00'));
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    await settleImages(tester); // 收款码真解码

    expect(find.text('选金额'), findsOneWidget, reason: '步骤指示：第 1 步已完成');
    expect(find.text('应付金额'), findsOneWidget);
    expect(find.text('上传付款截图'), findsOneWidget);
    await shoot(tester, 'recharge_3_step2_pay.png');
  });

  testWidgets('出图 3b：Step 2 下半屏（上传付款截图 + 备注 + 提交 + 上一步 + 记录入口）', (tester) async {
    phone(tester);
    final router = _Router();
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr!));
    final proof = await tester.runAsync(() => proofPng(cjk));
    await tester.pumpWidget(stage(RechargePage(
      api: api(router),
      picker: () async => PickedProof(bytes: proof!, name: 'wx-pay.png'),
      uploader: ({required String type, required List<int> bytes, required String filename, required String token}) async =>
          const MediaUploadResult(id: 'proof-1', mimeType: 'image/png'),
    )));
    await settle(tester);

    await tester.tap(find.text('¥68.00'));
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    // 上传付款截图（必填）→ 备注 → 滚动到提交区出图
    await scrollToAndTap(tester, find.text('选择付款截图'));
    expect(find.text('可以提交了'), findsOneWidget);
    await scrollToAndTap(tester, find.text('备注（选填）'));
    await tester.enterText(find.byKey(const Key('recharge-note')), '微信转账，付款人昵称与账号一致');
    await settle(tester);
    await scrollToOnly(tester, find.text('提交申请'));
    await settleImages(tester); // 本地截图预览也是真异步解码
    expect(find.text(RechargeCopy.submitted), findsNothing, reason: '这只是出图，不提交');
    await shoot(tester, 'recharge_3b_step2_upload.png');
  });

  // =====================================================================================
  // 4. 提交成功态
  // =====================================================================================
  testWidgets('出图 4：提交成功态（申请已提交，等待审核）', (tester) async {
    phone(tester);
    final router = _Router();
    final qr = await tester.runAsync(() => qrPng());
    await tester.runAsync(() => ImageDiskCache.instance.seed(router.qrUrl, qr!));
    final proof = await tester.runAsync(() => proofPng(cjk));
    await tester.pumpWidget(stage(RechargePage(
      api: api(router),
      picker: () async => PickedProof(bytes: proof!, name: 'wx-pay.png'),
      uploader: ({required String type, required List<int> bytes, required String filename, required String token}) async =>
          const MediaUploadResult(id: 'proof-1', mimeType: 'image/png'),
    )));
    await settle(tester);

    await tester.tap(find.text('¥6.00'));
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    await scrollToAndTap(tester, find.text('选择付款截图'));
    expect(find.text('可以提交了'), findsOneWidget);
    await scrollToAndTap(tester, find.text('提交申请'));
    expect(find.text(RechargeCopy.submitted), findsOneWidget);
    await shoot(tester, 'recharge_4_submitted.png');
  });

  // =====================================================================================
  // 5. 我的充值记录
  // =====================================================================================
  testWidgets('出图 5：我的充值记录（待审核 / 已到账 / 已驳回+原因）', (tester) async {
    phone(tester);
    await tester.pumpWidget(stage(RechargeRecordsPage(api: api(_Router()))));
    await settle(tester);
    expect(find.text('已驳回'), findsOneWidget);
    await shoot(tester, 'recharge_5_records.png');
  });

  // =====================================================================================
  // 6. 身份弹层（含管理员）
  // =====================================================================================
  testWidgets('出图 6：身份弹层（我是打手 / 我是管理员）', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: cjk, useMaterial3: true),
      home: RepaintBoundary(
        key: pageKey,
        child: Scaffold(
          backgroundColor: const Color(0xFFF4F6F9),
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 760),
              child: IdentitySwitchSheet(key: UniqueKey(), api: api(_Router())),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('我是管理员'));
    await settle(tester);
    expect(find.text('绑定并切换为管理员'), findsOneWidget);
    await shoot(tester, 'recharge_6_identity_admin.png');
  });

  // =====================================================================================
  // 7–9. 管理员态：待审核列表 / 详情 / 发放二次确认
  // =====================================================================================
  Future<void> enterAdmin() async {
    AuthStore.instance.debugSetIdentity(
      identity: AppIdentity.admin,
      adminToken: adminTokenValue,
      adminMe: RechargeAdminMe.fromJson(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }),
    );
    await AuthStore.instance.switchToAdmin();
  }

  testWidgets('出图 7：管理员态 · 待审核列表（无底栏 + 28dp 身份细带）', (tester) async {
    phone(tester);
    final router = _Router();
    final proof = await tester.runAsync(() => proofPng(cjk));
    await tester.runAsync(
        () => ImageDiskCache.instance.seed(router.proofUrl('9'), proof!, headers: proofImageHeaders(adminTokenValue)));
    await enterAdmin();
    await tester.pumpWidget(stage(RechargeAdminShell(api: api(router))));
    await settle(tester);
    await settleImages(tester);
    expect(find.text('麻药'), findsOneWidget);
    // 凭证缩略图**真的出图**（Image，不是占位/转圈）
    expect(
      find.descendant(of: find.byType(RechargeProofThumb), matching: find.byType(Image)),
      findsWidgets,
      reason: '付款凭证缩略图必须是真图（一直转圈 = 本次要修的 bug）',
    );
    await shoot(tester, 'recharge_7_admin_pending.png');
  });

  /// 假服务器**故意**下发修前那条坏地址（少了 `/api/v1` 前缀的根路径，实测 404）
  /// ——用来证明"App 管理员态不再采用服务端 proofUrl，只走窄通道"。
  /// 若哪天有人把优先级改回去，这个用例立刻红。
  testWidgets('出图 7b：服务端下发坏地址 /media/protected/201 时，凭证仍走窄通道并真出图', (tester) async {
    phone(tester);
    final router = _Router()..brokenProofUrl = true;
    final proof = await tester.runAsync(() => proofPng(cjk));
    await tester.runAsync(
        () => ImageDiskCache.instance.seed(router.proofUrl('9'), proof!, headers: proofImageHeaders(adminTokenValue)));
    await enterAdmin();
    await tester.pumpWidget(stage(RechargeAdminShell(api: api(router))));
    await settle(tester);
    await settleImages(tester);

    // 组件拿到的地址 = 窄通道（不是服务端那条坏地址），且带受限会话令牌
    final imgs = tester
        .widgetList<CachedNetImage>(find.byType(CachedNetImage))
        .where((w) => w.url.contains('/recharge/proof/'))
        .toList();
    expect(imgs, isNotEmpty, reason: '凭证必须走 /recharge/proof/:requestId');
    expect(imgs.first.url, router.proofUrl('9'), reason: '最终地址必须逐字相等（含 /api/v1 前缀）');
    expect(imgs.first.url.contains('/media/protected/'), isFalse);
    expect(imgs.first.headers['Authorization'], 'Bearer $adminTokenValue',
        reason: '受保护凭证必须带受限会话令牌（否则 401 → 永久转圈）');
    expect(find.text('麻药'), findsOneWidget);
    await shoot(tester, 'recharge_7b_admin_pending_broken_url.png');
  });

  testWidgets('出图 8：审核详情（凭证大图）', (tester) async {
    phone(tester);
    final router = _Router();
    final proof = await tester.runAsync(() => proofPng(cjk));
    await tester.runAsync(
        () => ImageDiskCache.instance.seed(router.proofUrl('9'), proof!, headers: proofImageHeaders(adminTokenValue)));
    await enterAdmin();
    await tester.pumpWidget(stage(RechargeAdminShell(api: api(router))));
    await settle(tester);
    await tester.tap(find.text('详情').first);
    await settle(tester);
    await settleImages(tester);
    expect(find.text('审核详情'), findsOneWidget);
    // 详情大图与列表缩略图**同一份口径**：都是 /recharge/proof/9
    final big = tester
        .widgetList<CachedNetImage>(find.descendant(
          of: find.byKey(RechargeReviewDetailPage.proofKey),
          matching: find.byType(CachedNetImage),
        ))
        .toList();
    expect(big, hasLength(1));
    expect(big.single.url, endsWith('/recharge/proof/9'));
    expect(
      find.descendant(of: find.byKey(RechargeReviewDetailPage.proofKey), matching: find.byType(Image)),
      findsWidgets,
      reason: '详情大图必须是真图',
    );
    await shoot(tester, 'recharge_8_review_detail.png');
  });

  testWidgets('出图 9：发放二次确认（给 麻药 发放 ¥68.00 余额）', (tester) async {
    phone(tester);
    final router = _Router();
    final proof = await tester.runAsync(() => proofPng(cjk));
    await tester.runAsync(
        () => ImageDiskCache.instance.seed(router.proofUrl('9'), proof!, headers: proofImageHeaders(adminTokenValue)));
    await enterAdmin();
    await tester.pumpWidget(stage(RechargeAdminShell(api: api(router))));
    await settle(tester);
    await settleImages(tester);
    await tester.tap(find.text('详情').first);
    await settle(tester);
    await settleImages(tester);
    await tester.tap(find.text('发放'));
    await settle(tester);
    expect(find.text('给 麻药 发放 ¥68.00 余额'), findsOneWidget);
    await shoot(tester, 'recharge_9_grant_confirm.png');
  });
}

/// 出图用的假服务器（只喂这几屏要用的字段）
class _Router implements HttpClientAdapter {
  /// true = 待审核列表**故意**回修前那条坏地址（少了 `/api/v1` 的根路径，实测 404），
  /// 用于证明 App 管理员态只认窄通道、不被服务端 proofUrl 带偏（见出图 7b）。
  bool brokenProofUrl = false;

  /// 收款码地址（与页面里 `AppConfig.resolveMediaUrl('/media/public/11')` 同源）
  String get qrUrl => AppConfig.resolveMediaUrl('/media/public/11');

  /// 凭证地址（受限会话窄通道 `/recharge/proof/:requestId`）
  ///
  /// ⚠️ **必须带全局前缀 `/api/v1`**（服务端真实路由）；少写这一段的旧值是
  /// 2026-10-07「付款凭证图一直转圈」的根因 —— 出图用例的假服务器与页面**同源**，
  /// 两边一起错就会一直出绿（所以这里只能有一种写法）。
  String proofUrl(String requestId) => AppConfig.resolveMediaUrl('/api/v1/recharge/proof/$requestId');

  /// 待审列表下发的 `proofUrl`（修好后与服务端一致；brokenProofUrl 时给历史坏值）
  String get _emittedProofUrl => brokenProofUrl ? '/media/protected/201' : '/api/v1/media/protected/201';

  /// `GET /recharge/requests` 的行（补上凭证字段：url + 媒体 id）
  List<Map<String, dynamic>> get _pendingRows =>
      _pending.map((r) => <String, dynamic>{...r, 'proofUrl': _emittedProofUrl, 'voucherMediaId': r['proofMediaId']}).toList();

  static final List<Map<String, dynamic>> _pending = [
    {
      'id': '9',
      'nickname': '麻药',
      'uid': 'U8471209365',
      'amountYuan': 68,
      'points': 68,
      'proofMediaId': 'proof-9',
      'note': '微信转账，付款人昵称与账号一致',
      'createdAt': '2026-10-06T12:34:00Z',
      'status': 'pending',
    },
    {
      'id': '10',
      'nickname': '雪山',
      'uid': 'U10086',
      'amountYuan': 128,
      'points': 128,
      'proofMediaId': 'proof-10',
      'createdAt': '2026-10-06T12:51:00Z',
      'status': 'pending',
    },
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

    if (key == 'GET /public/recharge/config') {
      return _body(envelope(const {
        'amountOptions': [6, 10, 20, 38, 68, 98, 128, 198, 328, 648],
        'customEnabled': true,
        'minYuan': 6,
        'maxYuan': 10000,
        'pointsPerYuan': 10,
        'pendingLimitPerUser': 3,
        'noticeText': '付款后请上传截图并提交申请；客服核对收款记录后发放余额，请勿重复提交。',
        'qrCodes': [
          {'id': '11', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/11'},
          {'id': '12', 'channel': 'alipay', 'label': '支付宝收款码', 'url': '/media/public/12'},
        ],
      }));
    }
    if (key == 'GET /user/recharge/requests') {
      return _body(envelope({
        'list': [
          {
            'id': '1',
            'amountYuan': 68,
            'points': 68,
            'status': 'pending',
            'createdAt': '2026-10-06T12:34:00Z',
            'note': '微信转账',
          },
          {
            'id': '2',
            'amountYuan': 198,
            'points': 198,
            'status': 'granted',
            'createdAt': '2026-10-05T20:12:00Z',
            'grantedAt': '2026-10-05T20:31:00Z',
          },
          {
            'id': '3',
            'amountYuan': 38,
            'points': 38,
            'status': 'rejected',
            'rejectReason': '没查到这笔转账，请核对收款方后重新提交',
            'createdAt': '2026-10-04T09:02:00Z',
          },
        ],
        'total': 3,
        'pendingCount': 1,
        'pendingLimitPerUser': 3,
      }));
    }
    if (key == 'GET /recharge/requests') {
      return _body(envelope({'list': _pendingRows, 'total': 2, 'pendingCount': 2}));
    }
    if (key == 'GET /recharge/me') {
      return _body(envelope(const {
        'admin': {'id': '7', 'nickname': '周砚', 'username': 'recharge_zhou'},
        'pendingCount': 2,
        'expiresIn': 43200,
      }));
    }
    // 首页四件套
    if (key == 'GET /public/clubs') {
      return _body(envelope(const [
        {
          'id': '1',
          'name': '祁连山电竞 · 和平精英分部',
          'subTitle': '和平精英分部',
          'description': '手游全段位上分与护航；客服 9:00-次日 2:00 在线',
          'coverMediaId': null,
          'badge': '官方',
          'rating': '4.9',
          'orderCount': 2847,
          'divisionId': '1',
        }
      ]));
    }
    if (key == 'GET /public/site') {
      return _body(envelope(const {'clubTitle': '和平精英分部', 'clubParagraphs': ['手游全段位上分与护航；客服 9:00-次日 2:00 在线']}));
    }
    if (key == 'GET /public/banners') return _body(envelope(const []));
    if (key == 'GET /divisions/grouped') {
      return _body(envelope([
        {
          'gameId': '35',
          'gameName': '和平精英',
          'platformCount': 1,
          'divisions': [
            {
              'id': '1',
              'code': 'peace_mobile',
              'gameName': '和平精英',
              'platform': 'mobile',
              'platformLabel': '手游',
              'name': '和平精英 · 手游',
              'shortName': '和平精英',
              'onlineDesc': '平均 3 分钟内接单',
              'themeColor': '#16A34A',
              'onlineCount': 12,
            }
          ],
        },
        {
          'gameId': '36',
          'gameName': '三角洲行动',
          'platformCount': 2,
          'divisions': [
            {
              'id': '2',
              'code': 'delta_mobile',
              'gameName': '三角洲行动',
              'platform': 'mobile',
              'platformLabel': '手游',
              'name': '三角洲行动 · 手游',
              'shortName': '三角洲行动',
              'onlineDesc': '平均 5 分钟内接单',
              'themeColor': '#2563EB',
              'onlineCount': 8,
            },
            {
              'id': '3',
              'code': 'delta_pc',
              'gameName': '三角洲行动',
              'platform': 'pc',
              'platformLabel': '端游',
              'name': '三角洲行动 · 端游',
              'shortName': '三角洲行动',
              'onlineDesc': '平均 6 分钟内接单',
              'themeColor': '#7C3AED',
              'onlineCount': 4,
            },
          ],
        },
      ]));
    }
    if (key == 'GET /user/identity') {
      return _body(envelope(const {'bound': false, 'activeCount': 0, 'maxPerBoss': 1, 'bindings': []}));
    }
    return _body(envelope(const {'list': [], 'total': 0}));
  }

  ResponseBody _body(Object body) => ResponseBody.fromString(
        body is String ? body : jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
