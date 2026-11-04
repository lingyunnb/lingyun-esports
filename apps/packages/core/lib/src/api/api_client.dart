import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'api_cache.dart';

import '../config/app_config.dart';

/// 服务端字段级错误（400 响应里的 `fields[]` 一项，服务端已中文化）
///
/// 校验失败时服务端返回形如：
/// `{ "field": "username", "label": "账号", "message": "至少 3 个字符" }`
/// 客户端据此把提示落到**对应输入框下方**（见 `AppFieldError` / `FormErrors`）。
class FieldError {
  const FieldError({required this.field, required this.label, required this.message});

  /// 原始字段路径（服务端 DTO 属性名，如 `username` / `items.0.mediaId`）
  final String field;

  /// 字段中文标签（服务端未收录时是字段名本身）
  final String label;

  /// 中文错误文案
  final String message;

  factory FieldError.fromJson(Map json) => FieldError(
        field: '${json['field'] ?? ''}',
        label: '${json['label'] ?? json['field'] ?? ''}',
        message: '${json['message'] ?? ''}',
      );

  @override
  String toString() => 'FieldError($field: $message)';
}

/// 业务异常：携带服务端返回的错误信息，UI 层直接展示
class ApiException implements Exception {
  const ApiException(this.code, this.message, this.requestId, {this.errorCode = '', this.fields = const []});

  final int code;
  final String message;
  final String requestId;

  /// 服务端业务错误码（如 ACCOUNT_BANNED=账号被封禁），用于客户端差异化处理（弹窗等）
  final String errorCode;

  /// 字段级校验错误（服务端 errorCode=VALIDATION_FAILED 时给出）
  final List<FieldError> fields;

  /// 是否可把错误落到具体输入框（表单行内提示）
  bool get hasFieldErrors => fields.isNotEmpty;

  @override
  String toString() => 'ApiException($code): $message [$requestId]';
}

/// API 客户端封装（docs/03：统一响应/错误处理/请求ID 透传）
///
/// baseUrl 优先取**运行期下发的地址**（AppConfig.apiBase ← 固定引导地址解析，见 app_address.dart），
/// 未解析到时用 --dart-define=API_BASE_URL 的编译期兜底值；
/// 禁止在页面里写死 http://localhost 之类的地址（docs/11）。
class ApiClient {
  /// 全局会话踢出钩子（单设备登录，docs/04）：收到 401"账号已在其他设备登录"时触发，
  /// 由 AuthStore 在构造时注册，应用根组件弹出提示并回到登录页。
  static void Function(String message)? onSessionKicked;

  /// 令牌过期自动刷新钩子（2026-09-25 修复"用一会儿就提示登录已过期"）：
  /// access token 有效期 2 小时，此前只在 App 启动时刷新 —— 长时间使用后所有接口 401、
  /// 页面显示"登录已过期请重新登录"（消息页打不开就是这么来的）。
  /// 现在任何请求遇到该 401 都会调用本钩子拿新 token 并自动重试一次（AuthStore 注册，内部做并发去重）。
  static Future<String?> Function()? onTokenExpired;

  /// **401 的令牌维度通知**（合并双端 · 身份切换，负责人 2026-10-06 方案甲）：
  /// 入参是「刚刚 401 的那个 token」与服务端中文原文，由 AuthStore 判断它是不是
  /// companion（伴随）令牌 —— 是则只丢打手身份并切回老板态，不把老板一起登出。
  ///
  /// 为什么不复用 [onSessionKicked]：那个钩子只在 `message == '账号已在其他设备登录'`
  /// 这一条**精确文案**上触发（primary 被顶号的专用语义），而伴随会话失效时服务端给的是
  /// 「伴随身份已失效，请重新绑定打手账号」等另一套文案 —— 用文案匹配必然漏。
  /// 本钩子纯新增：为 null 时一切行为与历史完全一致。
  static void Function(String? token, String message)? onUnauthorized;

  /**
   * **封禁（账号被封）专用钩子**（2026-10-16 负责人需求：「点了封禁直接踢下线，显示被封禁 + 原因」）。
   *
   * 触发条件（两条，都靠**服务端下发的稳定机器码**判定，绝不靠文案匹配）：
   *   1. HTTP 响应 `code == 401` 且 `errorCode == 'ACCOUNT_BANNED'`（守卫每请求下发）；
   *   2. WS 收到 `auth:expired` 且载荷里带同一个 `errorCode`（封禁踢线时服务端主动带上）。
   *
   * 入参 = 服务端中文原文，形如 `账号已被封禁：<原因>（解封时间：2026-11-01 12:00）`
   * （无原因时省略原因段；永久封禁是 `（永久）`）。客户端**原样展示，一个字都不改写**。
   *
   * 与 [onSessionKicked] / [onUnauthorized] 的分工：那两个是"会话被顶/受限会话失效"，
   * 它们的文案（「登录已失效，请重新登录」）**看不出账号被封** —— 这正是本次要修的用户可见缺口。
   * 默认 `null`：不注册时行为与历史逐字节相同。
   */
  static void Function(String message)? onAccountBanned;

  /**
   * 服务端封禁的机器码常量（客户端侧**唯一**字面量；`ApiClient` 与 `RealtimeClient` 共用）。
   * 服务端出处：`modules/auth/account-ban.check.ts` 的 `ACCOUNT_BANNED_CODE`。
   */
  static const String accountBannedErrorCode = 'ACCOUNT_BANNED';

  /// **网络类失败的全局钩子**（2026-10-06 地址发现韧性专项，纯新增）。
  ///
  /// 由 `AddressWatchdog` 注册：连续 N 次"连不上"就说明**当前地址已经失效**
  /// （隧道重开换了域名 / ngrok 额度耗尽 / 换网），此时必须重新走一遍地址发现并热切换，
  /// 而不是让用户对着"网络连接失败"重启 App。
  ///
  /// 语义边界（三条，保证零影响）：
  ///   1. 只在 `code == -1`（连不上/超时，即"服务端根本没答话"）时触发 ——
  ///      4xx/5xx 属于"服务端活着但拒绝了"，不是地址问题，绝不触发；
  ///   2. 默认 `null`：不注册时行为与历史**逐字节相同**；
  ///   3. 在**重试耗尽之后**才触发一次（一次逻辑请求算一次失败，不是一次底层尝试算一次）。
  static void Function(Object? error)? onNetworkFailure;

  /// **请求成功的全局钩子**（同上）：看门狗据此把"连续失败计数"清零。
  static void Function()? onNetworkSuccess;

  /// **最近一次触发 [onTokenExpired] 的令牌**（合并双端 · 身份切换时新增）
  ///
  /// 为什么用字段而不是改钩子签名：`onTokenExpired` 的 `Future<String?> Function()` 签名被
  /// core / boss-app / worker-app 三个包的既有单测**直接赋值使用**，改签名会波及它们；
  /// 而"到底是哪个令牌 401 了"只有 ApiClient 自己知道。于是：
  ///   - 发请求前把它设成本次请求用的 token → 调钩子 → 调用完清空；
  ///   - `AuthStore.refreshAccessToken()` 读它来决定刷 primary 还是 companion。
  /// 这样"老板态的请求 401"绝不会被误当成"伴随会话过期"去刷 companion（反之亦然）。
  static String? lastFailedToken;

  /// ngrok 免费档"浏览器警示插页"跳过头（2026-10-04，与 app_address.dart 同一常量语义）。
  ///
  /// 起因：ngrok 固定域名下，**浏览器式**请求会先收到一张"你即将访问 xxx"的插页
  /// （HTTP **200** + `text/html`），正文不是 JSON。Dio 默认不发浏览器 UA（见下方
  /// [appUserAgent]），但 Cloudflare / 未来可能接入的其它前置代理都可能按 UA 或按
  /// 其它特征插页；无条件带上这个头是零成本的保险。
  ///
  /// 安全性：不是鉴权头、不含敏感信息；Cloudflare / 局域网直连 / 云服务器一律忽略
  /// 未知请求头（HTTP 语义），因此**不区分 host**，不需要 ngrok 专用分支。
  static const String ngrokSkipWarningHeader = 'ngrok-skip-browser-warning';

  /// 该请求头的值（ngrok 只判断"存在且非空"）
  static const String ngrokSkipWarningValue = 'true';

  /// **最近一次请求收到的 HTTP 状态码**（0 = 还没有过请求或不是 HTTP 层失败）。
  ///
  /// 为什么需要它（2026-10-16 网卡治理专项）：首页要判断"`GET /public/home` 这个**路由
  /// 到底存不存在**"，据此决定是否进入"不再频繁探测"的电路保护。
  /// 业务错误码 `ApiException.code` 在"服务端（或代理/测试替身）回了 404 但信封里写 `code:0`"
  /// 这类情况下**不等于 HTTP 状态码**（实测踩到：`code` 被判成 0，按 `code == 404` 判定永远不成立）。
  /// HTTP 状态码才是"路由存不存在"的权威事实，因此在异常路径上把它单独记下来。
  ///
  /// 语义边界：只读、纯新增；**失败**时刷新（成功时为 200 不必记）。既有调用方一行都不用改。
  static int lastHttpStatus = 0;

  /// **测试专用**：全局默认 Dio（只在 `ApiClient()` 不传 `dio` 时兜底）
  ///
  /// 为什么需要它：老板端有些页面（如「我的」页）与 `AuthStore` 单例**自己在内部**
  /// `ApiClient()`，没有 `api` 注入口 —— 端到端地测"身份切换"就必须让它们也走假通道。
  /// 语义边界（三条，保证生产零影响）：
  ///   1. 默认 `null`：不设它时构造路径与历史**逐字节相同**；
  ///   2. 显式传 `dio` 的调用优先于它（单测既有的假适配器不受影响）；
  ///   3. 命中它时 `_followsRuntimeAddress = false` —— 不把测试 fixture 的地址
  ///      改写成运行期下发地址（否则请求会打到真服务器上去）。
  @visibleForTesting
  static Dio? debugDefaultDio;

  /// 显式非浏览器 UA。Dart HttpClient 默认就是 `Dart/<sdk> (dart:io)`（非浏览器样式），
  /// 这里写死一个自带标识的值，好处有二：
  ///   1) 前置代理/后端日志能一眼看出是 App 流量（默认 UA 看不出是哪个端）；
  ///   2) 即使将来有人给 Dio 换适配器或加 UA，也不会悄悄变成浏览器 UA 而踩插页。
  static const String appUserAgent = 'FishApp/1.0 (Dart; dart:io)';

  /**
   * 【2026-10-06 抢单大厅延迟专项：连接复用】**全进程唯一**的默认 Dio（= 唯一 HttpClient = 唯一连接池）。
   *
   * 背景（负责人反馈「抢单大厅切换延迟巨大」）：本类此前在**构造时各自 new 一个 Dio**，
   * 而 Dio 每个实例持有自己的 `IOHttpClientAdapter` → 自己的 `dart:io` HttpClient →
   * **自己的连接池**。而全仓有 **40+ 处** `ApiClient()`（几乎每个页面一个，见 boss-app
   * `lib/pages/` 各页的 `late final ApiClient _api = widget.api ?? ApiClient();`），
   * 于是：
   *   - 同一台手机上，"进大厅 → 切分部 → 下拉"每换一个页面/每次重建页面都可能**换一个连接池**；
   *   - 经 Cloudflare 快速隧道实测（`scripts/tmp/probe-hall-latency.mjs`）：
   *     **新建连接** connect 0.24–0.33s + **TLS 握手 0.49–0.60s**，首字节 1.03–1.28s；
   *     **复用连接** 首字节 0.52s（**省掉 0.5–0.78s/次**，且是最大单项开销）。
   *
   * 修法：`dio == null && debugDefaultDio == null`（= "默认构造"，生产里 40+ 处全部命中）
   * 一律复用这个静态实例 → 全程一个连接池，keep-alive 真正生效。
   *
   * 语义边界（四条，保证零影响）：
   *   1. **显式传 `dio` 的实例完全不走这里** —— 单测的假适配器、自定义通道行为逐字节不变；
   *   2. 它在**第一次取用时**才创建（惰性），所以 `debugDefaultDio` 的赋值时机与历史一致；
   *   3. `persistentConnection` **保持 Dart 默认（true）**、`Connection: close` 一个都没有
   *      （全仓 grep 无命中）—— keep-alive 没被谁关掉，只是此前每个实例各留各的连接池，
   *      池子随页面销毁而闲死，复用率≈0；
   *   4. 地址维度仍由 request 拦截器逐请求对齐（见下），共享它不会写死地址。
   */
  static final Dio sharedDio = () {
    final dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBase,
      // 每个请求默认携带的"防插页"头（请求级 headers 仍可覆盖同名键）
      headers: const <String, dynamic>{
        ngrokSkipWarningHeader: ngrokSkipWarningValue,
        'User-Agent': appUserAgent,
      },
      // 超时兜底：防止坏连接（半死隧道/假连）导致界面无限挂起（docs/11）
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ));
    _attachInterceptor(dio);
    return dio;
  }();

  /// 生产里 40+ 处 `ApiClient()` 全部落到上面这一个 Dio（连接池从此唯一）。
  ///
  /// `baseUrl` 形参已废弃：历史上它就没人传（全仓调用点都是裸 `ApiClient()` 或 `ApiClient(dio:)`），
  /// 保留一个"只对非共享实例生效"的地址旋钮只会制造第二种地址来源（docs/11 单一真相）。
  ApiClient({Dio? dio})
      : _followsRuntimeAddress = dio == null && debugDefaultDio == null,
        dio = dio ?? debugDefaultDio ?? sharedDio {
    /**
     * 【**千万别把拦截器加在这里**】共享 Dio 只挂**一条**拦截器链。
     *
     * 首版改动把 `interceptors.add(...)` 留在构造函数里 —— 生产里 40+ 次 `ApiClient()`
     * 会给同一个 Dio 挂 40+ 条一模一样的拦截器：每请求多跑 40 遍，且随页面创建**无上限增长**
     * （长会话必然越用越慢）。改为 [_attachInterceptor] 幂等挂载（见其注释）。
     */
    _attachInterceptor(this.dio);
  }

  /// 拦截器挂载标记：一个 Dio 实例**至多**一条（共享 Dio 与外部注入的 Dio 各一次）
  ///
  /// 用 `Expando` 而不是 `Set<Dio>`：前者不持有强引用（Dio 被回收后标记自动消失），
  /// 不会让测试里造出来的临时 Dio 被全局集合钉住（那会变成测试间的隐性泄漏）。
  static final Expando<bool> _interceptorAttached = Expando<bool>('ApiClientInterceptor');

  /// 【幂等】给一个 Dio 挂上"地址对齐 + 网络错误归一"拦截器（全类只有这一处挂载点）
  ///
  /// 两类实例的语义差异（保持与历史逐字节一致）：
  ///   - **共享 Dio / `debugDefaultDio`**：`options.extra` 里没有 `_kFollowRuntime` 标记
  ///     → 拦截器**照旧按构造时固化的 `AppConfig.apiBase` 对齐**（默认构造的实例，
  ///     地址必须跟随运行期下发 —— 2026-10-04 首帧专项）；
  ///   - **显式注入的 Dio**（单测假适配器 / 自定义通道）：`_requestOnce` 会打上
  ///     `_kFollowRuntime: false` → 拦截器**跳过地址改写**，绝不把 fixture 的目标地址改掉。
  ///     （历史实现用"每个实例各挂一条闭包、闭包捕获自己那个 `_followsRuntimeAddress`"来区分；
  ///     改成共享链之后，这个判断只能挪到请求上，否则一条链服务两种实例必然搞错一种。）
  static void _attachInterceptor(Dio dio) {
    if (_interceptorAttached[dio] == true) return;
    _interceptorAttached[dio] = true;
    dio.interceptors.add(
      InterceptorsWrapper(
        /**
         * 【2026-10-04 性能专项：让"地址下发"与"首帧"并行】
         *
         * 背景：地址是**网络下发**的（app_address.dart，最多 ~3.5s），而 Dio 的 `baseUrl`
         * 在**构造时**就固化进 `BaseOptions`。所以以前必须"先 await 地址、再 runApp"——
         * 于是**首帧被网络往返卡住**，用户看到的是启动图干等。
         *
         * 现在改成 `runApp` 先跑（首帧立刻出），地址在后台解析；解析完成后
         * `AppConfig.apiBase` 会变，但已经 new 出来的 ApiClient 还指着旧地址。
         * 这里在每个请求发出前把 baseUrl 与"当前生效地址"对齐，**等价于**把地址解析挪到了
         * 第一次真正发请求之前 —— 这正是铁律要求的顺序（地址解析必须先于首个 API 调用），
         * 而且不再阻塞渲染。
         *
         * 为什么是 request 拦截器而不是"解析完后手动 setBaseUrl 一遍"：ApiClient 有几十个
         * 实例（几乎每个页面 `ApiClient()` 一个），逐个通知既啰嗦又必然漏。放在唯一出口上，
         * 任何实例、任何时刻都自动拿到最新地址。
         */
        onRequest: (options, handler) {
          if (options.extra[kFollowRuntimeAddress] != false) {
            final current = AppConfig.apiBase;
            if (current.isNotEmpty && options.baseUrl != current) {
              options.baseUrl = current;
            }
          }
          handler.next(options);
        },
        onError: (e, handler) {
          /**
           * 【2026-10-16 网卡治理专项：**这里一个字都没改**（如实记录一次失败的尝试）】
           *
           * 曾计划把 `sendTimeout` 也加进本分支（"它和 connectionTimeout 同类"）。
           * **实测不可接受**：`media_uploader.dart: mediaUploadErrorMessage` 正是靠
           * "类型被判成 `unknown` + 内层 `ApiException(-1)` 是拦截器指纹"来把超时
           * **还原**成"上传超时：请切到与电脑同一 WiFi"这句**可执行**文案；
           * `sendTimeout` 一旦也被归一成 -1，上传超时就会被判成"连不上服务器"，
           * 把那句最有用的指引吃掉（`upload_progress_test` ③ 立刻转红）。
           * 首屏聚合的"挂住"问题**不需要改这里** —— 页级 `Timer` 已经把等待上限
           * 收在 1.5s（见 `services_page.dart: _aggTimeout`）。**别再往这里加类型。**
           */
          if (e.type == DioExceptionType.connectionError ||
              e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout) {
            handler.next(
              DioException(
                requestOptions: e.requestOptions,
                error: const ApiException(-1, '网络连接失败，请检查网络', ''),
              ),
            );
            return;
          }
          handler.next(e);
        },
      ),
    );
  }

  /// 请求级开关：本次请求要不要跟随运行期下发地址（`false` = 调用方自己指定了地址）
  ///
  /// 放 `RequestOptions.extra` 而不是实例字段：拦截器现在是**多条实例共享的一条链**，
  /// 只有"每次请求"这个粒度才能区分"这一发是默认构造发的、还是注入 dio 发的"。
  static const String kFollowRuntimeAddress = '__fish_follow_runtime_address';

  /// 是否跟随运行期下发地址（仅"不注入 dio"的默认构造为 true）
  ///
  /// 注入 `dio` 的实例（单测假适配器、自定义通道）保持调用方指定的地址不被改写。
  final bool _followsRuntimeAddress;

  /// 历史遗留的默认地址常量已废弃，统一走 AppConfig（3100 端口），保留仅为兼容旧引用
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3100/api/v1',
  );

  final Dio dio;

  /// 请求头透传请求 ID 便于服务端日志溯源（docs/03）
  ///
  /// 这里**同时**贴上防插页头（双保险）：`BaseOptions.headers` 已带一份，请求级再带一份，
  /// 原因是本函数是测试可见的唯一请求头出口，把语义集中在此便于断言；
  /// 键名大小写不敏感，重复不会产生两个头（dio 用 caseInsensitiveKeyMap 合并）。
  static Map<String, dynamic> buildHeaders({String? token}) {
    return {
      if (token != null) 'Authorization': 'Bearer $token',
      ngrokSkipWarningHeader: ngrokSkipWarningValue,
      'User-Agent': appUserAgent,
    };
  }

  /// 发起请求并把服务端错误转成 ApiException。
  /// 1) 网络类失败（code -1）对幂等安全方法（GET/HEAD）自动重试一次 —— 隧道网络不稳定时
  ///    大幅减少"网络连接失败"误报（docs/11 半死隧道场景）。
  /// 2) access token 过期（401 登录已过期）→ 自动刷新令牌并用新令牌重试一次
  ///    （2026-09-25 修复：此前只在启动时刷新，用满 2 小时后所有页面报"登录已过期"）。
  /// 进行中的同键请求（并发去重：多页同时打开只打一次服务器）
  static final Map<String, Future<Map<String, dynamic>>> _inflight = {};

  /// 缓存开关（测试可关闭，行为与旧版一致）
  static bool cacheEnabled = true;

  /// 缓存键：把"本实例实际要打的地址"一并纳入（不同实例/不同服务器互不串味）。
  ///
  /// 【2026-10-06 地址热切换专项修正】原来这里直接取 `dio.options.baseUrl`，并在注释里
  /// 断言"request 拦截器已把前者对齐到运行期下发地址" —— **那句话不成立**：
  ///   - 拦截器改的是每次请求的 `RequestOptions.baseUrl`（一份 request 级副本）；
  ///   - `dio.options.baseUrl` 是**构造那一刻的快照**，此后永不改变。
  /// 后果：地址热切换后，切换前构造的实例仍然按**旧地址**算缓存键。
  /// 这不会串数据（键里毕竟带了地址），但让"隧道换址后旧缓存不粘连"这句设计意图落空，
  /// 也留下了两套并存的缓存命名空间。
  ///
  /// 现在改为：**默认构造的实例（跟随运行期地址）就用当前生效地址**，
  /// 与拦截器实际写入 `RequestOptions.baseUrl` 的值严格同源；
  /// 注入 `dio` 的实例（单测假适配器 / 自定义通道）继续用调用方指定的地址，一字不改。
  String _cacheKeyOf(String path, Map<String, dynamic>? q) =>
      ApiCache.instance.keyOf(path, q, apiBase: _cacheScopeBase);

  /// 缓存/失效共用的地址维度 —— 与 request 拦截器写进请求的是同一个值
  String get _cacheScopeBase {
    if (_followsRuntimeAddress) {
      final String live = AppConfig.apiBase;
      if (live.isNotEmpty) return live;
    }
    return dio.options.baseUrl;
  }

  /// [cacheScopeBase] 的**公开只读视图**（2026-10-06 抢单大厅延迟专项）。
  ///
  /// 为什么需要公开：页面要实现 SWR 的"有缓存先渲染"就必须能算出**与 request() 完全相同**的
  /// 缓存键（差一个字符就等于没有缓存）。若让页面自己拼 `sessionId|base|path?query`，
  /// 就是把"键怎么算"复制出第二份实现 —— 与「同一规则只有一份实现」直接冲突，
  /// 且以后改键（如再加维度）页面必然悄悄失配。
  /// 因此：**键的算法与地址维度都从 ApiClient 取**，页面只负责传 path/query。
  ///
  /// 安全性：只读、无副作用，不暴露 token/地址之外的任何东西。
  String get cacheScopeBase => _cacheScopeBase;

  /// 算出"这个客户端这次要打的请求"的缓存键（与 [request] 内部用的是同一个函数）。
  ///
  /// 页面侧用于 SWR 预读（有缓存 → 立刻渲染旧数据 + 后台刷新）。
  /// **不要**用它去 `put` 缓存 —— 写入只走 [request]/[_send]，避免绕过失效映射。
  String cacheKeyOf(String path, [Map<String, dynamic>? query]) => _cacheKeyOf(path, query);

  /**
   * **缓存优先读（cache-first）**：上一次拿到的响应体 + 它的年龄（**哪怕已经过期**）。
   *
   * 页面用法（本任务「秒刷」的核心动作）：
   * ```dart
   * final peek = _api.peekCache('/divisions/grouped');
   * if (peek != null) setState(() => 先用 peek.body 渲染);   // 进页那一帧就有内容
   * final fresh = await _api.request('GET', '/divisions/grouped', forceRefresh: true); // 再回源
   * ```
   * 与 [request] 的边界（不要混着理解）：
   *   - [request] 自己就会做 SWR（新鲜直接用 / 过期先给旧的再后台刷新）—— **但它返回的是 Future**，
   *     页面总要 `await` 一次才拿得到值，那一次 `await` 在冷启动路径上就是"白屏一帧甚至一屏"；
   *   - 本方法是**同步**的，专门给"首帧就要有内容"用；它**不发起任何请求、不写缓存**。
   *   - 键的算法与地址维度**完全复用** [request] 那一套（[cacheKeyOf]）：差一个字符就等于没有缓存，
   *     因此这里绝不自己拼键。
   *
   * 返回 null = 本次运行内从没成功拉到过这条路径（真·首次进页）→ 按原有加载态处理。
   */
  ({Map<String, dynamic> body, Duration age})? peekCache(String path, [Map<String, dynamic>? query]) =>
      ApiCache.instance.peek(_cacheKeyOf(path, query));

  /// 预取（页面秒开的关键）：登录后/首页出现时并发预热常用接口，
  /// 之后打开对应页面直接命中缓存，0 等待。
  ///
  /// 【2026-10-04 性能专项补齐】原清单 5 条覆盖不全，且预取的是**公开接口** ——
  /// 在 `request()` 修掉"公开 GET 不缓存"之前，这些预取等于白跑（详见 request 内注释）。
  /// 现在补上主路径上真正会点的页面：
  /// - 商品列表：服务页 → 分部卡的**第一跳**，必须首屏 0 等待
  ///   （`skill`/`divisionId` 都不传时是"全部商品"，与 services 页点第一个分部的场景同键）
  /// - 官方馆 `/public/clubs`：服务页第二块内容
  /// - 游戏/分类：商品列表页的筛选器数据
  /// - 公告 / 关于：设置页与公告详情入口
  ///
  /// 刻意**不预取**的东西：`/user/orders`、`/user/conversations`、`/user/wallet` ——
  /// 这些是**账号私有且时效敏感**的数据，预取会消耗流量、且可能把旧值先亮给用户，
  /// 收益（本来就在 45s 列表档内）不值得。
  static Future<void> prefetch(ApiClient api, {required String token}) async {
    final targets = <List<Object?>>[
      ['/divisions', null],
      ['/divisions/grouped', null],
      ['/public/clubs', null],
      ['/public/order-form', null],
      // 【2026-10-05】原先预取 `/public/home` —— 该聚合现在只剩 announcements（其余 5 个字段
      // 的唯一消费者是已删的死代码 home_page.dart），而首页公告又只取前 10 条。
      // 改为直接预取真正的公告列表路由（服务页顶部「公告」→ AnnouncementsPage 的主路径），
      // 这样点进公告页是命中缓存 0 等待，且预取到的就是页面要用的那一份数据。
      ['/public/announcements', null],
      ['/public/games', null],
      ['/public/categories', null],
      ['/public/products', {'page': 1, 'pageSize': 20}],
      ['/public/players', {'page': 1, 'pageSize': 20}],
      ['/public/leaderboard', {'kind': 'week'}],
    ];
    await Future.wait(targets.map((t) => api
        .request('GET', t[0] as String, token: token, queryParameters: t[1] as Map<String, dynamic>?)
        .catchError((_) => <String, dynamic>{})));
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? token,
    bool forceRefresh = false,
  }) async {
    // 身份/会话类接口永不缓存：改完昵称/头像/背景后必须立刻拿到新数据
    // （2026-10-04 负责人反馈"改完不显示"就是因为 /auth/me 被缓存了）。
    // `/user/ai/messages` 同理且更要紧（2026-10-04 会话轮换）：用户离开祁小山即轮换 session，
    // 若这份"当前会话消息"被缓存 45 秒，再次进入会命中上一条会话的列表 → 闪现上一次的对话，
    // 正是「用户退出祁小山之后应自动初始化」要消灭的现象。
    //
    // 【2026-10-16 网卡治理专项】名单本体收口到 `ApiCache.neverCachePrefixes`
    // （"单一出处"的理由、以及实测到的 `/user/orders` **漏配**——它不在这份名单里、
    //  于是订单列表会被真的写进缓存——全部写在那个常量及其下方 doc 里）。
    // 本行只做转发：逐条与改动前的字面量列表等价。
    final noCache = ApiCache.instance.isNeverCached(path);

    /**
     * 【2026-10-04 性能专项：SWR 对公开接口从未生效】
     *
     * 原判断是 `token != null && !noCache` —— 但**公开接口恰恰都是不带 token 调的**
     * （`/divisions`、`/public/home`、`/public/players`、`/public/products`、
     * `/public/leaderboard`、`/public/games`、`/public/categories`、`/public/clubs` …），
     * 于是：
     *   - `ApiCache.ttlFor()` 里为它们精心配的 TTL（分部/首页 10 分钟等）**一条也用不上**；
     *   - `prefetch()` 预取的全是这些公开接口 → 预取等于白跑，目标页面照样要等网络；
     *   - `services_page.dart` 里 `forceRefresh: force`（"下拉刷新必须真绕过缓存"）
     *     自然也从未起作用，因为压根没有缓存可绕。
     * 实测证据：进排行榜页 / 找陪玩页 / 商品列表 **每次都发真实请求**（无命中计数）。
     *
     * 修正：公开只读 GET 同样参与 SWR。安全性不变 ——
     *   - 缓存键含账号维度与地址来源（见 `ApiCache.keyOf`），不会跨账号/跨服务器串数据；
     *   - 公开数据本身人人一样，缓存它不产生越权；
     *   - `noCache` 名单里的实时接口（余额/我的资料/AI 会话）继续每次回源。
     */
    final isPublicPath = path.startsWith('/public/') ||
        path == '/divisions' ||
        path.startsWith('/divisions/') ||
        path == '/health';
    final cacheable =
        cacheEnabled && method == 'GET' && (token != null || isPublicPath) && !noCache;
    final key = _cacheKeyOf(path, queryParameters);

    if (cacheable && !forceRefresh) {
      // 【2026-10-16 网卡治理专项】TTL 改由 `ttlForBody` 取：**按这次响应体里出现的段**分档
      // （聚合接口 `/public/home` 一包里含宣传图 8 分钟 + 陪玩名单 30 秒 → 整包按 30 秒算，
      //  见 ApiCache.ttlForBody 的"为什么取 min"）。单接口路径行为与旧 `ttlFor` 逐字相同。
      final peeked = ApiCache.instance.peek(key);
      final hit = ApiCache.instance.get(key, ApiCache.instance.ttlForBody(path, peeked?.body));
      if (hit != null && hit.fresh) {
        ApiCache.instance.hitCount += 1;
        return hit.body; // 秒开：不发网络请求
      }
      if (hit != null) {
        // 过期：先给旧数据，后台静默刷新（stale-while-revalidate）
        ApiCache.instance.revalidateCount += 1;
        unawaited(_send(method, path,
            data: data, queryParameters: queryParameters, token: token, key: key, cacheable: true));
        return hit.body;
      }
      ApiCache.instance.missCount += 1;
    }

    if (method == 'GET') {
      final running = _inflight[key];
      if (running != null) return running;
      final fut = _send(method, path,
          data: data, queryParameters: queryParameters, token: token, key: key, cacheable: cacheable);
      _inflight[key] = fut;
      try {
        return await fut;
      } finally {
        _inflight.remove(key);
      }
    }

    return _send(method, path,
        data: data, queryParameters: queryParameters, token: token, key: key, cacheable: false);
  }

  /// 实际发送：写缓存 + 写操作后失效相关缓存
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? token,
    required String key,
    required bool cacheable,
  }) async {
    final resp = await _requestWithRetry(method, path, data: data, queryParameters: queryParameters, token: token);
    if (cacheable) ApiCache.instance.put(key, resp);
    if (method != 'GET' && cacheEnabled) {
      /**
       * 写操作后的缓存失效映射。
       *
       * 【2026-10-04 性能专项补齐】原清单 4 条漏掉了若干"写完必须立刻看到"的关系，
       * 表现为"刚操作完，返回列表还是旧的"（用户可见的 bug，不只是性能）：
       * - 下单 `POST /user/orders` → 必须失效 `/user/orders`（原有）+ `/user/wallet`（余额已变，
       *   但 wallet 本身在 noCache 名单里，无需失效）；
       * - **认领/取消/确认完成订单** 走的是 `/user/orders/:id/xxx`，前缀仍是 `/user/orders`，原有覆盖；
       * - 送礼/打赏 `/user/tips` → 失效 `/user/tips`（流水列表）；
       * - 退款 `/user/refunds` → 同时影响订单与钱；
       * - 投诉/反馈 → 各自的列表；
       * - 工作端接单/派单 `/worker/orders`、`/worker/order-hall` → 失效工作端两个列表；
       * - 打手直聊建会话 `/worker/cs/...` → 失效工作端会话列表。
       *
       * 用 `path` 自身前缀 + 显式清单双保险：任何 `/xxx` 写操作先把 `/xxx` 开头的缓存清掉，
       * 这条规则能自动覆盖绝大多数 REST 形状（POST /user/orders/:id/confirm → 清 /user/orders*）。
       */
      final prefixes = <String>{
        path, // 自身前缀（REST 资源写操作 → 清同资源所有列表/详情缓存）
        '/user/orders',
        '/user/tips',
        '/user/refunds',
        '/user/complaints',
        '/user/friends',
        '/user/conversations',
        '/user/notifications',
        '/worker/orders',
        '/worker/order-hall',
        '/worker/cs/conversations',
        /**
         * 客服大厅（2026-10-08）：`POST /worker/cs/hall/:id/claim` 的**自身前缀**是
         * `/worker/cs/hall/<id>/claim`，它**匹配不到**缓存键 `/worker/cs/hall?page=1&pageSize=20`
         * （键里没有 `/<id>/claim` 这一段）—— 所以必须显式登记这条前缀，
         * 否则"刚接完、返回大厅，那条还挂在列表上"（用户会以为接入没生效）。
         */
        '/worker/cs/hall',
        // 充值（2026-10-06）：提交申请后「我的充值记录」立刻可见；发放/驳回后待审核列表立刻少一条
        '/user/recharge',
        '/recharge/requests',
      };
      for (final e in prefixes) {
        ApiCache.instance.invalidatePrefix(e, apiBase: _cacheScopeBase);
      }
    }
    return resp;
  }

  /// 带重试的原始请求（网络失败重试一次；token 过期自动刷新重试）
  ///
  /// 2026-10-06：外面套一层"网络失败/成功"的全局通知（供地址看门狗判断
  /// "当前地址是不是已经失效"）。**通知在重试逻辑之外**，所以一次逻辑请求
  /// 最多算一次失败 —— 与用户感知的"一次请求失败"严格对应。
  Future<Map<String, dynamic>> _requestWithRetry(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? token,
  }) async {
    try {
      final Map<String, dynamic> resp = await _requestWithRetryInner(
        method,
        path,
        data: data,
        queryParameters: queryParameters,
        token: token,
      );
      onNetworkSuccess?.call();
      return resp;
    } on ApiException catch (e) {
      // code -1 = 网络连接失败/超时（服务端没答话）→ 只这一类才算"地址可能失效"
      if (e.code == -1) onNetworkFailure?.call(e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _requestWithRetryInner(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? token,
  }) async {
    try {
      return await _requestOnce(method, path, data: data, queryParameters: queryParameters, token: token);
    } on ApiException catch (e) {
      if (e.code == 401 && e.message.contains('登录已过期') && token != null && onTokenExpired != null) {
        // 把"本次请求用的令牌"告诉刷新钩子（身份切换：primary / companion 各有自己的刷新通道）
        lastFailedToken = token;
        String? fresh;
        try {
          fresh = await onTokenExpired!();
        } finally {
          lastFailedToken = null;
        }
        if (fresh != null && fresh.isNotEmpty) {
          return _requestOnce(method, path, data: data, queryParameters: queryParameters, token: fresh);
        }
      }
      if (e.code == -1 && (method == 'GET' || method == 'HEAD')) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return _requestOnce(method, path, data: data, queryParameters: queryParameters, token: token);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _requestOnce(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    String? token,
  }) async {
    try {
      final response = await dio.request<Map<String, dynamic>>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          method: method,
          headers: buildHeaders(token: token),
          /**
           * 请求级地址开关（见 [_attachInterceptor]）：拦截器现在是"多条实例共享的一条链"，
           * 它无法从闭包里知道**这一发**是谁发的 —— 于是由这里明确告诉它：
           * 默认构造（跟随运行期下发地址）→ `true`；注入 dio（目标地址由调用方指定）→ `false`。
           */
          extra: <String, dynamic>{kFollowRuntimeAddress: _followsRuntimeAddress},
        ),
      );
      return response.data ?? const {};
    } on DioException catch (e) {
      // HTTP 层失败：记下状态码（见 [lastHttpStatus] 的说明）。业务码与它**可能不一致**
      // （服务端/代理/测试替身回 404 但信封里写 code:0 的情况实测存在）。
      lastHttpStatus = e.response?.statusCode ?? 0;
      final body = e.response?.data;
      if (body is Map<String, dynamic>) {
        final code = body['code'] as int? ?? -1;
        final message = body['message'] as String? ?? '请求失败';
        /**
         * 业务错误码（服务端 `AllExceptionsFilter` 透传，见 `errorCode` 字段）——
         * 客户端**只认机器码，不认文案**：封禁走 [onAccountBanned] 而不是 [onSessionKicked]，
         * 否则用户只会看到那句与"自己退出登录"一模一样的「登录已失效，请重新登录」。
         */
        final errorCode = body['errorCode'] as String? ?? '';
        // 被新设备顶掉：先全局踢出（清本地会话+弹提示），再抛给调用方
        if (code == 401 && message == '账号已在其他设备登录') {
          onSessionKicked?.call(message);
        }
        // 401 的令牌维度通知（纯新增；打手态的伴随会话失效走这条，不动老板态会话）
        if (code == 401) {
          onUnauthorized?.call(token, message);
        }
        // 封禁（账号被封）：清本地会话 + 弹**含原因与解封时间**的不可关闭提示（见 AuthStore）
        if (code == 401 && errorCode == accountBannedErrorCode) {
          onAccountBanned?.call(message);
        }
        throw ApiException(
          code,
          message,
          body['requestId'] as String? ?? '',
          errorCode: errorCode,
          // 字段级校验错误（服务端已中文化）→ 表单页据此显示输入框下方红字
          fields: ((body['fields'] as List?) ?? const [])
              .whereType<Map>()
              .map((f) => FieldError.fromJson(f))
              .where((f) => f.field.isNotEmpty && f.message.isNotEmpty)
              .toList(growable: false),
        );
      }
      if (e.error is ApiException) throw e.error!;
      throw ApiException(-1, '请求失败，请稍后重试', '');
    }
  }
}
