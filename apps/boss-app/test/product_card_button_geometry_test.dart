import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/product_detail_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品卡「下单」按钮的**测量口径 + 几何不变量**（把"按钮偏移 < 20"这条真检查钉在正确的位置上）
///
/// ## 为什么单开一个文件（2026-10-11 实测，别删）
/// `product_order_button_visual_test.dart` 的出图①原来用 `find.text('下单').first` 取按钮，
/// 而卡片矩形取的是**目标商品那张卡**。目标商品一旦不在列表第一位，两个矩形就来自**两张不同的卡**：
/// `card.bottom - button.bottom` 变成"卡与卡之间的距离"（实测 **151** = 卡高 123 + 卡间距 10 + 卡内边距 18）,
/// 量到的根本不是"按钮与它自己那张卡"的关系 —— 断言仍然红/绿，但它已经在量别的东西了。
///
/// 本文件做两件事：
/// 1. **钉死测量口径**：按钮一律 `find.descendant(of: 目标卡, ...)` 取，并显式断言"别张卡的按钮
///    不落在目标卡矩形里"（跨卡测量一定在这里露出来）；
/// 2. **不依赖线上 3100**：目录（商品名/顺序/条数）全用 fixture 固定 —— 线上商品被改名、被挪位置、
///    被新商品顶到前面，本文件一条都不受影响（出图文件负责"线上真实数据下的 PNG 证据"，本文件负责
///    "任意目录形态下的不变量"，两份分工互补）。
///
/// ## 断言的有效范围（1 行名卡不在内，别误读）
/// 「偏移 < 20」= `card.bottom - button.bottom` ≈ 卡片内边距 10 + 按钮自身内边距 7，成立前提是
/// **卡高由文字列决定**（名字 ≥ 2 行时内容列 > 74dp 封面）。1 行短名的卡高由 74dp 封面决定，
/// 按钮贴的是内容列底部（实测 ~26，不是内容挤压）—— 线上目录 8 件商品全 ≥ 2 行，故 fixture 用 2/3/4 行档。
void main() {
  const divisionId = '1';
  const gameId = '35';
  const categoryId = '78';

  /// 四件商品的**名字长度覆盖 2 / 3 / 4 行**（与线上目录同一批真实商品名，字形宽度差异不影响判定：
  /// 只要 ≥2 行，内容列就高于 74dp 封面）
  const name2Lines = '18.8保500w（送7级套➕aug）';
  const name3Lines = '基础保底700w和小云单挑 打赢加1000w打输不加';
  const name4Lines = '44.6博弈鹰雕单（出反现小金人+金aug）不出保1200w[老板必须全程录屏不录开出不算]';
  const name3LinesB = '36.6博弈宝冠单（出返现小金人+金aug）不出保888w';

  Map<String, dynamic> product(String id, String name) => <String, dynamic>{
        'id': id,
        'name': name,
        'subtitle': '',
        'listName': null,
        'badgeText': null,
        'weeklyLimit': null,
        'weeklyLimitByQuantity': 0,
        'gameId': gameId,
        'divisionId': divisionId,
        'categoryId': categoryId,
        'price': 9.9,
        'priceUnit': '单',
        'estimateDurationMin': 30,
        'serviceStatus': 1,
        'salesCount': 0,
        'coverMediaId': null,
        'coverUrl': null,
      };

  /// 线上目录的形态：4 件商品，名字分别 3 / 4 / 2 / 3 行
  List<Map<String, dynamic>> catalog() => <Map<String, dynamic>>[
        product('101', name3Lines),
        product('102', name4Lines),
        product('103', name2Lines),
        product('104', name3LinesB),
      ];

  /// 详情页形状：列表字段的超集 + 详情页自己回源的字段（字段名与真实响应对齐）
  Map<String, dynamic> detailOf(Map<String, dynamic> item) => <String, dynamic>{
        ...item,
        'status': 1,
        'description': 'fixture 商品说明（按单计价）',
        'detail': null,
        'serviceFlow': null,
        'serviceRules': null,
        'attention': null,
        'orderNotice': null,
        'effectiveOrderNotice': '第一条须知：请确认游戏分区与游戏 ID 填写正确。\n第二条须知：未接单可随时取消。',
        'orderNoticeInherited': true,
        'orderPendingTakeTimeoutHours': 24,
        'divisionPlatformLabel': '手游',
        'media': <dynamic>[],
      };

  Map<String, Map<String, dynamic>> fixtureOf(List<Map<String, dynamic>> list) => <String, Map<String, dynamic>>{
        '/divisions': <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <dynamic>[
            <String, dynamic>{
              'id': divisionId,
              'code': 'peace_mobile',
              'name': '和平精英 · 手游',
              'shortName': '和平精英',
              'gameId': gameId,
              'gameName': '和平精英',
              'platform': 'mobile',
              'platformLabel': '手游',
              'themeColor': '#2563EB',
              'iconMediaId': null,
              'coverMediaId': null,
              'underConstruction': false,
              'noticeText': '',
            },
          ],
        },
        '/public/categories': <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <dynamic>[
            <String, dynamic>{'id': categoryId, 'gameId': gameId, 'name': '常规单'},
          ],
        },
        '/public/products': <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <String, dynamic>{'list': list, 'total': list.length, 'page': 1, 'pageSize': 50},
        },
        '/public/purchase-hint': <String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <String, dynamic>{'text': '下单均使用余额，余额不足请联系客服充值。'},
        },
        // 未登录态：限购提示不出现（限购不在本文件范围内，另有专门用例）
        '/user/orders/weekly-quota': <String, dynamic>{'code': 401, 'message': '未登录', 'data': null},
        for (final Map<String, dynamic> item in list)
          '/public/products/${item['id']}': <String, dynamic>{'code': 0, 'message': 'ok', 'data': detailOf(item)},
      };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
  });

  /// 390×844 真机画布（与出图文件同尺寸）+ 有界 pump（页面里有入场动画，**不用 pumpAndSettle**）
  Future<void> pumpList(WidgetTester tester, Map<String, Map<String, dynamic>> fixture) async {
    ApiCache.instance.clear(); // 同一用例里多次 pump 时，缓存会把"换过顺序的目录"顶掉
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ProductListPage(api: _api(fixture), initialDivisionId: divisionId),
    ));
    // StaggeredItem 的入场动画（错峰 + 上移 8px）必须跑完：中途量到的是被 SlideTransition 位移过的矩形
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(tester.takeException(), isNull);
  }

  /// 某件商品在列表页里的**那张卡**（按卡片显示名定位）
  Finder cardOf(String name) =>
      find.ancestor(of: find.text(name), matching: find.byType(AppCard)).first;

  /// **目标卡自己的**「下单」按钮（`rectOf` 要求 finder 恰好命中一个 → `.first`）
  Finder buttonOf(Finder card) =>
      find.descendant(of: card, matching: find.text('下单')).first;

  Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

  String trailing(double gap) => gap.toStringAsFixed(1);

  // ---------------- ① 首卡：按钮在卡内、贴卡底 ----------------

  testWidgets('① 首卡：按钮在卡片内、贴卡底（偏移 < 20）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final card = cardOf(name3Lines);
    final c = rectOf(tester, card);
    final b = rectOf(tester, find.descendant(of: card, matching: find.text('下单')).first);
    // ignore: avoid_print
    print('DBG ① card=$c button=$b gap=${c.bottom - b.bottom}');

    expect(b.top, greaterThanOrEqualTo(c.top), reason: '按钮在卡片内（没被上方内容挤出卡片顶部）');
    expect(b.bottom, lessThanOrEqualTo(c.bottom + 0.5), reason: '按钮不溢出卡片下沿');
    expect(c.bottom - b.bottom, lessThan(20),
        reason: '按钮贴在卡片底部（实测 ${trailing(c.bottom - b.bottom)}；被上方内容挤下去就会变大）');
  });

  // ---------------- ② 首卡：按钮贴右、在右半侧 ----------------

  testWidgets('② 首卡：按钮贴卡片右侧且在右半侧（右留白 = 卡内边距 10 + 按钮内边距 14 = 24）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final card = cardOf(name3Lines);
    final c = rectOf(tester, card);
    final b = rectOf(tester, find.descendant(of: card, matching: find.text('下单')).first);

    expect(c.right - b.right, lessThan(30),
        reason: '按钮贴右（实测留白 ${trailing(c.right - b.right)} = 卡片内边距 10 + 按钮内边距 14）');
    expect(b.right, greaterThan(c.center.dx), reason: '按钮在卡片右半侧（右下角，不是左下角）');
    expect(b.left, greaterThan(c.left), reason: '按钮不越出卡片左沿');
  });

  // ---------------- ③ 跨卡不串（151 那条假红的成因，本文件的重点）----------------

  testWidgets('③ 第 2 张卡的按钮必须取自第 2 张卡 —— 别张卡的按钮不落在它里面', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final c1 = rectOf(tester, cardOf(name3Lines));
    final b1 = rectOf(tester, buttonOf(cardOf(name3Lines)));
    final c2 = rectOf(tester, cardOf(name4Lines));
    final b2 = rectOf(tester, buttonOf(cardOf(name4Lines)));
    // ignore: avoid_print
    print('DBG ③ card1=$c1 button1=$b1 | card2=$c2 button2=$b2 '
        'crossCardGap=${c2.bottom - b1.bottom} ownCardGap=${c2.bottom - b2.bottom}');

    expect(b1, isNot(b2), reason: '两张卡的按钮不是同一个矩形');
    expect(c1.bottom, lessThan(c2.top), reason: '两张卡是上下两张（不是同一张卡的两半）');
    expect(c2.contains(b1.center), isFalse,
        reason: '第 1 张卡的按钮**不在**第 2 张卡里面（拿 A 卡的按钮量 B 卡，一定会在这里露出来）');
    // 跨卡相减正是 151 那条假红：它的数值与"按钮本身"无关 → 必须比卡内偏移大得多
    expect(c2.bottom - b1.bottom, greaterThan(20),
        reason: '跨卡距离必然 > 卡内偏移（这就是它不能用来当"按钮贴卡底"证据的原因）');
    expect(c2.bottom - b2.bottom, lessThan(20),
        reason: '第 2 张卡自己的按钮仍贴第 2 张卡底（实测 ${trailing(c2.bottom - b2.bottom)}）');
  });

  // ---------------- ④ 顺序无关：同一件商品排在第 1/2/3 位，卡内偏移逐值相等 ----------------

  testWidgets('④ 顺序无关：同一件商品排在第 1/2/3 位，卡内偏移逐值相等且都 < 20', (tester) async {
    final target = product('101', name3Lines);
    final others = <Map<String, dynamic>>[
      product('102', name4Lines),
      product('103', name2Lines),
      product('104', name3LinesB),
    ];

    final gaps = <double>[];
    for (final index in <int>[0, 1, 2]) {
      final list = <Map<String, dynamic>>[...others]..insert(index, target);
      await pumpList(tester, fixtureOf(list));
      final card = cardOf(name3Lines);
      final c = rectOf(tester, card);
      final b = rectOf(tester, buttonOf(card));
      gaps.add(c.bottom - b.bottom);
    }
    // ignore: avoid_print
    print('DBG ④ gaps@position1/2/3 = ${gaps.map(trailing).toList()}');

    expect(gaps.every((g) => g < 20), isTrue,
        reason: '三个位置的卡内偏移都要 < 20（实测 ${gaps.map(trailing).toList()}）');
    expect(gaps.toSet().length, 1,
        reason: '同一件商品在不同位置的卡内偏移**逐值相等**（实测 ${gaps.map(trailing).toList()}）'
            '—— 用例结论不该随"这件商品排第几"变化');
  });

  // ---------------- ⑤ 全卡遍历：每张卡的按钮都贴自己卡底 ----------------

  testWidgets('⑤ 遍历首屏每一张商品卡：它自己的「下单」按钮都在卡内且贴自己卡底（偏移 < 20）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final count = find.byType(AppCard).evaluate().length;
    expect(count, greaterThanOrEqualTo(3), reason: '首屏至少要渲染出 3 张商品卡（实测 $count）');
    final gaps = <String, double>{};
    for (var i = 0; i < count; i++) {
      final card = find.byType(AppCard).at(i);
      final c = tester.getRect(card);
      final b = tester.getRect(find.descendant(of: card, matching: find.text('下单')).first);
      expect(b.bottom, lessThanOrEqualTo(c.bottom + 0.5), reason: '第 ${i + 1} 张卡：按钮不溢出卡下沿');
      expect(b.top, greaterThanOrEqualTo(c.top), reason: '第 ${i + 1} 张卡：按钮不越出卡上沿');
      gaps['#${i + 1}'] = c.bottom - b.bottom;
    }
    // ignore: avoid_print
    print('DBG ⑤ cards=$count gaps=$gaps');

    expect(gaps.values.every((g) => g < 20), isTrue,
        reason: '每张卡的按钮都贴自己卡底（实测 $gaps）—— 卡片高度随名字行数自适应，但按钮不许被挤下去');
  });

  // ---------------- ⑥ 4 行超长名：名字把卡片撑高，按钮仍在名字下方且贴卡底 ----------------

  testWidgets('⑥ 4 行超长名卡：按钮在名字下方（不被压住/重叠）且贴卡底（偏移 < 20）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final card = cardOf(name4Lines);
    final c = rectOf(tester, card);
    final b = rectOf(tester, buttonOf(card));
    final nameRect = tester.getRect(find.text(name4Lines));
    // ignore: avoid_print
    print('DBG ⑥ card=$c name=$nameRect button=$b gap=${c.bottom - b.bottom}');

    expect(nameRect.bottom, lessThanOrEqualTo(b.top + 0.5),
        reason: '按钮排在名字**下方**（名字撑高卡片也不会压到按钮）');
    expect(c.bottom - b.bottom, lessThan(20),
        reason: '长名卡里按钮仍贴卡底（实测 ${trailing(c.bottom - b.bottom)}）');
  });

  // ---------------- ⑦ 2 行短名：卡高由内容决定，按钮仍贴卡底 ----------------

  testWidgets('⑦ 2 行短名卡：按钮仍贴卡底（偏移 < 20）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final card = cardOf(name2Lines);
    final c = rectOf(tester, card);
    final b = rectOf(tester, buttonOf(card));
    // ignore: avoid_print
    print('DBG ⑦ card=$c button=$b gap=${c.bottom - b.bottom}');

    expect(c.bottom - b.bottom, lessThan(20),
        reason: '名字只有 2 行时内容列仍高于 74dp 封面 → 按钮照样贴卡底（实测 ${trailing(c.bottom - b.bottom)}）');
    expect(b.right, greaterThan(c.center.dx), reason: '短名卡里按钮同样在右下角');
  });

  // ---------------- ⑧ 卡片与按钮一一对应 ----------------

  testWidgets('⑧ 卡片与「下单」按钮一一对应：每张卡恰有一颗按钮（不重复、不遗漏）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    final cards = find.byType(AppCard).evaluate().length;
    expect(cards, greaterThanOrEqualTo(3), reason: '首屏至少要渲染出 3 张商品卡（实测 $cards）');
    expect(find.text('下单').evaluate().length, cards,
        reason: '「下单」按钮数必须 == 卡片数（实测 ${find.text('下单').evaluate().length} vs $cards）');
    for (var i = 0; i < cards; i++) {
      expect(find.descendant(of: find.byType(AppCard).at(i), matching: find.text('下单')).evaluate().length, 1,
          reason: '第 ${i + 1} 张卡恰有一颗「下单」（按钮与卡一一对应是"卡内测量"能成立的前提）');
    }
  });

  // ---------------- ⑨ 点第 2 张卡的按钮 → 进第 2 张卡的商品 ----------------

  testWidgets('⑨ 点第 2 张卡的「下单」→ 详情页是第 2 张卡的商品（点了哪件就进哪件）', (tester) async {
    final list = catalog();
    await pumpList(tester, fixtureOf(list));

    await tester.tap(buttonOf(cardOf(name4Lines)));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.byType(ProductDetailPage), findsOneWidget, reason: '点「下单」进商品详情页');
    expect(find.text(name4Lines), findsWidgets, reason: '详情页 = 第 2 张卡的商品');
    expect(find.text(name3Lines), findsNothing,
        reason: '不是第 1 张卡的商品（点错卡的按钮就会跳到这里）—— 列表页那条路由已 offstage');
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
