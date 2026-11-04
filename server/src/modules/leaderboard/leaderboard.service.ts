import { BadRequestException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, IsNull, Repository } from 'typeorm';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { publicOwnedDivisionVisibleSql } from '../division/public-division-scope';
import { Worker } from '../worker/worker.entity';
import { LeaderboardAdjustment } from './leaderboard-adjustment.entity';
import { LeaderboardEntry } from './leaderboard-entry.entity';
import { WorkerStats } from './worker-stats.entity';

/** 公开接口路径（写路径失效钩子必须与 `PublicCacheInterceptor` 登记的前缀逐字一致） */
const LEADERBOARD_PUBLIC_PATH = '/api/v1/public/leaderboard';

/** 周期解析：'2026-W38'（ISO 周）或 '2026-09'（月） */
export function parsePeriod(period: string): { start: Date; end: Date } {
  const weekMatch = /^(\d{4})-W(\d{1,2})$/.exec(period);
  if (weekMatch) {
    const year = Number(weekMatch[1]);
    const week = Number(weekMatch[2]);
    // ISO 周：第 1 周从该年第一个周四所在周的周一开始
    const jan4 = new Date(Date.UTC(year, 0, 4));
    const firstMonday = new Date(Date.UTC(year, 0, 4 - ((jan4.getUTCDay() + 6) % 7)));
    const start = new Date(firstMonday.getTime() + (week - 1) * 7 * 86400_000);
    return { start, end: new Date(start.getTime() + 7 * 86400_000) };
  }
  const monthMatch = /^(\d{4})-(\d{1,2})$/.exec(period);
  if (monthMatch) {
    const year = Number(monthMatch[1]);
    const month = Number(monthMatch[2]);
    return { start: new Date(Date.UTC(year, month - 1, 1)), end: new Date(Date.UTC(year, month, 1)) };
  }
  throw new BadRequestException('周期格式非法（示例：2026-W38 / 2026-09）');
}

/**
 * 「这笔结算单尚未被退款冲正」的判定片段 —— **全项目只此一处**（下面全站榜与分部榜共用）。
 *
 * ## 为什么需要它（真 bug，2026-10-06 修）
 *
 * 售后退款走 `OrderService.reverseSettlementAndRefund`：钱包按**原结算单金额**冲正
 * （`settlement_reversal` / `platform_commission_reversal`），
 * 而 `order_settlement` 行**刻意保留**（它是审计凭证，删了就无法回溯"这单结算过多少、按什么比例"）。
 *
 * 但 `recalc()` 原先**直接聚合 `order_settlement`**、完全没看冲正流水 →
 * **凡是退过款的单都会继续算进榜单**，打手名次与金额一起虚高。
 * 实证（修前 recalc 一次）：本已退干净的打手 167 仍以 `1单/88元` 上榜、打手 170 同上、
 * 打手 168 把已退款的 order 785 也算了进去（`6单/576元`，正确应为 `5单/476元`）。
 *
 * ## 判定口径
 *
 * 一次退款**必然**写入幂等键 `settlement-reversal:{orderId}:worker` 的流水（唯一约束
 * `UQ_wallet_txn_idem` 保证一单至多一条）。故「存在该 `order_id` 的 `settlement_reversal` 流水」
 * ⇔ 「这笔结算已被冲正」——与钱包回退、`worker_stats` 回退**同一把尺子**，不会出现三处口径打架。
 *
 * 用 `NOT EXISTS` 半连接而不是 JOIN：语义就是"排除"，不会因 JOIN 放大行数；
 * `wallet_transaction.order_id` 与 `change_type` 都有索引可用。
 */
const NOT_REVERSED_SQL = `NOT EXISTS (
         SELECT 1 FROM wallet_transaction wt
          WHERE wt.order_id = s.order_id AND wt.change_type = 'settlement_reversal'
       )`;

/** 当前周期串 */
export function currentPeriod(kind: 'week' | 'month'): string {
  const now = new Date();
  if (kind === 'month') {
    return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
  }
  // ISO 周
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((d.getTime() - yearStart.getTime()) / 86400_000 + 1) / 7);
  return `${d.getUTCFullYear()}-W${week}`;
}

/**
 * 排行榜服务（M7，docs/待确认事项默认先行）：
 * - 口径：完成订单数 + 总金额（默认），榜单按有效金额（真实金额 + 人工调整）排序
 * - 榜单快照：管理员手动/定时 recalc（结算流水聚合）；调整留痕可审计
 */
@Injectable()
export class LeaderboardService {
  constructor(
    @InjectRepository(WorkerStats) private readonly statsRepo: Repository<WorkerStats>,
    @InjectRepository(LeaderboardEntry) private readonly entryRepo: Repository<LeaderboardEntry>,
    @InjectRepository(LeaderboardAdjustment) private readonly adjustRepo: Repository<LeaderboardAdjustment>,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /**
   * 榜单快照写入后立刻失效公开接口的进程内微缓存（**2026-10-08 缺口修复**）
   *
   * `GET /public/leaderboard` 挂在 `PublicCacheInterceptor` 的 30s 微缓存下，
   * 而榜单模块此前**没有写入侧失效钩子** —— 管理端「重算榜单」或人工调整后，
   * 公开榜单最长 30s 还是旧名次/旧金额。
   *
   * 口径与 `division` / `product` / `banner` 既有实现一致：
   * **内容随管理端写入变化的数据，写入时必须配失效钩子**。
   * 唯一写入口是 [recalc]（[adjust] 内部也走它），故只需在 recalc 末尾调用：
   * ⚠️ **新增任何榜单快照写路径都必须调用本函数**。
   */
  private invalidatePublicLeaderboardCache(): void {
    PublicCacheInterceptor.invalidate(LEADERBOARD_PUBLIC_PATH);
  }

  /** 结算事务内调用：累计打手统计（总单/完成单/总金额），失败不阻断结算 */
  async bumpWorkerStats(workerId: string, orderAmount: number): Promise<void> {
    await this.dataSource.query(
      `INSERT INTO worker_stats (worker_id, total_orders, completed_orders, total_amount)
       VALUES (?, 1, 1, ?)
       ON DUPLICATE KEY UPDATE total_orders = total_orders + 1, completed_orders = completed_orders + 1, total_amount = total_amount + ?`,
      [workerId, orderAmount, orderAmount],
    );
  }

  async workerStats(workerId: string) {
    return this.statsRepo.findOne({ where: { workerId } });
  }

  /** 按 user id 查 worker 档案 id */
  async workerIdByUserId(userId: string): Promise<string | null> {
    const rows: Array<{ id: string }> = await this.dataSource.query(
      'SELECT id FROM worker WHERE user_id = ? LIMIT 1',
      [userId],
    );
    return rows[0]?.id ?? null;
  }

  /** 重算榜单（结算流水聚合 + 人工调整，按有效金额排名写快照） */
  /**
   * 重算榜单（负责人 2026-10-03：同时产出**全站榜**与**分部榜**）
   *
   * 规则：
   * - 全站榜：division_id = NULL，覆盖周期内全部结算
   * - 分部榜：按订单所属分部独立排名（客户端榜单页按分部切换）
   * - 幂等：先删除该周期全部快照再写入（period 维度覆盖）
   */
  async recalc(period: string): Promise<{ entries: number; divisions: number }> {
    const { start, end } = parsePeriod(period);
    // 全站：worker 维度合计（**排除已退款冲正的结算**，见 NOT_REVERSED_SQL）
    const rows: Array<{ worker_id: string; cnt: string; amt: string }> = await this.dataSource.query(
      `SELECT s.worker_id, COUNT(*) AS cnt, SUM(s.order_amount) AS amt
       FROM order_settlement s WHERE s.created_at >= ? AND s.created_at < ? AND ${NOT_REVERSED_SQL}
       GROUP BY s.worker_id`,
      [start, end],
    );
    // 分部：worker × division 维度合计（仅统计已挂分部的订单；同样排除已冲正的结算）
    const divRows: Array<{ worker_id: string; division_id: string; cnt: string; amt: string }> = await this.dataSource.query(
      `SELECT s.worker_id, o.division_id, COUNT(*) AS cnt, SUM(s.order_amount) AS amt
       FROM order_settlement s
       JOIN \`order\` o ON o.id = s.order_id
       WHERE s.created_at >= ? AND s.created_at < ? AND o.division_id IS NOT NULL AND ${NOT_REVERSED_SQL}
       GROUP BY s.worker_id, o.division_id`,
      [start, end],
    );
    const adjustments = await this.adjustRepo.find({ where: { period } });
    const adjMap = new Map<string, number>();
    for (const a of adjustments) {
      adjMap.set(a.workerId, (adjMap.get(a.workerId) ?? 0) + a.amountDelta);
    }

    // 覆盖写入（period 维度幂等；含全站与各分部）
    await this.entryRepo.delete({ period });

    /**
     * 批量写入（2026-10-13 N+1 优化）：原先是**逐行 `await entryRepo.save(create(...))`** ——
     * 每行一个 INSERT 往返，1000 打手 × 3 分部 ≈ 4000 次往返/次重算。
     * 现改为**一次性 `insert()`**（TypeORM 会自动按 `maxQueryParameters` 分块），
     * 行内容、行顺序、`rank` 计算、`created_at` 取值全部**逐字不变**（见下）。
     *
     * ⚠️ 三条不变量，改动时不许破坏：
     * 1. **必须显式写 `createdAt: new Date()`**：`@CreateDateColumn` 的默认值来自 DDL
     *    （`DEFAULT CURRENT_TIMESTAMP(3)`），而 `InsertQueryBuilder` **不会**为 `createDate`
     *    列生成 SQL 表达式（TypeORM 源码里那段是注释掉的）→ 不显式给值就会整批落成 NULL，
     *    而该列是 `NOT NULL`。这里刻意用同一个 `now` 给整批，与原先"同一瞬间连续 save"
     *    的时间戳语义等价（原先每行差几毫秒，现在完全相同 —— 两者都是"本次重算的时间"）。
     * 2. **`rank` 的计算与顺序不变**：排序键仍是 `effective DESC, completedOrders DESC`
     *    （`effective = totalAmount + 人工调整`，**不入库**，只用于排名），
     *    全站榜 rank 从 1 连续递增，各分部榜**各自**从 1 递增（原样保留）。
     * 3. **`divisionId: null`（全站榜）必须显式写**：`insert()` 不像 `save()` 那样会替你把
     *    `null` 当成"用列默认值"，写进去就是 SQL NULL —— 正是全站榜要的语义。
     */
    const now = new Date();
    let rank = 1;
    const globalSorted = rows
      .map((r) => ({
        workerId: r.worker_id,
        completedOrders: Number(r.cnt),
        totalAmount: Number(r.amt),
        effective: Number(r.amt) + (adjMap.get(r.worker_id) ?? 0),
      }))
      .sort((a, b) => b.effective - a.effective || b.completedOrders - a.completedOrders);
    const globalEntities: LeaderboardEntry[] = [];
    for (const e of globalSorted) {
      globalEntities.push(
        this.entryRepo.create({
          period,
          workerId: e.workerId,
          divisionId: null,
          completedOrders: e.completedOrders,
          totalAmount: e.totalAmount,
          rank,
          createdAt: now,
        }),
      );
      rank += 1;
    }
    if (globalEntities.length) await this.entryRepo.insert(globalEntities);

    // 分部榜
    const byDivision = new Map<string, typeof divRows>();
    for (const r of divRows) {
      const list = byDivision.get(r.division_id) ?? [];
      list.push(r);
      byDivision.set(r.division_id, list);
    }
    const divisionEntities: LeaderboardEntry[] = [];
    for (const [divisionId, list] of byDivision) {
      const sorted = list
        .map((r) => ({
          workerId: r.worker_id,
          completedOrders: Number(r.cnt),
          totalAmount: Number(r.amt),
          effective: Number(r.amt) + (adjMap.get(r.worker_id) ?? 0),
        }))
        .sort((a, b) => b.effective - a.effective || b.completedOrders - a.completedOrders);
      let dRank = 1;
      for (const e of sorted) {
        divisionEntities.push(
          this.entryRepo.create({
            period,
            workerId: e.workerId,
            divisionId,
            completedOrders: e.completedOrders,
            totalAmount: e.totalAmount,
            rank: dRank,
            createdAt: now,
          }),
        );
        dRank += 1;
      }
    }
    if (divisionEntities.length) await this.entryRepo.insert(divisionEntities);
    // 快照已覆盖写入（全站 + 分部）→ 公开榜单微缓存立即失效（管理端"重算/调整"改完下一次请求即生效）
    this.invalidatePublicLeaderboardCache();
    return { entries: globalSorted.length, divisions: byDivision.size };
  }

  /** 榜单列表（含昵称与调整合计；无快照时自动重算，保证首屏不为空；按分部取榜） */
  async list(period: string, divisionId?: string) {
    let rows = await this.queryBoardRows(period, divisionId);
    if (rows.length === 0) {
      await this.recalc(period);
      rows = await this.queryBoardRows(period, divisionId);
    }
    return rows.map((r) => ({
      rank: Number(r.rank),
      workerId: r.worker_id,
      nickname: r.nickname,
      workerNo: r.worker_no,
      completedOrders: Number(r.completed_orders),
      totalAmount: Number(r.total_amount),
      adjustment: Number(r.adj ?? 0),
      effectiveAmount: Number(r.total_amount) + Number(r.adj ?? 0),
    }));
  }

  /**
   * **公开榜单输出形状的唯一实现**（`GET /public/leaderboard` 与 `GET /public/home` 的 `leaderboard` 子块共用）
   *
   * 为什么放服务层（2026-10-16 任务②）：聚合接口要"周榜前 N 条"，而榜单的**对外字段裁剪**
   * （只给 名次/名字/工号/单数/金额，**不给 `workerId`/调整明细**）原先内联在控制器里 ——
   * 复制一份就等于把"公开暴露哪些字段"这条规则写两遍，迟早分叉。
   *
   * 展示口径（负责人硬规则）：**每行只有 名次 + 名字 + 数值**（头像由客户端用昵称首字生成），
   * 不写分部、不带"明星/单考/空闲"等标签；分部由上方胶囊（`?divisionId=`）决定。
   * `amount` = 有效金额（总金额 + 人工调整合计），与榜单页完全一致。
   */
  async publicBoard(q: { kind?: string; divisionId?: string; period?: string }) {
    const kind: 'week' | 'month' = q.kind === 'month' ? 'month' : 'week';
    const period = String(q.period ?? '').trim() || currentPeriod(kind);
    const list = await this.list(period, q.divisionId);
    return {
      period,
      divisionId: q.divisionId ?? null,
      list: list.map((r) => ({
        rank: r.rank,
        // 只给展示所需：名字 + 数值（头像由客户端用昵称首字生成）
        nickname: r.nickname,
        workerNo: r.workerNo,
        completedOrders: r.completedOrders,
        amount: r.effectiveAmount,
      })),
    };
  }

  /**
   * 榜单行查询
   * @param divisionId 传分部 id 取**分部榜**；不传取**全站榜**（division_id IS NULL，避免与分部行重复）
   */
  private async queryBoardRows(period: string, divisionId?: string): Promise<Array<{
    id: string; worker_id: string; completed_orders: number; total_amount: number; rank: number;
    nickname: string; worker_no: string; adj: string | null;
  }>> {
    /**
     * 「分部下架 = 其内容不再公开」（2026-10-08）：**已下架分部的分部榜不再下发**。
     *
     * 条件追加在**唯一一处**（`division/public-division-scope.ts` 的 `publicOwnedDivisionVisibleSql`）：
     * - 全站榜（`division_id IS NULL`）走第一个析取分支 → 语义**逐字不变**（历史金额不会被抹掉）；
     * - 传了 `?divisionId=<已下架分部>` → EXISTS 不成立 → 空榜（与 `/public/products`、`/public/players` 同口径）。
     *
     * 榜单快照表 `leaderboard_entry` 里 2/3/6 等已下架分部的历史快照**不删**（保留可回溯），
     * 只是公开读路径不再下发。
     */
    const divisionVisible = publicOwnedDivisionVisibleSql('e.division_id');
    return this.dataSource.query(
      `SELECT e.id, e.worker_id, e.completed_orders, e.total_amount, e.rank,
              u.nickname, w.worker_no,
              (SELECT SUM(amount_delta) FROM leaderboard_adjustment a WHERE a.period = e.period AND a.worker_id = e.worker_id) AS adj
       FROM leaderboard_entry e
       JOIN worker w ON w.id = e.worker_id
       JOIN user u ON u.id = w.user_id
       WHERE e.period = ? AND ${divisionId ? 'e.division_id = ?' : 'e.division_id IS NULL'} AND ${divisionVisible}
       ORDER BY e.rank ASC
       LIMIT 100`,
      divisionId ? [period, divisionId] : [period],
    );
  }

  /** 人工调整（docs/待确认事项：允许，调整留痕可审计；权限 admin:leaderboard:adjust） */
  async adjust(period: string, workerId: string, amountDelta: number, reason: string, adminUserId: string) {
    if (!Number.isInteger(amountDelta) || amountDelta === 0) {
      throw new BadRequestException('调整金额必须为非零整数');
    }
    const worker = await this.dataSource.getRepository(Worker).findOne({ where: { id: workerId } });
    if (!worker) throw new NotFoundException('工作端不存在');
    await this.adjustRepo.save(
      this.adjustRepo.create({ period, workerId, amountDelta, reason: (reason || '').slice(0, 255), adminUserId }),
    );
    await this.recalc(period);
    return { ok: true };
  }

  async adjustments(period: string) {
    const rows: Array<{
      id: string; worker_id: string; amount_delta: number; reason: string; created_at: Date; nickname: string;
    }> = await this.dataSource.query(
      `SELECT a.id, a.worker_id, a.amount_delta, a.reason, a.created_at, u.nickname
       FROM leaderboard_adjustment a
       JOIN worker w ON w.id = a.worker_id
       JOIN user u ON u.id = w.user_id
       WHERE a.period = ?
       ORDER BY a.id DESC`,
      [period],
    );
    return rows.map((r) => ({
      id: r.id, workerId: r.worker_id, nickname: r.nickname,
      amountDelta: Number(r.amount_delta), reason: r.reason, createdAt: r.created_at,
    }));
  }

  /** 工作端：我的排名 */
  /**
   * 我的排名（默认取**全站榜**行：division_id IS NULL）
   *
   * 负责人 2026-10-03 引入分部榜后，同一 worker 在同一周期可能存在多条快照
   * （1 条全站 + 每分部 1 条），必须显式过滤，否则会取到分部行导致名次错乱。
   */
  async myEntry(workerId: string, period: string, divisionId?: string) {
    const entry = await this.entryRepo.findOne({
      where: divisionId ? { period, workerId, divisionId } : { period, workerId, divisionId: IsNull() },
    });
    if (!entry) return null;
    const adj = await this.adjustRepo
      .createQueryBuilder('a')
      .select('COALESCE(SUM(a.amount_delta), 0)', 's')
      .where('a.period = :period AND a.worker_id = :workerId', { period, workerId })
      .getRawOne();
    return {
      rank: entry.rank,
      completedOrders: entry.completedOrders,
      totalAmount: entry.totalAmount,
      adjustment: Number(adj?.s ?? 0),
      effectiveAmount: entry.totalAmount + Number(adj?.s ?? 0),
    };
  }
}
