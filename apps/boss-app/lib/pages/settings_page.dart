import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'about_privacy_page.dart';
import 'email_bind_page.dart';
import 'feedback_page.dart';
import 'security_page.dart';

/// 设置（负责人 2026-10-04：去掉玻璃卡 / miuix 偏好项，改设计稿 I 系列风格）
///
/// 结构：自绘页头（AppPageHeader）+ AppSectionHeader 分组 + AppCard（圆角 16 + 发丝线）
/// 功能全保留：通知开关 / 清除缓存 / 账号与安全（改密码）/ 关于 / 隐私 / 意见反馈 / 退出登录
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.versionOverride, this.api});

  /// **仅测试/出图用**的版本行覆盖值（如 `v1.11.29（85）`）。
  ///
  /// 真实运行永远为 null → 取 [AppConfig.versionLine]（构建期 `--dart-define` 注入的真值）。
  /// 有它才能把"这一行确实渲染出了注入的版本号"写成断言 ——
  /// 否则测试只能断言默认的 `v1.0.0（1）`，等于没验证渲染链路。
  final String? versionOverride;

  /// 测试注入（不传 → AuthStore 内部单例客户端）；邮箱状态与绑定请求都走它
  final ApiClient? api;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _friendNotify = true;
  bool _csNotify = true;
  bool _clearing = false;

  /// 邮箱状态（`GET /user/email`）——**唯一数据源是服务端**。
  ///
  /// null = 还没拿到（加载中或失败）→ 页面渲染「正在获取…」/「点击重试」，
  /// **绝不用本地值猜「未绑定/已绑定」**：邮箱是登录凭据，猜错会让用户点进错误的页面。
  EmailBindStatus? _emailStatus;
  bool _emailLoading = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadEmailStatus();
  }

  Future<void> _loadPrefs() async {
    final f = await AppSettings.instance.friendNotifyEnabled();
    final c = await AppSettings.instance.csNotifyEnabled();
    if (mounted) {
      setState(() {
        _friendNotify = f;
        _csNotify = c;
      });
    }
  }

  /// 拉邮箱状态（进页面 / 绑定换绑返回后 / 失败点击重试都走它）
  Future<void> _loadEmailStatus() async {
    if (_emailLoading) return;
    setState(() => _emailLoading = true);
    try {
      final status = await AuthStore.instance.fetchEmailStatus(api: widget.api);
      if (!mounted) return;
      setState(() {
        _emailStatus = status;
        _emailLoading = false;
      });
    } on ApiException {
      // **不吞错、也不假装未绑定**：状态未知 → 那一行显示「获取失败，点击重试」
      if (!mounted) return;
      setState(() {
        _emailStatus = null;
        _emailLoading = false;
      });
    }
  }

  /// 点邮箱行：状态未知时先重试取状态（不猜两态）；已知则进绑定/换绑页
  Future<void> _openEmailBind() async {
    if (_emailLoading) return;
    final status = _emailStatus;
    if (status == null) {
      await _loadEmailStatus();
      return;
    }
    final result = await Navigator.of(context).push<EmailBindResult>(
      AppMotionRoute<EmailBindResult>(
        builder: (_) => EmailBindPage(api: widget.api, currentEmail: status.maskedEmail),
      ),
    );
    if (!mounted || result == null) return;
    // 服务端返回的就是**脱敏**邮箱（响应即权威值）→ 立刻刷新这一行，再拉一次状态兜底
    // （提示必须在**设置页**弹：绑定页 pop 之后它的 Overlay 已经没了）
    setState(() => _emailStatus =
        EmailBindStatus(bound: true, email: result.email, verified: result.emailVerified));
    AppToast.success(context, result.message.isEmpty ? '邮箱已更新' : result.message);
    await _loadEmailStatus();
  }

  Future<void> _setFriendNotify(bool v) async {
    setState(() => _friendNotify = v);
    await AppSettings.instance.setFriendNotify(v);
  }

  Future<void> _setCsNotify(bool v) async {
    setState(() => _csNotify = v);
    await AppSettings.instance.setCsNotify(v);
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    // 真实效果：清空 Flutter 图片内存缓存（网络图片缓存由框架自动管理）
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => _clearing = false);
    AppToast.success(context, '缓存已清除');
  }

  void _push(Widget page) {
    Navigator.of(context).push<void>(AppMotionRoute<void>(builder: (_) => page));
  }

  /// 点「当前服务器地址」= 复制完整地址（用户报障时贴给运营，比截图更好用）
  Future<void> _copyAddress() async {
    final String text = '${AppConfig.apiBase} '
        '(ws=${AppConfig.wsBase} source=${AppConfig.addressSource ?? '-'})';
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) AppToast.success(context, '服务器地址已复制');
  }

  /// 点「当前版本」= 复制版本行（`v1.11.29（85）`）—— 报障时一句话说清是哪一版
  Future<void> _copyVersion() async {
    await Clipboard.setData(ClipboardData(text: _versionLine));
    if (mounted) AppToast.success(context, '版本号已复制');
  }

  /// 上屏/复制的版本行（真实运行 = 构建期注入值；测试可覆盖）
  String get _versionLine => widget.versionOverride ?? AppConfig.versionLine;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.scaffoldColor,
      body: Column(
        children: [
          const AppPageHeader(title: '设置'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                const AppSectionHeader(title: '账号', padding: EdgeInsets.fromLTRB(16, 16, 16, 8)),
                _card([
                  _row(
                    icon: AppIcon.info,
                    title: '关于 祁连山电竞',
                    sub: '版本、协议与反馈',
                    onTap: () => _push(const AboutPrivacyPage(kind: 'about')),
                  ),
                  const AppHairline(indent: 54),
                  _row(
                    icon: AppIcon.shield,
                    title: '隐私政策',
                    sub: '我们如何收集与使用信息',
                    onTap: () => _push(const AboutPrivacyPage(kind: 'privacy')),
                  ),
                  const AppHairline(indent: 54),
                  // 【2026-10-10 邮箱能力】邮箱行：未绑定 →「未绑定」+「绑定」；
                  // 已绑定 → 脱敏邮箱 +「已验证」+「更换」。状态来自 `GET /user/email`（服务端权威）。
                  _emailRow(),
                  const AppHairline(indent: 54),
                  _row(
                    icon: AppIcon.lock,
                    title: '账号与安全',
                    sub: '修改密码、登录保护',
                    onTap: () => _push(const SecurityPage()),
                  ),
                ]),
                const AppSectionHeader(title: '消息通知'),
                _card([
                  _switch(
                    icon: AppIcon.users,
                    title: '好友申请通知',
                    sub: '有人加你好友时提醒',
                    value: _friendNotify,
                    onChanged: _setFriendNotify,
                  ),
                  const AppHairline(indent: 54),
                  _switch(
                    icon: AppIcon.headset,
                    title: '客服消息通知',
                    sub: '客服回复时提醒',
                    value: _csNotify,
                    onChanged: _setCsNotify,
                  ),
                ]),
                const AppSectionHeader(title: '通用'),
                _card([
                  _row(
                    icon: AppIcon.trash,
                    title: '清除缓存',
                    sub: _clearing ? '正在清理…' : '清空本地图片缓存',
                    onTap: _clearing ? null : _clearCache,
                  ),
                  const AppHairline(indent: 54),
                  _row(
                    icon: AppIcon.comment,
                    title: '意见反馈',
                    sub: '问题与建议直达运营',
                    onTap: () => _push(const FeedbackPage()),
                  ),
                ]),
                // 【2026-10-06 地址发现韧性】「当前服务器地址」诊断行：
                // 公网入口有 ngrok / Cloudflare 隧道 / 局域网多条，用户报障时
                // "连不上"到底是哪一条、走的哪个引导源，截图这一行就够了。
                const AppSectionHeader(title: '诊断'),
                _card([
                  _row(
                    icon: AppIcon.cloud,
                    title: '当前服务器地址',
                    sub: AppConfig.serverAddressLine,
                    onTap: _copyAddress,
                  ),
                  const AppHairline(indent: 54),
                  // 【2026-10-07 负责人要求】版本行：报障/验收时先确认"手机上到底是哪一版"。
                  // 取值全部来自构建期注入的 AppConfig（不写死；格式 `v1.11.29（85）`）。
                  _row(
                    icon: AppIcon.info,
                    title: '当前版本',
                    sub: _versionLine,
                    onTap: _copyVersion,
                  ),
                ]),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _logoutButton(),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text('余额与账号均由平台统一管理',
                      style: TextStyle(fontSize: 10.5, color: T.mutedText)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分组卡片（AppCard 内零内边距，行自带左右 16，配发丝线）
  Widget _card(List<Widget> children) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: AppCard(padding: EdgeInsets.zero, child: Column(children: children)),
      );

  /// 带图标 / 标题 / 副文案 / 右箭头的行（文案左对齐）
  Widget _row({
    required IconData icon,
    required String title,
    required String sub,
    VoidCallback? onTap,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.categorySoft(AppColors.primary),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: AppIcon.of(icon, size: 17, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary)),
                    const SizedBox(height: 2),
                    Text(sub, style: TextStyle(fontSize: 11, color: T.mutedText)),
                  ],
                ),
              ),
              AppIcon.of(AppIcon.chevronRight, size: 18, color: T.textTertiary),
            ],
          ),
        ),
      );

  /// 邮箱行（2026-10-10 邮箱能力）——行结构与 [_row] 同源，额外多两处：
  /// ① 已绑定时的**脱敏邮箱**与「已验证」标记；② 右侧的**动作词**（绑定 / 更换）而不是光秃秃的箭头。
  ///
  /// 三态（**状态未拿到时不许猜两态**）：
  /// - 拉取中：`正在获取…` + 不可点；
  /// - 拉取失败：`获取失败，点击重试`（点击=重试取状态，不进绑定页）；
  /// - 成功：`未绑定`+「绑定」/ 脱敏邮箱 +「已验证」+「更换」。
  Widget _emailRow() {
    final status = _emailStatus;
    final masked = status?.maskedEmail;
    final bound = masked != null;
    final sub = _emailLoading
        ? '正在获取…'
        : status == null
            ? '获取失败，点击重试'
            : (bound ? masked : '未绑定');
    // 状态未知（加载中/失败）→ 不显示动作词：此时显示「绑定」或「更换」都是在猜
    final action = (_emailLoading || status == null) ? null : (bound ? '更换' : '绑定');
    return InkWell(
      key: const Key('settings-email-row'),
      onTap: _emailLoading ? null : _openEmailBind,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.categorySoft(AppColors.primary),
                borderRadius: BorderRadius.circular(10),
              ),
              child: AppIcon.of(bound ? AppIcon.mailVerified : AppIcon.mail, size: 17, color: AppColors.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('邮箱',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: T.mutedText)),
                      ),
                      // 已验证标记：只在"已绑定且服务端说 verified"时出现（不臆造）
                      if (bound && (status?.verified ?? false)) ...[
                        const SizedBox(width: 6),
                        const AppTag('已验证', color: AppColors.statusOnline),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (action != null)
              Text(action,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: T.primary)),
            AppIcon.of(AppIcon.chevronRight, size: 18, color: T.textTertiary),
          ],
        ),
      ),
    );
  }

  /// 开关行（沿用原有偏好项读写，仅换外观）
  Widget _switch({
    required IconData icon,
    required String title,
    required String sub,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.categorySoft(AppColors.statusOnline),
                borderRadius: BorderRadius.circular(10),
              ),
              child: AppIcon.of(icon, size: 17, color: AppColors.statusOnline),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 11, color: T.mutedText)),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      );

  /// 退出登录（危险动作：白卡 + 红字描边，不做渐变主按钮）
  Widget _logoutButton() => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async => AuthStore.instance.logout(),
          child: Container(
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: T.bgCardSolid,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.error.withValues(alpha: .35)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon.of(AppIcon.logout, size: 17, color: AppColors.error),
                const SizedBox(width: 6),
                Text('退出登录',
                    style: TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.error)),
              ],
            ),
          ),
        ),
      );
}
