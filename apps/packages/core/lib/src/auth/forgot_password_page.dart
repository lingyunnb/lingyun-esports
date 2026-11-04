import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/form_errors.dart';
import 'auth_store.dart';
import 'email_auth.dart';

/// 找回密码页（邮箱验证码版，负责人 2026-10-05）
///
/// 实现放在 **core**：老板端与工作端的流程、校验、文案、错误映射必须逐字一致，
/// 两端 `lib/pages/forgot_password_page.dart` 只是薄封装（传各自的品牌副文案/脚注）。
///
/// ## 流程（三步一页，照登录改版方案 B 的视觉）
/// 1. 输入邮箱 → 「获取验证码」（`POST /auth/email/code`，scene=`reset`，60 秒倒计时禁用）；
/// 2. 输入验证码 + 新密码（两次确认，8-64 位，与注册同规则）；
/// 3. 提交 `POST /auth/password/reset` → 成功 **pop(true)** 回登录页
///    （由登录页清空密码框并提示「密码已重置，请用新密码登录」）。
///
/// ## 防枚举（**硬要求，不得改动**）
/// 工作端账号若未绑定邮箱，后端**同样返回成功但不发信**。因此：
/// - 取码成功的提示一律用 [emailCodeSentHint]（「若该邮箱已绑定，验证码已发送…」）；
/// - 提交阶段的失败文案由后端给（未注册邮箱返回的是「验证码已过期」这类通用文案），
///   客户端**绝不**把它改写成「邮箱不存在/未注册」。
///
/// ## 视觉
/// 与登录页同源：`AppBrandHeader`（176 实色 `#2563EB`，不用渐变）→ 白卡（圆角 14、上移 18 压边）
/// → 顶部错误汇总条 → filled 输入框（错误态红底红边 + 行内红字）→ 实色主按钮。
/// 本页同样**自锁浅色 + 实色底**（压住全局玻璃背景的彩色光斑，与登录页一致）。
class AuthForgotPasswordPage extends StatefulWidget {
  const AuthForgotPasswordPage({
    super.key,
    this.api,
    this.title = '找回密码',
    this.subtitle = '邮箱验证 · 全分部服务',
    this.footnote,
    this.facts = const [BrandFact(value: '10 分钟', label: '验证码有效期')],
  });

  /// 测试注入（不传 → AuthStore 内部单例客户端）
  final ApiClient? api;

  /// 品牌区标题
  final String title;

  /// 品牌区副文案
  final String subtitle;

  /// 卡片底部脚注（各端可写自己的提示；null 用默认防枚举说明）
  final String? footnote;

  /// 品牌区数据行
  final List<BrandFact> facts;

  @override
  State<AuthForgotPasswordPage> createState() => _AuthForgotPasswordPageState();
}

class _AuthForgotPasswordPageState extends State<AuthForgotPasswordPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  /// 60 秒重发倒计时（与注册页共用同一实现）
  final EmailCodeCountdown _countdown = EmailCodeCountdown();

  /// 表单错误（行内红字 + 按钮上方汇总）
  final FormErrors _errs = FormErrors();

  bool _loading = false;

  @override
  void dispose() {
    _countdown.dispose();
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// 邮箱本地校验不通过时就地标红并返回 false（**不发请求**）
  bool _checkEmail() {
    final err = emailFormatError(_email.text);
    if (err == null) return true;
    setState(() => _errs.set(AuthErrorField.email, err));
    return false;
  }

  /// 「获取验证码」：本地校验 → 请求 → 成功才进入 60 秒倒计时
  Future<void> _sendCode() async {
    if (!_countdown.canSend) return;
    if (!_checkEmail()) return;
    setState(() => _errs.clearField(AuthErrorField.email));
    _countdown.beginSend();
    try {
      await AuthStore.instance.sendEmailCode(
        email: _email.text.trim(),
        scene: EmailCodeScene.reset,
        api: widget.api,
      );
      if (!mounted) return;
      _countdown.start();
      // 防枚举文案（工作端未绑定邮箱时后端也返回成功）
      AppToast.success(context, emailCodeSentHint(EmailCodeScene.reset));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (bindAuthApiException(_errs, e)) {
        setState(() {});
      } else {
        AppToast.error(context, e.message);
      }
    } finally {
      _countdown.endSend();
    }
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final code = _code.text.trim();
    final password = _password.text;
    final confirm = _confirm.text;
    _errs.clear();

    final emailErr = emailFormatError(email);
    if (emailErr != null) _errs.set(AuthErrorField.email, emailErr);
    final codeErr = emailCodeFormatError(code);
    if (codeErr != null) _errs.set(AuthErrorField.emailCode, codeErr);
    final pwdErr = newPasswordFormatError(password);
    if (pwdErr != null) {
      _errs.set(AuthErrorField.newPassword, pwdErr);
    } else if (password != confirm) {
      _errs.set(AuthErrorField.confirmPassword, '两次输入的密码不一致');
    }
    if (_errs.isNotEmpty) {
      setState(() {});
      return;
    }

    setState(() => _loading = true);
    try {
      await AuthStore.instance.resetPassword(
        email: email,
        code: code,
        newPassword: password,
        api: widget.api,
      );
      if (!mounted) return;
      // 回登录页：由登录页清空密码框 + 提示「密码已重置，请用新密码登录」
      // （提示必须在**登录页**弹：本页 pop 之后它的 Overlay 已经没了）
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (bindAuthApiException(_errs, e)) {
        setState(() {});
      } else {
        AppToast.error(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 与登录页一致：本页自锁浅色实色（不跟随深色主题、不参与全局玻璃背景）
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        scaffoldBackgroundColor: Colors.white,
        colorScheme: base.colorScheme.copyWith(surface: Colors.white, surfaceContainerLowest: Colors.white),
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppBrandHeader(
                    title: widget.title,
                    subtitle: widget.subtitle,
                    facts: widget.facts,
                    // 二级页：品牌区左上角返回（登录页没有箭头，视觉不变）
                    onBack: () => Navigator.of(context).maybePop(),
                  ),
                  _card(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card() {
    return Transform.translate(
      offset: const Offset(0, -18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 26),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppAuthRadius.card)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormErrorSummary(_errs),
            AppAuthField(
              label: '邮箱',
              icon: AppIconsLegacy.mail_outline_rounded,
              controller: _email,
              hint: '用于接收验证码的邮箱',
              keyboardType: TextInputType.emailAddress,
              maxLength: kEmailMaxLength,
              textInputAction: TextInputAction.next,
              errors: _errs,
              errorField: AuthErrorField.email,
              onChanged: (_) {
                if (_errs.errorOf(AuthErrorField.email) != null) {
                  setState(() => _errs.clearField(AuthErrorField.email));
                }
              },
            ),
            const SizedBox(height: 20),
            AppAuthField(
              key: const Key('forgot-code-field'),
              label: '验证码',
              icon: AppIconsLegacy.shield_outlined,
              controller: _code,
              hint: '$kEmailCodeLength 位数字',
              keyboardType: TextInputType.number,
              // 只收数字（与服务端 ^\d{6}$ 对齐）
              inputFormatters: emailCodeInputFormatters,
              maxLength: kEmailCodeLength,
              textInputAction: TextInputAction.next,
              errors: _errs,
              errorField: AuthErrorField.emailCode,
              trailing: AppAuthCodeButton(countdown: _countdown, onPressed: _sendCode),
              onChanged: (_) {
                if (_errs.errorOf(AuthErrorField.emailCode) != null) {
                  setState(() => _errs.clearField(AuthErrorField.emailCode));
                }
              },
            ),
            const SizedBox(height: 20),
            AppAuthField(
              label: '新密码',
              icon: AppIconsLegacy.lock_outline_rounded,
              controller: _password,
              obscure: true,
              hint: '$kPasswordMinLength-$kPasswordMaxLength 位',
              textInputAction: TextInputAction.next,
              errors: _errs,
              errorField: AuthErrorField.newPassword,
              onChanged: (_) {
                if (_errs.errorOf(AuthErrorField.newPassword) != null) {
                  setState(() => _errs.clearField(AuthErrorField.newPassword));
                }
              },
            ),
            const SizedBox(height: 20),
            AppAuthField(
              label: '确认新密码',
              icon: AppIconsLegacy.lock_reset_rounded,
              controller: _confirm,
              obscure: true,
              hint: '再次输入新密码',
              textInputAction: TextInputAction.done,
              errors: _errs,
              errorField: AuthErrorField.confirmPassword,
              onChanged: (_) {
                if (_errs.errorOf(AuthErrorField.confirmPassword) != null) {
                  setState(() => _errs.clearField(AuthErrorField.confirmPassword));
                }
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            AppAuthButton(
              key: const Key('forgot-submit'),
              label: '重置密码',
              loading: _loading,
              onPressed: _loading ? null : _submit,
            ),
            const SizedBox(height: 14),
            Text(
              widget.footnote ?? '若该邮箱已绑定账号，验证码将发送至该邮箱（未绑定则不会收到，属正常情况）',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 10),
            Center(
              child: InkWell(
                key: const Key('forgot-back-login'),
                onTap: _loading ? null : () => Navigator.of(context).maybePop(),
                borderRadius: BorderRadius.circular(AppAuthRadius.xs),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Text(
                    '返回登录',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
