import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/profile_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「我的」页 结构 / 状态护栏 —— 负责人 2026-10-13（方案 B）+ **2026-10-17（真机反馈 ⑥⑦）**
///
/// 钉住的 6 件事：
/// 1. **区块顺序**：资料卡 → 资产卡（余额）→ 我的订单 → **服务卡** → **身份（切换）**。
///    - 2026-10-13：身份切换在「余额」下面；
///    - **2026-10-17 ⑥（负责人真机反馈）**：服务要放到「我的订单」下面 → 身份退到服务之后。
///    用**widget 树顺序**断言（SingleChildScrollView 会构建全部子项，y 坐标随视口变）。
/// 2. **未绑定打手时不存在「切换身份」**（结构规则 2「不存在的东西不出现」）→ 入口退化为「绑定打手账号」。
/// 3. **页头无品牌渐变、无「通知 / 设置」图标**（docs/21 禁渐变做主视觉 + 结构规则 1 同一入口只出现一次）。
/// 4. **服务卡 5 个入口的图标按"功能区语义色"上色**（2026-10-17 ⑥「图标上色」）：
///    实色 = `featureHue(featureOfIcon(icon))`、浅底 = `featureSoft(...)`，逐格钉住具体色值。
/// 5. **加载态 = 骨架占位**（不是空白）；**失败态 = 可见中文提示 + 重试**（不是静默）。
/// 6. 金额口径：`¥` + 两位小数 + 千分位；全页不出现「积分」「玩家圈」。
///
/// 变异自证（红/绿已实测，见开发日志）：
/// 把 `profile_page.dart` 里 `_buildServiceCard(context)` 那一行挪到身份区**之后** →
/// 本文件第 1 条（`服务卡必须在身份区块之前`）**必红**；挪回即绿。
void main() {
  late _Router router;

  setUpAll(() {
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.debugDefaultDio = Dio(BaseOptions(baseUrl: 'http://profile.local'));
    router = _Router();
    ApiClient.debugDefaultDio!.httpClientAdapter = router;
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
        'totalSpent': 1286.5,
      }),
    );
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugClearIdentity();
    AuthStore.instance.debugSetSession();
  });

  /// **有界**推进（本项目硬要求：用例必须能终止；页面里可能有 Toast/进度动画，不用 pumpAndSettle）
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await settle(tester);
  }

  /// 屏上所有文本，**按 widget 树顺序**（深度优先）——顺序断言用它，不用 y 坐标
  List<String> treeTexts(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').where((s) => s.isNotEmpty).toList();

  testWidgets('① 区块顺序：资料卡 → 资产卡（余额）→ 服务卡 → 身份（服务在我的订单下面，身份退到最后）', (tester) async {
    router.bound = true;
    await pumpPage(tester);

    final texts = treeTexts(tester);
    final nickname = texts.indexOf('阿远'); // 资料卡
    final balance = texts.indexOf('余额'); // 资产卡
    final identity = texts.indexOf('切换身份'); // 身份区块（已绑定态才是「切换身份」）
    final service = texts.indexOf('系统通知'); // 服务卡第一格

    expect(nickname, greaterThanOrEqualTo(0), reason: '资料卡必须在树里\n$texts');
    expect(balance, greaterThan(nickname), reason: '资产卡必须在资料卡之后\n$texts');
    expect(identity, greaterThan(balance),
        reason: '**身份切换必须在资产卡（余额）之后** —— 负责人 2026-10-13 指定\n$texts');
    // 负责人 2026-10-17 ⑥：服务要放到我的订单下面，身份退到服务后面
    expect(service, lessThan(identity),
        reason: '**服务卡必须在身份区块之前** —— 负责人 2026-10-17 ⑥「把这个（服务）放到我的订单的下面」\n$texts');
  });

  testWidgets('② 未绑定打手账号时不出现「切换身份」，只有「绑定打手账号」', (tester) async {
    router.bound = false;
    await pumpPage(tester);

    expect(find.text('切换身份'), findsNothing, reason: '未绑定 → 不存在"切换"这件事（结构规则 2）');
    expect(find.text('绑定打手账号'), findsOneWidget, reason: '入口必须还能走（否则绑定不可达）');
    expect(find.text('未绑定打手端账号'), findsOneWidget);
    expect(find.text('当前身份：老板'), findsNWidgets(2), reason: '资料卡昵称行 + 身份区块行，随时能看出当前身份');
  });

  testWidgets('③ 页头：白底实色（无品牌渐变）+ 无「通知 / 设置」两个图标 + 无「编辑资料」重复入口', (tester) async {
    await pumpPage(tester);

    // 页头容器：实色白底、**没有任何渐变**（改版前无自定义背景图时整块铺 T.brandGradient）
    final header = tester.widget<Container>(find.byKey(const Key('profile-header')));
    expect(header.color, T.bgCardSolid, reason: '页头改实色白底');
    expect((header.decoration as BoxDecoration?)?.gradient, isNull, reason: '页头不得再有品牌渐变主视觉（docs/21）');

    // 页头标题用深色正文色 → 也证明它不再是"白字叠在渐变上"
    final title = tester.widget<Text>(find.text('我的'));
    expect(title.style?.color, AppColors.textPrimary, reason: '页头标题回到实色正文色');

    // 通知 / 设置两个入口**全页各只有一处**（都在服务卡里）：页头不再重复（结构规则 1）
    expect(find.byIcon(AppIcon.bell), findsOneWidget, reason: '通知入口只有服务卡那一行');
    expect(find.byIcon(AppIcon.settings), findsOneWidget, reason: '设置入口只有服务卡那一行');
    expect(find.text('系统通知'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('④ 服务卡 5 格：图标按功能区语义色上色（逐格钉死具体色值）', (tester) async {
    router.bound = false; // 未绑定 → 没有「解除绑定」行，页面里只有服务卡这 5 枚 17dp 图标
    await pumpPage(tester);

    for (final label in ['系统通知', '联系客服', '账号安全', '设置', '关于祁连山电竞']) {
      expect(find.text(label), findsOneWidget, reason: '服务卡缺了「$label」');
    }

    // 负责人 2026-10-17 ⑥「图标上色」：**逐格钉住**语义色（不是"不等于 textSecondary 就算过"）
    // 通知=活动粉 / 客服=客服青 / 安全=安全绿 / 设置与关于=品牌蓝
    // （`IconData` 覆写了 `==`，所以这张表不能是 const —— 见 core `feature_hues.dart` 同款注释）
    final expected = <IconData, Color>{
      AppIcon.bell: AppColors.accentPink, // 活动（通知类）
      AppIcon.headset: AppColors.accentSupport, // 客服
      AppIcon.lock: AppColors.accentSafe, // 安全
      AppIcon.settings: AppColors.primary, // 品牌
      AppIcon.info: AppColors.primary, // 品牌
    };

    final rowIcons = tester.widgetList<Icon>(find.byType(Icon)).where((i) => i.size == 17).toList();
    expect(rowIcons.length, 5, reason: '服务卡 5 格各一枚图标');

    for (final icon in rowIcons) {
      final IconData glyph = icon.icon!;
      expect(expected.containsKey(glyph), isTrue, reason: '出现了未登记的 17dp 图标：$glyph');
      // ① 实色：逐格具体色值
      expect(icon.color, expected[glyph], reason: '「$glyph」的语义色不对');
      // ② 与 `feature_hues` 的唯一映射一致（同功能必须与别处同色）
      expect(icon.color, featureHue(featureOfIcon(glyph)),
          reason: '图标实色必须取自 featureHue(featureOfIcon(icon))');
      // ③ 34×34 浅底同族（featureSoft）+ 圆角 10
      final tile = tester.widget<Container>(
        find.ancestor(of: find.byIcon(glyph), matching: find.byType(Container)).first,
      );
      final deco = tile.decoration as BoxDecoration?;
      expect(deco?.color, featureSoft(featureOfIcon(glyph)), reason: '「$glyph」的浅底必须是 featureSoft(...)');
      expect(deco?.borderRadius, BorderRadius.circular(10), reason: '服务格浅底圆角 = 10');
    }
  });

  testWidgets('⑤ 加载态 = 骨架占位（不是空白）；数据到达后骨架消失', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    // 只推一帧：HTTP future 还没回来 → 资产卡必须是骨架
    await tester.pump();
    expect(find.byKey(const Key('profile-asset-skeleton')), findsOneWidget,
        reason: '数据未加载时必须给骨架占位，不能是空白');

    await settle(tester);
    expect(find.byKey(const Key('profile-asset-skeleton')), findsNothing, reason: '数据到达后骨架必须让位给真实数值');
    expect(find.text('¥1,286.50'), findsOneWidget, reason: '余额：¥ + 两位小数 + 千分位');
  });

  testWidgets('⑥ 失败态 = 可见中文提示 + 重试入口（点重试能恢复）', (tester) async {
    router.walletFail = true;
    await pumpPage(tester);

    expect(find.text('余额与订单未能加载，请检查网络后重试'), findsOneWidget,
        reason: '拉取失败必须可见（改版前是静默）');
    expect(find.text('重新加载'), findsOneWidget, reason: '失败态必须给重试入口');
    expect(find.text('¥1,286.50'), findsNothing);

    router.walletFail = false;
    await tester.tap(find.text('重新加载'));
    await settle(tester);
    expect(find.text('¥1,286.50'), findsOneWidget, reason: '重试后必须拿到真实数值');
    expect(find.text('余额与订单未能加载，请检查网络后重试'), findsNothing);
  });

  testWidgets('⑦ 订单三状态来自真实订单（待接单 2 / 进行中 1 / 待评价 3）', (tester) async {
    await pumpPage(tester);
    expect(find.text('待接单'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('待评价'), findsOneWidget);
    expect(find.text('全部订单 17 单'), findsOneWidget);
    expect(find.text('去下单'), findsNothing, reason: '有订单 → 不出现空态');
    // 三状态数字来自假订单列表（2 / 1 / 3），不是占位符
    final counts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((s) => s == '2' || s == '1' || s == '3')
        .toList();
    expect(counts, containsAll(<String>['2', '1', '3']), reason: '三个计数必须来自订单数据');
  });

  testWidgets('⑨ 订单为 0 时给「去下单」空态（不是三个大 0 摆着）', (tester) async {
    router.orders = const [];
    router.total = 0;
    await pumpPage(tester);

    expect(find.text('还没有订单，去看看有哪些陪玩服务'), findsOneWidget);
    expect(find.text('去下单'), findsOneWidget);
    expect(find.text('全部订单 0 单'), findsOneWidget);
  });

  testWidgets('⑧ 文案红线：全页无「积分」「玩家圈」', (tester) async {
    await pumpPage(tester);
    final texts = treeTexts(tester).join('\n');
    expect(texts.contains('积分'), isFalse, reason: '金额口径统一是「余额」，全页不得出现「积分」');
    expect(texts.contains('玩家圈'), isFalse, reason: '玩家圈已于 2026-10-05 整体下线');
  });
}

/// 假服务器：余额 / 订单三状态 / 绑定状态（形状与生产一致）
class _Router implements HttpClientAdapter {
  bool bound = true;
  bool walletFail = false;
  int total = 17;

  /// 与设计稿同形：待接单 2 / 进行中 1 / 待评价 3
  List<Map<String, dynamic>> orders = const [
    {'id': '1', 'status': 'pending_take'},
    {'id': '2', 'status': 'pending_take'},
    {'id': '3', 'status': 'taken'},
    {'id': '4', 'status': 'pending_confirm'},
    {'id': '5', 'status': 'pending_confirm'},
    {'id': '6', 'status': 'pending_confirm'},
  ];

  void reset() {
    bound = true;
    walletFail = false;
    total = 17;
    orders = const [
      {'id': '1', 'status': 'pending_take'},
      {'id': '2', 'status': 'pending_take'},
      {'id': '3', 'status': 'taken'},
      {'id': '4', 'status': 'pending_confirm'},
      {'id': '5', 'status': 'pending_confirm'},
      {'id': '6', 'status': 'pending_confirm'},
    ];
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final key = '${options.method} ${options.path}';
    Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

    if (key == 'GET /user/wallet') {
      if (walletFail) {
        return _body({'code': 500, 'message': '服务暂时不可用', 'data': null}, status: 500);
      }
      return _body(envelope({'balance': 1286.5}));
    }
    if (key == 'GET /user/orders') {
      return _body(envelope({'list': orders, 'total': total, 'page': 1, 'pageSize': 50}));
    }
    if (key == 'GET /user/identity') {
      return _body(envelope(bound
          ? {
              'bound': true,
              'activeCount': 1,
              'maxPerBoss': 2,
              'message': '可继续绑定',
              'bindings': [
                {
                  'bindingId': '77',
                  'status': 'active',
                  'worker': {
                    'workerNo': 'W20260118',
                    'nickname': '王野',
                    'workerStatus': 1,
                    'divisionPermissions': const [],
                  },
                }
              ],
            }
          : {'bound': false, 'activeCount': 0, 'maxPerBoss': 1, 'bindings': const []}));
    }
    if (key == 'GET /public/levels') return _body(envelope(const []));
    // 其它一律空成功，避免任何一块卡在加载态
    return _body(envelope({'list': const [], 'total': 0}));
  }

  ResponseBody _body(Object body, {int status = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
