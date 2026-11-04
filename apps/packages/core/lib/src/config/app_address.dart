/// 服务地址动态下发 + **地址发现韧性**（2026-10-04 建立 / 2026-10-06 多源加固）。
///
/// 背景（docs/11）：FISH 公网入口先是 Cloudflare **Quick Tunnel**（`trycloudflare.com`
/// 随机子域、每次重启会变），后加 ngrok 固定域名。地址若只靠 `--dart-define` 烘进 APK，
/// 电脑一重启 / 隧道一换 / 账号一限流，所有已安装 App 全部失联，只能重新打包发版。
///
/// 解决方案（不花钱路线，2026-10-06 实测可达性为据）：
///   固定引导地址（bootstrap，**多源按序尝试**，任一成功即用）
///     ① Gitee raw                —— 本机实测 0.25s 可达（账号/仓库由负责人提供后启用）
///     ② 服务端自托管             —— `<候选>/site/client-config.json`
///                                    **不需要任何第三方账号**：只要还有一个候选活着就能拿到最新配置
///     ③ jsDelivr（GitHub 镜像）  —— 实测 CDN 可达
///     ④ GitHub raw               —— 保留为末位兼容（本机实测 http=000 不可达）
///        └─ 内容是一份很小的 JSON：{ "api": "...", "candidates": [...] }
///             └─ 多候选**并行探活**，取最快的一个（隧道 / 局域网 / 未来云服务器可同时列）
///                  └─ 解析失败 → **内置多候选**并行探活（最快者胜）
///                       └─ 全部失败 → 打包内置地址（AppConfig 编译期常量）
///
/// 运行期韧性（本轮新增，见 [AddressWatchdog]）：
///   启动解析失败、或运行中连续 N 次请求失败、或首次 WS 连不上
///     → 清缓存 → 重走一遍"多源 bootstrap + 探活" → **热切换**地址（不要求重启 App）
///   重取带**指数退避**（5s→10s→20s…上限 5 分钟）与**次数上限**（默认 6 次/进程），
///   全部候选不可达时不会死循环。
///
/// 铁律（docs/11）：地址只有这一个来源，禁止在页面里写死地址。
/// 本文件不引入任何新依赖（只用 dart:io / dart:convert / flutter foundation 的 debugPrint）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'app_config_runtime.dart';

/// 地址**类别**（2026-10-06 局域网优先专项；仅诊断/日志用，不参与任何判定分支）。
///
/// 为什么要单独一个枚举而不是 `bool isLan`：诊断行要直接给人看"当前走的是哪条路"
/// （「我的 → 设置 → 诊断 → 当前服务器地址」），而 `lan/tunnel/builtin/unknown`
/// 四个词比 `true/false` 自解释得多。判定实现只有一处（[AppAddressResolver.addressKindOf]）。
enum AddressKind {
  /// 局域网直连（私网 IP / localhost / `.local`）—— 家用 WiFi 下的最优路径
  lan('LAN'),

  /// 公网隧道（Cloudflare Quick Tunnel / ngrok）
  tunnel('隧道'),

  /// 其它公网地址（未来自建云服务器）
  builtin('直连'),

  /// 判不出来
  unknown('未知');

  const AddressKind(this.label);

  /// 诊断行里的中文/英文短标签
  final String label;
}

/// 下发生效后的地址集合。只由 [AppAddressResolver] 在解析成功时构造。
class ResolvedAddress {
  const ResolvedAddress({
    required this.apiBaseUrl,
    required this.wsBaseUrl,
    required this.source,
    this.latencyMs,
    this.candidates = const <String>[],
    this.bootstrapFrom,
  });

  /// 形如 `https://xxx.trycloudflare.com/api/v1`（含 /api/v1 前缀）
  final String apiBaseUrl;

  /// 形如 `https://xxx.trycloudflare.com`（Socket.IO 同源同端口）
  final String wsBaseUrl;

  /// 来源标记（日志/排查用）：
  /// `builtin` / `bootstrap` / `bootstrap+probe` / `bootstrap+preferred` /
  /// `bootstrap+builtin` / `builtin+probe`
  final String source;

  /// 探活耗时（毫秒，未探活时为 null）
  final int? latencyMs;

  /// 本次参与探活的全部候选（日志/排查用）
  final List<String> candidates;

  /// **哪一条引导源命中的**（2026-10-06 多源加固新增）：
  /// `override` / `gitee` / `self-hosted` / `jsdelivr` / `github-raw`；
  /// 未用到下发（走了内置）时为 null。仅日志/诊断用，不参与任何判定。
  final String? bootstrapFrom;

  /// 当前地址的类别（由 [apiBaseUrl] 推导，见 [AddressKind]）—— 诊断行显示 LAN/隧道
  AddressKind get kind => AppAddressResolver.addressKindOf(apiBaseUrl);

  /// 诊断行用的短标签（`LAN` / `隧道` / `直连` / `未知`）
  String get kindLabel => kind.label;

  @override
  String toString() =>
      'ResolvedAddress(api=$apiBaseUrl, ws=$wsBaseUrl, source=$source, '
      'kind=$kindLabel, latencyMs=$latencyMs, candidates=${candidates.length}, '
      'bootstrapFrom=$bootstrapFrom)';
}

/// 解析结果：无论成败都返回一个可直接用于启动的地址 ——
/// 成功时是下发/探活得到的最优地址，失败时是打包内置地址（[ResolvedAddress.source] == 'builtin'）。
class AddressResolution {
  const AddressResolution({
    required this.address,
    required this.fromBootstrap,
    required this.probed,
    this.error,
  });

  final ResolvedAddress address;

  /// 是否用到了下发内容（false = 回退内置）
  final bool fromBootstrap;

  /// 是否真的做了探活（bootstrap 只有单个候选时可跳过）
  final bool probed;

  /// 回退原因（成功时为 null）
  final String? error;

  @override
  String toString() => 'AddressResolution(fromBootstrap=$fromBootstrap, '
      'probed=$probed, error=$error, ${address.toString()})';
}

/// 单次探活结果（测试可见）
class AddressProbeResult {
  const AddressProbeResult(this.apiBaseUrl, this.latencyMs);

  final String apiBaseUrl;
  final int latencyMs;
}

/// 一条引导源（多源 bootstrap 的"源"）。
///
/// [parallel] = true 表示"同族多 host 并行取第一个成功者"（目前只有自托管族：
/// 本机记住的上次地址 + 打包内置候选可能有好几个 host，串行等它们逐个超时太慢）。
class AddressBootstrapSource {
  const AddressBootstrapSource(this.name, this.url, {this.parallel = false});

  /// 源名（日志/诊断）：`override` / `gitee` / `self-hosted` / `jsdelivr` / `github-raw`
  final String name;

  /// 该源的完整 URL
  final String url;

  /// 同族并行（见类注释）
  final bool parallel;

  @override
  String toString() => '$name($url)';
}

/// 下发配置（bootstrap JSON）解析器 —— 纯函数，便于单测。
///
/// 支持的字段（宽松解析，任一为空都不算错误）：
///   `api`        : 单条 API 地址（最简单写法）
///   `candidates` : 候选地址数组（字符串，或 `{ "api": "..." }` 对象）
///   `preferred`  : **首选地址**（可选，2026-10-06 新增）。见下。
///   `ws`         : 显式 Socket.IO 地址（缺省由 api 派生：去掉 /api/v1 后缀）
///   `updatedAt`  : 下发时间（仅日志用）
///
/// `preferred` 的用途：Quick Tunnel 域名**每次重启都会变**，而 ngrok 固定域名不变 ——
/// 于是"固定域名活着就用它，死了才用快速隧道"才是正确的偏好。只按延迟选最快
/// 会把"今天恰好更快的临时隧道"选成主入口，隧道一重启又得重来一遍。
/// 语义（严格的）：`preferred` **必须同时出现在 candidates 里**，且探活通过才生效；
/// 任何一条不满足就当没写（退回"最快者胜"）。老 JSON 没有这个字段 → 行为与历史逐字相同。
class AddressBootstrap {
  const AddressBootstrap({
    required this.apiBaseUrl,
    required this.candidates,
    this.wsBaseUrl,
    this.updatedAt,
    this.preferred,
  });

  final String apiBaseUrl;
  final List<String> candidates;
  final String? wsBaseUrl;
  final String? updatedAt;

  /// 首选地址（已规范化；不合法或不在 [candidates] 里时为 null）
  final String? preferred;

  /// 解析下发 JSON；内容不合法时抛 [FormatException]（由调用方兜底成内置地址）。
  static AddressBootstrap parse(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('bootstrap 根节点必须是 JSON 对象');
    }
    final List<String> candidates = <String>[];
    final Object? primary = decoded['api'];
    if (primary is String) candidates.add(primary);
    final Object? list = decoded['candidates'];
    if (list is List) {
      for (final Object? item in list) {
        if (item is String) {
          candidates.add(item);
        } else if (item is Map && item['api'] is String) {
          candidates.add(item['api'] as String);
        }
      }
    }
    final List<String> normalized = <String>[];
    for (final String c in candidates) {
      final String n = AppAddressResolver.normalizeApiBase(c);
      if (n.isNotEmpty && !normalized.contains(n)) normalized.add(n);
    }
    if (normalized.isEmpty) {
      throw const FormatException('bootstrap 未包含任何可用地址（api / candidates）');
    }
    final String? ws = decoded['ws'] is String
        ? AppAddressResolver.normalizeWsBase(decoded['ws'] as String)
        : null;
    // preferred 必须真的在候选里才算数（防"下发写了个没人探过的地址"）
    String? preferred;
    if (decoded['preferred'] is String) {
      final String p = AppAddressResolver.normalizeApiBase(decoded['preferred'] as String);
      if (normalized.contains(p)) preferred = p;
    }
    return AddressBootstrap(
      apiBaseUrl: normalized.first,
      candidates: normalized,
      wsBaseUrl: (ws == null || ws.isEmpty) ? null : ws,
      updatedAt: decoded['updatedAt'] is String ? decoded['updatedAt'] as String : null,
      preferred: preferred,
    );
  }
}

/// 地址解析器：多源拉下发配置 → 多候选并行探活 → 取最快 → 写回 AppConfig。
///
/// 设计要点：
/// - **绝不抛异常**：任何失败都回退内置地址，App 一定起得来（离线/下发站被墙都不会白屏）。
/// - **并行探活**：候选之间互不等待，总耗时 ≈ 最慢的一条；探活失败的直接丢弃。
/// - **可注入**：`debugFetchHealth` / `debugFetchBootstrap` / `debugBuiltinCandidates`
///   可被测试替换，不需要真网络。
class AppAddressResolver {
  AppAddressResolver._();

  /// 显式钉死的引导地址（**最高优先**）。
  ///
  /// 非空时**只**用它（保持"钉死一个源"的语义，便于排查与私有部署）：
  /// `--dart-define=ADDRESS_BOOTSTRAP=<任意静态 JSON URL>`。
  static const String explicitBootstrapUrl = String.fromEnvironment(
    'ADDRESS_BOOTSTRAP',
    defaultValue: '',
  );

  /// GitHub raw 兜底（历史默认值，**末位兼容**保留）。
  /// ⚠️ 2026-10-06 实测本机 `http=000` 不可达 —— 因此它不再是唯一来源。
  static const String githubBootstrapUrl =
      'https://raw.githubusercontent.com/kslingyun/fish-endpoint/main/client-config.json';

  /// ① Gitee raw（**预留常量**：负责人提供账号/仓库后由构建注入即生效；空 = 未配置，自动跳过）
  ///
  /// 形如 `https://gitee.com/<user>/<repo>/raw/<branch>/client-config.json`。
  /// 本机实测 Gitee 0.25s 可达（404 仅因仓库未建）。铺路脚本见
  /// `scripts/tmp/publish-bootstrap-gitee.ps1`。
  /// 构建：`--dart-define=ADDRESS_BOOTSTRAP_GITEE=https://gitee.com/<user>/<repo>/raw/main/client-config.json`
  static const String giteeBootstrapUrl = String.fromEnvironment(
    'ADDRESS_BOOTSTRAP_GITEE',
    defaultValue: '',
  );

  /// ③ jsDelivr 镜像（GitHub 仓库的免费 CDN 镜像；实测可达）
  static const String jsdelivrBootstrapUrl = String.fromEnvironment(
    'ADDRESS_BOOTSTRAP_JSDELIVR',
    defaultValue:
        'https://cdn.jsdelivr.net/gh/kslingyun/fish-endpoint@main/client-config.json',
  );

  /// ② 服务端自托管路径（相对候选根）。服务端把 `site/` 挂在 `/site`（server/src/main.ts），
  /// `scripts/publish-address.ps1` 会把同一份 JSON 同步到 `site/client-config.json`
  /// —— 于是**任何活着的候选**都能当引导站用，这条腿不需要任何第三方账号。
  static const String selfHostedPath = '/site/client-config.json';

  /// **兼容既有引用**：历史名 `bootstrapUrl`。
  /// 语义 = 显式钉死值（若给了）否则 GitHub raw 末位兜底。
  /// 多源清单请用 [bootstrapSources]。
  static String get bootstrapUrl =>
      explicitBootstrapUrl.isNotEmpty ? explicitBootstrapUrl : githubBootstrapUrl;

  /// 内置兜底地址（打包时注入；同 AppConfig 编译期常量）
  static String get builtinApiBase => const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://10.0.2.2:3100/api/v1',
      );

  static String get builtinWsBase => const String.fromEnvironment(
        'WS_BASE_URL',
        defaultValue: 'http://10.0.2.2:3100',
      );

  /// **额外的内置候选**（除 `API_BASE_URL` 之外的烧录地址，逗号分隔）。
  ///
  /// 打包时把"ngrok 固定域名 + 构建时的 Cloudflare 隧道 + 局域网 IP 列表"一并烧进来：
  /// `--dart-define=ADDRESS_BUILTIN_CANDIDATES=https://a.ngrok-free.dev,https://b.trycloudflare.com,http://192.168.1.145:3100`
  ///
  /// 为什么默认留空：单测必须**确定性**（默认值里塞真地址会让"回退内置"这类断言
  /// 随线上额度/隧道状态飘动）。真实候选一律由构建命令注入，见 release-boss.js。
  static const String extraBuiltinCandidatesRaw = String.fromEnvironment(
    'ADDRESS_BUILTIN_CANDIDATES',
    defaultValue: '',
  );

  /// 开关（编译期）：`--dart-define=ADDRESS_BOOTSTRAP_ENABLED=false` 可完全关闭下发
  /// （调试/离线包用）。关闭时**不下发、不探活**，直接用 [builtinApiBase] —— 行为与历史一致。
  static const bool bootstrapEnabled = bool.fromEnvironment(
    'ADDRESS_BOOTSTRAP_ENABLED',
    defaultValue: true,
  );

  /// 编译期开关的**可测包装**（测试用 [debugEnabledOverride] 覆盖；生产恒等于 [bootstrapEnabled]）
  static bool get enabled => debugEnabledOverride ?? bootstrapEnabled;

  /// 测试钩子：强制开关（null = 用编译期值）
  static bool? debugEnabledOverride;

  /// 拉取单条下发的超时（默认 3.5s：不能让"下发站慢"拖死冷启动）
  static const Duration bootstrapTimeout = Duration(milliseconds: 3500);

  /// **全部引导源的总预算**（默认 8s）：多源意味着最坏要试 N 次，
  /// 预算用尽就不再试后面的源（宁可回退内置，也不让冷启动无限等）。
  static const Duration bootstrapTotalBudget = Duration(milliseconds: 8000);

  /// 读"上次可用地址"的超时（安全存储在部分机型上很慢；读不到就当没有）
  static const Duration lastKnownGoodTimeout = Duration(milliseconds: 300);

  /// 单个候选探活超时（默认 2.5s）
  static const Duration probeTimeout = Duration(milliseconds: 2500);

  /// **局域网优选的等待上限**（2026-10-06 局域网优先专项，默认 1.5s）。
  ///
  /// 语义：局域网候选的探活**与引导/隧道解析并行**跑，但**最多**只等它这么久。
  /// - 同一 WiFi 下局域网 `GET /health` 实测 9ms → 远在预算内，必然赢下优先级；
  /// - 不在同一内网时候选会一直挂到 [probeTimeout] → 这里主动放弃，
  ///   让隧道结果直接接管（**绝不让"局域网不通"拖慢冷启动**）。
  ///
  /// 为什么不是"等满 probeTimeout"：探活是并行发的，但**决策**要等它；
  /// 预算 1.5s 已经是我方局域网 RTT 的 160 倍，再长只会白等。
  static const Duration lanProbeGate = Duration(milliseconds: 1500);

  /// 测试钩子：替换探活实现（返回 null = 不可用）
  static Future<int?> Function(String apiBaseUrl)? debugFetchHealth;

  /// 测试钩子：替换下发拉取实现
  static Future<String> Function(String url)? debugFetchBootstrap;

  /// 测试钩子：替换"内置候选清单"（null = 用真实编译期清单）
  static List<String>? debugBuiltinCandidates;

  /// 测试钩子：替换"引导源清单"（null = 用真实多源清单）
  static List<AddressBootstrapSource>? debugBootstrapSources;

  /// 日志出口（null = 走 `debugPrint('[address] ...')`）
  static void Function(String message)? debugLog;

  /// **本机"上次可用地址"读写钩子**（生产由 App 的 `main()` 接到 AppSettings；
  /// 为 null 时完全不参与解析 —— 单测无需碰安全存储，也不会被 method channel 挂住）。
  ///
  /// 用途：自托管 bootstrap 需要一个"已知入口"才能去拉 `/site/client-config.json`；
  /// 除了打包内置候选，本机记住的上次可用地址是最有希望的一个。
  static Future<String?> Function()? loadLastKnownGood;
  static Future<void> Function(String apiBase)? saveLastKnownGood;

  /// ngrok 免费档"浏览器警示插页"跳过头（2026-10-04）。
  ///
  /// 背景（docs/11，实测）：ngrok 免费档对**浏览器式**请求（UA 形如 `Mozilla/5.0 ...`）
  /// 返回一张"你即将访问 xxx"的插页 HTML，**状态码仍是 200**、`Content-Type: text/html`。
  /// 于是"探活只看状态码"的实现会**假通过**：地址拿到了，正文却不是 JSON ——
  /// 引导 JSON 解析失败 → 静默回退内置地址（隧道明明通着却用不上）。
  /// 带上这个头（或任意非浏览器 UA）ngrok 直接放行，返回真实后端响应。
  ///
  /// 对所有 host 都安全：Cloudflare / 局域网直连 / 未来云服务器都会忽略未知请求头
  /// （HTTP 语义如此），因此无条件携带，不做 ngrok 专用分支。
  /// 注意：这不是鉴权头，不含任何敏感信息，写进请求头不会泄露任何东西。
  static const String ngrokSkipWarningHeader = 'ngrok-skip-browser-warning';

  /// 该请求头的值（ngrok 只判断"存在且非空"，值本身任意）
  static const String ngrokSkipWarningValue = 'true';

  /// 非浏览器 UA：ngrok 以 UA 判定"是否浏览器"，Dart HttpClient 默认 UA
  /// `Dart/<sdk> (dart:io)` 已经是非浏览器样式（本项目默认就这么发），
  /// 这里**显式**再写一遍，避免将来有人替换 HttpClient 实现时悄悄退回浏览器 UA。
  static const String appUserAgent = 'FishApp/1.0 (Dart; dart:io)';

  /// 给任意请求统一贴上下发/探活用的请求头（**唯一实现点**，便于单测直接断言）。
  ///
  /// 为什么必须有这个函数而不是两处各写一行：`_fetch` 与 `fetchHealth` 用的是两个
  /// 独立 HttpClient，任何一处漏加都会重新掉进"假 200 插页"陷阱，且症状隐蔽。
  static void applyCommonHeaders(HttpClientRequest req) {
    req.headers.set(HttpHeaders.userAgentHeader, appUserAgent);
    req.headers.set(ngrokSkipWarningHeader, ngrokSkipWarningValue);
  }

  /// 建一个已配好 [applyCommonHeaders] 的 HttpClient（探活与下发共用）。
  static HttpClient createHttpClient(Duration timeout, {Duration? idle}) {
    final HttpClient client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = idle ?? const Duration(seconds: 2);
    client.userAgent = appUserAgent;
    return client;
  }

  /// 判断 `/health` 正文是否**真的是** FISH 后端（防"200 但是插页"假通过）。
  ///
  /// 只认我们自己的响应契约（docs/03）：`code` 必须是 0（数字或数字字符串），
  /// 且 `data.status` 存在 —— 插页 HTML 连 JSON 都解析不出来，必然被判为不可用。
  static bool isHealthBody(String body) {
    if (body.isEmpty) return false;
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return false;
      final Object? code = decoded['code'];
      if (code != 0 && code != '0') return false;
      final Object? data = decoded['data'];
      return data is Map && data['status'] != null;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 引导源清单

  /// 内置候选清单（**并行探活**，最快者胜）。
  ///
  /// = `API_BASE_URL` 编译期地址 + `ADDRESS_BUILTIN_CANDIDATES`（逗号分隔的额外候选），
  /// 去重后保序（顺序影响"并列延迟时取靠前者"的稳定性）。
  static List<String> get builtinCandidates {
    final List<String>? override = debugBuiltinCandidates;
    if (override != null) return override;
    final List<String> out = <String>[];
    void add(String raw) {
      final String n = normalizeApiBase(raw);
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }

    add(builtinApiBase);
    for (final String part in extraBuiltinCandidatesRaw.split(',')) {
      add(part);
    }
    return out;
  }

  // ---------------------------------------------------------------- 局域网识别（唯一实现）

  /// Android 模拟器访问宿主机的固定别名 —— **刻意的开发专用地址**，不算"局域网候选"。
  ///
  /// 为什么必须排除（2026-10-06 实测踩到）：
  ///   - 它是 [builtinApiBase] 的**编译期默认值**（模拟器调试用），恰好落在 `10.x` 私网段里，
  ///     于是"按私网段判定"会把它当成本机局域网；
  ///   - 但真机（发布 APK）上 `10.0.2.2` 根本不指向任何东西 —— 把它当 LAN 只会白探一次；
  ///   - 更糟的是**模拟器上**它真的可达（= 开发机的 localhost），会让"局域网优先"在模拟器
  ///     调试时静默压过隧道地址，把"隧道优先级"这类调试场景搅乱。
  ///
  /// 换句话说：真正的局域网候选来自构建注入的 `ADDRESS_BUILTIN_CANDIDATES`
  /// （如 `http://192.168.1.145:3100`），而不是这个开发兜底值。
  static const String emulatorHostAlias = '10.0.2.2';

  /// 判断一个地址是否**局域网直连**（私网 IP / localhost / `.local`）。
  ///
  /// 覆盖（RFC1918 + 回环 + 链路本地 + mDNS）：
  ///   - `10.x.x.x` · `172.16–31.x.x` · `192.168.x.x`（含 `192.168.1.145` 这类烧录地址）
  ///   - `127.x.x.x` · `localhost` · `*.local`
  ///   - `169.254.x.x`（DHCP 失败时的自分配地址，仅同网段可达 → 同样当局域网）
  ///
  /// **不含** [emulatorHostAlias]（`10.0.2.2`，见其注释）。
  ///
  /// 为什么按**主机名**判而不看 scheme：局域网候选是 `http://`，但如果将来有人给
  /// 内网挂了证书（`https://192.168.x.x`），它依然是局域网 —— 判定不该随 scheme 漂。
  ///
  /// 这是"局域网候选"的**唯一**判定点（[lanCandidates] 与 [AddressKind] 都走它）。
  static bool isPrivateHost(String apiBaseUrl) {
    final String host = _hostOf(apiBaseUrl);
    if (host.isEmpty) return false;
    // 开发专用别名不算局域网候选（见 emulatorHostAlias）
    if (host == emulatorHostAlias) return false;
    if (host == 'localhost' || host.endsWith('.local')) return true;
    final List<String> parts = host.split('.');
    if (parts.length != 4) return false;
    final List<int?> nums = parts.map(int.tryParse).toList();
    if (nums.any((int? n) => n == null || n < 0 || n > 255)) return false;
    final int a = nums[0]!;
    final int b = nums[1]!;
    if (a == 10 || a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  /// 地址的**主机名**（小写、无端口）。解析不出来时返回空串。
  static String _hostOf(String apiBaseUrl) {
    final String s = apiBaseUrl.trim();
    if (s.isEmpty) return '';
    try {
      final Uri uri = Uri.parse(s.contains('://') ? s : 'https://$s');
      final String host = uri.host;
      return host.isEmpty ? '' : host.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// 地址类别（诊断行 + 日志用；判定口径与 [isPrivateHost] 同源）
  static AddressKind addressKindOf(String apiBaseUrl) {
    final String host = _hostOf(apiBaseUrl);
    if (host.isEmpty) return AddressKind.unknown;
    if (isPrivateHost(apiBaseUrl)) return AddressKind.lan;
    if (host.endsWith('trycloudflare.com') ||
        host.endsWith('ngrok-free.dev') ||
        host.endsWith('ngrok.io') ||
        host.endsWith('ngrok-free.app') ||
        host.endsWith('ngrok.app')) {
      return AddressKind.tunnel;
    }
    return AddressKind.builtin;
  }

  /// **打包内置的局域网候选**（并行探活、**优先于隧道**）—— 本轮局域网优先专项的核心。
  ///
  /// 数据源仍是 [builtinCandidates]（`API_BASE_URL` + `ADDRESS_BUILTIN_CANDIDATES`），
  /// 只是**挑出其中的局域网地址**。这保证了"烧录进 APK 的候选"与"参与探活的候选"
  /// 是同一份清单，不存在"某个地址只在某条分支里存在"的二义性。
  static List<String> get lanCandidates =>
      builtinCandidates.where(isPrivateHost).toList(growable: false);

  /// 探活局域网候选，取最快者；全部不可达/超时返回 null（**绝不抛异常**）。
  ///
  /// 与 [resolve] 里的隧道探活**并行**发起，结果只由 [lanProbeGate] 决定是否来得及参与。
  ///
  /// [settled] 是**结果出口**（引用会被填充）："已探完的局域网候选 → 结果"
  /// （null = 本次不可达，含"拿满了等待上限仍没答"）。后面 `_pickFastest` 复用它能省掉
  /// 一次重复探活 —— 同一内网时那是白探，不在同一内网时那要白挂满 [probeTimeout]
  /// （单测实测：不复用时总耗时 4.5s）。
  static Future<AddressProbeResult?> _probeLanCandidates(
    Map<String, AddressProbeResult?> settled,
  ) async {
    final List<String> lans = lanCandidates;
    if (lans.isEmpty) return null;
    _log('局域网候选 ${lans.length} 个并行探活（等待上限 ${lanProbeGate.inMilliseconds}ms）：'
        '${lans.join(', ')}');

    final Future<int?> Function(String) probe = debugFetchHealth ?? fetchHealth;
    final List<AddressProbeResult> ok = <AddressProbeResult>[];
    final Future<void> walking = Future.wait<void>(lans.map((String api) async {
      final int? ms = await _probeWithDeadline(probe, api);
      if (ms == null) {
        settled[api] = null; // 已探、不可达
        return;
      }
      final AddressProbeResult r = AddressProbeResult(api, ms);
      settled[api] = r;
      ok.add(r);
    }));

    // 等待上限：到点就用当前已知的最快者。
    //
    // 到点仍**没答**的候选（同一内网里"这台机器不在"的典型表现：SYN 出去没人应）
    // 标记为**本次不可达** —— 它们已经拿满了 [lanProbeGate] 的机会，再让后面的
    // `_pickFastest` 重探一次只会白挂满 [probeTimeout]（单测实测：总耗时 4.5s → 改善到 ~3s）。
    // 代价可接受：这一轮已经确认过彼此不在同一内网，本轮不会再走它。
    try {
      await walking.timeout(lanProbeGate);
    } catch (_) {
      // 只可能是超时（探活本身绝不抛）；忽略，用已探到的结果
    }
    for (final String api in lans) {
      settled.putIfAbsent(api, () => null);
    }

    if (ok.isEmpty) {
      _log('局域网候选均不可达（不在同一内网，或未在等待上限内应答）→ 跳过，不影响隧道解析');
      return null;
    }
    ok.sort((AddressProbeResult a, AddressProbeResult b) {
      final int byLatency = a.latencyMs.compareTo(b.latencyMs);
      if (byLatency != 0) return byLatency;
      return lans.indexOf(a.apiBaseUrl).compareTo(lans.indexOf(b.apiBaseUrl));
    });
    final AddressProbeResult best = ok.first;
    _log('局域网可达：${best.apiBaseUrl}（${best.latencyMs}ms）→ 优先于隧道');
    return best;
  }

  /// 自托管引导的"已知入口"清单（按可能性排序）：本机记住的上次可用地址 + 打包内置候选。
  static Future<List<String>> bootstrapHostCandidates() async {
    final List<String> out = <String>[];
    void add(String raw) {
      final String n = normalizeApiBase(raw);
      if (n.isNotEmpty && !out.contains(n)) out.add(n);
    }

    final Future<String?> Function()? loader = loadLastKnownGood;
    if (loader != null) {
      try {
        final String? last = await loader().timeout(lastKnownGoodTimeout);
        if (last != null && last.isNotEmpty) add(last);
      } catch (e) {
        _log('上次可用地址读取失败（忽略，不影响解析）：${_short(e)}');
      }
    }
    for (final String c in builtinCandidates) {
      add(c);
    }
    return out;
  }

  /// **多源引导地址清单（按顺序尝试，任一成功即用）** —— 本轮地址发现韧性的核心。
  ///
  /// | 顺序 | 源 | 需要第三方账号 | 实测（2026-10-06 本机） |
  /// |---|---|---|---|
  /// | 0 | `override`（`ADDRESS_BOOTSTRAP` 显式钉死，**排他**） | 否 | —— |
  /// | 1 | `gitee`（Gitee raw） | 是（负责人提供后注入） | 0.25s 可达（仓库未建时 404） |
  /// | 2 | `self-hosted`（`<候选>/site/client-config.json`，同族并行） | **否** | 200 / 1.16s ✅ |
  /// | 3 | `jsdelivr`（GitHub 仓库 CDN 镜像） | 否（用 GitHub 仓库） | CDN 可达 ✅ |
  /// | 4 | `github-raw`（末位兼容） | 否 | **http=000 不可达** ❌ |
  ///
  /// 为什么自托管排在 jsDelivr/GitHub 之前：它**不依赖任何第三方**，且下发的是
  /// 服务端自己那份（永远与后端一致）；第三方只作为"服务端整站都不可达"时的旁路。
  static Future<List<AddressBootstrapSource>> bootstrapSources() async {
    final List<AddressBootstrapSource>? override = debugBootstrapSources;
    if (override != null) return override;

    // 显式钉死：只用一个源（保持"pin 一个 URL"的既有语义）
    if (explicitBootstrapUrl.isNotEmpty) {
      return <AddressBootstrapSource>[
        AddressBootstrapSource('override', explicitBootstrapUrl),
      ];
    }

    final List<AddressBootstrapSource> out = <AddressBootstrapSource>[];
    // ① Gitee raw（未配置则整条跳过）
    if (giteeBootstrapUrl.isNotEmpty) {
      out.add(AddressBootstrapSource('gitee', giteeBootstrapUrl));
    }
    // ② 服务端自托管（同族并行：多个 host 谁先答应用谁）
    for (final String api in await bootstrapHostCandidates()) {
      final String origin = normalizeWsBase(api);
      if (origin.isEmpty) continue;
      out.add(AddressBootstrapSource('self-hosted', '$origin$selfHostedPath',
          parallel: true));
    }
    // ③ jsDelivr 镜像
    if (jsdelivrBootstrapUrl.isNotEmpty) {
      out.add(AddressBootstrapSource('jsdelivr', jsdelivrBootstrapUrl));
    }
    // ④ GitHub raw（末位兼容）
    if (githubBootstrapUrl.isNotEmpty) {
      out.add(AddressBootstrapSource('github-raw', githubBootstrapUrl));
    }
    return out;
  }

  // ---------------------------------------------------------------- 入口

  /// 入口：在 `main()` 里**后台**跑一次（有超时上限，最坏约 `bootstrapTotalBudget` 8s）。
  ///
  /// 返回解析结果，并把结果写回 [AppConfig]（`ApiClient()` / `RealtimeClient()` 立即可用）。
  /// **绝不抛异常**。
  static Future<AddressResolution> resolve() async {
    final ResolvedAddress builtin = ResolvedAddress(
      apiBaseUrl: builtinApiBase,
      wsBaseUrl: builtinWsBase,
      source: 'builtin',
      candidates: builtinCandidates,
    );

    if (!enabled) {
      _apply(builtin);
      _log('ADDRESS_BOOTSTRAP_ENABLED=false：完全走打包内置（不下发、不探活）'
          ' api=$builtinApiBase');
      return AddressResolution(address: builtin, fromBootstrap: false, probed: false);
    }

    final List<AddressBootstrapSource> sources = await bootstrapSources();
    _log('开始解析：引导源 ${sources.length} 个，按序尝试 '
        '[${sources.map((AddressBootstrapSource s) => s.name).join(' > ')}]'
        ' | 内置候选 ${builtinCandidates.length} 个'
        '（其中局域网 ${lanCandidates.length} 个，优先）');

    /**
     * 【局域网优先 · 唯一改动点】（2026-10-06）
     *
     * 原实现："隧道先赢就不试内置候选" —— 于是**在家连同一个 WiFi** 也永远走
     * Cloudflare 快速隧道（实测上行 16KB/s，322KB 图要 20.7s），而局域网直连是
     * 6.3MB/s（0.05s）。用户体感就是"上传卡死"。
     *
     * 现在：局域网候选探活与引导/隧道解析**并行**发起，但只等 [lanProbeGate]（1.5s）；
     * 局域网可达 → **直接赢下优先级**，隧道那条腿的结果连用都不用。
     * 局域网不可达/超时 → 结果被丢弃，**后续全部逻辑逐字不变**（preferred → 最快隧道
     * → 内置候选 → 编译期兜底），因此"不在内网"的设备行为与改动前完全一致。
     *
     * 为什么并行而不是"先探局域网再探隧道"：串行会让冷启动多等一个 RTT（隧道弱网下
     * 可达 1.2s）；并行时局域网几乎总是先答（同 WiFi 实测 9ms），零额外代价。
     */
    final Map<String, AddressProbeResult?> lanSettled = <String, AddressProbeResult?>{};
    final Future<AddressProbeResult?> lanFuture = _probeLanCandidates(lanSettled);
    unawaited(lanFuture.catchError((Object _) => null));
    // 引导拉取也**兜住异常**：TCP connect 失败（后端全挂）同样会抛 —— 不能让它
    // 从并发分支里冒出来变成 uncaught，也不能影响局域网那条腿的判定。
    final Future<_BootstrapAttempt> attemptFuture = _fetchFromSources(sources)
        .catchError((Object e) => _BootstrapAttempt(
              null,
              <String>['引导源全部异常（已兜底）：${_short(e)}'],
              0,
            ));

    // 决策要等两条腿：局域网（受 1.5s 上限约束）+ 引导拉取
    await Future.wait<void>(<Future<void>>[lanFuture, attemptFuture]);
    final _BootstrapAttempt attempt = await attemptFuture;
    final AddressProbeResult? lanPick = await lanFuture;
    if (lanPick != null) {
      final ResolvedAddress lanChosen = ResolvedAddress(
        apiBaseUrl: lanPick.apiBaseUrl,
        wsBaseUrl: normalizeWsBase(lanPick.apiBaseUrl),
        source: 'lan',
        latencyMs: lanPick.latencyMs,
        candidates: <String>[lanPick.apiBaseUrl, ...builtinCandidates]
            .toSet()
            .toList(growable: false),
      );
      _applyChoice(lanChosen, label: '解析完成 source=lan（局域网优先）');
      return AddressResolution(address: lanChosen, fromBootstrap: false, probed: true);
    }

    if (attempt.win == null) {
      // ---- 全部引导源失败 → 内置多候选并行探活（最快者胜） ----
      // 局域网候选已在上面探过一轮 → 复用结果（`lanSettled`），不再重复探
      final AddressProbeResult? best = builtinCandidates.length > 1
          ? await _pickFastest(builtinCandidates, known: lanSettled)
          : null;
      final ResolvedAddress fallback = best == null
          ? builtin
          : ResolvedAddress(
              apiBaseUrl: best.apiBaseUrl,
              wsBaseUrl: normalizeWsBase(best.apiBaseUrl),
              source: 'builtin+probe',
              latencyMs: best.latencyMs,
              candidates: builtinCandidates,
            );
      _apply(fallback);
      // 探活确认过可用的内置候选也值得记住（它是"真的通"的地址，
      // 下次冷启动可以直接拿它当自托管引导的入口）
      if (best != null) _remember(best.apiBaseUrl);
      final String err = '下发不可用：'
          '${attempt.errors.isEmpty ? '无可用引导源' : attempt.errors.join(' | ')}';
      _log('$err | 回退 ${fallback.source} api=${fallback.apiBaseUrl}'
          '${best == null ? '' : '（内置候选并行探活最快 ${best.latencyMs}ms）'}');
      return AddressResolution(
        address: fallback,
        fromBootstrap: false,
        probed: best != null || builtinCandidates.length > 1,
        error: err,
      );
    }

    final AddressBootstrap cfg = attempt.win!.config;
    // 多候选并行探活 → 最快者胜（单候选也探一次确认可用）；
    // 下发若声明了 preferred（如 ngrok 固定域名），它活着就优先用它 —— 见 AddressBootstrap.preferred
    final AddressProbeResult? best =
        await _pickFastest(cfg.candidates, preferred: cfg.preferred);
    String chosenApi = best?.apiBaseUrl ?? cfg.candidates.first;
    String source = best == null ? 'bootstrap' : 'bootstrap+probe';
    int? latency = best?.latencyMs;
    String? probeError =
        best == null ? '候选择活全部失败，按首条下发地址尝试' : null;
    if (best != null && cfg.preferred != null && best.apiBaseUrl == cfg.preferred) {
      source = 'bootstrap+preferred';
    }

    // 下发候选全挂时，再看一眼**打包内置候选**（有多个才值得探）：
    // 典型场景 = 下发内容过期（还指着已经限流的 ngrok 域名），而机器上另一条隧道活着。
    AddressProbeResult? builtinPick;
    if (best == null && builtinCandidates.length > 1) {
      builtinPick = await _pickFastest(builtinCandidates, known: lanSettled);
      if (builtinPick != null) {
        chosenApi = builtinPick.apiBaseUrl;
        source = 'bootstrap+builtin';
        latency = builtinPick.latencyMs;
        probeError =
            '下发候选择活全部失败，改用内置候选 ${builtinPick.apiBaseUrl}（${builtinPick.latencyMs}ms）';
      }
    }

    final ResolvedAddress chosen = ResolvedAddress(
      apiBaseUrl: chosenApi,
      wsBaseUrl: _wsFor(cfg, chosenApi),
      source: source,
      latencyMs: latency,
      candidates: cfg.candidates,
      bootstrapFrom: attempt.win!.source,
    );
    _apply(chosen);
    _log('解析完成 source=$source from=${attempt.win!.source} '
        'api=$chosenApi kind=${chosen.kindLabel} latency=${latency ?? '-'}ms '
        'candidates=${cfg.candidates.length} '
        '引导耗时=${attempt.elapsedMs}ms error=${probeError ?? '-'}');
    _remember(chosenApi);
    return AddressResolution(
      address: chosen,
      fromBootstrap: true,
      probed: best != null || cfg.candidates.length > 1 || builtinPick != null,
      error: probeError,
    );
  }

  /// 落盘一个选定地址 + 打一行日志（[resolve] 的成功路径共用，避免几处各写一遍）。
  ///
  /// **只做"生效 + 记忆 + 日志"**，刻意不构造 [AddressResolution]：
  /// 那三个字段（`fromBootstrap` / `probed` / `error`）每条路径的语义各不相同，
  /// 收口到这里就必然改写既有返回语义（`AddressWatchdog.noteStartup` 直接读它们）。
  static void _applyChoice(ResolvedAddress address, {required String label}) {
    _apply(address);
    _log('$label api=${address.apiBaseUrl} kind=${address.kindLabel} '
        'latency=${address.latencyMs ?? '-'}ms candidates=${address.candidates.length}');
    _remember(address.apiBaseUrl);
  }

  /// 把解析结果写进运行期地址槽（AppConfig.apiBase / wsBase 由此生效）
  static void _apply(ResolvedAddress a) => AppConfigRuntime.apply(
        api: a.apiBaseUrl,
        ws: a.wsBaseUrl,
        from: a.source,
        bootstrapFrom: a.bootstrapFrom ?? '',
        latencyMs: a.latencyMs,
        candidateCount: a.candidates.length,
      );

  /// 记住"本次解析生效的地址"，供下次自托管引导使用（写失败完全不影响主流程）
  static void _remember(String apiBase) {
    final Future<void> Function(String apiBase)? save = saveLastKnownGood;
    if (save == null) return;
    try {
      unawaited(save(apiBase).timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      ).catchError((Object _) {}));
    } catch (_) {
      /* 忽略：记忆失败只是少一条自托管入口 */
    }
  }

  /// 最终地址对应的 ws 地址。
  ///
  /// 只有当选中的地址**确实来自这份下发内容**时才用下发里显式声明的 `ws`
  /// （否则会把"另一台服务器的 ws"配到这台服务器上 —— 内置候选顶上的场景就是这么错配的）。
  static String _wsFor(AddressBootstrap cfg, String apiBase) {
    final String? ws = cfg.wsBaseUrl;
    if (ws != null && ws.isNotEmpty && cfg.candidates.contains(apiBase)) return ws;
    return normalizeWsBase(apiBase);
  }

  /// 把地址规范成 `<scheme>://<host>[:port]/api/v1`
  ///
  /// - `https://x.com`            → `https://x.com/api/v1`
  /// - `https://x.com/`           → `https://x.com/api/v1`
  /// - `https://x.com/api/v1/`    → `https://x.com/api/v1`
  /// - `http://192.168.1.145:3100`→ `http://192.168.1.145:3100/api/v1`
  static String normalizeApiBase(String raw) {
    String s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) s = 'https://$s';
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (s.endsWith('/api/v1')) return s;
    return '$s/api/v1';
  }

  /// 把地址规范成 Socket.IO 根地址（去掉 /api/v1 后缀与末尾斜杠）
  static String normalizeWsBase(String raw) {
    String s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) s = 'https://$s';
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (s.endsWith('/api/v1')) s = s.substring(0, s.length - '/api/v1'.length);
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  /// 探活：GET `<api>/health` 要求 HTTP 200 **且正文是 FISH 统一响应**（docs/03）。
  /// 返回毫秒耗时；不可用返回 null。
  ///
  /// 为什么不能只看状态码（2026-10-04 实测）：ngrok 免费档的浏览器警示插页也是
  /// **HTTP 200**（`text/html`）。只看状态码 → 插页被当成"探活成功" → 真实地址选错。
  /// 因此这里多读一次正文并用 [isHealthBody] 校验；解析失败/字段不对一律视为不可用，
  /// 让其它候选（或内置地址）接管。
  static Future<int?> fetchHealth(String apiBaseUrl) async {
    final HttpClient client = createHttpClient(probeTimeout);
    final Stopwatch sw = Stopwatch()..start();
    try {
      final Uri uri = Uri.parse('$apiBaseUrl/health');
      final HttpClientRequest req = await client.getUrl(uri).timeout(probeTimeout);
      applyCommonHeaders(req);
      final HttpClientResponse res = await req.close().timeout(probeTimeout);
      if (res.statusCode != 200) {
        await res.drain<void>().timeout(probeTimeout);
        return null;
      }
      // 正文很小（约 220 字节），读它不影响探活耗时上限
      final String body =
          await res.transform(utf8.decoder).join().timeout(probeTimeout);
      if (!isHealthBody(body)) return null;
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _fetch(String url) async {
    final Future<String> Function(String)? hook = debugFetchBootstrap;
    if (hook != null) return hook(url);
    final HttpClient client = createHttpClient(bootstrapTimeout);
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse(url)).timeout(bootstrapTimeout);
      applyCommonHeaders(req);
      final HttpClientResponse res = await req.close().timeout(bootstrapTimeout);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      return await res.transform(utf8.decoder).join().timeout(bootstrapTimeout);
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------- 多源拉取

  /// 按序尝试全部引导源；返回"命中"或"全部失败的原因清单"。
  ///
  /// 冲突处理：[AddressBootstrapSource.parallel] 的同名源（自托管族）**并行竞争**，
  /// 先成功者胜 —— 否则"3 个内置候选逐个等 3.5s"会白等 10s，冷启动直接崩体验。
  static Future<_BootstrapAttempt> _fetchFromSources(
    List<AddressBootstrapSource> sources,
  ) async {
    final Stopwatch sw = Stopwatch()..start();
    final List<String> errors = <String>[];
    final List<List<AddressBootstrapSource>> groups = _groupSources(sources);

    for (int i = 0; i < groups.length; i++) {
      if (sw.elapsedMilliseconds >= bootstrapTotalBudget.inMilliseconds) {
        errors.add('引导源总预算 ${bootstrapTotalBudget.inMilliseconds}ms 用尽，'
            '跳过剩余 ${groups.length - i} 组');
        _log('引导源总预算用尽（${sw.elapsedMilliseconds}ms），剩余 ${groups.length - i} 组不再尝试');
        break;
      }
      final List<AddressBootstrapSource> group = groups[i];
      if (group.length == 1) {
        final AddressBootstrapSource s = group.first;
        try {
          final AddressBootstrap cfg = await _fetchOne(s);
          _log('引导源命中：${s.name}（${sw.elapsedMilliseconds}ms，'
              '${cfg.candidates.length} 个候选）${s.url}');
          return _BootstrapAttempt(
            _BootstrapWin(s.name, cfg, sw.elapsedMilliseconds),
            errors,
            sw.elapsedMilliseconds,
          );
        } catch (e) {
          errors.add('${s.name}:${_short(e)}');
          _log('引导源失败：${s.name} → ${_short(e)}');
        }
        continue;
      }
      final _BootstrapWin? win = await _raceGroup(group, errors, sw);
      if (win != null) {
        return _BootstrapAttempt(win, errors, sw.elapsedMilliseconds);
      }
    }
    return _BootstrapAttempt(null, errors, sw.elapsedMilliseconds);
  }

  /// 把源清单折叠成"组"：同名且 parallel 的连续源合成一组（并行竞争）
  static List<List<AddressBootstrapSource>> _groupSources(
    List<AddressBootstrapSource> sources,
  ) {
    final List<List<AddressBootstrapSource>> groups =
        <List<AddressBootstrapSource>>[];
    for (final AddressBootstrapSource s in sources) {
      final bool mergeable = s.parallel &&
          groups.isNotEmpty &&
          groups.last.first.parallel &&
          groups.last.first.name == s.name;
      if (mergeable) {
        groups.last.add(s);
      } else {
        groups.add(<AddressBootstrapSource>[s]);
      }
    }
    return groups;
  }

  static Future<AddressBootstrap> _fetchOne(AddressBootstrapSource s) async {
    final String raw = await _fetch(s.url).timeout(bootstrapTimeout);
    return AddressBootstrap.parse(raw);
  }

  /// 同族并行竞争：先成功者胜；全失败返回 null
  static Future<_BootstrapWin?> _raceGroup(
    List<AddressBootstrapSource> group,
    List<String> errors,
    Stopwatch sw,
  ) {
    final Completer<_BootstrapWin?> done = Completer<_BootstrapWin?>();
    int pending = group.length;
    for (final AddressBootstrapSource s in group) {
      _fetchOne(s).then((AddressBootstrap cfg) {
        if (!done.isCompleted) {
          _log('引导源命中（并行族 ${s.name}）：${sw.elapsedMilliseconds}ms '
              '${cfg.candidates.length} 个候选 ${s.url}');
          done.complete(_BootstrapWin(s.name, cfg, sw.elapsedMilliseconds));
        }
      }).catchError((Object e) {
        errors.add('${s.name}:${_short(e)}');
        _log('引导源失败（并行族 ${s.name}）：${s.url} → ${_short(e)}');
        pending -= 1;
        if (pending <= 0 && !done.isCompleted) done.complete(null);
      });
    }
    return done.future.timeout(
      bootstrapTimeout + const Duration(milliseconds: 500),
      onTimeout: () => null,
    );
  }

  /// 多候选并行探活，返回**最快**的可用候选（全部失败返回 null）。
  ///
  /// [preferred] 非空且它**自己探活通过**时，直接返回它（不看延迟）——
  /// 用于"固定域名活着就用固定域名"（见 [AddressBootstrap.preferred]）。
  /// preferred 探活失败 = 当没写，退回最快者胜。
  ///
  /// [known] = **已经探过的候选及其结果**（值 null = 已探过且不可达）。
  ///
  /// 为什么需要它（2026-10-06 局域网优先专项，单测实测抓到）：局域网候选在 [resolve]
  /// 开头的"局域网优先"那一轮已经被探过一次了；若这里再探一次，而在**同一内网**时
  /// 它是可达的、**不在同一内网**时它要挂满 [probeTimeout]（2.5s）—— 于是"内置候选顶上"
  /// 这条既有路径会白等一个完整的探活超时（实测总耗时 4.5s）。
  /// 复用第一轮结果后**既省这一次等待、也不改变选中结果**（同一个地址、同一个延迟读数），
  /// 因此既有语义（最快者胜 / 并列取靠前）逐字不变。
  static Future<AddressProbeResult?> _pickFastest(
    List<String> candidates, {
    String? preferred,
    Map<String, AddressProbeResult?> known = const <String, AddressProbeResult?>{},
  }) async {
    if (candidates.isEmpty) return null;
    final Future<int?> Function(String) probe = debugFetchHealth ?? fetchHealth;
    final List<AddressProbeResult> ok = <AddressProbeResult>[];
    await Future.wait(candidates.map((String api) async {
      // 已探过的候选直接复用结果（见 [known] 的说明），**不重复探活**
      if (known.containsKey(api)) {
        final AddressProbeResult? hit = known[api];
        if (hit != null) ok.add(hit);
        return;
      }
      final int? ms = await _probeWithDeadline(probe, api);
      if (ms != null) ok.add(AddressProbeResult(api, ms));
    }));
    if (ok.isEmpty) return null;
    if (preferred != null && preferred.isNotEmpty) {
      for (final AddressProbeResult r in ok) {
        if (r.apiBaseUrl == preferred) return r;
      }
    }
    // 并列时取候选顺序靠前的（稳定，避免同一份下发在不同机型选到不同出口）
    ok.sort((AddressProbeResult a, AddressProbeResult b) {
      final int byLatency = a.latencyMs.compareTo(b.latencyMs);
      if (byLatency != 0) return byLatency;
      return candidates.indexOf(a.apiBaseUrl).compareTo(candidates.indexOf(b.apiBaseUrl));
    });
    return ok.first;
  }

  /// 单候选探活 + 硬超时：超时/抛错一律视为不可用（null）。
  ///
  /// 不用 `Future.timeout` 的原因：其 `onTimeout` 返回类型会被推断成非空 `int`，
  /// 传 null 兜底会在运行期抛类型错误（2026-10-04 单测抓到）。
  static Future<int?> _probeWithDeadline(
    Future<int?> Function(String) probe,
    String api,
  ) {
    final Completer<int?> done = Completer<int?>();
    Timer? timer;
    probe(api).then((int? ms) {
      if (!done.isCompleted) done.complete(ms);
    }).catchError((Object _) {
      if (!done.isCompleted) done.complete(null);
    });
    timer = Timer(probeTimeout + const Duration(milliseconds: 500), () {
      if (!done.isCompleted) done.complete(null);
    });
    return done.future.whenComplete(() => timer?.cancel());
  }

  // ---------------------------------------------------------------- 日志

  static void _log(String msg) {
    final void Function(String)? sink = debugLog;
    if (sink != null) {
      sink(msg);
      return;
    }
    debugPrint('[address] $msg');
  }

  /// 错误信息压成一行（异常消息里带 URI 时很长，日志没必要全量）
  static String _short(Object e) {
    final String s = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    return s.length <= 160 ? s : '${s.substring(0, 157)}...';
  }
}

/// 一次多源拉取的产物
class _BootstrapAttempt {
  _BootstrapAttempt(this.win, this.errors, this.elapsedMs);

  final _BootstrapWin? win;
  final List<String> errors;
  final int elapsedMs;
}

/// 命中的引导源
class _BootstrapWin {
  _BootstrapWin(this.source, this.config, this.elapsedMs);

  final String source;
  final AddressBootstrap config;
  final int elapsedMs;
}
