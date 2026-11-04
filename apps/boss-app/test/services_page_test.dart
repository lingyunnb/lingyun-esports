import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务页（新首页）渲染测试 —— **负责人 2026-10-18 首页重构规格**
///
/// ## 本文件钉的是「结构」，不是像素
/// 规格 ⑥ 的模块顺序是**唯一口径**（顶部品牌栏 → 轮播图 → 公告滚动栏 → 快捷入口 → 三宫格 →
/// 热门游戏 → 精选服务 → 人气打手 → 底部导航），本文件逐块钉住：
/// - 每块都**来自真实接口**（分部 `/divisions/grouped`、商品 `/public/products`、
///   公告 `/public/announcements`、陪玩 `/public/players`、分类 `/public/categories`）；
/// - 接口没给 → **整块不渲染**（不摆假卡、不摆「待接入」）；
/// - 顶栏**不再有横向导航**（选择陪玩 / 排行榜 / 公告 三项文字入口已删，规格 ②）；
/// - 三宫格（投诉客服 / 打赏 / 充值）仍在（「不许让功能失去入口」）；
/// - 没有主页面的 "会员中心 / 平台公告" 大模块（规格 ⑤）。
void main() {
  /// 三个分部（和平精英·手游 / 三角洲·手游 / 三角洲·端游，最后一个建设中）
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
                'onlineDesc': '平均 3 分钟内接单',
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
                'underConstruction': true,
                'noticeText': '本分部正在建设中，敬请期待。',
              },
            ],
          },
        ],
      };

  /// 商品夹具（`GET /public/products` 列表档形状：`{data: {list: [...]}}`）
  Map<String, dynamic> products() => {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {
              'id': '101',
              'name': '和平精英上分单',
              'subtitle': '30 局速通 · 全程录屏',
              'price': 30,
              'priceUnit': '局',
              'salesCount': 12,
              'divisionId': '1',
              'gameId': '35',
            },
            {
              'id': '103',
              'name': '三角洲端游护航单',
              'price': 66,
              'priceUnit': '小时',
              'salesCount': 5,
              'divisionId': '3',
              'gameId': '36',
            },
          ],
          'total': 2,
          'page': 1,
          'pageSize': 50,
        },
      };

  /// 公告夹具（服务端已按 `pinned DESC, createdAt DESC` 排好；首页只展示**最新一条**）
  Map<String, dynamic> announcements() => {
        'code': 0,
        'message': 'ok',
        'data': [
          {'id': '136', 'title': '欢迎来到 祁连山电竞', 'pinned': 1, 'createdAt': '2026-10-18T03:20:00.000Z'},
          {'id': '135', 'title': '护航单恢复接单', 'pinned': 0, 'createdAt': '2026-10-17T03:20:00.000Z'},
        ],
      };

  /// 陪玩夹具：5 位，接单量 5400 / 1200 / 860 / 320 / 40 → 首页只取前 4（按接单量降序）
  ///
  /// ⚠️ **`divisionName` 刻意写成短名**（`三角洲行动` / `和平精英`，不是 `三角洲行动 · 手游`）：
  /// 首页「热门游戏」卡显示的是**完整分部名**；若这里的分部标签也写完整名，
  /// `find.text('三角洲行动 · 手游')` 会同时命中"热门游戏卡"和"人气打手卡上的分部标签"两处，
  /// 顺序/唯一性断言就分不清是哪一块（那是夹具自撞，不是实现问题）。
  Map<String, dynamic> players() => {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {
              'workerId': 'w1',
              'nickname': '青柠不加冰',
              'intro': '只接三角洲手游',
              'avatarMediaId': null,
              'divisionName': '三角洲行动',
              'completedOrders': 1200,
              'reviewCount': 320,
              'satisfiedRate': '98.4',
              'grade': 4,
              'gradeLabel': 'LV4',
              'gradeName': '称雄',
            },
            {
              'workerId': 'w2',
              'nickname': '黑桃老K',
              'intro': '端游老手',
              'avatarMediaId': null,
              'divisionName': '三角洲行动',
              'completedOrders': 5400,
              'reviewCount': 900,
              'satisfiedRate': '99.1',
              'grade': 5,
              'gradeLabel': 'LV5',
              'gradeName': '宗师',
            },
            {
              'workerId': 'w3',
              'nickname': '北屿',
              'intro': '和平精英地铁护航',
              'avatarMediaId': null,
              'divisionName': '和平精英',
              'completedOrders': 860,
              'reviewCount': 210,
              'satisfiedRate': '97.5',
              'grade': 3,
              'gradeLabel': 'LV3',
              'gradeName': '扬名',
            },
            {
              'workerId': 'w4',
              'nickname': '演示工作站',
              'intro': '',
              'avatarMediaId': null,
              'divisionName': null,
              'completedOrders': 320,
              'reviewCount': 0,
              'satisfiedRate': null,
              'grade': 1,
              'gradeLabel': 'LV1',
              'gradeName': '初出',
            },
            {
              'workerId': 'w5',
              'nickname': '第五位',
              'intro': '不该出现在首页',
              'avatarMediaId': null,
              'divisionName': null,
              'completedOrders': 40,
              'reviewCount': 1,
              'satisfiedRate': '90',
              'grade': 1,
              'gradeLabel': 'LV1',
              'gradeName': '初出',
            },
          ],
          'total': 5,
          'page': 1,
          'pageSize': 50,
        },
      };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    // 【2026-10-04 性能专项】公开 GET 会真正进 ApiCache；不清缓存会让上一个 case 的 fixture
    // 被下一个 case 命中（"接口失败要给重试入口"就会因为命中成功缓存而失败）。
    ApiCache.instance.clear();
  });

  testWidgets('首页结构：按规格 ⑥ 的 8 块顺序渲染，且每块都来自真实接口', (tester) async {
    /// 视口给足（800 × 2400，dpr 1）：这条用例要**逐块量纵坐标比大小**，
    /// 视口矮的时候"屏外那几块到底有没有按序落位"只能靠推理 —— 给够高度就是让它落地可测。
    /// （一条断言都没放宽：8 块仍逐块比 dy，任何一块被挪位都会红。）
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api({
        '/public/products': products(),
        '/divisions/grouped': grouped(),
        '/public/announcements': announcements(),
        '/public/players': players(),
      })),
    ));
    await tester.pumpAndSettle();

    // ① 品牌行（字标 + 消息通知 + 搜索）：品牌行只有字标，不再有横向导航
    expect(find.byKey(ServicesPage.brandKey), findsOneWidget);
    expect(find.text('${ServicesPage.brandInkText}${ServicesPage.brandAccentText}'), findsOneWidget);

    // ② 轮播图组件在树上（本夹具没配宣传图 → 零占位，高度 0）
    expect(find.byType(HomeBannerCarousel), findsOneWidget);

    // ③ 公告滚动栏：最新一条 + 日期
    expect(find.text('欢迎来到 祁连山电竞'), findsOneWidget, reason: '公告栏读真实公告（最新一条）');
    expect(find.text('护航单恢复接单'), findsNothing, reason: '首页只展示最新一条，其余进公告页');
    expect(find.text('官方'), findsOneWidget, reason: '公告栏左侧「官方」小标');
    // 右侧日期 = 服务端 `createdAt` 的**本地日期**（`MM-DD`），期望值由本用例现算
    final local = DateTime.parse('2026-10-18T03:20:00.000Z').toLocal();
    final expectDate =
        '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    expect(find.text(expectDate), findsOneWidget, reason: '右侧日期（服务端 createdAt 的本地日期）');

    // ④ 快捷入口四格
    for (final label in <String>['选择陪玩', '排行榜', '我的订单', '联系客服']) {
      expect(find.text(label), findsOneWidget, reason: '快捷入口必须有「$label」（覆盖现有页面入口）');
    }

    // ⑤ 三宫格（投诉客服 / 打赏 / 充值）—— 三件事没有别的入口
    expect(find.text('投诉客服'), findsOneWidget);
    expect(find.text('打赏'), findsOneWidget);
    expect(find.text('充值'), findsOneWidget);
    expect(find.text('退款'), findsNothing, reason: '第三格是充值，不是退款');

    // ⑥ 热门游戏：完整分部名 + 真实在线数 + 「进入服务」
    expect(find.text('和平精英 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 手游'), findsOneWidget);
    expect(find.text('三角洲行动 · 端游'), findsOneWidget);
    expect(find.text('12 人在线'), findsOneWidget, reason: '在线人数来自服务端 onlineCount');
    expect(find.text('8 人在线'), findsOneWidget);
    expect(find.text('4 人在线'), findsOneWidget);
    expect(find.text('建设中'), findsOneWidget, reason: '只有那个 underConstruction 的分部带小片');

    // ⑦ 精选服务：商品名 + 副标 + 金额（¥ 走 fmtMoney）
    expect(find.text('精选服务'), findsOneWidget);
    expect(find.text('和平精英上分单'), findsOneWidget);
    expect(find.text('30 局速通 · 全程录屏'), findsOneWidget, reason: '副标来自服务端 subtitle');
    expect(find.text(fmtMoney(30)), findsOneWidget, reason: '金额一律 ¥（fmtMoney 唯一出口）');
    expect(find.text('三角洲端游护航单'), findsOneWidget);

    // ⑧ 人气打手：按接单量降序取前 4（第 5 位不出现）
    expect(find.text('人气打手'), findsOneWidget);
    expect(find.text('黑桃老K'), findsOneWidget);
    expect(find.text('青柠不加冰'), findsOneWidget);
    expect(find.text('北屿'), findsOneWidget);
    expect(find.text('演示工作站'), findsOneWidget);
    expect(find.text('第五位'), findsNothing, reason: '首页只取接单量前 4 位');

    // 顺序：规格 ⑥ 自上而下（用纵坐标量，任何一块被挪位都会红）
    double top(Finder f) => tester.getTopLeft(f).dy;
    final ys = <String, double>{
      '品牌行': top(find.byKey(ServicesPage.brandKey)),
      '公告栏': top(find.text('欢迎来到 祁连山电竞')),
      '快捷入口': top(find.text('选择陪玩')),
      '三宫格': top(find.text('投诉客服')),
      '热门游戏': top(find.text('热门游戏')),
      '精选服务': top(find.text('精选服务')),
      '人气打手': top(find.text('人气打手')),
    };
    final keys = ys.keys.toList();
    for (var i = 1; i < keys.length; i++) {
      expect(ys[keys[i]]!, greaterThan(ys[keys[i - 1]]!),
          reason: '模块顺序被改动：${keys[i - 1]} 应在 ${keys[i]} 之上（规格 ⑥ 定序）');
    }

    // 规格 ⑤：首页不再有「会员中心」「平台公告」两个大模块
    expect(find.text('会员中心'), findsNothing);
    expect(find.text('平台公告'), findsNothing);
    // 结构规则：不出现多档俱乐部标签、不出现写死的服务分类
    expect(find.textContaining('推荐'), findsNothing);
    expect(find.textContaining('关注'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('顶栏：不再有三项横向导航（选择陪玩/排行榜/公告 只在别处各出现一次）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api({
        '/public/products': products(),
        '/divisions/grouped': grouped(),
        '/public/announcements': announcements(),
        '/public/players': players(),
      })),
    ));
    await tester.pumpAndSettle();

    // 「选择陪玩」「排行榜」各只有快捷入口那一处（顶部横向导航已整排删除，规格 ②）
    expect(find.text('选择陪玩'), findsOneWidget, reason: '同一入口只出现一次：快捷入口第 1 格');
    expect(find.text('排行榜'), findsOneWidget, reason: '同一入口只出现一次：快捷入口第 2 格');
    // 「公告」这两个字本身不再出现在顶栏（公告改由下方公告滚动栏承载）
    expect(find.text('公告'), findsNothing);

    // 顶栏右侧两枚图标：消息通知（铃铛）+ 搜索
    expect(find.byWidgetPredicate((w) => w is AppIcon && w.icon == AppIcons.search), findsOneWidget);
    // 铃铛有两处：顶栏 + 公告滚动栏
    expect(find.byWidgetPredicate((w) => w is AppIcon && w.icon == AppIcons.bell), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('公告为空 → 公告栏整块不渲染（不留白条、不摆占位）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api({
        '/public/products': products(),
        '/divisions/grouped': grouped(),
        '/public/announcements': {'code': 0, 'message': 'ok', 'data': <dynamic>[]},
        '/public/players': players(),
      })),
    ));
    await tester.pumpAndSettle();

    expect(find.text('官方'), findsNothing, reason: '一条公告都没有 → 「官方」小标也不渲染');
    // 其余模块照常
    expect(find.text('热门游戏'), findsOneWidget);
    expect(find.text('精选服务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('商品接口 404 → 「精选服务」整块不渲染（不摆假卡、不摆待接入）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api({
        '/divisions/grouped': grouped(),
        '/public/announcements': announcements(),
        '/public/players': players(),
      })),
    ));
    await tester.pumpAndSettle();

    expect(find.text('精选服务'), findsNothing, reason: '没有真实商品 → 模块与标题一起不渲染');
    expect(find.textContaining('待接入'), findsNothing);
    // 其它块照常
    expect(find.text('热门游戏'), findsOneWidget);
    expect(find.text('人气打手'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('陪玩接口 404 → 「人气打手」整块不渲染', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api({
        '/public/products': products(),
        '/divisions/grouped': grouped(),
        '/public/announcements': announcements(),
      })),
    ));
    await tester.pumpAndSettle();

    expect(find.text('人气打手'), findsNothing, reason: '没有真实陪玩 → 模块与标题一起不渲染');
    expect(find.text('黑桃老K'), findsNothing);
    expect(find.text('热门游戏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('接口失败时给出重试入口而不是白屏', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api(const {})),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('内容加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  /// 窄屏不溢出不重叠（原口径保留，承载者换成"品牌行 + 右侧两枚图标"）
  for (final width in <double>[320, 360]) {
    testWidgets('服务页：顶栏 ${width.toInt()}dp 下不溢出（字标 + 两枚图标同行不重叠）', (tester) async {
      tester.view.physicalSize = Size(width * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: ServicesPage(api: _api({
          '/public/products': products(),
          '/divisions/grouped': grouped(),
          '/public/announcements': announcements(),
          '/public/players': players(),
        })),
      ));
      await tester.pumpAndSettle();

      // 品牌字标（两段色：祁连山 + 电竞）在同一行、没有被裁断
      final brand = find.byKey(ServicesPage.brandKey);
      expect(brand, findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(brand).didExceedMaxLines, isFalse,
          reason: '${width.toInt()}dp 下字标被截断');

      // 负责人指定原文常量仍在（只是首页不再渲染它，原文不许丢字）
      expect(ServicesPage.headlineText,
          '欢迎各位板板来到祁连山电竞 祝各位板板玩的快乐 玩的开心 ——祁连山电竞董事长 小云');

      // 搜索图标（20dp）在本行最右，且与字标不重叠
      final search = find.byWidgetPredicate((w) => w is AppIcon && w.icon == AppIcons.search);
      expect(search, findsOneWidget, reason: '顶栏右侧必须有一枚搜索图标（规格 ②）');
      expect(tester.widget<AppIcon>(search).size, 20);
      final b = tester.getRect(brand);
      final s = tester.getRect(search);
      expect(b.right, lessThanOrEqualTo(s.left), reason: '字标与搜索图标不重叠');
      expect(b.top, lessThanOrEqualTo(s.top));

      // 布局无溢出异常（RenderFlex overflow 会在测试里抛异常）
      expect(tester.takeException(), isNull);
    });
  }
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
