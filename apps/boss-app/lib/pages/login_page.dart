import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'about_privacy_page.dart';
import 'forgot_password_page.dart';

// ============================================================================
// 方案 G 视觉层（2026-10-17 重构；**只动视觉，业务流程一个字节未改**）
// ============================================================================
//
// 方案 G 的取值里，有两项在色板（`AppColors`）里没有同值项，而色板/公共组件
// 本轮**禁止改动**（另一路在改 core/widgets）→ 按页面私有常量落地，理由如下：
//
// - [loginPageBg] `#F6F7F9`：方案 G 的**页底**。色板里最近的两档是 `fieldBg`
//   `#F1F4F8` 与 `placeholderBg` `#F1F5FA`，都偏灰一档且各自另有语义
//   （区块浅底 / 占位底），借来当页底会把两个语义粘在一起。登录页是**独立整屏**，
//   页底只服务本页，所以留一个私有常量，注释即理由。
// - [loginCardRadius] `12`：方案 G 的圆角分档只有 10 / 12 / 14 / 999。
//   `AppAuthRadius.card` 是 14（方案 B 的白卡），而方案 G 的卡片档是 **12**。
//   公共组件那枚 14 仍被「找回密码/绑定邮箱」等二级页复用，因此不在本页引用它。

/// 方案 G 页底（颜色卡之外的全部留白）
const Color loginPageBg = AppColors.bgPageG;

/// 方案 G 卡片圆角（卡片档 12，与 10 / 14 / 999 并列的既定分档）
const double loginCardRadius = 12;

/// 老板端登录/注册页（docs/04：账号密码，注册仅限 user 角色）
///
/// ## 2026-10-05 视觉改版（负责人已审批：方案 B「品牌主视觉」）
/// 依据 `site/design/auth/b-login.html` / `b-register.html` / `b-err-inline.html` /
/// `b-err-top.html` / `b-keyboard.html`（出图 `p-b-*.png`），逐值照稿：
/// - 顶部 **176px 纯实色 `AppColors.primary`** 品牌区（`AppBrandHeader`：小山标 + 「祁连山电竞」+ 标题 + 副文案 + 数据行），
///   **不做渐变**；
/// - 品牌区下方**白卡**（圆角 14，`margin-top:-18` 压边）：顶部错误汇总条 → filled 输入框 → 忘记密码行
///   → 协议勾选（发丝线分隔）→ 主按钮 → 页脚切换；
/// - 输入框 filled（底 `#FAFBFD` / 描边 `#E5E9F0` / 圆角 10 → 聚焦白底 + 主色描边 + 外发光）、高 50；
///   错误态保持既有组件：框边转红 + **行内红字 `AppFieldError`** + **顶部汇总条 `AppFormErrorSummary`**；
/// - 主按钮实色 `AppColors.primary` / 高 48 / 圆角 6；禁用（协议未勾选）灰态 `#E9EDF4`。
///
/// ## 本页**脱离全局玻璃背景**（负责人硬要求）
/// `main.dart` 在 `MaterialApp.builder` 里全局套了 `MiuixSystemTheme + FishGlassBackdrop`
/// （透明 scaffold + 彩色光斑）。登录页按设计稿是**白/浅底实色**，做法选**最小改动 + 不动全局背景**：
/// ① 本页 `Theme` 覆盖 `scaffoldBackgroundColor`（玻璃主题下它是 `Colors.transparent`，必须改回实色）；
/// ② body 自己铺一层**实色** `#FFFFFF`（品牌区实色、白卡实色、卡片下方留白区也是白）——
///    不透明层压在光斑之上，玻璃彻底不参与登录页渲染。
/// 全局 `FishGlassBackdrop` 一行未改，其它页面（主框架/聊天/我的…）的玻璃效果完全不受影响。
///
/// ## 业务逻辑
/// `_submit`（本地空值校验、AuthStore 调用、封禁弹窗、字段错误绑定、toast 兜底）、
/// `FormErrors`、`AuthStore`、登录↔注册切换、`widget.api` 测试注入保持原样。
///
/// ## 2026-10-05 邮箱通道（负责人：邮箱验证替代短信验证）
/// - **注册模式**新增「邮箱」+「验证码」两格：验证码格内右侧是**获取验证码**按钮
///   （`POST /auth/email/code`，scene=`register`，成功才进入 **60 秒倒计时**并禁用，显示「60s 后重发」）；
/// - 邮箱**本地格式校验**不过 → 只标行内红字，**一个请求都不发**；
/// - 提交时把 `email` + `emailCode` 一并交给 `POST /auth/register`；
///   邮箱是否必填由 core 的 `kRegisterEmailRequired` 单点控制（true = 必填，当前取值与理由见该常量注释）；
/// - 服务端返回的「验证码错误/已过期/次数过多/邮件发送失败/请求过于频繁」这些**没有 `fields[]`**
///   的中文错误，由 core 的 `bindAuthApiException` 映射到**对应输入框的行内红字**；
/// - **忘记密码**改为真流程：打开 [ForgotPasswordPage]（邮箱验证码自助找回），
///   成功返回后清空本页密码框并提示「密码已重置，请用新密码登录」。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.api});

  /// 测试注入（不传 → 全局单例客户端走 AuthStore）
  final ApiClient? api;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _nickname = TextEditingController();
  final _email = TextEditingController();
  final _emailCode = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;

  /// 登录方式（2026-10-10 邮箱能力）：false = **账号密码**（默认，不改变现有用户习惯）、
  /// true = 邮箱验证码登录。注册态下本开关不渲染（注册仍是账号密码 + 邮箱绑定的老流程）。
  bool _emailMode = false;

  /// 注册用的「获取验证码」60 秒重发倒计时（三个入口共用 core 的实现）
  final EmailCodeCountdown _countdown = EmailCodeCountdown();

  /// **邮箱验证码登录**自己的倒计时：与注册码分开计（服务端 Redis 键含 scene，互不占额度），
  /// 共用同一个实例会出现"注册页倒计时未走完导致登录页取不了码"的假故障。
  final EmailCodeCountdown _loginCountdown = EmailCodeCountdown();

  /// 协议勾选（设计稿位置：主按钮上方）。**不持久化**，每次进页面默认未勾选。
  bool _agreed = false;

  /// 表单错误（行内红字 + 按钮上方汇总）
  final FormErrors _errs = FormErrors();

  @override
  void dispose() {
    _countdown.dispose();
    _loginCountdown.dispose();
    _username.dispose();
    _password.dispose();
    _nickname.dispose();
    _email.dispose();
    _emailCode.dispose();
    super.dispose();
  }

  /// 是否处于「邮箱验证码登录」态（注册态恒 false）
  bool get _emailLogin => !_isRegister && _emailMode;

  /// 切换登录方式（清掉上一种方式留下的行内红字；输入内容保留，便于来回比对）
  void _switchMode(bool emailMode) {
    if (_loading || _emailMode == emailMode) return;
    setState(() {
      _emailMode = emailMode;
      _errs.clear();
    });
  }

  /// 邮箱验证码登录的「获取验证码」：本地格式校验 → `scene=login` 取码 → 成功才 60 秒倒计时
  ///
  /// 防枚举（**硬要求**）：服务端对"未绑定任何账号的邮箱"返回**逐字相同**的成功响应（不发信），
  /// 因此这里的提示必须是与绑定状态无关的同一句 [emailCodeSentHint]（照实提示"已发送"，
  /// **绝不**写成"该邮箱未注册/未绑定"）。
  Future<void> _sendLoginCode() async {
    if (!_loginCountdown.canSend) return;
    _errs.clear();
    final err = emailFormatError(_email.text);
    if (err != null) {
      setState(() => _errs.set('email', err));
      return;
    }
    _loginCountdown.beginSend();
    try {
      await AuthStore.instance.sendEmailCode(
        email: _email.text.trim(),
        scene: EmailCodeScene.login,
        api: widget.api,
      );
      if (!mounted) return;
      _loginCountdown.start();
      AppToast.success(context, emailCodeSentHint(EmailCodeScene.login));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (bindAuthApiException(_errs, e)) {
        setState(() {});
      } else {
        AppToast.error(context, e.message);
      }
    } finally {
      _loginCountdown.endSend();
    }
  }

  /// 未勾选协议时的中文提示（不发起任何请求）
  void _remindAgreement() {
    AppToast.info(context, '请先阅读并勾选《用户协议》与《隐私政策》');
  }

  /// 忘记密码：真流程（邮箱验证码自助找回，2026-10-05）
  ///
  /// 成功回来自 [ForgotPasswordPage] 的 `pop(true)`：清空密码框 + 在**本页**提示
  /// （提示不能由找回页弹：它 pop 之后 Overlay 已经没了）。
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

  /// 注册时的邮箱本地校验（**不合法不发请求**）；返回 true 表示邮箱这一格没问题
  bool _checkRegisterEmail() {
    final email = _email.text.trim();
    if (email.isEmpty) {
      if (kRegisterEmailRequired) {
        _errs.set('email', '请输入邮箱');
        return false;
      }
      return true; // 邮箱可选模式：不填就走旧注册路径
    }
    final err = emailFormatError(email);
    if (err != null) {
      _errs.set('email', err);
      return false;
    }
    return true;
  }

  /// 注册模式的「获取验证码」：本地校验 → 请求 → 成功才进入 60 秒倒计时
  Future<void> _sendRegisterCode() async {
    if (!_countdown.canSend) return;
    _errs.clear();
    if (!_checkRegisterEmail()) {
      setState(() {});
      return;
    }
    _countdown.beginSend();
    try {
      await AuthStore.instance.sendEmailCode(
        email: _email.text.trim(),
        scene: EmailCodeScene.register,
        api: widget.api,
      );
      if (!mounted) return;
      _countdown.start();
      AppToast.success(context, emailCodeSentHint(EmailCodeScene.register));
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
    // 防连点（第一道闸）：请求在途时再点一次直接忽略（第二道是主按钮的 loading 态）
    if (_loading) return;
    // 协议未勾选：纯前端拦截（后端无此校验），连请求都不发
    if (!_agreed) {
      _remindAgreement();
      return;
    }
    final username = _username.text.trim();
    final password = _password.text;
    final email = _email.text.trim();
    final emailCode = _emailCode.text.trim();
    _errs.clear();
    if (_emailLogin) {
      // 邮箱验证码登录：只校验邮箱 + 6 位验证码（**不发任何密码请求**）
      final emailErr = emailFormatError(email);
      if (emailErr != null) _errs.set('email', emailErr);
      final codeErr = emailCodeFormatError(emailCode);
      if (codeErr != null) _errs.set('emailCode', codeErr);
    } else {
      // 本地空值校验（服务端也会校验，这里只是让输入框立刻有反馈）
      if (username.isEmpty) _errs.set('username', '请输入账号');
      if (password.isEmpty) _errs.set('password', '请输入密码');
      // 注册：邮箱（必填开关见 core 的 kRegisterEmailRequired）+ 验证码本地校验
      if (_isRegister) {
        if (_checkRegisterEmail()) {
          // 邮箱填了就必须带 6 位验证码（后端在传了 email 时强制验码，本地先拦一次省一个往返）
          if (email.isNotEmpty) {
            final codeErr = emailCodeFormatError(emailCode);
            if (codeErr != null) _errs.set('emailCode', codeErr);
          }
        }
      }
    }
    if (_errs.isNotEmpty) {
      setState(() {});
      return;
    }
    setState(() => _loading = true);
    try {
      final auth = AuthStore.instance;
      if (_emailLogin) {
        // 邮箱验证码登录：**与密码登录同一条落地链路**（AuthStore 内 _completeLogin：
        // 清上一个账号的打手身份 → 落令牌到安全存储 → GET /auth/me 刷新身份态 → notifyListeners）
        // → RootGate 据此切主框架；更新检查与「账号已在其他设备登录」提示链路一行未改。
        // 服务端签发的仍是 **primary** 会话 → 会顶掉其它设备（单设备铁律不豁免）。
        await auth.loginByEmailCode(
          email: email,
          emailCode: emailCode,
          role: 'user',
          api: widget.api,
        );
      } else if (_isRegister) {
        await auth.register(
          username: username,
          password: password,
          nickname: _nickname.text.trim(),
          // 邮箱可选模式下不填邮箱 → 两个参数都是 null → 请求体与旧版逐字节一致
          email: email.isEmpty ? null : email,
          emailCode: email.isEmpty ? null : emailCode,
          api: widget.api,
        );
        if (!mounted) return;
        AppToast.success(context, '注册成功，请登录');
        setState(() {
          _isRegister = false;
          _errs.clear();
          _countdown.reset();
        });
      } else {
        await auth.login(username: username, password: password, role: 'user', api: widget.api);
        // 登录成功：RootGate 自动切换到主框架
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.errorCode == 'ACCOUNT_BANNED') {
        // 账号被封禁：弹窗展示封禁结束时间（负责人需求）
        _showBannedDialog(e.message);
      } else if (!_showFieldErrors(e)) {
        // 定位不到输入框的失败（网络/账号密码不正确/「邮箱或验证码错误」/限流）→ 浮层浮出提示
        // 邮箱码登录的失败文案由服务端统一给出（防枚举：不区分"邮箱没绑账号"与"码不对"），
        // 客户端**原样展示**，不改写成"该邮箱未注册"。
        AppToast.error(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 服务端错误 → 对应输入框下方红字；返回 false 表示没定位到字段
  ///
  /// 两条来源合并（core 的 `bindAuthApiException`）：
  /// ① 结构化 `fields[]`（DTO 校验，服务端已中文化）；
  /// ② **没有 fields[] 的业务中文错误**（如「验证码错误」「邮件发送失败」）→ 客户端按文案映射字段。
  bool _showFieldErrors(ApiException e) {
    final bound = bindAuthApiException(_errs, e);
    if (bound) setState(() {});
    return bound;
  }

  void _showBannedDialog(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const AppIcon.of(AppIconsLegacy.block, color: AppColors.error, size: 40),
        title: const Text('账号已被封禁'),
        content: Text(message, textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 打开既有阅读页（`AboutPrivacyPage`：内容来自管理端 GET /public/about|privacy，客户端零硬编码）
  void _openDoc(String kind) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AboutPrivacyPage(kind: kind)));
  }

  @override
  Widget build(BuildContext context) {
    // 登录页自锁浅色：设计稿是浅色实色页，不跟随系统深色（否则浅底 + 浅字不可读）
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        // 方案 G：页底 `#F6F7F9`（白卡靠 1px 描边浮起，不靠阴影）
        scaffoldBackgroundColor: loginPageBg,
        colorScheme: base.colorScheme.copyWith(surface: Colors.white, surfaceContainerLowest: Colors.white),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.primary, textStyle: const TextStyle(fontSize: 14)),
        ),
      ),
      child: Scaffold(
        backgroundColor: loginPageBg,
        // 键盘弹出时整体上推（设计稿 b-keyboard.html：品牌区被顶出可视区，卡片单整体上移），
        // 由 Flutter 默认的 resizeToAvoidBottomInset + 滚动视图天然满足
        body: Stack(
          children: [
            // 实色底：压住全局 FishGlassBackdrop 的彩色光斑（登录页不参与玻璃主题）
            // 方案 G：这层是**页底** `#F6F7F9`，白卡与品牌区各自实色盖在它上面
            const Positioned.fill(child: ColoredBox(color: loginPageBg)),
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppBrandHeader(
                    title: _isRegister ? '创建账号' : '登录',
                    // 副文案走**不会过期**的固定文案（设计稿原文写死「和平精英·手游 / 三角洲行动·手游 /
                    // 三角洲行动·端游」与「3 个分部在营 / 客服 9:00-次日 2:00」——
                    // 分部会增减、时段归管理端配置，客户端写死必然过期；接口下发的方案见交付说明）
                    subtitle: '陪玩 · 代练 · 全分部服务',
                    facts: const [BrandFact(value: '官方自营', label: '客服在线时段见公告')],
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

  /// 登录方式切换（2026-10-10 邮箱能力）：`账号密码` / `邮箱验证码`
  ///
  /// 视觉沿用全站已经验收的分段切换取值（docs/21：**实色主色**选中、不做渐变、圆角分档外 6 内 5、
  /// 发丝线描边、只有"当前在哪一段"一个信息）——本页自锁浅色实色，所以取 [AppColors] 常量
  /// 而**不走** `T`（与登录页不参与玻璃主题的既有约定一致）。
  ///
  /// 两个段都带稳定 Key 与 `Semantics(selected:)`：测试据此断言"默认仍是账号密码"，
  /// 不依赖颜色这类易碎实现细节。
  Widget _loginModeSwitch() {
    Widget seg({required String label, required bool selected, required VoidCallback onTap, required Key key}) =>
        Expanded(
          child: Semantics(
            button: true,
            selected: selected,
            label: label,
            child: GestureDetector(
              key: key,
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary : Colors.transparent,
                  // 方案 G 圆角分档：分段内部用小胶囊（999），外框用 10
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected ? Colors.white : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        );

    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppAuthColors.fieldFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.strokeSoft),
      ),
      child: Row(
        children: [
          seg(
            label: '账号密码',
            selected: !_emailMode,
            onTap: () => _switchMode(false),
            key: const Key('login-mode-password'),
          ),
          seg(
            label: '邮箱验证码',
            selected: _emailMode,
            onTap: () => _switchMode(true),
            key: const Key('login-mode-email'),
          ),
        ],
      ),
    );
  }

  /// 白卡（方案 G：**白底 + 1px 描边 `#E8ECF2` + 圆角 12**，上移 18 与品牌区压边）
  ///
  /// 设计稿是 `margin:-18px 0 0`（CSS 允许负 margin）；Flutter 的 `Container.margin`
  /// 断言非负，故用 `Transform.translate` 把卡片整体上移 18px —— 视觉与设计稿一致，
  /// 且不影响布局尺寸。
  ///
  /// 方案 G 的三条硬约束都落在这里：① **不做大块渐变**（整卡纯白）；② **不用满屏阴影**
  /// （浮起靠 1px 描边 `AppColors.strokeSoft` `#E8ECF2`，`boxShadow` 一个都没有）；
  /// ③ 圆角只用 10 / 12 / 14 / 999 四档 → 本卡取 **12**。
  ///
  /// 左右各留 16（`AppSpacing.page`）：卡片成为**独立卡片**而不是通栏白片，
  /// 页底 `#F6F7F9` 因此能在两侧与卡下露出来（方案 G 的层次来源）。
  Widget _card() {
    return Transform.translate(
      offset: const Offset(0, -18),
      child: Container(
        margin: const EdgeInsets.fromLTRB(AppSpacing.page, 0, AppSpacing.page, AppSpacing.page),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(loginCardRadius),
          border: Border.all(color: AppColors.strokeSoft),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部错误汇总（既有组件；无错误时零占位）
          AppFormErrorSummary(_errs),
          // 登录方式切换（2026-10-10 邮箱能力）——**只在登录态出现**（注册态仍是老流程）。
          // 默认「账号密码」，不改变现有用户习惯。
          if (!_isRegister) ...[
            _loginModeSwitch(),
            const SizedBox(height: 18),
          ],
          if (_emailLogin) ...[
            // 邮箱验证码登录：邮箱 + 验证码（无密码格）
            AppAuthField(
              key: const Key('login-email-field'),
              label: '邮箱',
              icon: AppIcon.mail,
              controller: _email,
              hint: '登录邮箱',
              keyboardType: TextInputType.emailAddress,
              maxLength: kEmailMaxLength,
              errors: _errs,
              errorField: 'email',
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_errs.errorOf('email') != null) setState(() => _errs.clearField('email'));
              },
            ),
            const SizedBox(height: 20),
            AppAuthField(
              key: const Key('login-code-field'),
              label: '验证码',
              icon: AppIconsLegacy.shield_outlined,
              controller: _emailCode,
              hint: '$kEmailCodeLength 位数字',
              keyboardType: TextInputType.number,
              // 只收数字（粘贴/输入法都可能带进字母，服务端要 ^\d{6}$）
              inputFormatters: emailCodeInputFormatters,
              maxLength: kEmailCodeLength,
              errors: _errs,
              errorField: 'emailCode',
              textInputAction: TextInputAction.done,
              trailing: AppAuthCodeButton(countdown: _loginCountdown, onPressed: _sendLoginCode),
              onChanged: (_) {
                if (_errs.errorOf('emailCode') != null) setState(() => _errs.clearField('emailCode'));
              },
              onSubmitted: (_) => _submit(),
            ),
          ] else ...[
            AppAuthField(
              label: '账号',
              icon: AppIconsLegacy.person_outline_rounded,
              controller: _username,
              errors: _errs,
              errorField: 'username',
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
              onChanged: (v) {
                if (_errs.errorOf('username') != null) setState(() => _errs.clearField('username'));
              },
            ),
            const SizedBox(height: 20),
            AppAuthField(
              label: '密码',
              icon: AppIconsLegacy.lock_outline_rounded,
              controller: _password,
              obscure: true,
              errors: _errs,
              errorField: 'password',
              autofillHints: const [AutofillHints.password],
              textInputAction: _isRegister ? TextInputAction.next : TextInputAction.done,
              onChanged: (_) {
                if (_errs.errorOf('password') != null) setState(() => _errs.clearField('password'));
              },
              onSubmitted: (_) => _submit(),
            ),
            if (_isRegister) ...[
              const SizedBox(height: 20),
              // 邮箱（2026-10-05 邮箱通道）：找回密码的唯一通道，注册即绑定
              AppAuthField(
                key: const Key('register-email-field'),
                label: kRegisterEmailRequired ? '邮箱' : '邮箱（可选）',
                icon: AppIcon.mail,
                controller: _email,
                hint: '用于接收验证码与找回密码',
                keyboardType: TextInputType.emailAddress,
                maxLength: kEmailMaxLength,
                errors: _errs,
                errorField: 'email',
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_errs.errorOf('email') != null) setState(() => _errs.clearField('email'));
                },
              ),
              const SizedBox(height: 20),
              // 验证码 + 获取验证码（成功才进入 60 秒倒计时）
              AppAuthField(
                key: const Key('register-code-field'),
                label: '验证码',
                icon: AppIconsLegacy.shield_outlined,
                controller: _emailCode,
                hint: '$kEmailCodeLength 位数字',
                keyboardType: TextInputType.number,
                // 只收数字（粘贴/输入法都可能带进字母，服务端要 ^\d{6}$）
                inputFormatters: emailCodeInputFormatters,
                maxLength: kEmailCodeLength,
                errors: _errs,
                errorField: 'emailCode',
                textInputAction: TextInputAction.next,
                trailing: AppAuthCodeButton(countdown: _countdown, onPressed: _sendRegisterCode),
                onChanged: (_) {
                  if (_errs.errorOf('emailCode') != null) setState(() => _errs.clearField('emailCode'));
                },
              ),
              const SizedBox(height: 20),
              AppAuthField(
                label: '昵称（可选）',
                icon: AppIconsLegacy.badge_outlined,
                controller: _nickname,
                errors: _errs,
                errorField: 'nickname',
                hint: '留空则用账号作为昵称',
                textInputAction: TextInputAction.done,
                onChanged: (_) {
                  if (_errs.errorOf('nickname') != null) setState(() => _errs.clearField('nickname'));
                },
              ),
            ],
          ],
          const SizedBox(height: 20),
          // 忘记密码（左）+ 既有提示（右）——照设计稿 .rowline
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
              const Spacer(),
              const Text('打手账号请联系客服开通', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
            ],
          ),
          const SizedBox(height: 20),
          // 协议勾选（发丝线分隔 → 主按钮）。未勾选：按钮灰态 + 点一下给中文提示
          AppAgreementRow(
            value: _agreed,
            onChanged: (v) => setState(() => _agreed = v),
            onAgreement: () => _openDoc('about'),
            onPrivacy: () => _openDoc('privacy'),
          ),
          const SizedBox(height: 14),
          AppAuthButton(
            key: const Key('auth-submit'),
            label: _isRegister ? '注册' : '登录',
            loading: _loading,
            // 未勾选协议 → onPressed 为 null（设计稿的灰态禁用）；禁用时点一下仍给中文提示
            onPressed: _agreed && !_loading ? _submit : null,
            onDisabledTap: _loading ? null : _remindAgreement,
          ),
          const SizedBox(height: 14),
          // 页脚：一整句可点（文案与既有测试/文案一致：「还没有账号？注册一个」）
          Center(
            child: InkWell(
              key: const Key('auth-switch-mode'),
              onTap: _loading
                  ? null
                  : () => setState(() {
                        _isRegister = !_isRegister;
                        _errs.clear();
                      }),
              borderRadius: BorderRadius.circular(AppAuthRadius.xs),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 12, color: AppColors.mutedText),
                    children: [
                      TextSpan(text: _isRegister ? '已有账号？' : '还没有账号？'),
                      TextSpan(
                        text: _isRegister ? '去登录' : '注册一个',
                        style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 底部小字说明（方案 G：白卡最下一行"弱"档小字 `#8A99AB`）
          //
          // 只陈述两件**可验证**的事（官方自营 / 客服时段在公告里），
          // 不写"娱乐平台""官方保证"这类不能自证的口气（docs/21）。
          // 刻意**不放任何支付/充值入口**：登录页不承担充值引导。
          const SizedBox(height: 6),
          const Center(
            child: Text(
              '官方自营 · 客服在线时段见公告',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, height: 1.5, color: AppColors.textPlaceholder),
            ),
          ),
        ],
        ),
      ),
    );
  }
}
