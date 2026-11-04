/// **TTL 分档表 + 永不变缓存红线**（2026-10-16 网卡治理专项 · core 侧）
///
/// ## 背景（病灶口径，不是猜的）
/// 服务端处理 2–21ms、负载 0.08、无慢查询；香港节点 RTT ≈ 245ms —— 瓶颈**全在路上**，
/// 于是"回访秒开"只能靠两件事：**减少请求次数**（聚合，见 boss-app 侧测试）与
/// **加长缓存窗口**（本文件）。
///
/// ## 本文件钉死四件事（只增不减，防回归）
/// 1. **每个档位的具体数值**（banners 60 秒 / divisions 6 分钟 / players 30 秒 / …）——
///    数值不是随手挑的，每档理由写在 `api_cache.dart` 的表注释里，这里逐条锁值；
/// 2. **按数据类型分档**（`ttlForBody`）：聚合接口一包里含多段时取**变化最快的一段**，
///    并给出"为什么取 min"的可执行证据（宣传图 60s 不会因陪玩名单 30s 而被迫更短，
///    也不会反过来把整包拉长）；
/// 3. **红线**：余额 / 订单 / 消息 / 会话类**一律不缓存**（`isNeverCached` + `ttlFor == 0`），
///    且这层判定**不依赖** AkApiClient 的 `noCache` 名单（第二道锁，防误登记）；
/// 4. **既有档位没被一刀切改坏**：列表 45s / 会话 15s / 字典 10 分钟 / 运营 60s 原样。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录每次请求路径的假通道（**真 ApiClient + 真 ApiCache**，零延迟：本文件只数请求数）
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.body);

  /// 一律回这一个信封（本文件不测解析，只测"打了几发"）
  final Map<String, dynamic> body;

  final List<String> requested = <String>[];

  int countOf(String path) => requested.where((p) => p.startsWith(path)).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.path);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _envelope(Object? data) =>
    <String, dynamic>{'code': 0, 'message': 'ok', 'data': data};

/// 首页聚合的真实形状（与任务书契约一致：5 段 + updatedAt）
Map<String, dynamic> _aggregateData() => <String, dynamic>{
      'banners': <dynamic>[
        <String, dynamic>{'id': '1', 'imageMediaId': 'm1', 'sortOrder': 1},
      ],
      'divisions': <dynamic>[
        <String, dynamic>{
          'id': '2',
          'code': 'delta_mobile',
          'name': '三角洲行动 · 手游',
          'shortName': '三角洲手游',
          'platform': 'mobile',
          'platformLabel': '手游',
          'onlineCount': 8,
        },
      ],
      'hotProducts': <dynamic>[
        <String, dynamic>{'id': 'p1', 'name': '上分陪练'},
      ],
      'players': <dynamic>[
        <String, dynamic>{'workerId': 'w1', 'nickname': '陪玩甲'},
      ],
      'leaderboard': <dynamic>[
        <String, dynamic>{'rank': 1, 'nickname': '陪玩甲'},
      ],
      'updatedAt': '2026-10-16T10:00:00.000Z',
    };

ApiClient _api(_CountingAdapter adapter, String host) {
  final dio = Dio(BaseOptions(baseUrl: 'http://$host/api/v1'))..httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  // -------------------------------------------------------------------
  // ① 分档表：逐档锁值 + 锁理由（理由写在 api_cache.dart，这里只锁"值"}
  // -------------------------------------------------------------------
  group('① TTL 分档表（每档值 + 该档存在的原因）', () {
    final cache = ApiCache.instance;

    test('宣传图档：banners **60 秒**（运营换图 1 分钟内可见）', () {
      /**
       * 【2026-10-16 二轮修正：8 分钟 → 60 秒】原断言是 `Duration(minutes: 8)` + "落在 5–10 分钟区间"。
       *
       * 为什么值变了：负责人 2026-10-16 反馈「加秒刷新 —— 换完宣传图 App 最长 8 分钟还是旧图」。
       * 上一轮把宣传图当"改动以周计的运营素材"拉到 8 分钟，对"几乎不变的图"合理，
       * **对刚换的那一张就是纯粹的延迟**。新值 60s 与三处对齐：
       *   ① 服务端 `/public/banners` 下发的 `Cache-Control: private, max-age=60`；
       *   ② 客户端"运营档" [ApiCache.ttlOps]（同一把尺子：管理端改完 ≤1 分钟可见）；
       *   ③ 宣传图是**静态资源**（个位数行数、单条 SQL），60s 的重复请求成本可忽略。
       *
       * **断言强度没有降低**（不是放宽）：从"等于 8 分钟 + 落在区间内"改成
       * "**等于 60 秒** + 严格短于字典档 + **严格长于聚合体里最快的段（players 30s）**" ——
       * 最后一条是**新增的不变量**：宣传图档若短于 players，它就会成为聚合体的 min-TTL，
       * 把整包聚合数据压到比"陪玩名单"还紧，那与"按段分档"的初衷相反。
       */
      expect(ApiCache.ttlBanner, const Duration(seconds: 60));
      expect(cache.ttlFor('/public/banners'), ApiCache.ttlBanner);
      expect(ApiCache.ttlBanner, ApiCache.ttlOps, reason: '与"运营档 60s"同值：换图 1 分钟内必须可见');
      expect(ApiCache.ttlBanner < ApiCache.ttlDict, isTrue,
          reason: '宣传图仍在运营可改范畴，不许长到字典档（10 分钟）');
      expect(ApiCache.ttlBanner > ApiCache.ttlLive, isTrue,
          reason: '必须**长于**聚合体里最快的一段（players 30s），否则它会取代 players 成为整包 min-TTL');
      expect(ApiCache.ttlBanner < ApiCache.ttlDivision, isTrue,
          reason: '换图是日常动作，应比"接新游戏才变"的分部档（6 分钟）更短');
    });

    test('分部档：divisions（含 grouped）6 分钟（5–10 分钟区间）', () {
      expect(ApiCache.ttlDivision, const Duration(minutes: 6));
      expect(cache.ttlFor('/divisions'), ApiCache.ttlDivision);
      expect(cache.ttlFor('/divisions/grouped'), ApiCache.ttlDivision);
      expect(ApiCache.ttlDivision >= const Duration(minutes: 5), isTrue);
      expect(ApiCache.ttlDivision <= const Duration(minutes: 10), isTrue);
      // 与旧值的关系（这是本次的核心改动之一）：从 60s 拉到 6 分钟
      expect(ApiCache.ttlDivision > ApiCache.ttlOps, isTrue,
          reason: '分部是"接新游戏才变"的事件级配置，应长于"运营档"60s');
    });

    test('陪玩名单档：players 30 秒（30–60 秒区间，取下限）', () {
      expect(ApiCache.ttlLive, const Duration(seconds: 30));
      expect(cache.ttlFor('/public/players'), ApiCache.ttlLive);
      expect(ApiCache.ttlLive >= const Duration(seconds: 30), isTrue);
      expect(ApiCache.ttlLive <= const Duration(seconds: 60), isTrue);
      // 为什么取区间下限：它随「接单权限」变，是聚合体里变化最快的一段（决定整包 TTL）
      expect(ApiCache.ttlLive < ApiCache.ttlList, isTrue,
          reason: '比通用列表档 45s 更短：权限一改名单就该尽快追平');
    });

    test('商品档：products 30–60 秒（本表取 45s 列表档）', () {
      expect(cache.ttlFor('/public/products'), ApiCache.ttlList);
      expect(ApiCache.ttlList >= const Duration(seconds: 30), isTrue);
      expect(ApiCache.ttlList <= const Duration(seconds: 60), isTrue);
    });

    test('排行榜档：leaderboard 1–2 分钟（本表取 45s，比区间更保守）', () {
      expect(cache.ttlFor('/public/leaderboard'), ApiCache.ttlList);
      // 45s < 区间上限 2 分钟：**比要求的 1–2 分钟更短**（更保守、绝不过期更久），
      // 因此无需为它拉长 TTL 去"对齐区间"——排行榜页自带 forceRefresh 回源。
      expect(ApiCache.ttlList <= const Duration(minutes: 2), isTrue);
    });

    test('既有四档一个都没被顺手改坏（列表/会话/字典/运营）', () {
      expect(ApiCache.ttlList, const Duration(seconds: 45));
      expect(ApiCache.ttlChat, const Duration(seconds: 15));
      expect(ApiCache.ttlDict, const Duration(minutes: 10));
      expect(ApiCache.ttlOps, const Duration(seconds: 60));
      expect(cache.ttlFor('/public/announcements'), ApiCache.ttlDict);
      expect(cache.ttlFor('/user/conversations'), ApiCache.ttlChat);
      expect(cache.ttlFor('/worker/cs/hall'), ApiCache.ttlChat);
      expect(cache.ttlFor('/public/clubs'), ApiCache.ttlOps);
      expect(cache.ttlFor('/worker/order-hall'), const Duration(seconds: 10));
      expect(cache.ttlFor('/some/unregistered/path'), ApiCache.ttlList);
    });

    test('旧形状的 /public/home 仍落 ttlOps（按路径兜底档）', () {
      // 新聚合体走 ttlForBody（见下组）；**不带段的旧形状**（只剩 announcements）
      // 必须仍是 60s —— 这是 ops_ttl_test 既有断言的语义，不能被本次改动掀翻。
      expect(cache.ttlFor('/public/home'), ApiCache.ttlOps);
      expect(cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'announcements': <dynamic>[]})),
          ApiCache.ttlOps);
    });
  });

  // -------------------------------------------------------------------
  // ② 按数据类型分档：聚合体取"变化最快的一段"
  // -------------------------------------------------------------------
  group('② ttlForBody：聚合体按"最快变化的那一段"整包过期', () {
    final cache = ApiCache.instance;

    test('完整聚合体 → 30s（由 players/products 决定，而不是 6 分钟的分部/60s 的宣传图）', () {
      final ttl = cache.ttlForBody('/public/home', _envelope(_aggregateData()));
      expect(ttl, ApiCache.ttlLive, reason: '整包必须按最易过期的一段算，否则会拿 30s 前的名单糊弄用户');
      expect(ttl, const Duration(seconds: 30));
      expect(ttl < ApiCache.ttlBanner, isTrue, reason: '绝不能取 max（那会让陪玩名单 60s 不更新）');
    });

    test('只有宣传图的包 → 60 秒（宣传图不会因为别的段而被迫短命）', () {
      final ttl = cache.ttlForBody('/public/home', _envelope(<String, dynamic>{
        'banners': <dynamic>[],
      }));
      expect(ttl, ApiCache.ttlBanner);
      expect(ttl, const Duration(seconds: 60));
    });

    test('只有分部的包 → 6 分钟', () {
      final ttl = cache.ttlForBody('/public/home', _envelope(<String, dynamic>{
        'divisions': <dynamic>[],
      }));
      expect(ttl, ApiCache.ttlDivision);
    });

    test('两段混合取更短的那一段（顺序无关）', () {
      // 【2026-10-16 二轮】banners 由 8 分钟改成 60 秒后，这一对里**更短的是 banners**
      // （60s < 分部档 6 分钟）—— 期望值随之从 ttlDivision 改为 ttlBanner。
      // 断言语义**没有变**（仍是"取更短的那一段 + 与 map 顺序无关"），只是被比较的两档换了短长关系。
      final a = cache.ttlForBody('/public/home', _envelope(<String, dynamic>{
        'banners': <dynamic>[],
        'divisions': <dynamic>[],
      }));
      final b = cache.ttlForBody('/public/home', _envelope(<String, dynamic>{
        'divisions': <dynamic>[],
        'banners': <dynamic>[],
      }));
      expect(a, ApiCache.ttlBanner);
      expect(b, ApiCache.ttlBanner, reason: '取 min 与 map 顺序无关');
      expect(a, b);
      expect(a, lessThan(ApiCache.ttlDivision), reason: '这一对里 banners(60s) 更短，故整包按它算');
    });

    test('无段的包 / null 体 → 回落按路径取档（行为与旧 ttlFor 一致）', () {
      expect(cache.ttlForBody('/public/banners', null), ApiCache.ttlBanner);
      expect(cache.ttlForBody('/public/banners', _envelope(<dynamic>[])), ApiCache.ttlBanner);
      expect(cache.ttlForBody('/public/products', _envelope(<String, dynamic>{'list': <dynamic>[]})),
          ApiCache.ttlList);
      expect(cache.ttlForBody('/unknown/path', null), ApiCache.ttlList);
    });

    test('单接口路径的档位与 ttlFor 完全一致（不是两套表）', () {
      for (final p in <String>[
        '/public/banners',
        '/public/players',
        '/public/products',
        '/public/leaderboard',
        '/public/clubs',
        '/divisions/grouped',
      ]) {
        expect(cache.ttlForBody(p, _envelope(<String, dynamic>{'list': <dynamic>[]})), cache.ttlFor(p),
            reason: '$p 的"按路径"结果不许与 ttlFor 有任何偏差（同一份 _byPrefix）');
      }
    });
  });

  // -------------------------------------------------------------------
  // ③ 红线：余额 / 订单 / 消息 类永不缓存
  // -------------------------------------------------------------------
  group('③ 红线：账号私有且"一变就要看得见"的类别永不缓存', () {
    final cache = ApiCache.instance;

    test('红线名单覆盖：余额 / 打手余额 / 身份 / 邮箱 / 账号 / 充值审核 / AI 会话', () {
      for (final p in <String>[
        '/user/wallet',
        '/user/wallet/transactions',
        '/worker/my-wallet',
        '/user/identity',
        '/user/email',
        '/user/ai/messages',
        '/auth/me',
        '/recharge/requests',
        '/recharge/requests/9/pay-proof',
      ]) {
        expect(cache.isNeverCached(p), isTrue, reason: '$p 必须被红线拦住');
        expect(cache.ttlFor(p), Duration.zero, reason: '$p 的新鲜窗口必须是 0（= 永远回源）');
        expect(cache.ttlForBody(p, _envelope(<String, dynamic>{'banners': <dynamic>[]})), Duration.zero,
            reason: '$p 不许被"按类型分档"绕过：响应体里出现 banners 也不行');
      }
    });

    test('公开读物不在红线里（缓存公开数据不产生越权，也不是本次改动对象）', () {
      for (final p in <String>['/public/banners', '/public/clubs', '/divisions/grouped', '/public/players']) {
        expect(cache.isNeverCached(p), isFalse);
        expect(cache.ttlFor(p) > Duration.zero, isTrue);
      }
    });

    test('红线名单 = `ApiClient.request` 的 noCache 那份（单一出处，防两侧漂移）', () {
      // 这一条钉的是"结构"：`request()` 现在转发缓存层这份名单（`isNeverCached`），
      // 所以"红线名单"与"请求侧不缓存名单"不可能再各说各话。
      expect(ApiCache.instance.neverCacheForRequest, ApiCache.neverCachePrefixes);
      for (final p in ApiCache.neverCachePrefixes) {
        expect(p.startsWith('/'), isTrue, reason: '名单项必须是路径前缀');
        expect(p.endsWith('/'), isFalse, reason: '不许带尾斜杠（否则 `/user/walletX` 会漏进来）');
      }
      expect(ApiCache.neverCachePrefixes.contains('/user/wallet'), isTrue);
      expect(ApiCache.neverCachePrefixes.contains('/worker/my-wallet'), isTrue);
      expect(ApiCache.neverCachePrefixes.contains('/auth/me'), isTrue);
      expect(ApiCache.neverCachePrefixes.contains('/user/ai/messages'), isTrue);
    });

    /**
     * **如实上报（不粉饰）：`/user/orders` 目前**会被**写进缓存。**
     *
     * 实测：`GET /user/orders`（带 token）连发 3 次 → 只打 1 次网络，
     * 第 2/3 次走 SWR 的 `revalidate` 分支（`stats()` 得 `cached=1`）。
     * 原因：`/user/orders` **不在** `ApiCache.neverCachePrefixes` 里（因此不在
     * `ApiClient.noCache` 里）—— 而任务书红线要求"用户自己的订单类一律不缓存"。
     *
     * **本轮刻意不修**：把 `/user/orders` 收进名单会让 boss-app 的
     * `perf_first_paint_test ⑩`（"缓存已在时首个可见帧就该是内容"）失败 ——
     * 那条断言在现状下**依赖"订单被缓存"**；而本次允许改的文件不含任何测试文件，
     * 按"不许放宽既有断言"的铁律不能动它。
     *
     * 本用例把现状**钉住**（而不是假装它已经合规）：谁将来修好它，这条会红并提示
     * "把断言改成 3 次真回源、并同步核对 perf_first_paint_test ⑩"。
     */
    /**
     * 【2026-10-16 已修】这条用例原本是"钉住已知差距"（断言 `/user/orders` **不在**红线名单、
     * 3 次请求只打 1 次网络），并在注释里写明了修复指引：
     * "谁将来修好它，这条会红并提示「把断言改成 3 次真回源、并同步核对 perf_first_paint_test ⑩」"。
     *
     * 本轮主控按该指引完成修复：
     *   ① `/user/orders` 收进 `neverCachePrefixes`（红线：余额/订单/消息类一律不缓存）；
     *   ② `perf_first_paint_test ⑩` 的前提同步修正 —— 公开数据（找陪玩/商品）仍断言"首帧就是内容"，
     *      而订单改为断言"首帧**不该**是内容 + 必须在红线名单"（原来那条把错误行为当性能目标）。
     * 于是这条从"钉住差距"翻转为**正向红线守卫**：3 次请求 = 3 次真回源。
     */
    test('红线：/user/orders 永不缓存（3 次请求 = 3 次真回源）', () async {
      final adapter = _CountingAdapter(_envelope(<String, dynamic>{'list': <dynamic>[], 'total': 0}));
      final api = _api(adapter, 'ttl-orders-fixed.test');
      for (var i = 0; i < 3; i++) {
        await api.request('GET', '/user/orders', token: 't');
      }
      expect(ApiCache.instance.isNeverCached('/user/orders'), isTrue,
          reason: '红线：订单是私有数据，必须在 `neverCachePrefixes` 里');
      expect(adapter.countOf('/user/orders'), 3,
          reason: '红线：3 次请求必须打 3 次网络 —— 订单**不许**命中任何缓存');
    });
  });

  // -------------------------------------------------------------------
  // ④ 端到端：banners 5 分钟内不再发请求（SWR 命中，真 ApiClient + 真 ApiCache）
  // -------------------------------------------------------------------
  group('④ 端到端：档位在真请求路径上生效', () {
    test('banners：5 分钟内第二次请求不再上网（5 分钟 > 8 分钟档内的任意时刻）', () async {
      final adapter = _CountingAdapter(_envelope(<dynamic>[]));
      final api = _api(adapter, 'ttl-banner.test');

      await api.request('GET', '/public/banners');
      expect(adapter.countOf('/public/banners'), 1);

      // 立刻再要一次：8 分钟档内 → 命中缓存，**不发请求**
      await api.request('GET', '/public/banners');
      expect(adapter.countOf('/public/banners'), 1, reason: 'banners 在 8 分钟档内必须命中缓存（这正是"5 分钟不再发请求"）');
      expect(ApiCache.instance.hitCount, greaterThan(0));

      // 对照：`forceRefresh`（下拉刷新/回前台/切回 tab 的路径）必须**真回源**
      await api.request('GET', '/public/banners', forceRefresh: true);
      expect(adapter.countOf('/public/banners'), 2, reason: '三条强制回源路径不许被缓存拦住');
    });

    test('divisions/grouped：同一次运行内重复进入不再回源', () async {
      final adapter = _CountingAdapter(
        _envelope(<dynamic>[
          <String, dynamic>{'gameId': '36', 'gameName': '三角洲行动', 'platformCount': 1, 'divisions': <dynamic>[]},
        ]),
      );
      final api = _api(adapter, 'ttl-division.test');
      await api.request('GET', '/divisions/grouped');
      await api.request('GET', '/divisions/grouped');
      expect(adapter.countOf('/divisions/grouped'), 1);
    });

    test('players：30s 档内命中缓存；但 forceRefresh 回源（权限改动的主路径不受缓存阻碍）', () async {
      final adapter = _CountingAdapter(_envelope(<String, dynamic>{'list': <dynamic>[], 'total': 0}));
      final api = _api(adapter, 'ttl-players.test');
      await api.request('GET', '/public/players', queryParameters: <String, dynamic>{'page': 1, 'pageSize': 20});
      await api.request('GET', '/public/players', queryParameters: <String, dynamic>{'page': 1, 'pageSize': 20});
      expect(adapter.countOf('/public/players'), 1);
      await api.request('GET', '/public/players',
          queryParameters: <String, dynamic>{'page': 1, 'pageSize': 20}, forceRefresh: true);
      expect(adapter.countOf('/public/players'), 2);
    });

    test('聚合接口：第二次请求命中（30s 档 = 由 players 段决定）', () async {
      final adapter = _CountingAdapter(_envelope(_aggregateData()));
      final api = _api(adapter, 'ttl-agg.test');
      await api.request('GET', '/public/home');
      await api.request('GET', '/public/home');
      expect(adapter.countOf('/public/home'), 1, reason: '聚合体 30s 档内命中缓存 → 回访首屏 0 网络');
    });

    test('余额类：每一次都必须真回源，且**缓存条目零增长**', () async {
      final adapter = _CountingAdapter(_envelope(<String, dynamic>{'balance': '100.00'}));
      final api = _api(adapter, 'ttl-wallet.test');
      for (var i = 0; i < 3; i++) {
        await api.request('GET', '/user/wallet', token: 't');
      }
      expect(adapter.countOf('/user/wallet'), 3, reason: '余额 3 次请求 = 3 次回源（一次都不许吃缓存）');
      expect(ApiCache.instance.stats(), contains('cached=0'),
          reason: '红线类的响应**连写都不许写进缓存**（不只是"不吃"）');
    });

    test('反面对照：公开读物请求后**真的进了缓存**（证明上一条不是假阳性）', () async {
      final adapter = _CountingAdapter(_envelope(<dynamic>[]));
      final api = _api(adapter, 'ttl-control.test');
      await api.request('GET', '/public/banners');
      expect(ApiCache.instance.stats(), contains('cached=1'),
          reason: '对照物：同一次运行里公开读物确实写进了缓存 → "红线类 cached=0" 是真差异，不是口径失灵');
    });
  });
}
