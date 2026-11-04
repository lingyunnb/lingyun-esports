import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 老板端「忘记密码」页（邮箱验证码自助找回，负责人 2026-10-05）
///
/// ## 为什么实现放在 core
/// 找回密码的**流程、校验规则（8-64 位）、60 秒倒计时、错误映射、防枚举文案**必须与工作端
/// 逐字一致 —— 两端各写一份必然漂移。所以真正的页面是 core 的 [AuthForgotPasswordPage]，
/// 本文件只做端内收敛：给一个 `pages/` 下的稳定类名（`ForgotPasswordPage`）与
/// 老板端专属的品牌副文案/脚注，测试与路由都用它。
///
/// ## 流程
/// 1. 邮箱 →「获取验证码」（`POST /auth/email/code`，scene=`reset`，成功才 60 秒倒计时）；
/// 2. 验证码 + 新密码（两次确认）；
/// 3. `POST /auth/password/reset` → 成功后 `pop(true)` 回登录页，
///    由登录页清空密码框并提示「密码已重置，请用新密码登录」。
class ForgotPasswordPage extends StatelessWidget {
  const ForgotPasswordPage({super.key, this.api});

  /// 测试注入（不传 → AuthStore 内部单例客户端）
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    return AuthForgotPasswordPage(
      api: api,
      subtitle: '陪玩 · 代练 · 全分部服务',
      facts: const [BrandFact(value: '邮箱验证', label: '10 分钟内有效')],
      footnote: '若该邮箱已绑定账号，验证码将发送至该邮箱；未绑定的邮箱不会收到邮件。',
    );
  }
}
