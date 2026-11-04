import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'app_updater.dart';

/// 更新流程状态
enum UpdateFlow { idle, downloading, verifying, done, failed }

/// 更新中心（双端共用：老板端 boss / 工作端 worker，负责人云端更新需求）：
/// 启动检测 → 弹窗提示 → 下载（进度 + 实时速度 + 剩余时间）→ 哈希校验 → 调起系统安装。
/// 强制更新被用户关闭后 forceBlocked=true，RootGate 以阻断页替代主界面。
///
/// appType 必须在各端启动时 configure 注入（boss / worker）——未配置即抛错，
/// 避免工作端误检老板端版本通道（拿错安装包）。
///
/// 2026-10-06 提速专项：下载改走 [AppUpdater] 的**多连接分片并行**，
/// 这里只负责把"累计字节 / 实时速度 / 剩余时间 / 是否并行"暴露给 UI，
/// 并保证进度**单调不倒退**（并行下各片乱序完成也不会回退）。
class UpdateCenter extends ChangeNotifier {
  UpdateCenter._();
  static final UpdateCenter instance = UpdateCenter._();

  String? _appType;
  String? get appType => _appType;

  /// 各端启动时注入自身类型（'boss' / 'worker'）
  void configure(String appType) {
    if (appType != 'boss' && appType != 'worker') {
      throw ArgumentError('未知应用类型: $appType（应为 boss / worker）');
    }
    _appType = appType;
  }

  AppUpdateInfo? _latest;
  AppUpdateInfo? get latest => _latest;

  bool _forceBlocked = false;
  bool get forceBlocked => _forceBlocked;
  set forceBlocked(bool v) {
    if (_forceBlocked == v) return;
    _forceBlocked = v;
    notifyListeners();
  }

  UpdateFlow _flow = UpdateFlow.idle;
  UpdateFlow get flow => _flow;

  int _downloaded = 0;
  int _total = 0;
  int get downloaded => _downloaded;
  int get total => _total;

  /// 下载进度 0..1（total 未知时为 0）
  double get progress => _total > 0 ? (_downloaded / _total).clamp(0.0, 1.0) : 0;

  /// 实时速度（字节/秒，滑动窗口平均）；无样本时为 0
  double _speed = 0;
  double get speedBytesPerSecond => _speed;

  /// 展示用速度（MB/s，保留 2 位）
  String get speedText => '${(_speed / 1024 / 1024).toStringAsFixed(2)} MB/s';

  /// 预计剩余时间；速度为 0/未知时为 null（UI 显示"计算中"）
  Duration? get remaining {
    if (_speed <= 0 || _total <= 0) return null;
    final int left = _total - _downloaded;
    if (left <= 0) return Duration.zero;
    final double secs = left / _speed;
    if (secs.isNaN || secs.isInfinite || secs > 86400) return null;
    return Duration(milliseconds: (secs * 1000).round());
  }

  /// 展示用剩余时间文案（如 `剩余 12 秒` / `剩余 1 分 20 秒`）
  String get remainingText {
    final Duration? d = remaining;
    if (d == null) return '计算中…';
    if (d.inSeconds <= 0) return '即将完成';
    if (d.inSeconds < 60) return '剩余 ${d.inSeconds} 秒';
    return '剩余 ${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
  }

  /// 本次下载是否走了分片并行（UI 标注"多连接加速"；回退后自动置 false）
  bool get parallelActive => _parallelForShot ?? AppUpdater.instance.parallelActive;

  /// 停滞重试状态（2026-10-17）：>0 表示"看门狗判死过、正在退避重试第 n 次"。
  ///
  /// 为什么必须暴露给 UI：停滞时**没有任何错误**（连接还在、就是不给数据），
  /// 最坏要 ~3 分钟才走到失败态；这期间界面若只说「0.00 MB/s · 计算中…」，
  /// 用户看到的就是"卡死了"（负责人原话："网没问题但卡住不下了"）。
  int _stallAttempt = 0;
  int _stallMax = 3;
  int get stallAttempt => _stallAttempt;
  bool get stallRetrying => _stallAttempt > 0;

  /// 停滞重试文案；不在重试中时为空串。
  /// - 还有下一轮：`网络缓慢，正在重试（1/3），只补未完成的部分…`
  ///   说"只补未完成的部分"是**准确的**：重试按**片**重取（已完成区间记在 sidecar 里，
  ///   每轮用 `pendingRanges(shards, done)` 重建队列），不会整包重下 ——
  ///   用户不会以为要从 0 开始（片数提到 12×4 后这一点更重要：片更小更多）。
  /// - 已经是最后一轮：`网络缓慢，最后一次重试（3/3），仍无进展将中断下载…`
  ///   （给明确预期：不是无限等，再卡一次就出失败态 + 重试按钮）
  String get stallNotice {
    if (_stallAttempt <= 0) return '';
    if (_stallAttempt >= _stallMax) {
      return '网络缓慢，最后一次重试（$_stallAttempt/$_stallMax），仍无进展将中断下载…';
    }
    return '网络缓慢，正在重试（$_stallAttempt/$_stallMax），只补未完成的部分…';
  }

  String? _error;
  String? get error => _error;

  String? _filePath;
  String? get filePath => _filePath;

  /// 取消令牌：`cancel()` 时立即断流，`download()` 会清理临时文件
  CancelToken? _cancelToken;

  /// 启动检测：仅服务端存在比当前版本更新的版本时返回更新信息
  Future<AppUpdateInfo?> check() async {
    final type = _appType;
    if (type == null) {
      throw StateError('UpdateCenter 未配置 appType：请在 App 启动时调用 UpdateCenter.instance.configure(...)');
    }
    final info = await AppUpdater.instance.checkUpdate(appType: type);
    _latest = (info?.hasUpdate == true) ? info : null;
    notifyListeners();
    return _latest;
  }

  /// 下载 + 哈希校验；失败可重试（重试会**接着已下部分续传**，不重头下）
  Future<bool> download() async {
    final info = _latest;
    if (info == null) return false;
    _flow = UpdateFlow.downloading;
    _downloaded = 0;
    _total = info.fileSize;
    _speed = 0;
    _stallAttempt = 0;
    _error = null;
    _filePath = null;
    _cancelToken = CancelToken();
    notifyListeners();
    try {
      final path = await AppUpdater.instance.download(
        info,
        cancelToken: _cancelToken,
        onProgress: (done, total) {
          // AppUpdater 已保证单调；这里再夹一次，杜绝 UI 侧任何回退可能
          if (done > _downloaded) {
            _downloaded = done;
            _stallAttempt = 0; // 有真实进展 → 撤掉"正在重试"（进度绝不回退）
          }
          if (total > 0) _total = total;
          notifyListeners();
        },
        onSpeed: (bps) {
          _speed = bps;
          notifyListeners();
        },
        onStallRetry: (attempt, maxAttempts) {
          // 判死要退避重试了：明确告诉用户"在重试"，而不是让他看着 0.00 MB/s 干等
          _stallAttempt = attempt;
          _stallMax = maxAttempts;
          _speed = 0;
          notifyListeners();
        },
      );
      _flow = UpdateFlow.verifying;
      _speed = 0;
      notifyListeners();
      try {
        await AppUpdater.instance.verifyHash(path, info.fileHash);
      } catch (e) {
        // 校验失败：删除文件，绝不把坏包交给系统安装器
        await AppUpdater.instance.discard(path);
        rethrow;
      }
      _filePath = path;
      _flow = UpdateFlow.done;
      notifyListeners();
      return true;
    } catch (e) {
      _flow = UpdateFlow.failed;
      _speed = 0;
      _stallAttempt = 0; // 已失败：由失败态接管，不再显示"正在重试"
      _error = _isCancelled(e) ? '下载已取消' : (e is ApiException ? e.message : '下载失败，请检查网络后重试');
      notifyListeners();
      return false;
    } finally {
      _cancelToken = null;
    }
  }

  /// 取消下载：立即断流（AppUpdater 负责清理 .part 与 sidecar）
  void cancel() {
    final CancelToken? t = _cancelToken;
    if (t != null && !t.isCancelled) t.cancel('用户取消下载');
  }

  static bool _isCancelled(Object e) =>
      e is DioException && e.type == DioExceptionType.cancel;

  /// **测试专用**：把"下载中"的展示态直接摆好（出图/UI 单测用）。
  ///
  /// 为什么需要它：下载中态的取值全部来自真实网络回调，而出图测试不能打真实网络
  /// （也不该为了截图去下载 26MB）。语义边界：只写展示字段 + 置 downloading，
  /// **不触碰任何下载状态机/令牌**，生产代码路径完全不受影响。
  ///
  /// [stallAttempt]：>0 时同时摆出"正在退避重试（n/max）"的展示态（2026-10-17），
  /// 用于验证"停滞重试期间 UI 说清楚在重试、且进度不回退"。
  @visibleForTesting
  void debugSetProgressForShot({
    required int downloaded,
    required int total,
    required double speedBytesPerSecond,
    required bool parallel,
    int stallAttempt = 0,
    int stallMax = 3,
  }) {
    _flow = UpdateFlow.downloading;
    _downloaded = downloaded;
    _total = total;
    _speed = speedBytesPerSecond;
    _parallelForShot = parallel;
    _stallAttempt = stallAttempt;
    _stallMax = stallMax;
    _error = null;
    notifyListeners();
  }

  bool? _parallelForShot;

  /// **测试专用**：把"失败"的展示态直接摆好（UI 单测用）。
  ///
  /// 语义边界与 [debugSetProgressForShot] 完全一致：只写展示字段 + 置 failed，
  /// **不触碰下载状态机/令牌**。存在的理由：失败文案必须被"看得见"（负责人要求
  /// "卡死到上限要明确失败 + 可重试，不能停在计算中"），而真实失败态只有真跑网络
  /// 才能进，出图/UI 单测不能打真实网络。
  @visibleForTesting
  void debugSetFailureForShot(String message, {int downloaded = 0, int total = 0}) {
    _flow = UpdateFlow.failed;
    _error = message;
    _downloaded = downloaded;
    _total = total;
    _speed = 0;
    _parallelForShot = false;
    _stallAttempt = 0;
    notifyListeners();
  }

  void reset() {
    _flow = UpdateFlow.idle;
    _downloaded = 0;
    _total = 0;
    _speed = 0;
    _stallAttempt = 0;
    _parallelForShot = null;
    _error = null;
    _filePath = null;
    notifyListeners();
  }
}
