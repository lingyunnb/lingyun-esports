import 'dart:convert';
import 'dart:io';

import 'package:boss_app/pages/product_list_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「购买提示」小字回归（负责人 2026-10-05）
///
/// 需求原文：
/// > 「在选择服务那里加一行小字：下单均使用积分非人民币 10 积分等于 1 人民币，
/// >   如需下单请联系小云进行积分充值」
///
/// 本文件锁死四件事（对应负责人要求的验收口径）：
///  ① **接口有文案 → 渲染该文案**（逐字等于服务端 `GET /public/purchase-hint` 的 `data.text`，
///    含「10 积分等于 1 人民币」这段钱相关口径）；
///  ② **接口为空 / 接口不可用 → 整行不渲染**（不是渲染空行、更不是回退到客户端硬编码）；
///  ③ **长文案 2 行内不截断**：`maxLines == 2` 且 **不是 `ellipsis`**（负责人：不许截断），
///    正式默认文案在 360×780 真机逻辑尺寸下 `didExceedMaxLines == false`（真的显示全了）；
///  ④ 换一份服务端文案 → 页面显示新文案（**证明客户端没有硬编码**：库里改完即生效，App 不发版）。
///
/// 断言一律用 `RenderParagraph.didExceedMaxLines` / `visibleLinesOf` 而不是只看 `maxLines` 数字：
/// 后者在字号或宽度变化时会变成假绿（既有 `product_name_truncation_test.dart` 同一口径）。
///
/// 字体：`flutter test` 自带字体没有中文字形、且每个字形按 1em 方块排版，
/// 不挂真字体会量出**假的行数结论** —— 与既有出图/截断测试同样挂系统黑体。
void main() {
  Map<String, dynamic> envelope(Object? data) => {'code': 0, 'message': 'ok', 'data': data};

  const cjkFamily = 'PurchaseHintCJK';

  /// 负责人原文（**已按负责人要求订正错别字「人名币」→「人民币」**）= 服务端迁移 1800000000000 写库的默认值。
  /// 客户端**不存这份文案**，这里只是"服务端应该下发什么"的期望值。
  const bossDefaultHint = '下单均使用积分非人民币，10 积分等于 1 人民币；如需下单请联系小云进行积分充值';

  const divisionId = '1';
  const gameId = '35';

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
    {'id': '44', 'gameId': gameId, 'name': '段位上分'},
  ];
  final products = [
    {
      'id': '1',
      'name': '野区爆红单15.88',
      'price': 158.8,
      'priceUnit': '单',
      'salesCount': 4,
      'coverMediaId': null,
      'coverUrl': null,
      'categoryId': '44',
      'divisionId': divisionId,
    },
  ];

  /// fixture：`hint` 为 null 表示**服务端没有这个接口**（老版本后端 / 迁移没跑）
  Map<String, Map<String, dynamic>> fixture({String? hint, bool underConstruction = false}) => {
        '/divisions': envelope([
          {...divisions.first, if (underConstruction) 'underConstruction': 1},
        ]),
        '/public/categories': envelope(categories),
        '/public/products': envelope({'list': products, 'total': 1}),
        if (hint != null) '/public/purchase-hint': envelope({'text': hint}),
      };

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

  setUp(() {
    ApiClient.cacheEnabled = false; // 单测关接口缓存：每个用例都真的走 fixture
    ApiCache.instance.clear();
  });

  /// 真机尺寸 360×780（默认测试画布 800 宽会让这行字"一行放得下"，测不出 2 行口径）
  Future<void> pumpPhone(WidgetTester tester, Map<String, Map<String, dynamic>> raw) async {
    tester.view.physicalSize = const Size(360 * 3, 780 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: cjkFamily),
      home: ProductListPage(api: _api(raw)),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  /// 提示行文本（在底部提示条内），拿不到说明整行没渲染
  Finder hintTextFinder(String text) =>
      find.descendant(of: find.byKey(purchaseHintBarKey), matching: find.text(text));

  RenderParagraph hintParagraph(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.descendant(of: hintTextFinder(text), matching: find.byType(RichText)));

  /// 可见行数（`getBoxesForSelection` 会把被省略掉的行也算进来，不能用来数可见行）
  int visibleLinesOf(RenderParagraph para) => (para.size.height / (11.5 * 1.45)).round();

  // ---------------- ① 接口有文案 → 渲染该文案 ----------------

  testWidgets('① 接口下发文案 → 底部渲染该文案，且逐字来自接口（含「10 积分等于 1 人民币」）', (tester) async {
    await pumpPhone(tester, fixture(hint: bossDefaultHint));

    expect(tester.takeException(), isNull);
    expect(find.byKey(purchaseHintBarKey), findsOneWidget, reason: '接口有文案 → 这一行必须渲染');
    expect(hintTextFinder(bossDefaultHint), findsOneWidget, reason: '渲染的必须是接口下发的那份文案（逐字）');
    // 钱相关口径必须在画面里（负责人原文里的关键信息）
    expect(find.textContaining('10 积分等于 1 人民币'), findsOneWidget);
    expect(find.textContaining('小云'), findsOneWidget, reason: '充值联系人来自服务端文案');
  });

  testWidgets('①-b 样式：11.5px / 次要色 / 不加粗 / 无图标 / 无彩色底 / 顶部发丝线', (tester) async {
    await pumpPhone(tester, fixture(hint: bossDefaultHint));

    final t = tester.widget<Text>(hintTextFinder(bossDefaultHint));
    expect(t.style?.fontSize, 11.5, reason: 'docs/21：小字 11.5 号');
    expect(t.style?.color, AppColors.textSecondary, reason: '次要色 #475569（11.5px 下要看得清充值联系人）');
    expect(t.style?.fontWeight == null || t.style?.fontWeight == FontWeight.w400, isTrue, reason: '不许加粗');
    expect(t.textAlign, isNot(TextAlign.center), reason: 'docs/21：左对齐为主');

    // 无图标、无彩色底：条内不得出现 Icon；底色必须与**页面 Scaffold 底色**一致
    //（结构性证明"不是彩色条/卡片底"，比写死某个色值更抗主题切换：初始主题/液态玻璃都成立）
    expect(find.descendant(of: find.byKey(purchaseHintBarKey), matching: find.byType(Icon)), findsNothing,
        reason: '不许配图标（docs/21 禁 emoji/装饰图标）');
    final box = tester.widget<Container>(find.byKey(purchaseHintBarKey));
    final deco = box.decoration as BoxDecoration;
    final pageScaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(deco.color, pageScaffold.backgroundColor, reason: '与页面同底色 → 不是彩色底、不是卡片底');
    // 发丝线：默认主题下 = #E2E8F0（列表分隔一律用发丝线，不用阴影）
    expect((deco.border as Border?)?.top.color, T.divider, reason: '上方一条发丝线分隔');
    expect((deco.border as Border?)?.top.width, 1, reason: '发丝线 1px');
  });

  // ---------------- ② 接口空 / 拿不到 → 整行不渲染 ----------------

  testWidgets('② 接口文案为空串 → 【整行不渲染】（不是空行留白）', (tester) async {
    await pumpPhone(tester, fixture(hint: ''));

    expect(tester.takeException(), isNull);
    expect(find.byKey(purchaseHintBarKey), findsNothing, reason: '空串 = 运营主动关闭这行 → 整个条都不该构造');
    expect(find.textContaining('积分充值'), findsNothing, reason: '画面上不该残留任何提示文字');
    expect(find.textContaining('小云'), findsNothing, reason: '更不许回退到客户端硬编码的兜底文案');
    // 列表本体不受影响（这一行的有无不影响商品展示）
    expect(find.text('野区爆红单15.88'), findsOneWidget);
  });

  testWidgets('②-b 接口不可用（404：老后端/迁移没跑）→ 整行不渲染且页面不报错', (tester) async {
    await pumpPhone(tester, fixture(hint: null)); // fixture 里没有 /public/purchase-hint → 适配器回 404

    expect(tester.takeException(), isNull, reason: '这一行取不到**不能**把整页拖成错误页');
    expect(find.byKey(purchaseHintBarKey), findsNothing);
    expect(find.textContaining('小云'), findsNothing);
    expect(find.text('野区爆红单15.88'), findsOneWidget, reason: '商品列表照常渲染');
  });

  testWidgets('②-c 建设中分部 → 不渲染（那种分部不能下单，显示"请充值下单"自相矛盾）', (tester) async {
    await pumpPhone(tester, fixture(hint: bossDefaultHint, underConstruction: true));

    expect(tester.takeException(), isNull);
    expect(find.byKey(purchaseHintBarKey), findsNothing);
  });

  // ---------------- ③ 长文案 2 行内不截断（maxLines==2 且无 ellipsis）----------------

  testWidgets('③ 正式默认文案：2 行内完整显示（maxLines==2、无 ellipsis、didExceedMaxLines=false）', (tester) async {
    await pumpPhone(tester, fixture(hint: bossDefaultHint));

    final t = tester.widget<Text>(hintTextFinder(bossDefaultHint));
    expect(t.maxLines, 2, reason: '负责人定案：长文案允许 2 行');
    expect(t.overflow, isNot(TextOverflow.ellipsis), reason: '不许截断 → 绝不能是省略号');
    expect(t.overflow, TextOverflow.fade, reason: '万一超 2 行用淡出收口，也绝不出现「…」');

    final para = hintParagraph(tester, bossDefaultHint);
    expect(para.didExceedMaxLines, isFalse, reason: '正式文案在 360dp 机型上真的显示全了（不是被切掉）');
    expect(visibleLinesOf(para), lessThanOrEqualTo(2), reason: '占用不超过 2 行');
    expect(visibleLinesOf(para), 2, reason: '41 字文案在 328dp 可用宽下正好 2 行（1 行放不下）');
  });

  testWidgets('③-b 更长的运营文案（49 字）仍在 2 行内完整显示', (tester) async {
    const longer = '下单均使用积分非人民币，10 积分等于 1 人民币；如需下单请联系小云进行积分充值（充值后即时到账）';
    await pumpPhone(tester, fixture(hint: longer));

    final para = hintParagraph(tester, longer);
    expect(para.didExceedMaxLines, isFalse, reason: '2 行容得下 49 字，不需要截断');
    expect(visibleLinesOf(para), lessThanOrEqualTo(2));
  });

  testWidgets('③-c 极端超长文案（200 字上限）：结构上仍是 2 行 + 无省略号', (tester) async {
    final huge = '下单均使用积分非人民币，10 积分等于 1 人民币；如需下单请联系小云进行积分充值。' * 5;
    await pumpPhone(tester, fixture(hint: huge));

    final t = tester.widget<Text>(hintTextFinder(huge));
    expect(t.maxLines, 2, reason: '硬上限 2 行（页面不被一行小字撑高）');
    expect(t.overflow, isNot(TextOverflow.ellipsis), reason: '即使超长也不许出现省略号');
  });

  // ---------------- ④ 无硬编码证据：服务端换文案 → 页面就换 ----------------

  testWidgets('④ 服务端换一份文案 → 页面显示新的那份（客户端零硬编码）', (tester) async {
    const opsText = '积分充值请联系值班客服（10 积分 = 1 元，以到账为准）';
    await pumpPhone(tester, fixture(hint: opsText));

    expect(hintTextFinder(opsText), findsOneWidget, reason: '显示服务端当前文案');
    expect(find.textContaining('小云'), findsNothing, reason: '旧文案（含联系人）一个字都不该残留');
    expect(find.textContaining(bossDefaultHint), findsNothing, reason: '客户端里不存在写死的默认文案');
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
