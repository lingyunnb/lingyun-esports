import 'package:fish_core/fish_core.dart';

// ⚠️ 条件导入：**平台实现只能在 dart:io 存在时被编译进来**
//
//   Web / 无 dart:io  → worker_notifier_noop.dart   （安全 no-op，零插件依赖）
//   Android / iOS     → worker_local_notifier.dart  （flutter_local_notifications 真实通知）
//
// ## 为什么要有这层（**按实测口径写，不夸大**）
// 2026-10-15 负责人定案「要做网页版（H5）」时补的这层隔离。
//
// ⚠️ **起因的判断被实测证伪了，如实记在这里**：原以为 `flutter_local_notifications`
//   会让 web 构建失败，但把 import 改回**无条件**后，`flutter build web --release`
//   **照样 `√ Built`** —— 该插件 22.3.2 的 lib 里没有 `dart:io`，且自带
//   `flutter_local_notifications_web` 分支；dart2js 把 `dart:io` 当"运行期不支持"，
//   而不是**编译错误**。所以这层**不是"救命补丁"**。
//
// 它真实的收益是**架构正确性 + 防御性**：
//   ① `main.dart` 保持**平台无关** —— 宿主不再认识任何具体插件；
//   ② Web 产物里**绝不实例化平台通道插件**（不建渠道、不注册回调、不查权限）；
//   ③ 将来若真遇到**编译期就炸**的插件，同一条路即可隔离，宿主不必再改。
// 换端只换注入实现，`core` 的判定逻辑一行不改、零分叉。
import 'worker_notifier_noop.dart'
    if (dart.library.io) 'worker_local_notifier.dart' as impl;

/// 创建**当前平台**的打手态通知器（宿主 `main.dart` 的唯一入口）
///
/// 调用方拿到的一律是 `WorkerNotifier` 接口 —— **不需要知道自己在哪个平台**。
WorkerNotifier createWorkerNotifier() => impl.createWorkerNotifier();
