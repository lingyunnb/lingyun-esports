/// 运行环境配置：全部通过 --dart-define 注入（禁止在业务代码中写死地址，docs/11）
///
/// 开发（Android 模拟器）：默认值即可（10.0.2.2 = 模拟器访问宿主机）
/// 开发（Android 真机，需与电脑同一局域网）：
///   flutter run --dart-define=API_BASE_URL=http://<电脑局域网IP>:3100/api/v1 \
///               --dart-define=WS_BASE_URL=http://<电脑局域网IP>:3100
/// 公网（Cloudflare Tunnel）：
///   --dart-define=API_BASE_URL=https://<隧道域名>/api/v1 --dart-define=WS_BASE_URL=https://<隧道域名>
///
/// 【2026-10-04 地址动态下发】编译期常量只是**打包内置的兜底**；App 启动时
/// [AppAddressResolver.resolve] 会从固定引导地址拉当前真实地址并写进 [AppConfig]。
/// 因此隧道地址变化不再需要重新发版（详见 app_address.dart 与 docs/11）。
/// 业务代码一律用 [apiBase] / [wsBase] / [resolveMediaUrl]，不要直接读编译期常量。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'app_address.dart';
import 'app_config_runtime.dart';

/// 全局 API 前缀（`main.ts` 的 `setGlobalPrefix` 用的就是它；唯一出处，别在各处写字符串）
///
/// 客户端需要它的唯一原因是：**判断一个服务端路径该不该带前缀**
/// （见 [AppConfig.resolveMediaUrl] 的前缀规则表）。
const String kApiPrefix = '/api/v1';

class AppConfig {
  AppConfig._();

  /// 编译期注入的 HTTP API 基础地址（/api/v1）—— 兜底值，不是最终生效值
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3100/api/v1',
  );

  /// 编译期注入的 Socket.IO 地址（与 API 同源同端口，M6 聊天使用）—— 兜底值
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'http://10.0.2.2:3100',
  );

  /// **实际生效**的 API 地址：已成功下发时是下发地址，否则是编译期地址。
  static String get apiBase => AppConfigRuntime.apiBaseUrl ?? apiBaseUrl;

  /// **实际生效**的 Socket.IO 地址。
  static String get wsBase => AppConfigRuntime.wsBaseUrl ?? wsBaseUrl;

  /// 是否已用上下发地址（诊断/排查用）
  static bool get usingDispatchedAddress => AppConfigRuntime.source != null;

  /// 地址来源：`builtin` / `bootstrap` / `bootstrap+probe`（null = 尚未解析）
  static String? get addressSource => AppConfigRuntime.source;

  /// 当前生效地址的主机部分（去掉 `/api/v1`）—— 报障时用户真正需要念/截图的那一段
  static String get apiHost =>
      apiBase.replaceFirst(RegExp(r'/api/v1/?$'), '');

  /// **诊断行**（2026-10-06 地址发现韧性专项）：「我的 → 设置」展示一行
  /// 「当前服务器地址」，用户报障时截图即可，不必再猜是哪条隧道。
  ///
  /// 形如 `192.168.1.145:3100 · LAN · lan 9ms`
  /// 或 `<your-tunnel-domain> · 隧道 · bootstrap+probe(self-hosted)`
  /// 运行期热切换过还会带上切换次数；未解析时为 `… · 未解析`。
  ///
  /// 【2026-10-06 局域网优先专项】**行首加地址类别**（`LAN` / `隧道` / `直连` / `未知`）：
  /// 上传卡不卡，先看这一格 —— `LAN` 就是"同一 WiFi 走内网直连"，实测比隧道快约 400 倍。
  ///
  /// 类别**只在真的解析过**（[AppConfigRuntime.source] 非空）时才写：
  /// 未解析时显示的 `http://10.0.2.2:3100` 是**编译期兜底地址**（Android 模拟器别名），
  /// 它恰好落在私网段里 —— 给它贴一个 `LAN` 标签会让人误以为"已经确认走局域网了"。
  /// 未解析时的文案保持历史行为（`host · 未解析`，既有断言逐字不变）。
  static String get serverAddressLine {
    final String? source = AppConfigRuntime.source;
    final bool resolved = source != null;
    final String src = source ?? '未解析';
    final String from = AppConfigRuntime.bootstrapFrom ?? '';
    final int? ms = AppConfigRuntime.latencyMs;
    final int? n = AppConfigRuntime.candidateCount;
    final StringBuffer sb = StringBuffer(apiHost);
    if (resolved) sb.write(' · ${AppAddressResolver.addressKindOf(apiBase).label}');
    sb.write(' · ');
    sb.write(src);
    if (from.isNotEmpty) sb.write('($from)');
    if (ms != null) sb.write(' ${ms}ms');
    if (n != null && n > 1) sb.write(' 候选$n');
    if (AppConfigRuntime.switchCount > 0) {
      sb.write(' 已切换${AppConfigRuntime.switchCount}次');
    }
    return sb.toString();
  }

  /// 当前 App 数字版本号（云端更新版本比较依据；构建时 --dart-define 注入，禁止写死）
  static const int appVersionCode = int.fromEnvironment('APP_VERSION_CODE', defaultValue: 1);

  /// 当前 App 展示版本名（如 1.0.1）
  static const String appVersionName = String.fromEnvironment('APP_VERSION_NAME', defaultValue: '1.0.0');

  /// 「我的 → 设置 → 诊断」里显示的**版本行**：`v<版本名>（<版本码>）`
  ///
  /// 【2026-10-07 负责人要求】为什么必须让用户自查版本：一天之内多次需要确认
  /// "手机上到底是哪一版"（发版验收、灰度判断、报障复现），而此前 App 里**没有任何一处**
  /// 显示版本号 —— 只能靠"截图发我看看"或远程猜。
  ///
  /// 两个值都取 [appVersionName] / [appVersionCode]（构建时 `--dart-define` 注入，
  /// **禁止写死**），格式与云端更新弹窗、发布脚本的口径一致。
  static String get versionLine => 'v$appVersionName（$appVersionCode）';

  /// 把后端返回的相对媒体/接口路径解析为绝对 URL。
  /// 绝对 http(s) URL 原样返回；相对路径拼接到**当前生效**的 API 主机上
  /// —— 保证局域网/Tunnel/域名环境一致可用（docs/11）
  ///
  /// ## ⚠️ 全局前缀 `/api/v1` 的归属（2026-10-07 修「付款凭证图一直转圈」时收敛的规则）
  ///
  /// 服务端真实路由分两类，**传参必须与服务端路由逐字一致**：
  ///
  /// | 路由 | 真实路径 | 传参 |
  /// |---|---|---|
  /// | 公开媒体（`main.ts` 的 `setGlobalPrefix` 排除了它） | `/media/public/:id` | `/media/public/$id` —— **不带** `/api/v1` |
  /// | 其它所有接口（含 `/api/v1/media/protected/:id`） | 挂在全局前缀下 | **必须自己带** `/api/v1/...` |
  ///
  /// 本方法**不会**替你补前缀（它只做"相对路径 → 绝对地址"），但**会保留**你已经写对的前缀：
  /// 入参以 `/api/v1` 开头时按"主机 = apiBase 去掉前缀"拼接，结果与传参**逐字相等**。
  ///
  /// 历史坑（同一根因的三种表现，别回退）：
  /// - 调用方漏写前缀（如 `/recharge/proof/48`）→ 打到不存在的路径 → 404 / SPA HTML → 图永远转圈；
  /// - 调用方**写对**了前缀，但这里无条件 `replaceFirst` 把它剥掉
  ///   （如服务端下发的 `/api/v1/public/app-versions/download/113`）→ 同样 404，且更新包下载直接失败；
  /// - 两类混用（顺手给 `/media/public/*` 加前缀）→ 把公开图弄坏。
  static String resolveMediaUrl(String pathOrUrl) {
    if (pathOrUrl.isEmpty || pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }
    return '${apiHostFor(pathOrUrl)}$pathOrUrl';
  }

  /// 受保护媒体的**真实路由**（`/api/v1/media/protected/:id`）拼成绝对地址
  ///
  /// 【2026-10-07 收敛「图出不来」的同一根因】受保护媒体（聊天图片 / 投诉截图 / 头像 / 付款凭证）
  /// 挂在**全局前缀**下（`main.ts` 的 `setGlobalPrefix` 只排除 `media/public/*`），
  /// 而历史上各页面**各拼各的**，于是出现两种坏法：
  /// - 少了 `/api/v1`（`complaint_page.dart` 的 `/media/protected/$id`、`/media/chat/$id`）→ 404；
  /// - 路径整条不存在（`chat_detail_page.dart` 的 `/media/chat/$id`）→ 404。
  ///
  /// 现在只留这一处实现：**路径唯一出处 + 与 [resolveMediaUrl] 的前缀规则天然一致**
  /// （入参自带 `/api/v1`，`apiHostFor` 会保留它）。
  ///
  /// ⚠️ 拿到地址**还必须带令牌**（`Authorization: Bearer <token>`，见 `authImageHeaders`），
  /// 受保护媒体对匿名请求一律 401 —— 光改路径不改请求头，图仍然出不来。
  static String protectedMediaUrl(String mediaId) =>
      resolveMediaUrl('$kApiPrefix/media/protected/$mediaId');

  /// 给某个路径拼绝对地址时应该用的**主机前缀**（见 [resolveMediaUrl] 的前缀规则）
  ///
  /// - 路径带 `/api/v1` → 主机 = `apiBase` **去掉** `/api/v1`（拼回去与原路径逐字相等）；
  /// - 路径不带 → 主机 = `apiBase` 原样（公开媒体是根路径，必须落在 `/api/v1` 之外）。
  ///
  /// 兜底方向是**保持旧行为**：`apiBase` 不含 `/api/v1` 时不做任何剥离，
  /// 避免"想修前缀反而把地址改坏"（宁可与改动前一致，也不猜）。
  @visibleForTesting
  static String apiHostFor(String pathOrUrl) {
    final bool carriesPrefix = pathOrUrl == kApiPrefix || pathOrUrl.startsWith('$kApiPrefix/');
    // 不带前缀（公开媒体 / 站点静态资源）：**沿用改动前的实现**（剥掉结尾的 /api/v1），
    // 这一条是线上跑了很久的行为，逐字节不动。
    if (!carriesPrefix) return _legacyHost();
    // 带前缀（受保护媒体、/recharge/proof/*、/public/app-versions/download/* 等接口路径）：
    // 入参已经写对了前缀，主机必须是"去前缀的 apiBase"，否则会拼出 /api/v1/api/v1/...
    final int i = apiBase.indexOf(kApiPrefix);
    if (i <= 0) return _legacyHost(); // 地址里没有 /api/v1 可剥 → 保持旧行为（不猜）
    return apiBase.substring(0, i);
  }

  /// 改动前的 `resolveMediaUrl` 主机算法（唯一出处，见 [apiHostFor]）
  static String _legacyHost() => apiBase.replaceFirst(RegExp(r'/api/v1/?$'), '');
}
