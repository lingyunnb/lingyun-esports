import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../icons/app_icon.dart';
import '../theme/app_colors.dart';

/// ============ 表单错误呈现（负责人 2026-10-04：底部黑色弹窗改协调） ============
///
/// 背景：服务端校验失败时，页面此前用系统默认黑色 `SnackBar` 把 message 原样弹出来，
/// 与青蓝主题完全脱节（负责人："把下面的弹窗改得更协调一点"）。
///
/// 现在统一两种呈现（docs/21 反 AI 味：不用纯黑浮层、不做装饰、文案具体可验证）：
/// 1. **行内错误（首选）**：服务端返回 `fields[]` 时，把中文错误落到**对应输入框下方**
///    红色小字（#DC2626 / 11.5px），并在按钮上方保留一条汇总提示；
/// 2. **浮层兜底**：定位不到字段的通用失败（网络异常、服务端 500、"账号或密码错误"）
///    走 `AppToast.error`（品牌化浮层 + 淡入 + 自动消失），不再是黑色 SnackBar。
///
/// 用法：
/// ```dart
/// final _errs = FormErrors();
/// ...
/// } on ApiException catch (e) {
///   if (!_errs.bindApiException(e)) AppToast.error(context, e.message);
/// }
/// ...
/// AppFieldError(_errs, 'username'),
/// ...
/// AppFormErrorFooter(errors: _errs, submit: AppButton(label: '登录', onPressed: _submit)),
/// ```

/// 字段名 → 中文标签（客户端兜底用：服务端未给 label，或旧服务端只给英文 message）
///
/// 与服务端 `server/src/common/pipes/validation-messages.ts` 的 FIELD_LABELS 同源；
/// 查不到时回退字段名本身（绝不抛错）。
const Map<String, String> kFieldLabels = {
  'username': '账号',
  'account': '账号',
  'password': '密码',
  'oldPassword': '原密码',
  'newPassword': '新密码',
  'confirmPassword': '确认密码',
  'refreshToken': '登录凭证',
  'token': '登录凭证',
  'uid': '用户ID',
  'userId': '用户ID',
  'nickname': '昵称',
  'displayName': '展示名称',
  'realName': '真实姓名',
  'phone': '手机号',
  'contactPhone': '联系电话',
  'code': '验证码',
  // 邮箱验证码（2026-10-05 邮箱通道）：标签与服务端 validation-messages.ts 的
  // FIELD_LABELS 逐字一致（email: '邮箱' / emailCode: '邮箱验证码'），
  // 否则汇总条会出现「emailCode还需修改」这种半英文字段名。
  'email': '邮箱',
  'emailCode': '邮箱验证码',
  'role': '角色',
  'price': '价格',
  'amount': '金额',
  'quantity': '数量',
  'qty': '数量',
  'orderId': '订单',
  'orderNo': '订单号',
  'idempotencyKey': '幂等键',
  'content': '内容',
  'title': '标题',
  'subtitle': '副标题',
  'summary': '简介',
  'description': '描述',
  'detail': '详情',
  'name': '名称',
  'value': '取值',
  'text': '文本',
  'remark': '备注',
  'reason': '原因',
  'handlerRemark': '处理意见',
  'keyword': '关键词',
  'type': '类型',
  'status': '状态',
  'page': '页码',
  'pageSize': '每页条数',
  'sortOrder': '排序号',
  'mediaId': '媒体',
  'mediaType': '媒体类型',
  'imageMediaId': '图片',
  'avatarMediaId': '头像',
  'coverMediaId': '封面',
  'videoMediaId': '视频',
  'id': '编号',
  'gameId': '游戏',
  'categoryId': '分类',
  'productId': '商品',
  'divisionId': '分部',
  'workerId': '打手',
  'designatedWorkerId': '指定打手',
  'contact': '联系方式',
  'images': '图片',
  'mediaIds': '媒体',
  'targetId': '投诉对象',
  'targetType': '投诉对象类型',
  'complaintType': '投诉类型',
  'duration': '时长',
};

/// 取字段中文标签（未收录 → 字段名本身）
String labelOfField(String field) {
  if (field.isEmpty) return '参数';
  // 嵌套路径（items.0.mediaId）→ 取叶子
  final segs = field.split('.').where((s) => s.isNotEmpty && int.tryParse(s) == null).toList();
  if (segs.isEmpty) return '参数';
  return kFieldLabels[segs.last] ?? kFieldLabels[segs.join('.')] ?? segs.last;
}

/// 校验类英文文案特征（客户端兜底：万一服务端仍是旧版，也不让英文露到界面）
final RegExp _englishValidation = RegExp(
  r'must be|should not|should be|property |longer than|shorter than|regular expression|'
  r'one of the following|not exist|must not|must contain|must match',
  caseSensitive: false,
);

/// 是否含中日韩汉字
bool _hasChinese(String s) => RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]').hasMatch(s);

/// 英文校验文案 → 中文（与服务端规则同源的**客户端兜底**，仅用于旧服务端/异常路径）
String localizeValidationMessage(String raw, String label) {
  final text = raw.trim();
  if (text.isEmpty) return '「$label」填写有误';
  if (_hasChinese(text)) return text;

  // 去掉开头的 `username ` 前缀（class-validator 默认消息以属性名开头）
  final body = text.replaceFirst(RegExp(r'^\S+\s+'), '');
  final target = _hasChinese(body) ? body : text;

  if (RegExp(r'^property\s+.+\s+should\s+not\s+exist$', caseSensitive: false).hasMatch(target)) {
    final name = RegExp(r'^property\s+(.+?)\s+should', caseSensitive: false).firstMatch(target)?.group(1) ?? '';
    return '不支持字段 ${labelOfField(name)}';
  }
  if (RegExp(r'one of the following values', caseSensitive: false).hasMatch(target)) {
    final list = RegExp(r'values\s*:\s*(.+)$', caseSensitive: false).firstMatch(target)?.group(1) ?? '';
    final items = list.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    return items.isEmpty ? '「$label」取值不在允许范围内' : '只能是：${items.join('、')}';
  }
  final low = RegExp(r'longer than or equal to\s+(\d+)', caseSensitive: false).firstMatch(target);
  final up = RegExp(r'shorter than or equal to\s+(\d+)', caseSensitive: false).firstMatch(target);
  final chars = RegExp(r'characters?', caseSensitive: false).hasMatch(target);
  if (low != null || up != null || chars) {
    if (low != null && up != null) return '长度需为 ${low.group(1)}-${up.group(1)} 个字符';
    if (low != null) {
      final n = int.tryParse(low.group(1)!) ?? 0;
      return n <= 1 ? '不能为空' : (chars ? '至少 $n 个字符' : '至少 $n');
    }
    if (up != null) return chars ? '最多 ${up.group(1)} 个字符' : '最多 ${up.group(1)}';
  }
  if (RegExp(r'should not be empty|must not be empty', caseSensitive: false).hasMatch(target)) return '不能为空';
  if (RegExp(r'must be an email', caseSensitive: false).hasMatch(target)) return '邮箱格式不正确';
  if (RegExp(r'must be an integer', caseSensitive: false).hasMatch(target)) return '必须是整数';
  if (RegExp(r'must be a number|number conforming|must be a numeric', caseSensitive: false).hasMatch(target)) {
    return '必须是数字';
  }
  final minHit = RegExp(r'not be less than\s+(-?\d+)', caseSensitive: false).firstMatch(target);
  if (minHit != null) return '不能小于 ${minHit.group(1)}';
  final maxHit = RegExp(r'not be greater than\s+(-?\d+)', caseSensitive: false).firstMatch(target);
  if (maxHit != null) return '不能大于 ${maxHit.group(1)}';
  if (RegExp(r'regular expression|must match|must be a', caseSensitive: false).hasMatch(target)) return '格式不正确';
  return '「$label」填写有误';
}

/// 文案是否需要中文化（含英文校验特征且不含中文）
bool isEnglishValidationMessage(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return false;
  if (_hasChinese(t)) return false;
  return _englishValidation.hasMatch(t);
}

/// 表单错误状态（页面持有一个，setState 驱动输入框下方红字与汇总条）
///
/// 只做**呈现层**状态，不碰业务逻辑与状态机。
class FormErrors {
  final Map<String, FieldError> _map = {};
  List<String> _summary = const [];

  /// 「定位不到输入框」的整体错误（服务端未知字段等）—— 与字段红字一起进汇总条
  final List<String> _unmapped = [];

  /// 字段 → 错误（key 为**页面输入框对应的字段名**，如 `username`）
  Map<String, FieldError> get fields => Map.unmodifiable(_map);

  /// 按钮/表单顶部的汇总提示（多条，已去重且已中文化）
  List<String> get summaryLines => List.unmodifiable(_summary);

  /// 是否没有任何错误
  bool get isEmpty => _map.isEmpty && _summary.isEmpty;

  /// 是否还有未解决的错误
  bool get isNotEmpty => !isEmpty;

  /// 被输入框下方红字标出的字段数（汇总条文案据此生成）
  int get fieldErrorCount => _map.length;

  /// 出错字段的中文标签（按声明顺序）
  List<String> get fieldErrorLabels => _map.values.map((f) => f.label).toList(growable: false);

  /// 取某字段的错误（未设置 → null）
  FieldError? errorOf(String field) => _map[field];

  /// 取某字段的中文错误文案（未设置 → null）
  String? messageOf(String field) => _map[field]?.message;

  /// 设置单字段错误（本地校验用）
  ///
  /// 行内红字是主呈现（在出错的输入框下方）；汇总条给一句**指路**文案
  /// （「账号、密码还需修改」），不重复红字原文 —— 同一句话在按钮上方再写一遍是纯噪音。
  void set(String field, String message, {String? label}) {
    if (field.isEmpty || message.isEmpty) return;
    _map[field] = FieldError(field: field, label: label ?? labelOfField(field), message: message);
    _refreshSummary();
  }

  /// 重算汇总条（每次字段错误变化后调用，避免旧文案残留）
  void _refreshSummary() => _summary = _normalizeSummary([_summaryLine(), ..._unmapped]);

  /// 只能进汇总条的整体错误（没有对应输入框可标红）
  ///
  /// 用在**服务端权威拒绝**上：如投诉页的「该订单当前状态不可投诉」「该打手没有接过你的订单」。
  /// 这类文案原先只走 2 秒浮条 —— 用户在表单中部操作时顶部一闪而过，既留不下证据，
  /// 也说不清"为什么刚才能选、现在提交不了"。挂到汇总条后**跟着提交按钮一起显示、不自动消失**，
  /// 用户改完（下次提交 `clear()`）才撤。
  void setSummary(String message) {
    if (message.trim().isEmpty) return;
    _unmapped.add(message.trim());
    _refreshSummary();
  }

  /// 汇总条指路文案（字段少时报字段名，多了报数量）
  String _summaryLine() {
    if (_map.isEmpty) return '';
    final labels = fieldErrorLabels;
    return labels.length <= 2 ? '${labels.join('、')}还需修改' : '共 ${labels.length} 项填写有误';
  }

  /// 批量设置（用例构造 / 服务端 fields[]）
  void setAll(Iterable<FieldError> errors, {List<String>? summary}) {
    _map.clear();
    _unmapped
      ..clear()
      ..addAll(summary ?? const []);
    for (final e in errors) {
      if (e.field.isEmpty || e.message.isEmpty) continue;
      final label = e.label.isEmpty ? labelOfField(e.field) : e.label;
      _map[e.field] = FieldError(field: e.field, label: label, message: localizeValidationMessage(e.message, label));
    }
    _refreshSummary();
  }

  /// 清空全部（每次提交前 / 页面初始化）
  void clear() {
    _map.clear();
    _unmapped.clear();
    _summary = const [];
  }

  /// 只清某个字段（输入框 onChanged 时调用：用户改了就先撤掉红字）
  void clearField(String field) {
    _map.remove(field);
    _refreshSummary();
  }

  /// 绑定服务端异常。
  ///
  /// @return true = 已用行内/汇总呈现（调用方**不要**再弹浮层）；
  ///         false = 定位不到任何字段（网络异常、账号密码错误等）→ 调用方走 `AppToast.error`。
  bool bindApiException(ApiException e, {Map<String, String>? aliases}) {
    final remote = e.fields;
    if (remote.isEmpty) return false;

    _map.clear();
    _unmapped.clear();
    final unmapped = <String>[];
    for (final f in remote) {
      final key = matchFieldKey(f.field, aliases);
      final label = f.label.isEmpty ? labelOfField(f.field) : f.label;
      final message = localizeValidationMessage(f.message, label);
      if (key == null) {
        unmapped.add(message);
        continue;
      }
      _map[key] = FieldError(field: key, label: label, message: message);
    }

    if (_map.isEmpty) {
      // 一个字段都没匹配上（如服务端只报了请求体里多带的未知字段）→ 交给浮层
      return false;
    }
    // 汇总条只承载「红字说不清的整体问题」（未知字段原文）；已标红的字段改为指路文案，
    // 避免同一句中文在输入框下方与按钮上方各写一遍。
    _unmapped.addAll(unmapped);
    _refreshSummary();
    return true;
  }

  /// 服务端字段名 → 页面输入框键
  ///
  /// 匹配顺序：显式别名 → 叶子名（`items.0.mediaId` → `mediaId`）→ 别名表反查。
  String? matchFieldKey(String serverField, Map<String, String>? aliases) {
    if (serverField.isEmpty) return null;
    final direct = aliases?[serverField];
    if (direct != null && direct.isNotEmpty) return direct;
    final segs = serverField.split('.').where((s) => s.isNotEmpty && int.tryParse(s) == null).toList();
    if (segs.isEmpty) return null;
    final joined = segs.join('.');
    if (aliases != null) {
      for (final entry in aliases.entries) {
        if (entry.key == joined || entry.key == segs.last) return entry.value;
      }
      if (aliases.containsKey('*')) return aliases['*'];
    }
    return segs.last;
  }

  List<String> _normalizeSummary(Iterable<String> lines) {
    final out = <String>[];
    for (final l in lines) {
      // 【2026-10-10 修「幽灵红条」】空行必须**先**跳过：
      // `_refreshSummary` 的第一项是 `_summaryLine()`，字段错误清空后它返回 `''`，
      // 而下面的 `localizeValidationMessage('', '参数')` 会把空串兜底成「「参数」填写有误」
      // （它的 `if (text.isEmpty)` 分支是给"服务端只给字段名没给文案"用的，不是给空行用的）。
      // 结果：用户在表单里把红字改对（`clearField`）之后，按钮上方反而冒出一条
      // 「「参数」填写有误」——本轮邮箱绑定页出图自查时抓到（截图里那条无来源的红条）。
      if (l.trim().isEmpty) continue;
      final t = localizeValidationMessage(l, '参数');
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }
}

/// 输入框下方的行内错误（红色小字 #DC2626 / 11.5px）
///
/// 没有错误时**不占位**（返回 `SizedBox.shrink()`），页面间距不跳动。
class AppFieldError extends StatelessWidget {
  const AppFieldError(this.errors, this.field, {super.key, this.padding = const EdgeInsets.only(top: 6, left: 2)});

  /// 既接受普通 [FormErrors]（页面靠 setState 重建），
  /// 也接受 [ValueNotifier]<[FormErrors]>（弹层等不便 setState 的场景由 notifier 驱动重建）
  final Object errors;

  /// 输入框对应的字段名（与服务端 fields[].field 同源）
  final String field;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final source = errors;
    if (source is ValueNotifier<FormErrors>) {
      return ValueListenableBuilder<FormErrors>(
        valueListenable: source,
        builder: (_, value, _) => _build(value),
      );
    }
    return _build(source is FormErrors ? source : FormErrors());
  }

  Widget _build(FormErrors errors) {
    final message = errors.messageOf(field);
    if (message == null || message.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1.5),
            child: AppIcon.of(AppIconsLegacy.error_outline_rounded, size: 12, color: AppColors.error),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                fontWeight: FontWeight.w500,
                color: AppColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 按钮上方的汇总提示（浅红底，一行一条，组内紧）
///
/// 与行内错误同时存在：行内负责"哪一格错了"，汇总负责"整体还差什么"。
class AppFormErrorSummary extends StatefulWidget {
  const AppFormErrorSummary(this.errors, {super.key, this.padding = const EdgeInsets.only(bottom: 10)});

  /// 同 [AppFieldError]：接受 [FormErrors] 或 [ValueNotifier]<[FormErrors]>
  final Object errors;
  final EdgeInsetsGeometry padding;

  @override
  State<AppFormErrorSummary> createState() => _AppFormErrorSummaryState();
}

class _AppFormErrorSummaryState extends State<AppFormErrorSummary> {
  ValueNotifier<FormErrors>? _notifier;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant AppFormErrorSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.errors != widget.errors) {
      _notifier?.removeListener(_onChange);
      _bind();
    }
  }

  void _bind() {
    final source = widget.errors;
    if (source is ValueNotifier<FormErrors>) {
      _notifier = source..addListener(_onChange);
    } else {
      _notifier = null;
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _notifier?.removeListener(_onChange);
    super.dispose();
  }

  FormErrors get _errors {
    final source = widget.errors;
    return source is FormErrors ? source : (_notifier?.value ?? FormErrors());
  }

  @override
  Widget build(BuildContext context) {
    final errors = _errors;
    final lines = errors.summaryLines;
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: widget.padding,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: AppColors.categorySoft(AppColors.error),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.categoryBorder(AppColors.error), width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1.5),
                    child: AppIcon.of(AppIconsLegacy.error_outline_rounded, size: 12, color: AppColors.error),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      lines[i],
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: AppColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 表单「汇总提示 + 提交按钮」统一封装（各表单页间距一致）
class AppFormErrorFooter extends StatelessWidget {
  const AppFormErrorFooter({super.key, required this.errors, required this.submit});

  /// 接受 [FormErrors] 或 [ValueNotifier]<[FormErrors]>
  final Object errors;
  final Widget submit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFormErrorSummary(errors),
        submit,
      ],
    );
  }
}
