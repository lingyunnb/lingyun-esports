import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';

/// 意见反馈：文字提交到后台，管理端可见处理
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final ApiClient _api = ApiClient();
  final TextEditingController _content = TextEditingController();
  final TextEditingController _contact = TextEditingController();
  bool _busy = false;

  /// 表单错误（内容行内红字 + 按钮上方汇总条）
  final FormErrors _errs = FormErrors();

  @override
  void dispose() {
    _content.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _content.text.trim();
    if (text.isEmpty) {
      // 行内红字（反馈内容输入框下方），不再弹系统默认黑色浮条
      setState(() => _errs.set('content', '请填写反馈内容'));
      return;
    }
    setState(() => _busy = true);
    try {
      await _api.request('POST', '/user/feedback', token: AuthStore.instance.accessToken, data: {
        'content': text,
        'contact': _contact.text.trim(),
      });
      if (!mounted) return;
      AppToast.success(context, '感谢你的反馈，我们会尽快处理');
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 服务端 fields[] → 内容输入框下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.bindApiException(e, aliases: const {'content': 'content', 'contact': 'contact'})) {
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
    return FishGlassPage(
      title: '意见反馈',
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppSpacing.md)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _content,
                  maxLines: 6,
                  maxLength: 1000,
                  onChanged: (_) {
                    if (_errs.errorOf('content') != null) setState(() => _errs.clearField('content'));
                  },
                  decoration: const InputDecoration(
                    hintText: '告诉我们你的建议或遇到的问题…',
                    border: InputBorder.none,
                  ),
                ),
                AppFieldError(_errs, 'content', padding: const EdgeInsets.only(top: 2, left: 2)),
                const Divider(height: 1),
                TextField(
                  controller: _contact,
                  decoration: const InputDecoration(
                    hintText: '联系方式（选填）',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          // 汇总提示（按钮上方）
          AppFormErrorSummary(_errs),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('提交反馈'),
          ),
        ],
      ),
    );
  }
}
