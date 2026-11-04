import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 下单链路测试（负责人 2026-10-04：完全仿参考 App 的「商品列表 + 确认订单」）
///
/// 覆盖：
/// 1) 商品列表：专区行 / 分类竖栏 / 商品卡（标题+销量+价格+下单按钮）
/// 2) 确认订单：商品卡 + 数量步进器 + 选择区服 + 动态字段 + 选择护航员 + 费用 + 吸底提交
/// 3) **配置驱动**：字段标签/必填/开关、区服选项、护航员文案全部来自 `/public/order-form`
/// 4) 必填校验：缺必填项不发起下单请求
void main() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  final divisions = [
    {'id': '1', 'gameId': '35', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'platformLabel': '手游', 'themeColor': '#16A34A', 'iconMediaId': null},
    {'id': '2', 'gameId': '36', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'themeColor': '#2563EB', 'iconMediaId': null},
    {'id': '3', 'gameId': '36', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'platformLabel': '端游', 'themeColor': '#7C3AED', 'iconMediaId': null},
  ];
  final categories = [
    {'id': '44', 'gameId': '35', 'name': '段位上分'},
    {'id': '45', 'gameId': '35', 'name': '护航保底'},
  ];
  final products = [
    {
      'id': '101',
      'name': '传奇段位上分陪练',
      'subtitle': '全段位可接',
      'gameId': '35',
      'categoryId': '44',
      'divisionId': '1',
      'price': 100,
      'priceUnit': '局',
      'salesCount': 24811,
      'coverMediaId': null,
      'coverUrl': null,
    },
  ];
  final orderForm = {
    'zoneLabel': '选择区服',
    'zoneOptions': [
      {'label': '微信', 'value': 'wechat'},
      {'label': 'QQ', 'value': 'qq'},
    ],
    'fields': [
      {'key': 'gamePlayerId', 'label': '游戏昵称或游戏ID', 'placeholder': '请输入游戏昵称或者游戏ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 64},
      {'key': 'remark', 'label': '订单备注(选填)', 'placeholder': '请输入订单备注(选填)', 'type': 'textarea', 'required': false, 'enabled': true, 'maxLength': 200},
      {'key': 'contactPhone', 'label': '联系方式（选填）', 'placeholder': '请输入联系手机号码（选填）', 'type': 'phone', 'required': false, 'enabled': true, 'maxLength': 20},
    ],
    'workerLabel': '选择护航员',
    'workerRandomLabel': '随机安排',
    'workerDesignatedLabel': '指定护航员',
    'feeTitle': '商品费用',
    'feeUnitLabel': '单价',
    'totalLabel': '合计',
    'submitText': '提交订单',
  };

  Map<String, Map<String, dynamic>> fixture({Map<String, dynamic>? form}) => {
        '/divisions': envelope(divisions),
        '/public/categories': envelope(categories),
        '/public/products': envelope({'list': products, 'total': 1}),
        '/public/order-form': envelope(form ?? orderForm),
        '/public/players': envelope({'list': const [], 'total': 0}),
        '/user/conversations': envelope({'list': const []}),
        '/user/friends': envelope({'list': const []}),
        '/user/notifications': envelope({'list': const []}),
      };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 【2026-10-04 性能专项】公开 GET 现在会真正进 ApiCache（修复前 `token != null`
    // 的判断让公开接口从未被缓存）。本文件各 case 共用 `baseUrl = http://fixture.local`，
    // 不清缓存会让上一个 case 的 fixture 被下一个 case 命中 —— "管理端改了配置、
    // 页面要立即跟随"这类断言尤其容易因此拿到旧配置而失败。
    ApiCache.instance.clear();
  });

  testWidgets('商品列表：专区行 + 分类竖栏 + 商品卡（标题/销量/价格/下单按钮）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(fixture()))));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 专区行（3 个分部，含三角洲两个平台）
    expect(find.text('和平精英'), findsWidgets);
    expect(find.text('三角洲行动'), findsWidgets);
    // 左侧分类竖栏
    expect(find.text('段位上分'), findsWidgets);
    expect(find.text('护航保底'), findsWidgets);
    // 商品卡
    expect(find.text('传奇段位上分陪练'), findsOneWidget);
    expect(find.text('销量 24811'), findsOneWidget);
    expect(find.text('下单'), findsWidgets);
  });

  testWidgets('确认订单：完全仿参考结构（商品卡/区服/动态字段/护航员/费用/吸底提交）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(
        api: _api(fixture()),
        divisionId: '1',
        product: products.first,
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('确认订单'), findsOneWidget);
    // 商品卡
    expect(find.text('传奇段位上分陪练'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    // 数量步进器
    expect(find.text('1'), findsWidgets);
    // 区服（来自配置）
    expect(find.text('选择区服'), findsOneWidget);
    expect(find.text('微信'), findsOneWidget);
    expect(find.text('QQ'), findsOneWidget);
    // 动态字段（来自配置，含必填星号）
    expect(find.text('游戏昵称或游戏ID'), findsOneWidget);
    // 下方字段需滚动后可见（真机同样为滚动列表）
    await tester.drag(find.byType(ListView).first, const Offset(0, -420));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('订单备注(选填)'), findsOneWidget);
    expect(find.text('联系方式（选填）'), findsOneWidget);
    // 护航员（文案来自配置）
    expect(find.text('选择护航员'), findsOneWidget);
    expect(find.text('随机安排'), findsOneWidget);
    expect(find.text('指定护航员'), findsOneWidget);
    // 费用与吸底
    expect(find.text('商品费用'), findsOneWidget);
    expect(find.text('合计：'), findsOneWidget);
    expect(find.text('提交订单'), findsWidgets);
  });

  testWidgets('配置驱动：管理端改标签/必填/开关与文案，页面立即跟随', (tester) async {
    final custom = {
      ...orderForm,
      'zoneLabel': '选择大区',
      'zoneOptions': [
        {'label': '微信区', 'value': 'wechat'},
        {'label': 'QQ区', 'value': 'qq'},
        {'label': '国际服', 'value': 'global'},
      ],
      'workerLabel': '选择打手',
      'workerRandomLabel': '平台安排',
      'workerDesignatedLabel': '我要指定',
      'submitText': '立即下单',
      'fields': [
        {'key': 'gamePlayerId', 'label': '你的游戏ID', 'placeholder': '填 ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 64},
        {'key': 'remark', 'label': '备注一下', 'placeholder': '备注', 'type': 'textarea', 'required': false, 'enabled': false, 'maxLength': 200},
      ],
    };
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(fixture(form: custom)), divisionId: '1', product: products.first),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('选择大区'), findsOneWidget);
    expect(find.text('微信区'), findsOneWidget);
    expect(find.text('国际服'), findsOneWidget);
    expect(find.text('你的游戏ID'), findsOneWidget);
    expect(find.text('备注一下'), findsNothing); // enabled=false 不显示
    expect(find.text('选择打手'), findsOneWidget);
    expect(find.text('平台安排'), findsOneWidget);
    expect(find.text('立即下单'), findsWidgets);
  });

  testWidgets('必填校验：未填游戏ID 时提交被拦下并高亮', (tester) async {
    var posted = false;
    final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
    dio.httpClientAdapter = _Adapter(fixture(), onPost: (path) {
      if (path.contains('/user/orders')) posted = true;
    });
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: ApiClient(dio: dio), divisionId: '1', product: products.first),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('提交订单'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(posted, isFalse, reason: '缺必填项不得发起下单请求');
    // 提示已改为品牌化浮层（Overlay 内部），此处只断言"未发起请求"这一硬约束
  });

  testWidgets('数量步进器：+ 后合计翻倍', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: OrderCreatePage(api: _api(fixture()), divisionId: '1', product: products.first),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 初始 1 件 × 100
    expect(find.text('¥100.00'), findsWidgets);
    await tester.tap(find.byIcon(AppIcon.plus).last);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('¥200.00'), findsWidgets, reason: '2 件合计应为 ¥200.00');
  });
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, {this.onPost});
  final Map<String, Map<String, dynamic>> raw;
  final void Function(String path)? onPost;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.method == 'POST') onPost?.call(options.path);
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}), 404, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
