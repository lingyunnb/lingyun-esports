import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 编辑资料（负责人需求 #17/#18）：改昵称/改 ID（中文支持，后端校验+限频）/上传头像/上传背景（真实上传后端）
class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final ApiClient _api = ApiClient();
  final TextEditingController _nickname = TextEditingController();
  final TextEditingController _uid = TextEditingController();
  bool _saving = false;
  bool _changingUid = false;
  bool _uploading = false;

  /// 表单错误（昵称/展示 ID 行内红字，字段名与服务端 DTO 对齐）
  final FormErrors _errs = FormErrors();

  @override
  void initState() {
    super.initState();
    final me = AuthStore.instance.me;
    _nickname.text = me?.nickname ?? '';
    _uid.text = me?.uid ?? '';
  }

  @override
  void dispose() {
    _nickname.dispose();
    _uid.dispose();
    super.dispose();
  }

  Future<void> _saveNickname() async {
    final name = _nickname.text.trim();
    if (name.isEmpty) {
      // 行内红字（昵称输入框下方），不再弹系统默认黑色浮条
      setState(() => _errs.set('nickname', '昵称不能为空'));
      return;
    }
    setState(() => _saving = true);
    try {
      await _api.request('PUT', '/user/profile', token: AuthStore.instance.accessToken, data: {'nickname': name});
      await AuthStore.instance.fetchMe();
      if (mounted) AppToast.success(context, '昵称已更新');
    } on ApiException catch (e) {
      if (!mounted) return;
      // 服务端 fields[] → 昵称输入框下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.bindApiException(e, aliases: const {'nickname': 'nickname'})) {
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeUid() async {
    final uid = _uid.text.trim();
    if (uid.isEmpty || uid == AuthStore.instance.me?.uid) return;
    setState(() => _changingUid = true);
    try {
      await _api.request('POST', '/user/profile/uid', token: AuthStore.instance.accessToken, data: {'uid': uid});
      await AuthStore.instance.fetchMe();
      if (mounted) AppToast.success(context, 'ID 已修改（24 小时内最多 3 次）');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!_errs.bindApiException(e, aliases: const {'uid': 'uid'})) {
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _changingUid = false);
    }
  }

  Future<void> _uploadAvatar() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
      if (picked == null) return;
      setState(() => _uploading = true);
      final token = AuthStore.instance.accessToken;
      if (token == null) return;
      final up = await uploadMedia(type: 'avatar', bytes: Uint8List.fromList(await picked.readAsBytes()), filename: picked.name, token: token);
      await _api.request('PUT', '/user/profile', token: token, data: {'avatarMediaId': up.id});
      await AuthStore.instance.fetchMe();
      if (mounted) AppToast.success(context, '头像已更新');
    } catch (e) {
      // 不再把异常原文（英文类名/堆栈）吐给用户
      if (mounted) AppToast.error(context, '头像更新失败，请重试');
      debugPrint('头像上传失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _uploadBackground() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2000, imageQuality: 80);
      if (picked == null) return;
      setState(() => _uploading = true);
      final token = AuthStore.instance.accessToken;
      if (token == null) return;
      final up = await uploadMedia(type: 'bg', bytes: Uint8List.fromList(await picked.readAsBytes()), filename: picked.name, token: token);
      await _api.request('PUT', '/user/profile', token: token, data: {'backgroundMediaId': up.id});
      await AuthStore.instance.fetchMe();
      if (mounted) AppToast.success(context, '背景已更新');
    } catch (e) {
      if (mounted) AppToast.error(context, '背景更新失败，请重试');
      debugPrint('背景上传失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthStore.instance.me;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑资料')),
      body: AnimatedBuilder(
        animation: AuthStore.instance,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // 头像 + 背景
            Center(
              child: Column(
                children: [
                  Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      AppAvatar(nickname: me?.nickname ?? '', mediaId: me?.avatarMediaId, size: 88),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: GestureDetector(
                          onTap: _uploading ? null : _uploadAvatar,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(color: AppColors.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                            child: _uploading
                                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.camera_alt, size: 14, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextButton.icon(
                    onPressed: _uploading ? null : _uploadBackground,
                    icon: const Icon(Icons.image_outlined, size: 16),
                    label: const Text('更换个人背景'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            // 昵称
            TextField(
              controller: _nickname,
              maxLength: 32,
              onChanged: (_) {
                if (_errs.errorOf('nickname') != null) setState(() => _errs.clearField('nickname'));
              },
              decoration: const InputDecoration(labelText: '昵称', hintText: '1-32 字', border: OutlineInputBorder()),
            ),
            AppFieldError(_errs, 'nickname', padding: const EdgeInsets.only(top: 2, left: 2)),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(onPressed: _saving ? null : _saveNickname, child: const Text('保存昵称')),
            const SizedBox(height: AppSpacing.xl),
            // ID（中文/数字/英文）
            TextField(
              controller: _uid,
              maxLength: 20,
              onChanged: (_) {
                if (_errs.errorOf('uid') != null) setState(() => _errs.clearField('uid'));
              },
              decoration: const InputDecoration(
                labelText: '展示 ID',
                hintText: '2-20 位中文/字母/数字/下划线',
                helperText: '其他用户通过此 ID 搜索你；24 小时内最多修改 3 次',
                border: OutlineInputBorder(),
              ),
            ),
            AppFieldError(_errs, 'uid', padding: const EdgeInsets.only(top: 2, left: 2)),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.tonal(onPressed: _changingUid ? null : _changeUid, child: const Text('修改 ID')),
          ],
        ),
      ),
    );
  }
}
