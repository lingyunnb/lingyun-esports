import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_detail_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品详情页 v2 **方案 B 极简克制** 契约测试（负责人 2026-10-05）
///
/// 设计稿 `site/design/product-detail-v2/b-restrained.html`；
/// 本文件按负责人给的 7 条验收点逐条覆盖：
///
/// | # | 验收点 | 用例 |
/// |---|---|---|
/// | ① | 列表**整卡**点击 → 详情页；右下「下单」**也**进详情页（负责人 2026-10-05 复报：点下单也要弹到详情页） | 第 1、2、3 个 |
/// | ② | 无封面 → 空态渲染（非空白、含下一步动作） | 第 3 个 |
/// | ③ | 三列显示**真实字段**且不出现「库存 / 日产能」 | 第 4 个 |
/// | ④ | 提示条文案**取自接口**（假接口 24 → 48，页面跟着变） | 第 5 个 |
/// | ⑤ | 下单须知**默认折叠**、点开展开 | 第 6、7 个 |
/// | ⑥ | 「立即购买」→ push 确认订单页（带正确商品） | 第 8 个 |
/// | ⑦ | 徽标「董事长推荐」与每周限购提示仍在 | 第 9、10 个 |
void main() {
  setUp(() {
    // 关缓存：`/public/products` 挂 45s SWR 列表档缓存，用例间会互相串味
    // （实测踩过：第 1 个用例的成功详情被第 3 个用例命中，于是"加载失败"根本不发生）
    ApiClient.cacheEnabled = false;
    ApiCache.instance.clear();
    // 限购提示要带 token 才拉（未登录不显示）—— 本组用例默认已登录
    AuthStore.instance.debugSetSession(accessToken: 'detail-test-token');
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    AuthStore.instance.debugSetSession();
  });

  /// 真机尺寸画布（390×844，与设计稿 `.phone` 内容区一致）
  ///
  /// 为什么必须设：`flutter test` 默认画布 800×600 —— 详情页第一屏根本放不下
  /// 「下单须知」（实测它在 y≈753，远超 600），于是 `tester.tap` 会点在**屏幕外**：
  /// 状态不会变，断言以"找不到『收起』"这种误导性理由失败（排查花了不少时间）。
  /// 包装一层 `testWidgets` 而不是每个用例手写：少写 11 次、也不可能漏写。
  void phoneTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      tester.view.physicalSize = const Size(390 * 2, 844 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await body(tester);
    });
  }

  // ---------------- ① 列表整卡 / 右下「下单」都进详情页；只有「立即购买」进确认订单页 ----------------

  phoneTest('① 商品列表：整卡点击进详情页（不再是"点商品直接进确认订单页"）', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: api.client, initialDivisionId: '1')));
    await tester.pumpAndSettle();

    // 列表里有商品，且右下「下单」按钮在
    expect(find.text('9.9新人体验单保200w不卡保底'), findsWidgets);
    expect(find.text('下单'), findsWidgets, reason: '右下「下单」按钮保持不变');
    // 按钮尺寸/颜色/位置零回归：点「下单」前后都在同一处（视觉断言见 product_detail_v2_visual_test）
    expect(find.text('立即购买'), findsNothing, reason: '列表页本身没有「立即购买」（那是详情页底栏的）');

    // 点**商品名**（卡片内容区，不是「下单」按钮）→ 进详情页
    await tester.tap(find.text('9.9新人体验单保200w不卡保底').first);
    await tester.pumpAndSettle();

    expect(find.byType(ProductDetailPage), findsOneWidget, reason: '整卡点击必须进商品详情页');
    expect(find.byType(OrderCreatePage), findsNothing, reason: '点商品不该再直达确认订单页');
    expect(find.text('立即购买'), findsOneWidget);
  });

  phoneTest('① 商品列表：右下「下单」按钮也进详情页（负责人 2026-10-05 复报「点下单也要弹到图二页面」）', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: api.client, initialDivisionId: '1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下单').first);
    await tester.pumpAndSettle();

    expect(find.byType(ProductDetailPage), findsOneWidget, reason: '「下单」按钮必须进商品详情页（与整卡同一条路）');
    expect(find.byType(OrderCreatePage), findsNothing, reason: '「下单」按钮**不再**直达确认订单页，购买流程统一走详情页「立即购买」');
    expect(find.text('立即购买'), findsOneWidget, reason: '落到的是详情页（底栏有「立即购买」）');
    // 详情页显示的是点的那件商品（不是列表里其它商品、也不是空白详情）
    expect(find.text('9.9新人体验单保200w不卡保底'), findsWidgets, reason: '详情页标题 = 点的那件商品');
    expect(find.text('董事长推荐'), findsOneWidget, reason: '详情页的徽标来自详情接口，说明真的按 id 回源了');
  });

  phoneTest('① 参数完整性：整卡与「下单」按钮带下去的三项入参完全一致（id/name/coverUrl 逐值相等）', (tester) async {
    /// 从**新的一页**列表出发，点指定热区 → 返回落到详情页的那个 widget
    /// （每次重开一页：两条入口各自是真实用户路径，而不是"接着上一条状态往下点"）
    Future<ProductDetailPage> openVia(String where) async {
      final api = _FakeApi();
      await tester.pumpWidget(MaterialApp(home: ProductListPage(api: api.client, initialDivisionId: '1')));
      await tester.pumpAndSettle();
      await tester.tap(where == 'button' ? find.text('下单').first : find.text('9.9新人体验单保200w不卡保底').first);
      await tester.pumpAndSettle();
      return tester.widget<ProductDetailPage>(find.byType(ProductDetailPage));
    }

    final fromButton = await openVia('button');
    final fromCard = await openVia('card');

    // 两处调用 `_openDetail(p)` 传的是同一个 `_Product` → 三项入参必须逐值相等。
    // 这就是"参数完整性"的机器断言：以后谁只给其中一条入口加字段（或漏字段），这里立刻挂。
    expect(fromButton.productId, fromCard.productId, reason: '商品 id 必须一致（详情页回源全靠它）');
    expect(fromButton.initialName, fromCard.initialName, reason: '加载态商品名必须一致（且是完整 name，不是列表短名）');
    expect(fromButton.initialCoverUrl, fromCard.initialCoverUrl, reason: '加载态封面必须一致');
    // 且确实是那件商品（不是默认值/空值）
    expect(fromButton.productId, '137');
    expect(fromButton.initialName, '9.9新人体验单保200w不卡保底');
    // 详情页的权威展示值一律回源详情接口（fixture 里 price=99 → 画面 99，走的是详情那一跳）
    expect(find.text('¥99.00'), findsOneWidget, reason: '价格来自详情接口 /public/products/137（¥ + 两位小数）');
  });

  // ---------------- ② 无封面 → 空态 ----------------

  phoneTest('② 无封面图：渲染空态（虚线位 + 说明 + 下一步动作），不是空白', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    // 空态主图位：标题 + 说明（设计稿 Z2-A-空态.png）
    expect(find.text('商品图待补充'), findsOneWidget);
    expect(find.textContaining('只有文字配置'), findsOneWidget);
    // 「下一步动作」：底栏「立即购买」在且可点（详情已加载 → onBuy 非空）
    expect(find.text('立即购买'), findsOneWidget);
    // 页面不是空白：价格/标题/三列都在
    expect(find.text('9.9新人体验单保200w不卡保底'), findsWidgets);
    expect(find.text('已售'), findsOneWidget);
    // 空态只有**一枚线性图片图标**（不做插画、不做 emoji 堆砌）
    expect(find.byIcon(AppIcon.image), findsOneWidget);
  });

  // ---------------- ③ 三列真实字段，且不出现"库存/日产能" ----------------

  phoneTest('③ 三列显示真实字段（已售/预计时长/服务方式），不出现"库存""日产能"', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    // 三个标签
    expect(find.text('已售'), findsOneWidget);
    expect(find.text('预计时长'), findsOneWidget);
    expect(find.text('服务方式'), findsOneWidget);

    // 三个值都是**接口下发的真实字段**：salesCount=7 / estimateDurationMin=30 / divisionPlatformLabel=手游
    // 值与单位用 `Text.rich` 拼（单位要小一号灰字），所以用 RichText 的完整文本断言。
    // 注意 RichText 纯文本带一个前导空格（`' ${unit}'` 那个 span），故用 trim 后比较。
    final texts = _richTexts(tester);
    expect(texts.any((t) => t.trim() == '7 单'), isTrue, reason: '已售值必须来自 salesCount');
    expect(texts.any((t) => t.trim() == '30 分钟'), isTrue, reason: '预计时长来自 estimateDurationMin');
    expect(texts.any((t) => t.trim() == '手游 · 人工陪同'), isTrue, reason: '服务方式 = divisionPlatformLabel + 人工陪同');

    // **绝不出现**这两个系统里根本不存在的字段
    for (final forbidden in ['库存', '日产能']) {
      expect(find.textContaining(forbidden), findsNothing, reason: '系统没有$forbidden概念，编出来就是假数据');
      expect(texts.any((t) => t.contains(forbidden)), isFalse, reason: '$forbidden 不允许出现在画面上');
    }
  });

  // ---------------- ④ 提示条文案取自接口（24 → 48） ----------------

  phoneTest('④ 提示条小时数来自接口：24 → 页面 24；接口改 48 → 页面跟着变（没写死）', (tester) async {
    // 24 小时
    final api24 = _FakeApi(timeoutHours: 24);
    await tester.pumpWidget(MaterialApp(
      home: ProductDetailPage(key: const ValueKey('h24'), productId: '137', api: api24.client),
    ));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('超 24 小时无人接单，系统自动取消并退款。'),
      findsOneWidget,
      reason: '提示条必须拼出接口下发的 24 小时',
    );

    // 换成 48 小时（**同一个页面代码**，只有接口值变了）
    //
    // ⚠️ 必须换 key：`MaterialApp` 的 `home` 换实例时，同类型同位置的 `State` 会被**复用**，
    // `initState` 不再跑 → 页面仍显示上一次的数据，这条用例就测不出"没写死"（实测踩过）。
    final api48 = _FakeApi(timeoutHours: 48);
    await tester.pumpWidget(MaterialApp(
      home: ProductDetailPage(key: const ValueKey('h48'), productId: '137', api: api48.client),
    ));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('超 48 小时无人接单，系统自动取消并退款。'),
      findsOneWidget,
      reason: '接口改成 48，页面必须跟着变 —— 证明客户端没有写死 24',
    );
    expect(find.textContaining('超 24 小时'), findsNothing, reason: '不能再残留上一份接口值');
  });

  // ---------------- ⑤ 下单须知默认折叠、点开展开 ----------------

  phoneTest('⑤ 下单须知默认折叠（只有一行摘要），点「展开」看全 4 条', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    expect(find.text('下单须知'), findsOneWidget);
    expect(find.text('展开'), findsOneWidget, reason: '默认态右侧必须是「展开」');

    // 折叠时：摘要显示第一条，正文 2/3/4 条**不在画面上**
    expect(find.textContaining('第一条须知'), findsWidgets, reason: '摘要显示第一条');
    expect(find.textContaining('第二条须知'), findsNothing, reason: '折叠时正文不渲染（不占高度）');

    // 滚到折叠行 → 点展开
    await tester.ensureVisible(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();

    expect(find.text('收起'), findsOneWidget);
    expect(find.textContaining('第二条须知'), findsOneWidget);
    expect(find.textContaining('第三条须知'), findsOneWidget);
    expect(find.textContaining('第四条须知'), findsOneWidget);
    // 序号由客户端排版（服务端文案不带序号）
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('4.'), findsOneWidget);

    // 再点收起
    await tester.ensureVisible(find.text('收起'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('展开'), findsOneWidget);
    expect(find.textContaining('第四条须知'), findsNothing);
  });

  phoneTest('⑤ 须知正文按接口下发的换行分条渲染（多段都不丢）', (tester) async {
    // 服务端约定：`\n` 分条，条内不写序号（序号由客户端 `AppTermsList` 排版）
    final api = _FakeApi(notice: '请确认游戏分区与游戏 ID 填写正确。\n未接单可随时取消，积分全额退回。');
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('展开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();

    // 第一条会出现 **2 次**：收起态摘要那一行（它仍在树上，只是被折叠动画收起）+ 正文第 1 条
    expect(find.textContaining('请确认游戏分区与游戏 ID 填写正确。'), findsNWidgets(2));
    expect(find.textContaining('未接单可随时取消，积分全额退回。'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget, reason: '两条 → 序号 1. / 2.');
  });

  // ---------------- ⑥ 立即购买 → 确认订单页 ----------------

  phoneTest('⑥ 点「立即购买」→ push 确认订单页（带正确商品），详情页不自己下单', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('立即购买'));
    await tester.pumpAndSettle();

    expect(find.byType(OrderCreatePage), findsOneWidget);
    final page = tester.widget<OrderCreatePage>(find.byType(OrderCreatePage));
    expect('${page.product?['id']}', '137', reason: '要带对商品 id');
    expect('${page.product?['name']}', '9.9新人体验单保200w不卡保底');
    expect(parsePoints(page.product?['price']), 99);
    expect('${page.product?['priceUnit']}', '单');
    // 详情页**没有**绕过确认订单页自己下单（v1 的弹层直接下单已删除）
    expect(api.orderPostBody, isNull, reason: '详情页不得 POST /user/orders 绕过确认订单页');
  });

  // ---------------- ⑦ 徽标与限购提示仍在 ----------------

  phoneTest('⑦ 徽标「董事长推荐」与每周限购提示都保留', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    expect(find.text('董事长推荐'), findsOneWidget, reason: '徽标（ProductBadge）必须保留');
    // 限购文案来自 /user/orders/weekly-quota（服务端下发，客户端不拼规则）
    expect(find.textContaining('每周限购 2 单'), findsOneWidget, reason: '每周限购提示必须保留');
    expect(find.textContaining('本周还可下 2 单'), findsOneWidget);
  });

  phoneTest('⑦ 未登录：不显示限购提示（客户端不猜规则）', (tester) async {
    AuthStore.instance.debugSetSession();
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    expect(find.text('董事长推荐'), findsOneWidget);
    expect(find.textContaining('每周限购'), findsNothing, reason: '未登录拿不到配额 → 一个字都不显示');
  });

  // ---------------- 底栏两个真实入口 ----------------

  phoneTest('底栏左二是「我的订单」真实入口（点开是真实订单页，不是占位）', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(home: ProductDetailPage(productId: '137', api: api.client)));
    await tester.pumpAndSettle();

    expect(find.text('客服'), findsOneWidget);
    expect(find.text('我的订单'), findsOneWidget);
    expect(find.text('店铺'), findsNothing, reason: '结构规则 4：只有官方自营，没有店铺概念');

    // 点之前先清会话：`OrdersPage.didChangeDependencies` 在**有 token 时**会
    // `RealtimeClient.shared.connect()` —— 那会建一条真 socket.io 连接并挂上
    // 20s 重连定时器，用例结束时报 "A Timer is still pending even after the widget tree
    // was disposed"（实测踩过，且 pop 回去也救不了：定时器挂在全局 shared 客户端上）。
    // 本用例要证明的是"这是真实订单页入口"，不是实时订阅，所以清掉 token 让它安静渲染。
    AuthStore.instance.debugSetSession();

    await tester.tap(find.text('我的订单'));
    await tester.pumpAndSettle();

    // 真实订单页的页头 + 能返回。返回箭头限定在 AppPageHeader 内：
    // 订单页自己的页内也有箭头图标，不限定会被计数问题绊住（实测踩过）
    expect(find.text('我的订单'), findsOneWidget, reason: '页头标题');
    expect(
      find.descendant(of: find.byType(AppPageHeader), matching: find.byIcon(AppIcon.arrowLeft)),
      findsOneWidget,
      reason: '从详情页进入的订单页必须能返回',
    );

    // 返回一步 → 回到商品详情页
    await tester.tap(find.descendant(of: find.byType(AppPageHeader), matching: find.byIcon(AppIcon.arrowLeft)));
    await tester.pumpAndSettle();
    expect(find.text('立即购买'), findsOneWidget, reason: '返回后回到商品详情页');
  });
}

/// 画面里所有 `RichText` 的纯文本（`Text.rich` 拼出来的"值 + 单位"要用它断言）
List<String> _richTexts(WidgetTester tester) =>
    tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).toList();

/// 假接口：详情 / 商品列表 / 分类 / 分部 / 限购配额 / 下单表单 / 订单
///
/// 数据形状**逐字段对齐真实响应**（不是随手编的壳）：本组用例断言的就是
/// "页面显示的每个数字都来自这些字段"，字段名写错用例就会挂 —— 这正是它要保证的事。
class _FakeApi {
  _FakeApi({this.timeoutHours = 24, this.notice});

  /// 待接单超时小时数（服务端 `system_setting.order_pending_take_timeout_hours`）
  final int timeoutHours;

  /// 生效须知；null 用默认那 4 条
  final String? notice;

  /// 详情页若违规直接下单，这里会拿到请求体
  Map<String, dynamic>? orderPostBody;

  String get _notice =>
      notice ??
      '第一条须知：请确认游戏分区与游戏 ID 填写正确。\n'
          '第二条须知：下单即按标价扣积分，1 件为 1 单。\n'
          '第三条须知：未接单可随时取消，积分全额退回。\n'
          '第四条须知：请勿把账号密码告知护航员。';

  Map<String, dynamic> get _product => {
        'id': '137',
        'name': '9.9新人体验单保200w不卡保底',
        'subtitle': '',
        'listName': null,
        'badgeText': '董事长推荐',
        'weeklyLimit': 2,
        'weeklyLimitByQuantity': 0,
        'gameId': '35',
        'divisionId': '1',
        'categoryId': '78',
        'price': 99,
        'priceUnit': '单',
        'estimateDurationMin': 30,
        'serviceStatus': 1,
        'salesCount': 7,
        'coverMediaId': null,
        'description': '9.9新人体验单保200w不卡保底（积分 99，按单计价）。',
        'detail': null,
        'serviceFlow': null,
        'serviceRules': null,
        'attention': null,
        'orderNotice': null,
        'status': 1,
        'coverUrl': null,
        'media': [],
        'effectiveOrderNotice': _notice,
        'orderNoticeInherited': true,
        'orderPendingTakeTimeoutHours': timeoutHours,
        'divisionPlatformLabel': '手游',
      };

  Map<String, dynamic> get _listItem => {
        'id': '137',
        'name': '9.9新人体验单保200w不卡保底',
        'subtitle': '',
        'listName': null,
        'badgeText': '董事长推荐',
        'weeklyLimit': 2,
        'weeklyLimitByQuantity': 0,
        'gameId': '35',
        'categoryId': '78',
        'divisionId': '1',
        'price': 99,
        'priceUnit': '单',
        'estimateDurationMin': 30,
        'salesCount': 7,
        'coverMediaId': null,
        'coverUrl': null,
      };

  late final ApiClient client = () {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(this);
    return ApiClient(dio: dio);
  }();

  Map<String, dynamic> handle(RequestOptions options) {
    final path = options.path;
    if (options.method == 'POST') {
      orderPostBody = (options.data is Map) ? Map<String, dynamic>.from(options.data as Map) : null;
      return {
        'code': 0,
        'message': 'ok',
        'data': {'orderNo': 'ORDTEST001', 'totalAmount': 99},
      };
    }
    // 顺序要紧：详情路径 `/public/products/137` 也 contains `/public/products`
    if (path.contains('/public/products/')) return {'code': 0, 'message': 'ok', 'data': _product};
    if (path.contains('/public/products')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [_listItem],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        },
      };
    }
    if (path.contains('/user/orders/weekly-quota')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': {'limitText': '每周限购 2 单', 'quotaText': '本周还可下 2 单'},
      };
    }
    if (path.contains('/public/categories')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': '78', 'gameId': '35', 'name': '体验单'},
        ],
      };
    }
    if (path.contains('/divisions')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '1',
            'code': 'peace_mobile',
            'gameId': '35',
            'gameName': '和平精英',
            'platform': 'mobile',
            'platformLabel': '手游',
            'name': '和平精英 · 手游',
            'shortName': '和平精英',
            'onlineDesc': '打手全天在线',
            'priceNote': '',
            'themeColor': '#16A34A',
            'subTitle': '',
            'sortOrder': 10,
            'underConstruction': false,
            'noticeText': '',
            'onlineCount': 3,
          },
        ],
      };
    }
    if (path.contains('/public/order-form')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': {
          'zoneLabel': '选择区服',
          'zoneOptions': [
            {'label': '微信', 'value': 'wechat'},
            {'label': 'QQ', 'value': 'qq'},
          ],
          'fields': [],
          'workerLabel': '选择护航员',
          'workerRandomLabel': '随机安排',
          'workerDesignatedLabel': '指定护航员',
          'feeTitle': '商品费用',
          'feeUnitLabel': '单价',
          'totalLabel': '合计',
          'submitText': '提交订单',
          'notice': '',
        },
      };
    }
    if (path.contains('/public/players')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': {'list': [], 'total': 0},
      };
    }
    // 订单页（详情页底栏「我的订单」）要的一份**形状正确**的空列表。
    // ⚠️ 这里不能回 `data: null`：`OrdersPage._load` 会 `resp['data'] as Map`
    // 直接抛 `type 'Null' is not a subtype of type 'Map<String, dynamic>'`（实测踩过），
    // 于是"点我的订单"这条用例挂在一个与本任务无关的类型错误上。
    if (path.contains('/user/orders')) {
      return {
        'code': 0,
        'message': 'ok',
        'data': {'list': [], 'total': 0, 'page': 1, 'pageSize': 50},
      };
    }
    return {'code': 0, 'message': 'ok', 'data': null};
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.api);
  final _FakeApi api;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final body = api.handle(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
