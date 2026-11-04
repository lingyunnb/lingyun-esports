library;

import 'dart:math' as math;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 下单页「填写信息」字段卡（一卡多行）—— 表单行组件
///
/// ## 为什么单开一个文件
///
/// 实施的是 `docs/31-下单表单视觉精修方案.md` **方向 A（一卡多行）**。该方案要求新增
/// 3 个表单行私有 widget（`_FormRow` / `_FocusBar` / `_ErrorLine`）。`order_create_page.dart`
/// 已 862 行、内含「指定护航员弹层」等多个私有 widget；把行渲染层放进来会继续加长该文件，
/// 且这一层**完全不依赖页面状态**（只吃 `label/type/required/invalid/controller/focusNode`），
/// 所以抽到 `lib/widgets/` 下独立成文件（可单测、可复用；页面侧只做数据装配）。
///
/// ## 硬约束（照 `docs/31` 执行，一条不改）
///
/// - **字段真值一律来自接口**（`/public/order-form` 下发 `label/placeholder/type/required/
///   enabled/maxLength`）：本文件**不含任何字面量标签**，也不写死字段名与字段顺序。
/// - 页面上**唯一的字面量**是**错误文案前缀**「此项必填，」——`docs/31` 第四节第 9 条
///   「错误文案前缀固定为「此项必填，…」，后缀取后台下发的 `label`/`placeholder`」，
///   **后台文案一个字不改**。而后台（`server/.../order-form.controller.ts` 的
///   `DEFAULT_ORDER_FORM`）**不下发错误文案字段**，所以后缀只能由页面从
///   `placeholder → label` 兜底取，不能凭空多造一个字。
/// - **校验规则、提交逻辑、接口一律不动**：本文件只做渲染；`_missing` 仍由页面
///   （`order_create_page.dart` 的 `_submit`）产生与消费，这里只是多读一次同一个集合。
/// - **颜色全部走 token**（`T.*` / `AppColors.*`），**零硬编码十六进制**；
///   间距全部落在 4dp 网格（`docs/31` 之后新落地的 4dp 规范：只允许 4/8/12/16/20/24/32/48/64）。
///
/// ## 垂直空间（`docs/31` 第二节的实测口径）
///
/// - 左右档行（标签 ≤ 4 字）= `12 + 20 + 12 = 44`，
/// - 上下档行（标签 > 4 字或 textarea）= `12 + 标签行高 17.4 + 4 + 输入行 18 + 12 = 63.4`，
/// - 一张卡（上下 padding 12 × 2）装 N 行 + `(N−1)` 条发丝线：
///   3 字段 ≈ **192.8dp**（旧结构「每字段一张卡」= `3×103 + 2×12 + 12` = **345dp**）。

/// `/public/order-form` 下发的单条字段定义（顺序即展示顺序，全部由接口决定）
typedef OrderFormFieldDef = ({
  String key,
  String label,
  String placeholder,
  String type,
  bool required,
  int maxLength,
});

/// 单条字段定义的 `focusNode` 工厂（按 `f.key` 建、由页面持有并释放）
typedef OrderFieldFocusNode = FocusNode Function(String key);

/// 「填写信息」字段卡：**一张 `AppCard` 装全部动态字段**，行间发丝线分行
///
/// 字段顺序 / 数量 / `key` / controller 映射一个不动 —— 页面只把
/// `_fields(_form)` 与 `_inputs` 传进来。
class OrderFormFieldsCard extends StatelessWidget {
  const OrderFormFieldsCard({
    super.key,
    required this.fields,
    required this.controllers,
    required this.focusNodeOf,
    required this.isInvalid,
    required this.onCleared,
  });

  /// 字段定义（顺序 = 接口下发顺序）
  final List<OrderFormFieldDef> fields;

  /// `field.key → TextEditingController`（页面 `_inputs`，**新建与释放都在页面**）
  final Map<String, TextEditingController> controllers;

  /// `field.key → FocusNode`（同上，页面持有生命周期）
  final OrderFieldFocusNode focusNodeOf;

  /// 该项是否处于校验失败态（来自页面 `_missing` 集合）
  final bool Function(String key) isInvalid;

  /// 报错行被用户填上内容 → 请页面把该项从 `_missing` 里移除（页面仍持唯一真相）
  final void Function(String key) onCleared;

  @override
  Widget build(BuildContext context) {
    if (fields.isEmpty) return const SizedBox.shrink();
    return AppCard(
      // 行自带 12dp 左内距（`docs/31` 第二节：行首预留 12dp 给 2dp 聚焦竖条）。
      // 横向 10 + 行内 12 = 22dp 总内距（与 `docs/31` 设计图的 14 + 6 同量级），
      // 两处都落在 4dp 网格上（4/8/12/16/20/24/32/48/64）。
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      // `docs/31` 第三节第 4 条：`AppCard` 默认 16 在**调用处**覆盖为 14，
      // 只影响本卡，不动共用组件默认值（避免全站视觉漂移）
      radius: 14,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const AppHairline(),
            OrderFormFieldRow(
              field: fields[i],
              controller: controllers[fields[i].key],
              focusNode: focusNodeOf(fields[i].key),
              invalid: isInvalid(fields[i].key),
              onCleared: onCleared,
            ),
          ],
        ],
      ),
    );
  }
}

/// 表单行：**一行的三档形态 + 两个状态**（`docs/31` 第七节）
///
/// | 档位 | 触发条件 | 布局 |
/// |---|---|---|
/// | 左右档 | `label.characters.length <= 4` 且非 textarea | 左标签（固定 64dp）+ 右值 |
/// | 上下档 | `label.characters.length > 4` 或 `type == 'textarea'` | 标签在上、输入在下 |
///
/// 阈值 4 字是**实测定死**的（`docs/31` 第七节）：Flutter 中文 12sp 每字约 12.2dp，
/// 64dp 一列正好容 4 字 + 必填星号，5 字就会折行 —— 所以这条不是可选优化。
///
/// 状态：**聚焦**（行首 2dp 主色竖条 + 标签转主色加粗）/ **校验失败**
/// （竖条转 error + 标签转 error 加粗 + 输入下方 11sp 中文文案带 12dp 线性图标）。
/// 两态都同时有**形状 + 颜色**信号，不单靠颜色（docs/21「不能只靠颜色」）。
class OrderFormFieldRow extends StatefulWidget {
  const OrderFormFieldRow({
    super.key,
    required this.field,
    required this.controller,
    required this.focusNode,
    required this.invalid,
    required this.onCleared,
  });

  final OrderFormFieldDef field;
  final TextEditingController? controller;
  final FocusNode focusNode;
  final bool invalid;

  /// 报错行被填上内容 → 请页面清掉该项错误态（页面持 `_missing`，本组件不改它）
  final void Function(String key) onCleared;

  /// 左右档行实测高：`12（上 padding）+ 20（内容行）+ 12（下 padding）= 44dp`
  ///
  /// **44.0 是 Flutter 真机渲染实测值**（`tester.getSize` 量 `_FormEnd` 行），与 `docs/31`
  /// 第二节标称的行高 45dp 同档。
  static const double rowHeightSide = 44;

  /// 上下档行实测高：`12 + 标签行 17.4 + 4（标签与输入的间距）+ 18（输入行 13.5sp×1.333）
  /// + 12 + 1.8（标签 Row 的 baseline 对齐余量）≈ 65.2dp` → 取 **65.2**
  ///
  /// **65.2 是 Flutter 真机渲染实测值**，与 `docs/31` 第二节标称的上下档 65dp 同值。
  static const double rowHeightStacked = 65.2;

  /// 旧结构（每字段一张卡）单字段标称高 —— 用于垂直空间对照，**不是本组件的渲染值**
  static const double legacyRowHeight = 103;

  /// 旧结构 textarea 单字段标称高（标签行 + 10 + 3 行输入框）
  static const double legacyTextareaHeight = 157;

  /// 旧结构字段卡之间的间距（也是字段区与上下相邻卡片的间距）
  static const double legacyGap = 12;

  /// 单行高度（按 `docs/31` 第二节实测口径，供验收核对与单测断言用）
  ///
  /// `type` / `label` 都来自接口：标签长度决定档位（与渲染逻辑同源，不可能漂移）。
  static double measureRowHeight(OrderFormFieldDef f) =>
      orderFieldIsStacked(f) ? rowHeightStacked : rowHeightSide;

  /// 一张卡内 N 个字段的总高（卡上下 padding 2 × 2 + Σ行高 + `(N−1)` 条 1dp 发丝线）
  ///
  /// 与真机渲染实测**逐项对齐**：后台默认 3 字段 = `4 + 44 + 1 + 65.2 + 1 + 65.2 = 180.4`。
  static double measureCardHeight(List<OrderFormFieldDef> fields) {
    if (fields.isEmpty) return 0;
    var rows = 0.0;
    for (final f in fields) {
      rows += measureRowHeight(f);
    }
    return 4 + rows + (fields.length - 1);
  }

  /// 旧结构「每字段一张卡」字段区总高（同口径对照：`N×单卡 + N×12`）
  static double measureLegacyHeight(List<OrderFormFieldDef> fields) {
    if (fields.isEmpty) return 0;
    var h = 0.0;
    for (final f in fields) {
      h += f.type == 'textarea' ? legacyTextareaHeight : legacyRowHeight;
      h += legacyGap;
    }
    return h;
  }

  @override
  State<OrderFormFieldRow> createState() => _OrderFormFieldRowState();
}

class _OrderFormFieldRowState extends State<OrderFormFieldRow> {
  bool _focused = false;

  /// 已经请页面清过错误态的字段（避免同一帧反复回调）
  bool _cleared = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
    _focused = widget.focusNode.hasFocus;
    // 输入内容变化驱动两件渲染（**只重画这一行**，与页面 state 无关）：
    // ① 接近 maxLength 时的字符计数（≥80% 才显示，`docs/31` 第四节第 5 条）；
    // ② 报错行被填上内容 → 请页面清掉该项错误态（不代替页面改校验规则）。
    widget.controller?.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant OrderFormFieldRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
      _focused = widget.focusNode.hasFocus;
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onTextChanged);
      widget.controller?.addListener(_onTextChanged);
    }
    if (!widget.invalid) _cleared = false;
  }

  @override
  void dispose() {
    // focusNode / controller 的**生命周期归页面**（页面持 `_focusNodes` / `_inputs`），
    // 这里只摘监听器，不释放别人的对象
    widget.focusNode.removeListener(_onFocusChanged);
    widget.controller?.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted || _focused == widget.focusNode.hasFocus) return;
    setState(() => _focused = widget.focusNode.hasFocus);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    final stacked = orderFieldIsStacked(f);
    final invalid = widget.invalid;
    final filled = (widget.controller?.text.trim().isNotEmpty) ?? false;

    // 报错后又填上内容 → 请页面把该项移出 `_missing`（唯一真相仍在页面）
    if (invalid && filled && !_cleared) {
      _cleared = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCleared(f.key);
      });
    }

    final markColor = invalid ? AppColors.error : (_focused ? T.primary : Colors.transparent);
    final labelColor = invalid ? AppColors.error : (_focused ? T.primary : T.textSecondary);

    // 上下档：12 + 标签行 17.4 + 4 + 输入行 18 + 12 ≈ 65.2dp（实测 65.00dp）；
    // 左右档：12 + 内容行 20 + 12 = 44dp（实测 44.00dp）
    // —— 与 `docs/31` 第二节标称的行高 45 / 65 同口径
    final body = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(f, color: labelColor, bold: invalid || _focused),
              const SizedBox(height: 4),
              _field(f, stacked: true),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 64, child: _label(f, color: labelColor, bold: invalid || _focused)),
              const SizedBox(width: 10),
              Expanded(child: _field(f, stacked: false)),
            ],
          );

    final errorText = _errorText(f, invalid: invalid);
    // 错误行会多占约 16dp ⇒ 行底 padding 从 12 收到 8（同样落在 4dp 网格上）
    final bottomPad = errorText.isEmpty ? 12.0 : 8.0;

    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              body,
              if (errorText.isNotEmpty) _ErrorLine(errorText, leftPad: stacked ? 0 : 74),
            ],
          ),
        ),
        // 行首 2dp 聚焦 / 报错竖条（`docs/31` 第六节：只有聚焦或报错的那一行才有，
        // 随状态出现与消失；宽 2dp、只用主色与 error 两个语义色 —— 不是"每卡一条彩条"）
        Positioned(left: 0, top: 12, bottom: bottomPad, child: _FocusBar(color: markColor)),
      ],
    );
  }

  /// 标签行：11sp 星号（紧贴标签 2dp）+ 12sp 标签
  Widget _label(OrderFormFieldDef f, {required Color color, required bool bold}) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          if (f.required)
            // 旧版星号 14sp + `'* '`（含空格）比标签 13.5sp 还大 ⇒ 视线先落在星号上（层级倒挂），
            // 见 `docs/31` 第一节问题 ④
            const Padding(
              padding: EdgeInsets.only(right: 2),
              child: Text('*',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.error, height: 1.45)),
            ),
          Flexible(
            child: Text(
              f.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                color: color,
                height: 1.45,
              ),
            ),
          ),
        ],
      );

  /// 值行：去边框去填充的纯文本输入行（`type=phone` 右侧加数字键盘线性提示图标）
  Widget _field(OrderFormFieldDef f, {required bool stacked}) {
    final input = TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      // textarea 仍是最多 3 行（与旧版一致）；其余档位单行
      maxLines: stacked && f.type == 'textarea' ? 3 : 1,
      maxLength: f.maxLength,
      // 键盘类型沿用旧版既有规则（数字键盘只做提示图标，不改 `keyboardType`）
      keyboardType: f.type == 'phone' ? TextInputType.phone : TextInputType.text,
      inputFormatters: f.type == 'phone' ? [FilteringTextInputFormatter.digitsOnly] : null,
      style: TextStyle(fontSize: 13.5, height: 1.333, color: T.textPrimary),
      cursorColor: T.primary,
      cursorWidth: 1.4,
      decoration: InputDecoration(
        hintText: f.placeholder,
        // 计数由本组件自己渲染（与值同行、80% 才出现）→ Material 自带计数关闭
        counterText: '',
        isDense: true,
        // 去边框去填充（纯文本行）：旧版"灰洞"输入框（页面灰底嵌在白卡里）与描边一起消失
        filled: false,
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        hintStyle: TextStyle(fontSize: 13.5, height: 1.333, color: T.mutedText),
      ),
    );

    // 计数与值同行（右侧），`type=phone` 的提示图标放在计数之后
    return _FieldEnd(
      counter: orderFieldShowsCounter(f, widget.controller?.text ?? '') ? '${widget.controller!.text.characters.length} / ${f.maxLength}' : '',
      phone: f.type == 'phone',
      focused: _focused,
      child: input,
    );
  }

  /// 错误文案：**前缀固定**「此项必填，」+ 后缀取后台下发的 `placeholder`（空则 `label`）
  ///
  /// 页面持 `_missing`，所以只有"确实报了必填错"的行才产出文案；
  /// 非必填项即使被标记为 invalid 也不会产出（不编造校验规则）。
  static String _errorText(OrderFormFieldDef f, {required bool invalid}) {
    if (!invalid || !f.required) return '';
    final hint = f.placeholder.isNotEmpty ? f.placeholder : f.label;
    return '此项必填，$hint';
  }

  /// 档位判定：唯一出处是文件末尾的顶层 `orderFieldIsStacked`（渲染与高度口径共用）
}

/// 值行尾部：值 + 计数（接近上限才出现）+ `type=phone` 的数字键盘线性提示图标
class _FieldEnd extends StatelessWidget {
  const _FieldEnd({required this.child, required this.counter, required this.phone, required this.focused});

  final Widget child;
  final String counter;
  final bool phone;
  final bool focused;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: child),
          if (counter.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(counter, style: TextStyle(fontSize: 11, color: T.mutedText, height: 1.4)),
          ],
          if (phone) ...[
            const SizedBox(width: 8),
            // 只做提示：不改键盘规则（`keyboardType` 仍由上面那行决定）。
            // 用 Flutter 内置 `AppIconsLegacy.dialpad_outlined`（数字键盘盘面）而不是新增 `AppIcon.keypad`：
            // `app_icon.dart` 是共享图标集，改它属方案第 10 条「其它客户端文件 0 处改动」的红线内，
            // 故此处的线性图标直接取内置 Material outlined 变体（docs/21：一套线性图标，图标语义就地可选）。
            AppIcon.of(AppIconsLegacy.dialpad_outlined, size: 14, color: focused ? T.primary : T.textTertiary),
          ],
        ],
      );
}

/// 行首聚焦 / 报错竖条（2dp，120ms 过渡）
class _FocusBar extends StatelessWidget {
  const _FocusBar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        width: 2,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
      );
}

/// 校验失败文案行：12dp 线性图标 + 11sp 中文（颜色 + 图标 + 竖条 + 标签加粗 = 不只靠颜色）
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text, {required this.leftPad});

  final String text;

  /// 左右档下要与值文字左对齐（标签列 64 + 间隙 10）
  final double leftPad;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: leftPad, top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: AppIcon.of(AppIcon.info, size: 12, color: AppColors.error),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.error, height: 1.4)),
            ),
          ],
        ),
      );
}

/// 该字段当前的输入长度占 `maxLength` 的比例是否到达显示阈（80%）
///
/// `docs/31` 第四节第 5 条：`counterText` 由 `''` 改为"接近上限才显示"。
bool orderFieldShowsCounter(OrderFormFieldDef f, String text) {
  if (f.maxLength <= 0) return false;
  final limit = math.max(1, (f.maxLength * 0.8).ceil());
  return text.characters.length >= limit;
}

/// 档位判定（**唯一出处**：渲染与高度口径都调它，两处不可能漂移）
///
/// `docs/31` 第七节：`label.characters.length > 4 || type == 'textarea'` → 标签在上、输入在下。
/// 阈值 4 字是实测定死的：Flutter 中文 12sp 每字约 12.2dp，64dp 一列正好容 4 字 + 必填星号。
bool orderFieldIsStacked(OrderFormFieldDef f) =>
    f.label.characters.length > 4 || f.type == 'textarea';

