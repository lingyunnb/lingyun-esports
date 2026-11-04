/// 评价模型 + 判定文案（**唯一出口**）
///
/// ## 口径来源
///
/// 竞品（东东电竞）的真实设计已从资源字符串逆向出来（`data/temp/dd-res.txt`，可 grep 验证）：
/// ```
/// string/home_skill_order_desc = "接单%1$s次  好评率%2$s"
/// "已收到您的满意评价，感谢认可！" / "已收到您的不满意评价，平台售后正在前来的路上～"
/// "您已经评价过了哦~" / "未及时评价，评价已超时～"
/// ```
/// → 结论：**评价是「满意 / 不满意」二元**（不是 5 星），**不满意引导去售后**，
/// 打手侧**只展示好评率一个数字**（`接单 N 次  好评率 X%`）。
///
/// 本项目**只沿用这套信息架构**：文案、图标、视觉全部自研
/// （CLAUDE.md：禁止复制参考 App 的图片/插画/吉祥物/文案与独特装饰）。
///
/// ## 为什么单独一个文件
///
/// 「一笔订单的评价」「一条打手评价」「好评率怎么显示」这三件事同时被
/// 订单详情（`OrderReviewSection`）与打手信息页（`WorkerProfilePage`）消费。
/// 判定散在两处 = 两份实现 → 迟早漂移（"同一规则只有一份实现"的铁律）。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 无评价时好评率的**唯一文案**（测试与页面共用同一个字面量，不可能漂移）
const String kNoReviewYet = '暂无评价';

/// 介绍为空时的**唯一占位文案**（「选择陪玩」列表卡与打手主页共用同一个字面量）
///
/// 线上 13/14 位打手介绍为空 —— 占位文案必须两页一致，否则同一件事在
/// 列表上叫「介绍待补充」、点进去变成另一句话，读起来像两套产品。
const String kIntroPlaceholder = '介绍待补充';

/// 一笔订单的评价（`GET /user/orders/:id/review` 的 `data`；**未评价时服务端回 `null`**）
class OrderReviewInfo {
  const OrderReviewInfo({required this.satisfied, required this.remark, required this.createdAt});

  /// 满意（true）/ 不满意（false）
  final bool satisfied;

  /// 文字备注（可空串）
  final String remark;

  /// 评价时间（ISO 串，原样收；展示走 [reviewTimeText]）
  final String createdAt;

  /// 解析并**严格校验形状**：`satisfied` 必须是 `bool`，否则返回 null（= 当作"还没有评价"）。
  ///
  /// 为什么这么严而不是 `data['satisfied'] == true`：
  /// ① 服务端未评价时回 `null`，客户端必须把"没有"与"不满意"区分开；
  /// ② 若字段缺失/形状不对时默认成 `false`，页面会把**每一笔订单都显示成「不满意」**
  ///    —— 宁可显示"还没有评价（可评价）"，也不能凭空给用户扣一个差评。
  static OrderReviewInfo? fromJson(Object? data) {
    if (data is! Map) return null;
    final s = data['satisfied'];
    if (s is! bool) return null;
    return OrderReviewInfo(
      satisfied: s,
      remark: '${data['remark'] ?? ''}'.trim(),
      createdAt: '${data['createdAt'] ?? ''}',
    );
  }
}

/// 打手评价列表的一条（`GET /public/workers/:id` 的 `reviews[]` /
/// `GET /public/workers/:id/reviews` 的 `list[]`）
class WorkerReview {
  const WorkerReview({
    required this.satisfied,
    required this.remark,
    required this.createdAt,
    required this.nicknameMasked,
  });

  final bool satisfied;
  final String remark;
  final String createdAt;

  /// 评价人昵称（**服务端已脱敏**；客户端不再加工，也不尝试还原）
  final String nicknameMasked;

  /// 同一套严格口径：`satisfied` 不是 bool → 这条**丢掉**（不猜、不默认差评）
  static WorkerReview? fromJson(Object? data) {
    if (data is! Map) return null;
    final s = data['satisfied'];
    if (s is! bool) return null;
    return WorkerReview(
      satisfied: s,
      remark: '${data['remark'] ?? ''}'.trim(),
      createdAt: '${data['createdAt'] ?? ''}',
      nicknameMasked: '${data['nicknameMasked'] ?? ''}'.trim(),
    );
  }

  /// 去重键（"最近评价"与分页结果重叠时用；同一秒同一结论同一备注视为同一条）
  String get dedupeKey => '$createdAt|$satisfied|$remark';
}

/// 评价结论文案（**唯一出口**）：满意 / 不满意
String reviewVerdictText(bool satisfied) => satisfied ? '满意' : '不满意';

/// 评价结论图标（**唯一出口**）
///
/// 「好评 / 差评」不许只靠颜色区分（`docs/21`）：这里是**形状**信号，
/// 与 [reviewVerdictText] 的**文案**、调用处的 `FontWeight.w700` **字重**，
/// 三者一起构成"不只靠颜色"的三重区分。
IconData reviewVerdictIcon(bool satisfied) => satisfied ? AppIcon.check : AppIcon.complaint;

/// 评价结论前景色（**唯一出口**）：满意 = 品牌强调（青瓷 [AppColors.statusOnline]）；
/// 不满意 = 需要人处理的 [AppColors.error]。色值只做"第三重"信号，不是唯一信号。
Color reviewVerdictColor(bool satisfied) => satisfied ? AppColors.statusOnline : AppColors.error;

/// 好评率文案（**唯一出口**，负责人 2026-10-15 硬要求）
///
/// ## ⚠️ 口径由**服务端唯一决定**：`satisfiedRate` 是「百分数字符串」如 `"98.2"`，**不是 0–1 比率**
///
/// 这里曾经写过"两种口径都吃"（`v <= 1 ? v * 100 : v`），**那是个致命错，已修**：
/// 当 100 条评价里只有 1 条好评时，服务端给的是 `"1.0"`（= **1%**），
/// 旧写法会把它渲染成 **100%** —— 等于**把差评显示成满分**，
/// 用户会照着"满分"去下单。这是评价体系里最不能出的一类错。
/// 前端**只做展示、不做口径猜测**（契约见 `docs/03`）。
///
/// 规则：
/// - `satisfiedRate == null`（服务端契约：无评价时为 null）→ **「暂无评价」**；
/// - `reviewCount` 明确为 **0** 时同样给「暂无评价」—— 即使服务端把比率回成 `100`，
///   本条也**不许编 100%**（0 条评价算不出好评率）；
/// - 数值按**百分数**理解：`98.2` → `98.2%`（`1.0` → `1%`，**不是** `100%`）；
/// - 不合法（非数字 / 负数）→ 「暂无评价」（不猜）；
/// - 显示：整数不带小数点（`98.0` → `98%`），否则保留一位（`98.75` → `98.8%`）。
String satisfiedRateText(Object? rate, {Object? reviewCount}) {
  final v = _asDouble(rate);
  if (v == null || v < 0) return kNoReviewYet;
  final count = _asInt(reviewCount);
  if (count != null && count <= 0) return kNoReviewYet;
  final pct = v.clamp(0.0, 100.0); // 百分数口径，**不再做 `<=1 → ×100` 的比率猜测**
  final rounded = double.parse(pct.toStringAsFixed(1));
  final text = rounded == rounded.roundToDouble() ? rounded.toInt().toString() : rounded.toString();
  return '$text%';
}

/// 计数文案（`1284` → `1,284`；缺失 → `—`）
///
/// **金额不归它管**：金额只有 `fmtMoney` 一份实现（¥ + 两位小数），
/// 这里只服务"接单次数"这类整数计数（`docs/21` 的拟真数字写法 `2,847 单`）。
String countText(Object? raw, {String unit = ''}) {
  final n = _asInt(raw);
  if (n == null) return '—';
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  final grouped = '${n < 0 ? '-' : ''}$b';
  return unit.isEmpty ? grouped : '$grouped $unit';
}

/// 时间文案（**唯一出口**）：`2026-10-15T09:20:00.000Z` → `10-15 09:20`；解析不了 → `''`
///
/// 只做"到分钟"的短格式：评价列表里时间是次要信息，写全日期会把行挤散。
String reviewTimeText(String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final l = t.toLocal();
  return '${l.month}-${l.day} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// 计数/评分数解析：`int` / `num` / 数字串都吃，其余 → null（不猜 0）
int? _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.toInt() : null;
  final s = '${raw ?? ''}'.trim();
  if (s.isEmpty) return null;
  final d = double.tryParse(s);
  if (d == null || !d.isFinite) return null;
  return d.toInt();
}

double? _asDouble(Object? raw) {
  if (raw is num) return raw.isFinite ? raw.toDouble() : null;
  final s = '${raw ?? ''}'.trim().replaceAll('%', '');
  if (s.isEmpty) return null;
  final d = double.tryParse(s);
  return (d == null || !d.isFinite) ? null : d;
}
