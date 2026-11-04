import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';

import { RATING_DIMS, RatingDim } from './worker-grade.constants';

/**
 * 六维（= 五维 + 「评分」轴）手填值的**唯一读写实现**
 * ============================================================================
 * 负责人 2026-10-18：「管理端可手填打手六维评分（含雷达图数据）」。
 *
 * ## 为什么要有这一层（问题原样复述）
 *
 * 老板评价是**自愿**的：一个新打手 / 冷门打手没有任何评价 → `worker_rating_agg` 无行
 * （或全 0 + `sample_count = 0`）→ `GET /public/workers/:id` 的 `rating` 五维全 0、样本 0
 * → 陪玩主页六轴（评分 / 技术水平 / 情绪价值 / 抗压能力 / 声音听感 / 综合表现）**全部显示 `--`**。
 * 运营需要一个**只影响展示**的手填通道，让主页雷达图有数据。
 *
 * ## 三条铁律
 *
 * ### ① 每维独立：manual 有值就用 manual，否则回落 agg（**逐维**判定，不是整表二选一）
 *
 * 六维可以只填其中两维：填了的走 manual，没填的继续走自动聚合。返回值的
 * `sources` 逐维标 `'manual' | 'auto' | 'none'`，让前端/接口消费者一眼看出"这个数字是谁给的"：
 *
 * | manual 列 | agg 样本 | 结果值 | source |
 * |---|---|---|---|
 * | 有值 | 任意 | manual 值 | `manual` |
 * | NULL | `sample_count > 0` | agg 值 | `auto` |
 * | NULL | 无行 / 样本 0 | **`null`** | `none` |
 *
 * ⚠️ `none` 时值必须是 **`null` 而不是 0**：`0` 在这张雷达图上的意思是"这项极差"，
 * 而 `null` 是"没有数据"。把两者混成一个数字，就等于给新打手画了个"样样稀烂"的画像
 * （客户端 `_WorkerRating.tryParse` 也是按这个语义判空的，见
 * `apps/boss-app/lib/pages/worker_profile_page.dart`）。
 *
 * ### ② **绝不参与等级判定**（红线，改之前先读）
 *
 * 本表的数字**只影响展示**。`worker_grade` 的判定与升级进度一律只读
 * `worker_rating_agg` / `worker_stats` / `order_review`（落点：`worker-grade.service.ts#metricsOf`
 * 只调本文件的 [manualRow] **不调用**；它读的是 `ratingRow`，即 `worker_rating_agg`）。
 * 理由一句话：**手填值只影响展示，不影响等级判定，否则改分即可刷等级** ——
 * 等级是平台对真实履约的评价，让运营改个数字就能升级，等于把制度交给手输框。
 *
 * ### ③ 读侧**实时查库、无缓存**
 *
 * 管理端 PUT 完，老板端下一次请求即生效（与 `worker_stats.display_*`、
 * `worker_division_permission`、`worker_app_sunset_at` 全部同口径）。
 * 公开详情接口 `GET /public/workers/:id` 已在 `PublicCacheInterceptor` 里登记为 `no-store`，
 * 所以这里**不需要**任何失效钩子。
 *
 * ## 表与列
 *
 * `worker_rating_manual`（migration `1818000000000`，一人一行，`worker_id` 主键）：
 * `score`（「评分」那一轴）+ 五维 `skill/emotion/stress/voice/shop`，六列**全部可空**
 * （`NULL` = 该维未手动设，见 migration 注释 ①），外加 `updated_by` / `updated_at` 审计两列。
 *
 * ## 六维与五维的关系（别搞混）
 *
 * - **五维** = 老板评价的五列（`skill/emotion/stress/voice/shop`），有 agg 聚合；
 * - **「评分」轴** = 陪玩主页的第一个轴，原本由**好评率 ÷ 10** 算出来（客户端 `_scoreFromRate`），
 *   服务端没有对应列 —— 本表新增 `score` 列就是给它一个可手填的落点。
 *   没有手填时 `score` 的 `source` 为 `none`（**不在这里替客户端算好评率**：
 *   好评率口径的唯一出口是 `ReviewService.satisfiedRateText`，本服务不复制第二份）。
 */
@Injectable()
export class WorkerRatingManualService {
  private readonly logger = new Logger('WorkerRatingManual');

  /** 六维字段名（顺序 = 接口/审计输出顺序；「评分」在最前，与雷达图第一轴一致） */
  static readonly DIMS = ['score', ...RATING_DIMS] as const;

  /** 手填值取值范围（与 `worker_rating.r_*` 的 1-10 不同：手填允许 0 = "这项 0 分"） */
  static readonly MIN = 0;
  static readonly MAX = 10;

  /** `operation_log.module` 固定值（审批表指定） */
  static readonly LOG_MODULE = 'worker_rating_manual';

  constructor(@InjectDataSource() private readonly dataSource: DataSource) {}

  // ------------------------------------------------------------------ 读（唯一一处实现）

  /**
   * **读侧唯一实现**：解析某打手的六维生效值 + 逐维来源
   *
   * @param workerId 打手档案 id（`worker.id`，**不是** `user.id`）
   * @param autoScore 「评分」轴的**自动值**（= 好评率 ÷ 10，由调用方按唯一出口算好传入）；
   *   不传 / `null` = 没有好评率可换算 → `score` 回落 `none`（显示 `--`）。
   *   ⚠️ 本服务**不自己算好评率**：口径唯一出口是 `ReviewService.satisfiedRateText`，
   *   在这里再写一遍 `SUM(satisfied)/COUNT(*)` 就会立刻出现"公开页 98.2 / 雷达 98.0"两套口径。
   *
   * 固定 **2 条 SQL**（手填行 1 条 + 聚合行 1 条），不随维度数变化。
   * 打手不存在时**不抛错**（这是纯读函数，调用方 `publicWorkerProfile` 已经做过 404 判定；
   * 这里再抛一次只会把公开页那句统一文案盖掉）。
   */
  async resolveRating(workerId: string, autoScore?: number | null): Promise<ResolvedRating> {
    const id = String(workerId ?? '').trim();
    // 非法 id（非纯数字）→ 与"没有数据"同形：不抛错、不猜值（公开接口的 404 口径在上游）
    if (!/^\d+$/.test(id)) return emptyResolved();

    const [manual, agg] = await Promise.all([this.manualRow(id), this.aggRow(id)]);

    const sources: RatingSources = {
      score: 'none',
      skill: 'none',
      emotion: 'none',
      stress: 'none',
      voice: 'none',
      shop: 'none',
    };
    const values: MutableRatingValues = {
      score: null,
      skill: null,
      emotion: null,
      stress: null,
      voice: null,
      shop: null,
    };

    for (const dim of WorkerRatingManualService.DIMS) {
      const m = manual[dim];
      if (m !== null) {
        // ① 手填优先（**逐维**判定：只填了两维时，另外四维继续走自动）
        values[dim] = m;
        sources[dim] = 'manual';
        continue;
      }
      // ② 回落自动聚合：**有样本才算 auto**（样本 0 时 agg 里那串 0.00 不是"0 分"，是"没有"）
      //
      // 注意 `score` 这一维**不在 `worker_rating_agg` 里** —— 聚合表只有老板评的五维
      // （skill/emotion/stress/voice/shop）。「评分」那一轴的真实来源是**好评率 ÷ 10**
      // （如 98.6% -> 9.86），由调用方算好后经 `autoScore` 传进来；没传就是"没有"，显示 `--`。
      // 绝不能拿 agg 里的五维去顶 `score`，那是两个口径。
      if (dim === 'score') {
        if (autoScore !== null && autoScore !== undefined) {
          values[dim] = autoScore;
          sources[dim] = 'auto';
          continue;
        }
        values[dim] = null;
        sources[dim] = 'none';
        continue;
      }
      if (agg.samples > 0) {
        values[dim] = agg.values[dim];
        sources[dim] = 'auto';
        continue;
      }
      // ③ 两边都没有 → null + none（**绝不填 0**，见类注释 ①）
      values[dim] = null;
      sources[dim] = 'none';
    }

    return {
      ...values,
      samples: agg.samples,
      sources,
    };
  }

  /**
   * 管理端读取（`GET /admin/workers/:id/rating-manual`）
   *
   * 与 [resolveRating] **共用同一段解析**（`effective` / `sources` 逐字一致），
   * 只是额外把 `manual`（六列的原始值，含 NULL）与审计两列一起给出来 ——
   * 管理端表单要"回填手填值"（NULL 才能渲染成空输入框），也必须能看出"这是谁什么时候改的"。
   *
   * 打手不存在 → 中文 404（管理端要能对**已停用/已封禁**的打手读，所以只看 `worker` 行是否存在，
   * 不看 `worker.status` / `user.status` —— 与 `ReviewService.workerStatsView` 同口径）。
   */
  async detailForAdmin(workerId: string, autoScore?: number | null): Promise<ManualRatingDetail> {
    const id = await this.assertWorkerExists(workerId);
    const resolved = await this.resolveRating(id, autoScore);
    const manual = await this.manualRow(id);
    const audit = await this.manualAudit(id);
    return {
      workerId: id,
      manual: {
        score: manual.score,
        skill: manual.skill,
        emotion: manual.emotion,
        stress: manual.stress,
        voice: manual.voice,
        shop: manual.shop,
      },
      effective: {
        score: resolved.score,
        skill: resolved.skill,
        emotion: resolved.emotion,
        stress: resolved.stress,
        voice: resolved.voice,
        shop: resolved.shop,
      },
      sources: resolved.sources,
      samples: resolved.samples,
      updatedBy: audit.updatedBy,
      updatedAt: audit.updatedAt,
    };
  }

  // ------------------------------------------------------------------ 写（管理端）

  /**
   * 保存手填值（`PUT /admin/workers/:id/rating-manual`）
   *
   * ## 语义：**逐字段局部更新**（与 `display-stats` 的"整体覆盖"刻意不同，别搞混）
   *
   * | 请求体里的形态 | 含义 |
   * |---|---|
   * | 字段**不出现**（`undefined`） | **保持原值不动** |
   * | 字段 = 数字（0–10，两位小数） | 设为该值 |
   * | 字段 = `null` | **清除该项**（回到自动） |
   *
   * 为什么这里不做"整体覆盖"：六维是六个独立旋钮，运营经常只想改其中一维
   * （"技术水平调成 9.5，别的先不动"）。若整体覆盖，前端每次都得把另外五维回传一遍，
   * 一次漏传就会静默清空别人的数据 —— 那是比"多一次 GET"严重得多的失误。
   * 清除单维在 UI 上是**显式的「清除」按钮**，语义与"没填"一致（都落 NULL）。
   *
   * ## 校验（DTO 已先校验一遍，这里再兜一层）
   *
   * 本函数也可能被其它入口调用，校验不能只活在校验管道里：
   * 值必须是 `0 ≤ v ≤ 10` 的有限数字，**最多两位小数**（与列 `decimal(4,2)` 对齐）；
   * 越界/非数字/三位小数 → 中文 400（不静默四舍五入：那会让"我填 9.999 存成 10.00"
   * 变成最难查的一类报障）。
   *
   * ## 写入方式
   *
   * 单条 `INSERT … ON DUPLICATE KEY UPDATE`（**不做"先查再写"**：那有并发窗口，
   * 两个管理员同时保存时后写的会覆盖前写的中间态）。
   * 只更新**请求里出现的列**（`undefined` 的列在 SQL 里保持 `col = col`），
   * 因此并发保存不同维度不会互相抹掉。
   *
   * ## 返回值
   *
   * 更新后的完整 `detailForAdmin` 形状（管理端不必再 GET 一次），
   * 外加 `audit`（`before` / `after` 六维摘要，供控制器写 `operation_log`）——
   * **不含任何隐私**（只有打手 id 与六个数字）。
   */
  async saveForAdmin(
    workerId: string,
    input: Partial<Record<RatingDim6, number | null>>,
    actorUserId: string | null,
  ): Promise<ManualRatingDetail & { audit: ManualRatingAudit }> {
    const id = await this.assertWorkerExists(workerId);

    // ---- 归一化：undefined（未出现）保持 undefined；null 清除；数字校验后保留 ----
    const patch: Partial<Record<RatingDim6, number | null>> = {};
    for (const dim of WorkerRatingManualService.DIMS) {
      if (!(dim in input)) continue;
      const raw = input[dim];
      if (raw === null) {
        patch[dim] = null;
        continue;
      }
      if (raw === undefined) continue;
      const n = Number(raw);
      if (!Number.isFinite(n)) {
        throw new BadRequestException(`「${DIM_LABELS[dim]}」必须是 ${WorkerRatingManualService.MIN}-${WorkerRatingManualService.MAX} 的数字`);
      }
      if (n < WorkerRatingManualService.MIN || n > WorkerRatingManualService.MAX) {
        throw new BadRequestException(`「${DIM_LABELS[dim]}」必须在 ${WorkerRatingManualService.MIN}-${WorkerRatingManualService.MAX} 之间`);
      }
      if (Math.round(n * 100) !== Number((n * 100).toFixed(6))) {
        throw new BadRequestException(`「${DIM_LABELS[dim]}」最多保留两位小数`);
      }
      patch[dim] = round2(n);
    }

    const before = await this.manualRow(id);
    const beforeAudit = await this.manualAudit(id);

    // 没有任何可写字段 → 只读回显（不写库、不产生空 UPDATE）
    if (Object.keys(patch).length > 0) {
      /**
       * 只把**请求里出现的列**写进 UPDATE 列表；未出现的列写成 `col = col`（保持原值）。
       * 参数顺序必须与列顺序严格对应（下面按 DIMS 顺序拼，不手写数组）。
       */
      const cols = WorkerRatingManualService.DIMS;
      const insertCols = ['worker_id', ...cols, 'updated_by', 'updated_at'];
      const insertPlaceholders = insertCols.map(() => '?').join(', ');
      const insertValues: unknown[] = [
        id,
        ...cols.map((c) => (c in patch ? patch[c] : null)),
        actorUserId,
        new Date(),
      ];
      // 注意：INSERT 分支用 `patch[c] ?? null`（新行时未出现的列本来就是 NULL）；
      // UPDATE 分支只对**出现的列**赋值，其余 `col = col`。
      const updateClauses = cols.map((c) => (c in patch ? `\`${c}\` = ?` : `\`${c}\` = \`${c}\``));
      const updateValues = cols.filter((c) => c in patch).map((c) => patch[c]);
      await this.dataSource.query(
        `INSERT INTO worker_rating_manual (${insertCols.map((c) => `\`${c}\``).join(', ')})
         VALUES (${insertPlaceholders})
         ON DUPLICATE KEY UPDATE
           ${updateClauses.join(',\n           ')},
           \`updated_by\` = ?,
           \`updated_at\` = ?`,
        [...insertValues, ...updateValues, actorUserId, new Date()],
      );
    }

    const after = await this.manualRow(id);
    const detail = await this.detailForAdmin(id);
    const changedDims = WorkerRatingManualService.DIMS.filter(
      (d) => before[d] !== after[d] || (d in patch),
    );

    this.logger.log(
      `六维手填 worker=${id} by=${actorUserId ?? '-'} 改动维度=[${changedDims
        .map((d) => `${d}:${before[d] ?? 'NULL'}→${after[d] ?? 'NULL'}`)
        .join(', ')}]`,
    );

    return {
      ...detail,
      audit: {
        workerId: id,
        before: before,
        after: after,
        // 未手写时的最后修改人与时间（用于"从未设过"的展示；写入后就是本次操作人）
        beforeUpdatedBy: beforeAudit.updatedBy,
        beforeUpdatedAt: beforeAudit.updatedAt,
      },
    };
  }

  // ------------------------------------------------------------------ 内部

  /**
   * 手填行（无行 → 六列全 `null`；**不编造分数**）
   *
   * ⚠️ 本方法**只被展示路径调用**（[resolveRating] / [detailForAdmin] / [saveForAdmin]）。
   * **等级判定不得调用它** —— 见类注释 ②。
   */
  private async manualRow(workerId: string): Promise<ManualRow> {
    const rows = (await this.dataSource.query(
      `SELECT score, skill, emotion, stress, voice, shop
         FROM worker_rating_manual WHERE worker_id = ? LIMIT 1`,
      [workerId],
    )) as Array<Record<string, number | string | null>>;
    const r = rows[0];
    return {
      score: numOrNull(r?.score),
      skill: numOrNull(r?.skill),
      emotion: numOrNull(r?.emotion),
      stress: numOrNull(r?.stress),
      voice: numOrNull(r?.voice),
      shop: numOrNull(r?.shop),
    };
  }

  /** 手填行的审计两列（无行 → 双 null） */
  private async manualAudit(workerId: string): Promise<{ updatedBy: string | null; updatedAt: Date | null }> {
    const rows = (await this.dataSource.query(
      `SELECT updated_by AS updatedBy, updated_at AS updatedAt
         FROM worker_rating_manual WHERE worker_id = ? LIMIT 1`,
      [workerId],
    )) as Array<{ updatedBy: string | number | null; updatedAt: Date | null }>;
    const r = rows[0];
    return {
      updatedBy: r?.updatedBy == null ? null : String(r.updatedBy),
      updatedAt: r?.updatedAt == null ? null : new Date(r.updatedAt),
    };
  }

  /**
   * 五维聚合行（无行 → 全 0 + 样本 0）
   *
   * 与 `WorkerGradeService.ratingRow` **读同一张表同一批列**，但**刻意不共用**：
   * 那个方法是判级路径的私有实现，本服务的读取若挂到它上面，将来"判级想加个字段"
   * 就会牵动展示路径。两条路径各自只读 `worker_rating_agg` 的原始列，口径相同、互不牵连。
   */
  private async aggRow(workerId: string): Promise<{ values: Record<RatingDim, number>; samples: number }> {
    const rows = (await this.dataSource.query(
      `SELECT skill, emotion, stress, voice, shop, sample_count AS samples
         FROM worker_rating_agg WHERE worker_id = ? LIMIT 1`,
      [workerId],
    )) as Array<Record<string, number | string | null>>;
    const r = rows[0];
    return {
      values: {
        skill: Number(r?.skill ?? 0) || 0,
        emotion: Number(r?.emotion ?? 0) || 0,
        stress: Number(r?.stress ?? 0) || 0,
        voice: Number(r?.voice ?? 0) || 0,
        shop: Number(r?.shop ?? 0) || 0,
      },
      samples: Number(r?.samples ?? 0) || 0,
    };
  }

  /**
   * 打手档案存在性（**不看** `worker.status` / `user.status`）
   *
   * 与 `ReviewService.assertWorkerExists` 同口径：管理端要能对已停用/已封禁的打手
   * 查看与调整手填值（停用了也要能看见它对外长什么样）。
   */
  private async assertWorkerExists(workerId: string): Promise<string> {
    const id = String(workerId ?? '').trim();
    if (!/^\d+$/.test(id)) throw new NotFoundException('打手不存在');
    const rows = (await this.dataSource.query('SELECT id FROM worker WHERE id = ? LIMIT 1', [id])) as Array<{
      id: string;
    }>;
    if (!rows.length) throw new NotFoundException('打手不存在');
    return id;
  }
}

// ---------------------------------------------------------------------------
// 对外类型（形状即接口契约；前端 `api/worker-rating-manual.ts` 逐字对应）
// ---------------------------------------------------------------------------

/** 六维字段（五维 + 「评分」轴） */
export type RatingDim6 = 'score' | RatingDim;

/** 单维来源：手填 / 自动聚合 / 都没有 */
export type RatingSource = 'manual' | 'auto' | 'none';

/** 逐维来源（六项齐备，前端可直接按 key 取） */
export interface RatingSources {
  score: RatingSource;
  skill: RatingSource;
  emotion: RatingSource;
  stress: RatingSource;
  voice: RatingSource;
  shop: RatingSource;
}

/** 六维生效值（`null` = 该维没有数据；**不是 0**） */
export interface ResolvedRating {
  skill: number | null;
  emotion: number | null;
  stress: number | null;
  voice: number | null;
  shop: number | null;
  /** 「评分」那一轴（手填优先；未手填且无样本 → null） */
  score: number | null;
  /** 五维样本数（`worker_rating_agg.sample_count`；**手填不改变它**） */
  samples: number;
  sources: RatingSources;
}

/** 手填行原始值（六列，NULL = 未手动设） */
type ManualRow = Record<RatingDim6, number | null>;

type MutableRatingValues = Record<RatingDim6, number | null>;

/** 管理端读/写返回（`GET` 与 `PUT` 同形，`PUT` 另带 `audit`） */
export interface ManualRatingDetail {
  workerId: string;
  /** 手填值（六列，NULL = 未手动设）—— 管理端表单回填用 */
  manual: ManualRow;
  /** 生效值（手填优先，否则聚合；都没有 → null） */
  effective: Record<RatingDim6, number | null>;
  /** 逐维来源 */
  sources: RatingSources;
  /** 五维样本数（老板评价条数） */
  samples: number;
  /** 最后修改人（user.id；NULL = 从未经人手写） */
  updatedBy: string | null;
  /** 最后修改时间（NULL = 从未经人手写） */
  updatedAt: Date | null;
}

/** `operation_log.request_body` 直接用它：只记关键字段与**变更前后六维摘要**，无任何隐私 */
export interface ManualRatingAudit {
  workerId: string;
  before: ManualRow;
  after: ManualRow;
  beforeUpdatedBy: string | null;
  beforeUpdatedAt: Date | null;
}

// ---------------------------------------------------------------------------
// 六维中文名（**唯一出处**：管理端文案与错误提示都读它，不许在别处另写一份）
// ---------------------------------------------------------------------------

/**
 * 六维中文名（顺序 = 雷达图六轴，负责人 2026-10-18 定名）
 *
 * 「评分」是第一个轴；「综合表现」对应服务端列 `shop`（原「店内表现」改名）。
 * 与 `apps/boss-app/lib/pages/worker_profile_page.dart` 的 `kRatingAxes` **同序同义**。
 */
export const DIM_LABELS: Readonly<Record<RatingDim6, string>> = {
  score: '评分',
  skill: '技术水平',
  emotion: '情绪价值',
  stress: '抗压能力',
  voice: '声音听感',
  shop: '综合表现',
};

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

/** 空结果（非法 id / 上游已判 404 时用；与"没有数据"同形） */
function emptyResolved(): ResolvedRating {
  return {
    skill: null,
    emotion: null,
    stress: null,
    voice: null,
    shop: null,
    score: null,
    samples: 0,
    sources: { score: 'none', skill: 'none', emotion: 'none', stress: 'none', voice: 'none', shop: 'none' },
  };
}

/** decimal 列可能回字符串（mysql2 默认把 DECIMAL 当字符串）→ 数字；NULL 保持 null */
function numOrNull(raw: unknown): number | null {
  if (raw === null || raw === undefined || raw === '') return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

/** 两位小数（与列 `decimal(4,2)` 对齐，避免 0.1 + 0.2 这类浮点尾巴进 SQL） */
function round2(v: number): number {
  return Math.round((Number(v) + Number.EPSILON) * 100) / 100;
}
