import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_store.dart';

/// 单设备登录 / 封禁 的全局提示（docs/04）：监听 [AuthStore.authFailureMessage]，
/// 非空时弹出**不可关闭**遮罩的提示框，确认后清除标记（RootGate 已切回登录页）。
///
/// ============================ 两种提示（2026-10-16 封禁秒踢）============================
///
/// 1. **普通会话失效**（"账号已在其他设备登录" / "登录已失效，请重新登录"）：标题「登录状态变更」，
///    单个「重新登录」按钮 —— 行为与历史**逐字未变**；
/// 2. **账号被封**（服务端 `errorCode=ACCOUNT_BANNED`，见 `AuthStore.authFailureIsBanned`）：
///    标题「账号已被封禁」，正文是服务端原文（**含封禁原因与解封时间**），
///    只留两个出口：「退出」（离开 App）与「重新登录」。这是负责人明确要求的形态 ——
///    被封的人必须一眼看到"为什么被封、什么时候能解"，而不是一句含糊的"登录已失效"。
///
/// ============================ 回前台轻量校验（缺口 3）============================
///
/// 本组件挂在 `RootGate` 里（登录页/主框架之外那一层），是**全局唯一的会话生命周期组件**，
/// 因此"切回前台校验一次会话"也落在它身上（`didChangeAppLifecycleState` → 见
/// [AuthStore.verifySessionOnResume]）。这修的正是负责人那句「重新划掉 app 后台还能用」：
/// 切回前台**至少发一个** `GET /auth/me`，被封/被踢的账号会在这一瞬间被踢回登录页并弹封禁提示，
/// 而不是继续拿内存里那份旧数据用下去。
class SessionKickListener extends StatefulWidget {
  const SessionKickListener({super.key, required this.child});

  final Widget child;

  @override
  State<SessionKickListener> createState() => _SessionKickListenerState();
}

class _SessionKickListenerState extends State<SessionKickListener> with WidgetsBindingObserver {
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 切回前台：**只发一个**轻量校验请求（`GET /auth/me`）——
  /// 不发其它请求、不重建页面（跨境 RTT 下"每次切回都全量刷新"就是卡顿来源）。
  /// 失败静默（除 401 由全局钩子接管）；未登录时不发。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(AuthStore.instance.verifySessionOnResume());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthStore.instance,
      builder: (context, _) {
        final auth = AuthStore.instance;
        final message = auth.authFailureMessage;
        if (message != null && !_dialogShown) {
          _dialogShown = true;
          final banned = auth.authFailureIsBanned;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showKickDialog(message, banned: banned);
          });
        }
        return widget.child;
      },
    );
  }

  Future<void> _showKickDialog(String message, {required bool banned}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(banned ? '账号已被封禁' : '登录状态变更'),
        content: Text(banned ? '$message\n\n如有疑问请联系客服。' : message),
        actions: banned
            ? [
                // 两个出口，只有这两个（负责人要求）：退出 App / 重新登录
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _exitApp();
                  },
                  child: const Text('退出'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('重新登录'),
                ),
              ]
            : [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('重新登录'),
                ),
              ],
      ),
    );
    if (!mounted) return;
    /**
     * 关闭时**只清掉"刚刚显示过的那一句"**。
     *
     * 为什么要判断：封禁时服务端会同时做"吊销令牌 + 主动断开 WS"，两条通知几乎同时到达，
     * 谁先到不确定。如果 WS 的通用文案先到（已清令牌、弹出「登录已失效」），
     * 紧接着到达的封禁通只**覆盖**了 [AuthStore.authFailureMessage] 而不会再弹一次
     * （`_dialogShown` 还是 true）—— 此时若在关闭时无条件 `clearAuthFailure()`，
     * 那句最要紧的封禁原因就被静默吞掉了。
     * 所以：文案变了就保留新的那句并再弹一次（用户可以连点两次"知道了"，
     * 但**永远看得到封禁原因**）；没变才清理。
     */
    final latest = AuthStore.instance.authFailureMessage;
    _dialogShown = false;
    if (latest != null && latest != message) {
      setState(() {}); // 触发重建 → 用新的那一句再弹一次（不清理）
      return;
    }
    AuthStore.instance.clearAuthFailure();
  }

  /// 「退出」：Android 上离开 App（其它平台是 no-op，Flutter 的既定语义）。
  /// 包一层 try/catch：平台通道不应抛异常打断 UI（测试环境也没有平台实现）。
  void _exitApp() {
    try {
      SystemNavigator.pop();
    } catch (_) {
      // 忽略：退不出去也不该崩（用户仍停在登录页，可以重新登录）
    }
  }
}
