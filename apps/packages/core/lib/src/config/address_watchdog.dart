/// 运行期**地址看门狗**（2026-10-06 地址发现韧性专项）。
///
/// 解决的问题（实测背景）：地址只在**启动时**解析一次。一旦运行中地址失效
/// （隧道重开换了域名、ngrok 额度耗尽返回 403、换网后局域网地址不通），
/// 客户端会一直对着那个死地址发请求 —— 用户看到的是"网络连接失败"，
/// 唯一的自救方式是杀掉 App 重开（而重开也未必好，因为引导源本身也可能不可达）。
///
/// 本类把"地址失效"变成一个**可观测、可自愈**的状态机：
///
/// ```
///   启动解析失败            ─┐
///   连续 N 次请求失败        ├─→ 退避等待 ─→ 清缓存 ─→ 重走多源 bootstrap + 探活
///   首次 WS 连不上（严重）  ─┘                              │
///                                            ┌─────────────┴──────────────┐
///                                     地址真的变了                   地址没变/仍不可达
///                                            │                            │
///                                  AppConfig 热切换（旧请求不串味）   继续累计失败、
///                                  + onRefreshed（WS 重连）          退避翻倍，直到上限
/// ```
///
/// **不做的事（硬约束）**：
/// - 不引依赖、不改业务逻辑、不碰身份/订单/结算/聊天；
/// - 不无限重试：单进程最多 [maxRefreshes] 次，间隔按 [baseBackoff]×2^k 指数退避、
///   封顶 [maxBackoff]；到上限就停手（等下次冷启动或用户手动下拉刷新）。
///
/// 为什么放在 core 而不是 App 里：老板端与工作端都要这套能力，且它必须与
/// `ApiClient` / `RealtimeClient`（都在 core）同源，否则又是一份会漂的复制品。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../api/api_cache.dart';
import '../api/api_client.dart';
import '../config/app_address.dart';
import '../config/app_config.dart';
import '../config/app_config_runtime.dart';
import '../realtime/realtime_client.dart';

class AddressWatchdog {
  AddressWatchdog._();

  /// 全局单例（App 在 `main()` 里 `install()` 一次）
  static final AddressWatchdog instance = AddressWatchdog._();

  // ------------------------------------------------------------------ 策略（可调）

  /// 连续多少次"网络类失败"触发重取（默认 3）
  int failureThreshold = 3;

  /// 首次重取前的退避基数（默认 5s）；第 k 次重取前等 `baseBackoff × 2^(k-1)`
  Duration baseBackoff = const Duration(seconds: 5);

  /// 退避上限（默认 5 分钟）—— 指数增长到顶后不再变长
  Duration maxBackoff = const Duration(minutes: 5);

  /// 单进程内的重取**上限**（默认 6 次）—— 到顶就彻底停手，杜绝死循环
  int maxRefreshes = 6;

  // ------------------------------------------------------------------ 钩子（可注入）

  /// 热切换成功后的回调（生产接到 `RealtimeClient.shared.rebind()`，让 WS 也换到新地址）
  void Function(AddressResolution result)? onRefreshed;

  /// 测试钩子：替换"重新解析"实现（默认 [AppAddressResolver.resolve]）
  Future<AddressResolution> Function()? debugResolve;

  /// 测试钩子：替换退避调度（默认真 `Timer`）。测试里直接同步触发，不必等 5 秒。
  void Function(Duration delay, void Function() fire)? debugSchedule;

  /// 日志出口（null = 走 `debugPrint('[address] watchdog ...')`）
  void Function(String message)? debugLog;

  // ------------------------------------------------------------------ 状态（观测）

  int _consecutiveFailures = 0;
  int _refreshCount = 0;
  bool _running = false;
  bool _installed = false;
  Timer? _timer;
  Duration? _pendingDelay;

  /// 已连续失败次数
  int get consecutiveFailures => _consecutiveFailures;

  /// 已重取次数（含正在进行的那一次）
  int get refreshCount => _refreshCount;

  /// 是否正在重取
  bool get refreshing => _running;

  /// 是否已达重取上限（`true` = 不再自动重取）
  bool get exhausted => _refreshCount >= maxRefreshes;

  /// 已排定的退避时长（测试断言"确实退避了"；未排定 = null）
  Duration? get pendingDelay => _pendingDelay;

  /// 是否已挂载钩子
  bool get installed => _installed;

  // ------------------------------------------------------------------ 安装

  /// 挂上 `ApiClient` / `RealtimeClient` 的钩子（**幂等**，重复调用无副作用）。
  ///
  /// 由 App 的 `main()` 显式调用：不做成"解析时自动安装"，是为了让
  /// "谁改了我的全局钩子"这件事在代码里一眼可见。
  void install() {
    if (_installed) return;
    _installed = true;
    ApiClient.onNetworkFailure = (Object? e) => noteFailure(e);
    ApiClient.onNetworkSuccess = noteSuccess;
    RealtimeClient.onConnectFailed = () => noteConnectFailure();
    _log('已安装：阈值=$failureThreshold 次连续失败｜退避=${baseBackoff.inSeconds}s×2^k'
        '（上限 ${maxBackoff.inMinutes}min）｜重取上限=$maxRefreshes 次/进程');
  }

  /// 卸载钩子（测试用；生产不需要）
  void uninstall() {
    _installed = false;
    ApiClient.onNetworkFailure = null;
    ApiClient.onNetworkSuccess = null;
    RealtimeClient.onConnectFailed = null;
    _timer?.cancel();
    _timer = null;
    _pendingDelay = null;
  }

  // ------------------------------------------------------------------ 信号

  /// 一次**逻辑请求**网络类失败（`ApiClient` 回调；`error` 仅用于日志）
  void noteFailure(Object? error) {
    _consecutiveFailures += 1;
    if (_consecutiveFailures < failureThreshold) {
      _log('网络失败 $_consecutiveFailures/$failureThreshold'
          '${error == null ? '' : '（$error）'}');
      return;
    }
    _scheduleRefresh('连续 $_consecutiveFailures 次请求失败');
  }

  /// 服务端答话了（任何 HTTP 响应，含 4xx/5xx）→ 说明**地址是活的**，计数清零
  void noteSuccess() {
    if (_consecutiveFailures == 0) return;
    _log('请求成功，连续失败计数 $_consecutiveFailures → 0');
    _consecutiveFailures = 0;
  }

  /// WS 握手就失败 —— 严重信号，不等累计阈值，立刻排一次重取。
  ///
  /// 注意"设备根本没网"这一情形：重取同样会失败，于是走退避 + 上限，
  /// 第 [maxRefreshes] 次之后彻底停手（不会退化成耗电的重试风暴）。
  void noteConnectFailure() {
    _consecutiveFailures = failureThreshold;
    _scheduleRefresh('首次 WS 连不上');
  }

  /// 启动解析结果反馈（`main()` 里 `resolve()` 完成后调用）：
  /// 没拿到下发地址（回退内置）说明引导这条腿当前是瘸的 → 排一次重取。
  void noteStartup(AddressResolution r) {
    if (r.fromBootstrap && r.error == null) {
      _log('启动解析成功：${r.address}');
      return;
    }
    _consecutiveFailures = failureThreshold;
    _scheduleRefresh('启动解析未拿到可用下发地址（error=${r.error ?? '-'}）');
  }

  // ------------------------------------------------------------------ 重取

  void _scheduleRefresh(String reason) {
    if (_running) {
      _log('$reason → 重取已在进行中，不重复排队');
      return;
    }
    if (exhausted) {
      _log('$reason → 已达重取上限 $maxRefreshes 次/进程，停止自动重取'
          '（请检查隧道/网络，或重启 App）');
      return;
    }
    if (_timer != null) {
      _log('$reason → 已有排定中的重取（${_pendingDelay?.inMilliseconds}ms 后），不重复排队');
      return;
    }
    final int attempt = _refreshCount + 1;
    final Duration delay = _backoffFor(attempt);
    _pendingDelay = delay;
    _log('$reason → ${delay.inMilliseconds}ms 后执行第 $attempt/$maxRefreshes 次重取');

    final void Function(Duration, void Function())? schedule = debugSchedule;
    final void Function() fire = () {
      _timer = null;
      _pendingDelay = null;
      unawaited(refresh(reason: reason));
    };
    if (schedule != null) {
      schedule(delay, fire);
      return;
    }
    _timer = Timer(delay, fire);
  }

  /// 第 [attempt] 次（1 基）重取的退避时长：`base × 2^(attempt-1)`，封顶 [maxBackoff]
  Duration _backoffFor(int attempt) {
    final int shift = (attempt - 1).clamp(0, 20);
    // 用毫秒做乘法并对 maxBackoff 封顶，避免左移溢出（attempt 已被 clamp）
    final int ms = baseBackoff.inMilliseconds * (1 << shift);
    final int capped = ms <= 0 || ms > maxBackoff.inMilliseconds
        ? maxBackoff.inMilliseconds
        : ms;
    final int floorMs = baseBackoff.inMilliseconds <= 0 ? 0 : baseBackoff.inMilliseconds;
    return Duration(milliseconds: capped < floorMs ? floorMs : capped);
  }

  /// **执行一次重取 + 热切换**（也可手动调；同一时刻只有一个在跑）。
  ///
  /// 返回新的解析结果（被跳过/异常时为 null）。**绝不抛异常。**
  Future<AddressResolution?> refresh({String reason = '手动'}) async {
    if (_running) {
      _log('重取已在进行中，跳过（$reason）');
      return null;
    }
    if (exhausted) {
      _log('已达重取上限 $maxRefreshes 次/进程，跳过（$reason）');
      return null;
    }
    _running = true;
    _refreshCount += 1;
    final int attempt = _refreshCount;
    final String before = AppConfig.apiBase;
    try {
      // 清缓存：地址变了之后缓存键本来就不同（keyOf 含 apiBase），
      // 但"旧地址缓存还占着内存、且可能被仍在飞行的请求写回"这一点要主动切断。
      ApiCache.instance.clear();
      _log('第 $attempt 次重取开始（$reason）｜当前 api=$before source=${AppConfig.addressSource}');
      final Future<AddressResolution> Function() doResolve =
          debugResolve ?? AppAddressResolver.resolve;
      final AddressResolution r = await doResolve();
      final String after = AppConfig.apiBase;
      _consecutiveFailures = 0;
      final bool switched = before != after;
      _log('第 $attempt 次重取完成：source=${r.address.source} '
          'from=${r.address.bootstrapFrom ?? '-'} api=$after '
          'latency=${r.address.latencyMs ?? '-'}ms '
          'candidates=${r.address.candidates.length} '
          '${switched ? '【已热切换 $before → $after】' : '（地址未变）'}'
          '${r.error == null ? '' : ' err=${r.error}'}');

      if (switched) {
        // 一次**真实**的地址切换 = 自愈成功 → 重取预算回满
        // （否则"上午切过一次"会永久吃掉下午的额度）。
        // 注意：只在真切换时回满；"仍然不可达"的失败轮次继续累计，直到 maxRefreshes 停手。
        _refreshCount = 0;
        AppConfigRuntime.noteSwitch(DateTime.now());
        try {
          onRefreshed?.call(r);
        } catch (e) {
          _log('onRefreshed 回调异常（已忽略）：$e');
        }
      }
      return r;
    } catch (e) {
      _log('第 $attempt 次重取异常（已忽略）：$e');
      return null;
    } finally {
      _running = false;
    }
  }

  // ------------------------------------------------------------------ 测试辅助

  /// 测试钩子：第 [attempt] 次（1 基）重取会用的退避时长（断言退避曲线用）
  Duration debugBackoffFor(int attempt) => _backoffFor(attempt);

  /// 测试钩子：把全部状态**与策略参数**复位到默认值（不影响已安装的钩子）
  ///
  /// 策略也要复位：单测里常有"把 maxRefreshes 调到 3 好快速撞上限"的用例，
  /// 若不还原，下一个用例会莫名带着上一个用例的策略跑。
  void debugReset() {
    failureThreshold = 3;
    baseBackoff = const Duration(seconds: 5);
    maxBackoff = const Duration(minutes: 5);
    maxRefreshes = 6;
    _consecutiveFailures = 0;
    _refreshCount = 0;
    _running = false;
    _pendingDelay = null;
    _timer?.cancel();
    _timer = null;
  }

  void _log(String msg) {
    final void Function(String)? sink = debugLog;
    if (sink != null) {
      sink(msg);
      return;
    }
    debugPrint('[address] watchdog $msg');
  }
}
