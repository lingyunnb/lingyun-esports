/// 祁小山 AI —— **冷启动一次性初始化**（负责人 2026-10-04 定稿）
///
/// ## 触发时机（唯一）
/// **App 大退后重新打开时，调一次 `POST /user/ai/reset`。**
/// 以前是"进入 AI 页 reset + 离开 AI 页 stop+reset"，现在**不再**在进入/离开时轮换：
///
/// - **同一次 App 运行内**：AI 会话不轮换 —— 离开 AI 页再回来，刚才的对话还在（页面常驻 + 不 reset）
/// - **大退（进程结束）后重新打开**：这一次 reset 把服务端 `ai_conversation.current_session` 换掉
///   → 用户看到的是全新对话（开场白 + 快捷问题）；旧对话一条不删（管理端 `GET /admin/ai/messages` 仍可查）
///
/// ## 为什么用"进程内一次性标记"判定大退
/// **进程重新开始 = 大退**（用户从最近任务里划掉 / 被系统回收后重开）—— 这正是要的语义。
/// 刻意**不用**时间窗，也不用 AppLifecycle 的 paused/resumed 去近似：
/// 时间窗会把"切后台五分钟再回来"误判成大退；paused 在锁屏、切后台时就会触发 —— 那两次都不算大退。
///
/// ## 两个调用点，同一道门（进程内只发一次）
/// - `main()` → `RootGate` 恢复本地会话之后（冷启动时已登录的正常路径）
/// - `HomeShell.initState()`（冷启动时未登录、随后才登录 → 登录后首次挂载补上）
///
/// **未登录（没有 token）不消耗这次机会**：请求根本发不出去，谈不上"初始化过"，
/// 留给真正拿到 token 的那次挂载（否则"未登录→登录"这条路径会漏掉轮换）。
///
/// ## 与页面的衔接
/// - [settled]：`AiChatPage` 首拉历史前 await 它。冷启动的 reset 还在飞的时候先拉历史的话，
///   会把上一条会话的消息铺上屏、随后被新 session 顶掉 —— 用户看到旧对话闪一下。
/// - [takeColdStartStaleGuard]：reset 失败（离线冷启动）时的兜底门控，见方法注释。
///
/// 全程**失败静默**：不弹错、不阻塞启动；本次运行就按"没轮换成功"处理。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/foundation.dart';

import 'ai_chat_service.dart';

class AiColdStart {
  AiColdStart._();

  /// 本进程是否已经**发过**这次冷启动初始化（失败也算发过：一次运行只发一次）
  static bool _attempted = false;

  /// 本次冷启动是否**轮换成功**（页面兜底的判据）
  static bool _rotated = false;

  /// 正在飞的请求（`main()` 与 `HomeShell` 都调用时也只发一次）
  static Future<void>? _inFlight;

  /// 页面兜底门控是否已被本次运行取走（只对"本进程第一次加载历史"生效）
  static bool _guardTaken = false;

  /// 本次冷启动是否轮换成功（true = 服务端已换 current_session）
  static bool get rotatedThisRun => _rotated;

  /// 首拉历史前 await 它：冷启动那次 reset 落定之前不拉历史（没发过请求时立刻返回）
  static Future<void> get settled => _inFlight ?? Future<void>.value();

  /// 冷启动初始化（**进程内一次**）。调用方 fire-and-forget 即可，不阻塞启动。
  ///
  /// 幂等：已在飞 → 复用同一个 Future；已发过 → 立刻返回（tab 切换 / 重新挂载都不会再发第二次）。
  static Future<void> ensureResetOnce({AiChatSource? source}) {
    final running = _inFlight;
    if (running != null) return running;
    if (_attempted) return Future<void>.value();
    final token = AuthStore.instance.accessToken;
    if (token == null || token.isEmpty) return Future<void>.value();
    return _inFlight = _run(token, source ?? HttpAiChatSource());
  }

  static Future<void> _run(String token, AiChatSource source) async {
    _attempted = true;
    try {
      _rotated = await source.reset(token);
    } catch (_) {
      // 离线 / 接口失败：静默（不弹错、不卡启动）—— 本次运行按"没轮换成功"处理
      _rotated = false;
    }
  }

  /// 页面兜底门控：**只对"本进程第一次加载历史"返回 true，且要求这次冷启动没轮换成功**。
  ///
  /// 命中时 `AiChatPage` 允许用 [AiSessionTrace] 把"本机上次已展示过的 session"按空会话渲染 ——
  /// 等价于"大退后为空"（离线冷启动时 reset 发不出去，服务端还留着上一条会话）。
  /// 取过一次即失效：同一次运行里第二次加载历史（push 方式再打开 AI 页）必须**保留**对话。
  static bool takeColdStartStaleGuard() {
    if (_guardTaken) return false;
    _guardTaken = true;
    return !_rotated;
  }

  /// 测试钩子：模拟"进程重启"（大退后重新打开 App）
  @visibleForTesting
  static void debugResetRun() {
    _attempted = false;
    _rotated = false;
    _inFlight = null;
    _guardTaken = false;
  }
}
