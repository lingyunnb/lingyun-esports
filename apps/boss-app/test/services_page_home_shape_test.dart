import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务页对"服务端只给一部分数据"的真实返回体形状的回归（2026-10-05 新增，2026-10-18 重钉）
///
/// 背景：`GET /public/home` 曾被瘦身到**只剩 `announcements` 一个 key**。本文件把那种真实形状
/// 喂给服务页，断言页面照常渲染（分部/商品照常上屏）、不抛异常、不因缺字段白屏。
///
/// **2026-10-18 首页重构后重钉的口径**（负责人 2026-10-18 首页重构规格）：
/// - 分部导航由「热门游戏」承担 → 断言用**完整分部名**（`和平精英 · 手游`），不再有分类 Tab、
///   也不再出现「祁连山官方」这个 Tab 首项（首页没有 Tab 了）；
/// - 商品常驻「精选服务」横排卡（不再有"图1 不显示商品"的二选一视图）；
/// - `/public/site`、`/public/clubs` 自 2026-10-18 起都不是本页数据源（官方馆整块删除），
///   本文件用**负向断言**把它钉住。
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  /// 当天线上 `/public/home` 的真实形状（只有 announcements 一个 key → 契约残缺 → 必须回落）
  final homeNarrowed = {
    'code': 0,
    'message': 'ok',
    'data': {
      'announcements': [
        {
          'id': '136',
          'title': '欢迎来到 祁连山电竞',
          'summary': '祁连山电竞俱乐部正式上线',
          'pinned': 1,
          'createdAt': '2026-10-04T08:15:51.486Z',
        },
      ],
    },
  };

  final grouped = {
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

  testWidgets('服务页：/public/home 只剩 announcements 时照常渲染（无异常）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(
        api: _api({
          '/public/home': homeNarrowed,
          '/divisions/grouped': grouped,
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
        }),
      ),
    ));
    await tester.pumpAndSettle();

    // 分部来自 /divisions/grouped（不依赖 /public/home 的残缺契约）→ 落在「热门游戏」三张卡上
    expect(find.text('热门游戏'), findsOneWidget);
    expect(find.text('和平精英 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 端游'), findsOneWidget);
    // 首页**不再有分类 Tab / 「祁连山官方」Tab 首项**（规格 ② 拆掉了顶部与分类导航）
    expect(find.text('祁连山官方'), findsNothing, reason: '首页已无分类 Tab（分部导航由热门游戏承担）');

    // 三宫格仍在（投诉/打赏/充值没有别的入口）
    expect(find.text('投诉客服'), findsOneWidget);
    expect(find.text('打赏'), findsOneWidget);
    expect(find.text('充值'), findsOneWidget);

    // 精选服务：商品直接上屏（不再有"聚合视图不显示商品"的二选一）
    expect(find.text('精选服务'), findsOneWidget);
    expect(find.text('和平精英上分单'), findsOneWidget, reason: '商品来自 /public/products');

    // 公告栏读的是真实公告（这里来自回落路径的 /public/announcements → 404 → 空 → 整块不渲染）
    expect(find.text('官方'), findsNothing, reason: '没有公告数据就不渲染公告栏（不摆占位）');

    // 没有因为 /public/home 瘦身抛异常（若页面仍读被删字段，这里会炸或渲染出空卡片）
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务页：/public/site 与 /public/clubs 不再是本页数据源', (tester) async {
    /// 2026-10-18 重写：原用例断言「官方馆为空时兜底文案取自 /public/site」，
    /// 而官方馆整块**已被负责人删除**（它与首页分部入口重复）。
    /// 因此这里改成**负向**口径：即便服务端仍配了 site / clubs，首页也不再渲染它们。
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(
        api: _api({
          '/public/home': homeNarrowed,
          '/divisions/grouped': grouped,
          '/public/site': {
            'code': 0,
            'message': 'ok',
            'data': {'clubTitle': '关于俱乐部', 'clubParagraphs': ['这是来自官网内容接口的兜底简介。']},
          },
          '/public/clubs': {'code': 0, 'message': 'ok', 'data': <dynamic>[]},
        }),
      ),
    ));
    await tester.pumpAndSettle();

    // 官方馆那块（分区标题 + 兜底卡）整块不在了
    expect(find.text('平台直营 · 无第三方'), findsNothing, reason: '官方馆分区标题已随整块删除');
    expect(find.text('祁连山电竞 · 关于俱乐部'), findsNothing, reason: '/public/site 不再参与首页渲染');
    expect(find.text('这是来自官网内容接口的兜底简介。'), findsNothing, reason: '兜底文案随之消失');
    // 该说的东西还在（热门游戏 + 精选服务的标题在，商品/分部一个不少）
    expect(find.text('热门游戏'), findsOneWidget);
    expect(find.text('和平精英 · 手游'), findsOneWidget);

    // 关键：这段文案**不可能**来自 /public/home（该接口只剩 announcements）
    expect(find.textContaining('欢迎来到 祁连山电竞'), findsNothing);
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
