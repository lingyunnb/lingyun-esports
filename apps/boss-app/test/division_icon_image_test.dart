import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/orders_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「分部有图就用图」测试（负责人 2026-10-04 追加需求）
///
/// 背景：管理端已把官方游戏图挂到 `division.iconMediaId` / `coverMediaId`
/// （实测入库：和平精英 = media 141、三角洲行动 ×2 = media 140），
/// 客户端**有图就用图**，无图保持原来的"自绘游戏图标"回退。
///
/// 锁死的规则：
/// 1. `GameIconTile` 传了图片（imageUrl 或 mediaId）→ 渲染图片（[CachedNetImage]），**不再出现自绘图标**
/// 2. **端游角标逻辑不变**：`platform == 'pc'` 时在**图片底部居中**仍叠「端」（高 size*0.30、字号 size*0.18、距底约 3px）
/// 3. 图字段解析规则：`iconMediaId` 优先，其次 `coverMediaId`，都空 → 回退自绘图标
/// 4. 首页分部卡（通栏/半宽）、商品列表（专区圆形行 + 商品卡）、确认订单商品卡、订单卡商品块
///    都已按所属分部接上官方图（订单卡额外用上了服务端新下发的 divisionId/gameId）
void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 【2026-10-04 性能专项】公开 GET 现在会真正进 ApiCache（修复前 `token != null`
    // 的判断让公开接口从未被缓存）。本文件所有 case 都用同一个
    // `baseUrl = http://fixture.local`，于是**上一个 case 的 fixture 会被下一个 case 命中**，
    // 断言"无图回退"时却拿到"有图"的旧响应。测试间必须清缓存，保证各自从空缓存开始。
    ApiCache.instance.clear();
  });

  group('GameIconTile：有图就用图', () {
    testWidgets('传 imageUrl → 渲染图片，不是自绘图标', (tester) async {
      await tester.pumpWidget(wrap(const GameIconTile(
        gameKey: 'delta_mobile 三角洲行动 · 手游',
        platform: 'mobile',
        imageUrl: '/media/public/140',
      )));
      await tester.pump();

      expect(find.byType(CachedNetImage), findsOneWidget, reason: '有图必须用图');
      expect(find.byIcon(AppIcon.shield), findsNothing, reason: '不再渲染自绘游戏图标');

      final img = tester.widget<CachedNetImage>(find.byType(CachedNetImage));
      expect(img.url, endsWith('/media/public/140'));
      expect(img.radius, 12, reason: '圆角沿用调用点分档（默认 12）');
    });

    testWidgets('传 mediaId → 拼成 /media/public/{id} 后渲染图片', (tester) async {
      await tester.pumpWidget(wrap(const GameIconTile(
        gameKey: 'peace_mobile 和平精英',
        platform: 'mobile',
        mediaId: '141',
        radius: 10,
      )));
      await tester.pump();

      final img = tester.widget<CachedNetImage>(find.byType(CachedNetImage));
      expect(img.url, endsWith('/media/public/141'));
      expect(img.radius, 10);
      expect(find.byIcon(AppIcon.players), findsNothing);
    });

    testWidgets('pc 平台 + 有图 → 「端」角标仍叠在图片底部居中（几何与无图时一致）', (tester) async {
      await tester.pumpWidget(wrap(const GameIconTile(
        gameKey: 'delta_pc 三角洲行动 · 端游',
        platform: 'pc',
        size: 60,
        mediaId: '140',
      )));
      await tester.pump();

      expect(find.byType(CachedNetImage), findsOneWidget);
      expect(find.text('端'), findsOneWidget, reason: '端游角标必须保留（图片上也要有）');

      final block = tester.getRect(find.byType(GameIconTile));
      final badgeFinder = find.ancestor(of: find.text('端'), matching: find.byType(Container)).first;
      final badge = tester.getRect(badgeFinder);
      final deco = tester.widget<Container>(badgeFinder).decoration! as BoxDecoration;

      expect(badge.height, closeTo(60 * 0.30, 0.001), reason: '角标高 = size*0.30');
      expect(badge.center.dx, closeTo(block.center.dx, 0.5), reason: '图片上同样水平居中');
      expect(block.bottom - badge.bottom, closeTo(3, 0.6), reason: '距底约 3px');
      expect(deco.borderRadius, BorderRadius.circular(4));
      expect(deco.color!.a, closeTo(0.42, 0.01), reason: '半透明黑，压在图上也可读');
      final text = tester.widget<Text>(find.text('端'));
      expect(text.style!.fontSize, closeTo(60 * 0.18, 0.001));
      expect(text.style!.color, Colors.white);
    });

    testWidgets('无图 / 空串 / 空白 → 保持自绘图标回退（行为与改版前一致）', (tester) async {
      for (final tile in const [
        GameIconTile(gameKey: 'delta', platform: 'mobile'),
        GameIconTile(gameKey: 'delta', platform: 'mobile', mediaId: ''),
        GameIconTile(gameKey: 'delta', platform: 'mobile', mediaId: '   '),
        GameIconTile(gameKey: 'delta', platform: 'mobile', imageUrl: '', mediaId: ''),
      ]) {
        await tester.pumpWidget(wrap(tile));
        await tester.pump();
        expect(find.byType(CachedNetImage), findsNothing, reason: '没图不许出图片组件');
        expect(find.byIcon(AppIcon.shield), findsOneWidget, reason: '没图回退自绘图标');
      }
    });

    test('divisionMediaId：iconMediaId 优先 → 其次 coverMediaId → 都空为 null', () {
      expect(divisionMediaId(iconMediaId: '140', coverMediaId: '141'), '140');
      expect(divisionMediaId(iconMediaId: null, coverMediaId: '141'), '141');
      expect(divisionMediaId(iconMediaId: '  ', coverMediaId: '141'), '141');
      expect(divisionMediaId(iconMediaId: null, coverMediaId: null), isNull);
      expect(divisionMediaId(iconMediaId: '', coverMediaId: '  '), isNull);
    });
  });

  group('页面调用点：分部有图 → 各页出图（含端游角标）', () {
    testWidgets('服务页：3 个分部都挂了官方图 → 分类 Tab + 分部入口卡出图', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_servicesFixture(withIcons: true)))));
      await tester.pumpAndSettle();

      // 【2026-10-18】官方馆卡整块删除（与精选服务重复）。
      // 分部图仍有两处落点：分类 Tab 的 20dp 小图 + 分部入口卡的 44dp 图 → 3 × 2 = 6 个 GameIconTile
      // （都有图 → 各自内部是 CachedNetImage）
      expect(find.byType(GameIconTile), findsNWidgets(6));
      expect(find.byType(CachedNetImage), findsNWidgets(6), reason: '分部有图就用图（Tab 3 + 入口卡 3）');
      // Tab 的 20dp 小图上**刻意关闭「端」徽标**（3px 文字不可读）—— 平台差异由分类页承担；
      // 入口卡是 44dp，徽标仍然关闭（同一处代码），端游靠完整的「三角洲行动 · 端游」名区分
      expect(find.text('端'), findsNothing, reason: '20dp/44dp 图都不贴端游角标（见页面注释）');
      // 3 个分部都用图 → 一个自绘图标块都不剩（原来剩下的那一块是官方馆的）
      expect(find.byIcon(AppIcon.players), findsNothing);
      expect(find.byIcon(AppIcon.shield), findsNothing);
    });

    testWidgets('服务页：分部无图 → 保持自绘图标（回退不被破坏）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_servicesFixture()))));
      await tester.pumpAndSettle();

      expect(find.byType(CachedNetImage), findsNothing);
      // 3 Tab + 3 分部入口卡 = 6（无图 → 全是自绘图标块）
      expect(find.byType(GameIconTile), findsNWidgets(6));
    });

    testWidgets('商品列表：专区圆形行 + 商品卡都用分部官方图；切端游后商品卡图上出「端」角标', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(_productsFixture(withIcons: true)))));
      await tester.pumpAndSettle();

      // 专区圆形行 2 张（2 个分部） + 商品卡 1 张（商品无封面 → 用分部图）
      expect(find.byType(CachedNetImage), findsNWidgets(3));
      expect(find.text('手游陪练'), findsOneWidget);
      expect(find.text('端'), findsNothing, reason: '默认第一个分部是手游');

      await tester.tap(find.text('三角洲端游'));
      await tester.pumpAndSettle();

      expect(find.text('端游陪练'), findsOneWidget);
      expect(find.byType(CachedNetImage), findsNWidgets(3), reason: '端游分部同样用图');
      expect(find.text('端'), findsOneWidget, reason: '端游商品卡的图片底部叠「端」角标');
    });

    testWidgets('确认订单：商品卡用所属分部官方图 + 端游角标', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OrderCreatePage(api: _api(_orderFormFixture(withIcons: true)), divisionId: '3', product: _pcProduct),
      ));
      await tester.pumpAndSettle();

      expect(find.text('端游陪练'), findsOneWidget);
      expect(find.byType(CachedNetImage), findsOneWidget, reason: '商品卡用分部官方图');
      expect(find.text('端'), findsOneWidget, reason: '端游角标保留');
      // 分部文案现在出现两处：① 商品卡上的分部标签（照旧）② 服务区上方的平台标识（负责人 2026-10-04 新增）
      expect(find.text('三角洲行动 · 端游'), findsNWidgets(2), reason: '分部标签照旧 + 服务区平台标识');
    });

    testWidgets('订单卡：按订单 divisionId 对照分部 → 出官方图 + 端游角标（服务端已下发 divisionId/gameId）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: OrdersPage(api: _api(_ordersFixture()))));
      await tester.pumpAndSettle();

      expect(find.text('端游陪练'), findsOneWidget);
      expect(find.byType(CachedNetImage), findsOneWidget, reason: '订单卡商品块用分部官方图');
      expect(find.text('端'), findsOneWidget, reason: '端游订单同样叠「端」角标');
    });
  });
}

/// 端游商品（确认订单页直接传入的 payload，与详情页「立即购买」`_buyNow` 一致）
/// （列表页自 2026-10-05 起不再直接构造这份 payload：点卡/点「下单」都先进详情页）
const _pcProduct = <String, dynamic>{
  'id': '102',
  'name': '端游陪练',
  'price': 100,
  'priceUnit': '局',
  'coverUrl': null,
  'divisionId': '3',
  'gameKey': 'delta_pc 三角洲行动 · 端游',
  'platform': 'pc',
  'gameId': '36',
};

/// 服务页 fixture（`/divisions/grouped` + 官方馆 + 首页聚合）
Map<String, Map<String, dynamic>> _servicesFixture({bool withIcons = false}) {
  Map<String, dynamic> div(String id, String code, String gameId, String gameName, String platform, String label, String color) => {
        'id': id,
        'code': code,
        'gameId': gameId,
        'gameName': gameName,
        'platform': platform,
        'platformLabel': label,
        'name': '$gameName · $label',
        'shortName': gameName,
        'onlineDesc': '平均 3 分钟内接单',
        'themeColor': color,
        'onlineCount': 12,
        'iconMediaId': withIcons ? '140' : null,
        'coverMediaId': withIcons ? '140' : null,
      };
  return {
    '/divisions/grouped': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'gameId': '35',
          'gameName': '和平精英',
          'platformCount': 1,
          'divisions': [div('1', 'peace_mobile', '35', '和平精英', 'mobile', '手游', '#16A34A')],
        },
        {
          'gameId': '36',
          'gameName': '三角洲行动',
          'platformCount': 2,
          'divisions': [
            div('2', 'delta_mobile', '36', '三角洲行动', 'mobile', '手游', '#2563EB'),
            div('3', 'delta_pc', '36', '三角洲行动', 'pc', '端游', '#7C3AED'),
          ],
        },
      ],
    },
    '/public/clubs': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'id': '1',
          'name': '祁连山电竞 · 官方自营',
          'subTitle': '官方自营',
          'description': '和平精英与三角洲行动全段位上分与护航',
          'coverMediaId': null,
          'rating': '4.9',
          'orderCount': 2847,
        },
      ],
    },
    '/public/home': {
      'code': 0,
      'message': 'ok',
      'data': {
        'clubTitle': '官方自营',
        'clubParagraphs': ['和平精英与三角洲行动全段位上分与护航'],
      },
    },
  };
}

/// 商品列表 fixture（`/divisions` + 分类 + 商品；商品均无自带封面）
Map<String, Map<String, dynamic>> _productsFixture({bool withIcons = false}) => {
      '/divisions': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '2',
            'code': 'delta_mobile',
            'gameId': '36',
            'gameName': '三角洲行动',
            'platform': 'mobile',
            'platformLabel': '手游',
            'name': '三角洲行动 · 手游',
            'shortName': '三角洲手游',
            'themeColor': '#2563EB',
            'iconMediaId': withIcons ? '140' : null,
          },
          {
            'id': '3',
            'code': 'delta_pc',
            'gameId': '36',
            'gameName': '三角洲行动',
            'platform': 'pc',
            'platformLabel': '端游',
            'name': '三角洲行动 · 端游',
            'shortName': '三角洲端游',
            'themeColor': '#7C3AED',
            'iconMediaId': withIcons ? '140' : null,
          },
        ],
      },
      '/public/categories': {
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': '44', 'gameId': '36', 'name': '段位上分'},
        ],
      },
      '/public/products': {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            _product('101', '手游陪练', '2'),
            _product('102', '端游陪练', '3'),
          ],
          'total': 2,
        },
      },
    };

/// 确认订单 fixture（下单表单 + 分部）
Map<String, Map<String, dynamic>> _orderFormFixture({bool withIcons = false}) => {
      '/divisions': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '3',
            'code': 'delta_pc',
            'gameId': '36',
            'gameName': '三角洲行动',
            'platform': 'pc',
            'platformLabel': '端游',
            'name': '三角洲行动 · 端游',
            'shortName': '三角洲行动',
            'themeColor': '#7C3AED',
            'iconMediaId': withIcons ? '140' : null,
          },
        ],
      },
      '/public/order-form': {
        'code': 0,
        'message': 'ok',
        'data': {
          'zoneLabel': '选择区服',
          'zoneOptions': [
            {'label': '微信', 'value': 'wechat'},
          ],
          'fields': [
            {'key': 'gamePlayerId', 'label': '游戏昵称或游戏ID', 'placeholder': '请输入', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 64},
          ],
          'feeTitle': '商品费用',
          'feeUnitLabel': '单价',
          'totalLabel': '合计',
          'submitText': '提交订单',
        },
      },
      '/public/players': {
        'code': 0,
        'message': 'ok',
        'data': {'list': const [], 'total': 0},
      },
    };

/// 订单页 fixture（订单带 divisionId/gameId —— 服务端 2026-10-04 起下发）
Map<String, Map<String, dynamic>> _ordersFixture() => {
      '/user/orders': {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {
              'id': '9001',
              'orderNo': 'ORDTEST9001',
              'totalAmount': 100,
              'status': 'pending_take',
              'statusName': '待接单',
              'createdAt': '2026-10-04T10:00:00.000Z',
              'productName': '端游陪练',
              'priceUnit': '局',
              'quantity': 1,
              'divisionId': '3',
              'gameId': '36',
            },
          ],
          'total': 1,
          'page': 1,
          'pageSize': 50,
        },
      },
      '/divisions': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '3',
            'code': 'delta_pc',
            'gameId': '36',
            'gameName': '三角洲行动',
            'platform': 'pc',
            'platformLabel': '端游',
            'name': '三角洲行动 · 端游',
            'shortName': '三角洲行动',
            'themeColor': '#7C3AED',
            'iconMediaId': '140',
            'coverMediaId': '140',
          },
        ],
      },
    };

Map<String, dynamic> _product(String id, String name, String divisionId) => {
      'id': id,
      'name': name,
      'subtitle': '全段位可接',
      'gameId': '36',
      'categoryId': '44',
      'divisionId': divisionId,
      'price': 100,
      'priceUnit': '局',
      'salesCount': 128,
      'coverMediaId': null,
      'coverUrl': null,
    };

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

/// fixture 适配器：按 path 前缀匹配（长前缀优先）；`/public/products` 再按 query 的 divisionId 过滤
class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw);
  final Map<String, Map<String, dynamic>> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    if (key.isEmpty) {
      return ResponseBody.fromString(
        jsonEncode({'code': 404, 'message': 'Not Found', 'data': null}),
        404,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
      );
    }
    var body = raw[key]!;
    if (key == '/public/products') {
      final div = '${options.queryParameters['divisionId'] ?? ''}';
      final all = ((body['data'] as Map)['list'] as List).cast<Map>();
      final filtered = div.isEmpty ? all : all.where((p) => '${p['divisionId']}' == div).toList();
      body = {
        'code': 0,
        'message': 'ok',
        'data': {'list': filtered, 'total': filtered.length},
      };
    }
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
