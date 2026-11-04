import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'pages/home_shell.dart';
import 'pages/login_page.dart';
import 'services/ai_cold_start.dart';
import 'services/withdraw_media_picker.dart';
import 'services/worker_notifier_factory.dart';
import 'widgets/fish_glass.dart';
import 'widgets/startup_splash.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 底栏外观（液态玻璃开关）读一次：读不到就按默认关
  unawaited(NavStyleController.instance.init());

  /**
   * 【2026-10-04 性能专项：冷启动首帧不再被地址解析阻塞】
   *
   * 改之前是 `final address = await AppAddressResolver.resolve(); runApp(...)` ——
   * `resolve()` 要发一次网络（拉引导 JSON，超时上限 3.5s）+ 一次并行探活（上限 2.5s），
   * 两段**串行**，最坏约 6s。这段时间里 `runApp` 还没执行，Flutter 一帧都没画，
   * 用户盯着原生启动图干等 —— Android 上表现为"点了图标半天没反应"。
   *
   * 现在：**先 runApp（首帧立刻出）**，地址解析改成后台任务。
   * 顺序铁律仍然满足：`resolve()` 内部照旧在拿到地址后才写 `AppConfig`，
   * 而 `ApiClient` 的 request 拦截器会在**每个请求发出前**把 baseUrl 对齐到
   * "当前生效地址"（见 api_client.dart）。也就是说：
   *   地址解析完成 → 之后任何第一个 API 调用都必然用新地址；
   *   地址还没解析完就有人发请求 → 用编译期兜底地址（与"解析失败回退"完全同一条路径），
   *   解析完成后自动切换。
   *
   * 顺带把启动耗时打点（`[perf]` 前缀）：以后真机冷启动回归可以直接
   * `adb logcat -s flutter` 抓这两行，不用再靠"感觉快了"。
   */
  final Stopwatch boot = Stopwatch()..start();

  /**
   * 【2026-10-06 地址发现韧性：地址失效不再要求用户重启 App】
   *
   * 三件事在首帧之前**同步**接好（都是零成本的赋值，不发网络）：
   *   1) 自托管引导的"已知入口"持久化 —— 下次冷启动即便第三方引导站全挂，
   *      也能直接去本机记住的上次地址拉 `/site/client-config.json`；
   *   2) 地址看门狗装钩子 —— 连续 3 次请求失败 / 首次 WS 连不上，就自动
   *      清缓存 → 重走多源 bootstrap + 探活 → **热切换**地址（指数退避 + 次数上限）；
   *   3) 切换成功后重连 WS（`rebind`）—— socket.io 的自动重连只会重连旧 URL，
   *      不主动丢弃就永远切不过去。
   */
  AppAddressResolver.loadLastKnownGood = AppSettings.instance.readLastGoodApi;
  AppAddressResolver.saveLastKnownGood = AppSettings.instance.writeLastGoodApi;
  final AddressWatchdog watchdog = AddressWatchdog.instance;
  watchdog.onRefreshed = (AddressResolution _) {
    // socket.io 的自动重连只会重连**旧 URL**，不主动丢弃旧连接就永远切不过去
    RealtimeClient.shared.rebind();
  };
  watchdog.install();

  /**
   * 【2026-10-15 打手态通知栏提醒】把**平台能力**注入 core（core 只声明 `WorkerNotifier` 接口）。
   *
   * 为什么注册在 main 而不是让 core 自己引插件：core 同时被**已冻结的工作端**复用，
   * 往 core 引平台插件会连带改冻结端的依赖树（与 `WithdrawMedia` 的注入路线同源）。
   *
   * `init()` **刻意不 await**：main 的铁律是"首帧不被任何等待阻塞"（见上面的性能专项），
   * 而 `init()` 里要过两次 method channel。它的返回值（冷启动点通知拉起的目标）通过
   * `then` 补登记到 hub —— 壳挂载晚于它、且 hub 是 ValueNotifier，晚到也不会丢跳转。
   */
  final WorkerNotifier workerNotifier = createWorkerNotifier();
  WorkerNotifyHub.instance.notifier = workerNotifier;
  unawaited(workerNotifier.init().then((route) {
    if (route != null) WorkerNotifyHub.instance.requestRoute(route);
  }));

  runApp(const MainApp());

  // 液态玻璃着色器预编译（负责人 2026-10-18）
  //
  // ⚠️ 放在 runApp【之后】而不是之前：本文件开头的铁律是"runApp 不许被异步任务阻塞"
  // （地址解析就是为此改成了后台任务）。`precache()` 要编译 shader，放前面等于把
  // 冷启动拖回阻塞模式，首帧要等编译完才出。
  //
  // 放后面不会白屏：`LiquidGlass` 在着色器就绪前自动降级成 `FakeGlass`
  // （无折射的静态玻璃，本身也是可用的视觉），编译完自动换真折射。
  // 且只在用户**真的开了**玻璃底栏时才编译 —— 默认关，编译纯属浪费。
  if (NavStyleController.instance.glass) {
    unawaited(LiquidGlass.precache());
  }
  debugPrint('[perf] runApp called at ${boot.elapsedMilliseconds}ms '
      '(synchronous, first frame NOT blocked by address resolution)');

  // 首帧真实渲染完成时刻 —— 这是"冷启动体感"的量化指标：
  // 改动前 = runApp 时刻（≈地址解析耗时，最坏 6s）；改动后应接近 Flutter 引擎热身耗时。
  // 回归方法：`adb logcat -s flutter | findstr perf`
  WidgetsBinding.instance.addPostFrameCallback((_) {
    debugPrint('[perf] FIRST FRAME at ${boot.elapsedMilliseconds}ms');
  });

  unawaited(
    AppAddressResolver.resolve().then((address) {
      debugPrint('[perf] address resolved at ${boot.elapsedMilliseconds}ms '
          'api=${address.address.apiBaseUrl} source=${address.address.source} '
          'fromBootstrap=${address.fromBootstrap} err=${address.error}');
      // 启动解析结果反馈给看门狗：没拿到下发地址 → 排一次重取（退避 + 上限）
      AddressWatchdog.instance.noteStartup(address);
    }),
  );
}

/// 老板端（2026-09-25 液态玻璃大改：小米 HyperOS 风格开源组件库 flutter_miuix）
class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    // MiuixSystemTheme 跟随系统明暗模式并注入 miuix 调色板；
    // MaterialApp 主题由 miuix 色板派生（squircle 组件自带全套视觉）
    return MiuixSystemTheme(
      child: Builder(
        builder: (context) {
          final miuix = MiuixTheme.of(context);
          return AnimatedBuilder(
            animation: ThemeController.instance,
            builder: (context, _) {
              return MaterialApp(
                title: '祁连山电竞',
                debugShowCheckedModeBanner: false,
                theme: ThemeData(
                  useMaterial3: true,
                  colorScheme: ColorScheme.fromSeed(
                    seedColor: miuix.colors.primary,
                    brightness: miuix.brightness,
                  ),
                  brightness: miuix.brightness,
                  fontFamily: 'MiSans',
                  // 页面底色透明：露出下面 FishGlassBackdrop 的**实色**冷灰蓝底（AppColors.bgPage）
                  scaffoldBackgroundColor: Colors.transparent,
                  // 顶栏半透明：实色底透出，形成"白顶栏 + 冷灰蓝内容区"的分层
                  appBarTheme: AppBarTheme(
                    backgroundColor: miuix.brightness == Brightness.dark
                        ? const Color(0xB30E1226)
                        : const Color(0xB3FFFFFF),
                    elevation: 0,
                    scrolledUnderElevation: 0,
                  ),
                ),
                // 主题切换过渡：自然渐变，不闪屏
                themeAnimationDuration: const Duration(milliseconds: 320),
                themeAnimationCurve: Curves.easeInOutCubic,
                // 全局底色（**实色**，2026-10-07 起不再画渐变与径向光斑）
                //  + 冷启动品牌闪屏：盖在最上面、就绪即淡出，**不阻塞**底下的初始化
                builder: (context, child) => FishGlassBackdrop(
                  child: StartupSplashGate(child: child ?? const SizedBox.shrink()),
                ),
                home: const RootGate(),
              );
            },
          );
        },
      ),
    );
  }
}

/// 启动入口：恢复本地会话（安全存储）→ 已登录进主框架，未登录进登录页（docs/04）
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  @override
  void initState() {
    super.initState();
    AuthStore.instance.init();
    // 按最近登录账号恢复主题选择（重新打开 App 保持）
    ThemeController.instance.init();
    // **冷启动一次性初始化 AI 会话**（负责人 2026-10-04：会话轮换只在"大退后重新打开"时做一次，
    // 同一次运行内离开/回到 AI 页都保留刚才的对话）。
    // 这里发的是冷启动那一次；未登录（本地没有 token）时不消耗机会 ——
    // 登录后 HomeShell 首次挂载会补上（进程内只发一次的标记在 AiColdStart 里）。失败静默、不阻塞启动。
    unawaited(AiColdStart.ensureResetOnce());
    // 等级规则（升级阈值）从后台拉取：前端只读后台配置，失败回退默认阈值（2026-09-25）
    LevelRulesStore.instance.ensureLoaded();
    // 启动自动检测云端更新（负责人云端更新需求：无需用户手动检查）
    // appType=boss：双端共用更新中心，必须显式声明自身通道，避免拿错安装包
    UpdateCenter.instance.configure('boss');
    // 【2026-10-11 打手提现】给 core 的提现链路接上**选图/裁剪**能力
    //
    // 为什么在这里注册而不是让 core 自己引 image_picker：打手态四页都在 fish_core 里，
    // 而 core 要同时被老板端与工作端复用，平台依赖（相册/裁剪）只能由宿主提供
    // （与打手态聊天页的 `IdentityWorkerChatOpener` 同一条注入路线）。
    WithdrawMedia.configure(picker: pickWithdrawImage);
    _checkCloudUpdate();
  }

  Future<void> _checkCloudUpdate() async {
    try {
      final info = await UpdateCenter.instance.check();
      if (info == null || !mounted) return;
      // 仅当云端存在比当前更新的版本时才提示（服务端版本比较）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showUpdateDialog(context, info);
      });
    } catch (_) {
      // 网络异常等静默：下次启动再检测，不影响正常使用
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AuthStore.instance, UpdateCenter.instance]),
      builder: (context, _) {
        final auth = AuthStore.instance;
        if (!auth.initialized) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        // 强制更新未完成：阻断主功能（负责人需求 #4）
        if (auth.loggedIn && UpdateCenter.instance.forceBlocked) {
          return const UpdateBlockPage();
        }
        return SessionKickListener(
          child: auth.loggedIn ? const HomeShell() : const LoginPage(),
        );
      },
    );
  }
}
