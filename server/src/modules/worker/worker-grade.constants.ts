/**
 * 打手等级 + 五维评分 —— **制度唯一出处**（负责人已审批，2026-10-17）
 *
 * 本文件是**唯一**能写死等级中文名与门槛数字的地方：
 * - 打手等级名（`初出 / 立足 / 扬名 / 称雄 / 宗师`）与 `LV1–LV5` 标签**只出现在这里**；
 *   service / controller / migration / 接口文案一律走 [gradeName] / [gradeLabel]，**禁止内联中文字面量**
 *   —— 以后改名只改一处。
 * - 门槛数字同表，**代码里不许出现第二份阈值**（判定算法 `modules/rating/worker-grade.rules.ts`
 *   只读本表；查询接口的"升级进度"也算自同一张表）。
 *
 * ⚠️ 边界（2026-10-17 负责人澄清）：「XX会员」（初识/知交/尊享/臻享/至尊会员）是**老板端会员体系**的
 * 名称，**与打手等级无关**；打手等级只有下面这五档，本文件不提供、也不许加任何"会员"命名。
 *
 * ## 等级表（负责人审批原文，逐字）
 *
 * | grade | LV 标签 | 名称 | 累计完成单 | 好评率 | 五维均分 | 结算累计 | 备注 |
 * |---|---|---|---|---|---|---|---|
 * | 1 | LV1 | 初出 | 0 | — | — | — | 注册默认 |
 * | 2 | LV2 | 立足 | ≥10 | ≥95% | ≥7.0 | — | 无投诉成立记录 |
 * | 3 | LV3 | 扬名 | ≥40 | ≥97% | ≥8.0 | ≥¥300 | |
 * | 4 | LV4 | 称雄 | ≥120 | ≥98% | ≥8.5 | ≥¥1,200 | |
 * | 5 | LV5 | 宗师 | ≥300 | ≥99% | ≥9.0 | ≥¥4,000 | **必须人工审核，不自动升** |
 *
 * ## 三条铁律（判定算法必须遵守，纯函数实现见 `worker-grade.rules.ts`）
 *
 * 1. **只升不降**：达成即升，**永不自动降级**；门槛不再满足时只"暂缓下一次升级"。
 * 2. **五维样本 < 10 条不参与升级判定**（防刷）：样本不足的均分**不参与判定**，
 *    且该情况下**不升任何档**（`.samples` 是硬门槛，见 `MIN_RATING_SAMPLES_FOR_GRADE`）。
 * 3. **grade 5（宗师）绝不由自动判定产出**（`manualOnly: true` + `AUTO_MAX_GRADE = 4`）：
 *    自动最高只到 LV4，宗师只能由超管走 `PUT /admin/workers/:id/grade` 人工设置。
 *
 * ## 「五维均分」口径
 *
 * `worker_rating` 五列**各自 AVG**（1–10 分）→ `worker_rating_agg.skill/emotion/stress/voice/shop`；
 * 升级门槛比较的是这五列的**均值**（`(skill+emotion+stress+voice+shop)/5`，两位小数），
 * **不对单个维度另设门槛**（审批表只有一个"五维均分"数字）。
 *
 * ⚠️ 五维中文名**未在审批表中给出**：接口只回英文字段名（`skill/emotion/stress/voice/shop`），
 * 中文仅出现在下面的注释里作为字面直译（技术 / 情绪价值 / 抗压 / 声音 / 店铺），
 * 若负责人另有定名，改注释即可，**不影响任何逻辑与接口字段**。
 *
 * **「好评率」数据源**：`order_review`（`hidden = 0`）实时聚合 —— 与老板端/公开详情
 * **同一个出口**（`ReviewService.workerStatsView().real.satisfiedRate`），
 * 刻意**不**用 `worker_stats.display_satisfied_rate`（展示值是运营人设数字，不参与升级判定）。
 */

/** 等级中文名 + LV 标签（**唯一一处**；改这里等于全站改名） */
export const WORKER_GRADES = [
  { grade: 1, label: 'LV1', name: '初出' },
  { grade: 2, label: 'LV2', name: '立足' },
  { grade: 3, label: 'LV3', name: '扬名' },
  { grade: 4, label: 'LV4', name: '称雄' },
  { grade: 5, label: 'LV5', name: '宗师' },
] as const;

/** 等级代号（1–5），用于校验与循环 */
export const WORKER_GRADE_CODES: readonly number[] = WORKER_GRADES.map((g) => g.grade);

/** 合法等级下界/上界（DTO 与 service 共用，避免各处再写 1/5 字面量） */
export const WORKER_GRADE_MIN = 1;
export const WORKER_GRADE_MAX = 5;

/** 注册默认等级（`worker_grade` 无行时也视为这一级） */
export const DEFAULT_WORKER_GRADE = 1;

/** 自动判定最高档：**LV5（宗师）永不自动给**（只能超管人工设置） */
export const AUTO_MAX_GRADE = 4;

/** 五维样本门槛：**< 10 条不参与升级判定**（防刷）；达到后才允许升档 */
export const MIN_RATING_SAMPLES_FOR_GRADE = 10;

/** 五维字段（顺序 = 接口/审计输出顺序；与 `worker_rating.r_*` / `worker_rating_agg` 列一一对应） */
export const RATING_DIMS = ['skill', 'emotion', 'stress', 'voice', 'shop'] as const;
export type RatingDim = (typeof RATING_DIMS)[number];

/** 五维单条评分取值范围（各 1–10 的整数） */
export const RATING_SCORE_MIN = 1;
export const RATING_SCORE_MAX = 10;

/** 五维评价正文上限（`worker_rating.r_comment varchar(200)`） */
export const RATING_COMMENT_MAX = 200;

/** 一档的升级门槛（`null` = 该档不设此项门槛） */
export interface WorkerGradeRule {
  grade: number;
  /** 累计完成单（`worker_stats.completed_orders`，**真实值**） */
  minCompletedOrders: number | null;
  /** 好评率（百分数 0–100，`order_review` 实时聚合） */
  minSatisfiedRate: number | null;
  /** 五维均分门槛（0–10） */
  minRatingAvg: number | null;
  /** 结算累计（元，`worker_stats.total_amount`） */
  minSettlementAmount: number | null;
  /** true = 只能人工设置（不参与自动判定） */
  manualOnly: boolean;
  /** 审批表「备注」列（**只做展示/审计，不参与自动判定**） */
  remark: string | null;
}

/** 门槛表（负责人审批原文；**改这里 = 改制度**，需负责人同意） */
export const WORKER_GRADE_RULES: readonly WorkerGradeRule[] = [
  {
    grade: 1,
    minCompletedOrders: null,
    minSatisfiedRate: null,
    minRatingAvg: null,
    minSettlementAmount: null,
    manualOnly: false,
    remark: '注册默认',
  },
  {
    grade: 2,
    minCompletedOrders: 10,
    minSatisfiedRate: 95,
    minRatingAvg: 7.0,
    minSettlementAmount: null,
    manualOnly: false,
    remark: '无投诉成立记录',
  },
  {
    grade: 3,
    minCompletedOrders: 40,
    minSatisfiedRate: 97,
    minRatingAvg: 8.0,
    minSettlementAmount: 300,
    manualOnly: false,
    remark: null,
  },
  {
    grade: 4,
    minCompletedOrders: 120,
    minSatisfiedRate: 98,
    minRatingAvg: 8.5,
    minSettlementAmount: 1200,
    manualOnly: false,
    remark: null,
  },
  {
    grade: 5,
    minCompletedOrders: 300,
    minSatisfiedRate: 99,
    minRatingAvg: 9.0,
    minSettlementAmount: 4000,
    manualOnly: true,
    remark: '必须人工审核，不自动升',
  },
];

/** 取某一档的中文名（**唯一出口**；非法档位回落 LV1 档，不抛错 —— 展示路径不该 500） */
export function gradeName(grade: number | string | null | undefined): string {
  const g = Number(grade);
  return WORKER_GRADES.find((x) => x.grade === g)?.name ?? WORKER_GRADES[0].name;
}

/** 取某一档的 LV 标签（**唯一出口**；非法档位回落 LV1 档） */
export function gradeLabel(grade: number | string | null | undefined): string {
  const g = Number(grade);
  return WORKER_GRADES.find((x) => x.grade === g)?.label ?? WORKER_GRADES[0].label;
}

/** 取某一档的门槛规则（非法档位 → null） */
export function workerGradeRule(grade: number | string | null | undefined): WorkerGradeRule | null {
  const g = Number(grade);
  return WORKER_GRADE_RULES.find((r) => r.grade === g) ?? null;
}
