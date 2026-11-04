import { Injectable } from '@nestjs/common';

import { parsePageSize } from '../../common/pagination';
import { DivisionService } from '../division/division.service';
import { LeaderboardService } from '../leaderboard/leaderboard.service';
import { ProductService } from '../product/product.service';
import { PlayersService } from '../worker/players.service';
import { HomeService } from './home.service';

/** 首屏各子块的默认条数（负责人 2026-10-16：默认 10） */
export const HOME_AGGREGATE_DEFAULT_LIMIT = 10;

/**
 * 首屏各子块的条数上限（50）
 *
 * 为什么需要上限：本接口一次要把三块列表（商品/陪玩/周榜）装进**同一个响应体**，
 * 而每多一条陪玩就多一次头像图片请求（客户端侧成本）—— 首屏只需要"够看一眼"的量，
 * 真要翻到底应由各自的分页接口（`/public/products`、`/public/players`、`/public/leaderboard`）承担。
 * 50 与其它列表接口的 `parsePageSize` 默认上限一致，不引入第二套分页心智。
 */
export const HOME_AGGREGATE_MAX_LIMIT = 50;

/**
 * 首屏聚合（`GET /public/home`）—— **一次请求给全首屏**，治跨境卡顿的**正解**
 *
 * ## 为什么要合并（负责人 2026-10-16「网络都是一个网，为啥这么卡」的实测结论）
 *
 * 服务器处理每个接口只要 2–21ms、负载 0.08、慢查询 0 —— 慢的**不是服务器**，
 * 是香港机房到客户端的 **RTT ≈ 245ms**：同一条 keep-alive 连接上顺序跑 5 个接口 = **1819ms**。
 * 结论：**减少往返次数**是这条链路上唯一的数量级手段（省一次 = 省 245ms）。
 * 本接口把首屏需要的 5 类数据合并成 1 次往返（实测见交付报告）。
 *
 * ## 各子块**一律复用既有 service 方法**（"同一规则只有一份实现"）
 *
 * | 子块 | 复用点 |
 * |---|---|
 * | `announcements` | `HomeService.publicHome()`（既有字段，老板端服务页在读 —— **不删**） |
 * | `banners` | `HomeService.publicBanners()`（`GET /public/banners` 同一函数，**含 2026-10-16 新增的 `imageWidth`/`imageHeight`** —— 聚合段与独立接口逐字段一致，客户端两条路都能按真实宽高比定高） |
 * | `divisions` | `DivisionService.listGrouped()`（`GET /divisions/grouped` 同一函数） |
 * | `hotProducts` | `ProductService.publicList()`（`GET /public/products` 同一函数，含"分部下架即不公开"口径） |
 * | `players` | `PlayersService.list()`（`GET /public/players` 同一函数，含生效值/好评率口径） |
 * | `leaderboard` | `LeaderboardService.publicBoard()`（`GET /public/leaderboard` 同一函数） |
 *
 * **本文件里没有一条 SQL**：聚合层只做编排与裁剪，任何"顺手写个查询"都会立刻造出第二套口径
 * （例如首页商品忘了过滤已下架分部、首页陪玩用了真实值而不是生效值）。
 *
 * ## 并行取值（`Promise.all`）
 *
 * 六个子块之间**没有任何数据依赖**，一律并行发出（串行 = 白白多等 5 个 RTT × 各子查询耗时）。
 * 这也是本接口唯一能"比 5 次调用快一个数量级"的原因：往返是 1 次，SQL 是并行的一批。
 *
 * ## 脱敏口径（沿袭既有公开接口，**不放宽**）
 *
 * 响应里没有手机号 / `uid` / 真实姓名 / `user.id`；评价者仍只出现在
 * `GET /public/workers/:id/reviews` 的 `nicknameMasked`（本接口**不内嵌评价列表**，
 * 首屏不需要逐条评价，需要时由打手详情页取）。榜单行仍不含 `workerId`（见 `publicBoard`）。
 *
 * ## 缓存档位：**`no-store`**（不进进程内微缓存）
 *
 * 判定理由（沿袭 `PublicCacheInterceptor` 里 `/public/players` 那次修正的同一把尺子）：
 * 本接口内嵌了**随授权状态实时变化**的数据（people 名单：撤销某分部接单权限后必须**下一次请求即生效**，
 * CLAUDE.md 结构规则 10）与**随评价实时变化**的数字（好评率/展示值）。
 * 30 秒微缓存会把这些"现算出来的数字"挡成旧值 —— 等于用"省 2ms 的服务端算力"
 * 换"最长 30 秒的错数据"，在这条链路上是彻底的反向优化（真正的成本是 245ms 的 RTT，不是这几毫秒 SQL）。
 * 客户端侧仍有自己的 SWR（`api_cache.dart`，60s 档）负责"同一次前台会话内不重复问"。
 */
@Injectable()
export class PublicHomeService {
  constructor(
    private readonly home: HomeService,
    private readonly divisions: DivisionService,
    private readonly products: ProductService,
    private readonly leaderboard: LeaderboardService,
    private readonly players: PlayersService,
  ) {}

  /**
   * @param q.divisionId 可选：分部筛选（商品按"该分部已上架"过滤、陪玩按"该分部有接单权限"过滤、
   *   榜单取该分部榜；分部列表本身仍给全量分组，由客户端按上方胶囊高亮 —— 与既有页面一致）
   * @param q.gameId 可选：游戏筛选（只作用于商品子块；分部/陪玩/榜单无此维度，传了也不臆造语义）
   * @param q.limit 可选：三块列表的条数（默认 10，上限 50；非法值回落默认值，与 `parsePageSize` 同口径）
   */
  async aggregate(q: { divisionId?: string; gameId?: string; limit?: string }) {
    const limit = parsePageSize(q.limit, HOME_AGGREGATE_DEFAULT_LIMIT, HOME_AGGREGATE_MAX_LIMIT);
    const divisionId = q.divisionId?.trim() || undefined;
    const gameId = q.gameId?.trim() || undefined;

    // 六个子块并行（彼此无依赖）。刻意**不**串行：串行会把这 6 次查询的耗时相加，
    // 而它们在数据库侧各自都是 2–21ms 级、且互不等待。
    const [home, banners, divisions, products, players, board] = await Promise.all([
      this.home.publicHome(),
      this.home.publicBanners(),
      this.divisions.listGrouped(),
      this.products.publicList({ gameId, divisionId, page: 1, pageSize: limit }),
      this.players.list({ divisionId, page: 1, pageSize: limit }),
      this.leaderboard.publicBoard({ kind: 'week', divisionId }),
    ]);

    return {
      // 既有字段：老板端服务页读的是它（本周只做"扩展"，不删既有 key，避免打穿线上客户端契约）
      announcements: home.announcements,
      banners,
      divisions,
      hotProducts: products.list,
      players: players.list,
      // 周榜前 N 条（`publicBoard` 已裁成公开形状：名次/名字/工号/单数/金额，不含 workerId）
      leaderboard: board.list.slice(0, limit),
      /**
       * 数据快照时间（毫秒）：客户端可据此判断"这份首屏数据是什么时候算的"。
       * 注意它与响应体里的 `timestamp`（统一响应结构，见 `ResponseInterceptor`）不是一回事 ——
       * 后者是"响应生成时刻"，这里是"首屏数据取材时刻"，聚合接口用后者意义更明确。
       */
      updatedAt: Date.now(),
    };
  }
}
