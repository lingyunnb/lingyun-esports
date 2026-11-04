import 'dart:io' show HttpDate;

import 'package:dio/dio.dart';

import '../api/api_client.dart';

/// **服务端时间探测**（2026-10-06 工作端到期自动阻断专项，纯新增）
///
/// 背景：工作端 App 到期（2026-10-13）后不再给「暂时继续使用」，判定用手机本地时间。
/// 本地时间可被用户改回去 → 需要一个**服务端口径**的时间做交叉校验。
///
/// 为什么复用 HTTP `Date` 响应头，而不是新加接口：
/// - 按 HTTP 规范，服务端**每个**响应都必须带 `Date`（Express/Node 自动写，GMT 绝对时间），
///   所以"取服务端现在"不需要任何后端改动、不需要新接口、不需要新依赖；
/// - 打的是公开的 `/health`（`server/src/modules/health/health.controller.ts`），
///   不消耗业务配额、不要求登录态。
///
/// 语义边界（三条，保证零侵入）：
///   1. **永不抛异常**：网络失败 / 超时 / 没有 `Date` 头 / 头解析不了 → 返回 `null`，
///      由调用方回退本地时间（调用方负责"优雅降级"，本函数只报"拿不到"）；
///   2. **不参与业务判定**：只提供"服务端现在"这一个事实，怎么用（取较晚者等）由调用方决定；
///   3. 超时与重试完全交给 dio 的 `Options`（这里显式给了默认 5 秒，避免页面久等）。
///
/// 已知边界：HTTP `Date` 头可被中间代理改写，离线时不可用 —— 因此它只适合做
/// **展示侧的交叉校验**；真正的封堵必须由服务端在到期后拒绝旧客户端（见工作端交付报告的风险一节）。
class NetworkTime {
  NetworkTime._();

  /// 探测路径（公开、轻量、无业务副作用）
  static const String probePath = '/health';

  /// 探测结果缓存时长：**默认 10 分钟**（`null` = 不缓存；测试可设 `Duration.zero` 关掉）
  ///
  /// 为什么要缓存：判定的是"有没有到某个**日期**"，10 分钟粒度完全够用；而缓存带来两个好处：
  /// 1. 同一进程内多处判定（引导条 / 阻断页 / 将来别的入口）只探一次，省一次请求；
  /// 2. 命中缓存时 [probe] **同步返回**（不是 pending 的 Future），不会在页面反复挂载/卸载时
  ///    留下悬挂的异步工作 —— 这是 `flutter_test` 里 "A Timer is still pending" 的常见来源。
  static Duration cacheTtl = const Duration(minutes: 10);

  static DateTime? _cachedAt;
  static DateTime? _cachedNow;

  /// 清掉缓存（测试用；生产不需要）
  static void resetCache() {
    _cachedAt = null;
    _cachedNow = null;
  }

  /// 探测服务端时间；拿不到返回 `null`（**不抛异常**）
  ///
  /// 刻意**自建一个 Dio 并在 finally 里 `close(force: true)`**，而不是借用 [api] 实例：
  /// 1. 探测只读一个响应头，不需要业务 Header/拦截器，更不该受调用方实例状态影响；
  /// 2. 借用页面实例时，请求若被打断会留下悬挂的定时器（重试/接收超时），
  ///    在 `flutter_test` 里表现为 "A Timer is still pending" —— 自建并强制关闭可避免；
  /// 3. 地址仍取 [ApiClient] 的 baseUrl（含运行期下发地址与拦截器对齐逻辑），**不写死域名**。
  ///
  /// [api] 只用来提供"当前生效地址"（缺省自建 [ApiClient]，与页面其它请求同一个地址来源）。
  static Future<DateTime?> probe({
    ApiClient? api,
    String path = probePath,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // 命中缓存 → 直接返回（`async` 函数里的同步 return 仍然是一次微任务，但不再发起网络请求，
    // 也就不会留下连接/超时/重试定时器）
    final DateTime? hit = _cached(timeout);
    if (hit != null) return hit;

    final Dio dio = Dio(
      BaseOptions(
        baseUrl: (api ?? ApiClient()).dio.options.baseUrl,
        validateStatus: (int? s) => s != null && s < 500, // 4xx 也算"服务端答话了"
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
      ),
    );
    try {
      final Response<dynamic> resp = await dio.get<dynamic>(
        path,
        // 只关心响应头；responseType=plain 让响应体不参与解析
        options: Options(responseType: ResponseType.plain),
      );
      final DateTime? parsed = parseDateHeader(resp.headers.value('date'));
      _remember(parsed, timeout);
      return parsed;
    } catch (_) {
      return null;
    } finally {
      // 强制关闭：无论成功失败都不留下悬挂连接/定时器（见上面第 2 条）
      dio.close(force: true);
    }
  }

  /// 读缓存（未启用 / 过期 / 没探到过 → null）
  static DateTime? _cached(Duration timeout) {
    if (cacheTtl <= Duration.zero || timeout <= Duration.zero) return null;
    final DateTime? at = _cachedAt;
    if (at == null || _cachedNow == null) return null;
    if (DateTime.now().difference(at) > cacheTtl) return null;
    return _cachedNow;
  }

  static void _remember(DateTime? value, Duration timeout) {
    if (cacheTtl <= Duration.zero || timeout <= Duration.zero || value == null) return;
    _cachedAt = DateTime.now();
    _cachedNow = value;
  }

  /// HTTP `Date` 头 → **设备本地时区**的 [DateTime]（解析不了返回 null）
  ///
  /// 关键：`HttpDate.parse` 按规范返回 **UTC** 时刻，这里显式 `.toLocal()` —— 否则与
  /// `DateTime.now()`（本地）比较时在 UTC+8 会差 8 小时，跨日时会多放行/多阻断一天。
  /// 单独抽成纯函数是为了**不依赖网络**就能测"取不到就回退"这一条。
  static DateTime? parseDateHeader(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.isEmpty) return null;
    try {
      // `HttpDate.parse` 按 RFC 1123 解析（GMT）→ 转设备本地时区，与 DateTime.now() 同口径
      return HttpDate.parse(value).toLocal();
    } catch (_) {
      return null;
    }
  }
}
