import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 工作端「忘记密码」页（邮箱验证码自助找回，负责人 2026-10-05）
///
/// ## 为什么实现放在 core
/// 找回密码的**流程、校验规则（8-64 位）、60 秒倒计时、错误映射、防枚举文案**必须与老板端
/// 逐字一致 —— 两端各写一份必然漂移。真正的页面是 core 的 [AuthForgotPasswordPage]，
/// 本文件只做端内收敛：`pages/` 下的稳定类名（`ForgotPasswordPage`）+ 工作端专属脚注。
///
/// ## 工作端的额外前提（**界面不得改写**）
/// 工作账号是管理员创建的，只有**已绑定邮箱**的账号才能收到验证码；未绑定邮箱时后端
/// 按防枚举策略返回成功但不发信 → 界面照常提示「若该邮箱已绑定，验证码已发送」。
class ForgotPasswordPage extends StatelessWidget {
  const ForgotPasswordPage({super.key, this.api});

  /// 测试注入（不传 → AuthStore 内部单例客户端）
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    return AuthForgotPasswordPage(
      api: api,
      subtitle: '祁连山电竞内部 · 账号找回',
      facts: const [BrandFact(value: '邮箱验证', label: '10 分钟内有效')],
      footnote: '工作账号需已绑定邮箱才能找回；若该邮箱已绑定，验证码将发送至该邮箱。',
    );
  }
}
