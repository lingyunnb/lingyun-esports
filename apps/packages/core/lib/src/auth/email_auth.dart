import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../widgets/form_errors.dart';

/// ============ 邮箱验证码 / 找回密码：两端共用的**规则、文案与错误映射** ============
///
/// 负责人 2026-10-05：邮箱通道（QQ 邮箱已实测打通）替代短信验证码，用于
/// ① 老板端注册时绑定邮箱；② 两端「忘记密码」自助找回。
///
/// 本文件只放**纯逻辑**（不依赖任何页面），三个入口共用同一份规则：
/// - 老板端注册（`boss-app/lib/pages/login_page.dart`）
/// - 老板端找回密码（`boss-app/lib/pages/forgot_password_page.dart`）
/// - 工作端找回密码（`worker-app/lib/pages/forgot_password_page.dart`）
///
/// 与后端的契约（`server/src/modules/auth/`，客户端**只读不改**）：
/// | 接口 | 请求体 | 成功响应 `data` |
/// |---|---|---|
/// | `POST /auth/email/code` | `{email, scene}`（scene: register/reset/bind/login）| `{ok:true, message:'验证码已发送至邮箱…'}` |
/// | `POST /auth/register` | `{username, password, nickname?, email?, emailCode?}` | `{id, username, uid, nickname, email, emailVerified}` |
/// | `POST /auth/password/reset` | `{email, emailCode, newPassword}` | `{ok:true, message:'密码已重置，请使用新密码登录'}` |
/// | `GET /user/email` | —（主体只取 JWT）| `{bound, email(脱敏), verified, verifiedAt}` |
/// | `POST /user/email/bind` | `{email, emailCode, password}` | `{ok, email(脱敏), emailVerified, rebound, message}` |
/// | `POST /auth/login`（邮箱码）| `{email, emailCode, role}`（**不带 username/password**）| 与密码登录同一份 `{accessToken, refreshToken,…}` |
///
/// **服务端不回显验证码**；`/auth/email/_test/*` 是仅测试用注入点（生产 404），客户端不调用。

/// 验证码用途（与后端 `EmailCodeService.EmailScene` 同源，值必须逐字一致）
class EmailCodeScene {
  EmailCodeScene._();

  /// 注册（邮箱已被注册时后端返回中文 400 —— 注册场景本就要告知占用）
  static const String register = 'register';

  /// 找回密码（**防枚举**：邮箱未注册时后端同样返回成功且不发信）
  static const String reset = 'reset';

  /// 绑定 / 换绑邮箱（2026-10-10）：**当前密码 + 新邮箱验证码**（负责人拍板 2）
  static const String bind = 'bind';

  /// 邮箱验证码登录（2026-10-10）：**仅当该邮箱已绑定某账号才真发信**（防枚举，响应逐字相同）
  static const String login = 'login';
}

/// 注册是否**必须**填邮箱（负责人 2026-10-05 决策 + 一键回退开关）
///
/// **取 true 的理由**：邮箱是当前**唯一**的找回密码通道（没有手机号通道）。
/// 不绑邮箱的账号一旦忘记密码就永久失去账号 —— 这是不可逆的用户损失，
/// 比"注册少填一格"的摩擦严重得多；且本批次已提供找回密码，注册即绑定是最小总风险。
///
/// **已知风险**：注册漏斗从此依赖外部 QQ SMTP。若邮件通道故障，`获取验证码` 失败会
/// 阻塞新用户注册（老客户端不受影响：它们不发 `email`，后端行为与旧版逐字节一致）。
/// 万一必须立刻放开注册，把本常量改成 `false` 即可回到"邮箱可选"的旧路径 ——
/// **页面、接口、后端一行都不用动**（`AuthStore.register` 对 `email` 一直是可选参数）。
const bool kRegisterEmailRequired = true;

/// 邮箱最大长度（与服务端 `@Length(1, 120)` 对齐）
const int kEmailMaxLength = 120;

/// 验证码位数（与服务端 `@Matches(/^\d{6}$/)` 对齐）
const int kEmailCodeLength = 6;

/// 新密码长度规则（与服务端注册/改密一致：8-64 位）
const int kPasswordMinLength = 8;
const int kPasswordMaxLength = 64;

/// 重发间隔（与服务端 `MAIL_CODE_RESEND_SECONDS` 默认值 60 一致）
const int kEmailCodeResendSeconds = 60;

/// 邮箱格式（本地校验用；**比服务端宽松一档的严格实现**：
/// 必须有 `@`、有域名、顶级域至少 2 位字母，不接受空格/连续点/首尾点）
final RegExp _emailPattern = RegExp(
  r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?'
  r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}$',
);

final RegExp _emailCodePattern = RegExp('^\\d{$kEmailCodeLength}\$');

/// 验证码输入格式化器：**只收 6 位数字**里的数字部分（服务端要 `^\d{6}$`；
/// 粘贴/输入法都可能带进字母，这里直接吞掉，页面不必各自 import services.dart）
final List<TextInputFormatter> emailCodeInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
];

/// 邮箱格式是否合法。**不合法时页面不得发起任何请求**（本地拦截，省一次往返与一次限流额度）
bool isEmailFormatValid(String email) {
  final v = email.trim();
  if (v.isEmpty || v.length > kEmailMaxLength) return false;
  return _emailPattern.hasMatch(v);
}

/// 邮箱本地校验的中文提示（合法 → `null`）
String? emailFormatError(String email) {
  final v = email.trim();
  if (v.isEmpty) return '请输入邮箱';
  if (v.length > kEmailMaxLength) return '邮箱最多 $kEmailMaxLength 个字符';
  return isEmailFormatValid(v) ? null : '邮箱格式不正确';
}

/// 验证码格式是否合法（6 位数字）
bool isEmailCodeFormatValid(String code) => _emailCodePattern.hasMatch(code.trim());

/// 验证码本地校验的中文提示（合法 → `null`）
String? emailCodeFormatError(String code) {
  if (code.trim().isEmpty) return '请输入验证码';
  return isEmailCodeFormatValid(code) ? null : '验证码为 $kEmailCodeLength 位数字';
}

/// 新密码本地校验的中文提示（合法 → `null`）；规则与注册一致 8-64 位
String? newPasswordFormatError(String password) {
  if (password.isEmpty) return '请输入新密码';
  if (password.length < kPasswordMinLength) return '密码至少 $kPasswordMinLength 位';
  if (password.length > kPasswordMaxLength) return '密码最多 $kPasswordMaxLength 个字符';
  return null;
}

/// 「当前密码」本地校验的中文提示（合法 → `null`）—— 绑定/换绑邮箱用
///
/// 只校验**非空 + 长度上限**，**不校验 8-64 位**：服务端 `BindEmailDto.password` 用的是
/// **登录口径** `@Length(1, 64)`（历史账号的密码规则由登录侧决定，这里只是"再确认一次是你本人"，
/// 不能比登录更严 —— 否则老账号密码短于 8 位时会永远绑不上邮箱）。
String? currentPasswordFormatError(String password) {
  if (password.isEmpty) return '请输入当前密码';
  if (password.length > kPasswordMaxLength) return '密码最多 $kPasswordMaxLength 个字符';
  return null;
}

/// 换绑提示（负责人 2026-10-10 硬要求：换绑页必须**明确告知旧邮箱的去向**）
///
/// 文案同时被页面渲染与测试断言使用（只有一处，避免改一处漏一处）。
const String kEmailRebindNotice = '更换后原邮箱将不再用于登录';

/// 「取码成功」后的界面提示（**防枚举硬要求**）
///
/// 找回密码场景**一律**用「若该邮箱已绑定…」的措辞：后端对未注册邮箱也返回成功且不发信，
/// 客户端若写「验证码已发送至 xxx」就等于把"这个邮箱存在"这个信息泄露给攻击者
/// （可用注册/找回接口批量探测账号）。**任何情况下都不得改成「邮箱不存在/未注册」**。
///
/// 邮箱验证码登录（2026-10-10）同样防枚举，但口径是**另一条**：后端对"未绑定任何账号的邮箱"
/// 返回与真发**逐字相同**的响应，所以客户端提示必须是**与绑定状态无关的同一句常量**
/// —— 一旦按"这个邮箱绑没绑账号"换措辞，就等于替服务端回答了"该邮箱是不是平台账号"。
/// 同时按负责人要求**照实提示**（后端说已发送，客户端就说已发送，不改写成"未注册"）。
String emailCodeSentHint(String scene) => switch (scene) {
      EmailCodeScene.reset => '若该邮箱已绑定，验证码已发送，请查收（10 分钟内有效）',
      EmailCodeScene.login => '验证码已发送，请注意查收（10 分钟内有效）',
      // 注册 / 绑定换绑：后端确实真发信（占用类冲突在提交接口用中文 409/400 给出）
      _ => '验证码已发送至邮箱，请注意查收（10 分钟内有效）',
    };

/// `POST /auth/email/code` 的返回（服务端只回 `ok` + 一句中文，**绝不回显验证码**）
class EmailCodeSendResult {
  const EmailCodeSendResult({required this.ok, required this.message});

  final bool ok;

  /// 服务端文案（`data.message`）；界面展示请用 [emailCodeSentHint]（防枚举口径）
  final String message;

  static const EmailCodeSendResult empty = EmailCodeSendResult(ok: true, message: '');

  factory EmailCodeSendResult.fromJson(Map<String, dynamic>? json) => EmailCodeSendResult(
        ok: json?['ok'] != false,
        message: '${json?['message'] ?? ''}',
      );
}

/// `POST /auth/password/reset` 的返回
class PasswordResetResult {
  const PasswordResetResult({required this.ok, required this.message});

  final bool ok;

  /// 服务端中文文案（默认「密码已重置，请使用新密码登录」）
  final String message;

  static const PasswordResetResult empty = PasswordResetResult(ok: true, message: '');

  factory PasswordResetResult.fromJson(Map<String, dynamic>? json) => PasswordResetResult(
        ok: json?['ok'] != false,
        message: '${json?['message'] ?? ''}',
      );
}

/// `GET /user/email` 的返回：当前账号的邮箱状态（设置页邮箱行用）
///
/// **服务端只下发脱敏邮箱**（`ab***@qq.com`，`server/src/common/mail/mailer.service.ts` 的
/// `maskEmail`）：客户端对"完整邮箱"没有使用场景，少下发一次就少一次泄露面
/// （日志/埋点/截图）。因此设置页显示的也必须是这个脱敏值 —— **不要在本地拼全量邮箱**。
class EmailBindStatus {
  const EmailBindStatus({required this.bound, this.email, required this.verified});

  /// 是否已绑定邮箱
  final bool bound;

  /// **脱敏**邮箱（如 `ab***@qq.com`）；未绑定时为 null
  final String? email;

  /// 是否已验证（服务端在绑定/找回成功时写 `email_verified_at`）
  final bool verified;

  /// 可展示的脱敏邮箱（已绑定且服务端确实给了值）；null = 应当渲染「未绑定」
  String? get maskedEmail => bound && (email ?? '').isNotEmpty ? email : null;

  /// 还没拉到状态时的占位（**不代表"未绑定"** —— 页面据此渲染"获取失败/重试"，不猜状态）
  static const EmailBindStatus unknown = EmailBindStatus(bound: false, verified: false);

  factory EmailBindStatus.fromJson(Map<String, dynamic>? json) => EmailBindStatus(
        bound: json?['bound'] == true,
        email: (json?['email'] as String?)?.trim(),
        verified: json?['verified'] == true,
      );
}

/// `POST /user/email/bind`（绑定 / 换绑同一接口）的返回
class EmailBindResult {
  const EmailBindResult({
    required this.ok,
    required this.email,
    required this.emailVerified,
    required this.rebound,
    required this.message,
  });

  final bool ok;

  /// **脱敏**邮箱（服务端返回；设置页用它立刻刷新那一行）
  final String email;

  final bool emailVerified;

  /// 是否属于「换绑」（原本已有邮箱且与新邮箱不同）—— 服务端审计里区分 bind/rebind
  final bool rebound;

  /// 服务端中文文案（「邮箱绑定成功」/「邮箱换绑成功」）
  final String message;

  static const EmailBindResult empty =
      EmailBindResult(ok: true, email: '', emailVerified: true, rebound: false, message: '');

  factory EmailBindResult.fromJson(Map<String, dynamic>? json) => EmailBindResult(
        ok: json?['ok'] != false,
        email: '${json?['email'] ?? ''}',
        emailVerified: json?['emailVerified'] != false,
        rebound: json?['rebound'] == true,
        message: '${json?['message'] ?? ''}',
      );
}

/// 认证类接口的字段归属（**服务端这些错误只给一句中文、没有 `fields[]`**，
/// 客户端必须自己映射，才能把红字落到触发它的那个输入框下方）
///
/// 背景：`AuthService` 里 `throw new BadRequestException('验证码错误')` 走全局异常过滤器后
/// 响应只有 `{code, message}`（`errorCode`/`fields` 都缺省），
/// 而 `FormErrors.bindApiException` 只认结构化 `fields[]` → 会退化成顶部浮层提示，
/// 不满足「验证码错误要落在验证码字段行内红字」的要求。
class AuthErrorField {
  AuthErrorField._();

  static const String email = 'email';
  static const String emailCode = 'emailCode';
  static const String newPassword = 'newPassword';
  static const String confirmPassword = 'confirmPassword';
  static const String password = 'password';
  static const String username = 'username';

  /// **整句**匹配规则（先于下面的子串规则）。
  ///
  /// 为什么需要它：有些短文案是**另一条长文案的真子串**，按子串匹配会误伤 ——
  /// 绑定/换绑接口的「密码错误」正是这种情况：登录接口的「账号或密码错误」也含「密码错误」，
  /// 若按子串匹配，**密码登录失败**会被标到密码格的行内红字上（既有行为是整层浮层提示
  /// ——"账号和密码里有一个错了"，落到密码格等于替服务端指认了是密码错）。
  /// 因此这里按**整句**判等，子串规则里**不得**再出现「密码错误」。
  static const List<List<String>> _exactRules = [
    // 绑定/换绑邮箱：当前密码校验失败（server `EmailBindingService.bind` → 400「密码错误」）
    ['密码错误', password],
  ];

  /// 文案 → 字段。**长文案必须排在短文案前面**：
  /// 「验证码错误次数过多」含「验证码错误」，若短文案先匹配就会被它吞掉（落错行内位置）。
  ///
  /// 归属原则：**红字贴在触发它的控件上** ——
  /// - 身份类（已注册/未注册/格式不正确）→ 邮箱输入框；
  /// - 取码动作类（发送失败/过于频繁/次数过多）与校验码本身 → 验证码输入框（「获取验证码」按钮就在这一行）；
  /// - 密码规则 → 新密码输入框；
  /// - 绑定/换绑邮箱（2026-10-10）：「该邮箱已被其他账号绑定」→ 邮箱输入框，
  ///   「密码错误」（**整句**，见 [_exactRules]）→ 当前密码输入框。
  static const List<List<String>> _rules = [
    // —— 验证码字段（先匹配最长的） ——
    ['验证码错误次数过多', emailCode],
    ['验证码已过期', emailCode],
    ['验证码错误', emailCode],
    ['请填写邮箱验证码', emailCode],
    ['邮箱验证码', emailCode],
    ['验证码', emailCode],
    ['邮件发送失败', emailCode],
    ['请求过于频繁', emailCode],
    ['获取验证码次数过多', emailCode],
    // —— 邮箱字段 ——
    // 「该邮箱已被其他账号绑定」是绑定/换绑接口的 409 文案（**必须排在泛化的 ['邮箱', email] 之前**）；
    // 「邮箱或验证码错误」是邮箱码登录的统一失败文案，含「验证码」→ 已被上面的验证码规则接住（落在验证码格）。
    ['该邮箱已被其他账号绑定', email],
    ['该邮箱已被注册', email],
    ['该邮箱未注册', email],
    ['邮箱格式不正确', email],
    ['邮箱', email],
    // —— 密码字段 ——
    ['新密码须为 8-64', newPassword],
    ['新密码', newPassword],
    ['密码至少', newPassword],
    ['密码最多', newPassword],
    ['两次输入的密码不一致', confirmPassword],
  ];

  /// 把后端返回的中文文案映射到表单字段（映射不到 → `null`，由调用方走浮层兜底）
  static String? ofMessage(String message) {
    final text = _localize(message);
    if (text.isEmpty) return null;
    for (final rule in _exactRules) {
      if (text == rule[0]) return rule[1];
    }
    for (final rule in _rules) {
      if (text.contains(rule[0])) return rule[1];
    }
    return null;
  }

  /// 去掉首尾空白与可能的字段前缀（`emailEmail …` 之类不会出现，这里只做保守清洗）
  static String _localize(String raw) => raw.trim();
}

/// 绑定认证类接口异常到表单：**结构化 `fields[]` 优先**，否则按中文文案映射到字段。
///
/// @return `true` = 已落到行内红字（调用方**不要再弹浮层**）；
///         `false` = 字段定位不到（网络异常、服务端 500 等）→ 调用方走 `AppToast.error`。
bool bindAuthApiException(FormErrors errors, ApiException e, {Map<String, String>? aliases}) {
  if (errors.bindApiException(e, aliases: aliases)) return true;

  final field = AuthErrorField.ofMessage(e.message);
  if (field == null) return false;

  // 服务端文案已是中文（过滤器保证不露英文），原样展示；标签由 FormErrors 查 kFieldLabels
  errors.clear();
  errors.set(field, e.message);
  return true;
}

/// 「获取验证码」的 60 秒重发倒计时（老板端注册 + 两端找回密码三处共用）
///
/// 只有**取码真正成功**才 [start]；失败（邮件发送失败 / 限流 / 格式错）不启动倒计时，
/// 否则按钮会在"其实没发出去"的状态下把用户按死 60 秒，比不限制更糟。
///
/// 状态变化即 [notifyListeners]；页面用 `ListenableBuilder` 重建按钮即可。
/// **必须在 `State.dispose` 里 [dispose]**（取消定时器，避免测试与真机的定时器泄漏）。
class EmailCodeCountdown extends ChangeNotifier {
  EmailCodeCountdown({this.resendSeconds = kEmailCodeResendSeconds});

  /// 倒计时总秒数（默认 60，与后端重发间隔一致）
  final int resendSeconds;

  Timer? _timer;
  int _left = 0;
  bool _sending = false;

  /// 剩余秒数（0 = 可以再次获取）
  int get left => _left;

  /// 是否正在发送请求
  bool get sending => _sending;

  /// 是否处于倒计时中
  bool get counting => _left > 0;

  /// 是否可以点「获取验证码」
  bool get canSend => !counting && !sending;

  /// 请求开始（按钮转「发送中…」并禁用）
  void beginSend() {
    if (_sending) return;
    _sending = true;
    notifyListeners();
  }

  /// 请求结束（失败时按钮恢复可点）
  void endSend() {
    if (!_sending) return;
    _sending = false;
    notifyListeners();
  }

  /// 取码成功 → 进入倒计时（不传秒数则用 [resendSeconds]）
  void start([int? seconds]) {
    _timer?.cancel();
    _left = seconds == null || seconds <= 0 ? resendSeconds : seconds;
    notifyListeners();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _left -= 1;
      if (_left <= 0) {
        _left = 0;
        timer.cancel();
        _timer = null;
      }
      notifyListeners();
    });
  }

  /// 复位（重新进入页面/切换模式时用）
  void reset() {
    _timer?.cancel();
    _timer = null;
    _left = 0;
    _sending = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
