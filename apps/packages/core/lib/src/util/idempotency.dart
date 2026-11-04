import 'package:uuid/uuid.dart';

/// 生成幂等键（docs/06）：下单/资金类写操作必须携带，重试复用同一键防重复
String generateIdempotencyKey() => const Uuid().v4();

/// 解析服务端金额字段（小数价目 2026-09-23 起生效；**字段名不变，只变计价单位**）
///
/// 服务端 DECIMAL 金额经 money.transformer 返回 JSON 数字：整数价目是 `16`，小数价目是 `5.5`。
/// **禁止**写 `json['totalAmount'] as int?` —— 遇到小数会抛 TypeError 导致整页崩溃（双端订单页曾因此崩）。
double parsePoints(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

/// **金额显示的唯一出口**（负责人 2026-10-09 口径：计价单位由「积分」改为「余额」，1 元 = 1 元）
///
/// 全站金额一律由本函数产出，页面**不得**自己拼 `¥`/千分位/小数位：
/// - `¥` 前缀 + **千分位** + **固定两位小数**：`0 → ¥0.00`、`0.5 → ¥0.50`、`8.8 → ¥8.80`、
///   `1234.5 → ¥1,234.50`、`99999.9 → ¥99,999.90`；
/// - 负数是**扣款**（下单扣款/退款冲正），负号放在 `¥` 之前：`-5 → -¥5.00`；
///   `+` 号由调用方按需加（如钱包流水的入账行 `+¥5.00`）；
/// - 两位小数**四舍五入**（`(v*100).round()/100`），避免 `-0.001` 显示成 `-¥0.00`。
///
/// 为什么不直接改 [fmtPoints]：工作端 App 处于**冻结期**（代码保留、停止更新），
/// 它的页面把 `fmtPoints` 的结果直接拼上「积分」二字且回归用例钉住了那一串文本；
/// 改 [fmtPoints] 的返回值会连带改掉冻结端的展示与它的回归。
/// 因此新口径**新增**本函数：老板端 + 共享包的金额展示一律改调它（`fmtPoints` 只留给冻结的工作端）。
String fmtMoney(num v) {
  final rounded = (v.toDouble() * 100).round() / 100;
  final sign = rounded < 0 ? '-' : '';
  final fixed = rounded.abs().toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  final intPart = fixed.substring(0, dot);
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '$sign¥$buf${fixed.substring(dot)}';
}

/// 金额格式化（旧口径：整数不带小数点，小数最多两位去掉尾零）
///
/// ⚠️ **冻结兼容**：仅工作端 App（已停止服务、代码冻结）还在用；老板端/共享包新代码
/// **一律用 [fmtMoney]**（¥ + 两位小数 + 千分位）。新页面不要再调用本函数。
String fmtPoints(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  final s = v.toStringAsFixed(2);
  return s.endsWith('00') ? s.substring(0, s.length - 3) : (s.endsWith('0') ? s.substring(0, s.length - 1) : s);
}
