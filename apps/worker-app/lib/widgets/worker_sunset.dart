/// 工作端终止服务（sunset）· **完全阻断版 v1.8.2（码 60）／立即生效，无宽限期**
///
/// 负责人 2026-10-06 拍板（原话「目前这个 app 还没正式投入使用，所以没用、没迁移的打手」）：
/// **现在立即停用工作端 App，不需要 7 天宽限期**。服务端 worker 模块与打手账号/角色
/// **一行未动、必须保留**（老板端「打手态」就是靠 companion 会话调 `/worker/*`，
/// 见 CLAUDE.md 结构规则 11）。
///
/// **本版对用户的口径（只有一个时态：现在时）**：
/// - 冷启动先出阻断式提示页（`WorkerSunsetBlockPage`）：**只剩「前往下载」**；
///   「暂时继续使用」那条分支在 [kWorkerSunsetBlocking] = `true` 下**永不渲染**
///   （判定短路，既不看日期，也不看手机时间）。
/// - **不再出现"将于 X 月 X 日停止服务"**：既然打开就停，说"将来某天停"只会让人以为还有时间
///   （[kWorkerSunsetDateText] 因此**不再出现在任何用户可见文案里**）。
/// - **服务端兜底**：`system_setting.worker_app_sunset_at`（线上默认 `2026-10-13 00:00` Asia/Shanghai）
///   仍会拒绝 `role=worker` 的 **primary** 会话（登录 403 / 请求 401 / WS 拒连）——
///   那是给"别处还开着的旧版本"的兜底，**打手态 companion 一律不受影响**。
///   客户端**刻意不去改它**（改早了会打断用 worker primary 登录的既有回归套件），
///   用户可见文案里也**不给这个日期**，只说明"旧版本入口也会被关闭"（[kWorkerSunsetServerNote]）。
///
/// **两个常量的关系（别混）**：
/// - [kWorkerSunsetBlocking] = **立即阻断**开关（本版 = `true`）：任何时间都不可继续，日期判定被短路；
/// - [kWorkerSunsetDate] = 原来的到期日（2026-10-13）：**只在 `blocking == false` 时参与判定**
///   （备用分支，本版不发布）。
///
/// 判定仍然只有一份纯函数实现 [workerSunsetCanContinue]，`blocking` 与 `now` **都可注入** ——
/// 所以"备用开关为 false 时的到期逻辑"仍被单测逐条覆盖（证明它没被删），
/// 而产线调用一律走默认值 `blocking = kWorkerSunsetBlocking = true`。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show FontWeight, TextStyle;

/// 完全阻断版发布日 / **立即生效日**（v1.8.2 / 码 60，2026-10-06）
///
/// 注意：`DateTime` 没有 const 构造（Dart 语言限制），所以日期是 `final` 顶层常量；
/// 不变量由单测守住：`kWorkerSunsetDate - kWorkerSunsetReleaseDate == kWorkerSunsetGraceDays`。
final DateTime kWorkerSunsetReleaseDate = DateTime(2026, 10, 6);

/// 原迁移宽限期（天）——v1.8.0／码58 的「暂时继续使用（7 天内有效）」那个 7。
///
/// **本版不再给宽限期**（负责人 2026-10-06：平台还没正式投用、没有未迁移的打手）。
/// 常量保留的两个理由：它仍是 [kWorkerSunsetDate] 的来历（发布日 + 7 天），
/// 单测也还守着这条不变量；但它**不再出现在任何用户可见文案里**。
const int kWorkerSunsetGraceDays = 7;

/// 原来的到期日 = 发布日 + 7 天 = 2026-10-13
///
/// 本版（[kWorkerSunsetBlocking] = true）**客户端不再看它**：它现在的身份是
/// **服务端兜底日**的文档口径（`system_setting.worker_app_sunset_at` 的线上默认值），
/// 以及备用开关（`blocking == false`）那条分支的判定依据。
final DateTime kWorkerSunsetDate = DateTime(2026, 10, 13);

/// 「10 月 13 日」——服务端兜底日的中文写法。
///
/// ⚠️ **本版不再出现在用户可见文案里**（立即生效还给日期 = 误导用户以为还有时间）；
/// 保留它只为让文档与回归断言跟 [kWorkerSunsetDate] 对齐（唯一出处，别在别处再写一遍日期）。
const String kWorkerSunsetDateText = '10 月 13 日';

/// **立即阻断开关（本版 = `true`）**
///
/// - `true`（本版）= **任何时间**都不给「暂时继续使用」（立即彻底阻断，不看日期）；
/// - `false`（v1.8.0／码58、v1.8.1／码59 的旧口径）= 到 [kWorkerSunsetDate] 当天 00:00 自动阻断，
///   到期前仍可「暂时继续使用」——**这条分支已不发布**，只保留判定实现与回归覆盖。
const bool kWorkerSunsetBlocking = true;

/// **停止服务说明（用户可见的唯一一句"已停止服务"，阻断页与引导条共用）**
///
/// 现在时、**不带日期**：立即生效还说"将于／已于 某月某日 停止服务"都会误导
/// （用户会以为"那我还有时间"或"那天才停，今天还能用"）。
const String kWorkerSunsetBlockedNote = '工作端已停止服务，请下载「祁连山电竞」App，'
    '在「我的 → 身份」里绑定打手账号后继续接单。';

/// **服务端兜底说明（刻意不给具体日期）**
///
/// 线上 `system_setting.worker_app_sunset_at`（默认 2026-10-13 00:00 Asia/Shanghai）是**兜底**，
/// 负责"别处还开着的旧版本"。写具体日期等于告诉用户"还有几天可用"，所以只说会关、不说哪天。
const String kWorkerSunsetServerNote = '旧版本的入口也会由服务端一并关闭，不必再找旧安装包。';

/// **是否已到原到期日**（[kWorkerSunsetDate] 当天 00:00 起为真）——纯函数，日期由调用方注入
///
/// 这是备用开关（`blocking == false`）那条分支的日期判定；产线在 [kWorkerSunsetBlocking] = true 时
/// 被 [workerSunsetStopped] 短路，**不会走到它**（实现与用例都保留，别删）。
///
/// 边界口径：`2026-10-12 23:59:59` → false；`2026-10-13 00:00` → true。
bool workerSunsetEnded(DateTime now) => !now.isBefore(kWorkerSunsetDate);

/// **工作端是否已停止服务**（UI 层只读这一个判定）
///
/// `已停止 == kWorkerSunsetBlocking || 现在 >= kWorkerSunsetDate`
///
/// - [blocking] 可注入：产线用默认值（true → 恒真）；单测传 `false` 才能覆盖日期那两条分支；
/// - 传 [DateTime.now] 时是生产行为；传固定日期即可确定性地复现边界。
bool workerSunsetStopped(DateTime now, {bool blocking = kWorkerSunsetBlocking}) =>
    blocking || workerSunsetEnded(now);

/// **能不能「暂时继续使用」**——纯函数（唯一的判定实现，UI 层只调它）
///
/// `可继续 == !blocking && 现在 < 到期日`
///
/// 本版 `blocking = true` → **任何时间（过去 / 现在 / 未来）都返回 false**；
/// 单测用 `blocking: false` 注入，继续覆盖"到期前 true / 到期起 false"两条分支。
bool workerSunsetCanContinue(DateTime now, {bool blocking = kWorkerSunsetBlocking}) =>
    !workerSunsetStopped(now, blocking: blocking);

/// 停止服务文案的统一样式（**阻断提示页的停止服务状态条**用它；
/// 引导条正文样式在 `migration_notice.dart` 的 `_bodyStyle`，两处都不各写各的字号/字重）
const TextStyle kWorkerSunsetTextStyle = TextStyle(
  fontSize: 12.5,
  fontWeight: FontWeight.w700,
  color: AppColors.warning,
  height: 1.35,
);

/// 阻断提示的会话级开关（**只在内存里**：不落盘、不加依赖）
///
/// - 冷启动必定阻断（[blocking] == true）—— 对应"打开 App 后显著阻断式提示"；
/// - [canContinue] 本版**恒 false**（[kWorkerSunsetBlocking] = true）：不渲染「暂时继续使用」，
///   [continueUsing] 也会被拒绝 —— 这是"立即阻断、不可跳过"的那一道；
/// - 备用开关改回 `false` 时，这里才回到"到期前可放行本次运行"的老行为
///   （判定同样走纯函数 [workerSunsetCanContinue]，没有第二套实现）。
///
/// **时间来源可注入**：判定一律走 [now] 这个可覆盖的取值函数，而不是各处直接
/// `DateTime.now()` —— 单测与出图可以固定到"到期前一天 / 当天 00:00 / 到期后"，
/// 不受"今天真实是几号"影响（这正是纯函数 [workerSunsetCanContinue] 存在的意义）。
/// 生产环境不设置它，行为就是系统本地时间。
class WorkerSunsetGate extends ChangeNotifier {
  WorkerSunsetGate._();

  static final WorkerSunsetGate instance = WorkerSunsetGate._();

  bool _continued = false;

  /// 可注入的"现在"（默认系统本地时间）
  DateTime Function() _now = DateTime.now;

  /// 当前用于判定的"现在"（生产 = 系统本地时间；测试/出图可覆盖）
  DateTime get now => _now();

  /// 覆盖"现在"（**测试/出图专用**：边界必须能确定性复现）
  @visibleForTesting
  set debugNow(DateTime Function() value) => _now = value;

  /// true = 用阻断提示页替代主界面（首页/登录页都进不去）
  bool get blocking => !_continued;

  /// 工作端是否已停止服务（本版恒 true，文案与判定同源，UI 只读这个）
  bool get stopped => workerSunsetStopped(now);

  /// 是否允许「暂时继续使用」：本版**恒 false**（[kWorkerSunsetBlocking] = true →
  /// 按钮不渲染，且 [continueUsing] 直接拒绝）；备用开关为 false 时才是"到期前 true"
  bool get canContinue => workerSunsetCanContinue(now);

  /// 「暂时继续使用（7 天内有效）」：放行本次运行（**本版永不生效**）
  ///
  /// 立即阻断下 [canContinue] 恒 false，即使用户把系统时间改回去、或直接调到这里也进不去
  /// （工作端 App 到此为止；服务端另有兜底，见文件头）。
  void continueUsing() {
    if (!canContinue || _continued) return;
    _continued = true;
    notifyListeners();
  }

  /// 测试专用：复位到"冷启动"状态（生产不调用）
  @visibleForTesting
  void debugReset() {
    _continued = false;
    _now = DateTime.now;
    notifyListeners();
  }
}
