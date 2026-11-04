import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'about_privacy_page.dart';
import 'forgot_password_page.dart';

/// 工作端登录页（docs/04：账号由管理员后台创建，**无自助注册**）
///
/// ## 2026-10-05 视觉改版（与老板端同款：方案 B「品牌主视觉」）
/// 依据同一批设计稿（`site/design/auth/b-*.html`）：176px 纯实色 `#2563EB` 品牌区
/// （小山标 + 「祁连山电竞」+ 标题 + 副文案 + 数据行）→ 白卡（圆角 14）压边 →
/// filled 输入框 → 忘记密码行 → 协议勾选（发丝线分隔）→ 实色主按钮 → 页脚。
///
/// 与老板端的差异（本端是内部工具，**只有登录**）：
/// - 品牌行第二行写 **「祁连山电竞内部」**（原有文案，保留）；
/// - 页脚保留既有 **「工作账号由管理员创建分配」**；
/// - 没有注册入口、没有昵称字段。
///
/// 玻璃背景处理同老板端：本页自锁浅色 + 实色 scaffold（`Theme` 覆盖
/// `scaffoldBackgroundColor`，因为玻璃主题下它被全局设成了 `Colors.transparent`），
/// 全局 `FishGlassBackdrop` 不动，其它页面玻璃效果不受影响。
///
/// ## 2026-10-05 找回密码改为真流程
/// 「忘记密码」不再提示「暂未开放」，改为打开 [ForgotPasswordPage]（邮箱验证码自助找回，
/// 与老板端同一份实现/同一套文案）。**防枚举**：工作账号若未绑定邮箱，后端会返回与成功
/// 完全一致的响应但不发信，因此界面一律提示「若该邮箱已绑定，验证码已发送…」，
/// **绝不**改成「邮箱不存在」。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.api});

  /// 测试注入（不传 → AuthStore 内部单例客户端）
  final ApiClient? api;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  /// 协议勾选（**不持久化**，每次进页面默认未勾选）
  bool _agreed = false;

  /// 表单错误（行内红字 + 按钮上方汇总）
  final FormErrors _errs = FormErrors();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 未勾选协议时的中文提示（不发起任何请求）
  void _remindAgreement() {
    AppToast.info(context, '请先阅读并勾选《用户协议》与《隐私政策》');
  }

  /// 忘记密码：真流程（邮箱验证码自助找回，2026-10-05）
  ///
  /// 工作账号只有**绑定了邮箱**才能找回；未绑定邮箱时后端返回与成功一致的响应但不发信
  /// （防枚举），所以界面文案保持「若该邮箱已绑定…」，不得提示"邮箱不存在"。
  /// 成功回来自 [ForgotPasswordPage] 的 `pop(true)`：清空密码框 + 在**本页**提示。
  Future<void> _forgotPassword() async {
    final reset = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ForgotPasswordPage(api: widget.api)),
    );
    if (!mounted || reset != true) return;
    setState(() {
      _password.clear();
      _errs.clear();
    });
    AppToast.success(context, '密码已重置，请用新密码登录');
  }

  Future<void> _submit() async {
    // 协议未勾选：纯前端拦截（后端无此校验），连请求都不发
    if (!_agreed) {
      _remindAgreement();
      return;
    }
    final username = _username.text.trim();
    final password = _password.text;
    _errs.clear();
    // 本地空值校验：行内红字（服务端也会校验，这里让输入框立刻有反馈）
    if (username.isEmpty) _errs.set('username', '请输入工作账号');
    if (password.isEmpty) _errs.set('password', '请输入密码');
    if (_errs.isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() => _loading = true);
    try {
      await AuthStore.instance.login(username: username, password: password, role: 'worker', api: widget.api);
      // 登录成功：RootGate 自动切换到主框架
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.errorCode == 'ACCOUNT_BANNED') {
        // 账号被封禁：弹窗展示封禁结束时间（负责人需求）
        _showBannedDialog(e.message);
      } else if (!_errs.bindApiException(e)) {
        // 定位不到输入框的失败（网络/账号密码不正确/限流）→ 品牌浮层
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showBannedDialog(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.block, color: AppColors.error, size: 40),
        title: const Text('账号已被封禁'),
        content: Text(message, textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 打开既有阅读页（`AboutPrivacyPage`：内容来自管理端 GET /public/about|privacy）
  void _openDoc(String kind) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AboutPrivacyPage(kind: kind)));
  }

  @override
  Widget build(BuildContext context) {
    // 登录页自锁浅色（设计稿是浅色实色页）
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(scaffoldBackgroundColor: Colors.white),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            // 实色底：压住全局 FishGlassBackdrop 的彩色光斑
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppBrandHeader(
                    title: '登录',
                    subtitle: '祁连山电竞内部',
                    facts: const [BrandFact(value: '内部系统', label: '账号由管理员创建分配')],
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

  /// 白卡（圆角 14，上移 18 压边；padding 22/24/26，组间 20）
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
            // 顶部错误汇总（既有组件；无错误时零占位）
            AppFormErrorSummary(_errs),
            AppAuthField(
              label: '账号',
              icon: Icons.person_outline_rounded,
              controller: _username,
              errors: _errs,
              errorField: 'username',
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_errs.errorOf('username') != null) setState(() => _errs.clearField('username'));
              },
            ),
            const SizedBox(height: 20),
            AppAuthField(
              label: '密码',
              icon: Icons.lock_outline_rounded,
              controller: _password,
              obscure: true,
              errors: _errs,
              errorField: 'password',
              textInputAction: TextInputAction.done,
              onChanged: (_) {
                if (_errs.errorOf('password') != null) setState(() => _errs.clearField('password'));
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _forgotPassword,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '忘记密码',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.primary),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            AppAgreementRow(
              value: _agreed,
              onChanged: (v) => setState(() => _agreed = v),
              onAgreement: () => _openDoc('about'),
              onPrivacy: () => _openDoc('privacy'),
            ),
            const SizedBox(height: 14),
            AppAuthButton(
              key: const Key('auth-submit'),
              label: '登录',
              loading: _loading,
              // 未勾选协议 → onPressed 为 null（设计稿的灰态禁用）；禁用时点一下仍给中文提示
              onPressed: _agreed && !_loading ? _submit : null,
              onDisabledTap: _loading ? null : _remindAgreement,
            ),
            const SizedBox(height: 16),
            // 页脚：工作端没有注册入口（账号由管理员创建分配）
            const Text(
              '工作账号由管理员创建分配',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
