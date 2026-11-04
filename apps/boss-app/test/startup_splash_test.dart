import 'package:boss_app/widgets/fish_glass.dart';
import 'package:boss_app/widgets/startup_splash.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 冷启动品牌闪屏 + 全局实色底（负责人 2026-10-07 定案 B 方案）
///
/// 这组用例守两件事：
/// 1. **闪屏的 4 条时序**：冷启动先出现 → 就绪后消失 → 就绪永不来也 ≤1200ms 淡出 →
///    同一进程二次进入不再出现（负向）；
/// 2. **全局底色是实色**：`FishGlassBackdrop` 树里 **0 个渐变**（光斑/渐变底一旦回归就变红），
///    且底色就是设计 token 的冷灰蓝 `#F5F7FB`。
void main() {
  setUp(() {
    // 每条用例都从"冷启动"开始（"本进程已展示过"的静态标记）
    StartupSplashGate.debugResetShownThisProcess();
    AuthStore.debugStorageDisabled = true;
    AppSettings.debugStorageDisabled = true;
    RealtimeClient.shared.debugDisabled = true;
    ApiClient.cacheEnabled = false;
  });

  tearDown(() {
    AuthStore.debugStorageDisabled = false;
    AppSettings.debugStorageDisabled = false;
    RealtimeClient.shared.debugDisabled = false;
    ApiClient.cacheEnabled = true;
  });

  /// 与 `main.dart` 同构的壳：`FishGlassBackdrop` 包住整棵 App，闪屏闸门盖在 Navigator 上
  Widget shell({bool Function()? ready}) => MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => FishGlassBackdrop(
          child: StartupSplashGate(
            ready: ready,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: const Scaffold(body: Center(child: Text('主界面'))),
      );

  testWidgets('闪屏① 冷启动第一帧先出现闪屏（白底 + 雪山标 + 字名 + 说明），且不挡底下的初始化', (tester) async {
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(shell());
    await tester.pump(); // 第一帧

    expect(find.byKey(StartupSplash.splashKey), findsOneWidget);
    expect(find.text('祁连山电竞'), findsOneWidget);
    expect(find.text('陪玩 · 代练 · 护航'), findsOneWidget);
    expect(find.byType(AppMountainMark), findsOneWidget);

    // 白底（与原生启动图同色，消除白→灰跳变）
    final splash = tester.widget<ColoredBox>(find.byKey(StartupSplash.splashKey));
    expect(splash.color, AppColors.bgCard);
    expect(AppColors.bgCard, const Color(0xFFFFFFFF));

    // 雪山标：主色 + 出图尺寸
    final mark = tester.widget<AppMountainMark>(find.byType(AppMountainMark));
    expect(mark.color, AppColors.primary);
    expect(mark.size, StartupSplash.markSize);

    // 字名 700 / 29px / 深墨色；说明 12px / mutedText（docs/21：白底说明文字必须达 AA）
    final name = tester.widget<Text>(find.text('祁连山电竞'));
    expect(name.style?.fontWeight, FontWeight.w700);
    expect(name.style?.fontSize, inInclusiveRange(28, 30));
    expect(name.style?.color, AppColors.textPrimary);
    final tagline = tester.widget<Text>(find.text('陪玩 · 代练 · 护航'));
    expect(tagline.style?.fontSize, 12);
    expect(tagline.style?.color, AppColors.mutedText);

    // **不阻塞**：闪屏只是"盖在上面的一层"，App 在它底下照常构建并已排好版
    expect(find.text('主界面'), findsOneWidget);
    expect(tester.getSize(find.text('主界面')).isEmpty, isFalse, reason: '底下主界面已完成布局（闪屏没有挡住 runApp/构建）');

    // 闪屏层在 Stack 里位于 App 之上（先画 App，再盖闪屏）
    final stack = tester.widget<Stack>(find.descendant(
      of: find.byType(StartupSplashGate),
      matching: find.byType(Stack),
    ).first);
    expect(stack.children.length, 2);
    expect(stack.children.last, isA<Positioned>(), reason: '闪屏是最后（最上层）那个孩子');

    // 冷启动这条路径不得有溢出
    expect(tester.takeException(), isNull);
  });

  testWidgets('闪屏② 就绪后消失（最短 400ms 到点 + 真实就绪信号 AuthStore.init()）', (tester) async {
    await tester.pumpWidget(shell());

    // 第一帧：在
    expect(find.byType(StartupSplash), findsOneWidget);

    // 真实就绪信号：AuthStore.init() 结尾置位 initialized 并 notifyListeners()
    // （没有 token → 不发网络；安全存储被 debugStorageDisabled 关掉）
    unawaitedInit();
    await tester.pump();
    expect(AuthStore.instance.initialized, isTrue, reason: '既有就绪标志（auth_store.dart 的 init()）');

    // 最短 400ms 未到：即便已就绪也**不能**提前消失（否则一闪而过=没品牌）
    await tester.pump(const Duration(milliseconds: 399));
    expect(find.byType(StartupSplash), findsOneWidget);
    expect(_splashOpacity(tester), 1.0);

    // 到点 → 开始淡出（200ms）
    await tester.pump(const Duration(milliseconds: 1));
    expect(_splashOpacity(tester), 0.0, reason: 't=400ms 起淡出');

    // 淡出结束：闪屏彻底移除，主界面可交互
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplash), findsNothing, reason: 'pumpAndSettle 后找不到闪屏');
    expect(find.byKey(StartupSplash.splashKey), findsNothing);
    expect(find.text('主界面'), findsOneWidget, reason: '能找到主界面');
    expect(tester.takeException(), isNull);
  });

  testWidgets('闪屏③ 超时路径：就绪信号一直不来，≤1200ms 也一定开始淡出、1400ms 前必消失', (tester) async {
    await tester.pumpWidget(shell(ready: () => false)); // 就绪信号永不到来
    expect(find.byType(StartupSplash), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byType(StartupSplash), findsOneWidget, reason: '1s 时仍在（还没到兜底上限）');

    await tester.pump(const Duration(milliseconds: 199)); // t=1199
    expect(_splashOpacity(tester), 1.0, reason: 't=1199ms 还没有开始淡出');

    await tester.pump(const Duration(milliseconds: 1)); // t=1200 —— 兜底上限
    expect(_splashOpacity(tester), 0.0, reason: '**t=1200ms 必须开始淡出**（闪屏绝不能变成"真卡住"）');

    await tester.pump(const Duration(milliseconds: 200)); // 淡出 200ms
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplash), findsNothing, reason: '≤1200ms 起淡出 → 1400ms 前一定消失');
    expect(find.text('主界面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('闪屏④ 负向：同一进程二次挂载（热重启/二次进入/切页）不再出现闪屏', (tester) async {
    // 第一次（冷启动）：出现 → 消失
    await tester.pumpWidget(shell());
    expect(find.byType(StartupSplash), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1400));
    await tester.pumpAndSettle();
    expect(find.byType(StartupSplash), findsNothing);
    expect(StartupSplashGate.debugShownThisProcess, isTrue);

    // 第二次挂载（换 UniqueKey = 全新 State，等价于"再进一次"）：第一帧就没有闪屏
    await tester.pumpWidget(MaterialApp(
      key: const ValueKey('second-entry'),
      debugShowCheckedModeBanner: false,
      builder: (context, child) => FishGlassBackdrop(
        child: StartupSplashGate(
          key: UniqueKey(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: const Scaffold(body: Center(child: Text('主界面'))),
    ));
    await tester.pump();
    expect(find.byType(StartupSplash), findsNothing, reason: '同一进程内不再出现闪屏');
    expect(find.text('主界面'), findsOneWidget);

    // 切页（push 第二层路由）也不会把闪屏带回来
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('第二页'))));
    await tester.pumpAndSettle();
    expect(find.text('第二页'), findsOneWidget);
    expect(find.byType(StartupSplash), findsNothing, reason: '切页不出现闪屏');
    expect(tester.takeException(), isNull);
  });

  testWidgets('底色① FishGlassBackdrop 树里 0 个渐变/光斑（finder + 装饰扫描双保险）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FishGlassBackdrop(child: SizedBox.expand()),
    ));

    // finder 直断：一个画装饰的层都没有（原来这里有一个 LinearGradient 底 + 3 个 RadialGradient 光斑）
    expect(
      find.descendant(of: find.byType(FishGlassBackdrop), matching: find.byType(DecoratedBox)),
      findsNothing,
      reason: '实色底不需要任何 DecoratedBox / 渐变 / 光斑',
    );
    expect(_gradientsUnder(tester, find.byType(FishGlassBackdrop)), isEmpty);

    // 真实壳（MaterialApp.builder 同构 + 有内容的页面）下再扫一遍：内容里的渐变不算，
    // 但只要**背景层**再长出渐变/光斑，这条就变红
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => FishGlassBackdrop(child: child ?? const SizedBox.shrink()),
      home: const Scaffold(backgroundColor: Colors.transparent, body: Center(child: Text('内容'))),
    ));
    await tester.pump();
    expect(_gradientsUnder(tester, find.byType(FishGlassBackdrop)), isEmpty,
        reason: '全局背景层不得再出现任何渐变（光斑/渐变底回归即失败）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('底色② 全局底色 = 设计 token 的实色页底（AppColors.bgPage / 方案 F 纯白）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: FishGlassBackdrop(child: SizedBox.expand())));

    expect(AppColors.bgPage, const Color(0xFFFFFFFF));
    expect(FishGlassBackdrop.baseColor, AppColors.bgPage, reason: '取色必须走既有 token，不新造颜色');
    final solid = tester.widget<ColoredBox>(find.byKey(FishGlassBackdrop.solidLayerKey));
    expect(solid.color, AppColors.bgPage);
    expect(solid.color.a, 1.0, reason: '必须是不透明实色（半透明会让底下透出来）');

    // FishGlassPage（近 20 个页面用的页壳）同样不得再画渐变/光斑，且顶栏结构保持
    await tester.pumpWidget(MaterialApp(
      home: FishGlassPage(title: '页面标题', subtitle: '副标题', body: const SizedBox.expand()),
    ));
    await tester.pump();
    expect(_gradientsUnder(tester, find.byType(FishGlassPage)), isEmpty);
    expect(find.text('页面标题'), findsOneWidget);
    expect(find.text('副标题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 真实就绪信号：`AuthStore.init()`（生产同一条路径）。
///
/// 刻意不 `await`：真实冷启动也是"发出去就不管"，闪屏靠监听器被动得知就绪。
void unawaitedInit() {
  AuthStore.instance.init();
}

/// 当前闪屏层的目标不透明度（1 = 完全显示，0 = 已开始淡出）
double _splashOpacity(WidgetTester tester) {
  final finder = find.descendant(of: find.byType(StartupSplashGate), matching: find.byType(AnimatedOpacity));
  expect(finder, findsOneWidget, reason: '淡出期间闪屏层仍在树上（靠不透明度过渡，不硬切）');
  return tester.widget<AnimatedOpacity>(finder).opacity;
}

/// 收集某棵子树里所有**画了渐变**的装饰（背景光斑/渐变底就是这个形状）
///
/// `Container(decoration:)` 内部就是 `DecoratedBox`，所以扫 `DecoratedBox` 覆盖两种写法。
List<Gradient> _gradientsUnder(WidgetTester tester, Finder root) {
  final out = <Gradient>[];
  for (final element in find.descendant(of: root, matching: find.byType(DecoratedBox)).evaluate()) {
    final decoration = (element.widget as DecoratedBox).decoration;
    if (decoration is BoxDecoration && decoration.gradient != null) out.add(decoration.gradient!);
  }
  return out;
}
