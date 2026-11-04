import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/division_construction_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 分部「建设中」态（负责人 2026-10-05：瓦端 = 无畏契约端游 / 瓦手 = 无畏契约手游）
///
/// 需求原文：
/// > 增加**瓦端（无畏契约端游）**和**瓦手（无畏契约手游）**，但是用户点开先显示
/// > **该分部正在建设中，敬请期待**；本分部大力招人，有意联系本人 **q：3989032755**
///
/// 本文件覆盖四条验收（对应交付要求 3 的①②③④）：
/// ① 建设中的分部卡显示「建设中」标识（细描边小片），且不再显示在线绿点/人数；
/// ② 点建设中分部 → **进建设中页**，页面文案**逐字等于接口下发的 noticeText**；
/// ③ 非建设中分部 → **仍然进商品列表**（回归，一行原逻辑都没改）；
/// ④ 服务端把 `underConstruction` 切成 false（= DB 里 under_construction=0）→ **无需改代码**自动恢复进商品列表。
///
/// ②里「文案来自接口而非硬编码」的证明方式：fixture 里的 QQ 号是 **1234567890**，
/// 与负责人真实号码 3989032755 **故意不同** —— 一旦客户端哪天把号码写死，断言必然失败。
void main() {
  /// 5 个分部（生产现状：3 旧 + 瓦端 + 瓦手），后两个建设中
  Map<String, dynamic> groupedFixture({bool valiantUnderConstruction = true}) => {
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
                'underConstruction': false,
                'noticeText': null,
              },
            ],
          },
          {
            'gameId': '46',
            'gameName': '三角洲行动（手游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '2',
                'code': 'delta_mobile',
                'gameId': '46',
                'gameName': '三角洲行动（手游）',
                'platform': 'mobile',
                'platformLabel': '手游',
                'name': '三角洲行动 · 手游',
                'shortName': '三角洲行动',
                'onlineDesc': '平均 5 分钟内接单',
                'themeColor': '#2563EB',
                'sortOrder': 20,
                'onlineCount': 8,
                'underConstruction': false,
              },
            ],
          },
          {
            'gameId': '47',
            'gameName': '三角洲行动（端游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '3',
                'code': 'delta_pc',
                'gameId': '47',
                'gameName': '三角洲行动（端游）',
                'platform': 'pc',
                'platformLabel': '端游',
                'name': '三角洲行动 · 端游',
                'shortName': '三角洲行动',
                'onlineDesc': '平均 6 分钟内接单',
                'themeColor': '#7C3AED',
                'sortOrder': 30,
                'onlineCount': 4,
                'underConstruction': false,
              },
            ],
          },
          {
            'gameId': '48',
            'gameName': '无畏契约（端游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '5',
                'code': 'valorant_pc',
                'gameId': '48',
                'gameName': '无畏契约（端游）',
                'platform': 'pc',
                'platformLabel': '端游',
                'name': '无畏契约 · 端游',
                'shortName': '无畏契约',
                'onlineDesc': '招募中',
                'themeColor': '#DC2626',
                'sortOrder': 40,
                'onlineCount': 0,
                'underConstruction': valiantUnderConstruction,
                'noticeText': valiantUnderConstruction ? kServerNotice : '',
              },
            ],
          },
          {
            'gameId': '49',
            'gameName': '无畏契约（手游）',
            'platformCount': 1,
            'divisions': [
              {
                'id': '6',
                'code': 'valorant_mobile',
                'gameId': '49',
                'gameName': '无畏契约（手游）',
                'platform': 'mobile',
                'platformLabel': '手游',
                'name': '无畏契约 · 手游',
                'shortName': '无畏契约',
                'onlineDesc': '招募中',
                'themeColor': '#0D9488',
                'sortOrder': 50,
                'onlineCount': 0,
                'underConstruction': true,
                'noticeText': kServerNotice,
              },
            ],
          },
        ],
      };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
  });

  testWidgets('① 建设中分部在分类 Tab 上带「建设中」标识（其他分部不受影响）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures(groupedFixture())))));
    await tester.pumpAndSettle();

    // 5 个分部全部渲染（旧 3 个 + 瓦端 + 瓦手）—— 方案 G：分部渲染成**分类 Tab**
    expect(find.text('和平精英'), findsOneWidget);
    expect(find.text('三角洲行动'), findsNWidgets(2));
    expect(find.text('无畏契约'), findsNWidgets(2));
    // 只有新增的两个分部带「建设中」小片
    // 【负责人 2026-10-17】「精选服务」下面是分部卡列表 → 小片在**分类 Tab + 分部卡**两处出现
    // （2 个建设中分部 × 2 处 = 4；改动前只有 Tab 一处 = 2）
    expect(find.text('建设中'), findsNWidgets(4));
    // 5 个分部挤一行横向滚动：不能有 RenderFlex 溢出
    expect(tester.takeException(), isNull);
  });

  testWidgets('② 点建设中分部 → 建设中页，文案逐字取自接口（含 QQ 号，非硬编码）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures(groupedFixture())))));
    await tester.pumpAndSettle();

    // 点「瓦端」（半宽卡里的第一个「无畏契约」= valorant_pc）
    final card = find.text('无畏契约').at(0);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();

    // 进的是建设中页（页头是**服务端下发的完整分部名**）
    // 断言一律用 descendant 收口到新页，避免把仍在树上的服务页文本算进来
    final page = find.byType(DivisionUnderConstructionPage);
    expect(page, findsOneWidget);
    expect(find.descendant(of: page, matching: find.text('建设中')), findsOneWidget);
    // 完整分部名只在页头出现一次（内容区用简称 + 平台标签，不重复堆字）
    expect(find.descendant(of: page, matching: find.text('无畏契约 · 端游')), findsOneWidget);
    expect(find.descendant(of: page, matching: find.text('无畏契约')), findsOneWidget);
    expect(find.descendant(of: page, matching: find.text('端游')), findsOneWidget);
    // 没进商品列表
    expect(find.byType(ProductListPage), findsNothing);
    expect(find.text('选择服务'), findsNothing);

    // 文案 = 接口下发的 noticeText（逐字，含换行）
    final notice = tester
        .widget<SelectableText>(find.descendant(of: page, matching: find.byType(SelectableText)))
        .data;
    expect(notice, kServerNotice);
    // 证明不是硬编码：fixture 号码 ≠ 负责人真实号码，页面必须显示 fixture 的号码
    expect(notice, contains('QQ：1234567890'));
    expect(notice, isNot(contains('3989032755')));
    expect(notice, contains('本分部正在建设中，敬请期待。'));

    // 有返回/换分部出口（「看看其他分部」按钮）
    expect(find.descendant(of: page, matching: find.text('看看其他分部')), findsOneWidget);
  });

  testWidgets('③ 非建设中分部：点 Tab 切到该分部的货架（不再整页跳走）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final navKey = GlobalKey<NavigatorState>();
    final apis = _fixtures(groupedFixture());
    String? tapped;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: ServicesPage(
        api: _api(apis),
        onGoOrder: (id) {
          tapped = id;
          navKey.currentState!.push(MaterialPageRoute<void>(
            builder: (_) => ProductListPage(api: _api(apis), initialDivisionId: id),
          ));
        },
      ),
    ));
    await tester.pumpAndSettle();

    final tab = find.text('三角洲行动').at(0);
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();

    // 【方案 G 2026-10-17】分类 Tab 的语义 = **切首页货架**（不发 onGoOrder、不 push 整页）；
    // 选中态 = 加粗（首项「祁连山官方」的加粗随即转移到被点的这一项）
    expect(tapped, isNull, reason: '点 Tab 不再跳商品列表页');
    expect(find.byType(ProductListPage), findsNothing);
    expect(find.byType(DivisionUnderConstructionPage), findsNothing);
    expect(tester.widget<Text>(find.text('三角洲行动').at(0)).style!.fontWeight, FontWeight.w800,
        reason: '被点的 Tab 必须变成选中态');
    expect(tester.takeException(), isNull);
  });

  testWidgets('④ under_construction=0 → 该分部 Tab 自动恢复成可切换（不再进建设中页）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // 服务端把瓦端的开关切成 0（fixture 等价于把 DB 的 under_construction 改成 0）
    final apis = _fixtures(groupedFixture(valiantUnderConstruction: false));
    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(apis))));
    await tester.pumpAndSettle();

    // 瓦端不再有建设中标识（瓦手仍在建设中 → 分类 Tab + 分部卡各 1 = 2）
    expect(find.text('建设中'), findsNWidgets(2));

    final tab = find.text('无畏契约').at(0);
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();

    // 同一处入口，只是服务端开关不同 → 走的是"切货架"这条路（不进建设中页）
    expect(find.byType(DivisionUnderConstructionPage), findsNothing);
    expect(tester.widget<Text>(find.text('无畏契约').at(0)).style!.fontWeight, FontWeight.w800);
    expect(tester.takeException(), isNull);
  });

  testWidgets('④ 结构守卫：旧「选择分部」卡区仍不存在；分部以 Tab + 分部卡两条导航并存', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures(groupedFixture())))));
    await tester.pumpAndSettle();

    // 旧结构的三件签名：分区标题「选择分部」、在线人数行、建设中中性说明
    expect(find.text('选择分部'), findsNothing, reason: '旧「选择分部」卡区已移除（负责人 2026-10-17 方案 G 定案）');
    expect(find.textContaining('人在线'), findsNothing, reason: '首页不再逐分部列在线人数');
    expect(find.text('敬请期待'), findsNothing);
    /**
     * 【负责人 2026-10-17 二次修订】「精选服务」下面**恢复**成分部卡列表（每行 图 + 名 + 一句话 + 箭头），
     * 因此分部现在有**两条导航**：分类 Tab（顶部筛选）与分部卡（正文导航）。
     * 5 个分部 × 2 处 = 「无畏契约」出现 4 次（瓦端 + 瓦手，各两处）。
     * 注意这不是"同一入口出现两次"：Tab 是**筛选**、卡是**去哪下单**，两者分工不同。
     */
    expect(find.text('祁连山官方'), findsWidgets);
    // 分部卡的标题是**完整名**（`无畏契约 · 端游`），所以精确 `无畏契约` 仍只在 Tab 行里出现 2 次
    expect(find.text('无畏契约'), findsNWidgets(2));
    expect(find.text('无畏契约 · 端游'), findsOneWidget, reason: '分部卡用完整名（手机/端游可区分）');
    expect(find.text('无畏契约 · 手游'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('兜底：直接打开建设中分部的商品列表页 → 内容区也是建设中（不是空货架）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: ProductListPage(api: _api(_fixtures(groupedFixture())), initialDivisionId: '5'),
    ));
    await tester.pumpAndSettle();

    final notice = tester.widget<SelectableText>(find.byType(SelectableText)).data;
    expect(notice, kServerNotice);
    expect(notice, contains('QQ：1234567890'));
    // 不显示空货架、也不显示排序行
    expect(find.text('该分类暂无商品'), findsNothing);
    expect(find.text('综合'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端文案为空 → 只显示兜底文案（不含任何联系方式）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: DivisionUnderConstructionPage(
        name: '无畏契约 · 手游',
        shortName: '无畏契约',
        platform: 'mobile',
        platformLabel: '手游',
        gameKey: 'valorant_mobile',
        themeColor: '#0D9488',
        noticeText: '',
      ),
    ));
    await tester.pumpAndSettle();

    final notice = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(notice, DivisionUnderConstructionView.fallbackNotice);
    expect(notice, isNot(contains('3989032755')));
    expect(notice, isNot(contains('QQ')));
  });
}

/// 接口下发的建设中提示文案（fixture）；QQ 号**故意与负责人真实号码不同**，
/// 用来证明页面上的号码来自接口而不是客户端硬编码。
const String kServerNotice = '本分部正在建设中，敬请期待。\n本分部大力招人，有意者请联系本人 QQ：1234567890';

Map<String, Map<String, dynamic>> _fixtures(Map<String, dynamic> grouped) => {
      '/public/clubs': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'id': '1',
            'name': '祁连山电竞 · 官方自营',
            'subTitle': '',
            'description': '和平精英与三角洲行动全段位上分与护航',
            'coverMediaId': null,
            'badge': '官方',
            'rating': '',
            'orderCount': 0,
            'divisionId': null,
          },
        ],
      },
      '/divisions/grouped': grouped,
      '/divisions': {
        'code': 0,
        'message': 'ok',
        'data': (grouped['data'] as List).expand((g) => (g as Map)['divisions'] as List).toList(),
      },
      '/public/categories': {'code': 0, 'message': 'ok', 'data': <dynamic>[]},
      '/public/products': {
        'code': 0,
        'message': 'ok',
        'data': {'list': <dynamic>[], 'total': 0},
      },
      '/public/site': {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
    };

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
