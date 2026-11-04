import { ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import * as bcrypt from 'bcryptjs';
import { randomInt } from 'crypto';
import { DataSource, EntityManager, Repository } from 'typeorm';
import { Wallet } from '../wallet/wallet.entity';
import { Worker } from '../worker/worker.entity';
import { WorkerDivisionPermissionService } from '../worker/worker-division-permission.service';
import { User } from '../user/user.entity';
import { BindingReleaseService } from '../auth/binding-release.service';
import { ReleaseSink } from '../auth/worker-binding-release';
import { CreateWorkerDto, UpdateWorkerDto, UpdateWorkerPermissionDto } from './dto/worker-admin.dto';

/**
 * 工作端管理（阶段 9，docs/04）：
 * - 创建账号 = user(role=worker) + worker 档案（事务）
 * - 接单（**按分部**，负责人 2026-10-04）/ 客服权限独立授予/取消（admin:worker:permission，默认仅超管）
 * - 权限变更立即生效：所有接单/客服接口每次请求实时查库，无缓存
 * - 停用（status=2，`update` / `setPlayersProfile` 两个写入口）**顺手解绑**老板↔打手绑定（负责人 2026-10-06 裁决），
 *   并**按 binding_id 吊销 companion 令牌 + 断开其 WS + 写 identity 审计**（安全审计 F1-b / F4）
 */
@Injectable()
export class WorkerAdminService {
  constructor(
    @InjectRepository(User) private readonly userRepo: Repository<User>,
    @InjectRepository(Worker) private readonly workerRepo: Repository<Worker>,
    @InjectDataSource() private readonly dataSource: DataSource,
    /** 分部接单权限（打手 × 分部；本服务只做管理端写入与展示，判定在接单侧实时查库） */
    private readonly divisionPerm: WorkerDivisionPermissionService,
    /** 停用即释放绑定（置 unbound + 吊销 companion 令牌 + 审计 + 断开 WS）——两个入口共用同一实现 */
    private readonly bindingRelease: BindingReleaseService,
  ) {}

  async list(page: number, pageSize: number, keyword: string) {
    const qb = this.dataSource
      .createQueryBuilder(Worker, 'w')
      .innerJoin(User, 'u', 'u.id = w.user_id')
      .select([
        'w.id AS id',
        'u.id AS userId',
        'u.username AS username',
        'u.uid AS uid',
        'u.nickname AS nickname',
        'u.intro AS intro',
        'w.division_id AS divisionId',
        'w.worker_no AS workerNo',
        'w.real_name AS realName',
        'w.phone AS phone',
        'w.can_take_order AS canTakeOrder',
        'w.can_serve_customer AS canServeCustomer',
        'w.status AS status',
        'w.created_at AS createdAt',
      ]);
    if (keyword) {
      qb.where('u.username LIKE :kw OR u.nickname LIKE :kw OR w.worker_no LIKE :kw', { kw: `%${keyword}%` });
    }
    const total = await qb.clone().select('COUNT(1) AS cnt').getRawOne();
    const list = await qb
      .orderBy('w.id', 'DESC')
      .offset((page - 1) * pageSize)
      .limit(pageSize)
      .getRawMany();
    // 分部接单权限（负责人 2026-10-04）：管理端「接单权限」列按分部勾选，需要每行带上已授权分部 id。
    // 一次 IN 查询取回本页所有打手的授权，避免 N+1。
    const ids = list.map((r) => String((r as { id: unknown }).id));
    const grantedByWorker = new Map<string, string[]>();
    if (ids.length) {
      const rows: Array<{ worker_id: string; division_id: string }> = await this.dataSource.query(
        `SELECT worker_id, division_id FROM worker_division_permission WHERE can_take_order = 1 AND worker_id IN (?)`,
        [ids],
      );
      for (const r of rows) {
        const key = String(r.worker_id);
        const arr = grantedByWorker.get(key) ?? [];
        arr.push(String(r.division_id));
        grantedByWorker.set(key, arr);
      }
    }
    return {
      list: list.map((r) => ({ ...r, divisionPermissionIds: grantedByWorker.get(String((r as { id: unknown }).id)) ?? [] })),
      total: Number(total?.cnt ?? 0),
      page,
      pageSize,
    };
  }

  async create(dto: CreateWorkerDto) {
    const exists = await this.userRepo.findOne({ where: { username: dto.username } });
    if (exists) {
      throw new ConflictException('账号已存在');
    }
    const workerNoExists = await this.workerRepo.findOne({ where: { workerNo: dto.workerNo } });
    if (workerNoExists) {
      throw new ConflictException('工号已存在');
    }

    return this.dataSource.transaction(async (em) => {
      const user = await em.save(
        em.create(User, {
          username: dto.username,
          uid: await this.generateUid(em),
          passwordHash: await bcrypt.hash(dto.password, 10),
          nickname: dto.nickname || dto.username,
          role: 'worker',
          status: 1,
        }),
      );
      const worker = await em.save(
        em.create(Worker, {
          userId: user.id,
          workerNo: dto.workerNo,
          realName: dto.realName ?? null,
          phone: dto.phone ?? null,
          canTakeOrder: 0, // 默认无接单权限（铁律，docs/04）
          canServeCustomer: 0, // 默认无客服权限
          status: 1,
        }),
      );
      // 打手收益钱包（订单结算分成入账账户，与账号同事务创建；比例见 system_setting.platform_commission_rate）
      await em.save(em.create(Wallet, { userId: user.id, balance: 0 }));
      // id 语义统一为 worker.id（与列表/编辑/权限接口一致）
      return { id: worker.id, userId: user.id, username: user.username, workerNo: dto.workerNo };
    });
  }

  /**
   * 编辑工作端档案（真实姓名/电话/状态）。
   *
   * **停用即解绑**（负责人 2026-10-06 裁决）：`status=2`（停用）时顺手把该打手的 active 绑定置
   * `unbound`（写 `unbound_at`，保留历史行）—— 与「封禁即解绑」（`UserAdminService.ban`）同一条规则，
   * 两个入口共用 `releaseWorkerBindings`，不允许只在一个入口生效。
   * 语义：打手档案停用后伴随会话立即 401（守卫每请求校验 worker.status），绑定也要同步落到 unbound，
   * 否则老板侧 `GET /user/identity` 仍显示"已绑定"。**重新启用不会自动恢复绑定**（需老板重新输密码绑定）。
   * 本路径无事务，按裁决不为它新开事务：同一请求内同步执行。
   *
   * 安全审计 F1-b / F4：释放走 `BindingReleaseService.releaseWorkerSide()` —— 除置 unbound 外，
   * 还**按 `binding_id` 吊销该绑定的 companion 令牌**（审计实测：只 UPDATE 绑定行时，
   * "HTTP 已 401 而 WS 仍在收消息全文"）并写 identity 审计（谁/哪个 bindingId/两侧 id/来源/IP/UA/时间）。
   */
  async update(id: string, dto: UpdateWorkerDto, actor?: ReleaseActor) {
    const worker = await this.workerRepo.findOne({ where: { id } });
    if (!worker) {
      throw new NotFoundException('工作端不存在');
    }
    if (dto.realName !== undefined) worker.realName = dto.realName;
    if (dto.phone !== undefined) worker.phone = dto.phone;
    if (dto.status !== undefined) worker.status = dto.status;
    await this.workerRepo.save(worker);
    // 生效状态为「停用」→ 释放绑定（幂等：没有 active 行时零写入）
    const released = Number(worker.status) === 2 ? await this.bindingRelease.releaseWorkerSide(worker.userId, this.sinkOf(actor)) : null;
    return { ok: true, releasedBindings: released?.total ?? 0 };
  }

  /**
   * 授予/取消接单（按分部）或客服权限；返回变更前后值供操作日志留痕。
   *
   * 接单权限（负责人 2026-10-04）三种形态：
   * - 带 `divisionId`：只动该分部（管理端三个分部开关各自调用）
   * - 带 `divisionIds`：按勾选集合整体替换
   * - 都不带：旧的全局语义（授予 = 全部启用分部；撤销 = 全部撤销）
   * `worker.can_take_order` 由 [WorkerDivisionPermissionService] 同步为「是否有任一授权」的派生汇总。
   */
  async updatePermission(id: string, dto: UpdateWorkerPermissionDto) {
    const worker = await this.workerRepo.findOne({ where: { id } });
    if (!worker) {
      throw new NotFoundException('工作端不存在');
    }
    // 客服权限：与接单权限完全独立，且**不区分分部**（客服接待不属于某个游戏分部）
    if (dto.type === 'customer') {
      const before = worker.canServeCustomer;
      worker.canServeCustomer = dto.value ? 1 : 0;
      await this.workerRepo.save(worker);
      return {
        ok: true,
        type: dto.type,
        before: before === 1,
        after: dto.value,
        beforeDivisionIds: [] as string[],
        divisionIds: [] as string[],
        changes: [] as Array<{ divisionId: string; name: string; before: boolean; after: boolean }>,
      };
    }
    const beforeAggregate = worker.canTakeOrder === 1;
    const beforeDivisionIds = await this.divisionPerm.permittedDivisionIds(worker.id);
    const result =
      dto.divisionIds !== undefined
        ? await this.divisionPerm.replaceDivisions(worker.id, dto.divisionIds)
        : dto.divisionId
          ? await this.divisionPerm.setDivision(worker.id, dto.divisionId, dto.value)
          : await this.divisionPerm.setAll(worker.id, dto.value);
    // 汇总列已被同步，回读一次给前端/审计用（派生值，不是权威来源）
    const after = await this.workerRepo.findOne({ where: { id } });
    return {
      ok: true,
      type: dto.type,
      before: beforeAggregate,
      after: after?.canTakeOrder === 1,
      beforeDivisionIds,
      divisionIds: result.divisionIds,
      changes: result.changes,
    };
  }

  /** 读取陪玩资料（介绍 + 归属分部），用于变更留痕 */
  async getPlayersProfile(id: string) {
    const worker = await this.workerRepo.findOne({ where: { id } });
    if (!worker) throw new NotFoundException('工作端不存在');
    const user = await this.userRepo.findOne({ where: { id: worker.userId } });
    return { intro: user?.intro ?? '', divisionId: worker.divisionId, status: worker.status };
  }

  /**
   * 设置陪玩资料（负责人 2026-10-03 硬规则：管理端可改介绍）
   *
   * 「找陪玩」列表只显示 **名字 + 介绍**；同时可设置归属分部。
   *
   * ⚠️ **2026-10-17 改定：介绍的主写入口是打手自己**（`PUT /worker/profile`，
   * 见 `modules/worker/worker-profile.service.ts`）。本接口**保留**，作为负责人随时兜底改写的入口
   * （管理端仍可写 0–200 字，比打手的 2–120 字更宽 —— 兜底就该比自助宽）。
   *
   * **两条路径互不覆盖靠"定列更新"**：这里原来用 `userRepo.save(user)` 写**整个实体**，
   * 它会把加载那一刻的 `intro` 连同昵称/头像等全部列一起写回 —— 若打手在"管理端打开编辑页"
   * 与"管理员点保存"之间用自己的接口改了简介，管理端这一次保存会把它**静默回滚**（lost update）。
   * 现在只 UPDATE `intro` / `intro_updated_by` 两列：管理端没动简介时（`dto.intro === undefined`）
   * **一行都不写**，打手刚写的文案原样保留；管理端动简介时按管理端口径覆盖（这正是兜底的含义），
   * 并把 `intro_updated_by` 记为管理员 id（与打手自写时置 NULL 形成区分，见 worker-profile.service 注释）。
   */
  async setPlayersProfile(id: string, dto: { intro?: string; divisionId?: string; status?: number }, adminUserId: string, actor?: ReleaseActor) {
    const worker = await this.workerRepo.findOne({ where: { id } });
    if (!worker) throw new NotFoundException('工作端不存在');
    const user = await this.userRepo.findOne({ where: { id: worker.userId } });
    if (!user) throw new NotFoundException('账号不存在');

    if (dto.intro !== undefined) {
      user.intro = (dto.intro ?? '').slice(0, 200);
      user.introUpdatedBy = adminUserId;
      // 定列更新（不是 save(user)）：只碰这两列，不覆盖打手/其它入口刚写的内容
      await this.userRepo
        .createQueryBuilder()
        .update(User)
        .set({ intro: user.intro, introUpdatedBy: user.introUpdatedBy })
        .where('id = :id', { id: user.id })
        .execute();
    }
    if (dto.divisionId !== undefined) {
      worker.divisionId = dto.divisionId === '' || dto.divisionId === '0' ? null : dto.divisionId;
    }
    if (dto.status !== undefined) {
      worker.status = dto.status === 2 ? 2 : 1;
    }
    await this.workerRepo.save(worker);
    // 停用即解绑（负责人 2026-10-06 裁决）：与 PUT /admin/workers/:id 同一规则，
    // 且共用 `BindingReleaseService`（吊销 companion 令牌 + 审计 + 断开 WS，F1-b/F4），见 update() 注释
    const released = Number(worker.status) === 2
      ? await this.bindingRelease.releaseWorkerSide(worker.userId, this.sinkOf(actor, adminUserId))
      : null;
    return { ok: true, intro: user.intro, divisionId: worker.divisionId, status: worker.status, releasedBindings: released?.total ?? 0 };
  }

  /** 释放绑定的审计上下文（F4：来源=打手停用；触发者=管理员） */
  private sinkOf(actor?: ReleaseActor, fallbackAdminId?: string): ReleaseSink {
    const adminUserId = actor?.adminUserId ?? fallbackAdminId ?? null;
    return {
      source: 'worker-disabled',
      actorUserId: adminUserId,
      actorLabel: adminUserId ? `admin:${adminUserId}` : null,
      ip: actor?.ip ?? null,
      userAgent: actor?.userAgent ?? null,
    };
  }

  private async generateUid(em: EntityManager): Promise<string> {
    for (let i = 0; i < 5; i++) {
      const uid = `U${randomInt(1_000_000_000, 10_000_000_000)}`;
      const exists = await em.findOne(User, { where: { uid } });
      if (!exists) {
        return uid;
      }
    }
    throw new ConflictException('ID 生成失败，请重试');
  }
}

/**
 * 释放绑定的触发者上下文（审计 F4）+ 请求侧证据（IP/UA）：
 * 由控制器从 `@CurrentUser()` / `@Req()` 取，打手停用两个入口都传进来。
 */
export interface ReleaseActor {
  /** 管理员账号的 user id */
  adminUserId?: string | null;
  ip?: string | null;
  userAgent?: string | null;
}
