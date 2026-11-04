import { Controller, Get, Param, Query } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { HomeService } from './home.service';
import { PublicHomeService } from './public-home.service';

/** 公开：首页内容（无需登录） */
@ApiTags('public')
@Controller('public')
export class HomePublicController {
  constructor(
    private readonly service: HomeService,
    private readonly publicHomeService: PublicHomeService,
  ) {}

  /**
   * 首页聚合（**一次请求给全首屏**；负责人 2026-10-16 任务②）
   *
   * ## 从"只剩公告"到"首屏全量"的演进（两次改动都保留契约，不推翻）
   *
   * 2026-10-05 清理：`clubIntro` / `activity` / `orderButton` / `banners` / `topWorkers`
   * 五个字段的唯一消费者是已死代码（`apps/boss-app/lib/pages/home_page.dart`，全仓无人 import），
   * 随死代码一并删除；**`announcements` 保留**（老板端服务页仍从这里读公告）。
   *
   * 2026-10-16（本批次）重新把它做成**真正的首屏聚合**，但走的是**加法**：
   * - **新增** `banners` / `divisions` / `hotProducts` / `players` / `leaderboard` / `updatedAt`；
   * - **既有** `announcements` **逐字保留**（键名不变、口径不变），线上客户端契约不被打破；
   * - 每个子块都复用各自 service 的既有方法（见 `PublicHomeService` 的表格），本控制器**不算任何业务口径**。
   *
   * ## 为什么值得合并（实测，不是感觉）
   *
   * 服务端每个接口只要 2–21ms、负载 0.08、慢查询 0；真正的成本是跨境 **RTT ≈ 245ms** ——
   * 五条 keep-alive 串行 = 1819ms。**省一次往返 = 省 245ms**，合并是这条链路上唯一数量级手段。
   *
   * 客户端仍可分别调用各子接口（本接口是**替代 5 次调用的快路径**，不是唯一入口）。
   */
  @Get('home')
  @ApiOperation({
    summary:
      '公开：首页聚合（一次给全首屏：announcements/banners/divisions/hotProducts/players/leaderboard/updatedAt；可选 divisionId、gameId、limit）',
  })
  home(
    @Query('divisionId') divisionId?: string,
    @Query('gameId') gameId?: string,
    @Query('limit') limit?: string,
  ) {
    return this.publicHomeService.aggregate({ divisionId, gameId, limit });
  }

  /**
   * 公开公告列表（2026-10-05 新增）
   *
   * 为什么单独开一条：公告此前**只能**从首页聚合里拿，且聚合里写死 `take: 10`
   * ——列表被"首页展示位"的上限绑架。公告列表页需要完整列表，故开此路由；
   * 服务端微缓存前缀（`public-cache.interceptor.ts`）与客户端 SWR 前缀
   * （`api_cache.dart`）**此前就已登记 `/public/announcements`**（原为详情路由预留），
   * 本次直接命中，无需改缓存配置。
   *
   * 排序：置顶优先，其后按发布时间倒序（客户端列表页另做一次稳定排序兜底，
   * 保证「置顶优先 + 时间倒序」不依赖服务端排序细节）。
   */
  @Get('announcements')
  @ApiOperation({ summary: '公开：公告列表（置顶优先 + 时间倒序；不含正文）' })
  announcements() {
    return this.service.publicAnnouncements();
  }

  @Get('announcements/:id')
  @ApiOperation({ summary: '公开：公告详情' })
  announcementDetail(@Param('id') id: string) {
    return this.service.publicAnnouncementDetail(id);
  }

  /**
   * 公开宣传图轮播（2026-10-05 任务②，方案 C 顶部通栏沉浸）
   *
   * 为什么**单独开一条**而不是塞回 `GET /public/home`：
   * - `/public/home` 是首页聚合，它此前被"首页展示位上限"绑架过一次（公告写死 take:10），
   *   宣传图有自己明确的过滤语义（`visible=1` + 投放时间区间），独立路由才好按需取；
   * - 客户端 SWR 缓存按**路径前缀**登记（`api_cache.dart`），独立路径才能单独设 TTL 与 forceRefresh；
   * - 未登录也要能看（首页首屏就渲染轮播位）。
   */
  @Get('banners')
  @ApiOperation({ summary: '公开：宣传图轮播（仅 visible=1 且在投放时间区间内，按 sortOrder 升序）' })
  banners() {
    return this.service.publicBanners();
  }

  @Get('about')
  @ApiOperation({ summary: '公开：关于 祁连山电竞（管理端可编辑，设置页展示）' })
  about() {
    return this.service.publicModule('about_us');
  }

  @Get('privacy')
  @ApiOperation({ summary: '公开：隐私政策（管理端可编辑，设置页展示）' })
  privacy() {
    return this.service.publicModule('privacy_policy');
  }
}
