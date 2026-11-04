import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/product_list_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 游戏图标块规则测试（负责人 2026-10-04：主页 + 下单链路封面统一用游戏图标，端游加「端」角标）
///
/// 锁死的规则：
/// 1. **端游 → 出现「端」角标；手游 → 不出现**（核心规则，widget 级 + 页面级双重覆盖）
/// 2. 游戏 → 图标映射：和平精英 = AppIcon.players；三角洲行动 = AppIcon.shield；其他 = AppIcon.orders
/// 3. 底色优先用传入口（分部 themeColor）
/// 4. **管理端已上传的自定义图优先级最高**：有 coverMediaId / coverUrl 时不出图标块
/// 5. 无图时不再是"通用图标塞渐变色块"（不再出现渐变兜底）
void main() {
  const pc = GameIconTile(gameKey: 'delta_pc 三角洲行动 · 端游', platform: 'pc');
  const mobile = GameIconTile(gameKey: 'delta_mobile 三角洲行动 · 手游', platform: 'mobile');

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 【2026-10-04 性能专项】公开 GET 现在会真正进 ApiCache（修复前公开接口从未被缓存）。
    // 本文件各 case 共用 `baseUrl = http://fixture.local`，不清缓存会让上一个 case 的
    // fixture 被下一个 case 命中（"无图 → 回退图标"就会拿到"有图"的旧响应而失败）。
    ApiCache.instance.clear();
  });

  group('GameIconTile', () {
    testWidgets('端游 → 出现「端」角标', (tester) async {
      await tester.pumpWidget(wrap(pc));

      expect(find.text('端'), findsOneWidget);
      expect(find.byType(GameIconTile), findsOneWidget);
    });

    testWidgets('手游 → 不出现「端」角标', (tester) async {
      await tester.pumpWidget(wrap(mobile));

      expect(find.text('端'), findsNothing);
    });

    testWidgets('非端游的其它取值（空 / custom）也不出角标', (tester) async {
      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'peace', platform: null)));
      expect(find.text('端'), findsNothing);

      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'peace', platform: 'custom')));
      expect(find.text('端'), findsNothing);

      // badge=false 时即使端游也不显示（极小尺寸调用点用）
      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'delta', platform: 'pc', badge: false)));
      expect(find.text('端'), findsNothing);
    });

    testWidgets('映射：和平精英=players / 三角洲=shield / 未知=orders', (tester) async {
      expect(gameKeyIcon('peace_mobile 和平精英'), AppIcon.players);
      expect(gameKeyIcon('和平精英 · 手游'), AppIcon.players);
      expect(gameKeyIcon('delta_pc 三角洲行动 · 端游'), AppIcon.shield);
      expect(gameKeyIcon('三角洲行动 · 手游'), AppIcon.shield);
      expect(gameKeyIcon('unknown_game'), AppIcon.orders);
      expect(gameKeyIcon(null), AppIcon.orders);

      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'peace', platform: 'mobile')));
      expect(find.byIcon(AppIcon.players), findsOneWidget);

      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'delta', platform: 'pc')));
      expect(find.byIcon(AppIcon.shield), findsOneWidget);
    });

    testWidgets('底色优先用传入 color（分部 themeColor），未传时按 gameKey 稳定取色', (tester) async {
      await tester.pumpWidget(wrap(
        const GameIconTile(gameKey: 'peace', platform: 'mobile', color: Color(0xFF0E7C7B)),
      ));
      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(GameIconTile),
        matching: find.byType(DecoratedBox),
      ).first);
      expect((box.decoration as BoxDecoration).color, const Color(0xFF0E7C7B));

      // 同 gameKey 两次调用必须同色（稳定，不随 hash 种子漂移）
      expect(gameIconColor('peace_mobile'), gameIconColor('和平精英 · 手游'));
      expect(gameIconColor('delta_pc'), isNot(gameIconColor('peace_mobile')));
    });

    testWidgets('尺寸规则：默认 60，圆角 12，图标 = size*0.46', (tester) async {
      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'peace', platform: 'mobile')));

      final size = tester.getSize(find.byType(GameIconTile));
      expect(size.width, 60);
      expect(size.height, 60);

      final box = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(GameIconTile),
        matching: find.byType(DecoratedBox),
      ).first);
      expect((box.decoration as BoxDecoration).borderRadius, BorderRadius.circular(12));

      final icon = tester.widget<Icon>(find.byIcon(AppIcon.players));
      expect(icon.size, closeTo(60 * 0.46, 0.001));
      expect(icon.color, Colors.white);
    });

    testWidgets('端游角标几何：高 size*0.30、字号 size*0.18、距块底约 3px、不遮挡图标主体', (tester) async {
      await tester.pumpWidget(wrap(const GameIconTile(gameKey: 'delta_pc', platform: 'pc', size: 60)));

      final block = tester.getRect(find.byType(GameIconTile));
      final badgeFinder = find.ancestor(of: find.text('端'), matching: find.byType(Container)).first;
      final badge = tester.getRect(badgeFinder);
      final badgeBox = tester.widget<Container>(badgeFinder);
      final deco = badgeBox.decoration! as BoxDecoration;

      // 角标高度 = size*0.30（文字本身居中，所以量角标容器而不是文字）
      expect(badge.height, closeTo(60 * 0.30, 0.001));
      // 底部居中
      expect(badge.center.dx, closeTo(block.center.dx, 0.5), reason: '角标必须水平居中');
      // 距色块底边约 3px（规格 0.05*size 且夹在 [2,3]）
      expect(block.bottom - badge.bottom, closeTo(3, 0.6));
      // 不遮挡图标主体：图标整体在角标上方
      final icon = tester.getRect(find.byIcon(AppIcon.shield));
      expect(icon.bottom, lessThanOrEqualTo(badge.top), reason: '图标主体在角标之上，不被压住');

      final text = tester.widget<Text>(find.text('端'));
      expect(text.style!.fontSize, closeTo(60 * 0.18, 0.001)); // 60px 时约 10.8
      expect(text.style!.fontWeight, FontWeight.w600);
      expect(text.style!.color, Colors.white);

      // 角标底色：半透明黑 + 圆角 4
      expect(deco.color!.a, closeTo(0.42, 0.01));
      expect(deco.borderRadius, BorderRadius.circular(4));
    });
  });

  group('页面调用点', () {
    testWidgets('服务页：三分部（含 1 个端游）→ 分类 Tab 不贴端游徽标（20dp 档位）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_servicesFixture()))));
      await tester.pumpAndSettle();

      // 3 个分部（和平手游 + 三角洲手游 + 三角洲端游）
      expect(find.byType(GameIconTile), findsWidgets);
      // 【方案 G 2026-10-17】分部只以 20dp 分类 Tab 小图出现：这个尺寸上「端」徽标只有 3px、
      // 不可读 → 关闭徽标；平台差异由分类页 / 建设中页的 DivisionPlatformLabel 承担
      expect(find.text('端'), findsNothing, reason: '20dp Tab 小图不贴端游徽标');
      // 游戏 → 图标映射生效（和平 = players；三角洲 = shield）
      expect(find.byIcon(AppIcon.players), findsWidgets);
      expect(find.byIcon(AppIcon.shield), findsWidgets);
    });

    testWidgets('服务页：分部都挂了官方图 → 用图不用图标块（Tab + 入口卡都走图片）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_servicesFixture(clubCover: '9')))));
      await tester.pumpAndSettle();

      // 【2026-10-18】官方馆卡整块删除（与精选服务重复）。
      // 分部图仍有两处落点（分类 Tab 20dp + 分部入口卡 44dp）→ 3 分部 × 2 = 6 个 GameIconTile 位。
      expect(find.byType(GameIconTile), findsNWidgets(6), reason: '3 分部 × 2 处（Tab + 入口卡）');
    });

    testWidgets('服务页：分部无官方图 → 回落自绘游戏图标块（仍是 6 处）', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_servicesFixture()))));
      await tester.pumpAndSettle();

      // 无图时每个图位都用自绘图标块 —— 位置数不变（Tab 3 + 入口卡 3）
      expect(find.byType(GameIconTile), findsNWidgets(6));
    });

    testWidgets('商品列表：端游分部商品卡出现「端」角标，手游分部不出现', (tester) async {
      await tester.pumpWidget(MaterialApp(home: ProductListPage(api: _api(_productsFixture()))));
      await tester.pumpAndSettle();

      // 默认第一部 = 手游（无角标）
      expect(find.text('手游陪练'), findsOneWidget);
      expect(find.text('端'), findsNothing);

      // 切到端游专区 → 该分部商品卡出现「端」角标
      await tester.tap(find.text('三角洲端游'));
      await tester.pumpAndSettle();
      expect(find.text('端游陪练'), findsOneWidget);
      expect(find.text('端'), findsOneWidget);
    });
  });
}

/// 服务页 fixture：3 个分部（和平手游 / 三角洲手游 / 三角洲端游）+ 官方馆卡
Map<String, Map<String, dynamic>> _servicesFixture({String? clubCover}) => {
      '/divisions/grouped': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'gameId': '35',
            'gameName': '和平精英',
            'platformCount': 1,
            'divisions': [
              {
                'id': '1',
                'code': 'peace_mobile',
                'gameId': '35',
                'gameName': '和平精英',
                'platform': 'mobile',
                'platformLabel': '手游',
                'name': '和平精英 · 手游',
                'shortName': '和平精英',
                'onlineDesc': '平均 3 分钟内接单',
                'themeColor': '#16A34A',
                'onlineCount': 12,
              },
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
                'gameId': '36',
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
                'gameId': '36',
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
        ],
      },
      '/public/clubs': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '1',
            'name': '祁连山电竞 · 三角洲行动分部',
            'subTitle': '三角洲行动分部',
            'description': '全段位上分与护航',
            'coverMediaId': clubCover,
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
          'clubParagraphs': ['全段位上分与护航'],
        },
      },
    };

/// 商品列表 fixture：1 手游分部 + 1 端游分部，各自 1 个无封面商品
Map<String, Map<String, dynamic>> _productsFixture() => {
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
            'iconMediaId': null,
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
            'iconMediaId': null,
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

/// fixture 适配器：按 path 前缀匹配；`/public/products` 再按 query 里的 divisionId 过滤，
/// 以模拟「切分部 → 换商品列表」的真实服务端行为。
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
