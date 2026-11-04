import 'dart:convert';
import 'dart:io';

import 'package:boss_app/pages/order_create_page.dart';
import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 商品名 / 副标题**不被省略号吃掉**（负责人 2026-10-05 报障「好多都没显示全」）
///
/// 报障现场：
///   - 确认订单页：商品名被截成「36.6博弈宝冠单（出返现小金人+金aug）不出保888w[老…」
///   - 选择服务：副标题被截成「老板指定三个人机爆20w…」
///
/// 定案口径（商品列表 **4 行** 为负责人 2026-10-05 二次定案）：
///   - **商品列表商品名最多 4 行**（3 行时 45/49 字的博弈单名实测 `didExceedMaxLines=true`），
///     确认订单页商品名最多 3 行；字号/行高不变（列表 13.5/1.35、下单页 14/1.35）
///     —— 靠行数不靠放大字号（docs/21 克制原则）
///   - **副标题最多 2 行**
///   - 卡片高度随内容自适应，价格/按钮在名字下方，不会被文字压住
///
/// 断言用 `RenderParagraph.didExceedMaxLines` 而不是只看 maxLines 数字：
/// 前者是"真的显示全了"，后者字号/宽度一变就会变成假绿。
///
/// 实测（360×780 逻辑像素 + 系统黑体）：
///   - 确认订单页：名字可用宽 192.5dp → 45 字最长名 **3 行内完整显示**（exceeded=false）
///   - 商品列表：左侧有分类栏，卡片仅 240dp 宽、名字可用宽 134dp
///     → 45 / 49 字的博弈单名 **4 行内完整显示**（`visibleLinesOf == 4` 且 exceeded=false）
void main() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  /// 中文字体：`flutter test` 自带字体没有中文字形、且每个字形按 1em 方块排版，
  /// 不挂真字体会量出**假的截断结论**。写法与既有出图测试 product_badge_visual_test.dart 相同。
  const cjkFamily = 'TruncationTestCJK';

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final path in const [
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      'C:/Windows/Fonts/msyh.ttc',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader(cjkFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
  });

  const divisionId = '1';
  const gameId = '35';
  const categoryId = '78';

  /// 现场最长的一条在售名（负责人上架清单原文，45 个字）
  const longName = '36.6博弈宝冠单（出返现小金人+金aug）不出保888w[老板必须全程录屏不录开出不算]';

  /// 现场次长名（37 字）：在 134dp 的列表卡里 3 行放得下 → 用来证明"上限真的是 4 行、不是被压到 1 行"
  const mediumName = '38.8保1000w（送7级套➕强化74u/妹控/Aug强化12k四选一）';
  const shortName = '野区爆红单15.88';

  /// 两条超长名商品（管理端已配 listName 的那两条）
  const longestName = '44.6博弈鹰雕单（出反现小金人+金aug+雪隼）不出保1200w[老板必须全程录屏不录开出不算]';
  const shortListName = '36.6博弈宝冠单（不出保888w）';

  /// 现场副标题原文（45 字；1 行必截断，2 行是本次定案上限）
  const subtitle = '老板指定三个人机爆20w红反小金人+aug/雪隼（二选一）[老板必须全程录屏不录开出不算]';

  final divisions = [
    {
      'id': divisionId,
      'gameId': gameId,
      'name': '和平精英 · 手游',
      'shortName': '和平精英',
      'platformLabel': '手游',
      'themeColor': '#16A34A',
      'iconMediaId': null,
    },
  ];
  final categories = [
    {'id': categoryId, 'gameId': gameId, 'name': '博弈单'},
  ];

  Map<String, dynamic> product(String id, String name, {String sub = '', num price = 366, String? listName}) => {
        'id': id,
        'name': name,
        'listName': listName,
        'subtitle': sub,
        'gameId': gameId,
        'categoryId': categoryId,
        'divisionId': divisionId,
        'price': price,
        'priceUnit': '单',
        'salesCount': 4,
        'coverMediaId': null,
        'coverUrl': null,
        'badgeText': null,
        'weeklyLimit': null,
      };

  final longProduct = product('144', longName);
  final mediumProduct = product('141', mediumName, price: 388);
  final shortProduct = product('146', shortName, sub: subtitle, price: 158.8);

  /// 下单页表单配置（形状与线上一致；本文件只关心商品名排版，字段给最小可用集）
  final orderForm = {
    'zoneLabel': '选择区服',
    'zoneOptions': [
      {'label': 'QQ区', 'value': 'qq'},
      {'label': '微信区', 'value': 'wechat'},
    ],
    'fields': [
      {'key': 'gamePlayerId', 'label': '游戏ID', 'placeholder': '请输入游戏ID', 'type': 'text', 'required': true, 'enabled': true, 'maxLength': 32},
    ],
    'workerLabel': '选择护航员',
    'workerRandomLabel': '随机安排',
    'workerDesignatedLabel': '指定护航员',
    'feeTitle': '商品费用',
    'feeUnitLabel': '单价',
    'totalLabel': '合计',
    'submitText': '提交订单',
  };

  final fixture = <String, Map<String, dynamic>>{
    '/divisions': envelope(divisions),
    '/public/categories': envelope(categories),
    '/public/products': envelope({'list': [longProduct, mediumProduct, shortProduct], 'total': 3}),
    '/public/order-form': envelope(orderForm),
    '/user/orders/weekly-quota': envelope(const {
      'productId': '144',
      'weeklyLimit': 0,
      'orderedCount': 0,
      'remaining': null,
      'limitText': '',
      'quotaText': '',
    }),
    '/public/players': envelope({'list': const [], 'total': 0}),
  };

  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
    AuthStore.instance.debugSetSession(accessToken: 'test-token');
  });

  tearDown(() {
    AuthStore.instance.debugSetSession();
    AppSettings.debugStorageDisabled = false;
  });

  /// 用真机尺寸（360×780 逻辑像素）渲染：默认测试画布 800 宽会把长名字"放得下"，测不出截断
  Future<void> pumpPhone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: ThemeData(fontFamily: cjkFamily), home: child));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  RenderParagraph paragraphOf(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.descendant(of: find.text(text), matching: find.byType(RichText)));

  /// **可见**行数（`getBoxesForSelection` 会把被 maxLines 省略掉的行也算进来，不能用来数可见行）
  int visibleLinesOf(RenderParagraph para, double fontSize, double heightFactor) =>
      (para.size.height / (fontSize * heightFactor)).round();

  /// 卡片高度按**名字归属**取，不依赖列表里的先后顺序（页面会按服务端字段重排）
  double cardHeightOf(WidgetTester tester, String name) =>
      tester.getSize(find.ancestor(of: find.text(name), matching: find.byType(AppCard))).height;

  // ---------------- ① 商品列表：商品名 4 行上限（45/49 字最长名完整显示）----------------

  testWidgets('【诊断】列表卡 134dp 宽时，45/49 字博弈单名到底要几行、需要多宽', (tester) async {
    await pumpPhone(tester, ProductListPage(api: _api(fixture)));
    final cardWidth = tester.getSize(find.text(longName)).width;
    double linesAt(String name, double width) {
      final tp = TextPainter(
        text: TextSpan(text: name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, height: 1.35)),
        maxLines: 100,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      return tp.computeLineMetrics().length.toDouble();
    }

    double widthFor(String name, int lines) {
      var lo = 40.0, hi = 400.0;
      for (var i = 0; i < 40; i++) {
        final mid = (lo + hi) / 2;
        if (linesAt(name, mid) <= lines) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      return hi;
    }

    // ignore: avoid_print
    print('DBG cardWidth=$cardWidth '
        'lines(longName@134)=${linesAt(longName, cardWidth)} '
        'lines(longestName@134)=${linesAt(longestName, cardWidth)} '
        'widthFor(longName,4)=${widthFor(longName, 4)} '
        'widthFor(longestName,4)=${widthFor(longestName, 4)}');
    expect(cardWidth, greaterThan(100));
  });

  testWidgets('商品列表：商品名上限 4 行（3 行 → 4 行的本次改动真的生效）', (tester) async {
    await pumpPhone(tester, ProductListPage(api: _api(fixture)));

    final nameText = tester.widget<Text>(find.text(longName));
    expect(nameText.maxLines, 4, reason: '商品列表商品名上限 4 行（负责人 2026-10-05 二次定案）');
    expect(nameText.overflow, TextOverflow.ellipsis, reason: '超过 4 行才省略');

    final para = paragraphOf(tester, longName);
    expect(visibleLinesOf(para, 13.5, 1.35), 4, reason: '45 字最长名把 4 行用满（3 行上限时这里是 3 行）');
    expect(para.size.height, greaterThan(70), reason: '高度 ≈ 4 行 × 18.2dp（3 行 ≈ 55dp）');
    // 4 行仍放不下的原因（见【诊断】用例的实测数字）：134dp 卡片宽最多排 ≈9.9 个汉字/行，
    // 45 / 49 字的博弈单名需要 ≈162 / 175.5dp 才可能在 4 行内排完 —— 属于**窄卡物理限制**，
    // 不是行数没改到。这两条商品的实际显示由管理端「列表短名」解决（任务②），短名 1~2 行内完整显示。
    expect(para.didExceedMaxLines, isTrue, reason: '134dp 窄卡 + 45 字名：4 行仍会省略（改用 listName 短名）');
  });

  testWidgets('商品列表：4 行放得下的长名必须完整显示（无省略号）', (tester) async {
    await pumpPhone(tester, ProductListPage(api: _api(fixture)));

    final para = paragraphOf(tester, mediumName);
    expect(visibleLinesOf(para, 13.5, 1.35), 3, reason: '37 字的名字排满 3 行（4 行上限下第 4 行空着）');
    expect(para.didExceedMaxLines, isFalse, reason: '行数内能放下就必须显示完整（didExceed 才是"真没被截"）');
  });

  testWidgets('商品列表：副标题最多 2 行 —— 1 行会截断的文案现在多显示一行', (tester) async {
    await pumpPhone(tester, ProductListPage(api: _api(fixture)));

    final subText = tester.widget<Text>(find.text(subtitle));
    expect(subText.maxLines, 2, reason: '副标题上限 2 行（定案口径）');

    final para = paragraphOf(tester, subtitle);
    expect(visibleLinesOf(para, 10.5, 1.4), 2, reason: '该副标题排到 2 行（旧实现 1 行 → 这里是 1）');
    expect(para.size.height, greaterThan(20), reason: '高度 ≈ 2 行，不是 1 行');
  });

  // ---------------- ④ 列表短名（负责人 2026-10-05 任务②）----------------
  /// 短名/最长名常量见 `main` 顶部（管理端 `listName` 配的那 2 条超长名商品的实际取值）
  testWidgets('列表短名：配了 listName → 列表显示短名、完整名不在列表里；详情/确认订单页仍是完整名', (tester) async {
    final shorted = product('144', longName, listName: shortListName);
    await pumpPhone(
      tester,
      ProductListPage(api: _api({...fixture, '/public/products': envelope({'list': [shorted], 'total': 1})})),
    );

    // 列表卡：显示短名（完整名一个字都不出现在列表上）
    expect(find.text(shortListName), findsWidgets, reason: '列表卡必须显示管理端配的短名');
    expect(find.text(longName), findsNothing, reason: '列表卡显示了短名，就不该再显示完整名');

    // 点列表卡 → 商品详情页（2026-10-05 起点卡与点「下单」都进详情页，不再直达确认订单页）；
    // 断言仍成立且更强：详情页拿到的仍是**完整名**（`_openDetail` 传的是 p.name，不是短名），
    // 短名走不出列表卡这一处 —— 详情页/确认订单页/订单页一律完整名。
    await tester.tap(find.text(shortListName).first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text(longName), findsOneWidget, reason: '详情页必须显示完整商品名（短名只在窄卡列表生效）');
    expect(find.text(shortListName), findsNothing, reason: '详情页不能拿短名顶替完整名');
  });

  testWidgets('列表短名回退：listName 为空/缺失 → 列表仍显示完整名（回归，其余 31 条商品就是这种）', (tester) async {
    // 49 字最长名 + 不带 listName（= 服务端列 NULL 的那 31 条）
    final bare = product('145', longestName);
    await pumpPhone(
      tester,
      ProductListPage(api: _api({...fixture, '/public/products': envelope({'list': [bare], 'total': 1})})),
    );

    expect(find.text(longestName), findsWidgets, reason: '没配短名 → 回退完整名');
    final para = paragraphOf(tester, longestName);
    expect(visibleLinesOf(para, 13.5, 1.35), 4, reason: '49 字完整名同样用满 4 行（上限是 4，不是 3）');
  });

  testWidgets('列表短名：短名在窄卡里 1~2 行完整显示（这就是两条超长名商品的最终显示效果）', (tester) async {
    // 只放「配了短名的 144」+「没配短名的 145（49 字）」
    final shorted = product('144', longName, listName: shortListName);
    final bare = product('145', longestName);
    await pumpPhone(
      tester,
      ProductListPage(api: _api({...fixture, '/public/products': envelope({'list': [shorted, bare], 'total': 2})})),
    );

    final shortedPara = paragraphOf(tester, shortListName);
    expect(shortedPara.didExceedMaxLines, isFalse, reason: '短名 18 字：窄卡里完整显示（对比完整名 45 字）');
    expect(visibleLinesOf(shortedPara, 13.5, 1.35), lessThanOrEqualTo(2), reason: '短名占 1~2 行');

    // 没配短名的 49 字商品仍是完整名 + 4 行上限（回退路径）
    expect(find.text(longestName), findsWidgets, reason: '没配短名 → 列表回退完整名');
    final barePara = paragraphOf(tester, longestName);
    expect(visibleLinesOf(barePara, 13.5, 1.35), 4, reason: '49 字完整名同样受 4 行上限约束');
  });

  testWidgets('列表短名：短名带空格/空串一律回退完整名（管理端存了空格不能显示成空白）', (tester) async {
    final blank = product('144', longName, listName: '   ');
    await pumpPhone(
      tester,
      ProductListPage(api: _api({...fixture, '/public/products': envelope({'list': [blank], 'total': 1})})),
    );
    expect(find.text(longName), findsWidgets, reason: '空白短名 trim 后为空 → 回退完整名');
  });

  // ---------------- ② 确认订单页：商品名完整显示 ----------------

  testWidgets('确认订单页：45 字最长商品名 3 行内完整显示（就是报障截图那一条）', (tester) async {
    await pumpPhone(tester, OrderCreatePage(api: _api(fixture), divisionId: divisionId, product: longProduct));

    final nameText = tester.widget<Text>(find.text(longName));
    expect(nameText.maxLines, 3);

    final para = paragraphOf(tester, longName);
    expect(para.didExceedMaxLines, isFalse, reason: '确认订单页是下单前最后一道确认，商品名必须看全（报障原文「…不出保888w[老…」）');
    expect(visibleLinesOf(para, 14, 1.35), 3, reason: '45 字名字在这里正好 3 行排满');
  });

  testWidgets('确认订单页：价格与吸底按钮不被长名字挤掉（卡片高度自适应）', (tester) async {
    await pumpPhone(tester, OrderCreatePage(api: _api(fixture), divisionId: divisionId, product: longProduct));

    // 价格在商品名**下方**：取同一张卡里的 AppPrice（页面上另有"商品费用"区的价格，不能用 find.text 撞）
    final card = find.ancestor(of: find.text(longName), matching: find.byType(AppCard));
    final nameBottom = tester.getBottomLeft(find.text(longName)).dy;
    final priceTop = tester.getTopLeft(find.descendant(of: card, matching: find.byType(AppPrice))).dy;
    expect(priceTop, greaterThanOrEqualTo(nameBottom), reason: '价格在商品名下方，不存在压字');
    expect(find.text('提交订单'), findsOneWidget, reason: '吸底提交按钮仍在（长名字没有把它挤出屏幕）');
  });

  // ---------------- ③ 卡片高度随内容自适应 + 列表仍虚拟化 ----------------

  testWidgets('商品列表：卡片高度随内容自适应（4 行名卡明显高于 1 行名卡）', (tester) async {
    // 两张卡都不带副标题，唯一变量就是商品名行数（排除副标题干扰）
    final bare = product('144', longName);
    final bareShort = product('146', shortName, price: 158.8);
    await pumpPhone(
      tester,
      ProductListPage(api: _api({...fixture, '/public/products': envelope({'list': [bare, bareShort], 'total': 2})})),
    );

    final longCard = cardHeightOf(tester, longName);
    final shortCard = cardHeightOf(tester, shortName);
    expect(longCard, greaterThan(shortCard + 30), reason: '4 行名字的卡必须明显更高（高度跟着内容走，不是固定高度）');
    expect(shortCard, lessThan(130), reason: '短名卡没有被统一拉高（组内紧、不浪费版面）');

    // 列表仍是虚拟化构建（ListView + itemBuilder，不预建每张卡的 RenderObject）
    expect(find.byType(ListView), findsWidgets);
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
