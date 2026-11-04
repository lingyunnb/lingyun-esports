import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../auth/auth_store.dart';
import '../icons/app_icon.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import 'identity_widgets.dart';

/// 打手简介（陪玩介绍）编辑弹层 —— 负责人 2026-10-17 改定「介绍让打手自己写」
///
/// 只在**打手态**（`IdentityWorkerMinePage` 的「个人介绍」卡片）可打开；
/// 老板态「我的」页（`apps/boss-app/lib/pages/profile_page.dart`）没有这个入口 ——
/// 服务端也只对 `role=worker` 放行（老板 primary 调 `PUT /worker/profile` → 403），
/// 客户端隐藏只是"不诱导"，真正边界在服务端。
///
/// ## 三条实现约定
/// 1. **不自己写业务校验的第二份**：长度/换行/联系方式这些规则**唯一实现在服务端**
///    （`server/src/modules/worker/worker-intro.rules.ts`）。客户端只做两件本地事：
///    ① 字数显示（`maxLength: 120` 物理上限 + `N/120` 实时计数）；
///    ② 首尾空白在点保存时就地拦（纯展示性问题，不需要一次网络往返）。
///    其余一律以服务端中文原文为准，`AppIdentityBanner.error` 原样显示（不改写、不分类）；
///    这样服务端把文案改一个字，这里一个字都不用动。
/// 2. **成功后把新值回传给调用页**：返回值 = 保存成功的简介；取消/返回 = null。
///    打手态「我的」页据此 `setState`，「个人介绍」卡片立刻显示新文案
///    （老板端「找陪玩」列表走自己的 30s SWR 缓存，见 `api_cache.dart` 的 `/public/players`，
///    到点或下拉刷新即变 —— 刻意不为这一处强行清缓存）。
/// 3. **多行输入但只允许 1 个换行**：`TextField` 的软换行由 `maxLines` 负责显示，
///    用户按回车插换行时，服务端允许 1 个；多于 1 个由服务端拒绝并回中文原文。
///    客户端不预先吞掉换行（吞掉等于偷偷改用户输入）。
class WorkerIntroSheet extends StatefulWidget {
  const WorkerIntroSheet({super.key, this.api, this.initial = ''});

  /// 测试注入（不传 → 用默认 [ApiClient]）
  final ApiClient? api;

  /// 当前简介（回填输入框）
  final String initial;

  /// 打开弹层；返回**保存成功后的简介**，取消/关闭返回 null
  static Future<String?> show(BuildContext context, {ApiClient? api, String initial = ''}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x6B0F172A),
      builder: (_) => WorkerIntroSheet(api: api, initial: initial),
    );
  }

  @override
  State<WorkerIntroSheet> createState() => _WorkerIntroSheetState();
}

/// 简介口径常量（与服务端同源的那两个数字；**只用于输入框显示与本地就拦**，
/// 真实判定仍在服务端 `worker-intro.rules.ts`）
class WorkerIntroRules {
  WorkerIntroRules._();

  static const int minLength = 2;
  static const int maxLength = 120;

  /// 按「字符数」计数（emoji / 生僻字算 1 个），与服务端 `Array.from(text).length` 同口径
  static int lengthOf(String text) => text.runes.length;
}

class _WorkerIntroSheetState extends State<WorkerIntroSheet> {
  late final ApiClient _api = widget.api ?? ApiClient();
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _len => WorkerIntroRules.lengthOf(_controller.text);

  /// 首尾空白（含首尾换行）：服务端会 400，这里就地拦，省一次往返
  bool get _hasEdgeSpace => _controller.text != _controller.text.trim();

  bool get _tooShort => _len < WorkerIntroRules.minLength;

  bool get _canSave => !_busy && !_tooShort && !_hasEdgeSpace;

  Future<void> _save() async {
    final text = _controller.text;
    if (_hasEdgeSpace) {
      setState(() => _error = '简介首尾不能有空格或换行');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resp = await _api.request(
        'PUT',
        '/worker/profile',
        token: AuthStore.instance.activeToken,
        data: <String, dynamic>{'intro': text},
      );
      if (!mounted) return;
      // 以**服务端回传值**为准（服务端可能做过 `\r\n` 归一，客户端不假设）
      final saved = '${(resp['data'] as Map<String, dynamic>?)?['intro'] ?? text}';
      Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 服务端中文原文（长度 / 换行 / 联系方式…），不改写
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 键盘弹起时把弹层顶上去（否则输入框被遮住）
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: BoxDecoration(
        color: T.bgCardSolid,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        boxShadow: const [BoxShadow(color: Color(0x2E0F172A), blurRadius: 30, offset: Offset(0, -10))],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 8),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 4,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(color: AppColors.dragHandle, borderRadius: BorderRadius.circular(2)),
                    ),
                    Text('个人介绍', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: T.textPrimary)),
                    const Spacer(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _busy ? null : () => Navigator.of(context).maybePop(),
                      child: Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: T.divider),
                        ),
                        child: AppIcon.of(AppIdentityIcons.close, size: 16, color: T.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '老板会看到这段话：写点具体的——擅长什么、什么时候在线、接不接急单。',
                      style: TextStyle(fontSize: 12.5, color: AppColors.mutedText, height: 1.55),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: T.bgCardSolid,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: T.divider),
                      ),
                      padding: const EdgeInsets.fromLTRB(11, 8, 11, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          TextField(
                            controller: _controller,
                            enabled: !_busy,
                            minLines: 3,
                            maxLines: 6,
                            // 物理上限 120：超出根本打不进去（服务端仍会独立校验）
                            maxLength: WorkerIntroRules.maxLength,
                            textInputAction: TextInputAction.newline,
                            keyboardType: TextInputType.multiline,
                            style: TextStyle(fontSize: 13.5, color: T.textPrimary, height: 1.5),
                            decoration: const InputDecoration(
                              hintText: '例：和平精英双排老手，稳定上分不墨迹。工作日 20:00-次日 1:00 在线，不接急单。',
                              hintMaxLines: 3,
                              hintStyle: TextStyle(fontSize: 12.5, color: AppColors.textTertiary, height: 1.5),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              // 计数器自己画（要显示 N/120，且不想看到 Material 默认的居中样式）
                              counterText: '',
                            ),
                            onChanged: (_) => setState(() => _error = null),
                            inputFormatters: [LengthLimitingTextInputFormatter(WorkerIntroRules.maxLength)],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  // 唯一一处提示：不要留联系方式（与负责人「请勿私加打手」一致）
                                  '不要留手机号 / 微信 / QQ',
                                  style: TextStyle(fontSize: 10.5, color: AppColors.textTertiary),
                                ),
                              ),
                              Text(
                                '$_len/${WorkerIntroRules.maxLength}',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: _tooShort ? AppColors.error : AppColors.mutedText,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // 就地提示（不需要点保存才知道为什么存不了）：
                    // ① 首尾空白 —— 服务端会 400，这里先说清楚；② 不足 2 个字。
                    // 两条互斥，先报首尾空白（它是"改一个字就能好"，比长度更靠前）。
                    if (_hasEdgeSpace || _tooShort) ...[
                      const SizedBox(height: 8),
                      Text(
                        _hasEdgeSpace ? '简介首尾不能有空格或换行' : '至少写 ${WorkerIntroRules.minLength} 个字',
                        style: const TextStyle(fontSize: 11.5, color: AppColors.error),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      AppIdentityBanner.error(title: _error!),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 20),
                child: Column(
                  children: [
                    AppIdentityPrimaryButton(
                      label: '保存',
                      busy: _busy,
                      onPressed: _canSave ? _save : null,
                    ),
                    const SizedBox(height: 9),
                    AppIdentityOutlineButton(
                      label: '取消',
                      height: 40,
                      expand: true,
                      onTap: _busy ? () {} : () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
