import 'dart:async';
import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'recharge_records_page.dart';

/// ============================================================================
/// 充值页（老板侧）—— 负责人 2026-10-06 方案①
/// ============================================================================
///
/// ## 合规（写死在流程里，不给"顺手接个支付"留口子）
/// - **不接任何支付通道**：这里没有支付 SDK、没有支付订单号、没有回调轮询；
///   收款码就是一张**图片**（服务端下发），老板线下扫码付款；
/// - 付完**上传付款截图（必填）** + 可选备注 → 提交申请 → 由平台核对后**手工加余额**；
/// - 提交后的文案只有一句：[RechargeCopy.submitted]「申请已提交，等待审核」——
///   **绝不出现"支付成功 / 自动到账"**（`RechargeCopy.forbiddenWords` + 测试逐屏扫描）；
/// - 页面上**不做**提现、不做余额兑换现金。
///
/// ## 文件结构（刻意的分区，方便设计定案后只改一处）
/// 1. 【数据与状态】`_RechargePageState` 的上半部分：拉配置 / 校验 / 选图上传 / 提交 / 记录入口；
/// 2. 【版式区】`_body()` 及之后的 `_step*` / `_view*` 系列方法 —— 设计已定案为**形态 3「两步式」**，
///    版式改动**只落在这半部分 + 一个 `_step` 字段**（数据、校验、网络层一行未动）。
///
/// ## 两步式（设计定案「形态 3」）
/// - **Step 1 选金额**：10 档网格 + 自定义（受 min/max）→ 主按钮「下一步」（**未选金额置灰**）；
/// - **Step 2 扫码 + 上传**：步骤指示（`1 选金额 ✓ → 2 扫码付款`）+ 收款码大图（多张可切换，按渠道标注）
///   + 应付金额 / 到账余额（1:1） + 说明文案 + **上传付款截图（必填）** + 备注 + 提交；
/// - **可返回 Step 1 改金额**（点「上一步」或系统返回键）：**已填内容全部保留**
///   —— 状态都在同一个 `State` 里，返回只把 `_step` 置 1，不清空任何字段；
/// - 提交后仍是「申请已提交，等待审核」（**绝不出现"支付成功"**）；记录入口保留在页内。
class RechargePage extends StatefulWidget {
  const RechargePage({super.key, this.api, this.picker, this.uploader});

  /// 测试注入（不传 → 自建 ApiClient）
  final ApiClient? api;

  /// 选图器注入（测试用，避免真起 image_picker 平台通道）
  final Future<PickedProof?> Function()? picker;

  /// 上传器注入（测试用；不传 → 复用既有媒体上传能力 `uploadMedia`）
  final Future<MediaUploadResult> Function({
    required String type,
    required List<int> bytes,
    required String filename,
    required String token,
  })? uploader;

  /// 上传用途类型：**专用媒体类型 `recharge_proof`**（docs/02：`protected`，资金凭证绝不公开直连）。
  ///
  /// 刻意**不做**"失败就换个类型重试"的降级：`recharge_proof` 是服务端契约里的专用用途，
  /// 借用 `complaint_image` 之类会让审核员读不到图（受限会话的白名单里没有 `/media/*`，
  /// 凭证只能走 `/recharge/proof/:requestId`）—— 那是比"上传失败"更糟的静默错误。
  static const String mediaType = 'recharge_proof';

  /// 两步式的两个步骤号（测试与页面共用同一份常量，避免两套数字）
  static const int stepAmount = 1;
  static const int stepPay = 2;

  @override
  State<RechargePage> createState() => _RechargePageState();
}

/// 选中的付款截图（本地字节 + 原始文件名）
class PickedProof {
  const PickedProof({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
}

// =====================================================================================
// 【数据与状态】
// =====================================================================================
class _RechargePageState extends State<RechargePage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  RechargeConfig _cfg = RechargeConfig.empty;
  bool _loading = true;

  /// 加载失败原因（网络/服务端中文原文）→ 页内可重试
  String? _loadError;

  /// 选中的金额（档位或自定义解析结果）；null = 还没选
  ///
  /// **刻意不预选第一档**（设计定案两步式的前提）：Step 1 的「下一步」必须由用户真的选一次金额，
  /// 未选时置灰 —— 金额是钱的事，不能让"默认选中 6 元"替用户做决定。
  num? _amount;
  final TextEditingController _custom = TextEditingController();
  String? _customError;
  bool _customSelected = false;

  /// 当前步骤（1 = 选金额；2 = 扫码付款 + 上传 + 提交）—— 两步式唯一新增的状态字段
  int _step = 1;

  /// 当前展示的收款码下标（多张时可切换）
  int _qrIndex = 0;

  /// 付款截图（必填）：先本地预览，上传成功后拿到 mediaId
  PickedProof? _proof;
  String? _proofMediaId;
  bool _uploading = false;
  String? _proofError;

  /// 【2026-10-06 上传体验专项】付款截图的上传进度（百分比/速度/已传/总大小 + 慢网提示）
  final MediaUploadState _proofUp = MediaUploadState();

  final TextEditingController _note = TextEditingController();

  bool _submitting = false;
  String? _submitError;
  RechargeSubmitResult? _submitted;

  /// 我的申请（只取 `pendingCount` / `pendingLimitPerUser`：docs/03 明确"客户端据此禁用提交按钮"）
  RechargeRequestPage _mine = RechargeRequestPage.empty;

  @override
  void initState() {
    super.initState();
    // 慢网提示要在"长时间没有进度回调"时也能上屏（见 MediaUploadState 的说明）
    _proofUp.onTick = () {
      if (mounted) setState(() {});
    };
    // **进入即回源**（force）：档位/收款码/文案由管理端随时改，钱相关的页面不吃 45s 缓存
    unawaited(_load(force: true));
  }

  @override
  void dispose() {
    _proofUp.dispose();
    _custom.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 到账余额（**预览值**）：口径 1 元 = 1 元 → 到账 = 付款金额本身（见 [RechargeRules.previewBalance]）
  ///
  /// 刻意**不乘**配置里的历史比例字段（`pointsPerYuan`）：那是"1 元 = 10 积分"时代的产物，
  /// 现在拿它当乘数会把 `¥6.00` 预览成 `¥60.00`（界面撒谎）。字段仍解析（接口形状不变），
  /// 但不参与任何展示；最终到账以服务端发放结果为准。
  num get _arrival => _amount == null ? 0 : RechargeRules.previewBalance(_amount!);

  /// 拉充值配置（档位/收款码/文案**全部来自服务端**，客户端不写死）
  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final resp = await _api.request('GET', '/public/recharge/config', forceRefresh: force);
      final data = resp['data'];
      final cfg = RechargeConfig.fromJson(data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{});
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _loading = false;
        _qrIndex = 0;
        // **不预选任何档位**（定案两步式的前提）：由用户在 Step 1 真的选一次，
        // 「下一步」在未选时置灰 —— 金额是钱的事，不替用户做默认选择。
      });
      // 在审笔数（用了禁用提交按钮的判断；失败静默 —— 服务端 400 仍会兜底并原样透传文案）
      try {
        final mineResp = await _api.request(
          'GET',
          '/user/recharge/requests',
          queryParameters: {'page': 1, 'pageSize': 1},
          token: AuthStore.instance.accessToken,
          forceRefresh: true,
        );
        final mine = RechargeRequestPage.fromData(mineResp['data']);
        if (!mounted) return;
        setState(() => _mine = mine);
      } catch (_) {
        // 静默
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '充值配置加载失败，请重试';
      });
    }
  }

  void _selectAmount(num value) {
    setState(() {
      _amount = value;
      _customSelected = false;
      _customError = null;
      _submitError = null;
    });
  }

  /// 自定义金额输入：既报本地错（越界/格式），也把选中的值同步给下方金额卡
  void _onCustomChanged(String raw) {
    final err = RechargeRules.validateCustomInput(raw, _cfg);
    final v = RechargeRules.parseYuan(raw);
    final ok = err == null && v != null;
    setState(() {
      _customError = err;
      _customSelected = ok;
      _submitError = null;
      if (ok) _amount = v;
    });
  }

  /// 选图 → 上传（复用既有媒体上传能力 `uploadMedia`，docs/08）
  ///
  /// 【2026-10-06 上传体验专项】真实进度（`onProgress`）+ 中文失败原因 + 可重试：
  /// 付款凭证往往是一张 1–2MB 的**截图原图**，弱网下原来就是一个无限转圈。
  Future<void> _pickProof() async {
    if (_uploading) return;
    final picked = widget.picker != null ? await widget.picker!() : await _pickFromGallery();
    if (picked == null || !mounted) return;
    setState(() {
      _proof = picked;
      _proofMediaId = null;
      _proofError = null;
      _uploading = true;
      _proofUp.begin();
    });
    await _doUploadProof(picked);
  }

  /// 失败后「重新上传」：**不重新选图**，直接重传同一份字节
  Future<void> _retryProof() async {
    final picked = _proof;
    if (picked == null || _uploading) return;
    setState(() {
      _proofError = null;
      _uploading = true;
      _proofUp.begin();
    });
    await _doUploadProof(picked);
  }

  /// 真正上传（选图与重试共用这一条路径）
  Future<void> _doUploadProof(PickedProof picked) async {
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _proofUp.fail('登录已过期，请重新登录后再上传');
        _proofError = '登录已过期，请重新登录后再上传';
      });
      return;
    }
    try {
      final up = await _uploadProof(picked, token);
      if (!mounted) return;
      setState(() {
        _proofMediaId = up.id;
        _uploading = false;
        _proofUp.succeed();
      });
    } catch (e) {
      if (!mounted) return;
      // 中文可上屏原因（连不上/超时/服务端拒绝各有说法），并保留「重新上传」入口
      final String msg = mediaUploadErrorMessage(e);
      setState(() {
        _uploading = false;
        _proofError = msg;
        _proofUp.fail(msg);
      });
    }
  }

  /// 上传（复用既有媒体上传能力 `uploadMedia`；用途类型见 [RechargePage.mediaType]）
  ///
  /// `onProgress` 只在**真实上传路径**上传（注入的测试上传器签名不变 —— 既有 6 处
  /// 测试调用点一行都不用改）。
  Future<MediaUploadResult> _uploadProof(PickedProof picked, String token) {
    final injected = widget.uploader;
    if (injected != null) {
      return injected(type: RechargePage.mediaType, bytes: picked.bytes, filename: picked.name, token: token);
    }
    return uploadMedia(
      type: RechargePage.mediaType,
      bytes: picked.bytes,
      filename: picked.name,
      token: token,
      onProgress: (p) {
        if (mounted) setState(() => _proofUp.update(p));
      },
    );
  }

  Future<PickedProof?> _pickFromGallery() async {
    // 【2026-10-06 压缩收紧】1600/85 → **1600/72**：付款截图不是摄影作品，
    // 72 质量下金额/时间/收款方依然清晰可辨（客服核对够用），字节数明显更小。
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 72);
    if (picked == null) return null;
    return PickedProof(bytes: Uint8List.fromList(await picked.readAsBytes()), name: picked.name);
  }

  /// 提交申请（**只有这一条成功文案**；服务端 400 文案原样展示）
  Future<void> _submit() async {
    if (_submitting) return;
    final amount = _amount;
    final amountError = RechargeRules.validateAmount(amount, _cfg);
    if (amountError != null) {
      setState(() => _submitError = amountError);
      return;
    }
    if (_proofMediaId == null) {
      // 截图必填：本地先拦一次（比打服务器更即时），文案与服务端口径一致
      final msg = _proof == null
          ? '请上传付款截图'
          : (_proofError != null ? '付款截图还没上传成功，请重新上传' : '截图还在上传中，请稍候再提交');
      setState(() {
        _submitError = msg;
        if (_proof == null) _proofError = '付款截图是必填项，客服要照它核对收款记录';
      });
      return;
    }
    final token = AuthStore.instance.accessToken;
    if (token == null) {
      setState(() => _submitError = '登录已过期，请重新登录后再提交');
      return;
    }
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final resp = await _api.request(
        'POST',
        '/user/recharge/requests',
        token: token,
        data: {
          'amountYuan': amount,
          if (_cfg.usableQrCodes.isNotEmpty) 'qrId': _cfg.usableQrCodes[_qrIndex.clamp(0, _cfg.usableQrCodes.length - 1)].id,
          if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
          'proofMediaId': _proofMediaId,
        },
      );
      final data = resp['data'];
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitted = RechargeSubmitResult.fromJson(
          data is Map ? data.cast<String, dynamic>() : const <String, dynamic>{},
        );
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // 超待审核上限 / 收款码失效 等：**服务端中文原文原样展示**（客户端不改字、不猜测）
      setState(() {
        _submitting = false;
        _submitError = e.message;
      });
    }
  }

  void _openRecords() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RechargeRecordsPage(api: widget.api)));
  }

  // =====================================================================================
  // ★★★ 【版式区】—— 设计定案「形态 3 两步式」的实现全在这一段（+ 一个 `_step` 字段）★★★
  // =====================================================================================

  /// 返回上一步（Step 2 → Step 1）/ 退页（Step 1 → pop）
  ///
  /// **不清空任何已填内容**：状态都在同一个 `State` 里，这里只改 `_step`。
  void _back() {
    if (_step == RechargePage.stepPay) {
      setState(() => _step = RechargePage.stepAmount);
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _next() {
    if (_amount == null) return; // 未选金额：按钮本来就置灰（双保险，绝不静默进第二步）
    setState(() {
      _step = RechargePage.stepPay;
      _submitError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Step 2 时系统返回键 = 回 Step 1（不是退出页面）；Step 1 时放开（走系统默认 pop）
      canPop: _step == RechargePage.stepAmount,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: T.scaffoldColor,
        body: Column(
          children: [
            AppPageHeader(title: '充值', onBack: _back),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: T.primary));
    }
    if (_loadError != null) {
      return _errorView();
    }
    if (_submitted != null) {
      return _submittedView(_submitted!);
    }
    return _step == RechargePage.stepAmount ? _stepAmountView() : _stepPayView();
  }

  /// 加载失败：中文原因 + 重试
  Widget _errorView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 40, AppSpacing.page, 24),
      children: [
        AppCard(
          child: Column(
            children: [
              AppIcon.of(AppIcon.info, size: 26, color: T.warning),
              const SizedBox(height: 10),
              Text('充值页暂时打不开', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: T.textPrimary)),
              const SizedBox(height: 4),
              Text(_loadError ?? '', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.5)),
              const SizedBox(height: 14),
              AppButton(label: '重试', onPressed: () => _load(force: true), gradient: false, expand: false, height: 38),
            ],
          ),
        ),
      ],
    );
  }

  /// **Step 1 · 选金额**：档位网格 + 自定义 + 「下一步」（未选金额置灰）
  Widget _stepAmountView() {
    final canNext = _amount != null && _customError == null;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _stepIndicator(),
        const AppSectionHeader(title: '选择充值金额', padding: EdgeInsets.fromLTRB(16, 16, 16, 8)),
        _amountGrid(),
        if (_cfg.customEnabled) _customField(),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: AppIdentityPrimaryButton(
            label: '下一步',
            onPressed: canNext ? _next : null,
          ),
        ),
        if (!canNext)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.page, 8, AppSpacing.page, 0),
            child: Text(
              '选一个金额，或填写自定义金额后继续',
              style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
            ),
          ),
      ],
    );
  }

  /// **Step 2 · 扫码付款 + 上传 + 提交**
  Widget _stepPayView() {
    final qrCodes = _cfg.usableQrCodes;
    final qr = qrCodes.isEmpty ? null : qrCodes[_qrIndex.clamp(0, qrCodes.length - 1)];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _stepIndicator(),
        _amountSummary(),
        const AppSectionHeader(title: '扫码付款', padding: EdgeInsets.fromLTRB(16, 18, 16, 8)),
        _qrCard(qr, qrCodes.length),
        _noticeCard(),
        const AppSectionHeader(title: '上传付款截图', padding: EdgeInsets.fromLTRB(16, 18, 16, 8)),
        _proofCard(),
        const AppSectionHeader(title: '备注（选填）', padding: EdgeInsets.fromLTRB(16, 18, 16, 8)),
        _noteField(),
        if (_submitError != null) _submitErrorCard(),
        const SizedBox(height: 16),
        _submitBar(),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.page, 10, AppSpacing.page, 0),
          child: AppIdentityOutlineButton(
            label: '上一步 · 改金额',
            height: 40,
            expand: true,
            onTap: _back,
          ),
        ),
        _recordsEntry(),
      ],
    );
  }

  /// 步骤指示（`1 选金额 ✓ → 2 扫码付款`）：实色 + 发丝线，不用渐变/不用彩色胶囊
  Widget _stepIndicator() {
    final onAmount = _step == RechargePage.stepAmount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 14, AppSpacing.page, 0),
      child: Row(
        children: [
          _stepChip(no: '1', label: '选金额', done: !onAmount, active: onAmount),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Container(width: 18, height: 1, color: T.divider),
          ),
          _stepChip(no: '2', label: '扫码付款', done: false, active: !onAmount),
        ],
      ),
    );
  }

  Widget _stepChip({required String no, required String label, required bool done, required bool active}) {
    final color = active ? T.primary : AppColors.mutedText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 17,
          height: 17,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.primarySoft : AppColors.ice,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: active ? T.primary : T.divider),
          ),
          child: done
              ? const AppIcon.of(AppIcon.check, size: 11, color: AppColors.statusOnline)
              : Text(no, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: color),
        ),
      ],
    );
  }

  /// 金额档位网格（**全部来自配置**，客户端不写死任何一个数字）
  Widget _amountGrid() {
    final options = _cfg.amountOptions;
    if (options.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: AppEmpty(icon: AppIcon.coin, text: '暂无可选金额，请填写自定义金额'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.15,
        children: [
          for (final v in options)
            _amountCell(
              label: RechargeRules.formatYuan(v),
              selected: !_customSelected && _amount == v,
              onTap: () => _selectAmount(v),
            ),
        ],
      ),
    );
  }

  /// 金额档位（**只改视觉，不动逻辑**：选中态按方案 G 定为「蓝底白字」胶囊）
  ///
  /// 选中：`T.primary` 实色底 + 白字 + 加粗（对比 5.17:1，一眼看出选了哪档）；
  /// 未选中：白底 + 1px 发丝线 + 正文色（与全站未选中控件同一档）。
  /// 尺寸/圆角/点击行为与返工前**逐值一致**（圆角 10 = `AppDecoRadius.control`）。
  Widget _amountCell({required String label, required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? T.primary : T.bgCardSolid,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? T.primary : T.divider, width: selected ? 1.2 : 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? Colors.white : T.textPrimary,
          ),
        ),
      ),
    );
  }

  /// 自定义金额（受 min/max 限制；越界给中文错误）
  Widget _customField() {
    final min = RechargeRules.formatYuan(_cfg.effectiveMinYuan);
    final max = _cfg.effectiveMaxYuan > 0 ? RechargeRules.formatYuan(_cfg.effectiveMaxYuan) : '';
    final hint = max.isEmpty ? '自定义金额（不低于 $min）' : '自定义金额（$min ~ $max）';
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 10, AppSpacing.page, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _customError == null ? T.bgCardSolid : AppColors.bannerDangerBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _customError == null ? T.divider : AppColors.error),
            ),
            child: Row(
              children: [
                AppIcon.of(AppIcon.edit, size: 16, color: T.textTertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('recharge-custom-amount'),
                    controller: _custom,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: _onCustomChanged,
                    style: TextStyle(fontSize: 15, color: T.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: hint,
                      hintStyle: const TextStyle(fontSize: 13.5, color: AppColors.textTertiary),
                    ),
                  ),
                ),
                Text('元', style: TextStyle(fontSize: 13, color: T.textSecondary)),
              ],
            ),
          ),
          if (_customError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                  const SizedBox(width: 5),
                  Text(_customError!, style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.4)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 应付金额 + 到账余额（**1 元 = 1 元**；最终以服务端发放为准）
  Widget _amountSummary() {
    final amount = _amount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('应付金额', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                      const SizedBox(height: 4),
                      Text(
                        amount == null ? '—' : RechargeRules.formatYuan(amount),
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: T.textPrimary),
                      ),
                    ],
                  ),
                ),
                Container(width: 1, height: 36, color: T.divider),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('到账余额', style: TextStyle(fontSize: 11.5, color: AppColors.mutedText)),
                      const SizedBox(height: 4),
                      AppPrice(value: amount == null ? '—' : fmtMoney(_arrival), size: 19),
                    ],
                  ),
                ),
              ],
            ),
            // 口径明写：付款多少 → 到账多少（**1:1**，不再有"10 积分等于 1 元"那套换算）
            if (amount != null) ...[
              const SizedBox(height: 10),
              Text(
                RechargeCopy.previewLine(amount),
                style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 收款码卡：**图片**（不是支付按钮）+ 渠道标注（微信 / 支付宝，多张可切换）
  Widget _qrCard(RechargeQrCode? qr, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon.of(AppIcon.qr, size: 15, color: T.primary),
                const SizedBox(width: 6),
                const Text('收款码', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const Spacer(),
                if (qr != null) AppTag(qr.channel.label, color: AppColors.primary),
              ],
            ),
            const SizedBox(height: 12),
            if (qr == null)
              const SizedBox(
                height: 168,
                child: AppEmpty(icon: AppIcon.qr, text: '平台还没配置收款码，请联系客服'),
              )
            else
              Center(
                child: GestureDetector(
                  onTap: () => RechargeProofViewer.show(context, qr.imageUrl),
                  child: Container(
                    width: 196,
                    height: 196,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: T.divider),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetImage(
                        url: qr.imageUrl,
                        fit: BoxFit.contain,
                        width: 180,
                        height: 180,
                        placeholder: const Center(
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (count > 1) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  for (var i = 0; i < count; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _qrIndex = i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _qrIndex == i ? AppColors.primarySoft : T.bgCardSolid,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _qrIndex == i ? T.primary : T.divider),
                        ),
                        child: Text(
                          _cfg.usableQrCodes[i].displayLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _qrIndex == i ? FontWeight.w700 : FontWeight.w500,
                            color: _qrIndex == i ? T.primary : T.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.ice,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.bannerInfoBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: AppIcon.of(AppIcon.info, size: 13, color: AppColors.primary),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      RechargeCopy.scanHint,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.bannerInfoInk, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 说明文案（服务端下发；未下发时不编造规则，只保留必说的那一句）
  Widget _noticeCard() {
    final text = _cfg.noticeText.isNotEmpty ? _cfg.noticeText : RechargeCopy.submittedDetail;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 10, AppSpacing.page, 0),
      child: Text(text, style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.6)),
    );
  }

  /// 上传付款截图（**必填**；先本地预览，后台上传）
  Widget _proofCard() {
    final proof = _proof;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _pickProof,
                  child: Container(
                    width: 92,
                    height: 92,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.ice,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _proofError == null ? T.divider : AppColors.error),
                    ),
                    child: proof == null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const AppIcon.of(AppIcon.upload, size: 20, color: AppColors.primary),
                              const SizedBox(height: 5),
                              Text('选择截图', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.primary)),
                            ],
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.memory(proof.bytes, width: 92, height: 92, fit: BoxFit.cover),
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
                            ? '截图上传中…'
                            : (_proofMediaId != null ? '截图已上传' : '付款截图（必填）'),
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '截图要能看清收款方、金额与时间，客服核对时以它为准。',
                        style: TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.45),
                      ),
                      const SizedBox(height: 8),
                      if (_proofMediaId != null)
                        Row(
                          children: [
                            const AppIcon.of(AppIcon.check, size: 14, color: AppColors.success),
                            const SizedBox(width: 4),
                            Text('可以提交了', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: T.success)),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_proofError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const AppIcon.of(AppIcon.info, size: 13, color: AppColors.error),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(_proofError!,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.error, height: 1.45)),
                    ),
                  ],
                ),
              ),
            // 【2026-10-06 上传体验专项】真实进度（百分比 + 速度 + 已传/总大小 + 慢网提示），
            // 失败时这里是中文原因 + 「重新上传」（与下方灰字错误行同一份文案，两处都在）
            MediaUploadTile(
              state: _proofUp,
              label: '付款截图',
              onRetry: _proof == null ? null : _retryProof,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                AppIdentityOutlineButton(
                  // 按钮说"动作"、上方区块标题说"这是什么"（两处文案不重复，便于定位与断言）
                  label: _proof == null ? '选择付款截图' : '重新选择',
                  onTap: _uploading ? () {} : _pickProof,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _noteField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: T.divider),
        ),
        child: TextField(
          key: const Key('recharge-note'),
          controller: _note,
          maxLines: 2,
          style: TextStyle(fontSize: 14, color: T.textPrimary),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: '例如：微信转账，付款人昵称与账号一致',
            hintStyle: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
        ),
      ),
    );
  }

  /// 提交失败：**服务端中文原文**（超待审核上限 / 收款码失效 / 其它）
  Widget _submitErrorCard() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 0),
      child: Container(
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
              child: Text(_submitError!,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.error, height: 1.45)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _submitBar() {
    final atLimit = _mine.atPendingLimit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      child: Column(
        children: [
          if (atLimit)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  const AppIcon.of(AppIcon.info, size: 13, color: AppColors.warning),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // 笔数与上限都来自服务端；这里只说"还要等"，不替服务端承诺时间
                      '你在审的申请 ${_mine.pendingCount} 笔，已达上限 ${_mine.pendingLimitPerUser} 笔',
                      style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          AppIdentityPrimaryButton(
            label: atLimit
                ? RechargeCopy.pendingLimitReached
                : (_submitting ? '提交中…' : '提交申请'),
            busy: _submitting,
            onPressed: (_submitting || atLimit) ? null : _submit,
          ),
        ],
      ),
    );
  }

  /// 「我的充值记录」入口（入口放充值页内）
  Widget _recordsEntry() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 12, AppSpacing.page, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openRecords,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: T.bgCardSolid,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: T.divider),
          ),
          child: Row(
            children: [
              AppIcon.of(AppIdentityIcons.receipt, size: 16, color: T.textSecondary),
              const SizedBox(width: 9),
              Text('我的充值记录', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: T.textPrimary)),
              const Spacer(),
              AppIcon.of(AppIcon.chevronRight, size: 16, color: T.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  /// 提交成功态：**唯一**的成功文案「申请已提交，等待审核」
  ///
  /// 这里刻意**不写**任何"支付成功/自动到账/已到账"字样（合规红线，见 [RechargeCopy.forbiddenWords]）：
  /// 钱是线下扫给收款码的，平台只负责核对后**手工发放余额**。
  Widget _submittedView(RechargeSubmitResult result) {
    final arrival = result.points > 0 ? result.points : _arrival;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.page, 40, AppSpacing.page, 24),
      children: [
        Center(
          child: Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const AppIcon.of(AppIdentityIcons.clock, size: 26, color: AppColors.primary),
          ),
        ),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            RechargeCopy.submitted,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _amount == null
                ? RechargeCopy.submittedDetail
                : '${RechargeRules.formatYuan(_amount!)} · 待发放 ${fmtMoney(arrival)}',
            style: const TextStyle(fontSize: 12, color: AppColors.mutedText, height: 1.5),
          ),
        ),
        const SizedBox(height: 18),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('接下来会发生什么', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              _stepRow('1', '客服会核对你上传的付款截图与到账记录'),
              _stepRow('2', '核对通过后手工发放余额到你的账号'),
              _stepRow('3', '在「我的充值记录」里能看到状态变成已到账'),
              const SizedBox(height: 10),
              Text(
                RechargeCopy.submittedDetail,
                style: const TextStyle(fontSize: 11.5, color: AppColors.mutedText, height: 1.55),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppIdentityPrimaryButton(
          label: '查看我的充值记录',
          onPressed: () {
            setState(() => _submitted = null);
            _openRecords();
          },
        ),
        const SizedBox(height: 9),
        AppIdentityOutlineButton(
          label: '返回',
          height: 40,
          expand: true,
          onTap: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _stepRow(String no, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 17,
            height: 17,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.ice,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(no, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.primary)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
