import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

import '../widgets/fish_glass.dart';
import 'package:image_picker/image_picker.dart';

/// 编辑资料 —— **方案 G 视觉重构**（负责人定案：原页面"太丑"，结构重排 + 删注释型小字）
///
/// ## 逻辑零改动（本轮硬约束）
/// 两条资料接口、请求体字段名、成功后的 `fetchMe()` 与提示文案**逐字未改**：
/// - 昵称：`PUT /user/profile { nickname }` → `fetchMe()` → 「昵称已更新」
/// - 展示 ID：`POST /user/profile/uid { uid }` → `fetchMe()` → 「ID 已修改（24 小时内最多 3 次）」
/// - 头像：`uploadMedia(type: 'avatar')` → `PUT /user/profile { avatarMediaId }`
/// - 背景：`uploadMedia(type: 'bg')` → `PUT /user/profile { backgroundMediaId }`
/// 换头像链路（`ImagePicker` 640/80 压缩 → 真实进度 → 中文失败 + 「重新上传」不重新选图）
/// **一段没动**，本轮只改了角标的画法（30dp 白描边 → 22dp 主色圆）。
///
/// ## 现状字段与分组（改版前就这 4 项，无性别、无签名/简介、无「退出登录」入口）
/// | 字段 | 上限/限制 | 新分组 |
/// |---|---|---|
/// | 头像 | 640/80 压缩上传 | ① 顶部头像块（点击 + 相机角标 = 唯一入口，不重复出现第二次） |
/// | 昵称 | 32 字 | ② 卡 1「资料」 |
/// | 展示 ID | 20 字 · **24 小时内最多改 3 次** | ② 卡 1「资料」 |
/// | 个人背景 | 1600/72 压缩上传 | ③ 卡 2「图片」（动作行） |
///
/// ## 新版面骨架（自上而下）
/// ① 头像 72dp **圆形** + 右下 22dp 主色圆形「相机」角标（圆角取「胶囊」，不新增 20dp 档）；
/// ② 卡 1「资料」：昵称行 + 展示 ID 行（行高 52 / 左右 16 / 左标签定宽 72 / 行间发丝线）；
/// ③ 卡 2「图片」：个人背景动作行（右侧值 + chevron）；
/// ④ 底部固定「保存」：主色实底 + 白字 + 高 48 + 圆角 12 + 离底 16 安全区。
///
/// ## 注释型浅色小字已全删（负责人已多次要求）
/// 原三处 `helperText`（「1-32 字」「2-20 位中文/字母/数字/下划线」
/// 「其他用户通过此 ID 搜索你；24 小时内最多修改 3 次」）**不再渲染**。
/// **功能性限制保留**，但只作为该行右侧 11px 弱色读数：
/// `24h 限 3 次`（ID 的真实限制，服务端 `UID_CHANGE_LIMIT=3/24h`）与 `N/32`、`N/20` 字数计数
/// （满额转警示色 [AppColors.warning]）。
///
/// 视觉口径（方案 G）：页底 [AppColors.bgPageG] `#F6F7F9`、卡片白底 + 1px
/// [AppColors.strokeSoft] `#E8ECF2` 描边 + 圆角 12 + **零阴影**、零渐变、
/// 颜色一律走 token、图标一律 `AppIcon`（无 emoji）、间距落 4dp 网格。
class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key, this.debugOnUploadProgress});

  /// **测试/出图注入**：额外转发一次上传进度。
  ///
  /// 为什么需要它：真实上传的进度由 Dio 在请求体流上驱动，而请求体是**一口气推完**的
  /// （哪怕 260KB 也只在一帧内），所以"上传中 55%"这种中间帧在 widget 测试里根本抓不到。
  /// 这个钩子让出图/断言能把界面停在任意进度档位，而不必伪造一条假的进度链路。
  /// 生产恒为 null（默认不传）。
  @visibleForTesting
  final void Function(MediaUploadProgress progress)? debugOnUploadProgress;

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  /// 方案 G 页底（`#F6F7F9`）—— 与「我的」页同源 token，不新增色值
  static const Color _pageBg = AppColors.bgPageG;

  /// 卡片圆角（方案 G 定案：卡片与主按钮都是 12，与「我的」页 `_cardRadius` 同源）
  static const double _cardRadius = 12;

  /// 行高（方案 G 定案：52）
  static const double _rowHeight = 52;

  /// 左标签定宽（方案 G 定案：72），保证两行标签左缘与右侧输入起点都对齐
  static const double _labelWidth = 72;

  /// 行左右内边距（方案 G 定案：16）
  static const double _rowPadding = 16;

  /// 昵称长度上限（与 `TextField.maxLength` 同一个常量，计数与截断不会各说各话）
  static const int _nicknameMax = 32;

  /// 展示 ID 长度上限（同上）
  static const int _uidMax = 20;

  /// 展示 ID 的真实限制（服务端 `UID_CHANGE_LIMIT`：滚动 24 小时最多 3 次）
  ///
  /// 只作为该行右侧 11px 弱色提示读出来，不写整段说明（注释型小字已按负责人要求删除）。
  static const String _uidQuotaHint = '24h 限 3 次';

  final ApiClient _api = ApiClient();
  final TextEditingController _nickname = TextEditingController();
  final TextEditingController _uid = TextEditingController();
  bool _saving = false;
  bool _changingUid = false;
  bool _uploading = false;

  /// 头像/背景的上传进度与错误（两个各自独立 —— 一个失败不该清掉另一个的读数）
  final MediaUploadState _avatarUp = MediaUploadState();
  final MediaUploadState _bgUp = MediaUploadState();

  /// 上一次选中的图片（失败后「重试」用：**不重新选图**，直接重传同一份字节）
  Uint8List? _lastAvatarBytes;
  String? _lastAvatarName;
  Uint8List? _lastBgBytes;
  String? _lastBgName;

  /// 表单错误（昵称/展示 ID 行内红字，字段名与服务端 DTO 对齐）
  final FormErrors _errs = FormErrors();

  @override
  void initState() {
    super.initState();
    // 慢网提示要在"长时间没有进度回调"时也能上屏（见 MediaUploadState 的说明）
    _avatarUp.onTick = _rebuild;
    _bgUp.onTick = _rebuild;
    final me = AuthStore.instance.me;
    _nickname.text = me?.nickname ?? '';
    _uid.text = me?.uid ?? '';
    // 字数计数与「保存」可用态随输入实时更新（行右侧 `N/32` 是 11px 弱色读数）
    _nickname.addListener(_rebuild);
    _uid.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _avatarUp.dispose();
    _bgUp.dispose();
    _nickname.dispose();
    _uid.dispose();
    super.dispose();
  }

  /// 昵称是否改动过（未改动就不发请求，也不弹「昵称已更新」打扰用户）
  bool _nicknameDirty(AuthMe? me) => _nickname.text.trim() != (me?.nickname ?? '');

  /// 展示 ID 是否改动过（空值不算改动 —— 由服务端/行内校验拦）
  bool _uidDirty(AuthMe? me) {
    final String uid = _uid.text.trim();
    return uid.isNotEmpty && uid != (me?.uid ?? '');
  }

  /// 底部「保存」：**只提交真正改动过的字段**（触发方式变了，调用链一个字节没改）
  ///
  /// 两个字段**各自独立提交**（与改版前「保存昵称」「修改 ID」两个按钮互不影响完全一致）：
  /// 昵称失败不会连带拦住 ID 的提交；两边的失败都落到各自的行内红字（[AppFieldError]），
  /// 不弹打断式浮层。没改动就一句 info 提示，不发任何请求。
  Future<void> _onSave() async {
    if (_saving || _changingUid) return;
    final me = AuthStore.instance.me;
    final bool nicknameDirty = _nicknameDirty(me);
    final bool uidDirty = _uidDirty(me);
    if (!nicknameDirty && !uidDirty) {
      AppToast.info(context, '资料没有改动');
      return;
    }
    // 每次提交前清掉上一轮的字段红字（改对之后再提交不该还挂着旧错）
    setState(() => _errs.clear());
    if (nicknameDirty) await _saveNickname();
    if (uidDirty) await _changeUid();
  }

  /// 昵称（`PUT /user/profile`，路径/请求体/成功后的刷新与提示与改版前逐字相同）
  Future<void> _saveNickname() async {
    final name = _nickname.text.trim();
    if (name.isEmpty) {
      // 行内红字（昵称行下方），不弹系统默认黑色浮条
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
      // 服务端 fields[] → 昵称行下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.bindApiException(e, aliases: const {'nickname': 'nickname'})) {
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 展示 ID（`POST /user/profile/uid`，路径/请求体/成功后的刷新与提示与改版前逐字相同）
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

  /// 选头像（**不压缩**：2026-10-18「支持动态」—— `imageQuality` 会把 GIF 转成 JPEG，动画丢失；非 GIF 由服务端 sharp 缩到 1920px + q85）
  /// 上传前校验：是不是图片 + 是不是真的动图（2026-10-18）
  ///
  /// 两个必须挡的情况：
  /// 1. `pickMedia` 允许选视频 → 不是四种图片魔数就退回，并说清原因；
  /// 2. **文件名是 .gif 但字节不是 GIF** —— 相册/系统组件把动图转码成了静态图。
  ///    不提示的话，用户会以为"我传了动图"，然后到页面里发现不动，无从排查。
  ///    （线上真出现过：背景存成了 image/jpeg，而头像是 image/gif，同一次会话同一个 App。）
  bool _acceptImage(Uint8List bytes, String name, String label) {
    final kind = sniffImageKind(bytes);
    if (kind == null) {
      AppToast.error(context, '$label只支持 GIF / PNG / JPEG / WebP 图片');
      return false;
    }
    if (looksLikeGifName(name) && kind != ImageKind.gif) {
      AppToast.error(
        context,
        '$label选的是动图，但系统已把它转成${kind.label}。'
        '请用「文件」而不是相册重新选择原始 GIF',
      );
      return false;
    }
    return true;
  }

  Future<void> _uploadAvatar() async {
    final picked = await ImagePicker().pickMedia();
    if (picked == null) return;
    final bytes = Uint8List.fromList(await picked.readAsBytes());
    if (!_acceptImage(bytes, picked.name, '头像')) return;
    _lastAvatarBytes = bytes;
    _lastAvatarName = picked.name;
    await _doUploadAvatar(bytes, picked.name);
  }

  /// 真正上传头像（选图与「重试」共用同一条路径 —— 重试不重新选图）
  Future<void> _doUploadAvatar(Uint8List bytes, String name) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      if (mounted) setState(() => _avatarUp.fail('登录已过期，请重新登录后再上传'));
      return;
    }
    setState(() {
      _uploading = true;
      _avatarUp.begin();
    });
    try {
      final up = await uploadMedia(
        type: 'avatar',
        bytes: bytes,
        filename: name,
        token: token,
        onProgress: (p) {
          if (mounted) setState(() => _avatarUp.update(p));
          widget.debugOnUploadProgress?.call(p);
        },
      );
      await _api.request('PUT', '/user/profile', token: token, data: {'avatarMediaId': up.id});
      await AuthStore.instance.fetchMe();
      if (!mounted) return;
      setState(() => _avatarUp.succeed());
      AppToast.success(context, '头像已更新');
    } catch (e) {
      // 中文可上屏提示（连不上/超时/服务端拒绝 各有说法），并保留「重试」入口
      if (mounted) setState(() => _avatarUp.fail(mediaUploadErrorMessage(e)));
      debugPrint('头像上传失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 选背景（**不压缩**：同上，`imageQuality` 会杀掉 GIF 动画；服务端 sharp 会对非 GIF 做等比缩放）
  Future<void> _uploadBackground() async {
    // 图片（含 GIF）与 mp4 都收（2026-10-21「实况背景」）
    final picked = await ImagePicker().pickMedia();
    if (picked == null) return;
    final bytes = Uint8List.fromList(await picked.readAsBytes());
    // 视频：只有 mp4 能过（服务端 sniffType 也只放行 mp4）
    final asVideo = looksLikeMp4(bytes);
    if (!asVideo && !_acceptImage(bytes, picked.name, '主页背景')) return;
    if (asVideo && bytes.length > 30 * 1024 * 1024) {
      if (mounted) AppToast.error(context, '视频背景需小于 30MB');
      return;
    }
    _lastBgBytes = bytes;
    _lastBgName = picked.name;
    await _doUploadBackground(bytes, picked.name, isVideo: asVideo);
    }

  /// 真正上传背景（图片走 bg、视频走 bg_video；两者写同一个 backgroundMediaId）
  Future<void> _doUploadBackground(
    Uint8List bytes,
    String name, {
    bool isVideo = false,
  }) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      if (mounted) setState(() => _bgUp.fail('登录已过期，请重新登录后再上传'));
      return;
    }
    setState(() {
      _uploading = true;
      _bgUp.begin();
    });
    try {
      final up = await uploadMedia(
        // 视频背景走独立用途（2026-10-21）：`bg` 在服务端只收图片、`bg_video` 只收 mp4。
        // 靠魔数分流而不是靠文件名 —— 用户从"动态照片"里导出的 mp4 常常没有正经扩展名。
        type: isVideo ? 'bg_video' : 'bg',
        bytes: bytes,
        filename: name,
        token: token,
        onProgress: (p) {
          if (mounted) setState(() => _bgUp.update(p));
          widget.debugOnUploadProgress?.call(p);
        },
      );
      await _api.request('PUT', '/user/profile', token: token, data: {'backgroundMediaId': up.id});
      await AuthStore.instance.fetchMe();
      if (!mounted) return;
      setState(() => _bgUp.succeed());
      AppToast.success(context, '背景已更新');
    } catch (e) {
      if (mounted) setState(() => _bgUp.fail(mediaUploadErrorMessage(e)));
      debugPrint('背景上传失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// **测试/出图**：把背景上传进度定格到某一档（`fraction` 0–1）。
  ///
  /// 为什么需要它：真实进度由 Dio 在请求体流上驱动，而请求体是**一口气推完**的
  /// （哪怕 260KB 也只在一帧内走完）→ "上传中 55%"这种中间帧在 widget 测试里抓不到。
  /// 有了它，出图/断言能把界面停在任意进度档位（**不伪造上传链路** —— 上传本身照旧走真实现）。
  /// 生产代码不会调用它。
  @visibleForTesting
  void debugSetUploadProgress(double fraction, {bool slow = false}) {
    final MediaUploadState s = _bgUp;
    if (!s.uploading) return;
    const int total = 1000;
    s.update(MediaUploadProgress(
      sent: (total * fraction).round(),
      total: total,
      elapsed: const Duration(milliseconds: 900),
      speedBytesPerSecond: total * fraction / 0.9,
    ));
    if (slow) s.slow = true;
    setState(() {});
  }

  /// **测试/出图**：当前背景上传状态（只读，供断言）
  @visibleForTesting
  MediaUploadState get debugBackgroundUpload => _bgUp;

  @override
  Widget build(BuildContext context) {
    final me = AuthStore.instance.me;
    return FishGlassPage(
      title: '编辑资料',
      body: ColoredBox(
        // 方案 G：纯白卡片浮在微灰底上，卡片轮廓才看得出来
        color: _pageBg,
        child: AnimatedBuilder(
          animation: AuthStore.instance,
          builder: (context, _) => Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.xl,
                  ),
                  children: [
                    // ① 头像块（点击 + 相机角标 = 换头像的唯一入口）
                    _buildAvatarBlock(me),
                    // 头像上传的进度/失败重试（空闲时完全不占位）
                    MediaUploadTile(
                      state: _avatarUp,
                      key: const Key('avatar-upload-tile'),
                      label: '头像',
                      onRetry: (_lastAvatarBytes == null || _uploading)
                          ? null
                          : () => _doUploadAvatar(_lastAvatarBytes!, _lastAvatarName ?? 'avatar.jpg'),
                    ),
                    const SizedBox(height: 20),
                    // ② 卡 1「资料」：昵称 + 展示 ID（两个可编辑文本字段同组）
                    _buildCard(children: [
                      _buildFieldRow(
                        label: '昵称',
                        controller: _nickname,
                        maxLength: _nicknameMax,
                        hint: '填写昵称',
                        field: 'nickname',
                      ),
                      const AppHairline(indent: _rowPadding, endIndent: _rowPadding),
                      _buildFieldRow(
                        label: '展示 ID',
                        controller: _uid,
                        maxLength: _uidMax,
                        hint: '中文/字母/数字/下划线',
                        field: 'uid',
                        // 真实限制（24h 最多 3 次）只作为该行右侧 11px 弱色提示
                        trailingHint: _uidQuotaHint,
                      ),
                    ]),
                    const SizedBox(height: AppSpacing.lg),
                    // ③ 卡 2「图片」：个人背景（动作行；文案与改版前逐字相同）
                    _buildCard(children: [_buildBackgroundRow()]),
                    // 背景上传的进度/失败重试
                    MediaUploadTile(
                      state: _bgUp,
                      key: const Key('bg-upload-tile'),
                      label: '背景',
                      onRetry: (_lastBgBytes == null || _uploading)
                          ? null
                          : () => _doUploadBackground(_lastBgBytes!, _lastBgName ?? 'bg.jpg'),
                    ),
                  ],
                ),
              ),
              // ④ 底部固定「保存」（不在列表里滚动，键盘弹起也贴底）
              _buildSaveBar(),
            ],
          ),
        ),
      ),
    );
  }

  // =====================================================================================
  // ① 头像块：72dp 圆形 + 右下 22dp 主色圆形相机角标
  // =====================================================================================

  Widget _buildAvatarBlock(AuthMe? me) {
    return Center(
      child: SizedBox(
        width: 72,
        height: 72,
        child: Stack(
          // 角标压在头像右下角，不外扩 → 头像块整体仍占 72×72
          clipBehavior: Clip.none,
          children: [
            // 圆形（不新增 20dp 圆角档：`AppAvatar.square` 的 size*0.34 = 24.5 反而越格）
            AppAvatar(nickname: me?.nickname ?? '', mediaId: me?.avatarMediaId, size: 72, allowAnimation: true),
            Positioned(
              right: 0,
              bottom: 0,
              child: Semantics(
                label: '更换头像',
                button: true,
                child: GestureDetector(
                  // 点击 = 现有换头像流程（`_uploadAvatar` 一段未改）
                  onTap: _uploading ? null : _uploadAvatar,
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    child: _uploading
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                          )
                        : const AppIcon.of(AppIconsLegacy.camera_alt, size: 12, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================================================
  // ②/③ 卡片与行
  // =====================================================================================

  /// 方案 G 卡片：白底 + 1px [AppColors.strokeSoft] 描边 + 圆角 12（**零阴影**）
  ///
  /// 行自己带 16 的左右内边距（这样发丝线能横贯整行、标签左缘与卡片内边距对齐），
  /// 所以卡片本身不带 padding。
  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: AppColors.strokeSoft),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius),
        child: Column(
          // 行撑满卡片宽度（否则 Row 会按内容宽度居中）
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  /// 可编辑字段行：左标签（13px 定宽 72）+ 输入（14px）+ 右侧字数计数（11px）
  ///
  /// 行本体固定 [_rowHeight]；校验失败的红字挂在行**下方**（不撑高 52 的行，
  /// 结构变化时行高口径不受影响）。
  Widget _buildFieldRow({
    required String label,
    required TextEditingController controller,
    required int maxLength,
    required String hint,
    required String field,
    String? trailingHint,
  }) {
    final int length = controller.text.characters.length;
    final bool full = length >= maxLength;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _rowPadding),
            child: Row(
              children: [
                SizedBox(
                  width: _labelWidth,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    maxLength: maxLength,
                    style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      // Material 自带的那行 `0/32` 计数关掉：计数改为行右侧自绘（11px 弱色）
                      counterText: '',
                      contentPadding: EdgeInsets.zero,
                      hintText: hint,
                      hintStyle: const TextStyle(fontSize: 14, color: AppColors.textPlaceholder),
                    ),
                    onChanged: (_) {
                      // 用户改了就先撤掉该字段的行内红字（与改版前昵称一致）
                      if (_errs.errorOf(field) != null) setState(() => _errs.clearField(field));
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // 字数计数：右对齐 11px 弱色，满额转警示色
                Text(
                  '$length/$maxLength',
                  style: TextStyle(
                    fontSize: 11,
                    color: full ? AppColors.warning : AppColors.mutedText,
                  ),
                ),
                if (trailingHint != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    trailingHint,
                    style: const TextStyle(fontSize: 11, color: AppColors.mutedText),
                  ),
                ],
              ],
            ),
          ),
        ),
        // 校验失败：行内 11px 警示色（字段下方 2dp），不弹 Toast 打断
        AppFieldError(
          _errs,
          field,
          padding: const EdgeInsets.fromLTRB(_rowPadding, 2, _rowPadding, AppSpacing.sm),
        ),
      ],
    );
  }

  /// 动作行：左标签 + 右侧值 + chevron（整行可点）
  ///
  /// 文案 `更换个人背景` 与改版前**逐字相同**（既有用例按这句文字点击，断言一条没放宽）。
  Widget _buildBackgroundRow() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _uploading ? null : _uploadBackground,
        child: SizedBox(
          height: _rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _rowPadding),
            child: Row(
              children: [
                const SizedBox(
                  width: _labelWidth,
                  child: Text(
                    '个人背景',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
                const Expanded(
                  child: Text(
                    '更换个人背景',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                AppIcon.of(AppIcon.chevronRight, size: 16, color: AppColors.textPlaceholder),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // =====================================================================================
  // ④ 底部固定保存按钮
  // =====================================================================================

  /// 保存中：按钮进 loading（禁用 + 白字转浅），**不做全屏转圈**
  Widget _buildSaveBar() {
    final bool busy = _saving || _changingUid;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgCard,
        // 与滚动内容分界的发丝线（卡片内行间线同源：T.divider）
        border: Border(top: BorderSide(color: T.divider)),
      ),
      child: SafeArea(
        top: false,
        // 离底 16 安全区（+ 顶部 12 让按钮与发丝线不贴死）
        minimum: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
        child: SizedBox(
          height: 48,
          child: Material(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(_cardRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: busy ? null : _onSave,
              child: Center(
                child: busy
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            '保存中',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        '保存',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
