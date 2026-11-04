import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { publicTakeOrderDivisionExistsSql } from '../division/public-division-scope';
import { WorkerGradeService } from '../rating/worker-grade.service';
import { ReviewService } from '../review/review.service';
import { User } from '../user/user.entity';
import { Worker } from './worker.entity';
import { DEFAULT_WORKER_GRADE } from './worker-grade.constants';

/** 找陪玩列表的一行（对外形状，**只含展示必需字段**，见类注释） */
export interface PublicPlayerItem {
  workerId: string;
  nickname: string;
  intro: string;
  avatarMediaId: string | null;
  backgroundMediaId: string | null;
  divisionId: string | null;
  divisionName: string | null;
  /** 接单次数（**生效值**：管理端设过展示值则为展示值，否则真实值） */
  completedOrders: number;
  /** 评价条数（**永远真实**，不提供覆盖） */
  reviewCount: number;
  /** 好评率：百分数字符串保留 1 位小数；**无评价时 null**（生效值同样走这条出口） */
  satisfiedRate: string | null;
  /**
   * 打手等级（1–5）+ LV 标签 + 中文名（2026-10-17 追加，负责人已审批）
   *
   * **列表只给这三个字段**：五维均分、样本数、升级进度一律进详情页
   * （`GET /public/workers/:id`）—— 列表要"一眼扫完"，堆五维会把名字/介绍挤没。
   * 名称与标签来自 `worker/worker-grade.constants.ts` 的**唯一常量表**（不在这里写中文）。
   */
  grade: number;
  gradeLabel: string;
  gradeName: string;
}

export interface PublicPlayersPage {
  list: PublicPlayerItem[];
  total: number;
  page: number;
  pageSize: number;
}

/**
 * 找陪玩名单（公开，**服务层唯一实现**）
 *
 * 为什么把这段从控制器搬进服务（2026-10-16 任务②）：
 * `GET /public/players` 与新的聚合接口 `GET /public/home` 的 `players` 子块**必须是同一份名单**。
 * 控制器里内联的查询无法被第二个入口复用 —— 一旦复制粘贴，就会出现
 * 「首页 10 条与找陪玩页第 1 页不一致」这类两套口径（本批次要消灭的正是它）。
 * 因此：**查询只此一处**，`PublicPlayersController` 与 `PublicHomeService` 都调 [list]。
 *
 * 口径（负责人 2026-10-03 硬规则 + 2026-10-15 追加 + 2026-10-16 生效值）：
 * - 列表**只返回 名字 + 介绍**（+ 头像/分部做展示）；禁：明星陪玩/大神/单考/空闲/忙碌/等级/评分/单价/语音时长；
 * - 卡片数值追加且**仅追加**：`completedOrders` / `reviewCount` / `satisfiedRate`（+ 分部显示名）；
 * - 数值口径**唯一一处** = `ReviewService.publicWorkerStats()`（单人接口与首页子块走同一个函数）；
 * - **无 N+1**：整页 id 一次带进 `IN (...)` 批量聚合（固定 2 条聚合 SQL，与 pageSize 无关），不逐行查。
 */
@Injectable()
export class PlayersService {
  constructor(
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    private readonly reviewService: ReviewService,
    /**
     * 等级读（2026-10-17）：`grade/gradeLabel/gradeName` 的**唯一出处**。
     * `batchGrades()` 是整页 `IN (...)` 一次查（固定 1 条 SQL），**不做逐行查**。
     */
    private readonly gradeService: WorkerGradeService,
  ) {}

  /**
   * 分页取名单（`page` / `pageSize` 由调用方用 `common/pagination` 解析后传入 —— 查询参数是不可信输入）
   *
   * @param q.divisionId 传分部 id = 只列出**该分部有接单权限**的打手（接单权限下沉到分部，负责人 2026-10-04）
   */
  async list(q: { divisionId?: string; page: number; pageSize: number }): Promise<PublicPlayersPage> {
    const { divisionId } = q;
    const p = q.page;
    const ps = q.pageSize;

    // 列表与总数**并行**发出（两条 SQL 之间没有任何数据依赖，串行纯属浪费一个 RTT ——
    // 高延迟链路上每一个 RTT 都是 245ms 级别，见本次任务背景）。
    const listQb = this.workerRepo
      .createQueryBuilder('w')
      .innerJoin(User, 'u', 'u.id = w.user_id')
      .select([
        'w.id AS workerId',
        'w.division_id AS divisionId',
        /**
         * 分部显示名（负责人 2026-10-15「分部副标」）。
         *
         * ⚠️ 刻意用**标量子查询**而不是 `LEFT JOIN division`（两条实测理由，2026-10-15）：
         * ① **别名会撞**：`publicTakeOrderDivisionExistsSql()` 内部**硬编码了别名 `d`**
         *    （`JOIN division d ON d.id = p.division_id`）。外层再起一个 `d` 会让**同一条 SQL 里出现两个 `d`**
         *    （内层遮蔽外层）——执行结果碰巧正确，但任何人读到 `d.name` / `d.status` 都得先判断指的是哪张表；
         *    这里用 `dv`，与内层 `d` 不同名，别名各管各的。
         * ② **计划与改动前逐行一致**：标量子查询版（`dv` 走 PRIMARY 的 1 行 eq_ref 回查）
         *    与"没有这一列的改动前 SQL"做 EXPLAIN 对照，**每一行相同**（含 `key`/`type`/`Extra`），
         *    即本次追加字段对既有执行计划**零影响**；对照数据见交付报告。
         *
         * 取值口径：与同一行返回的 `divisionId`（= `w.division_id`）**同源** —— 只按 id 取名字，
         * 刻意不额外加 `status = 1`：否则会出现"给了 id 却给不出名字"的错配，前端只能显示空位。
         * 列表**可见性**仍由下面那条 EXISTS（已上架分部的接单权限）决定，本字段只负责显示。
         */
        '(SELECT dv.name FROM division dv WHERE dv.id = w.division_id) AS divisionName',
        'u.nickname AS nickname',
        'u.intro AS intro',
        'u.avatar_media_id AS avatarMediaId',
      'u.background_media_id AS backgroundMediaId',
      ])
      .where('w.status = 1')
      // `w.can_take_order` 现在是「是否有任一分部接单权限」的派生汇总（写入时同步维护），
      // 用它可以先快速筛掉完全没授权的打手（命中 IDX_worker_can_take_order_status）；
      // 具体到某个分部的判定则走下面的 EXISTS（worker_division_permission）。
      .andWhere('w.can_take_order = 1')
      .andWhere('u.status = 1')
      /**
       * 「分部下架 = 其内容不再公开」（2026-10-08）：**公开名单只认已上架分部的接单权限**。
       *
       * 不传 `divisionId` 时也必须带上这条 —— 否则"只在已下架分部有权限"的打手仍会出现在
       * 找陪玩列表里（既抢不到单、也点不进那个分部，属于本次报障的同一类"下架了还显示"）。
       * 判定唯一一处：`division/public-division-scope.ts` 的 `publicTakeOrderDivisionExistsSql`
       * （与大厅/抢单的 `takeOrderDivisionExistsSql` **刻意分开**：那条只看权限、不看分部状态，未改动）。
       */
      .andWhere(publicTakeOrderDivisionExistsSql())
      /**
       * 按主键排序（`w.id`）。
       *
       * ⚠️ 口径更正（2026-10-15 实测，MySQL 8.4）：原注释写"命中 PRIMARY，无 filesort"
       * 只对**不含 EXISTS 的 SQL** 成立。带上 `EXISTS`（已上架分部的接单权限）后，优化器会做
       * **半连接物化**，EXPLAIN 首行出现 `Using temporary; Using filesort`（排序落在物化的
       * `d` 行上，`w` 自己仍走 PRIMARY/eq_ref，不是"按 w.id 排序退化成全表排序"）。
       * 这一点**改动前就存在**：本次追加字段前后做 EXPLAIN 对照，每一行 `type/key/Extra` 相同
       * （去掉 EXISTS 即恢复干净计划），因此**本次不需要加/改索引**；也刻意不动既有 WHERE 形态。
       */
      .orderBy('w.id', 'ASC')
      .offset((p - 1) * ps)
      .limit(ps);
    const totalQb = this.workerRepo
      .createQueryBuilder('w')
      .innerJoin(User, 'u', 'u.id = w.user_id')
      .where('w.status = 1')
      .andWhere('w.can_take_order = 1')
      .andWhere('u.status = 1')
      .andWhere(publicTakeOrderDivisionExistsSql());
    if (divisionId) {
      // 分部隔离（负责人 2026-10-04 硬规则）：只列出**该分部有接单权限**的打手。
      // 此前是 `w.division_id = :divisionId OR w.division_id IS NULL`（按打手自己的归属分部），
      // 后果：老板点「三角洲手游」也会看到只接端游的人，反之亦然。
      // 现在按 worker_division_permission 判定（接单权限下沉到分部），并与大厅/抢单同一口径；
      // 2026-10-08 起额外要求该分部**已上架** → 请求已下架分部时结果为空（与商品同口径）。
      const cond = publicTakeOrderDivisionExistsSql(':divisionId');
      listQb.andWhere(cond, { divisionId });
      totalQb.andWhere(cond, { divisionId });
    }
    const [rows, total] = await Promise.all([
      listQb.getRawMany<Record<string, unknown>>(),
      totalQb.getCount(),
    ]);

    // 三个数值 + 等级整页**一次**批量取（各 1–2 条聚合 SQL，与 pageSize 无关）。
    // 三个数值的口径实现只在 `ReviewService.publicWorkerStats`（`GET /public/workers/:id` 与 `/public/home`
    // 的 `players` 子块走的是**同一个函数**），等级同理只在 `WorkerGradeService.batchGrades` ——
    // 因此各入口**逐字一致**，不会各算一套。两者之间没有数据依赖 → 并行发出。
    const workerIds = rows.map((r) => String(r.workerId));
    const [statsMap, gradeMap] = await Promise.all([
      this.reviewService.publicWorkerStats(workerIds),
      this.gradeService.batchGrades(workerIds),
    ]);

    return {
      list: rows.map((r) => {
        const workerId = String(r.workerId);
        const stats = statsMap.get(workerId);
        // 等级三件套：`batchGrades` 对每个入参 id 都会给一条（无行 = 注册默认档），
        // 这里的兜底只为类型收窄，**不写任何档位字面量**（名字/标签的唯一出处在常量表）
        const gradeInfo = gradeMap.get(workerId) ?? this.gradeService.gradeShape(DEFAULT_WORKER_GRADE);
        return {
          workerId,
          // 只暴露两个业务字段：名字 + 介绍（其余为展示所需的头像/分部/归属）
          nickname: String(r.nickname ?? ''),
          intro: String(r.intro ?? ''),
          avatarMediaId: r.avatarMediaId == null ? null : String(r.avatarMediaId),
    backgroundMediaId: r.backgroundMediaId == null ? null : String(r.backgroundMediaId),
          divisionId: r.divisionId == null ? null : String(r.divisionId),
          // 分部显示名：**逐字回传 `division.name`，不做任何拼接/裁剪**
          // （线上 id=1 的 name 本身就是「和平精英 」＝尾随空格、没有「· 手游」，
          //   那是管理端填的数据，接口不替它修饰；打手未挂分部时为 null，不编空串）
          divisionName: r.divisionName == null ? null : String(r.divisionName),
          // 接单次数：**生效值**（管理端展示值优先，否则 worker_stats.completed_orders）
          completedOrders: stats?.completedOrders ?? 0,
          // 评价条数：order_review 中 hidden=0 的条数（永远真实）
          reviewCount: stats?.reviewCount ?? 0,
          // 好评率：百分数字符串保留 1 位小数；**无评价时 null**（不是 0、不是 100）
          satisfiedRate: stats?.satisfiedRate ?? null,
          // 等级三件套（2026-10-17）：数字 + LV 标签 + 中文名；五维/进度进详情页
          grade: gradeInfo.grade,
          gradeLabel: gradeInfo.gradeLabel,
          gradeName: gradeInfo.gradeName,
        };
      }),
      total,
      page: p,
      pageSize: ps,
    };
  }
}
