import 'dart:convert';
import 'dart:typed_data';

import 'package:boss_app/pages/services_page.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「快速下单」浮标（方案 E 胶囊 + 滚动收起）—— 任务① 回归测试
///
/// 三组断言，逐条对应设计稿 `site/design/order-fab/e-collapse-pill.html` 的硬要求：
/// 1. **几何**：128 × 44 胶囊 / r=22 / 热区 ≥48dp / **不与底栏中间凸起「祁小山」重叠**
///    （横向净距 24dp、纵向净距 16dp —— 设计稿"实测标注"一节的数字）
/// 2. **滚动收起**：向下滚动 → 收成 44 × 44；停止滚动 600ms → 展开回 128 × 44
/// 3. **手势**：浮标不吃列表纵向滚动；横滑（轮播）不受影响
void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  // -------------------------------------------------------------------
  // 1) 几何：纯常量（不依赖渲染，任何屏幕尺寸下都成立）
  // -------------------------------------------------------------------
  group('浮标几何（设计稿硬参数）', () {
    test('默认态 128 × 44 圆角 22（全圆胶囊）', () {
      expect(AppOrderFab.expandedWidth, 128);
      expect(AppOrderFab.height, 44);
      expect(AppOrderFab.radius, 22, reason: '全圆胶囊 r = 高/2');
      expect(AppOrderFab.collapsedWidth, 44, reason: '收起态只收宽度，高度不变');
    });

    test('触控热区 ≥ 48dp（视觉 44 时外层补 hot area）', () {
      expect(AppOrderFab.tapHeight, greaterThanOrEqualTo(48));
      expect(AppOrderFab.tapWidth, greaterThanOrEqualTo(48));
      // 视觉右缘仍按设计稿落在 16dp 处（热区比视觉宽 4dp，故 Positioned.right = 12）
      expect(AppOrderFab.right + AppOrderFab.tapPadding, 16);
    });

    test('390dp 屏：横向净距 24dp（与设计稿实测一致）', () {
      // 浮标视觉左缘 = 390 − 16 − 128 = 246；凸起右缘 = 195 + 27 = 222 → 24
      expect(AppOrderFab.visualLeft(390), 246);
      expect(AppOrderFab.bulgeClearance(390), 24);
    });

    test('纵向净距 16dp（浮标底边 ↔ 凸起顶边）', () {
      expect(AppOrderFab.bulgeVerticalClearance(), 16);
    });

    test('收起态不会因此靠近凸起（只收宽度，右缘与底边不动）', () {
      // 收起动画只改裁剪宽度 → 底边与右缘的常量一个都没变
      expect(AppOrderFab.bottom + AppOrderFab.tapPadding, AppOrderFab.visualBottomGap);
      // 收起后横向净距反而更大（浮标左缘右移 84dp）
      expect(390 - AppOrderFab.right - AppOrderFab.tapPadding - AppOrderFab.collapsedWidth - 222, greaterThan(24));
    });
  });

  // -------------------------------------------------------------------
  // 2) 与底栏凸起「祁小山」同屏渲染：矩形不相交（防"压住凸起"回归）
  // -------------------------------------------------------------------
  testWidgets('与底栏凸起同屏：两个矩形不相交，横向 ≥8dp、纵向 ≥8dp', (tester) async {
    // 与设计稿同框：390 × 844，底栏 60 + 手势条 24
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(bottom: 24 * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 24)),
        child: MaterialApp(
          home: Scaffold(
            // body 底边 = 底栏顶边（与真实 HomeShell 完全一致）
            body: Stack(children: [AppOrderFab(onTap: _noop)]),
            bottomNavigationBar: AppBottomNav(currentIndex: 0, onTap: _noopI, onCenterTap: _noop),
          ),
        ),
      ),
    );
    await tester.pump();

    final fabRect = tester.getRect(find.byKey(AppOrderFab.visualKey));
    // 凸起 ⌀54 在底栏 Stack 里：取底栏顶边，凸起顶边 = 底栏顶边 − 16
    final navRect = tester.getRect(find.byType(AppBottomNav));
    final bulgeTop = navRect.top - AppOrderFab.bulgeProtrusion;
    final bulgeLeft = 390 / 2 - AppOrderFab.bulgeDiameter / 2; // 168
    final bulgeRight = 390 / 2 + AppOrderFab.bulgeDiameter / 2; // 222
    final bulge = Rect.fromLTRB(bulgeLeft, bulgeTop, bulgeRight, bulgeTop + AppOrderFab.bulgeDiameter);

    // 尺寸逐项对齐设计稿
    expect(fabRect.width, 128);
    expect(fabRect.height, 44);
    expect(fabRect.right, 390 - 16, reason: '视觉右缘距屏幕右边 16dp');

    // 不相交（硬要求）
    expect(fabRect.overlaps(bulge), isFalse, reason: '浮标不得与凸起「祁小山」重叠');
    // 横向净距（浮标左缘 ↔ 凸起右缘）：设计稿 24dp
    expect(fabRect.left - bulge.right, closeTo(24, 0.01));
    // 纵向净距（浮标底边 ↔ 凸起顶边）：设计稿 16dp
    expect(bulge.top - fabRect.bottom, closeTo(16, 0.01));
    // 纵向让开兜底：至少 8dp
    expect(bulge.top - fabRect.bottom, greaterThanOrEqualTo(8));
  });

  testWidgets('大字号（1.3x）下浮标不溢出、不与凸起重叠', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(bottom: 24 * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(bottom: 24),
          textScaler: TextScaler.linear(1.3),
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(children: [AppOrderFab(onTap: _noop)]),
            bottomNavigationBar: AppBottomNav(currentIndex: 0, onTap: _noopI, onCenterTap: _noop),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '大字号不得触发 RenderFlex overflow');
    final fabRect = tester.getRect(find.byKey(AppOrderFab.visualKey));
    // 视觉尺寸不随字号变（文字用 softWrap:false，宽度由设计稿定死）
    expect(fabRect.width, 128);
    expect(fabRect.right, 390 - 16);
    final navRect = tester.getRect(find.byType(AppBottomNav));
    expect(navRect.top - AppOrderFab.bulgeProtrusion - fabRect.bottom, greaterThanOrEqualTo(8));
  });

  // -------------------------------------------------------------------
  // 3) 组件级：展开 / 收起由 expanded 驱动
  // -------------------------------------------------------------------
  testWidgets('AppOrderFab：expanded=false 收成 44dp 可见宽度，只剩图标', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Stack(children: [AppOrderFab(onTap: _noop, expanded: true)])),
    ));
    await tester.pump();
    expect(tester.getSize(find.byKey(AppOrderFab.visualKey)).width, 128);
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, 128);
    expect(find.text('快速下单'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Stack(children: [AppOrderFab(onTap: _noop, expanded: false)])),
    ));
    await tester.pumpAndSettle();

    // 【2026-10-05 第二轮·等价新断言】
    // 旧断言是「内部胶囊恒 128、由外层窗口裁」（= "半截蓝字"的结构来源），
    // 那个结构已被**故意删除**：现在宽度真正参与布局，所以胶囊宽度必须**自己**收到 44。
    // 断言强度没有降低 —— 反而从"裁窗口量到 44"升级为"胶囊本体量到 44"：
    // 若哪天退回"固定 128 内容 + 外层裁剪"，这一条会立刻失败。
    expect(tester.getSize(find.byKey(AppOrderFab.visualKey)).width, AppOrderFab.collapsedWidth,
        reason: '收起完成 → 胶囊本体宽度就是 44dp（不再靠外层窗口裁 128 的内容）');
    // **可见窗口**同样收成 44 —— 这是"看得见多少"的唯一真相（量 Align.widthFactor 曾经漏掉
    // "紧约束下 Align 自身不收"这个真 bug，所以这里直接量渲染宽度）
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).width, AppOrderFab.collapsedWidth,
        reason: '收起完成 → 可见窗口只剩 44dp');
    expect(tester.getSize(find.byKey(AppOrderFab.clipKey)).height, AppOrderFab.height);
    // 文字节点**已下树**（不是"被裁"）：`labelFadeEnd` 之内淡出到 0，
    // 到 t=1 时 Opacity 子树整段不建 → 结构上不可能留下半个字形
    expect(find.text('快速下单', skipOffstage: false), findsNothing,
        reason: '收起态文字必须不在树上（`op <= 0` 时整段不建），否则又会露"半截蓝字"');
    // 剩下的是**左侧的雪山标**（设计稿"收起只留图标"）
    expect(find.byType(AppMountainMark), findsOneWidget);
    // 热区不随视觉缩小
    expect(tester.getSize(find.byType(AppOrderFab)).width, AppOrderFab.tapWidth);
  });

  // -------------------------------------------------------------------
  // 4) 服务页：滚动 600ms → 收起；停止滚动 600ms → 展开（完整状态机）
  // -------------------------------------------------------------------
  testWidgets('服务页：向下滚动收起浮标，停止滚动 600ms 后展开', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures()))));
    await tester.pumpAndSettle();
    await _selectFirstDivision(tester);
    expect(_maxScrollExtent(tester), greaterThan(200), reason: '夹具内容要够长，否则本用例没有意义');

    AppOrderFab fab() => tester.widget<AppOrderFab>(find.byType(AppOrderFab));
    expect(fab().expanded, isTrue, reason: '静止态默认展开');

    // 向下滚一点（> 8dp 触发阈值）
    await _flingList(tester, const Offset(0, -60));
    expect(fab().expanded, isFalse, reason: '向下滚动 → 立即收起');
    // 收起动画走完
    await tester.pump(AppOrderFab.collapseDuration);
    // 【2026-10-05 第二轮·等价新断言】旧断言「文字节点仍在树上（被裁掉，不是被移除）」，
    // 但"被裁"正是真机上露出半个字形的根因；现在改成"淡出到 0 → 整段不建"。
    // 这一条同时钉住 `labelFadeEnd` 的**取值合理性**：t 恰好为该阈值时 Opacity 一定为 0，
    // 所以在窗口压到第一个字形（x≈40dp）之前文字就已经不可见。
    expect(find.text('快速下单', skipOffstage: false), findsNothing,
        reason: '收起态文字不在树上（不是被裁掉一半）');
    // 顺带钉住 `labelFadeEnd` 取值的**合理性**（不是随手写的数）：
    // 文字左缘固定 = sidePadding(15) + markSize(18) + markGap(7) = 40dp；
    // 遮罩右边界 = 可见宽度。要求"遮罩压到第一个字形之前文字已不可见" ⇒
    //   visibleWidth(labelFadeEnd) > 40dp
    // 反过来若把 labelFadeEnd 调大（文字消失得更晚），这一条会失败 —— 那正是"半截字"回归点。
    final labelLeft = AppOrderFab.sidePadding + AppOrderFab.markSize + AppOrderFab.markGap;
    expect(AppOrderFab.visibleWidth(AppOrderFab.labelFadeEnd), greaterThan(labelLeft),
        reason: '文字必须在遮罩压到字形（x=$labelLeft dp）之前就已淡出到 0');

    // 停止滚动 600ms → 展开
    await tester.pump(AppOrderFab.expandDelay + const Duration(milliseconds: 20));
    expect(fab().expanded, isTrue, reason: '停止滚动 600ms 后自动展开');

    await tester.pump(AppOrderFab.collapseDuration);
  });

  testWidgets('服务页：向上滚动立刻展开（8dp 迟滞只防"误收起"，不锁死展开）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: ServicesPage(api: _api(_fixtures()))));
    await tester.pumpAndSettle();
    await _selectFirstDivision(tester);

    AppOrderFab fab() => tester.widget<AppOrderFab>(find.byType(AppOrderFab));
    // 先向下滚足够远，并**等惯性滚完**（否则下一步向上滚时列表还带着向下的惯性，
    // 首帧 delta 仍是正数，会被 8dp 迟滞当成"继续向下"）
    await _flingList(tester, const Offset(0, -200));
    await tester.pumpAndSettle();
    // 展开定时器 600ms：这里只等 120ms，保持收起态断言
    await tester.pump(const Duration(milliseconds: 120));
    expect(fab().expanded, isFalse);
    final offset = _listOffset(tester);
    expect(offset, greaterThan(100), reason: '列表要真的滚下去了');

    // 向上滚 60dp → 立刻展开（不等 600ms）
    await _flingList(tester, const Offset(0, 60));
    expect(fab().expanded, isTrue, reason: '向上滚动应立即展开，用户"想看上面"不能被收起态挡住');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('服务页：浮标点击可用（收起态也能点，热区不随视觉缩小）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    String? got = 'init';
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api(_fixtures()), onGoOrder: (id) => got = id ?? 'null'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppOrderFab));
    await tester.pump();
    expect(got, 'null', reason: '默认浮标 = 去下单（divisionId 传 null，进商品列表）');
    await tester.pump(AppOrderFab.collapseDuration);
  });

  // -------------------------------------------------------------------
  // 5) 手势冲突：浮标不吃列表纵向滚动、不吃轮播横滑
  // -------------------------------------------------------------------
  testWidgets('手势：浮标外侧纵滑照常滚动列表，从浮标上纵滑不会误触发下单', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: _api(_fixtures()), onGoOrder: (_) => taps++),
    ));
    await tester.pumpAndSettle();
    await _selectFirstDivision(tester);
    expect(_maxScrollExtent(tester), greaterThan(200));

    // ① 浮标左侧（屏幕中线附近）纵滑 → 列表照常滚动
    await _flingList(tester, const Offset(0, -80));
    expect(_listOffset(tester), greaterThan(0), reason: '浮标之外必须能正常滚动列表');

    // ② 手指落在浮标上纵滑 → 不得触发下单（浮标只认 tap，drag 不产生点击）
    final before = _listOffset(tester);
    final g = await tester.startGesture(tester.getCenter(find.byType(AppOrderFab)));
    await g.moveBy(const Offset(0, -40));
    await tester.pump();
    await g.moveBy(const Offset(0, -40));
    await g.up();
    await tester.pump();
    expect(taps, 0, reason: '在浮标上滑动不能算点击');
    expect(_listOffset(tester), before, reason: '浮标自身区域按设计不参与列表滚动（不抢手势，也不透传）');
    await tester.pumpAndSettle();
  });

  testWidgets('手势：浮标横滑不会拦住宣传图轮播（浮标不认领先横向手势）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var taps = 0;
    final api = _api(_fixtures(banners: [
      {'id': '1', 'title': '第一张', 'subtitle': '', 'imageMediaId': null, 'imageUrl': '', 'linkType': 'none', 'linkValue': ''},
      {'id': '2', 'title': '第二张', 'subtitle': '', 'imageMediaId': null, 'imageUrl': '', 'linkType': 'none', 'linkValue': ''},
    ]));
    await tester.pumpWidget(MaterialApp(
      home: ServicesPage(api: api, onGoOrder: (_) => taps++),
    ));
    await tester.pumpAndSettle();

    expect(find.text('第一张'), findsOneWidget);
    // 从浮标位置起手横向拖动 → 不抛异常、不触发下单（浮标不认领横向手势）
    final g = await tester.startGesture(tester.getCenter(find.byType(AppOrderFab)));
    await g.moveBy(const Offset(-120, 0));
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '浮标不认领先横向手势');
    expect(taps, 0, reason: '横滑不是点击');
    expect(find.text('第一张'), findsOneWidget, reason: '横滑起于浮标 → 宣传图不翻页');

    // 宣传图自身横滑**必须**能翻页（浮标不干扰轮播的手势）
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('第二张'), findsOneWidget, reason: '宣传图横滑翻页正常');
  });
}

void _noop() {}
void _noopI(int _) {}

// -------------------------------------------------------------------------
// 测试辅助
//
// ⚠️ 别用 `tester.drag(find.byType(ListView), ...)`：它取的是 ListView 的**几何中心**
// （390 × 844 视口的中心 = (195, 422)）——用在这个页面上没问题，但一旦页面内容/浮标位置变化，
// 落点就可能砸在浮标上（浮标是 Stack 里 z 序更高的兄弟节点），手势被浮标吃掉，
// 表现为"列表滚不动"，会被误判成浮标抢了滚动。这里统一起手在**屏幕中线偏上**的空位。
// -------------------------------------------------------------------------

const Offset _listDragStart = Offset(195, 300);

/// **切进第一个具体分部**（首页默认停在「祁连山官方」= 聚合视图，**按负责人 2026-10-18
/// 的口径不渲染商品** → 页面撑不长，浮标的滚动状态机跑不起来）。
///
/// 夹具的 12 条商品全部挂 `divisionId=1`，所以点第一个 Tab（id=1）就能**全部**上屏 ——
/// **商品条数一条没少**（`maxScrollExtent > 200` 这条前提继续成立）。
Future<void> _selectFirstDivision(WidgetTester tester) async {
  await tester.tap(find.text('和平精英').first);
  await tester.pumpAndSettle();
}

Future<void> _flingList(WidgetTester tester, Offset delta) async {
  final g = await tester.startGesture(_listDragStart);
  final steps = 4;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(delta / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pump();
}

double _listOffset(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first)
    .position
    .pixels;

double _maxScrollExtent(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first)
    .position
    .maxScrollExtent;

// -------------------------------------------------------------------------
// 测试夹具：与真实服务端同形状的响应
//
// 关键：内容必须**长到可以滚动**。浮标的收起/展开完全由滚动通知驱动，
// 若夹具只够渲染半屏（maxScrollExtent = 0），drag 不会产生任何 ScrollUpdateNotification，
// 于是"没收起"会被误读成状态机坏了 —— 那是夹具问题，不是实现问题。
// -------------------------------------------------------------------------

Map<String, Map<String, dynamic>> _fixtures({List<Map<String, dynamic>>? banners}) => {
      // **首页的"长内容"现在是商品双列列表**（2026-10-18：底部官方馆整块删除，
      // 原来靠 8 张官方馆卡把页面撑长的那条路已经没有了）。
      // 这里给 12 条商品（双列 6 行）→ maxScrollExtent 远超 200，滚动/FAB 状态机才有意义。
      '/public/products': {
        'code': 0,
        'message': 'ok',
        'data': {
          'list': [
            for (var i = 0; i < 12; i++)
              {
                'id': 'p${i + 1}',
                'name': '和平精英上分单 ${i + 1}',
                'price': 30 + i,
                'priceUnit': '局',
                'salesCount': 120 + i,
                'divisionId': '1',
                'gameId': '35',
              },
          ],
          'total': 12,
          'page': 1,
          'pageSize': 50,
        },
      },
      '/divisions/grouped': {
        'code': 0,
        'message': 'ok',
        'data': [
          {
            'gameId': '35',
            'gameName': '和平精英',
            'platformCount': 1,
            'divisions': [
              for (var i = 0; i < 6; i++)
                {
                  'id': '${i + 1}',
                  'code': 'peace_mobile_$i',
                  'gameId': '35',
                  'gameName': '和平精英',
                  'platform': 'mobile',
                  'platformLabel': '手游',
                  'name': '和平精英 · 手游 $i',
                  'shortName': '和平精英',
                  'onlineDesc': '9:00-次日 2:00',
                  'themeColor': '#2563EB',
                  'sortOrder': 10 + i,
                  'onlineCount': 9,
                },
            ],
          },
        ],
      },
      '/public/site': {'code': 0, 'message': 'ok', 'data': <String, dynamic>{}},
      '/public/banners': {'code': 0, 'message': 'ok', 'data': banners ?? const []},
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
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
    return ResponseBody.fromString(
      jsonEncode(raw[key]!),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
