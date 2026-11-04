import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「记住我的游戏 ID」回填（负责人 2026-10-15）
///
/// 口径（接口契约：保存是**服务端在订单创建成功时自动做的**，客户端只有读）：
/// - 进下单页调 `GET /user/game-accounts`，按**当前商品所属游戏**匹配到记录就预填
///   `gamePlayerId`（`gameZone` 命中区服选项时一起填）；
/// - **只回填、不新增必填**：必填仍完全由 `/public/order-form` 的 `required` 决定，
///   `_submit` 的校验一个字节没动；
/// - 预填后**用户仍可改**，清空后**不会被填回来**；
/// - 拿不到 / 无记录 / 未登录 → **保持现状（空）**，不报错、不挡下单。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    AuthStore.instance.debugSetSession(accessToken: 'prefill-token');
    ApiCache.instance.clear();
  });

  tearDown(() {
    AppToast.dismiss();
    AuthStore.instance.debugSetSession();
  });

  Future<void> settle(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 下单页从"宿主页 push 进去"渲染：提交成功后页面会 `pop`（真实交互就是返回上一页）
  ///
  /// 视口 402×874（真机常见档）：360 宽时**商品卡里"价格 + 数量步进器"那一行**
  /// 会被测试字体（每个字 = 1em 的方块字）撑溢出 —— 那是既有布局在测试字体下的
  /// 表现，与本次回填无关，所以本用例用真机宽度渲染，不去碰那一行。
  Future<void> pumpCreate(WidgetTester tester, _Adapter adapter, {Map<String, dynamic>? product}) async {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => OrderCreatePage(
                    api: _api(adapter),
                    divisionId: '2',
                    product: product ?? Map<String, dynamic>.from(_product),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  /// 按 hint 取字段（字段顺序/数量由接口下发，用 hint 定位最稳）
  TextField fieldByHint(WidgetTester tester, String hint) => tester.widget<TextField>(
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint),
      );

  String textOfHint(WidgetTester tester, String hint) => fieldByHint(tester, hint).controller!.text;

  // -------------------------------------------------------------------------
  // ① 命中游戏 → 预填
  // -------------------------------------------------------------------------

  testWidgets('进页按当前商品所属游戏回填：游戏 ID + 命中区服选项的区服一起填', (tester) async {
    final adapter = _Adapter(accounts: [
      {'gameId': '99', 'gameName': '别的游戏', 'gamePlayerId': 'OTHER-1', 'gameZone': 'qq', 'updatedAt': '2026-10-15T10:00:00.000Z'},
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': 'ID-7788', 'gameZone': 'wechat', 'updatedAt': '2026-10-14T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);

    expect(adapter.accountsGets, 1, reason: '进页读一次已记住的游戏账号');
    expect(textOfHint(tester, '填游戏 ID'), 'ID-7788', reason: '按商品所属游戏（gameId=36）命中并预填');
    expect(textOfHint(tester, '填手机号'), '', reason: '别的字段一个字都不动');

    // 区服：记住的值 'wechat' 在当前选项里 → 预填（选中项是主色实底白字）
    final wechat = tester.widget<Container>(find.ancestor(
      of: find.text('微信区'),
      matching: find.byType(Container),
    ).first);
    expect((wechat.decoration as BoxDecoration).color, T.primary, reason: '记住的区服被选中');
  });

  testWidgets('匹配口径：gameId 精确相等优先；同一游戏多条取 updatedAt 最近的一条', (tester) async {
    final adapter = _Adapter(accounts: [
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': '旧-ID', 'gameZone': '', 'updatedAt': '2026-09-01T10:00:00.000Z'},
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': '新-ID', 'gameZone': '', 'updatedAt': '2026-10-12T10:00:00.000Z'},
      {'gameName': '三角洲行动', 'gamePlayerId': '同名但没 gameId 的', 'gameZone': '', 'updatedAt': '2026-10-15T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);

    expect(textOfHint(tester, '填游戏 ID'), '新-ID', reason: 'gameId 命中优先于按游戏名兜底，且取最近使用');
  });

  testWidgets('没有该游戏的记录：保持空（不猜、不报错、不挡下单）', (tester) async {
    final adapter = _Adapter(accounts: [
      {'gameId': '99', 'gameName': '别的游戏', 'gamePlayerId': 'OTHER-1', 'gameZone': 'qq', 'updatedAt': '2026-10-15T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);

    expect(textOfHint(tester, '填游戏 ID'), '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('接口拿不到（500）：保持空、不报错、不弹提示', (tester) async {
    final adapter = _Adapter(accounts: null, accountsStatus: 500);
    await pumpCreate(tester, adapter);

    expect(textOfHint(tester, '填游戏 ID'), '');
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // ② 预填后仍可改 / 可清空 / 不影响必填
  // -------------------------------------------------------------------------

  testWidgets('清空预填值不会被填回来；必填校验照旧生效（回填不新增/不移除必填）', (tester) async {
    final adapter = _Adapter(accounts: [
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': 'ID-7788', 'gameZone': 'qq', 'updatedAt': '2026-10-14T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);
    expect(textOfHint(tester, '填游戏 ID'), 'ID-7788');

    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '填游戏 ID'), '');
    await settle(tester, frames: 6);

    expect(textOfHint(tester, '填游戏 ID'), '', reason: '用户清空就是清空，不会被回填覆盖回来');

    // 清空后提交 → 必填错误照旧（`_submit` 的校验与回填无关）
    await tester.tap(find.text('提交订单'));
    await settle(tester, frames: 6);

    expect(find.text('此项必填，填游戏 ID'), findsOneWidget, reason: '必填仍是接口说了算');
    expect(adapter.orderPosts, isEmpty, reason: '校验没过不该发下单请求');
    // 排空「请填写标 * 的必填项」浮层的 2 秒定时器（否则用例结束被判 pending timer）
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('预填值用户可改：提交时带的是用户改后的值（不是记住的那个）', (tester) async {
    final adapter = _Adapter(accounts: [
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': 'ID-7788', 'gameZone': 'wechat', 'updatedAt': '2026-10-14T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);

    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '填游戏 ID'), '改过的-ID');
    await settle(tester, frames: 4);
    await tester.tap(find.text('提交订单'));
    await settle(tester);

    expect(adapter.orderPosts, hasLength(1));
    expect(adapter.orderPosts.single['gamePlayerId'], '改过的-ID');
    expect(adapter.orderPosts.single['gameZone'], 'wechat', reason: '区服仍是被预填的那个（用户没改）');
    await tester.pump(const Duration(seconds: 3)); // 排空 toast 定时器
  });

  testWidgets('预填值直接提交：回填让必填天然过关（回填不改变必填规则，只是填好了）', (tester) async {
    final adapter = _Adapter(accounts: [
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': 'ID-7788', 'gameZone': 'wechat', 'updatedAt': '2026-10-14T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);

    await tester.tap(find.text('提交订单'));
    await settle(tester);

    expect(find.text('此项必填，填游戏 ID'), findsNothing);
    expect(adapter.orderPosts, hasLength(1));
    expect(adapter.orderPosts.single['gamePlayerId'], 'ID-7788');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('未登录（没有令牌）：不发请求、保持空、不报错', (tester) async {
    AuthStore.instance.debugSetSession();
    final adapter = _Adapter(accounts: [
      {'gameId': '36', 'gameName': '三角洲行动', 'gamePlayerId': 'ID-7788', 'gameZone': 'qq', 'updatedAt': '2026-10-14T10:00:00.000Z'},
    ]);
    await pumpCreate(tester, adapter);

    expect(adapter.accountsGets, 0, reason: '没登录就不该打这个接口');
    expect(textOfHint(tester, '填游戏 ID'), '');
    expect(tester.takeException(), isNull);
  });
}

/// 商品（三角洲手游，gameId=36 / divisionId=2）
const Map<String, dynamic> _product = {
  'id': '201',
  'name': '三角洲手游护航单',
  'subtitle': '',
  'gameId': '36',
  'categoryId': '51',
  'divisionId': '2',
  'price': 88,
  'priceUnit': '单',
  'salesCount': 12,
  'coverMediaId': null,
  'coverUrl': null,
};

ApiClient _api(_Adapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter({this.accounts, this.accountsStatus = 200});

  /// `/user/game-accounts` 的 data（null 且 status=500 → 模拟接口挂了）
  Object? accounts;
  int accountsStatus;

  int accountsGets = 0;
  final List<Map<String, dynamic>> orderPosts = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.path;

    if (options.method == 'POST' && path == '/user/orders') {
      orderPosts.add((options.data as Map).cast<String, dynamic>());
      return _body(200, {'code': 0, 'message': 'ok', 'data': {'id': '900', 'orderNo': 'ORDTEST'}});
    }
    if (path.startsWith('/user/game-accounts')) {
      accountsGets += 1;
      if (accountsStatus != 200) {
        return _body(accountsStatus, {'code': accountsStatus, 'message': '服务器开小差了', 'data': null});
      }
      return _body(200, {'code': 0, 'message': 'ok', 'data': accounts ?? const []});
    }
    if (path.startsWith('/divisions')) {
      return _body(200, {'code': 0, 'message': 'ok', 'data': _divisions});
    }
    if (path.startsWith('/public/order-form')) {
      return _body(200, {'code': 0, 'message': 'ok', 'data': _orderForm});
    }
    if (path.startsWith('/user/wallet')) {
      return _body(200, {'code': 0, 'message': 'ok', 'data': {'balance': 999}});
    }
    // 限购配额等其它接口：一律"没有这一项"（页面按 null 处理）
    return _body(200, {'code': 0, 'message': 'ok', 'data': null});
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

  static const List<dynamic> _divisions = [
    {
      'id': '2',
      'gameId': '36',
      'name': '三角洲行动 · 手游',
      'shortName': '三角洲行动',
      'platformLabel': '手游',
      'themeColor': '#2563EB',
      'iconMediaId': null,
    },
  ];

  static const Map<String, dynamic> _orderForm = {
    'zoneLabel': '选择区服',
    'zoneOptions': [
      {'label': 'QQ 区', 'value': 'qq'},
      {'label': '微信区', 'value': 'wechat'},
    ],
    'fields': [
      {
        'key': 'gamePlayerId',
        'label': '游戏 ID',
        'placeholder': '填游戏 ID',
        'type': 'text',
        'required': true,
        'enabled': true,
        'maxLength': 64,
      },
      {
        'key': 'contactPhone',
        'label': '联系电话',
        'placeholder': '填手机号',
        'type': 'phone',
        'required': false,
        'enabled': true,
        'maxLength': 20,
      },
    ],
    'workerLabel': '选择护航员',
    'workerRandomLabel': '随机安排',
    'workerDesignatedLabel': '指定护航员',
    'feeTitle': '商品费用',
    'feeUnitLabel': '单价',
    'totalLabel': '合计',
    'submitText': '提交订单',
  };
}
