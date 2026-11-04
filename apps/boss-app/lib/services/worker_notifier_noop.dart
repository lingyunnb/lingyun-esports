import 'package:fish_core/fish_core.dart';

/// 打手态通知器 —— **Web / 无平台通知能力环境的空实现**
///
/// ## 为什么必须有这个文件
/// 负责人 2026-10-15 定案：**要做网页版（路线 A：H5）**。
/// 而 Android 侧用的 `flutter_local_notifications` **不支持 Web** ——
/// 它的 Dart 实现依赖 `dart:io`（Web 上不存在）→ 一旦被无条件 import，
/// **`flutter build web` 直接编译失败**。
///
/// 所以宿主（`main.dart`）**不直接 import 平台实现**，改为经
/// [createWorkerNotifier]（`worker_notifier_factory.dart`）做**条件导入**：
///   - Android / iOS  → `worker_local_notifier.dart`（真实通知）
///   - Web / 其它     → 本文件（安全 no-op）
///
/// 这也是"core 只声明接口、宿主注入平台能力"这条分层的自然延续：
/// **换端时只换注入实现，core 一行不改、判定逻辑零分叉。**
///
/// ## 为什么全部返回"否"而不是抛异常
/// 通知是**增强能力不是主链路**。Web 上用户本来就不会收到推送
/// （Safari 需 PWA 装到主屏才有 Web Push），所以这里如实回 `false`
/// 让上层走"静默降级"分支（发一条中文说明后不再打扰），
/// **绝不能因为"通知不可用"影响下单/接单**。
class WorkerNotifierNoop implements WorkerNotifier {
  const WorkerNotifierNoop();

  @override
  Future<WorkerNoticeRoute?> init() async => null;

  @override
  /// ⚠️ **刻意返回 true**（不是 false），理由如下：
  ///
  /// Web 上根本不存在"系统设置里的通知开关"这个入口。若返回 false，上层会判定成
  /// "用户拒绝了通知权限"，进而弹那句「未开启通知权限：…可在系统设置里打开」——
  /// 在网页版上这是**误导**（用户按提示去系统设置里找，什么也找不到）。
  ///
  /// 返回 true = 上层不弹窗、不打扰；而 [show] 仍是 no-op，**不会真的发出任何通知**。
  /// 也就是：**能力缺失靠"什么都不做"表达，不靠"假装被拒"**。
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> show(WorkerNotice notice) async {}

  @override
  Future<void> cancelAll() async {}
}

/// 供条件导入统一调用（与 `worker_local_notifier.dart` 的同名函数配对）
WorkerNotifier createWorkerNotifier() => const WorkerNotifierNoop();
