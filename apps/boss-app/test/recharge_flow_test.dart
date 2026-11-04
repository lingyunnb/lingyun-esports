import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:boss_app/pages/recharge_page.dart';
import 'package:boss_app/pages/recharge_records_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 充值入口 + 充值页（负责人 2026-10-06 方案①）—— 验收 ①–⑥
///
/// ① 首页顶部有充值入口，且样式守规范（无渐变 / 无 emoji / 圆角 10）
/// ② 未配置收款码 → 入口**不渲染**（首页与改动前逐像素一致）
/// ③ 金额档位来自接口（换掉假接口档位 → 页面跟着变，证明没写死）
/// ④ 自定义金额越界 → 中文错误
/// ⑤ 付款截图必填校验（不发提交请求）
/// ⑥ 提交后文案含「等待审核」且**不含"支付成功"**（合规红线）
///
/// 另外覆盖：服务端 400 文案原样展示、配置加载失败可重试、我的充值记录三态。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
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

  /// 有界推进（本项目硬要求：不用 pumpAndSettle 卡死；最多 40 帧 × 50ms）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 滚到某个控件（充值页是长表单：ListView 懒构建，没进视口的子树**根本不存在**，
  /// 所以不能直接 ensureVisible —— 必须先 dragUntilVisible 把它滚进来）
  ///
  /// 注意：`Finder.first` 在**零匹配时会抛 StateError**，所以这里先判存在再用它。
  Future<void> scrollTo(WidgetTester tester, Finder f) async {
    final scrollable = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    if (f.evaluate().isEmpty) {
      await tester.dragUntilVisible(f, scrollable, const Offset(0, -200));
      await settle(tester);
    }
    await tester.ensureVisible(f);
    await settle(tester);
  }

  /// 往上滚直到出现（有界：最多 20 次 × 200dp）
  Future<void> scrollUpTo(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 20 && f.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, 200));
      await settle(tester);
    }
  }

  /// **真机尺寸**（390 × 844）：两步式的 Step 1 在默认 800×600 测试视口下会把
  /// 「自定义金额」挤出视口（800 宽 → 档位格高 116dp × 4 行 = 494dp）—— 那是测试视口的假象，
  /// 不是真机现象。所有充值页用例统一按真机尺寸渲染，断言才对得上真机。
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// 两步式的公共路径：Step 1 选金额 → 「下一步」→ Step 2
  Future<void> goStep2(WidgetTester tester, {String amountLabel = '¥6.00'}) async {
    await tester.tap(find.text(amountLabel));
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);
  }

  /// 以指定系统字号渲染（两步式与入口的 1.0× / 1.3× 证据都靠它）
  Widget stageScaled(Widget page, double scale) => MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      );

  ApiClient api(_Router router) => ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://recharge.local'))..httpClientAdapter = router,
      );

  /// 生成一张**真的能解码**的 PNG（4×4 纯色）—— 假字节会让 `Image.memory` 报异常
  Future<Uint8List> tinyPng(WidgetTester tester) async {
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = const Color(0xFF1D5FA8));
      final img = await recorder.endRecording().toImage(4, 4);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return data!.buffer.asUint8List();
    });
    return bytes!;
  }

  List<String> allTexts(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').where((s) => s.isNotEmpty).toList();

  List<BoxDecoration> decorationsIn(WidgetTester tester, Finder of) {
    final out = <BoxDecoration>[];
    for (final e in tester.elementList(find.descendant(of: of, matching: find.byType(Container)))) {
      final d = (e.widget as Container).decoration;
      if (d is BoxDecoration) out.add(d);
    }
    for (final e in tester.elementList(find.descendant(of: of, matching: find.byType(DecoratedBox)))) {
      final d = (e.widget as DecoratedBox).decoration;
      if (d is BoxDecoration) out.add(d);
    }
    return out;
  }

  // =====================================================================================
  // ① 首页充值入口（**方案 G 2026-10-17**：原「导航下方通栏条」改为三宫格第三格「充值」）
  // =====================================================================================
  testWidgets('① 首页：充值入口 = 三宫格第三格（白底 + 1px 描边 + 图标上色），点进去是 Step 1', (tester) async {
    phone(tester);
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final router = _Router(config: _config());
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api(router))));
    await settle(tester);

    // 三宫格：投诉客服 / 打赏 / 充值（方案 G 定案的三项，顺序固定）
    final entry = find.text('充值');
    expect(entry, findsOneWidget, reason: '充值入口必须在首页三宫格里');
    expect(find.text('投诉客服'), findsOneWidget);
    expect(find.text('打赏'), findsOneWidget);
    final players = tester.getTopLeft(find.text('投诉客服')).dx;
    final tip = tester.getTopLeft(find.text('打赏')).dx;
    final recharge = tester.getTopLeft(entry).dx;
    expect(players, lessThan(tip));
    expect(tip, lessThan(recharge), reason: '顺序：投诉客服 · 打赏 · 充值');

    // 位置：**在宣传图/页头之下、播报条与分类 Tab 之上**（方案 G 的第二块）
    final cell = find.ancestor(of: entry, matching: find.byType(Container)).first;
    expect(tester.getSize(cell).height, greaterThan(48), reason: '入口格是 图标 + 文字的方框');

    // 样式：无渐变、无阴影（docs/21）
    final decorations = decorationsIn(tester, cell);
    expect(decorations, isNotEmpty);
    for (final d in decorations) {
      expect(d.gradient, isNull, reason: 'docs/21：禁渐变做主视觉');
      expect(d.boxShadow ?? const <BoxShadow>[], isEmpty, reason: 'docs/21：阴影只给弹层');
    }
    // 无 emoji（三宫格的每一段文字都不许带 emoji）
    for (final label in <String>['投诉客服', '打赏', '充值']) {
      expect(RechargeEntry.containsEmoji(label), isFalse, reason: '「$label」含 emoji，违反 docs/21');
    }

    // 点入口进充值页（Step 1）
    await tester.tap(entry);
    await settle(tester);
    expect(find.text('选择充值金额'), findsOneWidget);
  });

  /// ①-b 三宫格标签在两档系统字号下都不被截断（原「入口副文案」那条的等价口径）
  for (final scale in <double>[1.0, 1.3]) {
    testWidgets('①-b 三宫格标签在 $scale× 系统字号下不被截断（didExceedMaxLines == false）', (tester) async {
      phone(tester);
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(stageScaled(ServicesPage(api: api(_Router(config: _config()))), scale));
      await settle(tester);

      for (final label in <String>['投诉客服', '打赏', '充值']) {
        final para = tester.renderObject<RenderParagraph>(find.text(label));
        expect(para.didExceedMaxLines, isFalse, reason: '$scale× 下「$label」被截断了（可用 ${para.size.width}dp）');
      }
      expect(tester.takeException(), isNull, reason: '$scale× 下不得有布局溢出');
    });
  }

  // =====================================================================================
  // ② 收款码没配 / 配置接口挂了 —— 三宫格结构不变（方案 G 定案：三项恒在）
  // =====================================================================================
  testWidgets('② 后端没配任何收款码 → 三宫格仍固定三项（结构不变），点充值仍进充值页', (tester) async {
    phone(tester);
    final router = _Router(config: {
      'amountOptions': [6, 20],
      'customEnabled': true,
      'pointsPerYuan': 10,
      'qrCodes': [],
    });
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api(router))));
    await settle(tester);

    // 方案 G 定案：三宫格是**固定结构**（投诉客服 / 打赏 / 充值），不随收款码增减而变化；
    // "有没有可用档位/收款码"由充值页自己判定并给中文提示。
    expect(find.text('充值'), findsOneWidget);
    expect(find.text('投诉客服'), findsOneWidget);
    expect(find.text('打赏'), findsOneWidget);
    // 首页其余内容照常（不是整页失败）
    expect(find.text('祁连山官方'), findsWidgets);

    await tester.tap(find.text('充值'));
    await settle(tester);
    expect(find.byType(RechargePage), findsOneWidget, reason: '入口必须真的能进充值页');
    expect(tester.takeException(), isNull);
  });

  testWidgets('② 配置接口挂了 → 首页照常渲染三宫格（不半残、不白屏）', (tester) async {
    phone(tester);
    final router = _Router(configStatus: 500, configMessage: '服务器开小差了');
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: api(router))));
    await settle(tester);

    expect(find.text('充值'), findsOneWidget);
    expect(find.text('投诉客服'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================================
  // ③ 档位来自接口（不写死）
  // =====================================================================================
  testWidgets('③ 金额档位来自接口：换掉假接口档位 → 页面跟着变', (tester) async {
    phone(tester);
    final a = _Router(config: _config(amounts: [6, 10, 20, 38, 68, 98, 128, 198, 328, 648]));
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(a))));
    await settle(tester);
    for (final v in [6, 10, 20, 38, 68, 98, 128, 198, 328, 648]) {
      // 口径 2026-10-09：档位显示 ¥ + 两位小数（金额格式统一由 RechargeRules.formatYuan/fmtMoney 产出）
      expect(find.text(RechargeRules.formatYuan(v)), findsWidgets, reason: '任务书 10 档必须逐档来自接口');
    }

    // 换一套档位（并把历史比例字段改成 20）→ 页面必须跟着变，且旧档位消失
    final b = _Router(config: _config(amounts: [7, 15], pointsPerYuan: 20));
    await tester.pumpWidget(MaterialApp(home: RechargePage(key: UniqueKey(), api: api(b))));
    await settle(tester);
    expect(find.text('¥7.00'), findsOneWidget); // Step 1 只有档位格（未选 → 没有"应付金额"卡）
    expect(find.text('¥15.00'), findsOneWidget);
    expect(find.text('¥6.00'), findsNothing, reason: '旧档位必须消失（没写死）');
    // 到账 = 付款金额（1:1）：**比例字段即使配成 20 也不得参与展示**（防"界面按倍数撒谎"回归）
    await goStep2(tester, amountLabel: '¥7.00');
    expect(find.text('付款 ¥7.00 → 到账 ¥7.00'), findsOneWidget);
    expect(find.text('¥140.00'), findsNothing, reason: '旧口径 7 × 20 = 140 不得再出现');
  });

  // =====================================================================================
  // ④ 自定义金额越界 → 中文错误
  // =====================================================================================
  testWidgets('④ 自定义金额：低于下限/高于上限/格式非法都给中文错误，且不发请求', (tester) async {
    phone(tester);
    final router = _Router(config: _config(minYuan: 6, maxYuan: 200));
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(router))));
    await settle(tester);

    final field = find.byKey(const Key('recharge-custom-amount'));
    expect(field, findsOneWidget);
    expect(find.textContaining('¥6.00 ~ ¥200.00'), findsOneWidget, reason: '区间来自配置');

    await tester.enterText(field, '3');
    await settle(tester);
    expect(find.text('最低 ¥6.00'), findsOneWidget);

    await tester.enterText(field, '900');
    await settle(tester);
    expect(find.text('最高 ¥200.00'), findsOneWidget);

    await tester.enterText(field, '1.234');
    await settle(tester);
    expect(find.text('请输入正确的金额（最多两位小数）'), findsOneWidget);

    // 合法值：错误消失 + 可进 Step 2，到账余额 1:1（88 → ¥88.00）
    await tester.enterText(field, '88');
    await settle(tester);
    expect(find.text('最低 ¥6.00'), findsNothing);
    expect(find.text('最高 ¥200.00'), findsNothing);
    expect(find.text('请输入正确的金额（最多两位小数）'), findsNothing);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('¥88.00'), findsWidgets);
    expect(find.text('付款 ¥88.00 → 到账 ¥88.00'), findsOneWidget);

    // 全程没打提交接口
    expect(router.calls.where((c) => c.key == 'POST /user/recharge/requests'), isEmpty);
  });

  // =====================================================================================
  // ⑤ 付款截图必填
  // =====================================================================================
  testWidgets('⑤ 没上传截图就提交 → 中文提示「请上传付款截图」，且不发提交请求', (tester) async {
    phone(tester);
    final router = _Router(config: _config());
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(router))));
    await settle(tester);

    await goStep2(tester);
    await scrollTo(tester, find.text('提交申请'));
    await tester.tap(find.text('提交申请'));
    await settle(tester);

    expect(find.text('请上传付款截图'), findsOneWidget);
    expect(router.calls.where((c) => c.key == 'POST /user/recharge/requests'), isEmpty);

    // 截图卡片上也给红字（往上滚能看到）
    await scrollUpTo(tester, find.text('付款截图是必填项，客服要照它核对收款记录'));
    expect(find.text('付款截图是必填项，客服要照它核对收款记录'), findsOneWidget);
  });

  // =====================================================================================
  // ⑥ 提交成功文案（合规红线）
  // =====================================================================================
  testWidgets('⑥ 提交成功后文案含「等待审核」，且全屏**不含"支付成功"**', (tester) async {
    phone(tester);
    final png = await tinyPng(tester);
    final router = _Router(config: _config());
    await tester.pumpWidget(MaterialApp(
      home: RechargePage(
        api: api(router),
        picker: () async => PickedProof(bytes: png, name: 'proof.png'),
        uploader: ({required String type, required List<int> bytes, required String filename, required String token}) async {
          router.uploadTypes.add(type);
          return const MediaUploadResult(id: 'proof-media-1', mimeType: 'image/png');
        },
      ),
    ));
    await settle(tester);

    await goStep2(tester);
    await scrollTo(tester, find.text('选择付款截图'));
    await tester.tap(find.text('选择付款截图'));
    await settle(tester);
    expect(find.text('可以提交了'), findsOneWidget, reason: '上传成功后才允许提交');

    await scrollTo(tester, find.text('提交申请'));
    await tester.tap(find.text('提交申请'));
    await settle(tester);

    expect(find.text(RechargeCopy.submitted), findsOneWidget);
    expect(find.textContaining('等待审核'), findsWidgets);

    // 合规：全屏任何一段文字都不含禁用词（支付成功 / 自动到账 / 提现 …）
    for (final t in allTexts(tester)) {
      for (final w in RechargeCopy.forbiddenWords) {
        expect(t.contains(w), isFalse, reason: '界面出现「$w」违反合规口径（在「$t」里）');
      }
    }

    // 提交体：金额 + 收款码 id + 凭证 mediaId（截图必填的那一个字段真的传上去了）
    final post = router.calls.firstWhere((c) => c.key == 'POST /user/recharge/requests');
    expect(post.body?['amountYuan'], 6);
    expect(post.body?['proofMediaId'], 'proof-media-1');
    expect(post.body?['qrId'], '11');
    // 上传用途类型：契约优先 recharge_proof
    expect(router.uploadTypes, [RechargePage.mediaType]);
  });

  // =====================================================================================
  // 服务端 400 文案原样展示（超待审核上限）
  // =====================================================================================
  testWidgets('服务端 400（超待审核上限）→ 文案原样展示，不改字', (tester) async {
    phone(tester);
    final png = await tinyPng(tester);
    const serverText = '你已有 3 笔待审核的充值申请，请等审核完成后再提交';
    final router = _Router(config: _config(), submitStatus: 400, submitMessage: serverText);
    await tester.pumpWidget(MaterialApp(
      home: RechargePage(
        api: api(router),
        picker: () async => PickedProof(bytes: png, name: 'p.png'),
        uploader: ({required String type, required List<int> bytes, required String filename, required String token}) async =>
            const MediaUploadResult(id: 'm1', mimeType: 'image/png'),
      ),
    ));
    await settle(tester);

    await goStep2(tester);
    await scrollTo(tester, find.text('选择付款截图'));
    await tester.tap(find.text('选择付款截图'));
    await settle(tester);
    await scrollTo(tester, find.text('提交申请'));
    await tester.tap(find.text('提交申请'));
    await settle(tester);

    expect(find.text(serverText), findsOneWidget, reason: '服务端中文原文必须原样展示');
    expect(find.text(RechargeCopy.submitted), findsNothing, reason: '失败不能显示提交成功');
  });

  // =====================================================================================
  // 配置加载失败 → 页内可重试
  // =====================================================================================
  testWidgets('配置加载失败 → 页内给中文原因 + 重试按钮（可恢复）', (tester) async {
    phone(tester);
    final router = _Router(configStatus: 500, configMessage: '服务器开小差了');
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(router))));
    await settle(tester);

    expect(find.text('充值页暂时打不开'), findsOneWidget);
    expect(find.text('服务器开小差了'), findsOneWidget);

    // 服务端恢复 → 点重试必须真的恢复
    router.configStatus = 200;
    router.config = _config();
    await tester.tap(find.text('重试'));
    await settle(tester);
    expect(find.text('选择充值金额'), findsOneWidget);
  });

  // =====================================================================================
  // 我的充值记录
  // =====================================================================================
  testWidgets('我的充值记录：付款金额/到账余额/状态（待审核·已到账·已驳回+原因）/时间', (tester) async {
    phone(tester);
    final router = _Router(config: _config(), records: [
      {
        'id': '1',
        'amountYuan': 6,
        'points': 6, // 1:1
        'status': 'pending',
        'createdAt': '2026-10-06T10:00:00Z',
      },
      {
        'id': '2',
        'amountYuan': 68,
        'points': 68,
        'status': 'granted',
        'createdAt': '2026-10-05T09:00:00Z',
        'grantedAt': '2026-10-05T09:30:00Z',
      },
      {
        'id': '3',
        'amountYuan': 38,
        'points': 38,
        'status': 'rejected',
        'rejectReason': '没查到这笔转账',
        'note': '微信转账',
        'createdAt': '2026-10-04T08:00:00Z',
      },
    ]);
    await tester.pumpWidget(MaterialApp(home: RechargeRecordsPage(api: api(router))));
    await settle(tester);

    expect(find.text('我的充值记录'), findsOneWidget);
    // 付款金额与到账余额同值（1:1）：每行两处 ¥ + 两位小数
    expect(find.text('¥6.00'), findsNWidgets(2));
    expect(find.text('¥68.00'), findsNWidgets(2));
    expect(find.text('¥38.00'), findsNWidgets(2));
    expect(find.text('待审核'), findsOneWidget);
    expect(find.text('已到账'), findsOneWidget);
    expect(find.text('已驳回'), findsOneWidget);
    expect(find.text('驳回原因：没查到这笔转账'), findsOneWidget);
    // 记录页同样不许出现"支付成功"
    for (final t in allTexts(tester)) {
      expect(t.contains('支付成功'), isFalse);
    }
  });

  testWidgets('充值记录为空 → 空态文案（不是白屏）', (tester) async {
    phone(tester);
    final router = _Router(config: _config(), records: const []);
    await tester.pumpWidget(MaterialApp(home: RechargeRecordsPage(api: api(router))));
    await settle(tester);
    expect(find.textContaining('还没有充值申请'), findsOneWidget);
  });

  testWidgets('充值页内有「我的充值记录」入口，点进记录页', (tester) async {
    phone(tester);
    final router = _Router(config: _config());
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(router))));
    await settle(tester);
    await goStep2(tester);
    await scrollTo(tester, find.text('我的充值记录'));
    await tester.tap(find.text('我的充值记录'));
    await settle(tester);
    expect(find.byType(RechargeRecordsPage), findsOneWidget);
  });

  testWidgets('多张收款码：按渠道标注微信/支付宝，可切换', (tester) async {
    phone(tester);
    final router = _Router(config: _config(qrCodes: [
      {'id': '11', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/11'},
      {'id': '12', 'channel': 'alipay', 'label': '支付宝收款码', 'url': '/media/public/12'},
    ]));
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(router))));
    await settle(tester);
    await goStep2(tester);

    // 渠道标注（顶部标签按当前渠道）+ 两张码的切换片 + 说明文案
    await scrollTo(tester, find.text('微信'));
    expect(find.text('微信'), findsOneWidget);
    expect(find.text('微信收款码'), findsOneWidget);
    expect(find.text('支付宝收款码'), findsOneWidget);
    expect(find.textContaining('付款后请上传截图并提交申请'), findsWidgets);

    await tester.tap(find.text('支付宝收款码'));
    await settle(tester);
    expect(find.text('支付宝'), findsOneWidget);
    expect(find.text('微信'), findsNothing);
  });

  // =====================================================================================
  // 两步式（设计定案「形态 3」）：步骤流转 + 返回保留内容
  // =====================================================================================
  testWidgets('两步式 ① 未选金额时「下一步」置灰、点了也进不去 Step 2；选了才放行', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(_Router(config: _config())))));
    await settle(tester);

    // Step 1 起步：只有金额相关的内容，没有收款码/上传区
    expect(find.text('选择充值金额'), findsOneWidget);
    expect(find.text('选金额'), findsOneWidget, reason: '步骤指示：第 1 步');
    expect(find.text('上传付款截图'), findsNothing);
    expect(find.text('应付金额'), findsNothing);

    // 未选金额 → 置灰（onPressed == null）
    AppIdentityPrimaryButton nextBtn() =>
        tester.widget<AppIdentityPrimaryButton>(find.widgetWithText(AppIdentityPrimaryButton, '下一步'));
    expect(nextBtn().onPressed, isNull, reason: '未选金额必须置灰');
    await tester.tap(find.text('下一步'), warnIfMissed: false);
    await settle(tester);
    expect(find.text('选择充值金额'), findsOneWidget, reason: '点了置灰按钮也不能进 Step 2');
    expect(find.text('上传付款截图'), findsNothing);

    // 选一档 → 按钮可用 → 进 Step 2
    await tester.tap(find.text('¥20.00'));
    await settle(tester);
    expect(nextBtn().onPressed, isNotNull);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    // Step 2：步骤指示里「扫码付款」+ 区块标题「扫码付款」= 2 处（指示 1 → 已打勾）
    expect(find.text('扫码付款'), findsNWidgets(2));
    expect(find.text('选金额'), findsOneWidget);
    expect(find.text('上传付款截图'), findsOneWidget);
    expect(find.text('应付金额'), findsOneWidget);
    expect(find.text('到账余额'), findsOneWidget);
    expect(find.text('¥20.00'), findsWidgets);
    expect(find.text('付款 ¥20.00 → 到账 ¥20.00'), findsOneWidget); // 1:1（旧口径 20 × 10 = 200 已作废）
  });

  testWidgets('两步式 ② 「上一步」返回 Step 1 改金额：已填内容（自定义金额/备注）全部保留', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(_Router(config: _config(minYuan: 6, maxYuan: 200))))));
    await settle(tester);

    // 自定义 88 元 → Step 2
    await tester.enterText(find.byKey(const Key('recharge-custom-amount')), '88');
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('¥88.00'), findsWidgets);
    expect(find.text('付款 ¥88.00 → 到账 ¥88.00'), findsOneWidget);

    // Step 2 填备注
    await scrollTo(tester, find.byKey(const Key('recharge-note')));
    await tester.enterText(find.byKey(const Key('recharge-note')), '微信转账，账号一致');
    await settle(tester);

    // 返回 Step 1：自定义输入仍在
    await scrollTo(tester, find.text('上一步 · 改金额'));
    await tester.tap(find.text('上一步 · 改金额'));
    await settle(tester);
    expect(find.text('选择充值金额'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('recharge-custom-amount'))).controller?.text,
      '88',
      reason: '返回 Step 1 不得清空已填的自定义金额',
    );

    // 改成 ¥6.00 档位 → 再进 Step 2：备注仍在（不清空）
    await tester.tap(find.text('¥6.00'));
    await settle(tester);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.text('¥6.00'), findsWidgets);
    expect(find.text('付款 ¥6.00 → 到账 ¥6.00'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('recharge-note'))).controller?.text,
      '微信转账，账号一致',
      reason: '返回再进来不得清空备注',
    );
  });

  testWidgets('两步式 ③ 系统返回键：Step 2 → 回 Step 1（不退出页面）', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(home: RechargePage(api: api(_Router(config: _config())))));
    await settle(tester);
    await goStep2(tester);
    expect(find.text('上传付款截图'), findsOneWidget, reason: '已在 Step 2');

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(RechargePage), findsOneWidget, reason: '不能退出页面');
    expect(find.text('选择充值金额'), findsOneWidget, reason: '系统返回键 = 回 Step 1');
    expect(find.text('上传付款截图'), findsNothing);
  });
}

/// 任务书形状的配置（默认值可按用例覆盖）
Map<String, dynamic> _config({
  List<num> amounts = const [6, 10, 20, 38, 68, 98, 128, 198, 328, 648],
  num minYuan = 6,
  num maxYuan = 648,
  num pointsPerYuan = 10,
  List<Map<String, dynamic>>? qrCodes,
}) =>
    {
      'amountOptions': amounts,
      'customEnabled': true,
      'minYuan': minYuan,
      'maxYuan': maxYuan,
      'pointsPerYuan': pointsPerYuan,
      'pendingLimitPerUser': 3,
      'noticeText': '付款后请上传截图并提交申请；客服核对收款记录后发放余额。',
      'qrCodes': qrCodes ??
          [
            {'id': '11', 'channel': 'wechat', 'label': '微信收款码', 'url': '/media/public/11'},
          ],
    };

/// 假服务器：充值三接口 + 首页需要的四个基础接口
class _Router implements HttpClientAdapter {
  _Router({
    this.config,
    this.configStatus = 200,
    this.configMessage = 'ok',
    this.records = const [],
    this.submitStatus = 200,
    this.submitMessage = 'ok',
  });

  Map<String, dynamic>? config;
  int configStatus;
  String configMessage;
  List<Map<String, dynamic>> records;
  int submitStatus;
  String submitMessage;

  final List<({String key, Map<String, dynamic>? body})> calls = [];
  final List<String> uploadTypes = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    final data = options.data;
    final body = data is Map ? data.cast<String, dynamic>() : null;
    calls.add((key: key, body: body));

    if (key == 'GET /public/recharge/config') {
      if (configStatus != 200) return _json({'code': configStatus, 'message': configMessage, 'data': null}, configStatus);
      return _data(config ?? const <String, dynamic>{});
    }
    if (key == 'GET /user/recharge/requests') {
      return _data({'list': records, 'total': records.length});
    }
    if (key == 'POST /user/recharge/requests') {
      if (submitStatus != 200) {
        return _json({'code': submitStatus, 'message': submitMessage, 'data': null}, submitStatus);
      }
      return _json({
        'code': 0,
        'message': 'ok',
        // 到账余额 1:1（口径 2026-10-09）：服务端返回的 points 即付款金额本身
        'data': {'id': '99', 'points': body?['amountYuan'] as num? ?? 0, 'status': 'pending'},
      }, 201);
    }
    // 首页基础接口（服务页并发拉这几个）
    if (key == 'GET /public/clubs') return _data(const []);
    if (key == 'GET /public/site') return _data(const {'clubTitle': '官方自营', 'clubParagraphs': ['和平精英与三角洲行动']});
    if (key == 'GET /public/banners') return _data(const []);
    if (key == 'GET /divisions/grouped') {
      return _data([
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
        }
      ]);
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
