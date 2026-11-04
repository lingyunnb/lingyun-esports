/// 打手等级 + 升级进度（三处共用**同一形状**）
///
/// 服务端唯一出处（客户端只读，**不重算、不编数字**）：
/// - `GET /public/players` → 每项带 `grade` / `gradeLabel` / `gradeName`（**不带五维与进度**）
/// - `GET /public/workers/:id` → 上面三个 + `rating{...}` + `progress{...}`
/// - `GET /worker/grade` → 与详情**完全同形**（打手态「我的」）
///
/// 等级名（`初出 / 立足 / 扬名 / 称雄 / 宗师`）与 `LV1–LV5` 标签一律**由服务端下发**
/// （服务端常量表 `worker-grade.constants.ts` 是唯一出处）→ 客户端**不写死任何等级中文名**：
/// 这里只做解析与展示，改名只改服务端一处。注意：这是**打手等级**，与老板端会员
/// （初识/知交/尊享/臻享/至尊会员）**没有任何关系**，两边命名不许互相串用。
library;

import '../util/idempotency.dart';

/// 「距下一级还差多少」的**数值差额**（服务端 `GradeRemain` 的镜像）
///
/// 每一项都是"还差多少"，`0` = 该项已达标；**不是在展示"已完成多少"**。
class GradeRemain {
  const GradeRemain({
    required this.completedOrders,
    required this.satisfiedRate,
    required this.ratingAvg,
    required this.settlementAmount,
    required this.ratingSamples,
  });

  /// 累计完成单还差多少单
  final num completedOrders;

  /// 好评率还差多少个百分点；`null` = **暂无评价**（服务端就这样下发，客户端不当成 0）
  final num? satisfiedRate;

  /// 五维均分还差多少（0–10 分制）
  final num ratingAvg;

  /// 结算累计还差多少元（展示走 `fmtMoney`，全站只认 ¥/元）
  final num settlementAmount;

  /// 五维样本还差多少条（< 10 条不参与判定，见服务端常量表）
  final num ratingSamples;

  /// 解析；形状不对（不是对象 / 一个数都没有）→ `null`（**不猜 0**）
  static GradeRemain? tryParse(Object? raw) {
    if (raw is! Map) return null;
    num? numOf(String key) {
      final v = raw[key];
      if (v is num) return v.isFinite ? v : null;
      final s = '${v ?? ''}'.trim();
      if (s.isEmpty) return null;
      final d = double.tryParse(s);
      return d == null || !d.isFinite ? null : d;
    }

    final orders = numOf('completedOrders');
    final avg = numOf('ratingAvg');
    final settle = numOf('settlementAmount');
    final samples = numOf('ratingSamples');
    if (orders == null && avg == null && settle == null && samples == null && numOf('satisfiedRate') == null) {
      return null;
    }
    return GradeRemain(
      completedOrders: orders ?? 0,
      satisfiedRate: numOf('satisfiedRate'),
      ratingAvg: avg ?? 0,
      settlementAmount: settle ?? 0,
      ratingSamples: samples ?? 0,
    );
  }
}

/// 升级进度（服务端 `GradeProgress` 的镜像）
class WorkerGradeProgress {
  const WorkerGradeProgress({
    required this.currentGrade,
    required this.currentGradeLabel,
    required this.currentGradeName,
    required this.nextGrade,
    required this.nextGradeLabel,
    required this.nextGradeName,
    required this.needManualReview,
    required this.readyNow,
    required this.blockers,
    required this.remain,
  });

  final int currentGrade;
  final String currentGradeLabel;
  final String currentGradeName;

  /// 下一档的代号；**已到最高档 → null**
  final int? nextGrade;
  final String? nextGradeLabel;
  final String? nextGradeName;

  /// 下一档是否**必须人工审核**（4 → 5 这一档，服务端 `needManualReview`）
  final bool needManualReview;

  /// 指标是否已满足下一档全部门槛
  final bool readyNow;

  /// 还差什么（服务端中文，可直接展示；空 = 指标已全部达标）
  final List<String> blockers;

  /// 数值差额；已到最高档 → `null`
  final GradeRemain? remain;

  static WorkerGradeProgress? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final current = _intOf(raw['currentGrade']);
    if (current == null) return null;
    return WorkerGradeProgress(
      currentGrade: current,
      currentGradeLabel: _strOf(raw['currentGradeLabel']),
      currentGradeName: _strOf(raw['currentGradeName']),
      nextGrade: _intOf(raw['nextGrade']),
      nextGradeLabel: _strNull(raw['nextGradeLabel']),
      nextGradeName: _strNull(raw['nextGradeName']),
      needManualReview: raw['needManualReview'] == true,
      readyNow: raw['readyNow'] == true,
      blockers: ((raw['blockers'] as List?) ?? const [])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      remain: GradeRemain.tryParse(raw['remain']),
    );
  }
}

/// 一个打手的等级（列表 → 三件套；详情/打手态 → 三件套 + 进度）
class WorkerGrade {
  const WorkerGrade({
    required this.grade,
    required this.gradeLabel,
    required this.gradeName,
    required this.progress,
  });

  /// 1–5
  final int grade;

  /// 服务端下发的 `LV1`–`LV5` 标签（客户端不自己拼）
  final String gradeLabel;

  /// 服务端下发的等级名（初出 / 立足 / 扬名 / 称雄 / 宗师）
  final String gradeName;

  /// 升级进度（只有详情与打手态「我的」才有；列表 → null）
  final WorkerGradeProgress? progress;

  /// `"LV3 扬名"` 这一类"标签 + 名"的展示串（服务端某个字段缺失时自动只显示另一个）
  String get title => [gradeLabel, gradeName].where((s) => s.trim().isNotEmpty).join(' ');

  /// 解析；**没有合法 `grade` 就当没有等级**（→ 上层渲染 `--` 占位 / 整块不画）
  static WorkerGrade? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final g = _intOf(raw['grade']);
    if (g == null || g < 1 || g > 5) return null;
    return WorkerGrade(
      grade: g,
      gradeLabel: _strOf(raw['gradeLabel']),
      gradeName: _strOf(raw['gradeName']),
      progress: WorkerGradeProgress.tryParse(raw['progress']),
    );
  }
}

/// 进度里的一行（`label` + `value` 两段式，页面自己决定怎么排）
///
/// `text` 是"一句能直接读的话"（详细页用）；`label`/`value` 分开是给「我的等级」卡
/// 做左右对齐的那一版用的 —— **同一份文案，一个出口**。
class GradeRemainItem {
  const GradeRemainItem({required this.label, required this.value});

  /// 指标名（完成单 / 好评率 / 五维均分 / 结算累计 / 五维样本）
  final String label;

  /// 还差多少（如 `还差 3 单`）
  final String value;

  /// `完成单还差 3 单`
  String get text => '$label$value';
}

/// `progress.remain` → 可展示的若干行（**唯一实现**：三个页面都读它）
///
/// 规则（"没数据就不显示"）：
/// - `null`（到顶了 / 没进度）→ 空列表；
/// - 每项**只有 > 0 才出现**（已达标的不占版面）；
/// - 好评率为 `null`（暂无评价）→ **不编 0**，整行不出现。
List<GradeRemainItem> gradeRemainItems(GradeRemain? remain) {
  if (remain == null) return const [];
  final out = <GradeRemainItem>[];
  if (remain.completedOrders > 0) {
    out.add(GradeRemainItem(label: '完成单', value: '还差 ${_numText(remain.completedOrders)} 单'));
  }
  final rate = remain.satisfiedRate;
  if (rate != null && rate > 0) {
    out.add(GradeRemainItem(label: '好评率', value: '还差 ${_numText(rate)} 个百分点'));
  }
  if (remain.ratingAvg > 0) {
    out.add(GradeRemainItem(label: '五维均分', value: '还差 ${_numText(remain.ratingAvg)}'));
  }
  if (remain.settlementAmount > 0) {
    out.add(GradeRemainItem(label: '结算累计', value: '还差 ${fmtMoney(remain.settlementAmount)}'));
  }
  if (remain.ratingSamples > 0) {
    out.add(GradeRemainItem(label: '五维样本', value: '还差 ${_numText(remain.ratingSamples)} 条'));
  }
  return out;
}

/// 数字文案：整数不带小数点，小数最多两位且不吃尾零（`3` / `1.5` / `0.25`）
String _numText(num v) {
  final d = v.toDouble();
  if (d == d.roundToDouble()) return d.toStringAsFixed(0);
  final s = d.toStringAsFixed(2);
  return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
}

int? _intOf(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.toInt() : null;
  final s = '${raw ?? ''}'.trim();
  if (s.isEmpty) return null;
  return int.tryParse(s);
}

String _strOf(Object? raw) => '${raw ?? ''}'.trim();

String? _strNull(Object? raw) {
  final s = '${raw ?? ''}'.trim();
  return s.isEmpty ? null : s;
}
