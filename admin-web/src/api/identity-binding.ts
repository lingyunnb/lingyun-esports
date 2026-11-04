/**
 * 身份绑定（老板 ↔ 打手，负责人 2026-10-06 方案甲）——管理端**只读**读取封装。
 *
 * 唯一数据源：`GET /admin/identity-bindings`（权限点 `admin:user:read`）。
 * 为什么封装成模块而不是在各页各写一遍：三个地方要用同一条读接口、同一套字段解释
 * （「身份绑定」页 /「用户管理」行内提示 /「工作端管理」行内提示），
 * 字段解释一旦分叉就会出现"同一关系两个页面显示不一致"的老问题。
 *
 * 只读：这里没有任何写方法 —— 绑定/解绑只有老板端能做（主体 id 只从 JWT sub 取）。
 */
import { request } from './client';

/** 绑定的一端（老板或打手；字段与服务端 IdentityBindingRow 一一对应，不造字段） */
export interface BindingParty {
  userId: string | null;
  uid: string | null;
  username: string | null;
  nickname: string | null;
  userStatus: number | null;
  /** 仅打手侧 */
  workerNo?: string | null;
  /** 仅打手侧：worker.status（1 在职 / 2 停用） */
  workerStatus?: number | null;
}

export interface BindingRow {
  id: string;
  status: 'active' | 'unbound';
  slot: number;
  boundAt: string | null;
  unboundAt: string | null;
  /** 该老板当前生效的绑定数（上限占用 = bossActiveCount / maxPerBoss） */
  bossActiveCount: number;
  boss: BindingParty;
  worker: BindingParty;
}

export interface BindingListResult {
  list: BindingRow[];
  total: number;
  page: number;
  pageSize: number;
  maxPerBoss: number;
  summary: { total: number; active: number; unbound: number };
}

export function fetchIdentityBindings(query: Record<string, string>): Promise<BindingListResult> {
  const q = new URLSearchParams(query);
  return request<BindingListResult>('GET', `/admin/identity-bindings?${q.toString()}`);
}

/** 分页读取的上限（防止"拉全量"在数据量变大时变成打后端：超过就只拿前 N 条并如实告知） */
export const BINDING_SCAN_LIMIT = 2000;

/**
 * 全部**生效**绑定（排查模式用）：分页拉全，最多 `BINDING_SCAN_LIMIT` 条。
 * 返回 `{ rows, truncated }`：`truncated=true` 表示被上限截断（调用方需如实提示，不能假装筛全了）。
 */
export async function fetchAllActiveBindings(): Promise<{ rows: BindingRow[]; truncated: boolean }> {
  const pageSize = 200;
  const rows: BindingRow[] = [];
  let page = 1;
  let total = Infinity;
  while (rows.length < Math.min(total, BINDING_SCAN_LIMIT)) {
    const data = await fetchIdentityBindings({ status: 'active', page: String(page), pageSize: String(pageSize) });
    total = data.total ?? 0;
    rows.push(...(data.list ?? []));
    if (!data.list?.length) break;
    page += 1;
  }
  return { rows: rows.slice(0, BINDING_SCAN_LIMIT), truncated: total > BINDING_SCAN_LIMIT };
}

/** 生效绑定的两端 user id 集合（"已绑定"判定；未在集合里 = 未绑定） */
export function boundUserIdSet(rows: BindingRow[]): Set<string> {
  const set = new Set<string>();
  for (const r of rows) {
    if (r.status !== 'active') continue;
    if (r.boss.userId) set.add(r.boss.userId);
    if (r.worker.userId) set.add(r.worker.userId);
  }
  return set;
}

/** 行内提示（列表页「身份绑定」列） */
export interface BindingNote {
  bindingId: string;
  boundAt: string | null;
  /** 对方名字（老板行 → 打手昵称；打手行 → 老板昵称） */
  peerName: string;
  /** 对方标识（老板行 → 工号；打手行 → 中文 ID），与需求文案一致 */
  peerSub: string;
}

/**
 * 当前页装饰：按老板/打手 user id **一次问一页**（避免 20 行发 20 个请求）。
 * 单次批量上限 50（服务端 DTO 约束），超过自动分组串行补齐。
 */
export async function fetchActiveBindingNotes(ids: string[]): Promise<Map<string, BindingNote>> {
  const wanted = [...new Set(ids.filter((v) => /^\d+$/.test(v)))];
  const notes = new Map<string, BindingNote>();
  if (!wanted.length) return notes;
  const chunks: string[][] = [];
  for (let i = 0; i < wanted.length; i += 50) chunks.push(wanted.slice(i, i + 50));
  for (const chunk of chunks) {
    const data = await fetchIdentityBindings({
      status: 'active',
      page: '1',
      pageSize: '200',
      bossUserIds: chunk.join(','),
      workerUserIds: chunk.join(','),
    });
    for (const row of data.list ?? []) {
      const bossId = row.boss.userId;
      const workerId = row.worker.userId;
      if (bossId && chunk.includes(bossId) && !notes.has(bossId)) {
        notes.set(bossId, {
          bindingId: row.id,
          boundAt: row.boundAt,
          peerName: row.worker.nickname || row.worker.username || '（打手账号已删除）',
          peerSub: `工号 ${row.worker.workerNo || '—'}`,
        });
      }
      if (workerId && chunk.includes(workerId) && !notes.has(workerId)) {
        notes.set(workerId, {
          bindingId: row.id,
          boundAt: row.boundAt,
          peerName: row.boss.nickname || row.boss.username || '（老板账号已删除）',
          peerSub: `中文 ID ${row.boss.uid || '—'}`,
        });
      }
    }
  }
  return notes;
}

/**
 * 分页读取**全量账号**（排查模式用；账号列表接口 pageSize 上限 100，逐页取到 total 为止）。
 * 只有运营显式选择「已绑定/未绑定」筛选时才走这条路 —— 常规浏览始终是服务端分页。
 */
export async function fetchAllPages<T>(
  loadPage: (page: number, pageSize: number) => Promise<{ list: T[]; total: number }>,
  limit = 500,
): Promise<{ rows: T[]; total: number; truncated: boolean }> {
  const pageSize = 100;
  const rows: T[] = [];
  let page = 1;
  let total = 0;
  for (;;) {
    const data = await loadPage(page, pageSize);
    total = data.total ?? 0;
    rows.push(...(data.list ?? []));
    if (!data.list?.length || rows.length >= total || rows.length >= limit) break;
    page += 1;
  }
  return { rows: rows.slice(0, limit), total, truncated: total > limit };
}
