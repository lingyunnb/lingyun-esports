/// **公开 GET 的 SWR 缓存生效性**（2026-10-04 性能专项）
///
/// 背景：`ApiCache` 从一开始就为 `/divisions`、`/public/home`、`/public/players` 等
/// 公开接口配了 TTL（分部/首页 10 分钟），但 `ApiClient.request` 的缓存条件是
/// `token != null && !noCache` —— 而公开接口**恰恰都是不带 token 调的**，
/// 于是这些 TTL 一条也没生效，导致：
///   * 进排行榜 / 找陪玩 / 商品列表 **每次都发真实网络请求**（弱网下就是每次都要等）；
///   * `ApiClient.prefetch()` 预取的全是公开接口 → 预取等于白跑；
///   * 页面里写好的 `forceRefresh: force`（"下拉刷新必须真绕过缓存"）**无缓存可绕**。
///
/// 本文件把修复后的行为钉死，防止回归：公开 GET 必须命中内存缓存、不再发请求；
/// 同时钉死"地址 / 会话隔离"，避免为了缓存而引入串味。
library;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_http.dart';

/// 构造一个指向固定 base 的 ApiClient（注入 dio → 不会被运行期下发地址改写）
ApiClient clientFor(String base, HeaderRecordingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

void main() {
  setUp(() {
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  tearDown(() {
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  group('公开 GET 的 SWR 缓存', () {
    test('第二次打开同一公开页 → 命中缓存，不再发网络请求', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"n":1}}');
      final api = clientFor('http://perf.test/api/v1', adapter);

      // 第一次：真实请求
      final first = await api.request('GET', '/divisions');
      expect(first['data']?['n'], 1);
      expect(adapter.paths.length, 1, reason: '首次必须真的请求一次');

      // 第二次（模拟"切走再切回服务页"）：应命中缓存 → 适配器调用次数不变
      final second = await api.request('GET', '/divisions');
      expect(second['data']?['n'], 1);
      expect(adapter.paths.length, 1,
          reason: 'TTL 内的第二次必须命中内存缓存（这正是"切页秒开"的来源）');
      expect(ApiCache.instance.hitCount, greaterThan(0));
    });

    test('多个公开路径都参与缓存（含带查询参数的列表）', () async {
      for (final String path in const <String>[
        '/public/home',
        '/public/players',
        '/public/leaderboard',
        '/public/products',
        '/public/games',
        '/divisions/grouped',
        '/public/clubs',
      ]) {
        final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"p":"$path"}}');
        final api = clientFor('http://perf-$path.test/api/v1', adapter);
        await api.request('GET', path);
        await api.request('GET', path);
        expect(adapter.paths.length, 1, reason: '$path 必须命中缓存（只请求一次）');
      }
    });

    test('带查询参数：参数不同 = 不同缓存条目', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"n":1}}');
      final api = clientFor('http://perf-q.test/api/v1', adapter);

      await api.request('GET', '/public/products', queryParameters: {'divisionId': '2'});
      await api.request('GET', '/public/products', queryParameters: {'divisionId': '2'});
      expect(adapter.paths.length, 1, reason: '同参数命中缓存');

      await api.request('GET', '/public/products', queryParameters: {'divisionId': '3'});
      expect(adapter.paths.length, 2, reason: '不同分部必须是不同缓存条目（不能串）');
    });

    test('forceRefresh=true（下拉刷新）必须真绕过缓存', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"n":1}}');
      final api = clientFor('http://perf-f.test/api/v1', adapter);

      await api.request('GET', '/divisions');
      await api.request('GET', '/divisions', forceRefresh: true);
      expect(adapter.paths.length, 2,
          reason: '下拉刷新带 forceRefresh → 必须再发一次（此前因为压根没缓存，这个参数是空转）');
    });

    test('实时接口永不缓存：/user/wallet 每次回源', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"balance":10}}');
      final api = clientFor('http://perf-w.test/api/v1', adapter);

      await api.request('GET', '/user/wallet', token: 'T');
      await api.request('GET', '/user/wallet', token: 'T');
      expect(adapter.paths.length, 2, reason: '余额属于时效敏感数据，必须在 noCache 名单里');
    });

    test('/public/players 不吃字典档（权限变更最多只等 30s 行话档）', () async {
      final cache = ApiCache.instance;
      final ttl = cache.ttlFor('/public/players');

      /**
       * **2026-10-16 网卡治理专项：45s → 30s（设计改动，断言同步收严）**
       *
       * 为什么改：它是首页聚合体（`/public/home`）里**变化最快的那一段** ——
       * 随管理端的 `worker_division_permission` 变动而变；而聚合体的整包 TTL 由
       * "最快的一段"决定（见 `ApiCache.ttlForBody`）。把它压到 30s（任务书区间
       * 30–60 秒的下限）等于让整包聚合数据都更快追平服务端。
       * 结论：这不是放宽，而是**收紧 15 秒**（45 → 30）。
       */
      expect(ttl, ApiCache.ttlLive, reason: '名单随「分部接单权限」变动，落"行话档"30s（比列表档更短）');
      expect(ttl, isNot(ApiCache.ttlDict),
          reason: '回归防护：管理端刚撤销权限，老板最长 10 分钟仍能看到旧名单 —— 这正是本次要修掉的残留风险');
      expect(ttl < ApiCache.ttlDict, isTrue, reason: '/public/players 必须严格短于字典档');
      expect(ttl < ApiCache.ttlList, isTrue, reason: '比通用列表档 45s 更短（变化更快）');
      expect(ApiCache.ttlLive.inSeconds, 30);
      expect(ApiCache.ttlDict.inMinutes, 10, reason: '字典档就是 10 分钟（对照物）');

      // 行为层面：TTL 就是"新鲜度阈值"，短 TTL 意味着同一条缓存更早被判过期 → 更早回源。
      // 这里用"手动给一个更短阈值"复现同一判定路径（ApiCache.get 的 fresh 语义），
      // 确认阈值收紧后旧名单不会被当作新鲜数据直接返回。
      final key = cache.keyOf('/public/players', {'divisionId': '2', 'page': 1, 'pageSize': 50},
          apiBase: 'http://perf-players.test/api/v1');
      cache.put(key, {
        'code': 0,
        'data': {
          'list': [
            {'nickname': '刚被撤销权限的人'}
          ]
        }
      });
      expect(cache.get(key, ttl)?.fresh, isTrue, reason: '刚写入的条目当然新鲜（缓存能力没被砍掉，只是档位变短）');
      expect(cache.get(key, Duration.zero)?.fresh, isFalse,
          reason: '阈值一到就该判过期（SWR 会先给旧值 + 后台回源），不可能一直"新鲜"到 10 分钟');

      // 只动 /public/players 一条：其余档位不得被顺手改坏。
      // 【2026-10-08 运营同步专项】`/public/games`、`/public/categories`、`/public/home`、
      // `/divisions/grouped` 已按"管理端会改、用户能感知"的判据迁到 **ttlOps（60s）**
      // （原为 ttlDict 10 分钟，正是"下架官方馆客户端还显示"的成因之一）——
      // 逐个端点的迁移断言见 ops_ttl_test.dart；这里保留"字典档没被一刀切砍掉"的对照物。
      //
      // 【2026-10-16 网卡治理专项】`/divisions/grouped` 由 ttlOps 再迁到 **ttlDivision（6 分钟）**：
      // 分部是"接新游戏才变"的事件级低频配置，却挂在首屏第一个区块的关键路径上
      // （香港 RTT ≈ 245ms，60s 一过就要多打一次往返）。运营改动仍由三条 force 回源路径兜住：
      // 下拉刷新 / 回前台 / 切回本 tab（见 `services_page.dart`）—— 详见 ops_ttl_test.dart 的
      // 「分部档」用例（那里对 5–10 分钟区间与"不是字典档"都有断言）。
      expect(cache.ttlFor('/public/games'), ApiCache.ttlOps);
      expect(cache.ttlFor('/public/categories'), ApiCache.ttlOps);
      expect(cache.ttlFor('/public/home'), ApiCache.ttlOps);
      expect(cache.ttlFor('/divisions/grouped'), ApiCache.ttlDivision);
      expect(cache.ttlFor('/public/announcements'), ApiCache.ttlDict,
          reason: '真正的低频字典端点仍留在 10 分钟档（运营档不是"一刀切"）');
      expect(cache.ttlFor('/public/products'), ApiCache.ttlList);
      expect(cache.ttlFor('/user/conversations'), ApiCache.ttlChat);
    });
  });

  group('缓存隔离（防止为了性能引入串味）', () {
    test('不同地址的客户端共用同一个 ApiCache 也不会互相命中', () async {
      final a1 = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"who":"A"}}');
      final apiA = clientFor('http://server-a.test/api/v1', a1);
      final a2 = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"who":"B"}}');
      final apiB = clientFor('http://server-b.test/api/v1', a2);

      final ra = await apiA.request('GET', '/divisions');
      final rb = await apiB.request('GET', '/divisions');

      expect(ra['data']?['who'], 'A');
      expect(rb['data']?['who'], 'B',
          reason: '地址是缓存键的一部分：换服务器（隧道换址）后不能拿到上一台的缓存');
      expect(a2.paths.length, 1, reason: 'B 服务器必须真的被请求一次');
    });

    test('换会话（登录/换号）后旧缓存不可见', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"who":"anon"}}');
      final api = clientFor('http://perf-s.test/api/v1', adapter);

      await api.request('GET', '/divisions');
      expect(adapter.paths.length, 1);

      // 模拟登录：会话维度变化 + 清空旧缓存（AuthStore._saveTokens 的真实行为）
      ApiCache.instance.beginSession('auth');

      final adapter2 = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"who":"auth"}}');
      final api2 = clientFor('http://perf-s.test/api/v1', adapter2);
      final r = await api2.request('GET', '/divisions');
      expect(r['data']?['who'], 'auth',
          reason: '换会话后必须回源，绝不能拿到上一会话的数据');
      expect(adapter2.paths.length, 1);
    });
  });
}
