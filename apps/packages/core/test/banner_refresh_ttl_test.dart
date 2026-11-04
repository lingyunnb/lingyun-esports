/// **换图"秒刷新"：banners TTL = 60 秒 + 走 SWR 的 revalidate（不是清空重来）**
/// （2026-10-16 负责人「加秒刷新 + 不要在等转圈」）
///
/// ## 病灶
/// 2026-10-16「治卡」专项把宣传图当成"改动以周计的运营素材"挂在 **8 分钟**档 ——
/// 对"几乎不变的图"合理，**对刚换的那一张就是纯粹的延迟**：运营在管理端换完图，
/// App 最长 8 分钟还是旧图。
///
/// ## 本文件钉死的三件事
/// 1. **banners = 60 秒**（具体值，不是"小于 8 分钟"这种含糊断言），并与三处对齐：
///    服务端 `/public/banners` 的 `Cache-Control: private, max-age=60`、客户端运营档 `ttlOps`、
///    "运营改完 ≤1 分钟可见"的既有判据；
/// 2. **`/public/home` 聚合体的 min-TTL 复核**：改动前后**都是 players 的 30s** ——
///    banners 60s **既不拉长**（它本来也不是最快的那一段）、**也不缩短**整包；
/// 3. **到点走 revalidate 分支**：`request()` 必须**先返回已缓存的旧数据**（页面上旧图留屏上）
///    并**后台静默回源**，把新数据写回缓存 —— 而不是"清空重来"（返回空/错误 → 页面骨架/转圈）。
///
/// ## 为什么能测"到点"（时钟钩子）
/// `ApiCache.debugClockOffset` 只把本缓存的"现在"整体前拨，判定仍是
/// `now - at < ttl` 那一行（生产默认偏移为 0，行为逐字不变）。
/// 不这么做就得真等 60 秒 —— 而本项目 `flutter test` 是全量并行跑的，不可接受。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _envelope(Object? data) =>
    <String, dynamic>{'code': 0, 'message': 'ok', 'data': data};

/// 线上两条宣传图的真实形状（2026-10-16 真人真数据：media 292/293，1920×1080）
List<dynamic> _bannersBody(String mediaId, {String title = '欢迎光临祁连山电竞'}) => <dynamic>[
      <String, dynamic>{
        'id': mediaId == '292' ? '136' : '137',
        'title': title,
        'subtitle': '',
        'imageMediaId': mediaId,
        'imageUrl': '',
        'imageWidth': 1920,
        'imageHeight': 1080,
        'linkType': 'none',
        'linkValue': '',
        'sortOrder': 0,
        'startAt': null,
        'endAt': null,
      },
    ];

/// 首页聚合的真实形状（五段 + updatedAt）
Map<String, dynamic> _aggregateBody(String mediaId) => <String, dynamic>{
      'announcements': <dynamic>[],
      'banners': _bannersBody(mediaId),
      'divisions': <dynamic>[
        <String, dynamic>{'id': '1', 'code': 'peace_mobile', 'name': '和平精英 · 手游', 'onlineCount': 12},
      ],
      'hotProducts': <dynamic>[
        <String, dynamic>{'id': 'p1', 'name': '上分陪练', 'price': '38.00'},
      ],
      'players': <dynamic>[
        <String, dynamic>{'workerId': 'w1', 'nickname': '陪玩甲', 'intro': '只接三角洲手游'},
      ],
      'leaderboard': <dynamic>[
        <String, dynamic>{'rank': 1, 'nickname': '陪玩甲', 'value': 2847},
      ],
      'updatedAt': '2026-10-16T10:00:00.000Z',
    };

/// 可变的假通道（**真 ApiClient + 真 ApiCache**）：宣传图媒体 id 可换，
/// 用来复现"运营换了图 → 客户端下次回源拿到新图"。
class _SwapAdapter implements HttpClientAdapter {
  _SwapAdapter({this.mediaId = '292', this.aggregate = false});

  /// 服务端当前那条宣传图的 `imageMediaId`（运营换图就改它）
  String mediaId;

  /// true = 只服务 `/public/home` 聚合（形状同真实聚合体）
  final bool aggregate;

  final List<String> requests = <String>[];

  int countOf(String path) => requests.where((p) => p.startsWith(path)).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.path);
    final Object? data = options.path.startsWith('/public/home')
        ? (aggregate ? _aggregateBody(mediaId) : null)
        : options.path.startsWith('/public/banners')
            ? _bannersBody(mediaId)
            : <dynamic>[];
    return ResponseBody.fromString(
      jsonEncode(_envelope(data)),
      200,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]},
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _api(_SwapAdapter adapter, String host) {
  final dio = Dio(BaseOptions(baseUrl: 'http://$host/api/v1'))..httpClientAdapter = adapter;
  return ApiClient(dio: dio);
}

void main() {
  setUp(() {
    AppSettings.debugStorageDisabled = true;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
    ApiCache.instance.debugClockOffset = Duration.zero;
  });

  tearDown(() {
    AppSettings.debugStorageDisabled = false;
    ApiClient.cacheEnabled = true;
    ApiCache.instance.debugClockOffset = Duration.zero;
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  // -------------------------------------------------------------------
  // ④ banners 的 TTL = 60 秒（具体值）
  // -------------------------------------------------------------------
  group('④ banners TTL = 60 秒', () {
    test('档位常量与登记：都是 60 秒（不是 8 分钟、也不是"小于 8 分钟"）', () {
      expect(ApiCache.ttlBanner, const Duration(seconds: 60));
      expect(ApiCache.ttlBanner.inSeconds, 60);
      expect(ApiCache.ttlBanner.inMinutes, 1, reason: '运营换完图，最长 1 分钟必须可见');
      expect(ApiCache.instance.ttlFor('/public/banners'), const Duration(seconds: 60),
          reason: '独立接口路径（首页回落到分接口时走的就是它）');
    });

    test('与服务端响应头 / 运营档 / 其它档的关系（四条不变量）', () {
      expect(ApiCache.ttlBanner, ApiCache.ttlOps,
          reason: '与服务端 `/public/banners` 的 `Cache-Control: private, max-age=60` 同值；'
              '也等于"运营改完 ≤1 分钟可见"的运营档');
      expect(ApiCache.ttlBanner < ApiCache.ttlDivision, isTrue, reason: '换图是日常动作，比"接新游戏才变"的分部档短');
      expect(ApiCache.ttlBanner < ApiCache.ttlDict, isTrue, reason: '不许长到字典档（10 分钟）');
      expect(ApiCache.ttlBanner > ApiCache.ttlLive, isTrue,
          reason: '必须长于聚合体里最快的一段（players 30s），否则它会取代 players 成为整包 min-TTL');
    });

    test('按响应体取档也认它：`/public/banners` 的包 → 60 秒', () {
      final cache = ApiCache.instance;
      expect(cache.ttlForBody('/public/banners', _envelope(_bannersBody('292'))), const Duration(seconds: 60));
      expect(cache.ttlForBody('/public/banners', null), const Duration(seconds: 60));
      expect(
        cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'banners': _bannersBody('292')})),
        const Duration(seconds: 60),
        reason: '只有宣传图那一段的包 → 整包按 60 秒算',
      );
    });

    test('60 秒内的重复请求命中缓存；到点判过期（阈值就是 60 秒）', () {
      final cache = ApiCache.instance;
      const base = 'http://banner-ttl.test/api/v1';
      final key = cache.keyOf('/public/banners', null, apiBase: base);
      cache.put(key, _envelope(_bannersBody('292')));

      expect(cache.get(key, ApiCache.ttlBanner)?.fresh, isTrue, reason: '刚写入的条目当然新鲜（缓存能力没被砍）');

      cache.debugClockOffset = const Duration(seconds: 59);
      expect(cache.get(key, ApiCache.ttlBanner)?.fresh, isTrue, reason: '59 秒 < 60 秒 → 仍新鲜');

      cache.debugClockOffset = const Duration(seconds: 61);
      expect(cache.get(key, ApiCache.ttlBanner)?.fresh, isFalse, reason: '61 秒 > 60 秒 → 判过期（不再拿 8 分钟旧图）');
      // 对照物：若 TTL 还是 8 分钟，同一时刻仍会被当成"新鲜"—— 那正是本次要修的缺陷机制
      expect(cache.get(key, const Duration(minutes: 8))?.fresh, isTrue,
          reason: '对照：8 分钟档下 61 秒的旧图仍算新鲜 → 换图后用户最长 8 分钟看不到新的');
    });
  });

  // -------------------------------------------------------------------
  // ⑤ /public/home 聚合体的 min-TTL 复核
  // -------------------------------------------------------------------
  group('⑤ `/public/home` 聚合体的 min-TTL 复核（改完不许被意外拉长或缩短）', () {
    test('完整聚合体 → 仍是 30 秒（players 段决定），与改动前逐字一致', () {
      final cache = ApiCache.instance;
      final ttl = cache.ttlForBody('/public/home', _envelope(_aggregateBody('292')));

      expect(ttl, const Duration(seconds: 30));
      expect(ttl, ApiCache.ttlLive);
      expect(ttl, isNot(ApiCache.ttlBanner), reason: '整包绝不是按宣传图的档算的');
      expect(ttl < ApiCache.ttlBanner, isTrue);
      expect(ttl < ApiCache.ttlDivision, isTrue);
      // 实测复核（不是猜）：把聚合体里各段自己的档位摆出来，min 必须还是 30s
      final perSegment = <String, Duration>{
        'banners': cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'banners': <dynamic>[]})),
        'divisions': cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'divisions': <dynamic>[]})),
        'leaderboard': cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'leaderboard': <dynamic>[]})),
        'hotProducts': cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'hotProducts': <dynamic>[]})),
        'players': cache.ttlForBody('/public/home', _envelope(<String, dynamic>{'players': <dynamic>[]})),
      };
      // ignore: avoid_print
      print('[TTL] 聚合体各段档位=$perSegment → min=${perSegment.values.reduce((a, b) => a < b ? a : b)}');
      expect(perSegment['banners'], const Duration(seconds: 60),
          reason: '宣传图段从 8 分钟改成 60 秒（本次改动），但**它不是 min**');
      expect(perSegment['players'], const Duration(seconds: 30));
      expect(perSegment.values.reduce((a, b) => a < b ? a : b), ttl,
          reason: '整包 = 各段 min，复核结果仍是 players 的 30s：既没被 banners 拉长，也没被它缩短');
    });

    test('banners 改动**不可能**影响 min：它必须严格长于 players', () {
      expect(ApiCache.ttlBanner > ApiCache.ttlLive, isTrue);
      final cache = ApiCache.instance;
      final withBanners = cache.ttlForBody('/public/home', _envelope(_aggregateBody('292')));
      final withoutBanners = cache.ttlForBody(
        '/public/home',
        _envelope(<String, dynamic>{'players': <dynamic>[<String, dynamic>{'workerId': 'w1'}]}),
      );
      expect(withBanners, withoutBanners, reason: '带上 banners 段后整包 TTL 一分不变');
    });
  });

  // -------------------------------------------------------------------
  // 秒刷新：到点走 SWR 的 revalidate（先给旧图 + 后台换新图）
  // -------------------------------------------------------------------
  group('换图路径：SWR revalidate（旧数据留屏上，后台静默换成新的）', () {
    test('TTL 到点 → 返回的是**已缓存的旧宣传图**，同时后台真的回源', () async {
      final adapter = _SwapAdapter(mediaId: '292');
      final api = _api(adapter, 'banner-swr.test');

      final first = await api.request('GET', '/public/banners');
      expect(adapter.countOf('/public/banners'), 1);
      expect((first['data'] as List).first['imageMediaId'], '292');

      // 运营换图：服务端那条宣传图换成 mediaId=293
      adapter.mediaId = '293';
      // 时间过 60 秒（TTL 到点）
      ApiCache.instance.debugClockOffset = const Duration(seconds: 61);

      final second = await api.request('GET', '/public/banners');
      // ① 先给旧数据（页面上就是"旧图留屏上"，不是空白/骨架）
      expect((second['data'] as List).first['imageMediaId'], '292',
          reason: '过期分支必须**先返回旧值**（SWR 的核心），不能返回空/错误让页面清空重来');
      expect((second['data'] as List).isNotEmpty, isTrue, reason: '"清空重来"会返回空 → 页面骨架/转圈');
      expect(ApiCache.instance.revalidateCount, greaterThan(0), reason: '必须走的是 revalidate 分支');

      // ② 后台那一发真的发出去了，并把**新图**写回缓存（静默替换）
      await pumpEventQueue();
      expect(adapter.countOf('/public/banners'), 2, reason: '后台必须静默回源一次');
      final key = ApiCache.instance.keyOf('/public/banners', null, apiBase: api.cacheScopeBase);
      final cached = ApiCache.instance.peek(key);
      expect(cached, isNotNull);
      expect((cached!.body['data'] as List).first['imageMediaId'], '293',
          reason: '静默回源后缓存里已是新图：下一次渲染/下一次进页面看到的就是它');

      // ③ 再请求一次（刚 revalidate 过，是新鲜的）→ 不再多发网络，且直接给新图
      final third = await api.request('GET', '/public/banners');
      expect((third['data'] as List).first['imageMediaId'], '293');
      expect(adapter.countOf('/public/banners'), 2, reason: 'revalidate 刚写完 → 新鲜窗口内命中缓存');
    });

    test('聚合接口同样走 SWR：旧首屏先上屏、新数据后台换（不发空包、不闪骨架）', () async {
      final adapter = _SwapAdapter(mediaId: '292', aggregate: true);
      final api = _api(adapter, 'banner-swr-agg.test');

      final first = await api.request('GET', '/public/home');
      expect((first['data'] as Map)['banners'][0]['imageMediaId'], '292');

      adapter.mediaId = '293';
      ApiCache.instance.debugClockOffset = const Duration(seconds: 31); // 聚合体是 30s 档

      final second = await api.request('GET', '/public/home');
      final oldAgg = second['data'] as Map;
      expect(oldAgg['banners'][0]['imageMediaId'], '292', reason: '整包先给旧值（页面已有内容可渲染）');
      expect((oldAgg['divisions'] as List), isNotEmpty, reason: '旧包是**完整**的（不是空壳），首屏所有区块都能继续显示');

      await pumpEventQueue();
      final key = ApiCache.instance.keyOf('/public/home', null, apiBase: api.cacheScopeBase);
      expect((ApiCache.instance.peek(key)!.body['data'] as Map)['banners'][0]['imageMediaId'], '293',
          reason: '后台换成新图，下次进页面/下次渲染即是新的');
      expect(adapter.countOf('/public/home'), 2);
    });

    test('下拉刷新（forceRefresh）绕过 TTL 直接拿新图 —— 运营改完不必等 60 秒', () async {
      final adapter = _SwapAdapter(mediaId: '292');
      final api = _api(adapter, 'banner-force.test');
      await api.request('GET', '/public/banners');
      expect(adapter.countOf('/public/banners'), 1);

      adapter.mediaId = '293';
      // 缓存**仍然新鲜**（0 秒偏移）也要回源
      final r = await api.request('GET', '/public/banners', forceRefresh: true);
      expect(adapter.countOf('/public/banners'), 2, reason: 'forceRefresh 必须真回源，不许被缓存拦住');
      expect((r['data'] as List).first['imageMediaId'], '293', reason: '下拉刷新拿到的就是新图');
    });

    test('换图后框体高度不跟着图片尺寸变（恒 156，换图永不引起布局跳动）', () {
      final oldItems = (jsonDecode(jsonEncode(_bannersBody('292'))) as List)
          .map((e) => HomeBannerItem.fromJson(e as Map))
          .toList();
      final newItems = (jsonDecode(jsonEncode(_bannersBody('293'))) as List)
          .map((e) => HomeBannerItem.fromJson(e as Map))
          .toList();
      expect(oldItems.first.imageMediaId, '292');
      expect(newItems.first.imageMediaId, '293', reason: '换了图 → mediaId 变 → 磁盘缓存未命中 → 需要有"旧图兜住空窗"');
      // 【2026-10-16 负责人二次定案】框体**恒 156**（图片走 BoxFit.fill 拉伸铺满）：
      // 渲染不再用 imageWidth/imageHeight → 换图**在任何比例下**都不会引起高度跳动
      //（比"比例相同时才不抖"更强的保证）。尺寸字段仍由服务端返回、客户端仍解析，只是不参与定高。
      expect(HomeBannerCarousel.height, 156);
      expect(oldItems.first.imageWidth, 1920, reason: '尺寸字段保留：服务端继续返回、fromJson 继续解析');
      expect(newItems.first.imageWidth, 1920);
      expect(oldItems.first.imageHeight, 1080);
      expect(newItems.first.imageHeight, 1080);
    });
  });
}
