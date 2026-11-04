import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/media_uploader.dart';
import '../auth/auth_store.dart';
import '../identity/identity_widgets.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/theme_colors.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_page_bg.dart';
import '../widgets/app_toast.dart';
import '../widgets/app_ui.dart';
import '../widgets/cached_image.dart';
import '../widgets/media_upload_tile.dart';
import 'withdraw_media.dart';
import 'withdraw_models.dart';

/// ============================================================================
/// 打手态 · **收款信息**（绑定 / 换绑）
///   `GET /worker/withdraw/account` · `POST /worker/withdraw/account`
/// ============================================================================
///
/// 表单四项（顺序就是填写的自然顺序）：
/// 1. **姓名**（收款人真实姓名，2–20 字）；
/// 2. **电话**（11 位手机号，本地校验 `1\d{10}`）；
/// 3. **微信号**（6–20 位、字母开头）；
/// 4. **微信收款码**（本地上传，媒体用途 `withdraw_qr`）。
///
/// ## 校验分层（**两层，缺一不可**）
/// - **本地**：格式/必填 —— 用户不必为了一个错别字等一次网络往返；
/// - **服务端**：中文错误**原样透传**（如"手机号已被其它账号绑定"），客户端不改字、不猜测。
///
/// ## 换绑（[rebind] = true）必须把话说清
/// [WorkerWithdrawCopy.rebindNotice]「换绑后新收款信息用于后续打款，正在处理中的提现仍按原信息打款」
/// —— 打款是人工操作，正在处理中的那一笔已经拿着旧信息在走了；不写这句，
/// 用户会以为换绑能把在途的那笔也改道（那是做不到的，会造成"我明明改了收款码"的纠纷）。
class WorkerWithdrawAccountPage extends StatefulWidget {
  const WorkerWithdrawAccountPage({
    super.key,
    this.api,
    this.account,
    this.rebind = false,
    this.picker,
    this.uploader,
    this.onSaved,
  });

  final ApiClient? api;

  /// 已绑定的收款信息（已绑定 → 带 `account` 进来时预填脱敏值，只改用户动了的那几格）
  final WorkerWithdrawAccount? account;

  /// true = 换绑（页面标题与提示语不同、成功文案不同）
  final bool rebind;

  /// 选图注入（测试用；不传 → [WithdrawMedia.pickImage]）
  final Future<PickedWithdrawImage?> Function()? picker;

  /// 上传注入（测试用；不传 → 既有媒体上传链路 `uploadMedia`）
  final Future<MediaUploadResult> Function({
    required String type,
    required List<int> bytes,
    required String filename,
    required String token,
  })? uploader;

  /// 保存成功回调（宿主据此刷新绑定状态；参数 = 服务端回带的最新收款信息）
  final ValueChanged<WorkerWithdrawAccount>? onSaved;

  /// 页头标题（测试与页面同源）
  static String titleOf({required bool rebind}) => rebind ? '换绑收款信息' : WorkerWithdrawCopy.bindTitle;

  /// 收款码上传位的 key（测试/出图定位）
  static const Key qrTileKey = Key('withdraw-qr-tile');

  @override
  State<WorkerWithdrawAccountPage> createState() => _WorkerWithdrawAccountPageState();
}

class _WorkerWithdrawAccountPageState extends State<WorkerWithdrawAccountPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  late final TextEditingController _name = TextEditingController(text: widget.account?.realName ?? '');
  late final TextEditingController _phone = TextEditingController(text: widget.account?.phone ?? '');
  late final TextEditingController _wechat = TextEditingController(text: widget.account?.wechatId ?? '');

  /// 已上传的收款码 mediaId（null = 还没有可提交的图）
  String? _qrMediaId;

  /// 本地预览（选完立即可见，不等上传）
  PickedWithdrawImage? _picked;

  final MediaUploadState _up = MediaUploadState();

  bool _uploading = false;
  String? _qrError;
  bool _saving = false;

  /// 表单级错误（本地校验或**服务端中文原文**）
  String? _formError;

  @override
  void initState() {
    super.initState();
    _up.onTick = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _up.dispose();
    _name.dispose();
    _phone.dispose();
    _wechat.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 收款码：选图 → 裁剪（宿主实现）→ 上传（既有媒体链路）
  // ---------------------------------------------------------------------------

  Future<void> _pickQr() async {
    if (_uploading) return;
    final picked = await WithdrawMedia.pick(injected: widget.picker);
    if (picked == null || !mounted) {
      // 没接选图能力 → 说清原因（不静默、不假装在传）
      if (mounted && !WithdrawMedia.available && widget.picker == null) {
        AppToast.info(context, WithdrawMedia.unavailableMessage);
      }
      return;
    }    if (picked.byteLength > WithdrawMedia.maxBytes) {
      setState(() => _qrError = '图片太大（${picked.sizeLabel}），请换一张 10MB 以内的图');
      return;
    }
    setState(() {
      _picked = picked;
      _qrMediaId = null;
      _qrError = null;
      _uploading = true;
      _formError = null;
      _up.begin();
    });
    await _doUpload(picked);
  }

  /// 上传失败后「重新上传」：**不重新选图**，直接重传同一份字节
  Future<void> _retryUpload() async {
    final picked = _picked;
    if (picked == null || _uploading) return;
    setState(() {
      _qrError = null;
      _uploading = true;
      _up.begin();
    });
    await _doUpload(picked);
  }

  Future<void> _doUpload(PickedWithdrawImage picked) async {
    final token = AuthStore.instance.activeToken;
    if (token == null) {
      if (!mounted) return;
      const msg = '登录已过期，请重新登录后再上传';
      setState(() {
        _uploading = false;
        _qrError = msg;
        _up.fail(msg);
      });
      return;
    }
    try {
      final up = await _upload(picked, token);
      if (!mounted) return;
      setState(() {
        _qrMediaId = up.id;
        _uploading = false;
        _up.succeed();
      });
    } catch (e) {
      if (!mounted) return;
      final msg = mediaUploadErrorMessage(e);
      setState(() {
        _uploading = false;
        _qrError = msg;
        _up.fail(msg);
      });
    }
  }

  Future<MediaUploadResult> _upload(PickedWithdrawImage picked, String token) {
    final injected = widget.uploader;
    if (injected != null) {
      return injected(
        type: WithdrawMedia.qrType,
        bytes: picked.bytes,
        filename: picked.name,
        token: token,
      );
    }
    return uploadMedia(
      type: WithdrawMedia.qrType,
      bytes: picked.bytes,
      filename: picked.name,
      token: token,
      onProgress: (p) {
        if (mounted) setState(() => _up.update(p));
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 保存
  // ---------------------------------------------------------------------------

  Future<void> _save() async {
    if (_saving) return;
    // 已绑定的账号进来换绑时，脱敏值（张*山 / 138****8888）**不能**当新值提交：
    // 服务端会把 `*` 原样存进去，下一笔打款就打到"张*山"这个名字上。
    if (widget.rebind && !_nameTouched) {
      setState(() => _formError = '请重新填写完整姓名（当前显示的是脱敏值）');
      return;
    }
    if (widget.rebind && !_phoneTouched) {
      setState(() => _formError = '请重新填写完整手机号（当前显示的是脱敏值）');
      return;
    }
    final localError = WorkerWithdrawRules.validateAccountForm(
      realName: _name.text,
      phone: _phone.text,
      wechatId: _wechat.text,
      hasQr: _qrMediaId != null,
    );
    if (localError != null) {
      setState(() => _formError = localError);
      return;
    }
    final token = AuthStore.instance.activeToken;
    if (token == null) {
      setState(() => _formError = '登录已过期，请重新登录后再试');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      final resp = await _api.request(
        'POST',
        '/worker/withdraw/account',
        token: token,
        data: {
          'realName': _name.text.trim(),
          'phone': _phone.text.trim(),
          'wechatId': _wechat.text.trim(),
          'qrMediaId': _qrMediaId,
        },
      );
      if (!mounted) return;
      final data = resp['data'];
      // 服务端回带的收款信息优先（它才是权威的脱敏/换绑结果）；没回带就用本地值兜一次
      final saved = data is Map && data.isNotEmpty
          ? WorkerWithdrawAccount.fromJson({
              ...data.cast<String, dynamic>(),
              // 服务端偶尔只回 `{ok:true}`：这时把本次提交的内容当作已保存事实
              if (data['realName'] == null) 'realName': _maskName(_name.text.trim()),
              if (data['phone'] == null) 'phone': _maskPhone(_phone.text.trim()),
              if (data['wechatId'] == null) 'wechatId': _wechat.text.trim(),
              if (data['bound'] == null) 'bound': true,
            })
          : WorkerWithdrawAccount(
              bound: true,
              realName: _maskName(_name.text.trim()),
              phone: _maskPhone(_phone.text.trim()),
              wechatId: _wechat.text.trim(),
              qrUrl: '',
              updatedAt: DateTime.now(),
            );
      setState(() => _saving = false);
      AppToast.success(context, widget.rebind ? WorkerWithdrawCopy.rebound : WorkerWithdrawCopy.bound);
      widget.onSaved?.call(saved);
      Navigator.of(context).maybePop(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      // 服务端中文原文**原样展示**（不改写、不吞掉）
      setState(() {
        _saving = false;
        _formError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = '保存失败：$e';
      });
    }
  }

  /// 用户是否真的动过姓名/电话（换绑时防"脱敏值原样提交"）
  bool _nameTouched = false;
  bool _phoneTouched = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 页底铺白 + 极浅品牌蓝渐变（负责人 2026-10-17）：Scaffold 让位成透明，底色由 `AppPageBg` 画。
      // 页头、表单卡、收款码块一律实色 —— 它们浮在渐变上，自身一句未改。
      backgroundColor: Colors.transparent,
      body: AppPageBg(child: Column(
        children: [
          IdentityWorkerPageHeader(
            title: WorkerWithdrawAccountPage.titleOf(rebind: widget.rebind),
            actions: [
              IdentityWorkerHeaderButton(
                icon: AppIdentityIcons.close,
                tooltip: '返回',
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 24),
              children: [
                if (widget.rebind) _rebindNotice(),
                if (!widget.rebind) _intro(),
                const SizedBox(height: 12),
                _formCard(),
                if (_formError != null) ...[
                  const SizedBox(height: 12),
                  _errorCard(_formError!),
                ],
                const SizedBox(height: 16),
                AppIdentityPrimaryButton(
                  label: _saving ? '保存中…' : '保存收款信息',
                  busy: _saving,
                  onPressed: _saving ? null : _save,
                ),
                const SizedBox(height: 9),
                AppIdentityOutlineButton(
                  label: '取消',
                  height: 40,
                  expand: true,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ],
      )),
    );
  }

  Widget _intro() => AppIdentityBanner.info(
        title: WorkerWithdrawCopy.needBind,
        detail: '填好下面四项后就能申请提现；打款会转到你填的微信收款码。',
      );

  Widget _rebindNotice() => AppIdentityBanner.warn(
        title: '换绑后新收款信息用于后续打款',
        detail: WorkerWithdrawCopy.rebindNotice,
      );

  Widget _formCard() {
    return AppCard(
      padding: EdgeInsets.zero,
      radius: 14,
      child: Column(
        children: [
          _field(
            keyName: 'withdraw-real-name',
            label: '姓名',
            hint: '收款人真实姓名',
            controller: _name,
            onChanged: (_) => setState(() {
              _nameTouched = true;
              _formError = null;
            }),
          ),
          _hairline(),
          _field(
            keyName: 'withdraw-phone',
            label: '电话',
            hint: '11 位手机号',
            controller: _phone,
            keyboardType: TextInputType.phone,
            onChanged: (_) => setState(() {
              _phoneTouched = true;
              _formError = null;
            }),
          ),
          _hairline(),
          _field(
            keyName: 'withdraw-wechat',
            label: '微信号',
            hint: '6–20 位，字母开头',
            controller: _wechat,
            onChanged: (_) => setState(() => _formError = null),
          ),
          _hairline(),
          _qrBlock(),
        ],
      ),
    );
  }

  Widget _hairline() => Divider(height: 1, thickness: 1, color: AppColors.divider, indent: 14);

  Widget _field({
    required String keyName,
    required String label,
    required String hint,
    required TextEditingController controller,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: TextField(
              key: Key(keyName),
              controller: controller,
              keyboardType: keyboardType,
              onChanged: onChanged,
              style: TextStyle(fontSize: 14.5, color: T.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 收款码上传位（92dp，与充值页付款截图同档几何）
  Widget _qrBlock() {
    final picked = _picked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                key: WorkerWithdrawAccountPage.qrTileKey,
                behavior: HitTestBehavior.opaque,
                onTap: _pickQr,
                child: Container(
                  width: 92,
                  height: 92,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.ice,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _qrError == null ? T.divider : AppColors.error),
                  ),
                  child: picked == null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const AppIcon.of(AppIcon.upload, size: 20, color: AppColors.primary),
                            const SizedBox(height: 5),
                            Text(
                              '上传收款码',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.primary),
                            ),
                          ],
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            bytesOfPicked(picked.bytes),
                            width: 92,
                            height: 92,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _uploading
                          ? '收款码上传中…'
                          : (_qrMediaId != null ? '收款码已上传' : '微信收款码（必填）'),
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '用微信「收付款 → 二维码」截图上传，打款会转到它。',
                      style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.45),
                    ),
                    if (_qrMediaId != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const AppIcon.of(AppIcon.check, size: 14, color: AppColors.success),
                          const SizedBox(width: 4),
                          Text('可以保存了', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.success)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_qrError != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(_qrError!, style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
                ),
              ],
            ),
          ],
          MediaUploadTile(
            state: _up,
            label: '微信收款码',
            onRetry: _picked == null ? null : _retryUpload,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              AppIdentityOutlineButton(
                label: _picked == null ? WorkerWithdrawCopy.pickQr : '重新选择',
                onTap: _uploading ? () {} : _pickQr,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _errorCard(String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.bannerDangerBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.bannerDangerBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1.5),
              child: AppIcon.of(AppIcon.info, size: 15, color: AppColors.error),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12.5, color: AppColors.error, height: 1.45)),
            ),
          ],
        ),
      );

  /// 脱敏（服务端没回带时，本地兜一份展示值；**绝不**用它当提交值）
  static String _maskName(String v) {
    if (v.isEmpty) return '';
    // 只留首字 + 固定三颗星：与「张*山」这类服务端脱敏值同为"看不出全名"的表达
    return '${v.substring(0, 1)}***';
  }

  static String _maskPhone(String v) => v.length == 11 ? '${v.substring(0, 3)}****${v.substring(7)}' : v;
}

/// `Image.memory` 要 `Uint8List`，而挂载点给的是 `List<int>`（宿主可能给 `List<int>`）
///
/// 只在必要时复制一次（`Uint8List` 原样透传），避免每帧重建图片数据。
Uint8List bytesOfPicked(List<int> bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

/// 收款码在「已绑定」态下的小图（列表行/详情共用；带令牌时也支持受保护通道）
class WithdrawQrThumb extends StatelessWidget {
  const WithdrawQrThumb({
    super.key,
    required this.url,
    this.size = 48,
    this.headers = const <String, String>{},
  });

  final String url;
  final double size;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: T.divider),
      ),
      child: url.isEmpty
          ? AppIcon.of(AppIcon.qr, size: size * 0.42, color: T.textTertiary)
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CachedNetImage(
                url: url,
                headers: headers,
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                placeholder: AppIcon.of(AppIcon.qr, size: size * 0.42, color: T.textTertiary),
                errorBuilder: (_, failure, retry) =>
                    ImageLoadError(failure: failure, onRetry: retry, compact: true),
              ),
            ),
    );
  }
}
