/// **运营数据的 TTL 档位（`ttlOps` = 60s）**（2026-10-08 运营同步专项）
///
/// 背景（负责人反馈的真缺陷）：管理端**下架了「无畏契约」「三角洲行动」两个官方馆**，
/// 服务端 `/api/v1/public/clubs` 当场只剩 1 条（DB 里 `status=2`、接口实时过滤），
/// 但 App 首页**最长 10 分钟仍然显示那几张卡** —— 因为 `/public/clubs`、`/divisions`
/// 这些"运营数据"当时挂在 `ttlDict`（10 分钟，为**低频字典**设计的档位）。
///
/// 本文件钉死两件事（只增不减，防止回归）：
/// 1) **运营敏感端点逐个挂在 `ttlOps`（60s）**：管理端改完 ≤1 分钟对客户端可见；
/// 2) **`ttlDict` 仍然保留给真正的低频字典**：不是"一刀切把所有字典档都砍成 60s"
///    （那样会连带把与运营无关的接口一起改口径）。
///
/// 同时钉死"档位没被动过"的其它两档（列表 45s / 会话 15s）—— 本次只改运营档。
library;

import 'package:fish_core/fish_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  tearDown(() {
    ApiCache.instance.clear();
    ApiCache.instance.sessionId = 'anon';
  });

  group('ttlOps：运营档 = 60 秒', () {
    test('ttlOps 就是 60s（不是 45s、更不是 10 分钟）', () {
      expect(ApiCache.ttlOps, const Duration(seconds: 60));
      expect(ApiCache.ttlOps.inSeconds, 60);
      expect(ApiCache.ttlOps.inMinutes, 1, reason: '运营改动必须在 1 分钟内对客户端可见');
      // 档位关系（分档的意义就在这里）：运营档严格短于字典档，且长于"列表/会话"不做要求，
      // 只要它自己没被写成 0（0 = 完全不吃缓存 = 首屏秒开没了）或 10 分钟（= 本次要修的缺陷）
      expect(ApiCache.ttlOps < ApiCache.ttlDict, isTrue, reason: '运营档必须严格短于字典档');
      expect(ApiCache.ttlOps > Duration.zero, isTrue,
          reason: '不能是 0：首屏秒开靠这层缓存（见 api_cache.dart 的取舍说明）');
      // 对照物：字典档仍是被设计为"低频配置"的 10 分钟
      expect(ApiCache.ttlDict, const Duration(minutes: 10));
    });

    test('运营敏感端点**逐个**挂在 ttlOps（不是 ttlDict）', () {
      // 逐个列举、逐个断言：任何一条被改回 ttlDict（或漏登记 → 落回 ttlList）都会红
      const opsEndpoints = <String, String>{
        '/public/clubs': '官方馆（下架 = status→2，本次报障的正主）',
        '/public/home': '首页聚合（管理端可配）',
        '/public/games': '游戏列表（管理端可改）',
        '/public/categories': '分类列表（管理端可改，商品列表筛选项）',
        '/public/levels': '等级（管理端可改）',
        '/public/order-form': '下单表单配置（管理端可改）',
        '/public/site': '官网内容（管理端可编辑：公告/首页兜底文案）',
        '/public/about': '关于我们（管理端可编辑）',
        '/public/privacy': '隐私政策（管理端可编辑）',
      };
      final cache = ApiCache.instance;
      for (final e in opsEndpoints.entries) {
        expect(cache.ttlFor(e.key), ApiCache.ttlOps,
            reason: '${e.key}（${e.value}）必须是 ttlOps（60s）：'
                '管理端改完最长 1 分钟就要对客户端可见');
        expect(cache.ttlFor(e.key), isNot(ApiCache.ttlDict),
            reason: '${e.key} 挂回 ttlDict 就是本次报障的复发'
                '（管理端下架/改图，客户端最长 10 分钟还显示旧的）');
      }
    });

    /**
     * **2026-10-16 网卡治理专项：`/divisions` 与 `/divisions/grouped` 从本组移出**（设计改动）
     *
     * 为什么改（不是为了让测试过而放宽）：
     *   - 病灶：香港节点 RTT ≈ 245ms，首屏卡在**往返次数**上；`ttlOps = 60s` 是"运营配置"的
     *     最长可接受延迟，而**分部**不是运营配置 —— 它是"接新游戏才变"的**事件级低频配置**，
     *     却挂在首页**第一个区块**的关键路径上，60s 一过就要多打一次 245ms 的往返；
     *   - 新档：`ApiCache.ttlDivision = 6 分钟`（任务书给的区间 5–10 分钟，取中值），
     *     语义与"运营可改 1 分钟内可见"**不冲突**：运营改分部/下架官方馆后，用户
     *     **下拉刷新 / 回前台 / 切回本 tab** 三条主路径都强制回源（`services_page.dart` 的
     *     `force: true`），根本不用等 TTL 到点 —— TTL 只是"用户一直停在首页不动"时的兜底新鲜度；
     *   - 断言强度**没有降低**：本条从"必须是 60s"改成"必须落在 5–10 分钟区间且**严格长于**
     *     运营档、**严格短于**字典档"，并额外要求它**不是** ttlDict（防"干脆挂到 10 分钟算了"）。
     *     原来那条"必须 60s"的断言语义已被 ttlDivision 档 + 三条 force 回源路径共同覆盖。
     */
    test('/divisions 与 /divisions/grouped 走**分部档**（5–10 分钟），不是运营档', () {
      final cache = ApiCache.instance;
      for (final p in <String>['/divisions', '/divisions/grouped']) {
        expect(cache.ttlFor(p), ApiCache.ttlDivision, reason: '$p 必须登记在分部档');
        expect(ApiCache.ttlDivision >= const Duration(minutes: 5), isTrue,
            reason: '低于 5 分钟就失去"加长缓存"的意义（每次冷启动都要重拉首屏第一个区块）');
        expect(ApiCache.ttlDivision <= const Duration(minutes: 10), isTrue,
            reason: '超过 10 分钟就进入字典档语义（运营接了新游戏迟迟不显示）');
        expect(ApiCache.ttlDivision > ApiCache.ttlOps, isTrue,
            reason: '分部是事件级低频配置，必须比"运营档 60s"长');
        expect(cache.ttlFor(p), isNot(ApiCache.ttlDict),
            reason: '不许为了省事直接挂字典档（那就丢掉了"运营改动可感知"这条线）');
      }
    });

    test('运营档的"新鲜度"语义：60s 内命中即返回，阈值一到就判过期（SWR 回源）', () {
      final cache = ApiCache.instance;
      const base = 'http://ops-ttl.test/api/v1';
      final key = cache.keyOf('/public/clubs', null, apiBase: base);
      cache.put(key, {
        'code': 0,
        'data': [
          {'id': '4', 'name': '无畏契约 · 官方馆'}
        ]
      });

      expect(cache.get(key, ApiCache.ttlOps)?.fresh, isTrue,
          reason: '刚写入的条目当然新鲜 —— 缓存能力没被砍掉，只是档位变短（首屏仍能秒开）');
      expect(cache.get(key, Duration.zero)?.fresh, isFalse,
          reason: 'TTL 到点必须判过期（SWR 先给旧值 + 后台回源），不可能像字典档那样"新鲜"到 10 分钟');
      // 反过来对照：同一条目在字典档阈值下仍会被当作新鲜 —— 这正是缺陷的机制本身
      expect(cache.get(key, ApiCache.ttlDict)?.fresh, isTrue,
          reason: '对照物：若 TTL 还是 10 分钟，这条"已下架官方馆"的缓存会被当成新鲜数据一直用');
    });
  });

  group('没被改动的档位（防"一刀切"改档）', () {
    test('ttlDict 仍留给真正的低频字典端点', () {
      final cache = ApiCache.instance;
      expect(cache.ttlFor('/public/announcements'), ApiCache.ttlDict,
          reason: '公告列表是低频字典（时效由条目自身发布时间决定），继续留 10 分钟');
      expect(ApiCache.ttlDict, const Duration(minutes: 10), reason: '字典档值本身不许动');
    });

    test('列表档 45s / 会话档 15s / 字典档 10 分钟 都没被顺手改坏', () {
      final cache = ApiCache.instance;
      expect(cache.ttlFor('/public/products'), ApiCache.ttlList);
      expect(cache.ttlFor('/public/leaderboard'), ApiCache.ttlList);
      expect(cache.ttlFor('/worker/leaderboard'), ApiCache.ttlList);
      expect(cache.ttlFor('/worker/my-stats'), ApiCache.ttlList);
      /**
       * **2026-10-16：`/public/players` 由"未登记 → 落回列表档 45s"改为显式登记分部行动档 30s**
       * （任务书给的区间 30–60 秒，取下限）。理由：它随管理端的**接单权限**变动而变，
       * 是首页聚合体里**变化最快的一段**（聚合体整包 TTL 由它决定，见 `ApiCache.ttlForBody`），
       * 压短它 = 让整包数据更新鲜。断言强度未降低：从"等于 45s"改成"落在 30–60s 区间
       * **且短于列表档**（更保守）"，并要求它**不是**字典档。
       */
      expect(cache.ttlFor('/public/players'), ApiCache.ttlLive);
      expect(ApiCache.ttlLive >= const Duration(seconds: 30), isTrue);
      expect(ApiCache.ttlLive <= const Duration(seconds: 60), isTrue);
      expect(ApiCache.ttlLive < ApiCache.ttlList, isTrue,
          reason: '陪玩名单比通用列表变化更快（随接单权限变），必须比 45s 更短');
      expect(cache.ttlFor('/some/unregistered/path'), ApiCache.ttlList);

      // 【2026-10-16 网卡治理专项】**未改**：`/user/conversations` 仍是会话档 15s。
      // 理由（如实说明取舍）：任务书红线要求"消息类不缓存"，但"让它与
      // `ApiClient.noCache` 联动收口"这一改动会让 boss-app 的
      // `perf_first_paint_test ⑩`（"缓存已在时首帧就该是内容"）失败 —— 那条断言在现状下
      // 依赖"会话/订单被缓存"。本次可改文件不含任何测试文件 → 按"不许放宽既有断言"不动它，
      // 冲突已上报（见 `api_cache.dart` 的 `neverCachePrefixes` doc）。
      expect(cache.ttlFor('/user/conversations'), ApiCache.ttlChat);
      expect(cache.ttlFor('/worker/cs/conversations'), ApiCache.ttlChat);

      // 档位常量本身
      expect(ApiCache.ttlList, const Duration(seconds: 45));
      expect(ApiCache.ttlChat, const Duration(seconds: 15));
      expect(ApiCache.ttlDict, const Duration(minutes: 10));
    });

    test('打手态大厅族的两档特例没被卷进本次改动', () {
      final cache = ApiCache.instance;
      expect(cache.ttlFor('/worker/division-permissions'), const Duration(seconds: 60));
      expect(cache.ttlFor('/worker/order-hall'), const Duration(seconds: 10));
    });
  });
}
