import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:boss_app/pages/services_page.dart';
import 'package:boss_app/widgets/fish_glass.dart';
import 'package:boss_app/widgets/startup_splash.dart';
import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 出图：① 启动品牌闪屏 ② 全局底色（实色冷灰蓝，无彩色光斑） ③ 改动前/后对照
///
/// 产出（`apps/boss-app/build/`）：
/// - `startup_splash.png`            闪屏：白底 + 雪山标 + 「祁连山电竞」+ 一行说明（390×844 @2x）
/// - `startup_backdrop_solid.png`    启动瞬间的全局底（内容还没上来那一瞬）：**像素级单色**证明无光斑
/// - `startup_home_solid.png`        首页（服务页，注入假数据）：页底渐变（白 + 极浅蓝）、无彩色光斑
/// - `startup_before_after.png`      对照：左 = 改动前（渐变 + 三个径向光斑）/ 右 = 改动后（实色）
///
/// 三个既有坑（照 `test/visual/muted_text_visual_test.dart` 的写法绕开）：
/// 1. 测试环境没有 CJK 字形 → `FontLoader` 挂系统字体（**msyh 放最前**，标点覆盖最广）
/// 2. 测试环境不加载 Material 图标字体 → 一并挂 `materialicons-regular.otf`
/// 3. `ThemeData(fontFamily:)` 改不动 `textTheme` → 必须 `textTheme.apply(fontFamily:)` 再套一遍
void main() {
  const cjkFamily = 'StartupShotCJK';
  const shotKey = Key('startup-shot');

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final cjkLoader = FontLoader(cjkFamily);
    for (final path in const [
      r'D:/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      r'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      break;
    }
    for (final path in const [
      'C:/Windows/Fonts/msyh.ttc', // msyh 放最前：标点覆盖最广
      'assets/fonts/MiSans-Normal.ttf', // App 真实字体（与 main.dart 的 fontFamily 同源）
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/Deng.ttf',
    ]) {
      final f = File(path);
      if (!f.existsSync()) continue;
      // 全部挂进**同一个族**（后者是前者的兜底）：只挂第一个时若某字体解析不出 CJK 字形，
      // 中文会渲染成豆腐块 —— 实测 msyh.ttc 单独挂就出豆腐，加上 App 自带 TTF 才正常。
      cjkLoader.addFont(Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await cjkLoader.load();
  });

  setUp(() {
    StartupSplashGate.debugResetShownThisProcess();
    ApiClient.cacheEnabled = false;
    RealtimeClient.shared.debugDisabled = true;
    AppSettings.debugStorageDisabled = true;
    AuthStore.debugStorageDisabled = true;
    ApiCache.instance.clear();
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    RealtimeClient.shared.debugDisabled = false;
    AppSettings.debugStorageDisabled = false;
    AuthStore.debugStorageDisabled = false;
  });

  void phone(WidgetTester tester, {double height = 844}) {
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// 与 `main.dart` 同构的壳：MaterialApp(透明 scaffold) → FishGlassBackdrop → StartupSplashGate
  Widget shell(Widget home, {double? height}) => RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: () {
            final base = ThemeData(fontFamily: cjkFamily, scaffoldBackgroundColor: Colors.transparent);
            return base.copyWith(textTheme: base.textTheme.apply(fontFamily: cjkFamily));
          }(),
          builder: (context, child) => FishGlassBackdrop(
            child: StartupSplashGate(child: child ?? const SizedBox.shrink()),
          ),
          home: home,
        ),
      );

  Future<ui.Image> shot(WidgetTester tester, String name, {double ratio = 2}) async {
    late ui.Image image;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
      image = await boundary.toImage(pixelRatio: ratio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory('build').createSync(recursive: true);
      File('build/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    return image;
  }

  /// ⚠️ `toByteData` 与 `toImage` 一样要等光栅线程回帧：**必须**放进 `runAsync`
  /// （假时钟下它永远不返回 —— 本项目在 `mountain_mark_layer_test.dart` 踩过同一个坑）
  Future<_Pixels> pixelsOf(WidgetTester tester, ui.Image image) async {
    late _Pixels px;
    await tester.runAsync(() async {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      px = _Pixels(data!.buffer.asUint8List(), image.width, image.height);
    });
    return px;
  }

  testWidgets('出图 ① 启动闪屏（白底 + 雪山标 + 「祁连山电竞」）', (tester) async {
    phone(tester);
    await tester.pumpWidget(shell(const Scaffold(backgroundColor: Colors.transparent, body: SizedBox.expand())));
    await tester.pump(); // 冷启动第一帧

    expect(find.byKey(StartupSplash.splashKey), findsOneWidget);
    expect(find.text('祁连山电竞'), findsOneWidget);
    expect(find.text('陪玩 · 代练 · 护航'), findsOneWidget);
    expect(find.byType(AppMountainMark), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得有布局溢出');
    final image = await shot(tester, 'startup_splash.png');
    final px = await pixelsOf(tester, image);
    image.dispose();

    // 白底像素证据：四角 + 顶边中点必须是**纯白**（与原生启动图同色）。
    // 旧渐变底最浅的那一角是 #EAF0FF（淡蓝）——它一旦回来，这条立刻变红。
    for (final (int, int) p in const [
      (0, 0),
      (779, 0),
      (0, 1687),
      (779, 1687),
      (390, 2),
      (2, 844),
      (777, 844),
    ]) {
      expect(px.at(p.$1, p.$2), (255, 255, 255), reason: '闪屏底必须是纯白 #FFFFFF（原生启动图同色），实测点 $p');
    }
    expect(px.width, 780);
    expect(px.height, 1688);
  });

  testWidgets('出图 ② 启动瞬间的全局底：全图像素级单色（无彩色光斑）', (tester) async {
    phone(tester);
    await tester.pumpWidget(shell(const Scaffold(backgroundColor: Colors.transparent, body: SizedBox.expand())));
    // 闪屏淡出后（内容页还没画任何东西）—— 这正是负责人截图看到"玻璃底"的那一瞬间
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplash), findsNothing);

    final image = await shot(tester, 'startup_backdrop_solid.png', ratio: 1);
    final px = await pixelsOf(tester, image);
    image.dispose();

    // 单色断言：全图每一个像素都必须等于**设计 token 的页底色**（光斑/渐变一旦回归立刻变红）。
    // ⚠️ 2026-10-14 品牌升级：`AppColors.bgPage` 由 `#F5F7FB` 改为 `#F4F6F9`，
    // 下面那条"字面量固化"的断言随 token 同步（**不是放宽**：上面 165–181 行的逐像素单色
    // 断言仍是硬门，本行只保证被固化的取值确实是设计 token 的当前值）。
    final want = (AppColors.bgPage.r * 255).round();
    final wantG = (AppColors.bgPage.g * 255).round();
    final wantB = (AppColors.bgPage.b * 255).round();
    var other = 0;
    (int, int, int) sample = (-1, -1, -1);
    for (var y = 0; y < px.height; y++) {
      for (var x = 0; x < px.width; x++) {
        final c = px.at(x, y);
        if (c.$1 != want || c.$2 != wantG || c.$3 != wantB) {
          if (other == 0) sample = (c.$1, c.$2, c.$3);
          other++;
        }
      }
    }
    expect(other, 0,
        reason: '启动瞬间的全局底必须是单色页底纯白 #FFFFFF；实测有 $other 个像素不是'
            '（示例 rgb$sample）—— 出现第二种颜色 = 光斑/渐变回来了');
    expect((want, wantG, wantB), (255, 255, 255), reason: '纯白页底 #FFFFFF（2026-10-16 方案 F 起为 AppColors.bgPage）');
  });

  testWidgets('出图 ③ 首页（服务页 · 假数据）：页底 = 白+极浅蓝渐变、无彩色光斑', (tester) async {
    phone(tester);
    await tester.pumpWidget(shell(ServicesPage(api: _api())));
    await tester.pump(const Duration(milliseconds: 1400)); // 闪屏淡出
    // 首页有加载动画（无限帧）→ 不能用 pumpAndSettle（它按 interval 一直泵到 10 分钟超时），
    // 用有界 pump 把数据回来的两帧推完
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    /**
     * 【依据】负责人 2026-10-17 要求页面底加「白 + 极浅蓝」自创渐变；底色由实色改为渐变，
     * 彩色光斑仍禁。
     *
     * 原断言是「全局底色必须是**实色**、树里 0 处渐变」—— 页底渐变落地后它**必然过期**
     * （这不是 bug，是断言过期）。这里按两条**更准确的事实**重钉，仍是收窄、不是放宽：
     *
     * ① 页底**就是**渐变：Scaffold 让位成透明 + `body` 外层有 `AppPageBg`，
     *    且那条渐变的朝向/止点/三档色**逐一等于 token**（本测试不写字面量色值）；
     * ② 彩色光斑**仍然禁**：树里**每一条**渐变都必须恰好是页底那条 `AppPageBg.wash` ——
     *    出现任何第二种渐变（径向光斑 / 扫描渐变 / 品牌渐变 / 第二层底色）立刻红，
     *    这与改动前"一处渐变都不许有"是**同一严格度**，只是基线多了页底这一条。
     */
    expect(find.byType(ServicesPage), findsOneWidget);

    // ①-a Scaffold 自身不再是实色底（否则渐变会被它整个盖住）
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, Colors.transparent,
        reason: '页底改由 AppPageBg 画 → Scaffold 必须让位成透明（不然渐变被盖住，等于没做）');

    // ①-b body 外层确实套了 AppPageBg（全站唯一的渐变消费点，这一页只应有一层）
    expect(find.byType(AppPageBg), findsOneWidget,
        reason: '首页页底必须是 AppPageBg（页底渐变的唯一消费点）');

    // ①-c 渐变本身：三档取 token、斜向 45 度、止点 0 / 0.45 / 1，且三档都是"极浅"（越往下越浅地压色）
    final wash = AppPageBg.wash;
    expect(wash.colors, <Color>[AppColors.bgWashTop, AppColors.bgWashMid, AppColors.bgWashBottom],
        reason: '页底渐变三档必须逐枚取 token（AppColors.bgWashTop / Mid / Bottom），不许写色值');
    expect(wash.stops, <double>[0.0, 0.45, 1.0], reason: '止点定案：0 / 45% / 1');
    expect(wash.begin, Alignment.topLeft, reason: '斜向：左上起');
    expect(wash.end, Alignment.bottomRight, reason: '斜向：右下止（比上下渐变耐看）');
    final lums = wash.colors.map((c) => c.computeLuminance()).toList();
    expect(lums.every((l) => l >= 0.85), isTrue,
        reason: '三档必须都是"极浅"（相对亮度 ≥ 0.85）：页底一深，纯白卡片就浮不起来');
    expect(lums[0] >= lums[1] && lums[1] >= lums[2], isTrue,
        reason: '必须越来越深（白 → 近白 → 极浅品牌蓝），不许出现回声式明暗');

    // ② 彩色光斑仍禁（原意逐字保留）：树里每一条渐变都必须是页底那条 wash
    final grads = _gradientsUnder(tester, find.byType(FishGlassBackdrop));
    expect(grads, isNotEmpty, reason: '页底渐变异丢：树里一条渐变都没有 = AppPageBg 没上屏');
    final extras = grads.where((g) => g != AppPageBg.wash).toList();
    expect(extras, isEmpty,
        reason: '出现页底之外的渐变（彩色光斑 / 品牌渐变 / 第二层底色）：$extras');
    expect(grads.whereType<RadialGradient>(), isEmpty,
        reason: '径向光斑已下线（负责人 2026-10-07 定案：光斑底在内容上来前先糊一屏）');
    expect(grads.whereType<SweepGradient>(), isEmpty, reason: '扫描渐变从未允许过');
    // 注：着色器（ShaderMask）刻意**不列进本测试**——播报条两端渐隐是既有实现，
    // 不属"页底底色"这一靶；本测试只钉底色与光斑，靶子不往外扩。

    expect(tester.takeException(), isNull);
    await shot(tester, 'startup_home_solid.png');
  });

  testWidgets('出图 ④ 对照：改动前（渐变 + 三个径向光斑） / 改动后（实色底）', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 420 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: () {
          final base = ThemeData(fontFamily: cjkFamily);
          return base.copyWith(textTheme: base.textTheme.apply(fontFamily: cjkFamily));
        }(),
        home: const _BeforeAfterPanel(),
      ),
    ));
    await tester.pumpAndSettle();
    await shot(tester, 'startup_before_after.png');
  });
}

/// 改动前 / 改动后对照面板（两栏同尺寸、同文案，只有"底"不一样）
class _BeforeAfterPanel extends StatelessWidget {
  const _BeforeAfterPanel();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 白底：让"改动后"的冷灰蓝实色底（#F5F7FB）在对照里看得见边界
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('冷启动那一层底 · 改动前 / 改动后',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            const Text('左：FishGlassBackdrop 的线性渐变 + 3 个径向光斑（改动前）  ·  右：实色 #F5F7FB（改动后）',
                style: TextStyle(fontSize: 11, color: AppColors.mutedText)),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                children: const [
                  Expanded(child: _Panel(label: '改动前（渐变 + 光斑）', child: _LegacyGlassBackdrop())),
                  SizedBox(width: 10),
                  Expanded(child: _Panel(label: '改动后（实色）', child: FishGlassBackdrop(child: SizedBox.expand()))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Expanded(
            child: DecoratedBox(
              // 发丝线：两栏都是浅色底，没有边框就看不出边界（尤其改动后的 #F5F7FB 挨着白底）
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.divider),
              ),
              child: ClipRRect(borderRadius: BorderRadius.circular(14), child: child),
            ),
          ),
        ],
      );
}

/// **改动前的实现**（从 git 历史原样复制，仅用于出图对照，**不参与产品代码**）：
/// 浅色线性渐变 + 三处径向光斑（初始主题的极轻档：alpha 0.10 / 0.09 / 0.07）
class _LegacyGlassBackdrop extends StatelessWidget {
  const _LegacyGlassBackdrop();

  static const _colors = [Color(0xFFEAF0FF), Color(0xFFF3EFFF), Color(0xFFFDF0F6)];
  static const _blobs = [
    (Color(0xFF8FA5FF), 0.10, -0.3, -0.38, 400.0),
    (Color(0xFFC3A6FF), 0.09, 0.55, 0.1, 360.0),
    (Color(0xFFFFB7D0), 0.07, 0.8, 0.9, 320.0),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _colors),
                ),
              ),
            ),
            for (final b in _blobs)
              Positioned(
                left: c.maxWidth * b.$3,
                top: c.maxHeight * b.$4,
                child: IgnorePointer(
                  child: Container(
                    width: b.$5,
                    height: b.$5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [b.$1.withValues(alpha: b.$2), b.$1.withValues(alpha: 0)]),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// 假数据：分部 / 官方自营 / 首页说明（**不依赖线上**，照 `services_headline_visual_test.dart`）
ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://fixture.local'));
  dio.httpClientAdapter = _Adapter(const {
    '/public/clubs': {
      'code': 0,
      'message': 'ok',
      'data': [
        {
          'id': '1',
          'name': '祁连山电竞 · 和平精英分部',
          'subTitle': '和平精英分部',
          'description': '全段位上分与护航',
          'coverMediaId': null,
          'badge': '官方',
          'rating': '4.9',
          'orderCount': 2847,
          'divisionId': '1',
        },
      ],
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
              'priceNote': '按局计费',
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
            },
          ],
        },
      ],
    },
    '/public/home': {
      'code': 0,
      'message': 'ok',
      'data': {
        'clubTitle': '和平精英分部',
        'clubParagraphs': ['手游全段位上分与护航；客服 9:00-次日 2:00 在线'],
      },
    },
    '/public/banners': {'code': 0, 'message': 'ok', 'data': []},
    '/public/recharge/config': {
      'code': 0,
      'message': 'ok',
      'data': {'amountOptions': [6, 10, 20, 38, 68], 'customEnabled': true, 'minYuan': 1, 'maxYuan': 10000, 'pointsPerYuan': 10},
    },
  });
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

/// 收集某棵子树里所有**画了渐变**的装饰（背景光斑/渐变底就是这个形状）
List<Gradient> _gradientsUnder(WidgetTester tester, Finder root) {
  final out = <Gradient>[];
  for (final element in find.descendant(of: root, matching: find.byType(DecoratedBox)).evaluate()) {
    final decoration = (element.widget as DecoratedBox).decoration;
    if (decoration is BoxDecoration && decoration.gradient != null) out.add(decoration.gradient!);
  }
  return out;
}

class _Pixels {
  _Pixels(this.bytes, this.width, this.height);

  final Uint8List bytes;
  final int width;
  final int height;

  (int, int, int) at(int x, int y) {
    final i = (y * width + x) * 4;
    return (bytes[i], bytes[i + 1], bytes[i + 2]);
  }
}
