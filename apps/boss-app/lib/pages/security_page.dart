import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 账号与安全：修改密码（校验旧密码；改密后全部会话吊销，需重新登录）
///
/// 2026-10-04 整改：去掉旧白卡/OutlineInputBorder 杂样式，改设计稿 I 系列
/// （AppPageHeader + AppSectionHeader + AppCard + 圆角 10 输入框 + AppButton），功能不变。
/// 同日二次整改（负责人："弹窗改协调 + 英文改中文"）：本地校验与服务端 fields[]
/// 一律落到**对应输入框下方红字** + 按钮上方汇总条，不再用系统默认黑色 SnackBar。
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key, this.api});

  /// 测试注入（不传 → 默认 ApiClient）
  final ApiClient? api;

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final TextEditingController _old = TextEditingController();
  final TextEditingController _new = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  /// 表单错误（字段名与服务端 DTO 对齐：oldPassword / newPassword）
  final FormErrors _errs = FormErrors();

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final oldPw = _old.text;
    final newPw = _new.text;
    final confirm = _confirm.text;
    _errs.clear();
    if (oldPw.isEmpty) _errs.set('oldPassword', '请输入原密码');
    if (newPw.isEmpty) _errs.set('newPassword', '请输入新密码（8-64 位）');
    if (newPw.isEmpty || newPw.length < 8 || newPw.length > 64) {
      if (newPw.isNotEmpty) _errs.set('newPassword', '密码至少 8 位');
    }
    if (confirm.isEmpty) {
      _errs.set('confirmPassword', '请再输入一次新密码');
    } else if (newPw != confirm) {
      _errs.set('confirmPassword', '两次输入的新密码不一致');
    }
    if (_errs.isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.request('POST', '/auth/password', token: AuthStore.instance.accessToken, data: {
        'oldPassword': oldPw,
        'newPassword': newPw,
      });
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('密码已修改'),
          content: const Text('为保障账号安全，所有设备已退出登录，请使用新密码重新登录。'),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
              },
              child: const Text('重新登录'),
            ),
          ],
        ),
      );
      // 本地清理会话（服务端已全部吊销）
      await AuthStore.instance.logout();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 服务端 fields[] → 对应输入框下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.bindApiException(e, aliases: const {
        'oldPassword': 'oldPassword',
        'newPassword': 'newPassword',
        'password': 'newPassword',
      })) {
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          const AppPageHeader(title: '账号与安全', subtitle: '修改后所有设备退出登录'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                const AppSectionHeader(title: '修改密码', padding: EdgeInsets.fromLTRB(16, 16, 16, 8)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.categorySoft(AppColors.primary),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: AppIcon.of(AppIcon.keyIcon, size: 17, color: AppColors.primary),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text('设置新密码',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: T.textPrimary)),
                            ),
                            GestureDetector(
                              onTap: () => setState(() => _obscure = !_obscure),
                              child: Text(_obscure ? '显示密码' : '隐藏密码',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: T.primary)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _field(_old, '原密码', errorField: 'oldPassword'),
                        const SizedBox(height: 12),
                        _field(_new, '新密码（8-64 位）', errorField: 'newPassword'),
                        const SizedBox(height: 12),
                        _field(_confirm, '确认新密码', errorField: 'confirmPassword', onSubmitted: (_) => _submit()),
                        const SizedBox(height: 14),
                        Text('密码 8-64 位，建议字母 + 数字组合；修改成功后需用新密码重新登录。',
                            style: TextStyle(fontSize: 11, height: 1.5, color: T.mutedText)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _busy
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
                          submit: AppButton(label: '确认修改', icon: AppIcon.check, onPressed: _submit),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 输入框（圆角 10 + 浅底填充，去掉 Material 默认描边样式）+ 下方行内错误红字
  Widget _field(TextEditingController c, String label, {ValueChanged<String>? onSubmitted, String? errorField}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: c,
            obscureText: _obscure,
            onSubmitted: onSubmitted,
            onChanged: (v) {
              if (errorField != null && _errs.errorOf(errorField) != null) setState(() => _errs.clearField(errorField));
            },
            style: TextStyle(fontSize: 14, color: T.textPrimary),
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              filled: true,
              fillColor: T.bgPage,
              labelStyle: TextStyle(fontSize: 13, color: T.textSecondary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: T.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: errorField != null && _errs.errorOf(errorField) != null ? AppColors.error : T.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(
                  color: errorField != null && _errs.errorOf(errorField) != null ? AppColors.error : T.primary,
                  width: 1.4,
                ),
              ),
            ),
          ),
          if (errorField != null) AppFieldError(_errs, errorField),
        ],
      );
}
