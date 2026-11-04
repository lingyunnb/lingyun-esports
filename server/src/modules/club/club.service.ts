import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { Club } from './club.entity';

/** 公开接口路径（写路径失效钩子必须与 `PublicCacheInterceptor` 登记的前缀逐字一致） */
const CLUB_PUBLIC_PATH = '/api/v1/public/clubs';

export interface ClubView {
  id: string;
  name: string;
  subTitle: string;
  description: string;
  coverMediaId: string | null;
  badge: string;
  rating: string;
  orderCount: number;
  divisionId: string | null;
  sortOrder: number;
  status?: number;
}

/** 官方自营馆（首页「祁连山官方」卡片）：纯管理端维护，客户端零硬编码 */
@Injectable()
export class ClubService {
  constructor(@InjectRepository(Club) private readonly repo: Repository<Club>) {}

  /**
   * 官方馆写入后立刻失效公开接口的进程内微缓存（**2026-10-08 缺口修复**）
   *
   * `/public/clubs` 挂在 `PublicCacheInterceptor` 的 30s 进程内微缓存下（缓存键 = `req.url`，
   * 见 `public-cache.interceptor.ts` 的 PREFIXES），而 `club` 模块此前**没有写入侧失效钩子**
   * —— 实测：管理端下架/改简介后，**同一个 URL** 最长 30s 仍返回旧数据
   * （换一个没缓存过的查询串立刻变，命中微缓存就还是旧值）。
   *
   * 口径与 `division` / `product` / `banner` / `recharge` 四处既有实现**完全一致**：
   * **内容随管理端配置变化的数据，写入时必须配失效钩子**
   * （`PublicCacheInterceptor.invalidate()` 是唯一失效入口，这里不另造机制）。
   *
   * ⚠️ **本模块新增任何写路径（新增/编辑/删除/上下架/排序）都必须调用本函数**，
   * 否则"管理端改完、App 还看到旧数据"会原地复发。
   */
  private invalidatePublicClubCache(): void {
    PublicCacheInterceptor.invalidate(CLUB_PUBLIC_PATH);
  }

  private toView(c: Club): ClubView {
    return {
      id: String(c.id),
      name: c.name,
      subTitle: c.subTitle ?? '',
      description: c.description ?? '',
      coverMediaId: c.coverMediaId == null ? null : String(c.coverMediaId),
      badge: c.badge || '官方',
      rating: String(c.rating ?? '5.0'),
      orderCount: Number(c.orderCount ?? 0),
      divisionId: c.divisionId == null ? null : String(c.divisionId),
      sortOrder: Number(c.sortOrder ?? 0),
    };
  }

  /** 上架列表（客户端首页用） */
  async listActive(): Promise<ClubView[]> {
    const rows = await this.repo.find({ where: { status: 1 }, order: { sortOrder: 'ASC', id: 'ASC' } });
    return rows.map((c) => this.toView(c));
  }

  /** 全部（管理端） */
  async listAll(): Promise<ClubView[]> {
    const rows = await this.repo.find({ order: { sortOrder: 'ASC', id: 'ASC' } });
    return rows.map((c) => ({ ...this.toView(c), status: Number(c.status) }));
  }

  async create(dto: Partial<ClubView>): Promise<{ id: string }> {
    const saved = await this.repo.save(
      this.repo.create({
        name: dto.name ?? '祁连山电竞 · 官方馆',
        subTitle: dto.subTitle ?? '',
        description: dto.description ?? '',
        coverMediaId: dto.coverMediaId ? String(dto.coverMediaId) : null,
        badge: dto.badge ?? '官方',
        rating: dto.rating ?? '5.0',
        orderCount: dto.orderCount ?? 0,
        divisionId: dto.divisionId ? String(dto.divisionId) : null,
        sortOrder: dto.sortOrder ?? 0,
        status: dto.status ?? 1,
      }),
    );
    // 新增后立刻可见（不等 30s TTL）
    this.invalidatePublicClubCache();
    return { id: String(saved.id) };
  }

  async update(id: string, dto: Partial<ClubView>): Promise<{ ok: boolean; message?: string }> {
    const found = await this.repo.findOne({ where: { id } });
    if (!found) return { ok: false, message: '官方馆不存在' };
    Object.assign(found, {
      name: dto.name ?? found.name,
      subTitle: dto.subTitle ?? found.subTitle,
      description: dto.description ?? found.description,
      coverMediaId: dto.coverMediaId !== undefined ? (dto.coverMediaId ? String(dto.coverMediaId) : null) : found.coverMediaId,
      badge: dto.badge ?? found.badge,
      rating: dto.rating ?? found.rating,
      orderCount: dto.orderCount ?? found.orderCount,
      divisionId: dto.divisionId !== undefined ? (dto.divisionId ? String(dto.divisionId) : null) : found.divisionId,
      sortOrder: dto.sortOrder ?? found.sortOrder,
      status: dto.status ?? found.status,
    });
    await this.repo.save(found);
    // 编辑（含 status 上下架 / 排序 / 简介 / 封面）后立刻可见
    this.invalidatePublicClubCache();
    return { ok: true };
  }

  async remove(id: string): Promise<{ ok: boolean }> {
    await this.repo.delete({ id });
    // 删除后立刻消失
    this.invalidatePublicClubCache();
    return { ok: true };
  }
}
