import 'dart:async';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 品牌闪屏（冷启动首屏）
///
/// 负责人 2026-10-07 定案（B 方案 · ① 启动加品牌闪屏）：
/// 打开 App 的那一瞬间不能再出现"紫/粉/蓝洗过的液态玻璃底"（那层底已随
/// `FishGlassBackdrop` 改为实色而消失，见 `fish_glass.dart`），改为**先出一张品牌闪屏**。
///
/// 视觉口径（逐条对 docs/21 反 AI 味规范）：
/// - **白底 `#FFFFFF`**：与原生启动图
///   (`android/app/src/main/res/drawable/launch_background.xml` = 白底 + 居中图标)
///   **同色**，所以「原生启动图 → Flutter 首帧」之间**没有跳变**（白→白）；
/// - 居中**雪山标** [AppMountainMark]（纯绘制、无图片依赖）+ 主色；
/// - 下方「祁连山电竞」（700 字重 / 29px / 深墨色）；
/// - 再下一行 12px 灰字「陪玩 · 代练 · 护航」（[AppColors.mutedText]，对比度 5.44:1）；
/// - **无 emoji、无装饰插画、无渐变、无光斑**（docs/21 禁止清单）。
///
/// 间距：标 → 字名 22（组间松），字名 → 说明 10（组内紧），符合 docs/21「组内紧组间松」。
class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key});

  /// 闪屏根节点 Key（测试与出图据此定位"闪屏在不在"）
  static const Key splashKey = Key('startup-splash');

  /// 品牌名（与 `main.dart` 的 `MaterialApp.title` 一致）
  static const String appName = '祁连山电竞';

  /// 一行说明（docs/21：具体、可验证，不写"立即体验"式空话）
  static const String tagline = '陪玩 · 代练 · 护航';

  /// 雪山标尺寸（逻辑像素）
  static const double markSize = 64;

  @override
  Widget build(BuildContext context) {
    // 闪屏挂在 `MaterialApp.builder` 里 —— 那个位置**没有任何 Material 祖先**（不套 Scaffold），
    // 于是拿不到主题字体（真机会掉回系统默认字体，`flutter test` 里会掉回测试字体 → 豆腐块）。
    // 这里显式把主题正文字体接上（等价于 `Material` 内部做的那件事），不改任何字体设置。
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return ColoredBox(
      key: splashKey,
      // 与原生启动图同色（#FFFFFF）—— 冷启动第一帧与系统启动图无缝衔接
      color: AppColors.bgCard,
      child: DefaultTextStyle(
        style: base,
        child: Center(
          // 小屏（360×640）也不溢出：整块高度约 134dp，居中 + 内边距留足余量
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppMountainMark(size: markSize, color: AppColors.primary),
                const SizedBox(height: 22), // 组间松
                const Text(
                  appName,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 29,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 10), // 组内紧
                const Text(
                  tagline,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.mutedText, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 闪屏闸门：**只负责"何时显示 / 何时淡出"，绝不阻塞启动**
///
/// 挂在 `MaterialApp.builder` 里把整棵 App 包住（见 `main.dart`）：
/// 首帧就开始画闪屏，App 自己在**闪屏底下照常构建与初始化**（地址解析、会话恢复、
/// 更新检查全部不受影响）—— 这就是"不阻塞"的实现方式：闪屏是**盖在上面的一层**，
/// 不是"等它结束才 runApp"。
///
/// 三条时间口径：
/// - **最短 400ms**：冷启动太快时一闪而过反而像闪屏（品牌没看清）；到点且就绪才淡出；
/// - **最长 1200ms**：就绪信号**一直不来也一定淡出**（闪屏绝不能变成"真卡住"）；
/// - **淡出 200ms**：白 → 首页冷灰蓝底是叠加淡出（不是硬切），不会闪白/闪灰。
///
/// 就绪判定用**既有状态**（不新造全局状态机）：`AuthStore.instance.initialized`
/// —— `AuthStore.init()` 结尾置位并 `notifyListeners()`（见 core 的 auth_store.dart）。
class StartupSplashGate extends StatefulWidget {
  const StartupSplashGate({
    super.key,
    required this.child,
    this.ready,
    this.minDuration = const Duration(milliseconds: 400),
    this.maxDuration = const Duration(milliseconds: 1200),
    this.fadeDuration = const Duration(milliseconds: 200),
  });

  /// 被闪屏盖住的 App（`MaterialApp.builder` 的 child）
  final Widget child;

  /// 就绪判定（默认 = 既有状态 [AuthStore.initialized]）。
  ///
  /// 可注入只为测试：生产路径**不传**，永远走既有的 `AuthStore` 标志。
  final bool Function()? ready;

  /// 最短展示时长（就绪了也要等满它）
  final Duration minDuration;

  /// 最长展示时长（到点无条件淡出，闪屏不会变成卡死）
  final Duration maxDuration;

  /// 淡出时长
  final Duration fadeDuration;

  /// 本进程是否已经展示过闪屏（**冷启动一次**）
  ///
  /// 同一进程里再次挂载（切页重建、热重载后重建）不再出现；
  /// 真正的大退重开 = 新进程 = 静态量重置 → 闪屏照常出现一次。
  static bool _shownThisProcess = false;

  /// 测试用：读过"本进程是否展示过"的标记
  @visibleForTesting
  static bool get debugShownThisProcess => _shownThisProcess;

  /// 测试用：重置"已展示"标记（让每条用例都能从"冷启动"开始）
  @visibleForTesting
  static void debugResetShownThisProcess() => _shownThisProcess = false;

  @override
  State<StartupSplashGate> createState() => _StartupSplashGateState();
}

/// 闪屏三态：显示 → 淡出中 → 已移除
enum _SplashPhase { showing, fading, gone }

class _StartupSplashGateState extends State<StartupSplashGate> {
  _SplashPhase _phase = _SplashPhase.gone;
  bool _minElapsed = false;
  Timer? _minTimer;
  Timer? _maxTimer;
  Timer? _fadeTimer;

  @override
  void initState() {
    super.initState();
    if (StartupSplashGate._shownThisProcess) return; // 非冷启动：一次都不显示
    StartupSplashGate._shownThisProcess = true;
    _phase = _SplashPhase.showing;
    _minTimer = Timer(widget.minDuration, () {
      _minElapsed = true;
      _maybeFade();
    });
    // 兜底：就绪信号一直不来也一定淡出（1200ms ≤ 人的"卡住"阈值）
    _maxTimer = Timer(widget.maxDuration, _beginFade);
    AuthStore.instance.addListener(_maybeFade);
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
    _fadeTimer?.cancel();
    AuthStore.instance.removeListener(_maybeFade);
    super.dispose();
  }

  bool _isReady() => (widget.ready ?? _defaultReady)();

  static bool _defaultReady() => AuthStore.instance.initialized;

  /// 两个条件都满足才淡出：① 最短时长已到 ② 就绪
  void _maybeFade() {
    if (!mounted || _phase != _SplashPhase.showing) return;
    if (!_minElapsed || !_isReady()) return;
    _beginFade();
  }

  void _beginFade() {
    if (!mounted || _phase != _SplashPhase.showing) return;
    _maxTimer?.cancel();
    setState(() => _phase = _SplashPhase.fading);
    _fadeTimer = Timer(widget.fadeDuration, () {
      if (!mounted) return;
      setState(() => _phase = _SplashPhase.gone); // 移除闪屏层，主界面完全露出
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _SplashPhase.gone) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          // 启动期间挡住误触（底下是还没就绪的界面）
          child: AbsorbPointer(
            child: AnimatedOpacity(
              opacity: _phase == _SplashPhase.showing ? 1 : 0,
              duration: widget.fadeDuration,
              curve: Curves.easeOut,
              child: const StartupSplash(),
            ),
          ),
        ),
      ],
    );
  }
}
