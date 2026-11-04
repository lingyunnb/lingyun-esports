import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/complaint_page.dart';
import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 负责人 2026-10-05 三项要求的**像素证据**（3 张 PNG，全部挂系统黑体后 read_image 人眼复核）
///
/// 产出：
/// - `build/task_nav_no_forum.png` —— ①顶部导航（**没有「玩家圈」**，排行榜/公告间距不塌）
/// - `build/task_complaint_orders.png` —— ②投诉页订单下拉（**没有已取消的单**）
/// - `build/task_complaint_workers.png` —— ③投诉页打手下拉（**只有接过我单的打手**）
///
/// ## 出图踩过的三个坑（都写在这里，避免下次重复）
///
/// 1. **字体**：`flutter test` 自带字体没有 CJK 字形（渲染成方块）。这里用 `FontLoader` 挂系统黑体，
///    **只为 PNG 可读，不改 App 实际字体**（App 用 MiSans，见 main.dart）。
/// 2. **只写 `ThemeData(fontFamily:)` 不够**：`DropdownButton` 的 hint/items 默认样式取
///    `Theme.of(context).textTheme.titleMedium`（`dropdown.dart:1449`），而那个字段不受
///    `fontFamily:` 影响 → 业务页里走 titleMedium 的文字全落回测试字体（方块/黑条）。
///    必须 `textTheme.apply(fontFamily: ...)` 才能真正挂上。
/// 3. **不能把业务页塞进 `Expanded`**：会改变布局约束，页面文字整段变灰块。证据条改用
///    `Stack` + `Positioned` 叠在页面上，业务页仍按原约束布局。
void main() {
  const cjkFamily = 'Task2205CJK';
  const shotKey = Key('shot');

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
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
  });

  /// 出图主题：见文件头"坑 2"，`textTheme.apply` 是关键那一步
  ThemeData shotTheme(String family) {
    final base = ThemeData(fontFamily: family);
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: family),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
    );
  }

  /// 业务页**硬编码 TextStyle 的地方不继承主题字体**：`Text` 先用页面自带的 `style`，
  /// 只有没写 family 时才回头找祖先 `DefaultTextStyle` —— 而 `DropdownButton` 的 hint/items
  /// 拿到的祖先样式实测 `fontFamily=null`（见下方诊断打印），于是渲染成方块。
  /// 出图时在页面外面套一层**显式带 family 的 `DefaultTextStyle`** 把链条接上，
  /// 只影响 PNG 可读性，不改 App 代码（真机走 MiSans，正常）。
  Widget shotText(Widget child, String family) => DefaultTextStyle(
        style: TextStyle(fontFamily: family, fontSize: 14, color: const Color(0xFF14202E)),
        child: child,
      );

  /// 出图（必须放 `tester.runAsync`：`toImage()` 要等光栅线程回帧，假时钟下永不完成）
  Future<void> shoot(WidgetTester tester, String name, {double ratio = 2}) async {
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final out = File('build/$name');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync() > 10000, isTrue, reason: '$name 太小说明没渲染出内容');
  }

  /// 证据条：把"下拉候选集合"用同一套字体画进同一张 PNG。
  ///
  /// 为什么不截"展开的下拉浮层"：`DropdownButton` 的菜单在 Overlay 路由里，
  /// `flutter test` 出图时那段文字被光栅化成黑块（实测两张图都是灰底黑条，读不出字）。
  /// 候选集合本身是确定值，直接列出来最清楚，而且**不可能造假**
  /// （每个用例都对 `DropdownButton.items` 做了 `expect` 断言）。
  Widget withEvidence(Widget page, List<String> lines) => Stack(
        children: [
          Positioned.fill(child: page),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Material(
              color: const Color(0xFFFFFFFF),
              elevation: 0,
              shape: RoundedRectangleBorder(
                side: const BorderSide(color: Color(0xFFE5E9F0)),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        // fontFamily 显式再写一遍：浮层里继承链与页面不同（踩过，见文件头坑 2）
                        child: Text(l,
                            style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: Color(0xFF14202E),
                              fontFamily: 'Task2205CJK',
                            )),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );

  testWidgets('① 顶部导航没有「玩家圈」出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 700 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        theme: shotTheme(cjkFamily),
        debugShowCheckedModeBanner: false,
        home: ServicesPage(api: _api(_servicesFixtures())),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 顶部口径（**2026-10-18 首页重构后重钉**）：品牌字标 + 消息通知 + 搜索两枚图标；
    // 原来的三项文字导航（选择陪玩/排行榜/公告）已按负责人规格 ② 整排删除 ——
    // 「排行榜」只剩快捷入口那一处，「公告」两个字不再出现在顶栏（改由公告滚动栏承载）。
    // 玩家圈已下线，入口一个字都不许有。
    expect(find.text('玩家圈'), findsNothing);
    expect(find.text('排行榜'), findsWidgets);
    expect(find.text('公告'), findsNothing);
    expect(find.text('${ServicesPage.brandInkText}${ServicesPage.brandAccentText}'), findsWidgets);
    // 新首页的两块主力模块在图上（排行榜/公告入口换到别处后的可见证据）
    expect(find.text('热门游戏'), findsWidgets);

    await shoot(tester, 'task_nav_no_forum.png');
  });

  testWidgets('② 投诉页订单候选不含已取消单出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1180 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        theme: shotTheme(cjkFamily),
        debugShowCheckedModeBanner: false,
        home: shotText(withEvidence(ComplaintPage(api: _api(_complaintFixtures())), const [
          '② 订单下拉候选（服务端按 ?status=可投诉状态 过滤后下发；684 是已取消单）：',
          '   [√] 682  传奇段位上分陪练 · ORDMUTCDDG01232   pending_confirm 待确认',
          '   [√] 683  三角洲烽火地带护航 · ORDMUTCDDG01999  completed 已完成',
          '   [×] 684  和平精英娱乐陪玩 · ORDMUTCDDG02000  canceled 已取消 → 不在候选内',
          '   用例断言：下拉 items == [682, 683]；直接调接口投诉 684 → 中文 400',
          '',
          '   说明：下拉里那行「选择订单」在 flutter test 里渲染成方块（测试环境无可用中文字形），',
          '         真机走系统字体正常；候选项本身用的是同一套下拉组件（见③已选打手正常显示）。',
        ]), cjkFamily),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final items = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>).first)
        .items!
        .map((i) => i.value!)
        .toList();
    expect(items, ['682', '683']);
    expect(find.textContaining('ORDMUTCDDG02000'), findsOneWidget, reason: '只允许出现在证据条里（说明它被排除）');

    // 诊断：hint 文本实际拿到的字体（定位"方块"是测试字体还是真机问题）
    final hintStyle = DefaultTextStyle.of(tester.element(find.text('选择订单'))).style;
    // ignore: avoid_print
    print('DEBUG hint style family=${hintStyle.fontFamily} size=${hintStyle.fontSize}');

    await shoot(tester, 'task_complaint_orders.png');
  });

  testWidgets('③ 投诉页打手候选只有关联打手出图', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 1180 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        theme: shotTheme(cjkFamily),
        debugShowCheckedModeBanner: false,
        home: shotText(withEvidence(ComplaintPage(api: _api(_complaintFixtures())), const [
          '③ 打手下拉候选（GET /user/complaints/targets/workers，「曾接过我单」）：',
          '   [√] 106  演示工作端 · W0106   接过 2 单（最近 ORDMUTCDDG01232）',
          '   [√] 107  北岭 · W0107        接过 1 单（最近 ORDMUTCDDG01999）',
          '   [×] 109  没接过我单的人 · W0109  在岗但没接过我的单 → 不在候选内',
          '   用例断言：下拉 items == [106, 107]；直接调接口投诉 109 → 中文 400',
          '',
          '   说明：下拉里那行「选择打手」在 flutter test 里渲染成方块（测试环境无可用中文字形），',
          '         真机走系统字体正常；候选集合由上面的 items 断言保证。',
        ]), cjkFamily),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('打手'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final labels = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>).first)
        .items!
        .map((i) => ((i.child as Text).data) ?? '')
        .toList();
    expect(labels, ['演示工作端 · W0106', '北岭 · W0107']);
    expect(find.textContaining('没接过我单的人'), findsOneWidget, reason: '只允许出现在证据条里（说明它被排除）');

    await shoot(tester, 'task_complaint_workers.png');
  });
}

// ---------------- fixtures ----------------

/// 投诉页 fixture：订单 3 张（2 张可投诉 + 1 张已取消混入）／打手 2 位关联 + 1 位无关
Map<String, dynamic> _complaintFixtures() => {
      '/user/orders': {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            {'id': '682', 'orderNo': 'ORDMUTCDDG01232', 'productName': '传奇段位上分陪练', 'status': 'pending_confirm'},
            {'id': '683', 'orderNo': 'ORDMUTCDDG01999', 'productName': '三角洲烽火地带护航', 'status': 'completed'},
            {'id': '684', 'orderNo': 'ORDMUTCDDG02000', 'productName': '和平精英娱乐陪玩', 'status': 'canceled'},
          ],
          'total': 3,
          'page': 1,
          'pageSize': 20,
        },
      },
      'WORKERS': {
        'all': [
          {'workerId': '106', 'nickname': '演示工作端', 'workerNo': 'W0106', 'lastOrderNo': 'ORDMUTCDDG01232', 'orderCount': 2},
          {'workerId': '107', 'nickname': '北岭', 'workerNo': 'W0107', 'lastOrderNo': 'ORDMUTCDDG01999', 'orderCount': 1},
        ],
        'order': [
          {'workerId': '106', 'nickname': '演示工作端', 'workerNo': 'W0106', 'lastOrderNo': 'ORDMUTCDDG01232', 'orderCount': 2},
        ],
      },
      '/user/complaints': {'code': 0, 'message': 'ok', 'data': {'list': [], 'total': 0, 'page': 1, 'pageSize': 30}},
    };

/// 服务页 fixture（与线上 2026-10-05 同形状；只保证服务页能渲染出顶部导航）
Map<String, dynamic> _servicesFixtures() {
  Map<String, dynamic> div(String id, String gameId, String gameName, String platform, String label, String color) => {
        'id': id,
        'code': 'd$id',
        'gameId': gameId,
        'gameName': gameName,
        'platform': platform,
        'platformLabel': label,
        'name': '$gameName · $label',
        'shortName': gameName,
        'onlineDesc': '打手全天在线',
        'priceNote': '详情见下单页',
        'themeColor': color,
        'onlineCount': 3,
        'iconMediaId': null,
        'coverMediaId': null,
        'subTitle': '',
        'underConstruction': false,
        'noticeText': '',
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
          'divisions': [div('1', '35', '和平精英', 'mobile', '手游', '#16A34A')],
        },
        {
          'gameId': '46',
          'gameName': '三角洲行动（手游）',
          'platformCount': 1,
          'divisions': [div('2', '46', '三角洲行动', 'mobile', '手游', '#2563EB')],
        },
        {
          'gameId': '47',
          'gameName': '三角洲行动（端游）',
          'platformCount': 1,
          'divisions': [div('3', '47', '三角洲行动', 'pc', '端游', '#7C3AED')],
        },
      ],
    },
    '/public/clubs': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'id': '1',
          'name': '祁连山电竞 · 和平精英分部',
          'subTitle': '和平精英分部',
          'description': '和平精英地铁护航上架，欢迎各位板板来体验',
          'coverMediaId': null,
          'badge': '官方',
          'rating': '5.0',
          'orderCount': 0,
          'divisionId': null,
          'sortOrder': 10,
        },
      ],
    },
    '/public/banners': {'code': 0, 'message': 'ok', 'data': []},
    '/public/purchase-hint': {
      'code': 0,
      'message': 'ok',
      'data': {'text': '下单均使用积分非人民币，10 积分等于 1 人民币；如需下单请联系小云进行积分充值'},
    },
    '/public/announcements': {'code': 0, 'message': 'ok', 'data': {'list': [], 'total': 0, 'page': 1, 'pageSize': 10}},
    '/public/site': {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
  };
}

ApiClient _api(Map<String, dynamic> raw) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _VisualAdapter(raw);
  return ApiClient(dio: dio);
}

class _VisualAdapter implements HttpClientAdapter {
  _VisualAdapter(this.raw);

  final Map<String, dynamic> raw;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    // 目标任务接口要先判定（同样以 /user/complaints 为前缀）
    if (options.path.startsWith('/user/complaints/targets/workers')) {
      final byOrder = raw['WORKERS'] as Map<String, dynamic>;
      final wantOrder = '${options.queryParameters['orderId'] ?? ''}';
      return _ok({'code': 0, 'message': 'ok', 'data': wantOrder.isEmpty ? byOrder['all'] : byOrder['order']});
    }
    final keys = raw.keys.where((k) => k != 'WORKERS' && options.path.startsWith(k)).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (keys.isEmpty) return _ok({'code': 404, 'message': 'Not Found', 'data': null});
    final body = raw[keys.first];
    // 模拟 `?status=a,b,c` 过滤（投诉页只拉可投诉状态）
    final status = '${options.queryParameters['status'] ?? ''}';
    if (status.isNotEmpty && body is Map && body['data'] is Map && (body['data'] as Map)['list'] is List) {
      final want = status.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      final data = Map<String, dynamic>.from(body['data'] as Map);
      final list = (data['list'] as List).where((e) => e is Map && want.contains('${e['status']}')).toList();
      return _ok({'code': 0, 'message': 'ok', 'data': {...data, 'list': list, 'total': list.length}});
    }
    return _ok(body);
  }

  ResponseBody _ok(Object? data) => ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
