import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/models/review_models.dart';
import 'package:boss_app/widgets/order_review_section.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 订单评价（负责人 2026-10-15：评价与评分体系）
///
/// 硬要求逐条守住：
/// 1. **已评价 → 不再显示评价入口**（原地显示结果）；
/// 2. **不满意才给售后入口**（且只有服务端 `needAfterSale === true` 时才给）；
/// 3. 只有 `status == 'completed'` 才有评价段（与服务端「仅 completed 可评」同口径）；
/// 4. 满意 / 不满意是**二元**（不是 5 星），备注 ≤200 字、可空；
/// 5. 评价入口**只在订单详情里**（本组件不从列表卡调用 —— 见 [OrdersPage] 的接入位置）。
///
/// 本用例**直接渲染评价段本身**（不经订单详情弹层），这样每条断言的失败点都唯一：
/// 是"评价段逻辑错了"而不是"弹层没打开"。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'review-token');
    ApiCache.instance.clear();
  });

  tearDown(() {
    // 排掉 Toast 的 2s 自动消失定时器（否则用例结束时报 pending timer）
    AppToast.dismiss();
    AuthStore.instance.debugSetSession();
  });

  Future<void> settle(WidgetTester tester, {int frames = 10}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> flushToasts(WidgetTester tester) async {
    AppToast.dismiss();
    await tester.pump(const Duration(milliseconds: 40));
  }

  Future<void> pumpSection(
    WidgetTester tester,
    _Adapter adapter, {
    String status = 'completed',
    VoidCallback? onAfterSale,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OrderReviewSection(
            api: _api(adapter),
            orderId: '396',
            status: status,
            onAfterSale: onAfterSale,
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  // -------------------------------------------------------------------------
  // ① 未评价：入口在（二选一 + 备注 + 提交），且"不选不能提交"
  // -------------------------------------------------------------------------

  testWidgets('未评价：显示「满意 / 不满意」二选一 + 备注框 + 提交键（未选时置灰）', (tester) async {
    final adapter = _Adapter(getBody: _envelope(null));
    await pumpSection(tester, adapter);

    expect(find.text('服务评价'), findsOneWidget);
    expect(adapter.gets, 1, reason: '进详情读一次评价状态');
    expect(adapter.getPath, '/user/orders/396/review');

    // 二元大按钮（不是 5 星）
    expect(find.byKey(const Key('order-review-satisfied')), findsOneWidget);
    expect(find.byKey(const Key('order-review-unsatisfied')), findsOneWidget);
    expect(find.text('满意'), findsOneWidget);
    expect(find.text('不满意'), findsOneWidget);
    for (final star in ['★', '1 星', '5 星', '评分']) {
      expect(find.textContaining(star), findsNothing, reason: '评价是二元，不是星级「$star」');
    }

    // 备注框：≤200 字
    final field = tester.widget<TextField>(find.byKey(const Key('order-review-remark')));
    expect(field.maxLength, 200);

    // 没选之前提交键不可用（不允许"不选就提交"）
    expect(tester.widget<AppButton>(find.byType(AppButton)).onPressed, isNull);
    await tester.tap(find.byKey(const Key('order-review-satisfied')));
    await settle(tester, frames: 4);
    expect(tester.widget<AppButton>(find.byType(AppButton)).onPressed, isNotNull,
        reason: '选了满意 → 提交键可用');
  });

  testWidgets('提交满意：POST 体正确（satisfied = true + 备注），提示「感谢认可！」且不给售后入口', (tester) async {
    final adapter = _Adapter(
      getBody: _envelope(null),
      postBody: _envelope({'ok': true, 'needAfterSale': false}),
      reviewAfterPost: {'satisfied': true, 'remark': '打得很稳', 'createdAt': '2026-10-15T09:20:00.000Z'},
    );
    await pumpSection(tester, adapter);

    await tester.tap(find.byKey(const Key('order-review-satisfied')));
    await settle(tester, frames: 4);
    await tester.enterText(find.byKey(const Key('order-review-remark')), '打得很稳');
    await tester.tap(find.text('提交评价'));
    await settle(tester);

    expect(adapter.posts, hasLength(1));
    expect(adapter.posts.single['satisfied'], isTrue);
    expect(adapter.posts.single['remark'], '打得很稳');
    expect(find.text('感谢认可！'), findsOneWidget, reason: '满意 → 提示「感谢认可！」');
    expect(find.byKey(const Key('order-review-after-sale')), findsNothing,
        reason: '满意不给售后入口');
    await flushToasts(tester);
  });

  testWidgets('提交不满意：提示收到反馈 + needAfterSale=true 时给「申请售后」入口，点了能走下一步', (tester) async {
    var afterSaleTapped = false;
    final adapter = _Adapter(
      getBody: _envelope(null),
      postBody: _envelope({'ok': true, 'needAfterSale': true}),
      reviewAfterPost: {'satisfied': false, 'remark': '挂机了 15 分钟', 'createdAt': '2026-10-15T09:20:00.000Z'},
    );
    await pumpSection(tester, adapter, onAfterSale: () => afterSaleTapped = true);

    await tester.tap(find.byKey(const Key('order-review-unsatisfied')));
    await settle(tester, frames: 4);
    await tester.enterText(find.byKey(const Key('order-review-remark')), '挂机了 15 分钟');
    await tester.tap(find.text('提交评价'));
    await settle(tester);

    expect(adapter.posts.single['satisfied'], isFalse);
    expect(find.textContaining('已收到你的反馈'), findsOneWidget);

    // 售后入口：只在 needAfterSale 时出现，且**不只是颜色**区分（有图标 + 文案 + 按钮）
    expect(find.byKey(const Key('order-review-after-sale')), findsOneWidget);
    expect(find.text('申请售后'), findsOneWidget);
    expect(find.byIcon(AppIcon.info), findsWidgets);

    await tester.tap(find.byKey(const Key('order-review-aftersale-action')));
    await settle(tester, frames: 4);
    expect(afterSaleTapped, isTrue, reason: '点「申请售后」必须真的走到下一步');
    await flushToasts(tester);
  });

  // -------------------------------------------------------------------------
  // ② 已评价：不再显示入口（原地显示结果）
  // -------------------------------------------------------------------------

  testWidgets('已评价（满意）：原地显示结果，入口（二选一 + 备注框 + 提交键）全部消失', (tester) async {
    final adapter = _Adapter(
      getBody: _envelope({'satisfied': true, 'remark': '很稳', 'createdAt': '2026-10-15T09:20:00.000Z'}),
    );
    await pumpSection(tester, adapter);

    expect(find.text('满意'), findsOneWidget, reason: '结果块的结论文案');
    expect(find.text('很稳'), findsOneWidget, reason: '备注照实回显');
    // 时间口径 = **本地时区**（`reviewTimeText` → `DateTime.toLocal()`，与 core 的
    // `network_time.dart` / `worker_wallet_page.dart` 同款，全仓 6 处一致）。
    // 所以期望值**从本地时区推导**，不硬编码 UTC 串 —— 否则在 UTC+8 上会期望错 8 小时。
    expect(find.text(localShort('2026-10-15T09:20:00.000Z')), findsOneWidget,
        reason: '时间由 reviewTimeText 唯一出口按本地时区渲染');
    if (DateTime.now().timeZoneOffset != Duration.zero) {
      expect(find.text('10-15 09:20'), findsNothing,
          reason: '非 UTC 时区下不得直接把 UTC 串当本地时间显示');
    }

    expect(find.text('提交评价'), findsNothing, reason: '已评价 → 不再显示评价入口');
    expect(find.byKey(const Key('order-review-satisfied')), findsNothing);
    expect(find.byKey(const Key('order-review-unsatisfied')), findsNothing);
    expect(find.byKey(const Key('order-review-remark')), findsNothing);
  });

  testWidgets('已评价（不满意）：显示结果但不重复推售后（needAfterSale 只来自本次提交）', (tester) async {
    final adapter = _Adapter(
      getBody: _envelope({'satisfied': false, 'remark': '', 'createdAt': '2026-10-15T09:20:00.000Z'}),
    );
    await pumpSection(tester, adapter);

    expect(find.text('不满意'), findsOneWidget);
    expect(find.text('提交评价'), findsNothing);
    expect(find.byKey(const Key('order-review-after-sale')), findsNothing,
        reason: '重进详情不再重复引导一次售后（售后入口在详情操作行常驻，见 OrdersPage）');
  });

  testWidgets('提交成功后原地变结果：入口消失（回读竞态也不能把入口放回来）', (tester) async {
    // 服务端"写入成功但回读还没看到"：POST ok，GET 仍回 null
    final adapter = _Adapter(
      getBody: _envelope(null),
      postBody: _envelope({'ok': true, 'needAfterSale': false}),
      reviewAfterPost: null,
    );
    await pumpSection(tester, adapter);

    await tester.tap(find.byKey(const Key('order-review-satisfied')));
    await settle(tester, frames: 4);
    await tester.tap(find.text('提交评价'));
    await settle(tester);

    expect(adapter.gets, greaterThanOrEqualTo(2), reason: '提交后会回读一次权威结果');
    expect(find.text('提交评价'), findsNothing, reason: '回读还没看到也不能让入口回来（否则用户会重复提交）');
    expect(find.text('满意'), findsOneWidget);
    await flushToasts(tester);
  });

  // -------------------------------------------------------------------------
  // ③ 边界：状态 / 重复评价 / 读不到
  // -------------------------------------------------------------------------

  testWidgets('非 completed 状态：整个评价段不渲染，也不发请求', (tester) async {
    final adapter = _Adapter(getBody: _envelope(null));
    await pumpSection(tester, adapter, status: 'after_sale');

    expect(find.byKey(const Key('order-review-card')), findsNothing);
    expect(find.text('服务评价'), findsNothing);
    expect(adapter.gets, 0, reason: '不渲染就不该打请求');
  });

  testWidgets('重复评价回 400「该订单已评价」：中文提示上屏、入口保持原样（不崩、不假装成功）', (tester) async {
    final adapter = _Adapter(
      getBody: _envelope(null),
      postStatus: 400,
      postBody: {'code': 400, 'message': '该订单已评价', 'data': null},
    );
    await pumpSection(tester, adapter);

    await tester.tap(find.byKey(const Key('order-review-satisfied')));
    await settle(tester, frames: 4);
    await tester.tap(find.text('提交评价'));
    await settle(tester);

    expect(find.text('该订单已评价'), findsOneWidget);
    expect(find.text('提交评价'), findsOneWidget, reason: '服务端拒了 → 入口照旧，让用户能重试');
    expect(tester.takeException(), isNull);
    await flushToasts(tester);
  });

  testWidgets('评价状态读不到：给一行重试（既不假装未评价，也不假装已评价）', (tester) async {
    final adapter = _Adapter(getStatus: 500, getBody: {'code': 500, 'message': '服务器开小差了', 'data': null});
    await pumpSection(tester, adapter);

    expect(find.byKey(const Key('order-review-load-failed')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('提交评价'), findsNothing, reason: '状态不明时不给入口（避免引导重复提交被服务端拒）');

    // 重试：这次服务端好了 → 正常显示入口
    adapter.getStatus = 200;
    adapter.getBody = _envelope(null);
    await tester.tap(find.byKey(const Key('order-review-retry')));
    await settle(tester);
    expect(find.text('提交评价'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // ④ 好评率口径（唯一出口在 models/review_models.dart，页面与测试同源）
  // -------------------------------------------------------------------------

  test('好评率：无评价 → 「暂无评价」（连 100 都不许编）', () {
    expect(satisfiedRateText(null, reviewCount: 0), kNoReviewYet);
    expect(satisfiedRateText(null, reviewCount: null), kNoReviewYet);
    // 服务端就算把比率回成 100，只要评价数是 0，也不许显示 100%
    expect(satisfiedRateText(100, reviewCount: 0), kNoReviewYet);
    expect(satisfiedRateText(1, reviewCount: 0), kNoReviewYet);
    expect(kNoReviewYet, '暂无评价');
  });

  test('好评率：**只认百分数口径**（`1.0` = 1%，不是 100%）；整数不带小数点', () {
    // 口径由服务端唯一决定：`satisfiedRate` 是「百分数字符串」如 "98.2"。
    // ⚠️ 这条测试原来断言的是"两种口径都吃"（`0.98 → 98%`、`1 → 100%`）——
    //    那是个**致命错**：100 条评价里只有 1 条好评时服务端给 "1.0"，
    //    旧口径会渲染成 **100%** = 把差评显示成满分。2026-10-15 已修，断言同步收严。
    expect(satisfiedRateText(98, reviewCount: 42), '98%');
    expect(satisfiedRateText(98.2, reviewCount: 42), '98.2%');
    expect(satisfiedRateText(98.75, reviewCount: 42), '98.8%');
    expect(satisfiedRateText(0, reviewCount: 42), '0%');
    // ★ 关键回归：这两条是本次修 bug 的核心
    expect(satisfiedRateText(1, reviewCount: 100), '1%');   // 不是 100%！
    expect(satisfiedRateText('1.0', reviewCount: 100), '1%'); // 服务端真实下发形态（字符串）
    // 小数比率口径**不再被兼容**：0.98 按百分数理解就是 0.98% → 显示 1.0%（不是 98%）
    expect(satisfiedRateText(0.98, reviewCount: 42), '1%');
  });

  test('计数文案：千分位；缺失 → —（不编 0）', () {
    expect(countText(1284, unit: '次'), '1,284 次');
    expect(countText(7), '7');
    expect(countText(null), '—');
  });
}

Map<String, dynamic> _envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

/// ISO(UTC) → 页面该显示的**本地**短时间（与 `reviewTimeText` 同一口径：`.toLocal()`）
///
/// 期望值一律由它推导，不在断言里硬编码 UTC 串（跨时区跑测试才不会假红）。
String localShort(String iso) {
  final l = DateTime.parse(iso).toLocal();
  return '${l.month}-${l.day} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

ApiClient _api(_Adapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

/// 假接口：`GET /user/orders/:id/review` + `POST /user/orders/:id/review`
///
/// `reviewAfterPost` 模拟"写入成功之后服务端能读到了"：POST 成功后 GET 的返回值被换成它
/// （`null` = 回读还没看到 —— 用来测回读竞态）。
class _Adapter implements HttpClientAdapter {
  _Adapter({
    required this.getBody,
    this.getStatus = 200,
    this.postBody,
    this.postStatus = 200,
    this.reviewAfterPost,
  });

  Map<String, dynamic> getBody;
  int getStatus;
  Map<String, dynamic>? postBody;
  int postStatus;

  /// POST 成功后 GET 返回什么（null → 继续回 [getBody]）
  Map<String, dynamic>? reviewAfterPost;

  final List<Map<String, dynamic>> posts = [];
  int gets = 0;
  String getPath = '';

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') {
      posts.add((options.data as Map).cast<String, dynamic>());
      if (postStatus == 200 && reviewAfterPost != null) {
        getBody = _envelope(reviewAfterPost);
      }
      return _body(postStatus, postBody ?? _envelope({'ok': true, 'needAfterSale': false}));
    }
    gets += 1;
    getPath = options.path;
    return _body(getStatus, getBody);
  }

  static ResponseBody _body(int status, Map<String, dynamic> json) => ResponseBody.fromString(
        jsonEncode(json),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
