import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首页「一次拉全 + 本地去重」的守卫（原「切分部/切分类零请求」用例，2026-10-18 重钉）
///
/// ## 口径变了什么、没变什么
/// **变了**：`2026-10-18 首页重构`（负责人规格）把**分类 Tab + 筛选胶囊 + 分部卡列表整排删除**，
/// 分部导航改由「热门游戏」承担 → 页面里**已经没有"切 Tab"这个交互**，原来那三条
/// "切 Tab 零请求"的断言失去了被测对象。
///
/// **没变**（这才是本用例真正要保的东西）：
/// 1. **首屏每类数据只发一发**：商品 1、分部 1、宣传图 1、公告 1、陪玩 1
///    —— 任何模块都不许"滑一下/看一块就再打一发"；
/// 2. **所有列表按 id 去重**（服务端重复下发时不会出现两张同款卡）；
/// 3. **分类只来自管理端**（`/public/categories`），且**先按当前游戏过滤、再按 id 去重**
///    （库里「护航带打」是 id=71/72 两行 —— 只去重不过滤就会同屏出现两次）。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  /// 三个分部 + **一条重复数据**：分部 `id=2` 在 `/divisions/grouped` 里被下发两次
  Map<String, dynamic> grouped() => {
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
                // 故意留空 → 热门游戏卡的「一行服务标签」回落到**管理端分类名**
                'onlineDesc': '',
                'themeColor': '#16A34A',
                'sortOrder': 10,
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
                'sortOrder': 20,
                'onlineCount': 8,
              },
              // ← 同一个 id 再来一次（真实场景：多来源合并 / 服务端重复下发）
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
                'sortOrder': 20,
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
                'sortOrder': 30,
                'onlineCount': 4,
              },
            ],
          },
        ],
      };

  Map<String, dynamic> products() => {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'id': '101', 'name': '和平精英上分单', 'price': 30, 'priceUnit': '局', 'salesCount': 12, 'divisionId': '1', 'gameId': '35'},
            {'id': '102', 'name': '三角洲手游护航单', 'price': 45.5, 'priceUnit': '局', 'salesCount': 8, 'divisionId': '2', 'gameId': '36'},
            {'id': '103', 'name': '三角洲端游护航单', 'price': 66, 'priceUnit': '小时', 'salesCount': 5, 'divisionId': '3', 'gameId': '36'},
          ],
          'total': 3,
          'page': 1,
          'pageSize': 50,
        },
      };

  testWidgets('首屏：每类数据各一发；列表按 id 去重；滚动/停留不再打请求', (tester) async {
    final log = _RequestLog();
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(
        api: _api(
          {
            '/divisions/grouped': grouped(),
            '/public/products': products(),
            '/public/announcements': {
              'code': 0,
              'message': 'ok',
              'data': [
                {'id': '136', 'title': '欢迎来到 祁连山电竞', 'pinned': 1, 'createdAt': '2026-10-18T03:20:00.000Z'},
              ],
            },
            '/public/players': {
              'code': 0,
              'message': 'ok',
              'data': {
                'list': [
                  {'workerId': 'w1', 'nickname': '青柠不加冰', 'intro': '只接三角洲手游', 'completedOrders': 1200},
                  {'workerId': 'w2', 'nickname': '黑桃老K', 'intro': '端游老手', 'completedOrders': 5400},
                ],
                'total': 2,
                'page': 1,
                'pageSize': 50,
              },
            },
          },
          log,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 首屏：三张分部卡（id=2 重复下发被去重 → 不是 4 张）
    expect(find.text('和平精英 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 手游'), findsOneWidget, reason: '同 id 的第二条必须被去重');
    expect(find.text('三角洲行动 · 端游'), findsOneWidget);
    // 热门游戏 + 精选服务 + 人气打手三块都上屏
    expect(find.text('热门游戏'), findsOneWidget);
    expect(find.text('精选服务'), findsOneWidget);
    expect(find.text('人气打手'), findsOneWidget);

    // **每类数据只发一发**（这是本文件的核心口径）
    expect(log.countOf('/public/products'), 1, reason: '商品一次拉全，不是每个模块各一发');
    expect(log.countOf('/divisions/grouped'), 1);
    expect(log.countOf('/public/banners'), 1);
    expect(log.countOf('/public/announcements'), 1);
    expect(log.countOf('/public/players'), 1);

    // 首屏快照（此后**不许再涨**）
    final baseline = log.total;
    expect(baseline, greaterThan(0), reason: '首屏该发的请求要真的发出去（否则这条用例没有意义）');

    // 滑动首页（用户看下面的模块）→ **零新请求**（模块数据已全在本地）
    await tester.drag(find.byType(ListView), const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(log.total, baseline, reason: '滚动浏览不许再发请求（模块数据首屏已一次拉全）');

    // 再停留一会儿 → 依然零请求
    await tester.pump(const Duration(seconds: 1));
    expect(log.total, baseline, reason: '停留不许触发任何轮询/补拉');
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类来自管理端：先按当前游戏过滤，再按 id 去重（同名不同 id 不合并）', (tester) async {
    final log = _RequestLog();
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(
        api: _api(
          {
            '/divisions/grouped': grouped(),
            '/public/products': products(),
            /**
             * 管理端配置的分类（**刻意做成事故现场的形状**）：
             * - id=7 被下发两次 → 按 id 去重成一条；
             * - id=9 叫「护航带打」同 id=7 同名、但**不同 id** → 必须保留（按名字去重会吃掉它）；
             * - id=10「段位上分」属于 game 36（三角洲）→ 在**和平精英**（game 35）的卡上不许出现。
             *
             * 这正是负责人 2026-10-17 查库查到的真因：库里「护航带打」是 id=71(game46)/id=72(game47)
             * **两行不同 id**，只去重不过滤 = 同屏出现两次；所以顺序必须是**过滤 → 去重**。
             */
            '/public/categories': {
              'code': 0,
              'message': 'ok',
              'data': [
                {'id': '7', 'name': '护航带打', 'gameId': '35'},
                {'id': '8', 'name': '代练', 'gameId': '35'},
                {'id': '7', 'name': '护航带打', 'gameId': '35'},
                {'id': '9', 'name': '护航带打', 'gameId': '35'},
                {'id': '10', 'name': '段位上分', 'gameId': '36'},
              ],
            },
          },
          log,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(log.countOf('/public/categories'), 1, reason: '分类数据只来自管理端接口，且只拉一次');

    // 「和平精英」分部没配 onlineDesc → 「一行服务标签」回落到管理端分类名前 2 项。
    // id=7 重复下发被去重（否则会出现「护航带打 · 护航带打」——正是"护航代打出现两次"的形状）。
    expect(find.text('护航带打 · 代练'), findsOneWidget,
        reason: '服务标签 = 管理端分类名（过滤该游戏 → 按 id 去重 → 取前两项），客户端零硬编码');
    expect(find.textContaining('护航带打 · 护航带打'), findsNothing, reason: '同 id 不许出现两次');
    // 跨游戏过滤：game 36 的分类不能混进 game 35 的分部卡。
    expect(find.textContaining('· 段位上分'), findsNothing,
        reason: '先按当前游戏过滤：三角洲的分类不许拼进和平精英卡的标签行');
    expect(tester.takeException(), isNull);
  });
}

ApiClient _api(Map<String, Map<String, dynamic>> raw, _RequestLog log) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(raw, log);
  return ApiClient(dio: dio);
}

/// 请求计数（**只记次数，不记内容**）
class _RequestLog {
  final List<String> paths = <String>[];

  int get total => paths.length;

  int countOf(String prefix) => paths.where((p) => p.startsWith(prefix)).length;
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.raw, this.log);

  final Map<String, Map<String, dynamic>> raw;
  final _RequestLog log;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    log.paths.add(options.path);
    final matches = raw.keys.where(options.path.startsWith).toList()..sort((a, b) => b.length.compareTo(a.length));
    final key = matches.isEmpty ? '' : matches.first;
    // 未匹配 → 与真实服务端一致返回 HTTP 404 + 错误信封（客户端据此走失败分支）
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
