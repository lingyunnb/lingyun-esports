import {
  AUTO_MAX_GRADE,
  DEFAULT_WORKER_GRADE,
  MIN_RATING_SAMPLES_FOR_GRADE,
  WORKER_GRADE_RULES,
  WorkerGradeRule,
  gradeLabel,
  gradeName,
  workerGradeRule,
} from '../worker/worker-grade.constants';

/**
 * 打手等级判定（**纯函数，唯一实现**；无 IO、无 Nest 依赖，便于单测与复审）
 *
 * 判定算法与门槛数字**全部分离**：数字只来自 `modules/worker/worker-grade.constants.ts`
 * 的 `WORKER_GRADE_RULES`（负责人审批表），本文件只负责"怎么比"。
 *
 * ## 判定顺序（与审批表一致：依次判定 2 → 3 → 4）
 *
 * 从 `grade 2` 起**升序**逐档检查；一档的五个门槛（完成单 / 好评率 / 五维均分 / 结算累计 / 五维样本）
 * **全部满足**才算达标，记住"最后一个达标的档位"。
 * 升序而不是降序扫描，是为了让"命中了哪几档、差在哪一项"在返回的 `tiers` 里完整可见（审计要用）。
 *
 * ## 三条铁律在本文件里的落点
 *
 * | 铁律 | 落点 |
 * |---|---|
 * | 只升不降 | **本文件不做 max(current, target) 的比较** —— 它只回答"指标够到第几档"；<br>"只升不降"由 `WorkerGradeService.evaluate()` 的 `newGrade > before` 保证（唯一一处） |
 * | 样本 < 10 不参与判定 | `ratingSamples < MIN_RATING_SAMPLES_FOR_GRADE` → **样本本身是硬门槛**，<br>该情况下**任何档都不达标**（不升档）；同时均分**不参与**比较（不会被 0 分拖累成"负分"） |
 * | 5 级不自动给 | `opts.maxGrade` 默认 `AUTO_MAX_GRADE = 4`；且 `grade 5` 的 `manualOnly` 为真，两道闸门都在 |
 *
 * ## 「无好评率」怎么算
 *
 * `order_review` 一条都没有时好评率是 **null**（既不是 0 也不是 100，见 `ReviewService` 的口径红线）。
 * 此时"≥95%"**无从满足** → 该档不达标（不升档）。理由：审批表的门槛是**至少要有多条好评**才能升档，
 * 把"没人评过"当成满分会让新打手一上来就满足好评率门槛。
 */

/** 判级输入指标（**全部真实值**，不含任何管理端展示覆盖值） */
export interface GradeMetrics {
  /** 累计完成单（`worker_stats.completed_orders`） */
  completedOrders: number;
  /** 好评率百分数（`order_review` 实时聚合，1 位小数）；**null = 无评价** */
  satisfiedRatePercent: number | null;
  /** 五维均分 = 五列 AVG 的均值（0–10，两位小数） */
  ratingAvg: number;
  /** 五维样本数（`worker_rating_agg.sample_count`） */
  ratingSamples: number;
  /** 结算累计（元；`worker_stats.total_amount`） */
  settlementAmount: number;
}

/** 单档判定结果（审计/进度展示用） */
export interface GradeTierResult {
  grade: number;
  label: string;
  name: string;
  /** 该档是否已全部达标 */
  satisfied: boolean;
  /** 已满足的门槛描述（中文，直接可展示） */
  hits: string[];
  /** 未满足的门槛描述（中文，直接可展示） */
  misses: string[];
}

export interface GradeTierDecision {
  /** 指标够到的最高档（**不低于 1**；不含只升不降的比较） */
  grade: number;
  /** 逐档明细（2..min(maxGrade,5)） */
  tiers: GradeTierResult[];
  /** 达标档位的命中指标（写 `operation_log` 用） */
  hits: string[];
}

const round2 = (v: number): number => Math.round((Number(v) + Number.EPSILON) * 100) / 100;
const round1 = (v: number): number => Math.round((Number(v) + Number.EPSILON) * 10) / 10;

/** 单档比较：返回 hits / misses（**判定口径的唯一实现**，进度计算复用同一份） */
export function compareGradeRule(
  rule: WorkerGradeRule,
  m: GradeMetrics,
): { hits: string[]; misses: string[] } {
  const hits: string[] = [];
  const misses: string[] = [];

  if (rule.minCompletedOrders !== null) {
    if (m.completedOrders >= rule.minCompletedOrders) {
      hits.push(`完成单 ${m.completedOrders} ≥ ${rule.minCompletedOrders}`);
    } else {
      misses.push(`还差 ${rule.minCompletedOrders - m.completedOrders} 单`);
    }
  }

  if (rule.minSatisfiedRate !== null) {
    if (m.satisfiedRatePercent === null) {
      misses.push('还没有好评率（暂无订单评价）');
    } else if (m.satisfiedRatePercent >= rule.minSatisfiedRate) {
      hits.push(`好评率 ${round1(m.satisfiedRatePercent)}% ≥ ${rule.minSatisfiedRate}%`);
    } else {
      misses.push(`好评率还差 ${round1(rule.minSatisfiedRate - m.satisfiedRatePercent)}%`);
    }
  }

  if (rule.minRatingAvg !== null) {
    // 五维样本门槛：不足 10 条时**均分不参与判定**（防刷），因此这里既不 hit 也不按"差多少分"报
    if (m.ratingSamples < MIN_RATING_SAMPLES_FOR_GRADE) {
      misses.push(`五维样本还差 ${MIN_RATING_SAMPLES_FOR_GRADE - m.ratingSamples} 条（不足 ${MIN_RATING_SAMPLES_FOR_GRADE} 条不参与升级判定）`);
    } else if (m.ratingAvg >= rule.minRatingAvg) {
      hits.push(`五维均分 ${round2(m.ratingAvg)} ≥ ${rule.minRatingAvg}`);
    } else {
      misses.push(`五维均分还差 ${round2(rule.minRatingAvg - m.ratingAvg)}`);
    }
  }

  if (rule.minSettlementAmount !== null) {
    if (m.settlementAmount >= rule.minSettlementAmount) {
      hits.push(`结算累计 ¥${round2(m.settlementAmount)} ≥ ¥${rule.minSettlementAmount}`);
    } else {
      misses.push(`结算累计还差 ¥${round2(rule.minSettlementAmount - m.settlementAmount)}`);
    }
  }

  return { hits, misses };
}

/**
 * 指标 → 应达档位（**自动判定唯一入口**）
 *
 * @param m 真实指标（见 `GradeMetrics`）
 * @param opts.maxGrade 自动判定上限，默认 `AUTO_MAX_GRADE = 4`（最高档永不自动给）；测试可显式传 5 做对照
 */
export function evaluateGradeTier(m: GradeMetrics, opts?: { maxGrade?: number }): GradeTierDecision {
  const cap = Math.min(
    Number.isFinite(Number(opts?.maxGrade)) ? Number(opts?.maxGrade) : AUTO_MAX_GRADE,
    AUTO_MAX_GRADE,
  );

  const tiers: GradeTierResult[] = [];
  let grade = DEFAULT_WORKER_GRADE;
  let hits: string[] = [];

  // 升序：2 → cap（审批表口径"依次判定"；门槛本身单调，结果与降序扫描等价，但审计信息更全）
  for (let g = 2; g <= cap; g += 1) {
    const rule = workerGradeRule(g);
    if (!rule || rule.manualOnly) continue; // 最高档 manualOnly → 永远进不了自动判定
    const cmp = compareGradeRule(rule, m);
    const satisfied = cmp.misses.length === 0;
    tiers.push({
      grade: g,
      label: gradeLabel(g),
      name: gradeName(g),
      satisfied,
      hits: cmp.hits,
      misses: cmp.misses,
    });
    if (satisfied) {
      grade = g;
      // 命中指标取**最高达标档**的（审计要能回答"凭什么升到这一档"）
      hits = cmp.hits;
    }
  }

  return { grade, tiers, hits };
}

/** 距下一级还差多少（数值形态，前端可直接算进度条） */
export interface GradeRemain {
  /** 还差多少单（0 = 已达标） */
  completedOrders: number;
  /** 好评率还差多少个百分点（0 = 已达标；无评价时为 null） */
  satisfiedRate: number | null;
  /** 五维均分还差多少（0 = 已达标） */
  ratingAvg: number;
  /** 结算累计还差多少元（0 = 已达标） */
  settlementAmount: number;
  /** 五维样本还差多少条（0 = 已达标） */
  ratingSamples: number;
}

/** 升级进度（公开详情 / 打手态「我的」共用**同一形状**） */
export interface GradeProgress {
  currentGrade: number;
  currentGradeLabel: string;
  currentGradeName: string;
  /** 下一档（已到最高档 → null） */
  nextGrade: number | null;
  nextGradeLabel: string | null;
  nextGradeName: string | null;
  /** 下一档是否必须人工审核（= 已达 LV4，想上 LV5） */
  needManualReview: boolean;
  /** 已满足的下一档门槛（中文） */
  hits: string[];
  /** 还差什么（中文，可直接展示；空数组 = 指标已全部达标） */
  blockers: string[];
  /** 数值差额（见 `GradeRemain`） */
  remain: GradeRemain | null;
  /** 指标是否已满足下一档全部门槛（true = 等着生效 / 等着人工审核） */
  readyNow: boolean;
}

/**
 * 升级进度（**唯一实现**：`GET /public/workers/:id` 与 `GET /worker/grade` 都走这里）
 *
 * - `nextGrade` 一律取 `current + 1`（含"4 → 5 需人工审核"这一档：进度要能显示"已经够门槛、等审核"）；
 * - 已到最高档（5）→ `nextGrade = null`，`remain = null`；
 * - `blockers` 与 `compareGradeRule` 的 `misses` **同源**（不另写一套文案，否则两处会各自演化）。
 */
export function buildGradeProgress(currentGrade: number, m: GradeMetrics): GradeProgress {
  const current = Number(currentGrade) || DEFAULT_WORKER_GRADE;
  const next = current >= 5 ? null : current + 1;
  const base = {
    currentGrade: current,
    currentGradeLabel: gradeLabel(current),
    currentGradeName: gradeName(current),
  };

  if (next === null) {
    return {
      ...base,
      nextGrade: null,
      nextGradeLabel: null,
      nextGradeName: null,
      needManualReview: false,
      hits: [],
      blockers: [],
      remain: null,
      readyNow: false,
    };
  }

  const rule = workerGradeRule(next);
  const cmp = rule ? compareGradeRule(rule, m) : { hits: [], misses: [] };
  const remain: GradeRemain = {
    completedOrders:
      rule?.minCompletedOrders == null ? 0 : Math.max(0, round2(rule.minCompletedOrders - m.completedOrders)),
    satisfiedRate:
      rule?.minSatisfiedRate == null
        ? 0
        : m.satisfiedRatePercent === null
          ? null
          : Math.max(0, round1(rule.minSatisfiedRate - m.satisfiedRatePercent)),
    ratingAvg:
      rule?.minRatingAvg == null ? 0 : Math.max(0, round2(rule.minRatingAvg - m.ratingAvg)),
    settlementAmount:
      rule?.minSettlementAmount == null
        ? 0
        : Math.max(0, round2(rule.minSettlementAmount - m.settlementAmount)),
    ratingSamples:
      rule?.minRatingAvg == null
        ? 0
        : Math.max(0, MIN_RATING_SAMPLES_FOR_GRADE - m.ratingSamples),
  };

  return {
    ...base,
    nextGrade: next,
    nextGradeLabel: gradeLabel(next),
    nextGradeName: gradeName(next),
    // 自动判定的天花板是 4 → 4 升 5 必须人工审核（`WORKER_GRADE_RULES` 里也标了 manualOnly）
    needManualReview: next > AUTO_MAX_GRADE,
    hits: cmp.hits,
    blockers: cmp.misses,
    remain,
    readyNow: cmp.misses.length === 0,
  };
}

/** 五维均分（五列 AVG 的均值；样本为 0 时返回 0 —— 调用方用 `samples` 判断"有没有数据"） */
export function ratingAvgOf(dims: { skill: number; emotion: number; stress: number; voice: number; shop: number }): number {
  const vals = [dims.skill, dims.emotion, dims.stress, dims.voice, dims.shop].map((v) => Number(v) || 0);
  return round2(vals.reduce((a, b) => a + b, 0) / vals.length);
}

/** 空指标（新打手 / 无任何数据时的兜底；**不编造任何数字**） */
export function emptyGradeMetrics(): GradeMetrics {
  return {
    completedOrders: 0,
    satisfiedRatePercent: null,
    ratingAvg: 0,
    ratingSamples: 0,
    settlementAmount: 0,
  };
}

/** 供管理端/审计读取的规则快照（不改表、不读库） */
export function gradeRuleSnapshot(): ReadonlyArray<WorkerGradeRule> {
  return WORKER_GRADE_RULES;
}
