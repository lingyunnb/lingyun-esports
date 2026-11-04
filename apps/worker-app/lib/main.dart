import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'pages/home_shell.dart';
import 'pages/login_page.dart';
import 'pages/worker_sunset_block_page.dart';
import 'widgets/fish_glass.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 【2026-10-04 性能专项：冷启动首帧不再被地址解析阻塞】
  // 与老板端同改（详见 apps/boss-app/lib/main.dart 的完整说明）：
  // 原先 `await AppAddressResolver.resolve()` 在 runApp 之前，最坏 ~6s 一帧不画；
  // 现在先 runApp 出首帧，地址后台解析，`ApiClient` 的 request 拦截器保证
  // 每个请求发出前都用"当前生效地址"（顺序铁律不破，见 core/api_client.dart）。
  final Stopwatch boot = Stopwatch()..start();

  // 【2026-10-06 地址发现韧性：地址失效不再要求用户重启 App】
  // 与老板端同改（完整说明见 apps/boss-app/lib/main.dart）：接好自托管引导的
  // "已知入口"持久化 + 地址看门狗（连续失败/WS 连不上 → 重取 + 热切换）+ WS 重连。
  AppAddressResolver.loadLastKnownGood = AppSettings.instance.readLastGoodApi;
  AppAddressResolver.saveLastKnownGood = AppSettings.instance.writeLastGoodApi;
  final AddressWatchdog watchdog = AddressWatchdog.instance;
  watchdog.onRefreshed = (AddressResolution _) {
    // socket.io 的自动重连只会重连**旧 URL**，不主动丢弃旧连接就永远切不过去
    RealtimeClient.shared.rebind();
  };
  watchdog.install();

  runApp(const MainApp());
  debugPrint('[perf] runApp called at ${boot.elapsedMilliseconds}ms '
      '(synchronous, first frame NOT blocked by address resolution)');

  WidgetsBinding.instance.addPostFrameCallback((_) {
    debugPrint('[perf] FIRST FRAME at ${boot.elapsedMilliseconds}ms');
  });

  unawaited(
    AppAddressResolver.resolve().then((address) {
      debugPrint('[perf] address resolved at ${boot.elapsedMilliseconds}ms '
          'api=${address.address.apiBaseUrl} source=${address.address.source} '
          'fromBootstrap=${address.fromBootstrap} err=${address.error}');
      AddressWatchdog.instance.noteStartup(address);
    }),
  );
}

/// 工作端（2026-09-25 与老板端统一设计语言：小米 HyperOS 风格 flutter_miuix + 液态玻璃骨架）
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
          return MaterialApp(
            title: '祁连山电竞内部',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme: ColorScheme.fromSeed(
                seedColor: miuix.colors.primary,
                brightness: miuix.brightness,
              ),
              brightness: miuix.brightness,
              fontFamily: 'MiSans',
              scaffoldBackgroundColor: Colors.transparent,
              appBarTheme: AppBarTheme(
                backgroundColor: miuix.brightness == Brightness.dark
                    ? const Color(0xB30E1226)
                    : const Color(0xB3FFFFFF),
                elevation: 0,
                scrolledUnderElevation: 0,
              ),
            ),
            builder: (context, child) => FishGlassBackdrop(child: child ?? const SizedBox.shrink()),
            home: const RootGate(),
          );
        },
      ),
    );
  }
}

/// 启动入口：恢复本地会话 → 已登录进主框架，未登录进登录页
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
    // 等级规则（升级阈值）从后台拉取：前端只读后台配置，失败回退默认阈值（2026-09-25）
    LevelRulesStore.instance.ensureLoaded();
    // 启动自动检测云端更新（负责人需求：工作端与老板端同等能力）
    // appType=worker：双端共用更新中心，必须显式声明自身通道，避免拿错安装包
    UpdateCenter.instance.configure('worker');
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
          child: WorkerSunsetGateHost(
            // 2026-10-06 **完全阻断版（v1.8.2 / 码 60）· 立即生效、无宽限期**（负责人拍板：
            // 平台还没正式投用、没有未迁移的打手）：冷启动先出「工作端已停止服务」阻断页
            // （下载入口 + 5 步绑定），**只剩「前往下载」**——登录页/主界面进不去，
            // 与既有强制更新阻断同一套机制（UpdateBlockPage 也是在这里替换主界面）。
            // 唯一开关见 lib/widgets/worker_sunset.dart 的 kWorkerSunsetBlocking（本版 = true）。
            child: auth.loggedIn ? const HomeShell() : const LoginPage(),
          ),
        );
      },
    );
  }
}
