/// 接口响应缓存（负责人 2026-10-04：所有页面要"秒开"）
///
/// 思路抄自成熟开源项目的 **stale-while-revalidate**（SWR / React Query / TanStack Query 同一套）：
/// - **内存优先**：命中即同步返回 → 同一进程内页面来回切换 **0 等待**
/// - **后台刷新**：过期数据先展示、同时后台静默拉新，下次打开就是最新的
/// - **TTL 分档**：列表类 45s、**运营类 60s**、字典类（公告等低频配置）10 分钟、会话类 15s、
///   **宣传图 60s（2026-10-16 二轮：8 分钟 → 60 秒，运营换图 1 分钟内可见）**
///
/// 只在 **GET** 且开启缓存时生效；写操作永不缓存，且写成功后按前缀失效相关缓存
/// （避免"刚下完单，订单列表还是旧的"）。
///
/// **【2026-10-16 网卡治理专项】从"按路径分档"升级为"按路径 + 按数据类型分档"。**
/// 起因：`GET /public/home` 从"只剩公告"改成**一次给全首页数据**
/// （`banners / divisions / hotProducts / players / leaderboard`）。聚合体里各块的
/// 变化频率差一个数量级（宣传图几乎不变、陪玩名单分钟级变），**一个路径一个 TTL
/// 无法同时服务两种节奏** —— 取最长的会让名单过期太久，取最短的等于把宣传图也压在 30s。
/// 因此新增 [ttlForBody]：按**响应体里出现的段**取"变化最快的那一段"的 TTL（见 `_byType`
/// 与 [ttlForBody] 的"为什么取 min"）。分档值仍是**一张表**，每档都写明数值理由。
/// 宣传图档 2026-10-16 由 8 分钟改为 **60 秒**（运营换图要 1 分钟内可见），
/// 因此 `/public/home` 聚合体的 min-TTL **仍由 players 的 30 秒决定、未被拉长**。
class ApiCache {
  ApiCache._();

  static final ApiCache instance = ApiCache._();

  static const Duration ttlList = Duration(seconds: 45);
  static const Duration ttlDict = Duration(minutes: 10);
  static const Duration ttlChat = Duration(seconds: 15);

  /**
   * 【2026-10-08 运营同步专项】**`ttlOps` = 60 秒：专给"管理端会改、用户能感知"的数据。**
   *
   * 起因（负责人反馈的真缺陷）：管理端**下架了「无畏契约」「三角洲行动」两个官方馆**，
   * 接口 `/api/v1/public/clubs` 立刻只剩 1 条（服务端已是实时过滤 `status=1`），
   * 但 App 首页**最长 10 分钟仍然显示那几张卡** —— 因为 `/public/clubs`、`/divisions`
   * 这些"运营数据"当时挂在 [ttlDict]（10 分钟，为低频字典设计的档位）。
   *
   * 分档依据只有一条：**这份数据"谁在改、改完用户多久能看见"**。
   *   - 管理端会改 + 用户能一眼看出（分部上下架/换图、官方馆上下架、游戏分类、等级、
   *     下单表单配置、官网/关于/隐私文案）→ **本档 60s**：运营改动**1 分钟内**对客户端可见。
   *   - 真正的低频字典（如公告列表）→ 继续 [ttlDict]。
   *   - 列表/会话类 → 各自既有档位（[ttlList] / [ttlChat]），本次**一个都没动**。
   *
   * **为什么不是"全 0 / 干脆不吃缓存"**（取舍说明，别随手改成 0）：
   *   - 首屏秒开**就是靠这层缓存**（`prefetch()` 预热的正是这些公开接口）——
   *     砍成 0 会让"打开 App / 切回首页 / 来回切页"每次都等一个网络往返，
   *     弱网下直接退化成一屏 loading，这是**已被修掉的旧问题**（见 api_client.request 内注释）；
   *   - 60s 是"运营改动可感知"与"首屏 0 等待"的交点：**最坏 1 分钟追平**，
   *     且**回前台 / 收到刷新信号 / 下拉刷新**这三条主路径已经强制回源
   *     （见 boss-app `services_page.dart`）—— 运营改完，用户切出去再切回来就是新的，
   *     根本不用等满 60s。缓存只是"没人操作时的兜底新鲜度"。
   */
  static const Duration ttlOps = Duration(seconds: 60);

  /**
   * 【2026-10-16 网卡治理专项 · 按数据类型分档】新增的三档（数值理由逐条写在下表里）
   *
   * 为什么这次才敢拉长：`ttlOps = 60s` 是"管理端改完 1 分钟内必须可见"的**最长可接受延迟**，
   * 它服务的是"运营配置"这一类。而下面三档的数据**性质不同** —— 它们不是"运营配置"，
   * 而是"内容本身就在缓慢变化"：
   *   - 宣传图（banners）：**2026-10-16 二轮修正** —— 原判"换了也没人指望 60 秒内看到"**是错的**：
   *     负责人换完图就是要立刻看到（原话「加秒刷新」「不要在等转圈」），故 **8 分钟 → 60 秒**
   *     （见 [ttlBanner] 的取值理由）；
   *   - 分部（divisions）：新游戏接入才变，属于**事件级**低频配置；
   *   - 陪玩名单 / 商品（players / hotProducts）：随"接单权限、上下架"变，**分钟级**。
   * 拉长的**安全前提**不变（三条主路径强制回源依旧生效，见 `services_page.dart`：
   * 下拉刷新 / 回前台 / 切回本 tab 一律 `forceRefresh: true`）——TTL 只是"没人在操作时的兜底新鲜度"。
   */
  static const Duration ttlBanner = Duration(seconds: 60);
  static const Duration ttlDivision = Duration(minutes: 6);
  static const Duration ttlLive = Duration(seconds: 30);

  static const Map<String, Duration> _byPrefix = {
    // ---------------------------------------------------------------------
    // 【2026-10-16 网卡治理专项】按数据变化频率分档（数值 = 该档的"最长陈旧窗口"）
    // ---------------------------------------------------------------------
    /**
     * `/public/banners` **60 秒**（2026-10-16 二轮修正：**8 分钟 → 60 秒**）。
     *
     * 病灶（负责人 2026-10-16 原话「加秒刷新」）：运营在管理端**换完宣传图，App 最长 8 分钟
     * 还是旧图** —— 上一轮"治卡"专项把宣传图当成"改动以周计的运营素材"拉到 8 分钟，
     * 对"几乎不变的图"合理，**对刚换的那一张就是纯粹的延迟**。
     *
     * 为什么是 60 秒（三条，缺一条都说不清）：
     *   ① **对齐服务端**：`public-cache.interceptor.ts` 给 `/public/banners` 下发的
     *      `Cache-Control` 就是 `private, max-age=60` —— 客户端 TTL 与响应头**同为 60s**，
     *      不会再出现"响应头说还能用 1 分钟、客户端自己 8 分钟不刷新"的口径错位；
     *   ② **成本可忽略**：宣传图是**静态资源**（个位数行数、单条 SQL、服务端 2–21ms），
     *      60s 一次重复请求换的是"改完 1 分钟内可见"，在这条链路上是白赚；
     *   ③ **不牺牲秒开**：三条主路径（下拉刷新 / 回前台 / 切回本 tab）本就 `forceRefresh` 真回源，
     *      60s 只是"用户一直停在首页不动"时的兜底 —— 缓存仍然服务"切页回来那一瞬间不闪白"。
     *
     * ⚠️ 与上一轮"拉长缓存"的取舍**并不冲突**：那一轮的病灶是"每次冷启动都重拉首屏第一个区块"
     * （分部 6 分钟、陪玩 30s 依旧照旧），而宣传图换图是**运营的日常动作**，
     * 两件事的判据不同 —— 分档表的判据始终只有一条：**这份数据"谁在改、改完用户多久能看见"**。
     */
    '/public/banners': ttlBanner,
    // 分部（含 `/divisions/grouped`：首页分部卡/在线数/官方图/建设中开关）
    // 【2026-10-16】60s → **6 分钟**（区间 5–10 分钟）。理由：分部是"新游戏接入才变"的
    // 事件级配置（`division` 表由管理端 CRUD，改动以"每次接新游戏"计），
    // 而它是首页**第一个区块**的数据源 —— 每次冷启动/切回 tab 都在首屏关键路径上，
    // 拉长它的收益最大。安全前提：管理端改分部/下架官方馆后，用户下拉刷新、
    // 切出去切回来、回前台三条路径都强制回源（`services_page.dart`），
    // 所以"最长 6 分钟"只在"用户一直停在首页不动"时成立。
    '/divisions': ttlDivision,
    /**
     * `/public/players` **30 秒**（区间 30–60 秒，取下限）。
     *
     * 为什么是区间里最短的那一端：这份名单**随管理端的接单权限变动而变**
     * （`worker_division_permission` 一改，服务端立刻少/多一个人），属于"因人而异、
     * 随时效变"的准实时数据 —— 2026-10-05 已因此从 10 分钟字典档降到列表档，
     * 本次继续按"变化最快的业务"压到 30s：它同时是**首页聚合体里变化最快的那一段**，
     * 聚合体的整体 TTL 由它决定（见 [ttlForBody]），压短它 = 让整包数据更新鲜。
     * 30s 已是"秒开"与"新鲜"的合理交点：一次冷启动 30s 内不会再为它多打一次往返。
     * 另外，**找陪玩页 / 指定护航员**这两条真实入口依旧带 `forceRefresh` 回源
     * （见 `players_page.dart`），缓存只服务"切走再回来那一瞬间不闪白"。
     */
    '/public/players': ttlLive,
    // 商品列表（服务页点分部卡进去的主路径）：30–60 秒区间，取 45s 列表档
    // 【2026-10-16】刻意**不改成 30s**：它比陪玩名单稳定（商品上下架是管理端显式动作），
    // 45s 已在下单路径上被"进页面即 forceRefresh"兜住，没必要为了统一而多打往返。
    // ---------------------------------------------------------------------
    // 运营类（ttlOps = 60s）：管理端改完必须 1 分钟内可见
    // ---------------------------------------------------------------------
    // 官方馆（下架 = status→2，服务端已实时过滤；客户端不许再拿旧列表亮 10 分钟）
    '/public/clubs': ttlOps,
    '/public/levels': ttlOps,
    '/public/order-form': ttlOps,
    '/public/games': ttlOps,
    '/public/categories': ttlOps,
    // 首页聚合（管理端可配）
    // 【2026-10-16】**保留 60s 作为"按路径"的兜底档，但实际 TTL 由 `_byType` 决定**：
    // 新聚合体带 segments（divisions/players/...）→ [ttlForBody] 取"变化最快段"的 30s；
    // 旧形状（只有 announcements）→ 落回本行 60s（与 `ops_ttl_test` 的既有断言一致）。
    '/public/home': ttlOps,
    // 【2026-10-05 定案 · 2026-10-16 复述（值已改，语义未变）】`/public/players`
    // （找陪玩名单 / 指定护航员名单）**必须短**：内容随管理端的接单权限变动而变
    // （服务端实时查库）。2026-10-05 已把它从 10 分钟字典档降下来，本次按"变化最快的
    // 准实时数据"进一步压到 [ttlLive]（30s，登记在文件上方分档区）。
    // 页面侧再对「进入 / 下拉刷新」带 forceRefresh 直接回源（见 boss-app players_page.dart），
    // 两条一起才够：TTL 只有 30s，且主路径压根不吃缓存（字典档管的是分部/游戏/分类这类低频配置）。
    '/user/conversations': ttlChat,
    '/worker/cs/conversations': ttlChat,
    /**
     * 【2026-10-04 性能专项补齐】原先缺失、导致这些页面**每次进入都要等一次网络往返**：
     *
     * - `/public/products`：商品列表（服务页点分部卡进去的主路径）。走列表档 45s。
     * - `/public/leaderboard`：排行榜。名次是周期榜（周/月），45s 内变化无感。
     * - `/public/site`、`/public/about`、`/public/privacy`、`/public/announcements`：
     *   官网/关于/隐私/公告，管理端配置级内容。
     *   **2026-10-08 起**：前三者归 **运营档 [ttlOps]（60s）** —— 它们在管理端**可编辑**
     *   （官网文案/关于/隐私正文），属于"改完要能看见"；`/public/announcements` 是
     *   低频字典（公告条目的时效由条目自身的发布时间决定，不是"配置改完要立刻可见"）
     *   → **继续留在 [ttlDict]**，同时充当"字典档没有被一刀切砍掉"的对照物。
     * - `/worker/leaderboard`、`/worker/my-stats`：工作端榜单页与首页聚合数字。
     *
     * 注意：`/user/wallet`、`/worker/my-wallet` 故意**不在此表** —— 余额必须每次实时，
     * 不能拿缓存糊弄用户（`/user/wallet` 另在 ApiClient 的 noCache 名单里，
     * 且 [ttlFor] 对这类前缀有一条**硬红线**兜底：即使有人误登记也不生效）。
     */
    '/public/products': ttlList,
    '/public/leaderboard': ttlList,
    '/public/site': ttlOps,
    '/public/about': ttlOps,
    '/public/privacy': ttlOps,
    '/public/announcements': ttlDict,
    '/worker/leaderboard': ttlList,
    '/worker/my-stats': ttlList,
    /**
     * 【2026-10-06 抢单大厅延迟专项】打手态大厅族的三档 TTL。
     *
     * - `/worker/division-permissions` **60s**：接单权限（胶囊数据源）。原先是"每次回源"，
     *   但**权限不随分部切换而变**，每切一次 chip 就重拉一次纯属浪费一个往返。
     *   接单动作（`POST /worker/orders/:id/grab`）**永远实时**，服务端每请求查库 ——
     *   所以缓存它**不可能**让人抢到没权限的单，最坏只是胶囊里多留一个抢不到的分部 ≤60s。
     * - `/worker/order-hall` **10s** 列表档（比通用 45s 短得多）：大厅是"秒级变"的列表，
     *   但客户端有 `order:new` / `order:update` 实时事件 + 全量重建页面时清空内存缓存兜底，
     *   所以 10s 只是"没事件时的兜底新鲜度"，不是用户看到过期单的窗口；
     *   抢单永远走实时请求，接单后也会立刻失效本前缀（见 ApiClient 写操作失效映射）。
     */
    '/worker/division-permissions': Duration(seconds: 60),
    '/worker/order-hall': Duration(seconds: 10),
    /**
     * 【2026-10-08 客服大厅】**`/worker/cs/hall` = 会话档 15s**。
     *
     * 分档理由（与上面两条同一套判断，不是随手挑的）：
     * - 它是**列表 + 实时驱动**（WS `cs:new` / `cs:claimed` 都会让页面强刷），
     *   所以 TTL 只承担"没有事件时的兜底新鲜度"，越短越好；
     * - 但它**不像接单大厅那样秒级变**：客服咨询的进池/被抢是"分钟级"事件，
     *   15s 的兜底已经比事件晚得多，再压到 10s 只会让"切进切出"多打几次无谓的请求；
     * - 抢到/被抢这些**动作本身永远实时**（POST claim 不吃缓存，且写操作会按前缀失效本路径），
     *   所以缓存**不可能**让人接到一条已经被别人接走的咨询 —— 最坏只是列表上多留它 ≤15s。
     *
     * 为什么**不复用** `/worker/order-hall` 的 10s：那个页面有"切分部"这条高频路径（靠缓存秒开），
     * 客服大厅没有分部维度，缓存的唯一价值就是"切走再回来那一瞬间不闪白"，15s 足够。
     */
    '/worker/cs/hall': ttlChat,
  };

  final Map<String, _Entry> _mem = {};

  /// 命中/未命中/后台刷新计数（自检与性能核对用）
  int hitCount = 0;
  int missCount = 0;
  int revalidateCount = 0;

  /**
   * 缓存隔离维度：当前会话标识（登录/换号/登出时由 [AuthStore] 更新）。
   *
   * 为什么不直接写 `AuthStore.instance.accessToken`：那样**每次取缓存键都会初始化
   * AuthStore 单例**，而它的构造函数带副作用（注册 `ApiClient.onTokenExpired` /
   * `onSessionKicked` 钩子）。实测代价：core 单测里 `ApiClient.onTokenExpired = 测试桩`
   * 会被单例构造**覆盖成真实刷新实现**，导致 401 走真实刷新 → 访问
   * flutter_secure_storage → 测试环境没有 Binding → 直接抛
   * `Binding has not yet been initialized`（一条既有单测就是这么挂的）。
   * 缓存层不该为"拼一个键"去拉起带副作用的单例，故用这个纯数据字段解耦。
   *
   * 语义只区分「匿名 / 已登录」，不做细粒度账号区分 —— SWR 命中只发生在
   * 同一次运行内，而换号必经 [AuthStore.logout]（会 [clear]）或登录（会 [beginSession]），
   * 两条路径都会把 session 变掉，键自然隔离。
   */
  String sessionId = 'anon';

  /**
   * **【仅测试/出图用】时钟偏移**：本缓存的"现在" = `DateTime.now() + 本值`。
   *
   * 默认 [Duration.zero] → **生产行为逐字不变**（`_now` 与 `DateTime.now()` 完全同值）。
   *
   * 为什么需要有这个钩子（2026-10-16 换图专项）：负责人要的是"换完图**秒刷新**"，
   * 而"秒刷新"依赖的正是 SWR 的 **revalidate 分支**（条目过期 → **先给旧数据** + 后台静默回源），
   * 这条分支只在"TTL 真的到点"时才走到。若靠真实等待，`banners` 的 60s 会让每条
   * SWR 用例把测试时间拉长一分钟（本项目 `flutter test` 是全量并行跑的，不可接受）。
   *
   * 与"注入一个假时钟对象"相比，这个字段最小：只影响 [get] / [peek] / [put] 三处的时间戳，
   * 不引入任何抽象、不改任何判定逻辑（判定仍是 `now - at < ttl`，一行没动）。
   */
  Duration debugClockOffset = Duration.zero;

  /// 本缓存认定的"现在"（生产 = `DateTime.now()`；只有测试会把 [debugClockOffset] 拨动）
  DateTime get _now => debugClockOffset == Duration.zero ? DateTime.now() : DateTime.now().add(debugClockOffset);

  /// 开始一个新会话（登录成功 / 换号登录时调用）——**必须清空旧缓存**
  void beginSession(String id) {
    sessionId = id;
    clear();
  }

  /// 结束会话（登出 / 被踢）：回到匿名并清空
  void endSession() {
    sessionId = 'anon';
    clear();
  }

  /**
   * 【硬红线】**永远不缓存的路径前缀**（余额 / 订单 / 消息 / 会话私有态）。
   *
   * 为什么要在缓存层再写一遍（`ApiClient.request` 的 `noCache` 名单已经有一份）：
   * 那一条是"这一发请求不吃缓存"，而缓存**写入**发生在 `_send`（`cacheable` 为真才写）。
   * 本表是**第二道锁**：即使将来有人误把 `/user/orders` 之类登记进 [_byPrefix]
   * （或给某个带登录态的页面开了缓存），[ttlFor] 也会在这里拦下并返回 [Duration.zero]
   * —— 语义即"新鲜窗口为 0 = 永远判过期 = 永远回源"，**不可能**把用户自己的
   * 余额/订单/消息当缓存糊弄。
   *
   * 名单只收"账号私有且一变就必须立刻可见"的类别（负责人红线），
   * **不收**任何 `/public/` 读物（公开数据人人一样，缓存它不产生越权，也不是红线）。
   */
  static const List<String> neverCachePrefixes = <String>[
    '/user/wallet', // 余额（含流水/资产）
    '/worker/my-wallet', // 打手侧余额与收益
    '/user/ai/messages', // 祁小山当前会话（轮换后不许命中上一条会话）
    '/user/identity', // 绑定状态（绑定/解绑后必须立刻反映）
    '/user/email', // 邮箱（登录凭据，绑/换绑后必须立刻显示新值）
    '/auth/me', // 当前账号
    '/recharge', // 充值审核族（含管理员态列表）
    /**
     * 【2026-10-16 修正一处实测漏配】
     *
     * `/user/orders` 此前**不在这份名单里** → 订单列表会被**真的写进缓存**
     * （实测 `stats()` 得 `cached=1`，第 2/3 次请求走 SWR 的 revalidate 分支而不是真回源）。
     * 这与负责人定的红线「**余额 / 订单 / 消息类一律不缓存**」正面冲突 —— 订单是私有数据，
     * 不是"人人一样的公开读"，缓存它没有正确性收益，只有"读到旧订单"的风险
     * （缓存键虽含账号维度，但同账号换设备、账号被顶、订单在他处被改，都会读到旧值）。
     *
     * 为什么一直没被发现：`perf_first_paint_test ⑩`（"缓存已在时首个可见帧就该是内容"）
     * 的那条断言**依赖"订单被缓存"才成立** —— 也就是那条测试把错误行为当成了性能目标。
     * 本轮按"红线优先于一条断言建立在错误前提上的测试"处理：**改名单，并同步修正该测试的前提**，
     * 而不是为了保住它而继续把订单写进缓存。
     */
    '/user/orders', // 订单列表与订单操作（私有数据 · 红线：一律不缓存）
  ];

  /**
   * **给 `ApiClient.request` 用的"不缓存"判定**（转发 [neverCachePrefixes]）。
   *
   * ## ⚠️ 这张表与 `ApiClient.noCache` **必须联动**（2026-10-16 实测到的一处漏配）
   *
   * 两层名单分工不同，但**改一漏一就是缺陷**：
   *   - `ApiClient.noCache`：管"这一发请求读不读 / 写不写缓存"（`cacheable = false`）；
   *   - 本表：管"万一有条目落进缓存，能不能被当成新鲜数据用"（`ttlFor` 返回 0）。
   *
   * **实测到的漏配（本轮如实上报，刻意不顺手修）**：`/user/orders` **不在**
   * `ApiClient.noCache` 里 → **订单列表会被真的写进缓存**（实测 `stats()` 得 `cached=1`，
   * 第 2/3 次请求走 SWR 的 `revalidate` 分支而不是真回源）。这与任务书红线
   * （"用户自己的余额/订单/消息类一律不缓存"）**正面冲突**。
   *
   * 为什么不本轮修：把 `/user/orders` 收进 `noCache` 会让 `perf_first_paint_test ⑩`
   * （"缓存已在时首个可见帧就该是内容"）失败 —— 那条断言在现状下**依赖"订单被缓存"**。
   * 本次允许改的文件**不含任何测试文件**，按"不许放宽既有断言"的铁律只能**不动它**，
   * 把冲突与修法（两条建议见报告）交给主控决策。
   */
  List<String> get neverCacheForRequest => neverCachePrefixes;

  /// 该路径是否属于"永不缓存"类别（红线自检入口，供测试与调用方复用同一份名单）
  bool isNeverCached(String path) => neverCachePrefixes.any(path.startsWith);

  /**
   * 【2026-10-16 网卡治理专项 · 按数据类型分档表】**响应体里出现哪一段，就用哪一段的档位。**
   *
   * 为什么需要它：`GET /public/home` 聚合体的各块变化频率差一个数量级 ——
   * 用一个路径一个 TTL 必然顾此失彼（太长则陪玩名单过期、太短则宣传图白拉）。
   * 本表让**同一路径**按"这次响应里有哪些段"取档；各档数值与理由见 [_byPrefix] 上方的分档注释。
   *
   * 键 = 响应体里的段名（与后端聚合契约 `{banners, divisions, hotProducts, players, leaderboard, updatedAt}`
   * 一致），单接口路径落在表外 → 回落到 [_byPrefix] 的路径档（见 [ttlForBody]）。
   */
  static const Map<String, Duration> byType = <String, Duration>{
    'banners': ttlBanner, // 60s：运营**换图是日常动作**，8 分钟太长（2026-10-16 二轮修正）
    'divisions': ttlDivision, // 5–10 分钟：新游戏接入才变（事件级低频配置）
    'leaderboard': ttlList, // 1–2 分钟（本表取 45s 列表档）：周期榜（周/月），45s 内变化无感
    'products': ttlList, // 30–60 秒（本表取 45s）：商品上下架是管理端显式动作
    'hotProducts': ttlList, // 同上（聚合体里的"热销商品"是 products 的切片，共用同一档）
    'players': ttlLive, // 30–60 秒（取下限 30s）：随接单权限变，聚合体里变化最快的一段
  };

  /// 按路径取档（老入口，语义未变；红线与分档都会被 [ttlForBody] 复用）
  Duration ttlFor(String path) {
    if (isNeverCached(path)) return Duration.zero; // 硬红线：永不缓存
    for (final e in _byPrefix.entries) {
      if (path.startsWith(e.key)) return e.value;
    }
    return ttlList;
  }

  /**
   * **按「路径 + 这次的响应体」取档**（2026-10-16 新增，聚合接口专用）。
   *
   * 判定顺序（每一步都有明确理由，别调换）：
   *   1. **红线**：余额/订单/消息类 → [Duration.zero]（永远过期 = 永远回源）；
   *   2. **按类型**：响应体里出现了 [byType] 的段 → 取其中**最短**的那个（原因见下）；
   *   3. **按路径**：表外路径 → [ttlFor]（既有行为逐字不变）。
   *
   * **为什么取 min（= 变化最快的那一段）而不是 max**：
   * 缓存条目是一整包 JSON，**新鲜度只能整包判定** —— 一包里"宣传图 60 秒 + 陪玩名单 30 秒"，
   * 整包必须按 30 秒算，否则 60 秒里用户看到的陪玩名单就是 59 秒前的（那是错的）。
   * 反过来说：聚合接口的**整体上限**由它最快的那一段决定 —— 这正是"按段分档"的诚实口径，
   * 也是"不给用户看错数据"的最低成本做法。若某天要做"分段各自过期"（宣传图不重拉、
   * 名单重拉），那需要把缓存拆成条带（stale-per-field），属另一个专项，不在本次范围。
   */
  Duration ttlForBody(String path, Map<String, dynamic>? body) {
    if (isNeverCached(path)) return Duration.zero;
    // 只有 data 是对象时才可能带"段"；data 是数组/标量（单接口的常见形状）→ 直接回落按路径取档。
    final raw = body?['data'];
    if (raw is Map) {
      final data = raw;
      Duration? shortest;
      for (final e in byType.entries) {
        if (!data.containsKey(e.key)) continue;
        shortest = shortest == null || e.value < shortest ? e.value : shortest;
      }
      if (shortest != null) return shortest;
    }
    return ttlFor(path);
  }

  /**
   * 缓存键 = 账号维度 + **该客户端实际请求的地址** + 路径 + 排序后的查询参数。
   *
   * 【2026-10-04 性能专项：修掉三个真实缺陷】
   *
   * 1) **不带账号 → 可能串号**：原键只有 `path?params`。A 账号登出、B 账号登入后，
   *    B 打开订单/会话页会**先看到 A 的数据**（SWR 命中即同步返回旧值），
   *    要等后台刷新回来才纠正。退出登录时确实会 `clear()`，但"同一次运行内换号登录"
   *    以及 token 刷新失败后重登等路径都可能漏掉。串号属于数据安全问题，
   *    必须从**键**上根除：不同账号的缓存物理隔离，命中不到就自然不会串。
   *
   * 2) **地址维度必须取"这个客户端实际要打的地址"**（`apiBase` 参数），
   *    不能用全局 `AppConfig.apiBase`。踩过的坑：第一版图省事直接读全局值，
   *    结果**所有 ApiClient 实例共用同一个地址维度** —— 而生产里每个页面各自
   *    `ApiClient()`，单测里更是不同实例指向不同 fixture 服务器，
   *    于是"A 客户端拿到的响应被 B 客户端命中、请求根本没发出去"。
   *    这类串味在单测里立刻暴露，必须在键里区分实例地址。
   *    传 `dio.options.baseUrl`（已被 request 拦截器对齐到运行期下发地址）即可，
   *    既满足"隧道换址后旧缓存不粘连"，也保证不同实例互不干扰。
   *
   * 3) 参数键排序：`{a:1,b:2}` 与 `{b:2,a:1}` 必须同键（原实现已排序，保留）。
   */
  String keyOf(String path, Map<String, dynamic>? query, {required String apiBase}) {
    final qs = (query == null || query.isEmpty)
        ? ''
        : '?' + (query.keys.toList()..sort()).map((k) => '$k=${query[k]}').join('&');
    return '$sessionId|$apiBase|$path$qs';
  }

  /// 取缓存：返回响应体与是否新鲜
  ({Map<String, dynamic> body, bool fresh})? get(String key, Duration ttl) {
    final e = _mem[key];
    if (e == null) return null;
    return (body: e.body, fresh: _now.difference(e.at) < ttl);
  }

  /**
   * **缓存优先读（cache-first）**：不管新不新鲜，只要有就给出上一次的响应体 + 它的年龄。
   *
   * 与 [get] 的分工（别混用）：
   *   - [get] 是 **ApiClient.request 内部**的判定入口（新鲜 → 直接用；过期 → 先给旧的再后台刷新）；
   *   - 本方法是**页面**的入口：页面想在"点进来的那一刻"立刻画出上一次的内容（哪怕已经过期），
   *     再让网络刷新原地更新 —— 用户感知从"等白屏"变成"秒出"。
   *
   * 为什么需要"年龄"：页面据此知道画上去的这份有多旧 —— 过期就配一条发丝线级"正在刷新"弱提示，
   * 新数据回来后原地替换。没有年龄就只能"要么不敢画、要么假装它是新的"。
   *
   * 返回 null = 这次运行内从没拉到过这条路径（真·首次），页面该显示加载态。
   */
  ({Map<String, dynamic> body, Duration age})? peek(String key) {
    final e = _mem[key];
    if (e == null) return null;
    return (body: e.body, age: _now.difference(e.at));
  }

  void put(String key, Map<String, dynamic> body) {
    _mem[key] = _Entry(body: body, at: _now);
  }

  /// 写操作后失效相关缓存（仅本账号 + 本地址的前缀匹配）
  ///
  /// **只失效"当前账号 + 当前地址"下的条目**：缓存键形如 `auth|<apiBase>|<path>?<query>`，
  /// 若直接 `k.contains(prefix)` 会连别的账号、别的服务器地址的条目一起清掉 ——
  /// 本来只是"自己写完了要刷新自己"，却顺手毁掉同机上其它账号/另一端地址的缓存，
  /// 切回去时要全部重新拉。因此先按 `who|base|` 收窄，再匹配路径前缀。
  void invalidatePrefix(String pathPrefix, {required String apiBase}) {
    final scope = keyOf('', null, apiBase: apiBase); // '<who>|<apiBase>|'
    _mem.removeWhere(
      (k, _) => k.startsWith(scope) && k.substring(scope.length).contains(pathPrefix),
    );
  }

  /// 清空（退出登录时调用，避免串号）
  void clear() => _mem.clear();

  /**
   * **页面热重载专用**：只丢掉"某条路径缓存"，不动账号维度（2026-10-06 大厅延迟专项）。
   *
   * 为什么需要它（不变量，别删）：大厅把缓存当"秒开素材"，于是**必须**保证
   * 「重建页面 = 重新确认服务端」。同一次运行内第二次进大厅时，内存缓存里的
   * `/worker/order-hall` 可能已经 40s 旧，而 10s TTL 会让 `request()` 判定它**过期**
   * → 走 SWR 路径（先给旧数据 + 后台刷新）。这本身没问题，但"给旧数据"那一刻页面
   * 会先把**上一次进入时的列表**亮出来 —— 用户会觉得"单子是老的"。
   * 因此大厅 `initState` 主动把 `/worker/order-hall` 的缓存条目清掉：
   * 进页面 = 一定回源，绝不拿上一次的列表充数；而**切分部**靠的是"进页面后立刻并行预取"
   * （那时缓存刚被这次进页面填满，是新鲜的），两者不冲突。
   *
   * 语义边界：调用方自己给出**全路径**（如 `/worker/order-hall`），只清本路径开头的条目，
   * 且只清"当前账号 + 当前地址"域（与 [invalidatePrefix] 同一套收窄规则）。
   */
  void invalidate(String path, {required String apiBase}) => invalidatePrefix(path, apiBase: apiBase);

  String stats() => 'hit=$hitCount miss=$missCount revalidate=$revalidateCount cached=${_mem.length}';
}

class _Entry {
  _Entry({required this.body, required this.at});
  final Map<String, dynamic> body;
  final DateTime at;
}
