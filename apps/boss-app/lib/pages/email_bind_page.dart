import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 老板端「绑定 / 更换邮箱」页（负责人 2026-10-10 邮箱能力）
///
/// ## 为什么实现放在 core
/// 流程、邮箱格式校验、6 位验证码、60 秒倒计时、错误映射、「密码错误/验证码错误/已被其他账号绑定」
/// 的中文原文展示必须**只有一份**（与找回密码页同一套做法，见 `forgot_password_page.dart`）。
/// 真正的页面是 core 的 [AuthEmailBindPage]，本文件只给 `pages/` 下一个稳定类名，
/// 供设置页与测试使用。
///
/// ## 两态（同一个页面）
/// - `currentEmail == null` → 绑定态（标题「绑定邮箱」）；
/// - `currentEmail` 非空（**只能是服务端下发的脱敏值**）→ 换绑态（标题「更换邮箱」+
///   明确提示「更换后原邮箱将不再用于登录」）。
class EmailBindPage extends StatelessWidget {
  const EmailBindPage({super.key, this.api, this.currentEmail});

  /// 测试注入（不传 → AuthStore 内部单例客户端）
  final ApiClient? api;

  /// 当前已绑定的**脱敏**邮箱（非空 = 换绑态）
  final String? currentEmail;

  @override
  Widget build(BuildContext context) => AuthEmailBindPage(api: api, currentEmail: currentEmail);
}
