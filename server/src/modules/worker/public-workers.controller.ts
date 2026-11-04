import { Controller, Get, Param, Query } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';

import { parsePage, parsePageSize } from '../../common/pagination';
import { WorkerGradeService } from '../rating/worker-grade.service';
import { ReviewService } from '../review/review.service';
import { WorkerRatingManualService } from './worker-rating-manual.service';

/**
 * 打手公开信息（公开接口，**无需登录**）
 *
 * 负责人 2026-10-15：「选打手页面点开打手头像可以看打手信息」，
 * 并按竞品（东东电竞 4.6.0）的信息架构取 **「接单次数 + 好评率」** 两个数值
 * （竞品资源串原文：`string/home_skill_order_desc = "接单%1$s次  好评率%2$s"`）——
 * 我们只用它的**信息结构**，文案与视觉自成一套。
 *
 * 数据源（口径唯一一处 = `ReviewService`）：
 * - `completedOrders` ← `worker_stats.completed_orders`（**与榜单同源**，不另算一套）；
 * - `reviewCount` / `satisfiedRate` / `reviews` ← `order_review` **实时聚合**，只算 `hidden = 0`。
 *
 * ⚠️ **脱敏口径（docs/09，不可放宽）**：响应里**只有脱敏昵称**（如「李**」），
 * 手机号 / `uid` / 真实用户名 / `user.id` 一个都不出现；评价人的身份信息到此为止。
 *
 * ⚠️ 2026-10-17 追加（负责人已审批的打手等级制度）：本接口在原有字段**之后追加**
 * `grade` / `gradeLabel` / `gradeName` / `rating`（五维均分 + 样本数）/ `progress`（升级进度）。
 * 追加来源是 `WorkerGradeService.detail()` —— 与 `GET /worker/grade`（打手态「我的」）
 * 走的是**同一个函数**，所以"打手自己看到的等级/进度"与"老板看到的"绝不可能是两套数字。
 * **原有字段一个都没改**（`id/nickname/intro/avatarMediaId/completedOrders/reviewCount/satisfiedRate/reviews`）。
 *
 * ⚠️ 2026-10-18 追加（负责人：管理端可手填六维评分）：`rating` 里**再加** `score` 与 `sources`
 * 两个字段（**其余字段名一个不改**，`skill/emotion/stress/voice/shop/avg/samples` 原样保留）。
 *
 * 解析规则**只有一处实现**：`WorkerRatingManualService.resolveRating()` ——
 * 每维「手填有值 → 用手的（`sources='manual'`）；否则用聚合（有样本才 `'auto'`）；都没有 → `null` + `'none'`」。
 * 这一步是**展示层叠加**，不影响 `grade` / `progress`：
 * **管理端手填值只影响展示，不影响等级判定，否则改分即可刷等级** ——
 * `WorkerGradeService.metricsOf()` 读的是 `worker_rating_agg`，从不读 `worker_rating_manual`。
 *
 * 为什么 `avg` / `samples` 保持 `WorkerGradeService.detail()` 的原值（不按手填重算）：
 * `avg` 是**判级门槛比较的那个数**，`samples` 是**评价条数**。若按手填值重算 `avg`，
 * 公开页显示的"五维均分"就会与判级用的数字不是同一个（`progress` 会自相矛盾）；
 * `samples` 若被手填影响，"老板评价 N 条"就成了假数据。因此两个都**原样透传**。
 *
 * ⚠️ 这两个接口在 `PublicCacheInterceptor` 里登记为 **`no-store`**（不进进程内微缓存）：
 * 好评率与等级随老板评价/评分**立刻**变化，与 `/public/players`（随授权状态变化）同类 ——
 * "实时算出来的数字"再被 30 秒缓存挡住，等于白算。管理端手填值同理（改完下一次请求即生效）。
 */
@ApiTags('public')
@Controller('public/workers')
export class PublicWorkersController {
  constructor(
    private readonly reviewService: ReviewService,
    private readonly gradeService: WorkerGradeService,
    /**
     * 六维手填值的**唯一读侧实现**（逐维 manual / auto / none 解析）。
     * 只在这里用于**展示叠加**；等级判定路径（`WorkerGradeService`）不注入本服务。
     */
    private readonly manualRating: WorkerRatingManualService,
  ) {}

  @Get(':id')
  @ApiOperation({
    summary:
      '公开：打手信息（昵称/介绍/头像/接单次数/好评率/最近 20 条评价 + 等级/六维（含手填优先）/样本数/升级进度；无需登录）',
  })
  async detail(@Param('id') id: string) {
    /**
     * 顺序有讲究：先 `publicWorkerProfile`（它的 `requirePublicWorker` 负责
     * 「不存在 / 档案停用 / 账号封禁 → 同一句中文 404」这条公开页口径），
     * 通过了才去读等级 —— 否则 `detail()` 自己那句 404 会盖掉公开页的**统一**文案。
     */
    const profile = await this.reviewService.publicWorkerProfile(id);
    const grade = await this.gradeService.detail(profile.id);
    /**
     * 六维（五维 + 「评分」轴）手填优先解析。
     *
     * 「评分」轴的**自动值** = 好评率 ÷ 10（客户端 `_scoreFromRate` 的同一口径）：
     * 这里只做除法，百分数本身来自 `profile.satisfiedRate` —— 它已经是
     * `ReviewService.satisfiedRateText()` 的输出（**好评率唯一出口**），
     * 本控制器**不重算** `SUM(satisfied)/COUNT(*)`。无评价时它是 `null` → `autoScore` 传 `null`
     * → `score` 回落 `none`（显示 `--`，绝不编 0）。
     *
     * `avg` / `samples` 仍用等级服务的原值（见类注释：avg 是判级比较的那个数）。
     */
    const autoScore = scoreFromRate(profile.satisfiedRate);
    const resolved = await this.manualRating.resolveRating(profile.id, autoScore);
    // 追加字段（不改既有字段）：grade / gradeLabel / gradeName / rating{...,score,sources} / progress
    //
    // ⚠️ 2026-10-18 修：这里原先只把 `score` / `sources` 接上，**五维还是 `grade.rating` 的原始
    // 聚合值**（全 0）→ 管理端手填后 `sources` 说 `manual` 但值仍是 0，老板端看不到。
    // 现在五维一律取 `resolved`（手填优先 → 回落聚合），`null`（两边都没有）落回 `0`
    // 是为了不改既有契约（客户端本来就按 `samples`/差集判断"无数据"，不吃 null）。
    return {
      ...profile,
      ...grade,
      rating: {
        ...grade.rating,
        skill: resolved.skill ?? 0,
        emotion: resolved.emotion ?? 0,
        stress: resolved.stress ?? 0,
        voice: resolved.voice ?? 0,
        shop: resolved.shop ?? 0,
        score: resolved.score,
        sources: resolved.sources,
      },
    };
  }

  @Get(':id/reviews')
  @ApiOperation({ summary: '公开：打手评价分页（只含未隐藏评价；脱敏昵称；pageSize ≤ 50）' })
  reviews(
    @Param('id') id: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    // 分页参数统一走 common/pagination（docs/03/09：查询参数是不可信输入）
    return this.reviewService.publicWorkerReviews(String(id), parsePage(page), parsePageSize(pageSize, 20, 50));
  }
}

/**
 * 好评率百分数字符串 → 「评分」轴（0–10，两位小数）
 *
 * 口径与客户端 `worker_profile_page.dart#_scoreFromRate` **逐字一致**：
 * `98.6%` → `9.86`、`100%` → `10`、`1%` → `0.1`；无评价（`null`）→ `null`（显示 `--`）。
 *
 * 入参**只接受 `satisfiedRateText()` 的输出形态**（百分数字符串，如 `"98.2"`）——
 * 本函数不碰 `order_review`、不重算好评率：好评率的唯一出口在 `ReviewService`，
 * 这里只是把它落进雷达图 0–10 的量程（与另外五轴同量程）。
 */
function scoreFromRate(rate: string | null | undefined): number | null {
  if (rate === null || rate === undefined) return null;
  const percent = Number(String(rate).replace('%', '').trim());
  if (!Number.isFinite(percent)) return null;
  const score = percent / 10;
  // 夹到 0–10（好评率理论上不会越界，但"上游口径变了"不该让雷达图画到框外）
  return Math.min(10, Math.max(0, Math.round((score + Number.EPSILON) * 100) / 100));
}
