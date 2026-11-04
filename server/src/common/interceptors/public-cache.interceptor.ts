import { Injectable, NestInterceptor, ExecutionContext, CallHandler } from '@nestjs/common';
import { Observable, of, tap } from 'rxjs';

/**
 * 热点公开接口的**服务端微缓存** + **缓存响应头**（负责人 2026-10-04：继续更快）
 *
 * 只缓存 **匿名公开 GET**（分部/官方馆/下单表单/游戏/分类/首页这类字典数据），
 * TTL 30 秒：这一层挡掉绝大多数重复查询与数据库往返（配合客户端 SWR，
 * 用户侧基本不再触发真实查询）。带鉴权的请求一律不缓存，避免越权串数据。
 *
 * 【2026-10-04 性能专项补强】此前只做了进程内缓存、**没有下发任何 Cache-Control**，
 * 于是每个客户端都只能"每次问一遍"：
 * - 浏览器 / OkHttp / admin-web 的 HTTP 缓存层完全用不上（每条请求都要走网络往返）；
 * - 移动网络下"一次往返"就是 60~300ms，而服务端算完只要 2~4ms —— 瓶颈在往返，不在算力。
 * 现在按前缀下发 Cache-Control，并把 `max-age` 与**进程内 TTL 对齐**（同为 30s），
 * 避免"客户端以为还能用、服务端已经换了数据"的不一致窗口。
 *
 * 为什么是 `private` 而不是 `public`：这些接口带 `Vary: Origin` 语义且响应随部署环境变化，
 * 标 `private` 只允许**客户端私有缓存**（浏览器/App 自己的 HTTP 缓存）复用，
 * 不允许 CDN/中间代理缓存，避免隧道或未来接入的网关把数据缓存后串给别的用户。
 * `stale-while-revalidate` 让客户端在过期后可以先用旧值渲染、后台再校验（与客户端 SWR 同思路）。
 *
 * ETag 由 Express 默认生成（实测 `/public/products` 已返回 `W/"..."`），此处不重复设置；
 * 代理转发时若响应头已有 `Cache-Control`（下游自己声明过），这里不覆盖。
 */
@Injectable()
export class PublicCacheInterceptor implements NestInterceptor {
  /**
   * 进程内微缓存（**static**：管理端写入侧要能主动失效，见 [invalidate]）
   *
   * 2026-10-05（分部「建设中」需求）：原实现是实例字段 + 只在 main.ts `new` 一次，
   * 管理端改完分部后没有任何代码能清它 —— 于是「切成建设中/改招人文案」要等最长 30s 才对客户端生效。
   * 改成 static 后由 [invalidate] 提供失效入口，语义与原 `/public/players` 的修正一致：
   * **内容随管理端配置实时变化的数据，写入时必须配失效钩子**。
   */
  private static readonly store = new Map<string, { at: number; body: unknown }>();

  /** 进程内微缓存 TTL：30 秒 */
  private static readonly TTL_MS = 30_000;

  /**
   * 参与微缓存的路径前缀（仅公开字典类）
   *
   * 【2026-10-04】补上 `/public/leaderboard`、`/public/announcements`、`/public/about`、
   * `/public/privacy`、`/divisions/grouped`（原 `/api/v1/divisions` 前缀已覆盖）、
   * `/public/site`：这些同样是"人人一样、短时间不变"的只读数据，但此前**漏在缓存外**，
   * 每次进排行榜页 / 官网内容页都要真查一次库。
   *（同批补入的 `/public/players` 后来被移出，原因见下。）
   *
   * 【2026-10-04 夜间修正：`/public/players` 移出微缓存】
   * 实测（撤销打手某分部接单权限后 0.02s 内请求同一 URL）：名单仍返回撤销前的人，
   * 30 秒 TTL 内一律是旧值 —— 即"管理端改完权限，老板端名单晚 ≤30s 才变"。
   * 根因**不是缓存键少带了 `divisionId`**：键就是 `req.url`（本身含完整 query），
   * 撤销后请求一个没缓存过的键（`...&_probe=1`）**立刻**返回空名单，
   * 证明按分部的权限判定本来就是实时查库的；
   * 真正缺的是**失效机制** —— `worker_division_permission` 写入时没有任何代码清这里的条目，
   * 所以"权限已变、缓存仍旧"这个窗口必然存在。
   *
   * 判定：它不是"人人一样、短时间不变"的字典数据，内容**随授权状态变化**且必须立刻可见
   * （CLAUDE.md 结构规则 10：接单权限按分部实时查库、管理端改完下一次请求即生效），
   * 与 `/public/products` 那种"销量变了晚 30 秒无所谓"的列表语义不同，故整条移出微缓存。
   * 代价可控：该接口只在打开找陪玩页 / 指定护航员弹层时被调，低并发，实测单次 2~5ms。
   * 将来若确实要为它加缓存，必须配"权限写入即失效"的钩子，不能只调 TTL。
   */
  private static readonly PREFIXES = [
    '/api/v1/divisions',
    '/api/v1/public/clubs',
    '/api/v1/public/order-form',
    '/api/v1/public/games',
    '/api/v1/public/categories',
    /**
     * ⚠️ **2026-10-16：`/api/v1/public/home` 已移出微缓存（本条是那次改动的落点）**
     *
     * 该接口从"只剩公告"升级成**首屏聚合**（banners / divisions / hotProducts / players /
     * leaderboard / announcements，一次给全）后，它内嵌了两类**必须下一次请求即生效**的数据：
     * - **陪玩名单**（随授权状态变化）：撤销某分部接单权限后，名单必须立刻变 ——
     *   与 2026-10-04 `/public/players` 被移出的**同一个理由、同一把尺子**（见下方那段长注释）；
     * - **打手数值**（接单次数/好评率）：好评率实时算、展示值由管理端刚设定，
     *   与 `/public/workers*` 的 `no-store` 判定同源。
     *
     * 代价评估（为什么不担心）：本接口的服务端成本是"6 条并行子查询"（各自 2–21ms），
     * 而这条链路的真正成本是跨境 **RTT ≈ 245ms** —— 用"省几毫秒 SQL"换"最长 30 秒的错数据"
     * 是彻底的反向优化。客户端侧仍有自己的 SWR（`api_cache.dart` 60s 档）负责同一次前台会话内不重复问。
     * 写入侧本就不依赖这里的失效钩子（各子块自己的 service 在写入时会清各自前缀的缓存）。
     */
    '/api/v1/public/levels',
    '/api/v1/public/products',
    '/api/v1/public/leaderboard',
    '/api/v1/public/announcements',
    // 宣传图轮播（2026-10-05 任务②）：字典类只读、个位数行数、首页首屏就要渲染。
    // 缓存本身安全（有 TTL 兜底），但**必须配写入侧失效**：管理端上下架/改时间区间要即时生效，
    // 见 `HomeService.invalidatePublicBannerCache()`（在 create/update/delete 三处调用）。
    '/api/v1/public/banners',
    // 购买提示小字（2026-10-05 负责人：选择服务页「下单均使用余额（元）…」）：
    // 只有 1 行配置、单次主键读（约 2ms），但**就挂在商品列表页的首屏路径上**，
    // 微缓存的意义正是"首屏那一跳不再多一次真实查询"。
    // 同样必须配写入侧失效：管理端改联系人/比例后下一次请求即生效，
    // 见 `PurchaseHintAdminController.save()` 里的 `PublicCacheInterceptor.invalidate`。
    '/api/v1/public/purchase-hint',
    // 充值配置（2026-10-06 负责人：老板端「充值」= 线下扫码 + 上传截图 + 人工审核）：
    // 金额档位/换算比例/收款码列表，就挂在充值页首屏路径上。内容随**运营**变化
    // （改档位、换收款码、停用某张码），因此与购买提示同档；
    // **必须配写入侧失效**：`RechargeService.invalidatePublicConfigCache()` 在
    // 收款码增删改与配置保存四处全部调用 → 运营改完下一次请求即生效。
    '/api/v1/public/recharge/config',
    '/api/v1/public/about',
    '/api/v1/public/privacy',
    '/api/v1/public/site',
  ];

  /**
   * 各前缀的 `Cache-Control` 值。
   *
   * 分档理由（"多久不变"决定 max-age）：
   * - **字典档 600s**（目前仅 `/public/announcements`）：真正"半年不动"的字典数据。
   *   ⚠️ 2026-10-08 起，**运营可改的配置类数据全部移出本档**（见下方运营档）。
   * - **运营档 60s**（分部/官方馆/游戏/分类/等级/下单表单/官网内容/关于/隐私/商品/排行榜/首页/公告列表…）：
   *   **管理端改完，客户端 1 分钟内必须可见**。为什么是 60 而不是字典档 600：
   *   客户端 1.11.32 起把"运营数据"统一降到 **60s 档**（`apps/packages/core/lib/src/api/api_cache.dart`
   *   的 `ttlOps = 60s`：`/divisions`、`/public/clubs`、`/public/levels`、`/public/order-form`、
   *   `/public/games`、`/public/categories`、`/public/home`、`/public/site`、`/public/about`、`/public/privacy`…），
   *   **响应头的 `max-age` 绝不能比客户端自己的 TTL 更长** —— 否则"客户端以为该刷新了、
   *   响应头却告诉中间层还能再用 10 分钟"，将来接任何带 HTTP 缓存的客户端都会原地复现
   *   「管理端改完、App 还看到旧数据」。故这里与客户端逐档对齐：**同为 60s**。
   *   进程内微缓存 TTL 仍是 30s（比 60s 更短，方向安全）；`stale-while-revalidate=300`
   *   让客户端先渲染旧的、后台再校验，用户侧等价于秒开。
   * - **不缓存档**（`no-store`，目前仅 `/public/players`）：内容随**授权状态**变化，
   *   必须"改完下一次请求即生效"，详见 PREFIXES 上方的说明。
   */
  private static readonly CACHE_CONTROL: Array<{ prefix: string; value: string }> = [
    // `/public/players` 已移出进程内微缓存，这里也**不能**让它落到下面的"字典档 600s"默认值
    // （那会比原先的 60s 更不新鲜，是反向优化）。名单随授权状态变化，显式声明不可缓存：
    // 配上客户端已有的 forceRefresh，保证"管理端改完权限，下一次请求就是新的"。
    { prefix: '/api/v1/public/players', value: 'no-store' },
    /**
     * 打手公开信息（负责人 2026-10-15）：`GET /public/workers/:id`（接单次数 + **实时算的**好评率 +
     * 最近评价）与 `GET /public/workers/:id/reviews`（评价分页）。
     *
     * 与 `/public/players` **同一档、同一理由**，甚至更硬：
     * - 好评率/评价条数是**从 `order_review` 现算的**（刻意不在 `worker_stats` 加冗余列 —— 加列
     *   就等于第二条真相），若再被 30s 进程内微缓存挡住，等于"实时算完再给你看旧的"；
     * - 评价是**老板刚提交就要能看见**的东西（提交成功 → 打手页刷新 → 数字变了），
     *   与"分部下架要立刻生效"属于同一类"随写入实时变化、必须下一次请求即生效"的语义。
     *
     * 因此：**不进 `PREFIXES` 微缓存**，且在这里显式登记 `no-store`
     * （按本文件既有约定：新增公开前缀必须显式登记，不许依赖兜底的 600s 字典档）。
     */
    { prefix: '/api/v1/public/workers', value: 'no-store' },
    /**
     * 首屏聚合 `GET /public/home`（2026-10-16 改造为"一次给全首屏"）—— 与上一条**同档 `no-store`**。
     *
     * 理由（与 `PREFIXES` 里移除它时写的那段是同一条，两处必须配套改）：
     * 它内嵌 `players`（随授权状态**实时**变化：撤销分部接单权限必须下一次请求即生效，
     * CLAUDE.md 结构规则 10）与打手数值（好评率现算 + 管理端刚设的展示值）。
     * 若留在下面的"运营档 60s"，就会出现「管理端设了展示值/撤了权限，而首页仍是旧值」——
     * 而首页首屏正是最显眼的位置，错值会被最多人看到。
     */
    { prefix: '/api/v1/public/home', value: 'no-store' },
    { prefix: '/api/v1/public/products', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/leaderboard', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/announcements', value: 'private, max-age=60, stale-while-revalidate=300' },
    // 宣传图与公告同档：内容会随运营变化（活动上下架/时间区间），60s + 后台校验比字典档 600s 合适
    { prefix: '/api/v1/public/banners', value: 'private, max-age=60, stale-while-revalidate=300' },
    // 购买提示与公告同档：内容随**运营**变化（充值联系人、到账比例），不是"半年不动"的字典数据。
    // 进程内 30s + 客户端 60s 都对得上"改完很快生效"，同时保留 SWR 让列表页秒开。
    { prefix: '/api/v1/public/purchase-hint', value: 'private, max-age=60, stale-while-revalidate=300' },
    // 充值配置与购买提示同档：档位/收款码随运营变化（活动一改就要立刻可见），不是字典数据。
    // 进程内 30s + 客户端 60s 都对得上"改完很快生效"，同时保留 SWR 让充值页秒开。
    { prefix: '/api/v1/public/recharge/config', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/site', value: 'private, max-age=60, stale-while-revalidate=300' },
    /**
     * 【2026-10-08 口径统一】以下六条此前**没有单独登记** → 落到 `DEFAULT_CACHE_CONTROL`
     * （字典档 `max-age=600`），而客户端 1.11.32 已把它们全部归入**运营档 60s**：
     * **响应头比客户端 TTL 长 10 倍**，正是"管理端改完、App 还看到旧数据"的同一类口径错位
     * （客户端 Flutter/Dio 目前没有 HTTP 缓存层，所以对 App 暂时无效，但只要将来接了带
     * HTTP 缓存的客户端就会复现）。这里逐条与客户端 `ttlOps` 对齐为 60s。
     *
     * 覆盖：官方馆（`/public/clubs`）、游戏与分类（`/public/games`、`/public/categories`，
     * 含 `/public/games/:code/config`）、等级规则（`/public/levels`）、下单表单
     * （`/public/order-form`）、关于/隐私（`home_module` 驱动的公开文案）、官网（`/public/site`）。
     * **写入侧失效钩子**同步补齐（见 club/home/site/game/system-setting 各模块）。
     */
    { prefix: '/api/v1/public/clubs', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/games', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/categories', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/levels', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/order-form', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/about', value: 'private, max-age=60, stale-while-revalidate=300' },
    { prefix: '/api/v1/public/privacy', value: 'private, max-age=60, stale-while-revalidate=300' },
    // 分部（`/divisions`、`/divisions/grouped`）：客户端同为 60s 运营档；
    // 写入侧失效钩子已在 `division.controller.ts` 的三个写路径（新增/编辑/删除）里。
    { prefix: '/api/v1/divisions', value: 'private, max-age=60, stale-while-revalidate=300' },
  ];

  /**
   * 兜底缓存头（`CACHE_CONTROL` 表里没登记、但命中 `PREFIXES` 的新前缀走这里）
   *
   * 【2026-10-08 口径统一后】现有前缀**全部**已在上表显式登记（`/public/announcements`
   * 是最后一个字典档 600s 的持有者，与客户端 `ttlDict = 10 分钟` 对齐）。
   * 这里保留 600s 只是**兜底**：**新增公开前缀时必须在上表显式登记**
   * —— 别再依赖兜底，否则新前缀的响应头会默认比客户端 TTL 长。
   */
  private static readonly DEFAULT_CACHE_CONTROL = 'private, max-age=600, stale-while-revalidate=600';

  private static cacheControlFor(url: string): string {
    for (const e of PublicCacheInterceptor.CACHE_CONTROL) {
      if (url.startsWith(e.prefix)) return e.value;
    }
    return PublicCacheInterceptor.DEFAULT_CACHE_CONTROL;
  }

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const req = context
      .switchToHttp()
      .getRequest<{ method: string; url: string; headers: Record<string, string> }>();
    if (req.method !== 'GET') return next.handle();

    const matched = PublicCacheInterceptor.PREFIXES.find(
      (p) => req.url.startsWith(p) || req.url.split('?')[0] === p,
    );

    /**
     * 【2026-10-04 夜间修正】响应头必须**先于** `matched` 判定下发。
     *
     * 原实现把"设 Cache-Control"放在 `if (!matched) return` **之后** —— 这对"只有进了微缓存
     * 前缀才有资格谈缓存头"的旧语义是对的，但 `/public/players` 移出 PREFIXES 后就会
     * **两头落空**：既不进微缓存，也拿不到 `no-store`，响应变成完全没有 Cache-Control
     * （实测确认过：HTTP 200 且无该头），比修复前更糟 —— 客户端/中间层可以按启发式
     * 自行缓存。所以这里拆成两段：**头按 CACHE_CONTROL 表全量下发**，
     * **进程内微缓存仍严格按 PREFIXES 判定**。
     *
     * 缓存响应头对**匿名与带鉴权**的公开 GET 都安全：这些都是"公开只读"数据，
     * 标成 private/no-store 只影响客户端自己的 HTTP 缓存，不涉及越权
     * （受保护数据不走这些前缀，仍完全不设头）。
     */
    const scope = PublicCacheInterceptor.CACHE_CONTROL.find((e) => req.url.startsWith(e.prefix));
    const inScope = !!matched || !!scope;
    if (inScope) {
      const setCacheHeader = context.switchToHttp().getResponse<{
        setHeader?: (k: string, v: string) => void;
        getHeader?: (k: string) => unknown;
      }>();
      if (typeof setCacheHeader?.setHeader === 'function') {
        const existing =
          typeof setCacheHeader.getHeader === 'function' ? setCacheHeader.getHeader('Cache-Control') : undefined;
        if (!existing) setCacheHeader.setHeader('Cache-Control', PublicCacheInterceptor.cacheControlFor(req.url));
      }
    }

    // 不在微缓存前缀里 → 到此为止：不查缓存、也不写缓存（响应头上面已经发过了）
    if (!matched) return next.handle();

    if (req.headers['authorization']) return next.handle(); // 带鉴权不进进程内缓存（避免按前缀串味）

    const key = req.url;
    const hit = PublicCacheInterceptor.store.get(key);
    if (hit && Date.now() - hit.at < PublicCacheInterceptor.TTL_MS) {
      return of(hit.body);
    }
    return next.handle().pipe(
      tap((body) => {
        PublicCacheInterceptor.store.set(key, { at: Date.now(), body });
        // 简单容量控制：超过 500 条清最早一半
        if (PublicCacheInterceptor.store.size > 500) {
          const keys = [...PublicCacheInterceptor.store.keys()].slice(0, 250);
          for (const k of keys) PublicCacheInterceptor.store.delete(k);
        }
      }),
    );
  }

  /**
   * 主动失效：清掉所有以 [prefix] 开头的微缓存条目（返回清掉的条数，便于调用方日志/断言）
   *
   * 使用场景（负责人 2026-10-05 分部「建设中」需求）：
   * 管理端改分部（建设中开关 / 招人文案 / 名称）后**必须立刻**对公开接口生效，
   * 不能等 30s TTL —— 判定口径与 `/public/players` 那次修正完全一致：
   * 内容随管理端写入变化的数据，要么不缓存，要么配失效钩子（这里选后者，保住字典接口的命中率）。
   *
   * 注意：微缓存是**进程内**的（多实例部署时每个实例各持一份），
   * 当前 fish-server 为 pm2 单实例 fork 模式，因此本进程内失效即全局生效。
   */
  static invalidate(prefix: string): number {
    let removed = 0;
    for (const k of [...PublicCacheInterceptor.store.keys()]) {
      if (k.startsWith(prefix)) {
        PublicCacheInterceptor.store.delete(k);
        removed++;
      }
    }
    return removed;
  }
}
