import { BadRequestException, Injectable } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource } from 'typeorm';

import { SystemSettingService } from '../setting/system-setting.service';
import {
  WORKER_BINDING_MAX_PER_BOSS_DEFAULT,
  WORKER_BINDING_MAX_PER_BOSS_KEY,
  parseWorkerBindingMax,
} from '../auth/worker-binding-limit';
import { IdentityBindingQueryDto } from './dto/identity-binding-query.dto';

/** 绑定行的两端身份摘要（全部来自既有列/既有表，无新增字段） */
export interface BindingParty {
  /** user.id（打手侧同时是 worker.user_id） */
  userId: string | null;
  /** 中文 ID */
  uid: string | null;
  username: string | null;
  nickname: string | null;
  /** user.status：1 正常 / 2 封禁（老板侧与打手侧都可能被封） */
  userStatus: number | null;
  /** 仅打手侧：工号 */
  workerNo?: string | null;
  /** 仅打手侧：worker.status：1 在职 / 2 停用 */
  workerStatus?: number | null;
}

export interface IdentityBindingRow {
  id: string;
  status: 'active' | 'unbound';
  slot: number;
  boundAt: string | null;
  unboundAt: string | null;
  /** 该老板**当前**仍生效的绑定数（上限占用 = bossActiveCount / maxPerBoss） */
  bossActiveCount: number;
  boss: BindingParty;
  worker: BindingParty;
}

/**
 * 老板 ↔ 打手 身份绑定 **只读** 查询（管理端运营排查；负责人 2026-10-06 身份合并方案甲）。
 *
 * 为什么单独一个只读接口而不是改 `/admin/users`、`/admin/workers`：
 * - 那两个是既有的账号列表契约，管理端另有页面在用；本轮的硬约束是**只加读接口**，
 *   不动既有接口的入参与返回（避免悄悄影响其它调用方与并行任务）。
 * - 绑定视角与账号视角是两张表：绑定记录（含历史 `unbound` 行）只有这里能看到；
 *   账号维度的行内提示由前端用 `bossUserIds` / `workerUserIds` **一次问一页**（见 DTO 注释）。
 *
 * 权威性：状态、槽位、绑定/解绑时间全部**直读** `worker_identity_binding`，不做任何缓存与推算；
 * 上限直读 `system_setting.worker_binding_max_per_boss`（与绑定写入路径同一个 key 与同一个解析器）。
 */
@Injectable()
export class IdentityBindingAdminService {
  constructor(
    @InjectDataSource() private readonly dataSource: DataSource,
    private readonly settings: SystemSettingService,
  ) {}

  /** 当前绑定上限（与 `WorkerIdentityService.maxPerBoss` 同口径：同一个 key + 同一个解析器 + 同一个默认值） */
  async maxPerBoss(): Promise<number> {
    const row = await this.settings.get(WORKER_BINDING_MAX_PER_BOSS_KEY);
    return parseWorkerBindingMax(row?.cfgValue?.['value']) ?? WORKER_BINDING_MAX_PER_BOSS_DEFAULT;
  }

  async list(q: IdentityBindingQueryDto): Promise<{
    list: IdentityBindingRow[];
    total: number;
    page: number;
    pageSize: number;
    maxPerBoss: number;
    summary: { total: number; active: number; unbound: number };
  }> {
    const page = q.page ?? 1;
    const pageSize = q.pageSize ?? 20;
    const where: string[] = ['1 = 1'];
    const params: unknown[] = [];

    const status = q.status ?? 'all';
    if (status !== 'all') {
      where.push('b.status = ?');
      params.push(status);
    }

    if (q.bossUserId) {
      where.push('b.boss_user_id = ?');
      params.push(q.bossUserId);
    }
    if (q.workerUserId) {
      where.push('b.worker_user_id = ?');
      params.push(q.workerUserId);
    }
    // 批量（当前页装饰）：任一列命中即可 —— 一页里可能既有老板行也有打手行
    const batchBoss = splitIds(q.bossUserIds);
    const batchWorker = splitIds(q.workerUserIds);
    if (batchBoss.length || batchWorker.length) {
      const ors: string[] = [];
      if (batchBoss.length) {
        ors.push(`b.boss_user_id IN (${batchBoss.map(() => '?').join(', ')})`);
        params.push(...batchBoss);
      }
      if (batchWorker.length) {
        ors.push(`b.worker_user_id IN (${batchWorker.map(() => '?').join(', ')})`);
        params.push(...batchWorker);
      }
      where.push(`(${ors.join(' OR ')})`);
    }

    if (q.keyword && q.keyword.trim()) {
      const kw = `%${q.keyword.trim()}%`;
      where.push(
        `(bu.uid LIKE ? OR bu.username LIKE ? OR bu.nickname LIKE ?
          OR wu.uid LIKE ? OR wu.username LIKE ? OR wu.nickname LIKE ? OR w.worker_no LIKE ?
          OR CAST(b.boss_user_id AS CHAR) = ? OR CAST(b.worker_user_id AS CHAR) = ?)`,
      );
      params.push(kw, kw, kw, kw, kw, kw, kw, q.keyword.trim(), q.keyword.trim());
    }

    const from = q.boundFrom ? parseTime(q.boundFrom, '绑定时间起') : null;
    if (from) {
      where.push('b.bound_at >= ?');
      params.push(from);
    }
    const to = q.boundTo ? parseTime(q.boundTo, '绑定时间止') : null;
    if (to) {
      where.push('b.bound_at <= ?');
      params.push(to);
    }

    const whereSql = where.join(' AND ');
    const fromSql = `
      FROM worker_identity_binding b
      LEFT JOIN \`user\` bu ON bu.id = b.boss_user_id
      LEFT JOIN \`user\` wu ON wu.id = b.worker_user_id
      LEFT JOIN worker w ON w.user_id = b.worker_user_id
      WHERE ${whereSql}`;

    const rows = await this.dataSource.query(
      `SELECT b.id AS id, b.status AS status, b.slot AS slot,
              b.bound_at AS boundAt, b.unbound_at AS unboundAt,
              b.boss_user_id AS bossUserId, b.worker_user_id AS workerUserId,
              bu.uid AS bossUid, bu.username AS bossUsername, bu.nickname AS bossNickname,
              bu.status AS bossUserStatus,
              wu.uid AS workerUid, wu.username AS workerUsername, wu.nickname AS workerNickname,
              wu.status AS workerUserStatus,
              w.worker_no AS workerNo, w.status AS workerStatus,
              (SELECT COUNT(1) FROM worker_identity_binding b2
                WHERE b2.boss_user_id = b.boss_user_id AND b2.status = 'active') AS bossActiveCount
         ${fromSql}
        ORDER BY b.bound_at DESC, b.id DESC
        LIMIT ? OFFSET ?`,
      [...params, pageSize, (page - 1) * pageSize],
    );

    const counted = await this.dataSource.query(`SELECT COUNT(1) AS cnt ${fromSql}`, params);
    const total = Number(counted?.[0]?.cnt ?? 0);

    // 汇总与筛选条件同口径（改了筛选，顶部数字跟着变），便于运营核对"筛出来的是不是我要的那批"
    const aggRows = await this.dataSource.query(
      `SELECT b.status AS status, COUNT(1) AS cnt ${fromSql} GROUP BY b.status`,
      params,
    );
    const summary = { total, active: 0, unbound: 0 };
    for (const r of aggRows ?? []) {
      if (r.status === 'active') summary.active = Number(r.cnt ?? 0);
      if (r.status === 'unbound') summary.unbound = Number(r.cnt ?? 0);
    }

    return {
      list: (rows ?? []).map((r: Record<string, unknown>) => mapRow(r)),
      total,
      page,
      pageSize,
      maxPerBoss: await this.maxPerBoss(),
      summary,
    };
  }
}

/** 逗号分隔 id → 去重后的数字字符串数组（DTO 正则已保证形状，这里再兜一层去重） */
function splitIds(raw?: string): string[] {
  if (!raw) return [];
  return [...new Set(raw.split(',').map((s) => s.trim()).filter((s) => /^\d{1,20}$/.test(s)))];
}

/**
 * 时间入参解析：接受 ISO 8601 与 `YYYY-MM-DD HH:mm:ss`（管理端日期选择器两种都可能给）。
 * 非法值抛 400 中文 —— 静默忽略会让运营以为"筛了"而实际没筛。
 */
function parseTime(raw: string, label: string): Date {
  const s = raw.trim();
  const normalized = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$/.test(s) ? s.replace(' ', 'T') : s;
  const d = new Date(normalized);
  if (Number.isNaN(d.getTime())) {
    throw new BadRequestException(`${label}格式非法（应为 ISO 8601 或 YYYY-MM-DD HH:mm:ss）：${s.slice(0, 32)}`);
  }
  return d;
}

/** 原始行 → 视图（bigint 一律转字符串；时间统一 ISO，前端自行本地化展示） */
function mapRow(r: Record<string, unknown>): IdentityBindingRow {
  const num = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
  const iso = (v: unknown): string | null => {
    if (!v) return null;
    const d = v instanceof Date ? v : new Date(String(v));
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  };
  return {
    id: String(r.id ?? ''),
    status: r.status === 'unbound' ? 'unbound' : 'active',
    slot: Number(r.slot ?? 0),
    boundAt: iso(r.boundAt),
    unboundAt: iso(r.unboundAt),
    bossActiveCount: Number(r.bossActiveCount ?? 0),
    boss: {
      userId: r.bossUserId === null || r.bossUserId === undefined ? null : String(r.bossUserId),
      uid: (r.bossUid as string) ?? null,
      username: (r.bossUsername as string) ?? null,
      nickname: (r.bossNickname as string) ?? null,
      userStatus: num(r.bossUserStatus),
    },
    worker: {
      userId: r.workerUserId === null || r.workerUserId === undefined ? null : String(r.workerUserId),
      uid: (r.workerUid as string) ?? null,
      username: (r.workerUsername as string) ?? null,
      nickname: (r.workerNickname as string) ?? null,
      userStatus: num(r.workerUserStatus),
      workerNo: (r.workerNo as string) ?? null,
      workerStatus: num(r.workerStatus),
    },
  };
}
