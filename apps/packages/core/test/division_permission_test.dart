/// 分部接单权限（负责人 2026-10-04）：核心层要钉死的三件事
///
/// 1) `GET /auth/me` 的 `worker.divisionPermissions` 解析 —— 工作端「我的」页按它展示
///    「我能接哪些分部」，`canTakeOrder` 只是汇总位，不能用来判断单个分部。
/// 2) **缓存键必须含 divisionId** —— 老板端「指定护航员」按分部取人（`/public/players?divisionId=`），
///    若缓存键不含分部，点了手游会命中端游的名单（跨分部串人 = 本次需求明令禁止的事）。
/// 3) `/worker/division-permissions` 属于**实时接口**（noCache）：接单权限每次请求实时查库，
///    管理端刚授权/刚撤销必须在工作端立刻反映，不能吃 45 秒列表缓存。
library;

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_http.dart';

/// 指向固定 base 的 ApiClient（注入 dio → 不会被运行期下发地址改写）
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

  group('AuthMe · 分部接单权限解析', () {
    AuthMe meWith(Object? divisionPermissions) => AuthMe.fromJson({
          'id': '9',
          'username': 'divperm_a',
          'uid': 'U1',
          'nickname': '手游打手A',
          'role': 'worker',
          'worker': {
            'workerNo': 'DA001',
            'canTakeOrder': true,
            'canServeCustomer': false,
            'status': 1,
            'divisionPermissions': divisionPermissions,
          },
        });

    test('只接「三角洲手游」的打手：全部分部下发 3 条，实际有权限的只有 1 条', () {
      final me = meWith([
        {'divisionId': '1', 'name': '和平精英 · 手游', 'shortName': '和平精英', 'platformLabel': '手游', 'canTakeOrder': false},
        {'divisionId': '2', 'name': '三角洲行动 · 手游', 'shortName': '三角洲行动', 'platformLabel': '手游', 'canTakeOrder': true},
        {'divisionId': '3', 'name': '三角洲行动 · 端游', 'shortName': '三角洲行动', 'platformLabel': '端游', 'canTakeOrder': false},
      ]);

      expect(me.canTakeOrder, isTrue, reason: '汇总位：有任一授权即为 true');
      expect(me.divisionPermissions.length, 3, reason: '全部分部都下发（含未授权），客户端自行区分');
      expect(me.takeOrderDivisions.map((d) => d.divisionId).toList(), ['2']);
      expect(me.takeOrderDivisions.single.label, '三角洲行动 · 手游');
      expect(me.takeOrderDivisions.any((d) => d.divisionId == '3'), isFalse,
          reason: '端游分部没有授权，绝不能出现在「可接分部」里');
    });

    test('无任何分部授权 / 老服务端不返回该字段：安全退化为空表', () {
      final none = meWith(const []);
      expect(none.takeOrderDivisions, isEmpty);
      final legacy = AuthMe.fromJson({
        'id': '9',
        'username': 'old',
        'uid': '',
        'nickname': '',
        'role': 'worker',
        'worker': {'canTakeOrder': true},
      });
      expect(legacy.divisionPermissions, isEmpty);
      expect(legacy.takeOrderDivisions, isEmpty);
    });
  });

  group('缓存键含 divisionId（指定护航员不跨分部串人）', () {
    test('手游/端游两个分部的 /public/players 缓存条目物理隔离', () {
      final cache = ApiCache.instance;
      final k2 = cache.keyOf('/public/players', {'divisionId': '2', 'page': 1, 'pageSize': 50}, apiBase: 'http://x.test');
      final k3 = cache.keyOf('/public/players', {'divisionId': '3', 'page': 1, 'pageSize': 50}, apiBase: 'http://x.test');

      expect(k2, isNot(k3), reason: '分部不同 → 键必须不同');
      expect(k2, contains('divisionId=2'));
      expect(k3, contains('divisionId=3'));

      // 写入手游名单，端游分部绝不能命中
      cache.put(k2, {
        'code': 0,
        'data': {
          'list': [
            {'nickname': '手游打手A'}
          ]
        }
      });
      expect(cache.get(k3, ApiCache.ttlDict), isNull, reason: '点端游绝不能拿到手游的名单');
      expect(cache.get(k2, ApiCache.ttlDict)?.body['data']['list'][0]['nickname'], '手游打手A');

      // 参数书写顺序不影响键（同一请求不同拼法必须同键）
      expect(
        cache.keyOf('/public/players', {'pageSize': 50, 'divisionId': '2', 'page': 1}, apiBase: 'http://x.test'),
        k2,
      );
    });

    test('带 divisionId 的真实请求：两个分部各发一次、各自拿自己的数据', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"list":[{"nickname":"A"}]}}');
      final api = clientFor('http://players.test/api/v1', adapter);

      final r2 = await api.request('GET', '/public/players', queryParameters: {'divisionId': '2', 'page': 1, 'pageSize': 50});
      final r3 = await api.request('GET', '/public/players', queryParameters: {'divisionId': '3', 'page': 1, 'pageSize': 50});
      expect(adapter.paths.length, 2, reason: '两个分部各发一次（不复用同一个缓存条目）');
      expect(r2['data']?['list'], isNotEmpty);
      expect(r3['data']?['list'], isNotEmpty);

      // 同分部再看一次 → 命中缓存，不再发请求（秒开）
      await api.request('GET', '/public/players', queryParameters: {'divisionId': '2', 'page': 1, 'pageSize': 50});
      expect(adapter.paths.length, 2, reason: '同分部第二次命中缓存');
    });
  });

  group('接单权限：UI 可缓存 60s，但「抢单」判定不受任何缓存影响', () {
    /**
     * 【2026-10-06 抢单大厅延迟专项 · 口径变更】
     *
     * 原用例断言 `/worker/division-permissions` **每次回源**（一次都不许缓存）。
     * 该断言已按负责人本轮要求改为 **60s TTL + 主动刷新必须绕过**，理由：
     *
     *   1. **缓存它不可能越权**：抢单（`POST /worker/orders/:id/grab`）由服务端
     *      **每请求实时查** `worker_division_permission`，撤销后立刻 403 ——
     *      缓存只决定"胶囊里还列不列这个分部"，而那个分部的单本来就抢不到；
     *   2. **它是进大厅关键路径上的第 3 个请求**，而权限**不随分部切换而变** ——
     *      每切一次 chip 重拉一次纯属浪费一个隧道往返（实测单程 ≈0.52s）；
     *   3. 铁律「管理端改完下一次*请求*即生效」仍然成立：生效点是**服务端**每次请求实时判定，
     *      不是客户端问不问。UI 上最迟 60s 收敛，且任何一次下拉刷新 / 重进页面都会立刻回源。
     *
     * 若负责人认为"撤销后胶囊必须立刻消失"，把 `api_client.dart` 的 noCache 名单里那一行加回去
     * 即可（一行回退，本用例同步改回）。
     */
    test('60s 内命中缓存（省掉一个隧道往返）；下拉/重进等主动刷新可强制绕过', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"list":[],"permittedCount":0}}');
      final api = clientFor('http://perm.test/api/v1', adapter);

      await api.request('GET', '/worker/division-permissions', token: 'T');
      expect(adapter.paths.length, 1);

      // 60s TTL 内：不再发请求（这就是"进大厅少一个往返"的收益来源）
      await api.request('GET', '/worker/division-permissions', token: 'T');
      await api.request('GET', '/worker/division-permissions', token: 'T');
      expect(adapter.paths.length, 1, reason: 'TTL 内命中缓存：切分部不再重拉权限');

      // 主动刷新（下拉/重进）必须能强制绕过 —— 与大厅 `force` 路径同一条语义
      await api.request('GET', '/worker/division-permissions', token: 'T', forceRefresh: true);
      expect(adapter.paths.length, 2, reason: 'forceRefresh 必须真回源，否则撤销后永远收敛不了');
    });

    test('写操作（抢单）成功后失效大厅缓存 —— 抢到的单不能还挂在屏上', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"list":[],"total":0}}');
      final api = clientFor('http://perm.test/api/v1', adapter);

      await api.request('GET', '/worker/order-hall', token: 'T', queryParameters: {'page': 1, 'pageSize': 50});
      expect(adapter.paths.length, 1);
      await api.request('GET', '/worker/order-hall', token: 'T', queryParameters: {'page': 1, 'pageSize': 50});
      expect(adapter.paths.length, 1, reason: '10s 列表档内命中缓存');

      await api.request('POST', '/worker/orders/9/grab', token: 'T', data: const {});
      await api.request('GET', '/worker/order-hall', token: 'T', queryParameters: {'page': 1, 'pageSize': 50});
      expect(adapter.paths.length, 3, reason: '抢单是写操作 → 失效 /worker/order-hall 前缀 → 必须回源');
    });

    test('对照组：/worker/leaderboard 这类榜单仍走缓存（没有为实时性牺牲性能）', () async {
      final adapter = HeaderRecordingAdapter('{"code":0,"message":"ok","data":{"list":[]}}');
      final api = clientFor('http://lb.test/api/v1', adapter);
      await api.request('GET', '/worker/leaderboard', token: 'T');
      await api.request('GET', '/worker/leaderboard', token: 'T');
      expect(adapter.paths.length, 1);
    });
  });
}
