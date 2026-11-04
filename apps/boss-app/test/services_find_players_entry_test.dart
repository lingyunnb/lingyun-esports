import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:fish_core/src/util/user_visible_copy_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务页「选择陪玩」入口的回归测试（2026-10-15 首版 → **2026-10-18 首页重构后重钉**）
///
/// ## 入口位置变了，口径没变
/// | | 位置 | 状态 |
/// |---|---|---|
/// | 首页主体那枚 48dp 实色主色按钮 | —— | **早已整块删除**（第 ⑤ 条守着它别被加回来） |
/// | 顶部横向导航第一项 `选择陪玩` | —— | **随规格 ②「彻底取消顶部横向导航」一并删除** |
/// | **「快捷入口」第 1 格** | 轮播/公告栏下方 | **本轮的重钉目标**（负责人规格 ⑥） |
///
/// 三件事必须在同一次改动里成立（否则就是功能倒退或入口重复）：
/// 1. 快捷入口第 1 格就是「选择陪玩」，点它真的能触发外壳回调；
/// 2. 顶部**不再有**「选择陪玩」文字导航（同一入口只出现一次）；
/// 3. 外壳没注入回调时这一格**照样在**（`_openPlayers` 兜底直接 push 现有 `PlayersPage`），
///    不会变成"点不动的死格子"。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  /// 三个分部，在线数 12 + 8 + 4 = 24
  Map<String, dynamic> grouped() => {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'gameId': '35',
            'gameName': '和平精英',
            'platformCount': 1,
            'divisions': [
              {'id': '1', 'code': 'peace_mobile', 'gameId': '35', 'gameName': '和平精英', 'platform': 'mobile', 'platformLabel': '手游', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'onlineDesc': '平均 3 分钟内接单', 'themeColor': '#16A34A', 'sortOrder': 10, 'onlineCount': 12},
            ],
          },
          {
            'gameId': '36',
            'gameName': '三角洲行动',
            'platformCount': 2,
            'divisions': [
              {'id': '2', 'code': 'delta_mobile', 'gameId': '36', 'gameName': '三角洲行动', 'platform': 'mobile', 'platformLabel': '手游', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'onlineDesc': '平均 5 分钟内接单', 'themeColor': '#2563EB', 'sortOrder': 20, 'onlineCount': 8},
              {'id': '3', 'code': 'delta_pc', 'gameId': '36', 'gameName': '三角洲行动', 'platform': 'pc', 'platformLabel': '端游', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'onlineDesc': '平均 6 分钟内接单', 'themeColor': '#7C3AED', 'sortOrder': 30, 'onlineCount': 4},
            ],
          },
        ],
      };

  Map<String, Map<String, dynamic>> fixture() => {
        '/divisions/grouped': grouped(),
        '/public/products': {
          'code': 0,
          'message': 'ok',
          'data': {
            'list': [
              {'id': '101', 'name': '和平精英上分单', 'price': 30, 'priceUnit': '局', 'salesCount': 12, 'divisionId': '1', 'gameId': '35'},
            ],
            'total': 1,
            'page': 1,
            'pageSize': 50,
          },
        },
        '/public/announcements': {
          'code': 0,
          'message': 'ok',
          'data': [
            {'id': '136', 'title': '欢迎来到 祁连山电竞', 'pinned': 1, 'createdAt': '2026-10-18T03:20:00.000Z'},
          ],
        },
      };

  Future<void> pump(WidgetTester tester, {VoidCallback? onFindPlayers}) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(
        api: _api(fixture()),
        onFindPlayers: onFindPlayers,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('① 快捷入口一行四格：选择陪玩 · 排行榜 · 我的订单 · 联系客服（左→右）', (tester) async {
    await pump(tester, onFindPlayers: () {});

    expect(find.text('选择陪玩'), findsOneWidget, reason: '本次的全部意义就是"让它被看见"');
    final players = tester.getTopLeft(find.text('选择陪玩'));
    final rank = tester.getTopLeft(find.text('排行榜'));
    final orders = tester.getTopLeft(find.text('我的订单'));
    final support = tester.getTopLeft(find.text('联系客服'));

    expect(players.dx, lessThan(rank.dx), reason: '顺序：选择陪玩 · 排行榜 · 我的订单 · 联系客服');
    expect(rank.dx, lessThan(orders.dx));
    expect(orders.dx, lessThan(support.dx));
    expect(players.dy, rank.dy, reason: '四格同一行（规格 ⑥：一行 4 格）');
    expect(rank.dy, orders.dy);
    expect(orders.dy, support.dy);

    // 每格都有一行小字副标（参考图的"图标方块 + 名称 + 一行小字"）
    expect(find.text('按分部挑人'), findsOneWidget);
    expect(find.text('分部周月榜'), findsOneWidget);
    expect(find.text('查看进度'), findsOneWidget);
    expect(find.text('在线响应'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('② 顶部横向导航已彻底删除：选择陪玩/排行榜 全页各只出现一次', (tester) async {
    await pump(tester, onFindPlayers: () {});

    expect(find.text('选择陪玩'), findsOneWidget, reason: '只剩快捷入口那一处（顶部导航按规格 ② 整排删除）');
    expect(find.text('排行榜'), findsOneWidget, reason: '只剩快捷入口那一处');
    // 「公告」两个字不再出现在任何顶栏位置（公告改由公告滚动栏承载）
    expect(find.text('公告'), findsNothing);

    // 品牌行仍然是「字标 + 两枚图标」（字标在最左，图标在右）
    final brand = tester.getTopLeft(find.byKey(ServicesPage.brandKey));
    final bell = tester.getTopLeft(find.byWidgetPredicate((w) => w is AppIcon && w.icon == AppIcons.bell).first);
    final search = tester.getTopLeft(find.byWidgetPredicate((w) => w is AppIcon && w.icon == AppIcons.search));
    expect(brand.dx, lessThan(bell.dx), reason: '品牌字标在最左');
    expect(bell.dx, lessThan(search.dx), reason: '右侧顺序：消息通知 · 搜索');
    expect(tester.takeException(), isNull);
  });

  testWidgets('③ 外壳没注入回调时：这一格照样在（不留"点了没反应"的空位）', (tester) async {
    await pump(tester);

    expect(find.text('选择陪玩'), findsOneWidget,
        reason: '回调缺失时 `_openPlayers` 兜底直接 push 现有 PlayersPage —— 格子不会被拿掉');
    expect(find.text('排行榜'), findsOneWidget, reason: '其余三格不受影响');
    expect(tester.takeException(), isNull);
  });

  testWidgets('④ 点击快捷入口第 1 格 → 触发外壳回调（不是个只会发光不干活的死格子）', (tester) async {
    var tapped = 0;
    await pump(tester, onFindPlayers: () => tapped++);

    await tester.tap(find.text('选择陪玩'));
    await tester.pump();
    expect(tapped, 1, reason: '真的能点 —— 快捷入口不是装饰');

    expect(tester.takeException(), isNull);
  });

  testWidgets('⑤ 回归：首页主体那枚 48dp 实色主色按钮已不存在（防止被加回来）', (tester) async {
    await pump(tester, onFindPlayers: () {});

    // 旧实现的三件签名：`Material(color: T.primary)` 外框 + 48dp 高 + 右侧「N 人在线」汇总
    expect(
      find.ancestor(
        of: find.text('选择陪玩'),
        matching: find.byWidgetPredicate((w) => w is Material && w.color == T.primary),
      ),
      findsNothing,
      reason: '快捷入口是浅底图标块，不是实色大按钮',
    );
    expect(
      find.ancestor(
        of: find.text('选择陪玩'),
        matching: find.byWidgetPredicate((w) => w is SizedBox && w.height == 48),
      ),
      findsNothing,
      reason: '首页那枚按钮是 48dp 通栏块，已整块删除',
    );
    expect(find.text('24 人在线'), findsNothing,
        reason: '按钮右侧那串在线数汇总（12+8+4=24）随按钮一起删除');

    // 源头级回归：组件本身也不该留在文件里（只删调用会被后来者"顺手恢复"）
    final src = File('${resolveRepoRoot()}/apps/boss-app/lib/pages/services_page.dart').readAsStringSync();
    expect(src.contains('_findPlayersEntry'), isFalse, reason: '`_findPlayersEntry` 组件必须整块删除');
    expect(src.contains('if (widget.onFindPlayers != null) _findPlayersEntry()'), isFalse);

    expect(tester.takeException(), isNull);
  });

  testWidgets('⑥ 全页不出现「积分」（项目铁律：金额一律 ¥ / 元）', (tester) async {
    await pump(tester, onFindPlayers: () {});

    expect(find.textContaining('积分'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

ApiClient _api(Map<String, Map<String, dynamic>> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw);
  return ApiClient(dio: dio);
}

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
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(jsonEncode(raw[key]), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
