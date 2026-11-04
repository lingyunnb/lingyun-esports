import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import 'about_privacy_page.dart';
import 'feedback_page.dart';
import 'security_page.dart';

/// 设置（工作端；2026-10-04 整改：去掉玻璃卡 / miuix 偏好项，改设计稿 I 系列风格）
///
/// 结构：自绘页头（AppPageHeader）+ AppSectionHeader 分组 + AppCard（圆角 16 + 发丝线）
/// 功能全保留：通知开关 / 清除缓存 / 账号与安全（改密码）/ 关于 / 隐私 / 意见反馈 / 退出登录
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _friendNotify = true;
  bool _csNotify = true;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
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
                    sub: '客服会话有新消息时提醒',
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
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _logoutButton(),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text('接单与客服权限由平台统一授予',
                      style: TextStyle(fontSize: 10.5, color: T.textTertiary)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分组卡片（AppCard 内零内边距，行自带左右内边距，配发丝线）
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
                child: Icon(icon, size: 17, color: AppColors.primary),
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
                    Text(sub, style: TextStyle(fontSize: 11, color: T.textTertiary)),
                  ],
                ),
              ),
              Icon(AppIcon.chevronRight, size: 18, color: T.textTertiary),
            ],
          ),
        ),
      );

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
              child: Icon(icon, size: 17, color: AppColors.statusOnline),
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
                  Text(sub, style: TextStyle(fontSize: 11, color: T.textTertiary)),
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
                Icon(AppIcon.logout, size: 17, color: AppColors.error),
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
