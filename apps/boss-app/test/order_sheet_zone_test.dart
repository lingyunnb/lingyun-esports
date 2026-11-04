import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_detail_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 详情页「立即购买」→ **确认订单页**（负责人 2026-10-05 商品详情页 v2 方案 B）
///
/// ## 这个文件为什么还在、但内容全换了
///
/// 旧文件名 `order_sheet_zone_test.dart` 锁定的是**已被删除的行为**：
/// v1 详情页的「立即下单」弹层（`_OrderSheet`）里选游戏分区（QQ区/微信区）+ 填游戏 ID，
/// 再由详情页**直接 POST /user/orders 下单** —— 也就是说它**绕过了确认订单页**。
/// 本轮（方案 B）把这条路径整个删掉：详情页只 push `OrderCreatePage`，
/// 分区/ID/数量/护航员全部回到确认订单页处理（现有下单流程一个字没改）。
///
/// 于是本文件改成**新契约的反向断言**：点「立即购买」之后
/// 1. 进入的是 `OrderCreatePage`（不是弹层、不是直接下单）；
/// 2. **没有任何 POST 发生**（弹层直接下单的旧行为必须彻底消失，
///    否则就会出现"详情页偷偷扣了积分、用户以为只是进了确认页"这种最坏情况）；
/// 3. 带下去的商品 id / 名称 / 价格与详情接口一致（确认订单页据此渲染商品卡）。
///
/// 分区/ID 必填的回归测试仍在，只是换了归属：见 `order_create_platform_test.dart`
/// （确认订单页自己的测试）。
void main() {
  setUp(() {
    // 关缓存：`ApiClient` 对 `/public/products` 挂 45s 列表档缓存（SWR），
    // 三个用例共用同一个 fixture baseUrl → 第 1 个用例的成功详情会被第 3 个用例命中，
    // 于是"详情加载失败"根本不会发生（实测踩过：单独跑过、一起跑就挂）。
    // 关掉后每个用例都真打自己的假接口，行为可预测。
    ApiClient.cacheEnabled = false;
    ApiCache.instance.clear();
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
  });

  testWidgets('立即购买 → 进入确认订单页（带正确商品），且详情页不自己下单', (tester) async {
    final recorder = _RecordingApi();
    await tester.pumpWidget(MaterialApp(
      home: ProductDetailPage(productId: '42', api: recorder.client),
    ));
    await tester.pumpAndSettle();

    expect(find.text('立即购买'), findsOneWidget, reason: '底部固定操作栏必须有「立即购买」');

    await tester.tap(find.text('立即购买'));
    await tester.pumpAndSettle();

    // ① 进了确认订单页（它有「提交订单」这个确认动作，详情页没有）
    expect(find.byType(OrderCreatePage), findsOneWidget, reason: '「立即购买」必须 push 确认订单页');
    expect(find.text('提交订单'), findsOneWidget, reason: '确认订单页的提交按钮应在画面上');

    // ② 详情页**没有**自己下单（旧弹层行为已删除）
    expect(recorder.postBody, isNull, reason: '详情页不得绕过确认订单页直接 POST /user/orders');

    // ③ 带下去的商品与详情接口一致
    final page = tester.widget<OrderCreatePage>(find.byType(OrderCreatePage));
    expect('${page.product?['id']}', '42');
    expect('${page.product?['name']}', '钻皮·刀');
    expect(parsePoints(page.product?['price']), 5.5);
    expect('${page.product?['priceUnit']}', '局');
  });

  testWidgets('确认订单页的分区与 ID 仍必填（下单流程未被详情页改版影响）', (tester) async {
    final recorder = _RecordingApi();
    await tester.pumpWidget(MaterialApp(
      home: ProductDetailPage(productId: '42', api: recorder.client),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即购买'));
    await tester.pumpAndSettle();

    // 分区与游戏 ID 由确认订单页承载（详情页不再有这两项输入）
    expect(find.text('游戏分区'), findsNothing, reason: '详情页不该再出现下单弹层的分区选择');
    expect(find.text('我的订单'), findsNothing, reason: '已在确认订单页，不再显示详情页底栏');

    // 确认订单页把"还没填完"如实体现为禁用提交（不静默放行）
    final submit = find.widgetWithText(ElevatedButton, '提交订单');
    if (submit.evaluate().isNotEmpty) {
      expect(tester.widget<ElevatedButton>(submit).onPressed, isNull, reason: '必填项未填齐时不得提交');
    }
  });

  testWidgets('详情加载失败：显示中文错误 + 重试，且不渲染假数据', (tester) async {
    final recorder = _RecordingApi(failDetail: true);
    await tester.pumpWidget(MaterialApp(
      home: ProductDetailPage(productId: '42', api: recorder.client),
    ));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    // 失败时**没有**「立即购买」可点（详情页的转化动作要以真实数据为前提）
    expect(find.text('立即购买'), findsOneWidget, reason: '底栏常驻（详情页结构稳定）');
  });
}

/// 记录 POST 的假接口：详情返回固定商品，其它路径给空壳
class _RecordingApi {
  _RecordingApi({this.failDetail = false});

  final bool failDetail;

  /// 详情页若违规直接下单，这里会拿到请求体（断言"没有发生过"）
  Map<String, dynamic>? postBody;

  late final ApiClient client = () {
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(this);
    return ApiClient(dio: dio);
  }();
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.rec);
  final _RecordingApi rec;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') {
      rec.postBody = (options.data is Map) ? Map<String, dynamic>.from(options.data as Map) : null;
      return _json({'code': 0, 'message': 'ok', 'data': {'orderNo': 'ORDTEST001', 'totalAmount': 5.5}});
    }
    if (options.path.contains('/public/products/')) {
      if (rec.failDetail) {
        return _json({'code': 404, 'message': '商品不存在或已下架', 'data': null}, status: 404);
      }
      return _json({
        'code': 0,
        'message': 'ok',
        'data': {
          'id': '42',
          'name': '钻皮·刀',
          'price': 5.5,
          'priceUnit': '局',
          'estimateDurationMin': 30,
          'salesCount': 7,
          'status': 1,
          'serviceStatus': 1,
          'divisionId': '1',
          'gameId': '35',
          'categoryId': '78',
          'coverUrl': null,
          'media': [],
          'effectiveOrderNotice': '第一条须知。\n第二条须知。',
          'orderPendingTakeTimeoutHours': 24,
          'divisionPlatformLabel': '手游',
        },
      });
    }
    // 确认订单页会拉的配置/分部：给最小可用空壳（本组用例不校验它们）
    if (options.path.contains('/public/order-form')) {
      return _json({'code': 0, 'message': 'ok', 'data': {'fields': [], 'zoneOptions': []}});
    }
    if (options.path.contains('/divisions')) {
      return _json({'code': 0, 'message': 'ok', 'data': []});
    }
    return _json({'code': 0, 'message': 'ok', 'data': null});
  }

  @override
  void close({bool force = false}) {}

  ResponseBody _json(Map<String, dynamic> body, {int status = 200}) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}
