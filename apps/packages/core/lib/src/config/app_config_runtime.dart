/// 运行期地址槽：由 [AppAddressResolver] 写、由 [AppConfig] 读（2026-10-04）。
///
/// 单独成文件的原因：`app_config.dart` 依赖地址解析器，而解析器又要写回地址 ——
/// 把"槽"抽出来，两边都只依赖本文件，避免循环导入。
///
/// 铁律：**地址只有一个来源**。业务代码读 [AppConfig.apiBase] / [AppConfig.wsBase]，
/// 不要直接读编译期常量（过期的 `trycloudflare.com` 地址就是这么来的）。
library;

class AppConfigRuntime {
  AppConfigRuntime._();

  /// 下发/探活得到并生效的 API 基础地址（含 /api/v1）；null = 尚未解析，用编译期兜底
  static String? apiBaseUrl;

  /// 生效的 Socket.IO 地址
  static String? wsBaseUrl;

  /// 地址来源：`builtin` / `bootstrap` / `bootstrap+probe` / `builtin+probe` / `bootstrap+builtin`
  static String? source;

  /// 命中的**引导源名**（`override`/`gitee`/`self-hosted`/`jsdelivr`/`github-raw`；空=未用到下发）
  static String? bootstrapFrom;

  /// 最近一次解析的探活耗时（毫秒；未探活为 null）
  static int? latencyMs;

  /// 最近一次解析参与探活的候选数
  static int? candidateCount;

  /// 运行期**热切换**次数（地址从 A 变成 B 的真实切换次数，看门狗累加）—— 诊断用
  static int switchCount = 0;

  /// 最近一次热切换时间（诊断用）
  static DateTime? lastSwitchAt;

  /// 写入解析结果
  ///
  /// 后四个具名参数是 2026-10-06 地址发现韧性专项新增的**纯诊断**字段，
  /// 都有默认值 —— 既有调用方（含单测）不传即行为不变。
  static void apply({
    required String api,
    required String ws,
    required String from,
    String? bootstrapFrom,
    int? latencyMs,
    int? candidateCount,
  }) {
    apiBaseUrl = api;
    wsBaseUrl = ws;
    source = from;
    AppConfigRuntime.bootstrapFrom = bootstrapFrom;
    AppConfigRuntime.latencyMs = latencyMs;
    AppConfigRuntime.candidateCount = candidateCount;
  }

  /// 记一次真实的地址热切换（由 AddressWatchdog 在 api 变化后调用）
  static void noteSwitch(DateTime at) {
    switchCount += 1;
    lastSwitchAt = at;
  }

  /// 测试钩子：清空运行期覆盖，回到编译期兜底
  static void reset() {
    apiBaseUrl = null;
    wsBaseUrl = null;
    source = null;
    bootstrapFrom = null;
    latencyMs = null;
    candidateCount = null;
    switchCount = 0;
    lastSwitchAt = null;
  }
}
