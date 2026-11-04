import 'dart:typed_data';

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// 投诉（顶部导航入口 · 负责人 2026-10-04）
///
/// 结构规则（CLAUDE.md 规则 1）：投诉页自己承载「提交 + 我的投诉」，不在别处重复挂入口。
///
/// 业务：
/// - 对象三选一：订单 / 打手 / 客服；类型：服务态度 / 未按约定 / 恶意拖延 / 其它
/// - 描述 5–1000 字；截图最多 6 张（`complaint_image` 受保护媒体，只有本人与管理员可读）
/// - 投诉人与目标归属由服务端校验（客户端传的 id 只是"选哪个"，服务端不认识就直接拒绝）
///
/// 【2026-10-05 负责人任务②③：两个下拉的候选范围都改成"服务端说了算"】
/// - **订单候选**：`GET /user/orders?status=<可投诉状态>` → 已取消的单**不显示**（也不可提交，
///   服务端对状态独立复校验，中文 400）。清单见 core `kComplaintableOrderStatuses`，
///   权威定义在 server `order-complaintable.ts`。
/// - **打手候选**：`GET /user/complaints/targets/workers`（`?orderId=` 可收敛到该订单接单人）
///   → 只列**真接过我单**的打手；此前用的 `/public/players`（全部在岗打手）已移除。
///   服务端 `ComplaintService.create` 会独立校验服务关系，未接过我单的打手一律中文 400。
class ComplaintPage extends StatefulWidget {
  const ComplaintPage({super.key, this.api, this.picker});

  final ApiClient? api;

  /// 测试注入的图片选择器（返回本地图片字节，避免测试依赖平台通道）
  final Future<List<PickedImage>> Function()? picker;

  @override
  State<ComplaintPage> createState() => _ComplaintPageState();
}

/// 待上传图片（文件名 + 字节，测试可注入）
class PickedImage {
  const PickedImage(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

class _ComplaintPageState extends State<ComplaintPage> {
  late final ApiClient _api = widget.api ?? ApiClient();

  int _tab = 0; // 0 提交投诉 / 1 我的投诉
  bool _loading = true;
  String? _error;

  // ---- 表单状态 ----
  String _targetType = 'order';
  String _type = 'attitude';
  final TextEditingController _content = TextEditingController();
  final List<PickedImage> _images = [];
  final List<String> _mediaIds = [];
  bool _uploading = false;
  bool _submitting = false;

  // ---- 对象候选（订单 / 打手，全部来自服务端）----
  List<_OrderOption> _orderOptions = const [];
  List<_WorkerOption> _workerOptions = const [];
  String? _targetId;

  /// 【任务③】「投诉打手」当前绑定的订单：非空 = 只允许选该订单的接单打手（服务端 `?orderId=` 口径）。
  /// 与 [_targetId] **分开存**：`_targetId` 会随投诉对象在"订单 id / 打手 id"之间切换，
  /// 若共用一个字段，切到「打手」时会把订单号误当成已选打手。
  String? _workerFilterOrderId;

  // ---- 我的投诉 ----
  List<_MyComplaint> _complaints = const [];

  static const List<List<String>> _targetOptions = [
    ['order', '订单'],
    ['worker', '打手'],
    ['service', '客服'],
  ];
  static const List<List<String>> _typeOptions = [
    ['attitude', '服务态度'],
    ['not_agreed', '未按约定'],
    ['delay', '恶意拖延'],
    ['other', '其它'],
  ];

  @override
  void initState() {
    super.initState();
    // 订单/打手候选与工单状态都要最新（避免缓存里已结束的订单还能被投诉）
    _load(force: true);
  }

  @override
  void dispose() {
    _content.dispose();
    _errs.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = AuthStore.instance.accessToken;
      if (_tab == 0) {
        final results = await Future.wait([
          // 【任务② 2026-10-05】订单候选 = **只列可投诉的订单**：
          // `status` 传后端认可的那组状态（core 的 kComplaintableOrderStatuses，
          // 与 server/src/modules/order/order-complaintable.ts 同一口径）→ 已取消（canceled）、
          // 待接单、异常处理中的单一律不下发。服务端 `ComplaintService.create` 还会独立复校验。
          _api.request('GET', '/user/orders',
              token: token,
              queryParameters: {'status': complaintableOrderStatusQuery(), 'page': 1, 'pageSize': 20},
              forceRefresh: force),
          // 【任务③ 2026-10-05】打手候选 = **我的关联打手**（曾接过我单的打手，服务端按 worker 去重）。
          // 此前这里是 `/public/players`（全部在岗打手，最多 50 个）→ 可以投诉一个从没接过我单的人。
          _api.request('GET', '/user/complaints/targets/workers', token: token, forceRefresh: force),
        ]);
        final orders = (((results[0]['data'] as Map?)?['list'] as List?) ?? const [])
            .map((e) => _OrderOption.fromJson(e as Map))
            .toList();
        final workers = (((results[1]['data'] as List?) ?? const []))
            .map((e) => _WorkerOption.fromJson(e as Map))
            .toList();
        if (!mounted) return;
        setState(() {
          _orderOptions = orders;
          _workerOptions = workers;
          _loading = false;
        });
      } else {
        final resp = await _api.request('GET', '/user/complaints',
            token: token, queryParameters: {'page': 1, 'pageSize': 30}, forceRefresh: force);
        final data = (resp['data'] as Map?) ?? const {};
        if (!mounted) return;
        setState(() {
          _complaints = ((data['list'] as List?) ?? const []).map((e) => _MyComplaint.fromJson(e as Map)).toList();
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// 【任务③】按所选**订单**收敛打手候选
  ///
  /// 负责人定的最严口径：投诉针对某一订单时，打手只能选**该订单的接单打手**。
  /// 这里不是前端过滤一份大名单（那样前端被绕过后端就失效），而是用 `?orderId=`
  /// 让服务端按同一套 where 条件重新查一次 —— 列表与服务端校验同源。
  ///
  /// 未选订单（通用投诉）时回到"曾接过我单的打手"全量，服务端校验同样成立。
  Future<void> _loadWorkersForOrder(String? orderId) async {
    try {
      final resp = await _api.request('GET', '/user/complaints/targets/workers',
          token: AuthStore.instance.accessToken,
          queryParameters: orderId == null || orderId.isEmpty ? null : {'orderId': orderId},
          forceRefresh: true);
      final workers = (((resp['data'] as List?) ?? const [])).map((e) => _WorkerOption.fromJson(e as Map)).toList();
      if (!mounted) return;
      setState(() {
        _workerOptions = workers;
        // 若已选打手不在新名单里（换了订单 / 选了通用），清掉选择，避免提交一个非法 targetId
        if (_targetId != null && !workers.any((w) => w.id == _targetId)) _targetId = null;
      });
    } on ApiException catch (_) {
      // 候选刷新失败不阻断页面：保留上一次名单，提交时服务端仍会做权威校验
    }
  }

  void _switchTab(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
    _load(force: true);
  }

  /// 选图 → 立即上传（`complaint_image` 受保护媒体），最多 6 张
  Future<void> _pickImages() async {
    if (_images.length >= 6) {
      AppToast.info(context, '最多 6 张截图');
      return;
    }
    final picked = widget.picker != null ? await widget.picker!() : await _pickFromGallery();
    if (picked.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    try {
      final token = AuthStore.instance.accessToken ?? '';
      for (final f in picked.take(6 - _images.length)) {
        final up = await uploadMedia(type: 'complaint_image', bytes: f.bytes, filename: f.name, token: token);
        if (!mounted) return;
        setState(() {
          _images.add(f);
          _mediaIds.add(up.id);
        });
      }
    } catch (e) {
      if (mounted) AppToast.error(context, '截图上传失败，请重试');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<List<PickedImage>> _pickFromGallery() async {
    final list = await ImagePicker().pickMultiImage(limit: 6 - _images.length, maxWidth: 1600, imageQuality: 82);
    final out = <PickedImage>[];
    for (final f in list) {
      out.add(PickedImage(f.name, Uint8List.fromList(await f.readAsBytes())));
    }
    return out;
  }

  void _removeImage(int index) {
    setState(() {
      _images.removeAt(index);
      if (index < _mediaIds.length) _mediaIds.removeAt(index);
    });
  }

  /// 表单错误（行内红字 + 按钮上方汇总条）
  ///
  /// 用 ValueNotifier：本页表单是「chip 直改状态」的写法，不便在构建里 setState，
  /// notifier 驱动 `AppFieldError` / `AppFormErrorSummary` 自己重建。
  final ValueNotifier<FormErrors> _errs = ValueNotifier(FormErrors());

  Future<void> _submit() async {
    final content = _content.text.trim();
    _errs.value.clear();
    // 本地必填校验 → 行内红字（与服务端 message 同一套呈现，不再弹黑色浮条）
    if (content.length < 5) _errs.value.set('content', '请把问题描述清楚（至少 5 个字）');
    if (_targetType != 'service' && (_targetId == null || _targetId!.isEmpty)) {
      _errs.value.set('targetId', _targetType == 'order' ? '请选择要投诉的订单' : '请选择要投诉的打手');
    }
    if (_errs.value.isNotEmpty) return;
    setState(() => _submitting = true);
    try {
      await _api.request('POST', '/user/complaints',
          token: AuthStore.instance.accessToken,
          data: {
            'targetType': _targetType,
            'targetId': _targetId ?? '',
            'type': _type,
            'content': content,
            'mediaIds': _mediaIds,
          });
      if (!mounted) return;
      AppToast.success(context, '投诉已提交，客服会在站内通知里回复你');
      setState(() {
        _content.clear();
        _images.clear();
        _mediaIds.clear();
        _targetId = null;
        _submitting = false;
        _tab = 1;
      });
      await _load(force: true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // 服务端 fields[] → 对应字段下方红字；定位不到字段的通用失败才用浮层
      if (!_errs.value.bindApiException(e, aliases: const {
        'content': 'content',
        'type': 'type',
        'targetId': 'targetId',
        'targetType': 'targetType',
        'mediaIds': 'mediaIds',
      })) {
        // 【2026-10-05 任务②③】服务端权威拒绝（"该订单当前状态不可投诉" /
        // "该打手没有接过你的订单，无法投诉"）此前**只弹 2 秒浮条**：
        // 用户在表单中部操作时浮条在顶部一闪而过，截图与复盘都留不下证据，
        // 下拉里也看不出"为什么刚才能选、现在提交不了"。这里同时落到
        // **表单汇总条**（按钮上方，跟着按钮走、不自动消失），浮条仍保留做即时反馈。
        _errs.value.setSummary(e.message);
        setState(() {});
        AppToast.error(context, e.message);
      } else {
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => Scaffold(
        backgroundColor: T.scaffoldColor,
        appBar: AppBar(
          backgroundColor: T.bgCardSolid,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 16,
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('投诉', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: T.textPrimary)),
              const SizedBox(width: 8),
              Text('客服核实后会在站内通知里回复', style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            ],
          ),
        ),
        body: Column(
          children: [
            AppSegmented(items: const ['提交投诉', '我的投诉'], current: _tab, onChanged: _switchTab),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _load(force: true),
                child: _tab == 0 ? _form() : _list(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 表单 ----------------

  Widget _form() {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
      children: [
        _label('投诉对象'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in _targetOptions)
              _chip(o[1], _targetType == o[0], () {
                setState(() {
                  _targetType = o[0];
                  _targetId = null;
                  // 切到「打手」时沿用已选订单（最严口径：针对订单投诉只能选该单接单人）；
                  // 切回「订单」或选「客服」则解除收敛，回到"曾接过我单的打手"全量。
                  _workerFilterOrderId = o[0] == 'worker' ? _workerFilterOrderId : null;
                });
                if (o[0] == 'worker') _loadWorkersForOrder(_workerFilterOrderId);
              }),
          ],
        ),
        const SizedBox(height: 12),
        if (_targetType == 'order') _orderPicker(),
        if (_targetType == 'worker') _workerPicker(),
        AppFieldError(_errs, 'targetId'),
        if (_targetType == 'service')
          Text('客服投诉由值班客服认领处理，不需要选择具体对象。', style: TextStyle(fontSize: 11.5, color: T.mutedText)),
        const SizedBox(height: 16),
        _label('投诉类型'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final t in _typeOptions) _chip(t[1], _type == t[0], () => setState(() => _type = t[0]))],
        ),
        const SizedBox(height: 16),
        _label('问题描述'),
        TextField(
          controller: _content,
          maxLines: 5,
          maxLength: 500,
          onChanged: (v) {
            // 用户开始改内容就把红字撤掉（避免旧错误一直挂着）
            if (_errs.value.errorOf('content') != null) _errs.value.clearField('content');
          },
          style: TextStyle(fontSize: 13.5, color: T.textPrimary),
          decoration: InputDecoration(
            hintText: '写清楚时间、发生了什么、你的诉求（例如：20:30 开始服务后打手挂机 15 分钟）',
            hintStyle: TextStyle(fontSize: 12.5, color: T.textTertiary),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            counterStyle: TextStyle(fontSize: 10, color: T.mutedText),
          ),
        ),
        AppFieldError(_errs, 'content', padding: const EdgeInsets.only(top: 2, left: 2)),
        const SizedBox(height: 4),
        _label('截图（可选，最多 6 张）'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _images.length; i++) _thumb(i),
            if (_images.length < 6)
              GestureDetector(
                onTap: _uploading ? null : _pickImages,
                child: Container(
                  width: 72,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: T.bgCardSolid,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: T.divider),
                  ),
                  child: _uploading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : AppIcon.of(AppIcon.camera, size: 22, color: T.textTertiary),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        // 汇总提示（按钮上方）+ 提交按钮：服务端 fields[] 落到对应输入框下方红字，这里给整体还需修正什么
        AppFormErrorFooter(
          errors: _errs,
          submit: AppButton(label: _submitting ? '提交中…' : '提交投诉', onPressed: _submitting ? null : _submit),
        ),
        const SizedBox(height: 10),
        Text('恶意投诉会被记录；截图仅你本人与客服可见。',
            style: TextStyle(fontSize: 10.5, color: T.mutedText, height: 1.5)),
      ],
    );
  }

  Widget _orderPicker() {
    if (_orderOptions.isEmpty) {
      return Text('暂无可投诉的订单', style: TextStyle(fontSize: 12, color: T.mutedText));
    }
    return _dropdown<String>(
      hint: '选择订单',
      value: _targetId != null && _orderOptions.any((o) => o.id == _targetId) ? _targetId : null,
      items: [
        for (final o in _orderOptions)
          DropdownMenuItem(
            value: o.id,
            child: Text('${o.title} · ${o.orderNo}',
                // 投诉要先认单：商品名 + 订单号（15 字符定长）→ 放宽到 2 行；
                // 不再往 3 行放（下拉项过高会遮挡相邻项），必要时订单号仍可完整辨认
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(height: 1.35)),
          ),
      ],
      onChanged: (v) {
        // 【任务③】选了订单 → 打手候选收敛为该订单的接单打手（服务端 `?orderId=` 重查）
        setState(() {
          _targetId = v;
          _workerFilterOrderId = v;
        });
        _loadWorkersForOrder(v);
      },
    );
  }

  Widget _workerPicker() {
    if (_workerOptions.isEmpty) {
      // 【任务③】空名单的两种原因分开说清楚，避免用户以为是加载失败
      final text =
          _workerFilterOrderId != null ? '该订单没有可投诉的打手' : '还没有打手接过你的订单';
      return Text(text, style: TextStyle(fontSize: 12, color: T.mutedText));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dropdown<String>(
          hint: '选择打手',
          value: _targetId != null && _workerOptions.any((w) => w.id == _targetId) ? _targetId : null,
          items: [
            for (final w in _workerOptions)
              DropdownMenuItem(
                value: w.id,
                child: Text(
                  // 同名打手靠工号/最近一单区分（不改展示极简规则：列表里本来就只有名字，这里是选择器）
                  w.workerNo.isEmpty ? w.name : '${w.name} · ${w.workerNo}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _targetId = v),
        ),
        const SizedBox(height: 6),
        Text(
          _workerFilterOrderId == null
              ? '只列出接过你订单的打手（共 ${_workerOptions.length} 位）'
              : '已选定订单，只可选该订单的接单打手',
          style: TextStyle(fontSize: 10.5, color: T.mutedText),
        ),
      ],
    );
  }

  Widget _dropdown<V>({
    required String hint,
    required V? value,
    required List<DropdownMenuItem<V>> items,
    required ValueChanged<V?> onChanged,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: T.bgCardSolid,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.divider),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<V>(
            value: value,
            isExpanded: true,
            hint: Text(hint, style: TextStyle(fontSize: 12.5, color: T.textTertiary)),
            icon: AppIcon.of(AppIcon.chevronDown, size: 18, color: T.textTertiary),
            style: TextStyle(fontSize: 12.5, color: T.textPrimary),
            items: items,
            onChanged: onChanged,
          ),
        ),
      );

  /// 截图缩略图（**受保护媒体** `complaint_image`）。
  ///
  /// 【2026-10-07 修「投诉截图不显示」】原来是
  /// `Image.network(AppConfig.resolveMediaUrl('/media/protected/$id'), headers: {...})`：
  /// ① **路径少了全局前缀** —— 真实路由是 `/api/v1/media/protected/:id`
  ///   （`main.ts` 的 `setGlobalPrefix` 只排除 `media/public/*`），`/media/protected/:id` 实测 404；
  /// ② 走的是 `Image.network`（无磁盘缓存、失败只能画一个灰块）。
  /// 现在 ① 路径走 [AppConfig.protectedMediaUrl]、② 令牌走共用的 [authImageHeaders]、
  /// ③ 改用 [CachedNetImage]（磁盘缓存 + **失败原因 + 重试**，与聊天图片/付款凭证同一套）。
  Widget _thumb(int i) {
    final id = i < _mediaIds.length ? _mediaIds[i] : null;
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        children: [
          ComplaintImageBox(mediaId: id),
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              onTap: () => _removeImage(i),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Color(0xCC0B1220),
                  borderRadius: BorderRadius.only(bottomLeft: Radius.circular(6)),
                ),
                child: const AppIcon.of(AppIcon.close, size: 13, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? T.primary : T.bgCardSolid,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? T.primary : T.divider),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected ? Colors.white : T.textSecondary,
              )),
        ),
      );

  // ---------------- 我的投诉 ----------------

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [AppEmpty(icon: AppIcon.info, text: '加载失败：$_error', action: '重试', onAction: _load)],
      );
    }
    if (_complaints.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [AppEmpty(icon: AppIcon.shield, text: '还没有投诉记录\n遇到服务问题可以在这里提交，客服会核实')],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      itemCount: _complaints.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _complaintCard(_complaints[i]),
    );
  }

  Widget _complaintCard(_MyComplaint c) => AppCard(
        radius: 10,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${_targetLabel(c.targetType)} · ${_typeLabel(c.type)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: T.textPrimary)),
                ),
                AppTag(_statusLabel(c.status), color: _statusColor(c.status)),
              ],
            ),
            const SizedBox(height: 6),
            Text('${c.complaintNo}${c.targetName.isEmpty ? '' : ' · ${c.targetName}'} · ${_timeText(c.createdAt)}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: T.mutedText)),
            const SizedBox(height: 8),
            Text(c.content, style: TextStyle(fontSize: 11.5, color: T.textSecondary, height: 1.6)),
            /**
             * 【2026-10-07 补】投诉记录里的**截图**（`mediaIds`，受保护媒体 `complaint_image`）。
             *
             * 此前这里只显示文字，用户提交完就再也看不到自己上传的截图 —— 而"我当时传了哪张图"
             * 恰恰是投诉双方对账时最需要确认的东西（提交页的缩略图一提交就没了）。
             * 复用 [ComplaintImageBox]（与表单缩略图**同一份实现**），因此路径/令牌/失败态一致。
             */
            if (c.mediaIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final id in c.mediaIds) ComplaintImageBox(mediaId: id)],
              ),
            ],
            if (c.handleRemark.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(color: T.bgPage, borderRadius: BorderRadius.circular(6)),
                child: Text('处理结果：${c.handleRemark}',
                    style: TextStyle(fontSize: 11.5, color: T.textSecondary, height: 1.5)),
              ),
            ],
          ],
        ),
      );

  static String _targetLabel(String t) => switch (t) {
        'order' => '投诉订单',
        'worker' => '投诉打手',
        'service' => '投诉客服',
        _ => '投诉',
      };

  static String _typeLabel(String t) => switch (t) {
        'attitude' => '服务态度',
        'not_agreed' => '未按约定',
        'delay' => '恶意拖延',
        _ => '其它',
      };

  static String _statusLabel(String s) => switch (s) {
        'pending' => '待处理',
        'processing' => '处理中',
        'handled' => '已处理',
        'rejected' => '未通过',
        _ => s,
      };

  static Color _statusColor(String s) => switch (s) {
        'pending' => T.warning,
        'processing' => T.primary,
        'handled' => T.success,
        _ => T.textTertiary,
      };

  static String _timeText(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final l = t.toLocal();
    return '${l.month}月${l.day}日 ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

class _OrderOption {
  _OrderOption({required this.id, required this.orderNo, required this.title, required this.status});

  final String id;
  final String orderNo;
  final String title;

  /// 订单状态（服务端下发。投诉页**不自行判定能否投诉**：能进这个列表就已经由服务端
  /// 按 `complaintableOrderStatusQuery()` 过滤过；此字段只用于下拉里的状态提示）
  final String status;

  factory _OrderOption.fromJson(Map json) => _OrderOption(
        id: '${json['id']}',
        orderNo: '${json['orderNo'] ?? ''}',
        title: '${json['productName'] ?? json['orderNo'] ?? '订单'}',
        status: '${json['status'] ?? ''}',
      );
}

class _WorkerOption {
  _WorkerOption({required this.id, required this.name, this.workerNo = '', this.lastOrderNo = '', this.orderCount = 0});

  final String id;
  final String name;

  /// 工号（同名打手区分用；列表展示规则不变，仅选择器里带上）
  final String workerNo;

  /// 该打手最近一次为我服务的订单号（服务端 `workerTargets` 下发）
  final String lastOrderNo;

  /// 为我服务过的订单数
  final int orderCount;

  factory _WorkerOption.fromJson(Map json) => _WorkerOption(
        // 服务端 `/user/complaints/targets/workers` 固定下发 workerId（= worker 表主键，
        // 与 order.worker_id、投诉提交的 targetId 同一口径）
        id: '${json['workerId'] ?? json['id'] ?? ''}',
        name: (json['nickname'] as String?)?.trim().isNotEmpty == true ? json['nickname'] as String : '打手',
        workerNo: '${json['workerNo'] ?? ''}',
        lastOrderNo: '${json['lastOrderNo'] ?? ''}',
        orderCount: (json['orderCount'] as num?)?.toInt() ?? 0,
      );
}

class _MyComplaint {
  _MyComplaint({
    required this.complaintNo,
    required this.targetType,
    required this.targetName,
    required this.type,
    required this.content,
    required this.mediaIds,
    required this.status,
    required this.handleRemark,
    required this.createdAt,
  });

  final String complaintNo;
  final String targetType;
  final String targetName;
  final String type;
  final String content;
  final List<String> mediaIds;
  final String status;
  final String handleRemark;
  final String createdAt;

  factory _MyComplaint.fromJson(Map json) => _MyComplaint(
        complaintNo: '${json['complaintNo'] ?? ''}',
        targetType: '${json['targetType'] ?? ''}',
        targetName: '${json['targetName'] ?? ''}',
        type: '${json['type'] ?? ''}',
        content: '${json['content'] ?? ''}',
        mediaIds: ((json['mediaIds'] as List?) ?? const []).map((e) => '$e').toList(),
        status: '${json['status'] ?? ''}',
        handleRemark: '${json['handleRemark'] ?? ''}',
        createdAt: '${json['createdAt'] ?? ''}',
      );
}

/// 投诉截图（**受保护媒体** `complaint_image`）的图片位 —— 表单里的 72dp 缩略图与
/// 「我的投诉」详情里的截图共用**同一份实现**（改一处即可，不会两边各写一套再分叉）。
///
/// 【2026-10-07 修「投诉截图不显示」】旧写法有两个错，**同时存在才导致图永远出不来**：
/// ① `AppConfig.resolveMediaUrl('/media/protected/$id')` —— **少了全局前缀**：
///    受保护媒体的真实路由是 `/api/v1/media/protected/:id`
///    （`main.ts` 的 `setGlobalPrefix` 只排除 `media/public/*`），实测 `/media/protected/:id` → 404；
/// ② 用裸 `Image.network`（无磁盘缓存；失败只画一个灰块，说不出原因，也没有下一步）。
/// 现在：路径走 [AppConfig.protectedMediaUrl]（唯一出处）、令牌走 [authImageHeaders]
/// （按**当前身份**取 primary/companion/recharge）、渲染走 [CachedNetImage]
/// （磁盘缓存 + 失败原因 + 「重试」）。
class ComplaintImageBox extends StatelessWidget {
  const ComplaintImageBox({super.key, required this.mediaId, this.size = 72});

  /// 媒体 id；null/空 → 占位底色（还没有图）
  final String? mediaId;

  /// 边长（表单缩略图 72；详情可放大）
  final double size;

  /// 失败态的语义标签（出图/测试断言"没出来时可点重试"）
  static const String failedSemanticsLabel = '投诉截图加载失败，点按重试';

  @override
  Widget build(BuildContext context) {
    final String id = (mediaId ?? '').trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: id.isEmpty
          ? Container(width: size, height: size, color: T.bgPage)
          : CachedNetImage(
              url: AppConfig.protectedMediaUrl(id),
              headers: authImageHeaders(AuthStore.instance.activeToken),
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: Container(width: size, height: size, color: T.bgPage),
              // 小格子塞不下文字 → compact 只给红线图标，**整格可点即重试**
              errorBuilder: (_, failure, retry) =>
                  ImageLoadError(failure: failure, onRetry: retry, compact: true),
            ),
    );
  }
}
