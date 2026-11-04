import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/email_auth.dart';
import '../theme/app_colors.dart';
import 'app_icon.dart';
import 'form_errors.dart';
import 'qishan_mark.dart';

/// 登录/注册改版（方案 B「品牌主视觉」）共用组件 —— 老板端与工作端**同款**
///
/// 唯一依据：`site/design/auth/b-login.html`、`b-register.html`、`b-err-inline.html`、
/// `b-err-top.html`、`b-keyboard.html`（配套出图 `p-b-*.png`）。数值全部照稿取值：
///
/// | 元素 | 设计稿 | 本文件 |
/// |---|---|---|
/// | 品牌区 | `.b .hero` 实色 `#2563EB`、左右 24、下 30、最低 176 | [AppBrandHeader]（**不用渐变**）|
/// | 白卡 | `.b .sheet` `margin-top:-18`、圆角 14 14 0 0、padding 22/24 | 登录页卡片 |
/// | 输入框 | `.b .fill .control` 高 50、圆角 10、底 `#FAFBFD`、描边 `#E5E9F0` | [AppAuthField] |
/// | 输入框聚焦 | 白底 + 主色描边 + `0 0 0 3px #E7EEFE` | [AppAuthField] |
/// | 输入框错误 | 底 `#FDECEC` + 描边 `#DC2626` | [AppAuthField]（`hasError`）|
/// | 主按钮 | `.btn` 高 48、圆角 6、禁用 `#E9EDF4` / 字 `#94A3B8` | [AppAuthButton] |
/// | 协议勾选 | `.agree` 方框 17×17、圆角 4、勾选 = 主色实底 | [AppAgreementRow] |
/// | 间距 | 组内紧 10 / 组间松 20 / 左右 24 | 各组件默认值 |
///
/// 取色一律用 `AppColors` 常量而**不走** `T`（主题门面）：设计稿是固定品牌色，
/// 登录页不随「液态玻璃」主题换色（负责人：登录页必须脱离玻璃背景，见登录页注释）。

/// 设计稿圆角档位：4（勾选框/角标）/ 6（主按钮）/ 10（输入框）/ 14（白卡）
class AppAuthRadius {
  AppAuthRadius._();

  static const double xs = 4;
  static const double sm = 6;
  static const double control = 10;
  static const double card = 14;
}

/// 设计稿 `b-*.html` 的 `:root` 取值 —— **2026-10-16 全部收敛到 `AppColors` token**
///
/// 本轮只做一件事：把"同一语义写过两遍"的值合并到一处（方案 F 换色后，
/// 原先写死的旧值不会自动跟随，会留下"登录页还是旧灰"的局部漂移）。
/// **类名与字段名一个不删**（调用点太多），值改为引用 token。
class AppAuthColors {
  AppAuthColors._();

  /// 发丝线（浅）—— 收敛到 `AppColors.divider`（方案 F 的唯一发丝线色 `#E9EEF5`）
  static const Color hairline = AppColors.divider;

  /// 输入框静止底色 —— F 稿内实测 `#FAFBFD`，仍保留（比白卡浅半档，属一次性微调）
  static const Color fieldFill = Color(0xFFFAFBFD);

  /// 输入框静止描边 —— 收敛到 `AppColors.divider`（F 稿里输入框描边与卡片发丝线同色）
  static const Color fieldBorder = AppColors.divider;

  /// 输入框错误底 —— 收敛到提示条错误档浅底
  static const Color errorSoft = AppColors.bannerDangerBg;

  /// 勾选框未选描边 —— 收敛到 `AppColors.hairline`（"控件轮廓"那一档）
  static const Color boxBorder = AppColors.hairline;

  /// 主按钮禁用底 —— 收敛到 `AppColors.disabledBg`
  static const Color disabled = AppColors.disabledBg;
}

/// 顶部品牌主视觉区（**176px 纯实色** `#2563EB`，不要渐变）
///
/// 结构（照 `b-login.html` 的 `.hero`）：小山标 + 品牌名 / 标题 / 副文案 / 数据行。
///
/// **高度 176 是"最低高度"**：内容天然高于 176 时由内容撑开（内容不可能被裁掉）；
/// 副文案与数据行各限 1 行（超长省略），保证手机壳里白卡起始位置与设计稿一致。
class AppBrandHeader extends StatelessWidget {
  /// 二级页返回箭头的稳定 Key（找回密码页测试用）
  static const Key backKey = Key('auth-brand-back');

  const AppBrandHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.facts = const [],
    this.showMark = true,
    this.height = 176,
    this.color = AppColors.primary,
    this.onBack,
  });

  /// 主标题（登录 / 创建账号）
  final String title;

  /// 副文案（可空；请用**不会过期**的文案，不要写死分部数量/客服时段）
  final String? subtitle;

  /// 数据行（如「3 个分部在营」「客服 9:00-次日 2:00 在线」）
  final List<BrandFact> facts;

  /// 是否显示小山标
  final bool showMark;

  /// 品牌区最低高度（设计稿 176）
  final double height;

  /// 实色底（默认品牌主色 `#2563EB`）
  final Color color;

  /// 左上角返回箭头（**仅二级页**用，如找回密码）；为 null 时不渲染（登录页视觉不变）
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: height),
      // 设计稿 .hero：padding 6 24 30；顶部再叠状态栏安全区（statusbar.on-brand 白字）
      padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 6, 24, 30),
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showMark || onBack != null) ...[
            Row(
              children: [
                if (onBack != null) ...[
                  // 26×26 白箭头（二级页返回；与品牌行同一行，不额外占高度）
                  Semantics(
                    button: true,
                    label: '返回',
                    child: InkWell(
                      key: AppBrandHeader.backKey,
                      onTap: onBack,
                      borderRadius: BorderRadius.circular(AppAuthRadius.xs),
                      child: const SizedBox(
                        width: 26,
                        height: 26,
                        child: AppIcon.of(AppIconsLegacy.arrow_back_ios_new_rounded, size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                if (showMark) ...[
                  const AppQishanMark(size: 20, color: Colors.white),
                  const SizedBox(width: 9),
                  Text(
                    '祁连山电竞',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: Colors.white.withValues(alpha: .94),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
          ],
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              letterSpacing: -.2,
              color: Colors.white,
              height: 1.2,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, height: 1.55, color: Colors.white.withValues(alpha: .82)),
            ),
          ],
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < facts.length; i++) ...[
                  if (i > 0) const SizedBox(width: 18),
                  facts[i],
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 品牌区数据行里的一项：`{value} {label}`（value 加粗纯白，label 半透明白）
class BrandFact extends StatelessWidget {
  const BrandFact({super.key, required this.label, this.value});

  /// 可空：纯文案（如「客服时段见公告」）时不加粗
  final String? value;

  /// 描述文案
  final String label;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontSize: 11.5, color: Color(0xDBFFFFFF));
    final head = value;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (head != null && head.isNotEmpty) ...[
          Text(head, style: base.copyWith(fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(width: 4),
        ],
        Text(label, style: base),
      ],
    );
  }
}

/// 白卡内的 filled 输入框（浅底 → 聚焦白底 + 主色描边 + 圆角 10）
///
/// - 标签在**框外上方**（12 / w600 / `#94A3B8`，间距 6）—— 照设计稿，不用浮动标签
/// - 前置图标 + 输入 + 明文切换（眼睛）；高度 50
/// - 传了 [errors] + [errorField] 时，框下方自动渲染**既有** [AppFieldError]（行内红字）
/// - [trailing]：框内右侧插槽（2026-10-05 邮箱验证码用它放「获取验证码」按钮，
///   与眼睛按钮同一位置规则，视觉不新造一套）
class AppAuthField extends StatefulWidget {
  const AppAuthField({
    super.key,
    this.label,
    required this.controller,
    this.icon,
    this.hint,
    this.obscure = false,
    this.enabled = true,
    this.textInputAction,
    this.autofillHints,
    this.errors,
    this.errorField = '',
    this.hasError = false,
    this.onChanged,
    this.onSubmitted,
    this.fieldKey,
    this.keyboardType,
    this.inputFormatters,
    this.maxLength,
    this.trailing,
  });

  final String? label;
  final TextEditingController controller;
  final IconData? icon;
  final String? hint;
  final bool obscure;
  final bool enabled;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;

  /// 行内错误的来源（[FormErrors] 或 `ValueNotifier<FormErrors>`）；不传则不挂行内红字
  final Object? errors;

  /// 行内红字对应的字段名
  final String errorField;

  /// 强制错误态（服务端已标红但本页不展示行内文案时用）
  final bool hasError;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Key? fieldKey;

  /// 键盘类型（邮箱用 `TextInputType.emailAddress`、验证码用 `TextInputType.number`）
  final TextInputType? keyboardType;

  /// 输入格式化（验证码用 digitsOnly）
  final List<TextInputFormatter>? inputFormatters;

  /// 最大长度（非空时自动加 `LengthLimitingTextInputFormatter`，并**关掉右下角计数器**）
  final int? maxLength;

  /// 框内右侧插槽（如 [AppAuthCodeButton]）；有值时渲染在眼睛按钮左侧
  final Widget? trailing;

  @override
  State<AppAuthField> createState() => _AppAuthFieldState();
}

class _AppAuthFieldState extends State<AppAuthField> {
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);
  bool _visible = false;

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final failed = widget.hasError || (widget.errorField.isNotEmpty && _inlineMessage() != null);
    final fill = !widget.enabled
        ? AppAuthColors.disabled
        : failed
            ? AppAuthColors.errorSoft
            : focused
                ? Colors.white
                : AppAuthColors.fieldFill;
    final stroke = failed
        ? AppColors.error
        : focused
            ? AppColors.primary
            : AppAuthColors.fieldBorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null && widget.label!.isNotEmpty) ...[
          Text(
            widget.label!,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 6),
        ],
        DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(AppAuthRadius.control),
            border: Border.all(color: stroke),
            boxShadow: focused && !failed ? const [BoxShadow(color: AppColors.primarySoft, spreadRadius: 3)] : null,
          ),
          child: SizedBox(
            height: 50,
            child: Row(
              children: [
                if (widget.icon != null) ...[
                  const SizedBox(width: 12),
                  AppIcon.of(widget.icon, size: 18, color: AppColors.textTertiary),
                ],
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: widget.icon == null ? 12 : 8, right: 12),
                    child: TextField(
                      key: widget.fieldKey,
                      controller: widget.controller,
                      focusNode: _focus,
                      enabled: widget.enabled,
                      obscureText: widget.obscure && !_visible,
                      keyboardType: widget.keyboardType,
                      // 只透传调用方给的格式化器；长度上限交给 TextField 的 maxLength
                      // （`EditableText` 会在**用户格式化器之后**再挂一个 LengthLimiting…
                      //  —— 我们自己再挂一个会让 digitsOnly 跑在截断之后，
                      //  实测把 `abc123456789` 变成 `123` 而不是期望的 `123456`）
                      inputFormatters: widget.inputFormatters,
                      maxLength: widget.maxLength,
                      textInputAction: widget.textInputAction,
                      autofillHints: widget.autofillHints,
                      onChanged: widget.onChanged,
                      onSubmitted: widget.onSubmitted,
                      style: TextStyle(
                        fontSize: 15,
                        color: widget.enabled ? AppColors.textPrimary : AppColors.textTertiary,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: widget.hint,
                        hintStyle: const TextStyle(fontSize: 15, color: AppColors.textTertiary),
                        // 设计稿没有右下角「0/6」计数器；maxLength 非空时显式关掉
                        counterText: widget.maxLength == null ? null : '',
                      ),
                    ),
                  ),
                ),
                if (widget.trailing != null) widget.trailing!,
                if (widget.obscure && widget.enabled)
                  _EyeButton(visible: _visible, onTap: () => setState(() => _visible = !_visible)),
              ],
            ),
          ),
        ),
        if (widget.errors != null && widget.errorField.isNotEmpty) AppFieldError(widget.errors!, widget.errorField),
      ],
    );
  }

  /// 行内错误文案（仅用于判断"是否错误态"；文案渲染仍交给既有 AppFieldError）
  String? _inlineMessage() {
    final source = widget.errors;
    if (source is FormErrors) return source.messageOf(widget.errorField);
    if (source is ValueNotifier<FormErrors>) return source.value.messageOf(widget.errorField);
    return null;
  }
}

/// 明文/密文切换的"眼睛"（44×50 热区，图标 18）
class _EyeButton extends StatelessWidget {
  const _EyeButton({required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: visible ? '隐藏密码' : '显示密码',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppAuthRadius.sm),
          child: SizedBox(
            width: 44,
            height: 50,
            child: Icon(
              visible ? AppIconsLegacy.visibility : AppIconsLegacy.visibility_outlined,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ),
        ),
      );
}

/// 「获取验证码」按钮（放在 [AppAuthField.trailing] 槽内，与眼睛按钮同一位置规则；2026-10-05 邮箱通道）
///
/// 三态文案（[labelOf] 是唯一来源，页面与测试都据此断言）：
/// - 可点：`获取验证码`
/// - 倒计时中：`{n}s 后重发`（**禁用**，点不动、不发请求）
/// - 请求中：`发送中…`（禁用）
///
/// 刻意**不用转圈动画**：① 这里是 40 高的文字按钮，转圈会撑动布局；
/// ② 无限动画会让 widget 测试的 `pumpAndSettle` 永不收敛（既有测试大量使用它）。
class AppAuthCodeButton extends StatelessWidget {
  const AppAuthCodeButton({super.key, required this.countdown, this.onPressed});

  /// 倒计时状态源（页面持有并负责 dispose；本组件只读）
  final EmailCodeCountdown countdown;

  /// 可点时的回调（[EmailCodeCountdown.canSend] 为 false 时一律不触发）
  final VoidCallback? onPressed;

  /// 稳定 Key（两端测试与自动化都用它点「获取验证码」）
  static const Key buttonKey = Key('auth-send-code');

  /// 三态文案（页面/测试共用，避免文案两处各写一份）
  static String labelOf({required bool sending, required int left}) {
    if (sending) return '发送中…';
    return left > 0 ? '${left}s 后重发' : '获取验证码';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: countdown,
      builder: (context, _) {
        final enabled = countdown.canSend && onPressed != null;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 与输入区之间的发丝线分隔（设计稿 .fill 内的分隔风格）
            Container(width: 1, height: 20, color: AppAuthColors.hairline),
            TextButton(
              key: buttonKey,
              onPressed: enabled ? onPressed : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(88, 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: AppColors.primary,
                disabledForegroundColor: AppColors.textTertiary,
                // textStyle 是整体替换（与 AppAuthButton 同理），必须显式带上主题中文字体，
                // 否则 flutter_test 里会渲染成 Ahem 方块
                textStyle: TextStyle(
                  fontFamily: Theme.of(context).textTheme.labelLarge?.fontFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppAuthRadius.sm)),
              ),
              child: Text(labelOf(sending: countdown.sending, left: countdown.left)),
            ),
          ],
        );
      },
    );
  }
}

/// 实色主按钮（高 48 / 圆角 6 / `#2563EB`；禁用 `#E9EDF4` + 字 `#94A3B8`）
///
/// [onDisabledTap]：**禁用态仍可点出提示**（协议未勾选时点按钮 → 中文提醒；
/// 按钮本体照设计稿是灰态、不发起任何请求）。
class AppAuthButton extends StatelessWidget {
  const AppAuthButton({
    super.key,
    required this.label,
    this.onPressed,
    this.loading = false,
    this.onDisabledTap,
    this.height = 48,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final VoidCallback? onDisabledTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final button = SizedBox(
      width: double.infinity,
      height: height,
      child: TextButton(
        onPressed: enabled ? onPressed : null,
        style: TextButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppAuthColors.disabled,
          disabledForegroundColor: AppColors.textTertiary,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppAuthRadius.sm)),
          // fontFamily 必须显式带上：`ButtonStyle.textStyle` 是**整体替换**（不是与父级
          // DefaultTextStyle 合并），不写就会丢掉主题里的中文字体（真机上兜底到系统字体，
          // 在 flutter_test 里直接渲染成 Ahem 方块）。取值仍来自主题，不写死字体名。
          textStyle: TextStyle(
            fontFamily: Theme.of(context).textTheme.labelLarge?.fontFamily,
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
            letterSpacing: .3,
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(label),
      ),
    );
    if (enabled || onDisabledTap == null) return button;
    // 禁用态包一层：吞掉按钮自身点击，只把点击转成提示（不发请求、不改状态）
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDisabledTap,
      child: AbsorbPointer(child: button),
    );
  }
}

/// 协议勾选行（主按钮上方，发丝线分隔；**未勾选不得提交**——纯前端约束，后端无此校验）
///
/// 文案：`我已阅读并同意《用户协议》与《隐私政策》`；
/// 两个书名号内文字**可点**（[onAgreement] / [onPrivacy] 打开既有阅读页）。
/// 勾选状态由页面持有（本组件受控），**不持久化**：每次进页面默认未勾选（负责人要求）。
class AppAgreementRow extends StatefulWidget {
  const AppAgreementRow({
    super.key,
    required this.value,
    required this.onChanged,
    this.onAgreement,
    this.onPrivacy,
    this.showDivider = true,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// 点《用户协议》
  final VoidCallback? onAgreement;

  /// 点《隐私政策》
  final VoidCallback? onPrivacy;

  /// 是否在上方画一条发丝线（设计稿的分隔）
  final bool showDivider;

  /// 方框 17×17（设计稿 `.box`）
  static const double boxSize = 17;

  /// 方框的稳定 Key（两端测试与自动化都用它勾选/取消）
  static const Key checkBoxKey = Key('auth-agreement-checkbox');

  /// 整行文案的稳定 Key（点《用户协议》/《隐私政策》用 `find.text` 定位书名号内文字）
  static const Key rowKey = Key('auth-agreement-row');

  @override
  State<AppAgreementRow> createState() => _AppAgreementRowState();
}

class _AppAgreementRowState extends State<AppAgreementRow> {
  late final TapGestureRecognizer _agreement = TapGestureRecognizer()..onTap = widget.onAgreement;
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()..onTap = widget.onPrivacy;

  @override
  void dispose() {
    _agreement.dispose();
    _privacy.dispose();
    super.dispose();
  }

  static const TextStyle _body = TextStyle(fontSize: 11.5, height: 1.5, color: AppColors.textSecondary);
  static const TextStyle _link =
      TextStyle(fontSize: 11.5, height: 1.5, fontWeight: FontWeight.w600, color: AppColors.primary);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showDivider) const Divider(height: 1, thickness: 1, color: AppAuthColors.hairline),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CheckBox(value: widget.value, onTap: () => widget.onChanged(!widget.value)),
            const SizedBox(width: 9),
            Expanded(
              child: Text.rich(
                key: AppAgreementRow.rowKey,
                TextSpan(
                  children: [
                    const TextSpan(text: '我已阅读并同意'),
                    TextSpan(text: '《用户协议》', style: _link, recognizer: _agreement),
                    const TextSpan(text: '与'),
                    TextSpan(text: '《隐私政策》', style: _link, recognizer: _privacy),
                  ],
                ),
                style: _body,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 17×17 方框（未勾：白底 + `#CFD8E6` 描边 + 圆角 4；已勾：主色实底 + 白勾）
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.value, required this.onTap});

  final bool value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: value,
        label: '同意用户协议与隐私政策',
        child: GestureDetector(
          key: AppAgreementRow.checkBoxKey,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 34, // 方框 17 + 左侧热区扩展（设计稿方框仍是 17）
            height: AppAgreementRow.boxSize,
            alignment: Alignment.centerLeft,
            child: Container(
              width: AppAgreementRow.boxSize,
              height: AppAgreementRow.boxSize,
              decoration: BoxDecoration(
                color: value ? AppColors.primary : Colors.white,
                borderRadius: BorderRadius.circular(AppAuthRadius.xs),
                border: Border.all(color: value ? AppColors.primary : AppAuthColors.boxBorder),
              ),
              child: value ? const AppIcon.of(AppIcon.check, size: 13, color: Colors.white) : null,
            ),
          ),
        ),
      );
}
