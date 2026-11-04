import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../theme/app_colors.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_ui.dart';
import '../widgets/auth_widgets.dart';
import '../widgets/form_errors.dart';
import 'auth_store.dart';
import 'email_auth.dart';

/// 绑定 / 换绑邮箱页（负责人 2026-10-10）——**两态共用一个页面**
///
/// 实现放在 **core**：它是账号设置能力（`/user/email/*`），老板端现在是主要使用者，
/// 工作端账号同为平台账号（服务端 `@Roles('user','worker')`），将来要用时**零改动**即可挂上去；
/// 两端各写一份"当前密码 + 新邮箱验证码"的流程必然漂移。
/// 老板端 `lib/pages/email_bind_page.dart` 只是薄封装（与找回密码页同一套做法）。
///
/// ## 契约（读服务端源码得出，客户端只读不改）
/// - 取码：`POST /auth/email/code`，`scene=bind`（**与登录码/注册码分离计码**：Redis 键含 scene）；
/// - 提交：`POST /user/email/bind`，`{email, emailCode, password}` 三要素缺一不可
///   —— 服务端 `BindEmailDto.password` **无 `@IsOptional`**，即**首次绑定同样要求当前密码**；
/// - 校验顺序（服务端）：邮箱格式 → **当前密码** → 邮箱唯一 → 验证码；
///   因此「密码错误」一定先于「该邮箱已被其他账号绑定」出现，也先于任何验证码消耗；
/// - 成功响应：`{ok, email(脱敏), emailVerified, rebound, message}`；**绑定与换绑同一接口**（换绑 = 覆盖）。
///
/// ## 两态
/// - [currentEmail] 为 null → **绑定态**：标题「绑定邮箱」，无旧邮箱提示；
/// - [currentEmail] 非 null → **换绑态**：标题「更换邮箱」，且**必须明确提示**
///   [kEmailRebindNotice]（「更换后原邮箱将不再用于登录」）—— 这是负责人点名的硬要求。
///   传进来的值只能是**脱敏**邮箱（服务端只下发脱敏值，客户端也无需知道全量）。
///
/// ## 交互（照抄注册/找回密码那套，不新造）
/// - 邮箱本地格式校验（[emailFormatError]）不过 → **一个请求都不发**；
/// - 「获取验证码」：发送中禁用 → **只有取码真正成功**才进入 60 秒倒计时（[EmailCodeCountdown]）；
/// - 验证码 6 位数字（[emailCodeInputFormatters] 吞掉非数字，粘贴可用）+ 行内红字；
/// - 提交**防连点**（[_submitting] 期间按钮换成转圈，`_submit` 自己还有一道闸）；
/// - 失败一律**服务端中文原文**：能定位到输入框的落行内红字（[bindAuthApiException]），
///   定位不到的走浮层 —— 不吞错、不改写、不翻译。
///
/// ## 视觉
/// 二级页沿用设置族（`AppPageHeader` + `AppSectionHeader` + `AppCard` + `AppButton`），
/// 表单控件复用登录族已验收的 [AppAuthField] / [AppAuthCodeButton]（filled 圆角 10、
/// 错误态红底红边 + 行内红字、按钮三态文案唯一来源），不另造一套。
class AuthEmailBindPage extends StatefulWidget {
  const AuthEmailBindPage({
    super.key,
    this.api,
    this.currentEmail,
    this.title,
  });

  /// 测试注入（不传 → AuthStore 内部单例客户端）
  final ApiClient? api;

  /// 当前已绑定的**脱敏**邮箱（非空 = 换绑态）；null = 首次绑定
  final String? currentEmail;

  /// 页头标题覆盖（默认按两态取「绑定邮箱」/「更换邮箱」）
  final String? title;

  @override
  State<AuthEmailBindPage> createState() => _AuthEmailBindPageState();
}

class _AuthEmailBindPageState extends State<AuthEmailBindPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();

  /// 60 秒重发倒计时（与注册/找回密码共用同一实现，scene=bind 单独计码）
  final EmailCodeCountdown _countdown = EmailCodeCountdown();

  final FormErrors _errs = FormErrors();

  bool _submitting = false;

  /// 换绑态（当前已有邮箱）
  bool get _rebind => (widget.currentEmail ?? '').isNotEmpty;

  @override
  void dispose() {
    _countdown.dispose();
    _email.dispose();
    _code.dispose();
    _password.dispose();
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
        scene: EmailCodeScene.bind,
        api: widget.api,
      );
      if (!mounted) return;
      _countdown.start();
      AppToast.success(context, emailCodeSentHint(EmailCodeScene.bind));
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
    // 防连点第一道闸：请求在途时再点一次也进不来（第二道是按钮换成转圈，压根没得点）
    if (_submitting) return;
    final email = _email.text.trim();
    final code = _code.text.trim();
    final password = _password.text;
    _errs.clear();

    final emailErr = emailFormatError(email);
    if (emailErr != null) _errs.set(AuthErrorField.email, emailErr);
    final codeErr = emailCodeFormatError(code);
    if (codeErr != null) _errs.set(AuthErrorField.emailCode, codeErr);
    final pwdErr = currentPasswordFormatError(password);
    if (pwdErr != null) _errs.set(AuthErrorField.password, pwdErr);
    if (_errs.isNotEmpty) {
      setState(() {});
      return;
    }

    setState(() => _submitting = true);
    try {
      final result = await AuthStore.instance.bindEmail(
        email: email,
        code: code,
        password: password,
        api: widget.api,
      );
      if (!mounted) return;
      // 成功回设置页：把服务端返回的**脱敏邮箱**与中文文案带回去
      // （提示必须在设置页弹：本页 pop 之后它的 Overlay 已经没了 —— 与找回密码页同一处理）
      Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (bindAuthApiException(_errs, e)) {
        setState(() {});
      } else {
        AppToast.error(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          AppPageHeader(
            title: widget.title ?? (_rebind ? '更换邮箱' : '绑定邮箱'),
            subtitle: _rebind ? '需验证当前密码' : '邮箱可用于登录与找回密码',
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                const AppSectionHeader(title: '新邮箱', padding: EdgeInsets.fromLTRB(16, 16, 16, 8)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_rebind) ...[
                          _rebindNotice(),
                          const SizedBox(height: 16),
                        ],
                        AppAuthField(
                          key: const Key('email-bind-email-field'),
                          label: '新邮箱',
                          icon: AppIcon.mail,
                          controller: _email,
                          hint: '接收验证码的邮箱',
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
                        const SizedBox(height: 16),
                        AppAuthField(
                          key: const Key('email-bind-code-field'),
                          label: '验证码',
                          icon: AppIconsLegacy.shield_outlined,
                          controller: _code,
                          hint: '$kEmailCodeLength 位数字',
                          keyboardType: TextInputType.number,
                          // 只收数字（粘贴/输入法都可能带进字母，服务端要 ^\d{6}$）
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
                        const SizedBox(height: 16),
                        AppAuthField(
                          key: const Key('email-bind-password-field'),
                          label: '当前密码',
                          icon: AppIconsLegacy.lock_outline_rounded,
                          controller: _password,
                          obscure: true,
                          hint: '登录密码，用于确认是本人操作',
                          textInputAction: TextInputAction.done,
                          errors: _errs,
                          errorField: AuthErrorField.password,
                          onChanged: (_) {
                            if (_errs.errorOf(AuthErrorField.password) != null) {
                              setState(() => _errs.clearField(AuthErrorField.password));
                            }
                          },
                          onSubmitted: (_) => _submit(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _submitting
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        )
                      : AppFormErrorFooter(
                          errors: _errs,
                          submit: AppButton(
                            key: const Key('email-bind-submit'),
                            label: _rebind ? '确认更换' : '确认绑定',
                            icon: AppIcon.check,
                            onPressed: _submit,
                          ),
                        ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '验证码发送到「新邮箱」，10 分钟内有效；绑定后可用邮箱验证码登录，也可用于自助找回密码。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: T.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 换绑提示条（负责人硬要求：换绑必须**明确**告知旧邮箱的去向）
  ///
  /// 主句**逐字**是 [kEmailRebindNotice]（不拼接、不省略 —— 测试与验收都按整句断言），
  /// 当前绑定的旧邮箱脱敏值另起一行小字（用户要能确认"换的是哪一个"）。
  Widget _rebindNotice() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.statusOnlineSoft,
          borderRadius: BorderRadius.circular(AppAuthRadius.control),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon.of(AppIcon.mailVerified, size: 16, color: AppColors.statusOnline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kEmailRebindNotice,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: T.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '当前绑定 ${widget.currentEmail}',
                    style: TextStyle(fontSize: 11, height: 1.4, color: T.mutedText),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
