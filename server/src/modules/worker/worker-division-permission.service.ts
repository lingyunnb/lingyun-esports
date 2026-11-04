import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, EntityManager, In, Repository } from 'typeorm';

import { Division } from '../division/division.entity';
import { Worker } from './worker.entity';
import { WorkerDivisionPermission } from './worker-division-permission.entity';

/** 打手在一个分部上的接单权限视图（工作端「我的」/大厅胶囊、管理端勾选框都用它） */
export type DivisionPermissionView = {
  divisionId: string;
  name: string;
  shortName: string;
  platform: string;
  platformLabel: string;
  canTakeOrder: boolean;
};

/** 单次授权变更留痕（写 operation_log 用） */
export type DivisionPermissionChange = {
  divisionId: string;
  name: string;
  before: boolean;
  after: boolean;
};

/**
 * 「该打手（别名 w）在该分部有接单权限」的 EXISTS 片段 —— **口径只有这一处**。
 *
 * 走 `IDX_wdp_division_take(division_id, can_take_order)`：由分部反查有权限的打手，
 * 供「指定护航员 / 找陪玩 / AI 推荐」这类"按分部挑人"的查询使用。
 * @param placeholder 参数占位符：QueryBuilder 用 `:divisionId`，裸 SQL 用 `?`
 */
export function takeOrderDivisionExistsSql(placeholder: string): string {
  return `EXISTS (SELECT 1 FROM worker_division_permission p WHERE p.worker_id = w.id AND p.division_id = ${placeholder} AND p.can_take_order = 1)`;
}

/**
 * 打手 × 分部 接单权限服务（负责人 2026-10-04）。
 *
 * 铁律（docs/04）：**接单权限每次请求实时查库**，本服务不做任何进程内缓存 ——
 * 管理端刚授的权，下一次大厅/抢单/接单请求立刻生效（实测用例 5 专门验证这一点）。
 *
 * 分工：
 * - `worker.can_take_order` = **派生汇总**（是否存在任一授权），写入时由本服务同步；
 * - 真正的判定读 `worker_division_permission`（本表）。
 */
@Injectable()
export class WorkerDivisionPermissionService {
  constructor(
    @InjectRepository(WorkerDivisionPermission) private readonly repo: Repository<WorkerDivisionPermission>,
    @InjectRepository(Division) private readonly divisionRepo: Repository<Division>,
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /** 事务内外统一入口：给了 em 就用事务连接（同一事务内读到自己写的行） */
  private permRepo(em?: EntityManager): Repository<WorkerDivisionPermission> {
    return em ? em.getRepository(WorkerDivisionPermission) : this.repo;
  }

  /** 该打手有接单权限的分部 id 列表（实时查库，无缓存） */
  async permittedDivisionIds(workerId: string, em?: EntityManager): Promise<string[]> {
    const rows = await this.permRepo(em).find({
      where: { workerId: String(workerId), canTakeOrder: 1 },
      select: ['divisionId'],
    });
    return rows.map((r) => String(r.divisionId));
  }

  /**
   * 单分部接单权限判定。
   *
   * `divisionId` 为空（订单/商品没挂分部）时**不做分部限制** —— 返回 true，
   * 由调用方先校验「全局是否有接单权限」。理由：无分部归属的历史/异常单若在这里被拒，
   * 就再也没人抢得动（大厅查询对这类单同样放宽，见 OrderService.workerHall）。
   */
  async hasTakeOrder(workerId: string, divisionId: string | null | undefined, em?: EntityManager): Promise<boolean> {
    if (divisionId === null || divisionId === undefined || `${divisionId}`.trim() === '') return true;
    const row = await this.permRepo(em).findOne({
      where: { workerId: String(workerId), divisionId: String(divisionId), canTakeOrder: 1 },
    });
    return !!row;
  }

  /** 分部名（中文提示用；查不到返回空串） */
  async divisionName(divisionId?: string | null): Promise<string> {
    if (!divisionId) return '';
    const d = await this.divisionRepo.findOne({ where: { id: String(divisionId) } });
    return d?.name ?? '';
  }

  /**
   * 服务端权威校验（抢单 / 确认派单等打手侧动作）：无该分部接单权限 → 403 + 中文消息。
   * @param message 由调用方给出文案模板，保证各入口措辞准确（抢单/接单/派单各不同）
   */
  async assertTakeOrder(
    workerId: string,
    divisionId: string | null | undefined,
    message: (divisionName: string) => string,
    em?: EntityManager,
  ): Promise<void> {
    if (await this.hasTakeOrder(workerId, divisionId, em)) return;
    const name = (await this.divisionName(divisionId)) || '该';
    throw new ForbiddenException(message(name));
  }

  /** 当前全部启用分部（按排序） */
  async enabledDivisions(): Promise<Division[]> {
    return this.divisionRepo.find({ where: { status: 1 }, order: { sortOrder: 'ASC', id: 'ASC' } });
  }

  /** 全部启用分部 id（管理端「全部授权」用） */
  async enabledDivisionIds(): Promise<string[]> {
    return (await this.enabledDivisions()).map((d) => String(d.id));
  }

  /**
   * 打手视角的全部启用分部 + 授权状态（工作端展示 + 大厅胶囊数据源）。
   * 未授权分部也返回（canTakeOrder=false），由客户端决定是"隐藏"还是"灰显"。
   */
  async listWithFlags(workerId: string, em?: EntityManager): Promise<DivisionPermissionView[]> {
    return this.buildViews(workerId, await this.enabledDivisions(), em);
  }

  /** 工作端按当前登录用户取（userId → worker 档案） */
  async listForUser(userId: string): Promise<{ list: DivisionPermissionView[]; permittedCount: number }> {
    const worker = await this.workerRepo.findOne({ where: { userId } });
    if (!worker) throw new NotFoundException('工作端不存在');
    const list = await this.listWithFlags(worker.id);
    return { list, permittedCount: list.filter((x) => x.canTakeOrder).length };
  }

  private async buildViews(workerId: string, divisions: Division[], em?: EntityManager): Promise<DivisionPermissionView[]> {
    const permitted = new Set(await this.permittedDivisionIds(workerId, em));
    return divisions.map((d) => ({
      divisionId: String(d.id),
      name: d.name,
      shortName: d.shortName,
      platform: d.platform,
      platformLabel: d.platformLabel,
      canTakeOrder: permitted.has(String(d.id)),
    }));
  }

  /**
   * 按分部授予/撤销接单权限（单分部）。
   * 返回变更前后值供 operation_log 留痕；同时同步 `worker.can_take_order` 汇总列。
   */
  async setDivision(
    workerId: string,
    divisionId: string,
    value: boolean,
  ): Promise<{ changes: DivisionPermissionChange[]; divisionIds: string[] }> {
    return this.apply(workerId, null, { [String(divisionId)]: value });
  }

  /** 批量替换（勾选集合语义）：传进来的授予，其余启用分部一律撤销 */
  async replaceDivisions(
    workerId: string,
    divisionIds: string[],
  ): Promise<{ changes: DivisionPermissionChange[]; divisionIds: string[] }> {
    const wanted = new Set(divisionIds.map((d) => String(d)));
    const current = await this.permittedDivisionIds(workerId);
    const target: Record<string, boolean> = {};
    for (const id of current) target[id] = wanted.has(id);
    for (const id of wanted) target[id] = true;
    return this.apply(workerId, null, target);
  }

  /** 追加/撤销若干分部（不触碰未列出的分部）；管理端"只动这一个"与"授权全部"共用 */
  private async apply(
    workerId: string,
    em: EntityManager | null,
    target: Record<string, boolean>,
  ): Promise<{ changes: DivisionPermissionChange[]; divisionIds: string[] }> {
    const ids = Object.keys(target);
    if (!ids.length) {
      return { changes: [], divisionIds: await this.permittedDivisionIds(workerId) };
    }
    // 分部必须真实存在（未知 id 直接 400，避免写入脏权限行）
    const divisions = await (em ? em.getRepository(Division) : this.divisionRepo).find({
      where: { id: In(ids.map((i) => String(i))) },
    });
    const nameOf = new Map(divisions.map((d) => [String(d.id), d.name]));
    const unknown = ids.filter((i) => !nameOf.has(String(i)));
    if (unknown.length) {
      throw new BadRequestException(`分部不存在：${unknown.join(',')}`);
    }

    const run = async (manager: EntityManager) => {
      const worker = await manager.findOne(Worker, { where: { id: String(workerId) } });
      if (!worker) throw new NotFoundException('工作端不存在');
      const repo = manager.getRepository(WorkerDivisionPermission);
      const rows = await repo.find({ where: { workerId: String(workerId) } });
      const rowOf = new Map(rows.map((r) => [String(r.divisionId), r]));
      const changes: DivisionPermissionChange[] = [];

      /**
       * 批量写入（2026-10-13 N+1 优化）：原先是**循环内逐行 `await repo.save(...)`** ——
       * 管理端一次勾选 N 个分部 = N 次写往返。现改为**固定 3 条语句封顶**
       * （授权 UPDATE / 撤销 UPDATE / 新建 INSERT，各自只在有内容时才发）。
       *
       * ⚠️ 语义逐字不变，三条不变量：
       * 1. **`changes` 的顺序与内容不变**：仍在下面同一个 `for (const id of ids)` 循环里
       *    按 `ids` 顺序 push，`before/after` 判定口径（`row.canTakeOrder === 1` vs
       *    `target[id] === true`）一字未改 —— 它同时是 `operation_log` 的留痕内容。
       * 2. **只对「授予」建行**：撤销一个不存在的行**不写无意义的 0 行**（原注释的刻意取舍）。
       * 3. **同一行在一次调用里只会被处理一次**：`ids = Object.keys(target)` 天然去重
       *    （对象键唯一），故"先收集后批量写"不会产生"同一 id 既授权又撤销"的歧义；
       *    批量 UPDATE 按主键 `id IN (...)` 定位，与逐行 `save(row)` 命中的是同一批行。
       *
       * `updated_at` 由列定义 `ON UPDATE CURRENT_TIMESTAMP(3)` 与 TypeORM 的 UpdateQueryBuilder
       * 共同维护（与 `save()` 一样会刷新），故"最后修改时间"照旧可审计。
       */
      const grantIds: string[] = []; // 已存在、且本次要置 1 的行
      const revokeIds: string[] = []; // 已存在、且本次要置 0 的行
      const toInsert: WorkerDivisionPermission[] = []; // 不存在、且本次要授予 → 建行

      for (const id of ids) {
        const before = rowOf.get(String(id))?.canTakeOrder === 1;
        const after = target[id] === true;
        if (before === after) continue;
        const row = rowOf.get(String(id));
        if (row) {
          if (after) grantIds.push(String(row.id));
          else revokeIds.push(String(row.id));
        } else {
          // 只对「授予」建行；撤销不存在的行不写无意义的 0 行
          if (after) {
            toInsert.push(repo.create({ workerId: String(workerId), divisionId: String(id), canTakeOrder: 1 }));
          }
        }
        changes.push({ divisionId: String(id), name: nameOf.get(String(id)) ?? '', before, after });
      }

      if (grantIds.length) await repo.update({ id: In(grantIds) }, { canTakeOrder: 1 });
      if (revokeIds.length) await repo.update({ id: In(revokeIds) }, { canTakeOrder: 0 });
      if (toInsert.length) await repo.insert(toInsert);

      // 汇总列同步（派生值：是否存在任一授权）
      const granted = await repo.count({ where: { workerId: String(workerId), canTakeOrder: 1 } });
      await manager.update(Worker, String(workerId), { canTakeOrder: granted > 0 ? 1 : 0 });
      const divisionIds = (await repo.find({ where: { workerId: String(workerId), canTakeOrder: 1 }, select: ['divisionId'] })).map(
        (r) => String(r.divisionId),
      );
      return { changes, divisionIds };
    };

    if (em) return run(em);
    return this.dataSource.transaction(run);
  }

  /** 管理端「全部授权 / 全部撤销」（旧的全局开关语义） */
  async setAll(workerId: string, value: boolean): Promise<{ changes: DivisionPermissionChange[]; divisionIds: string[] }> {
    return this.replaceDivisions(workerId, value ? await this.enabledDivisionIds() : []);
  }
}
