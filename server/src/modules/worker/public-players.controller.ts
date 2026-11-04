import { Controller, Get, Query } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';

import { parsePage, parsePageSize } from '../../common/pagination';
import { PlayersService } from './players.service';

/**
 * 找陪玩（公开）
 *
 * 负责人 2026-10-03 硬规则：列表**只返回 名字 + 介绍**（+ 头像/分部做展示）。
 * 禁止返回：明星陪玩 / 大神 / 单考 / 双考 / 空闲 / 忙碌 / 等级 / 评分 / 单价 /
 * 下单人数 / 语音时长 等字段（详见 CLAUDE.md 结构规则 6）。
 *
 * ⚠️ 负责人 2026-10-15 追加（`docs/43-陪玩入口与列表页设计（待审批）.md` 第八节）：
 * 卡片要显示 **接单次数 · 好评率**，而它们原先只在 `GET /public/workers/:id` 里 ——
 * 列表 14 行 = **N+1 次请求，不可接受**，因此追加 3 个字段：
 * `completedOrders` / `reviewCount` / `satisfiedRate`（+ `divisionName` 分部副标）。
 * 追加的**只有这三个数值 + 分部显示名**：单价 / 等级 / 评分 / 标签仍然一个都不出现。
 *
 * ⚠️ 2026-10-16（本批次）两处口径变化，都**不在本控制器**里：
 * ① 三个数值的**生效值**（管理端可设接单次数/好评率的展示值）由 `ReviewService.publicWorkerStats()`
 *    统一收口 —— 这个端点与 `GET /public/workers/:id`、`GET /public/home` 的 `players` 子块
 *    共用同一个函数，所以三处永远一致；
 * ② 查询与映射搬到了 `PlayersService.list()`（**服务层唯一实现**）——
 *    不为别的，就为了让 `/public/home` 能复用同一份名单，而不是复制粘贴出一份"首页版名单"。
 *
 * **无 N+1**：整页 id 一次带进 `IN (...)` 批量聚合（固定 2 条聚合 SQL，与 pageSize 无关）。
 *
 * 介绍来自 `user.intro`。⚠️ **2026-10-17 负责人改定：介绍由打手自己写**
 * （`PUT /worker/profile`，2–120 字 + 屏蔽联系方式），管理端 `PUT /admin/workers/:id/players-profile`
 * **保留**作为兜底改写入口 —— 两条路径写同一个字段，本列表对"谁写的"不感知、也不需要感知
 * （所以本文件一行未改：读路径本来就是"读 `user.intro`"）。
 */
@ApiTags('public')
@Controller('public')
export class PublicPlayersController {
  constructor(private readonly playersService: PlayersService) {}

  @Get('players')
  @ApiOperation({
    summary:
      '公开：找陪玩列表（名字 + 介绍 + 头像 + 分部 + 接单次数/评价条数/好评率；按分部筛选=该分部有接单权限的打手）',
  })
  players(
    @Query('divisionId') divisionId?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    // 分页参数统一走 common/pagination（docs/03/09：查询参数是不可信输入）。
    // 此前这里手写 `Math.max(1, Number(page) || 1)`：NaN 挡住了，但 `pageSize=10.9`
    // （小数）会让 LIMIT 拿到非法值、`pageSize=0`/负数会得到空结果，与其它列表接口不一致。
    // 上限 50：与其它列表接口一致（原实现允许到 100，"找陪玩"每行要取头像，
    // 一次拉 100 条会连带 100 次图片请求，反而拖慢首屏）
    return this.playersService.list({
      divisionId: divisionId?.trim() || undefined,
      page: parsePage(page),
      pageSize: parsePageSize(pageSize, 20, 50),
    });
  }
}
