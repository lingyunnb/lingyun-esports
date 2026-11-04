import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { Division } from './division.entity';

/** 分部对外视图（客户端零硬编码：名称/平台/颜色/说明全部来自服务端） */
export interface DivisionView {
  id: string;
  code: string;
  gameId: string;
  gameName: string;
  platform: string;
  platformLabel: string;
  name: string;
  shortName: string;
  onlineDesc: string;
  priceNote: string;
  themeColor: string;
  /** 专区圆形图媒体 id（管理端可换；空则客户端回退渐变色块） */
  iconMediaId: string | null;
  /** 分部卡封面图媒体 id（管理端可换；空则客户端回退渐变色块） */
  coverMediaId: string | null;
  /** 副标题（管理端可改） */
  subTitle: string;
  sortOrder: number;
  /**
   * 是否建设中（负责人 2026-10-05）：true = 客户端分部卡显示「建设中」标识、点击进建设中页；
   * false（默认）= 正常进商品列表。**改库即生效，客户端无需改代码**。
   */
  underConstruction: boolean;
  /** 建设中页提示文案（服务端下发；无文案时为 ''，客户端不回退硬编码 QQ 号） */
  noticeText: string;
  /** 真实在线人数（该分部下在职且可接单的陪玩数；服务端统计，客户端不再写死） */
  onlineCount: number;
  status?: number;
}

/** 按游戏分组（客户端的平台筛选只有同游戏多平台时才显示） */
export interface DivisionGroupView {
  gameId: string;
  gameName: string;
  /** 该游戏的平台数：=1 时客户端不显示平台筛选（如和平精英仅手游） */
  platformCount: number;
  divisions: DivisionView[];
}

@Injectable()
export class DivisionService {
  constructor(
    @InjectRepository(Division)
    private readonly repo: Repository<Division>,
  ) {}

  /** 上架分部列表（客户端首页/筛选用；含**真实在线人数**：在职且可接单的陪玩数） */
  async listActive(): Promise<DivisionView[]> {
    const rows = await this.repo
      .createQueryBuilder('d')
      .leftJoin('game', 'g', 'g.id = d.game_id')
      .select([
        'd.id AS id',
        'd.code AS code',
        'd.game_id AS gameId',
        'g.name AS gameName',
        'g.sort_order AS gameSort',
        'd.platform AS platform',
        'd.platform_label AS platformLabel',
        'd.name AS name',
        'd.short_name AS shortName',
        'd.online_desc AS onlineDesc',
        'd.price_note AS priceNote',
        'd.theme_color AS themeColor',
        'd.icon_media_id AS iconMediaId',
        'd.cover_media_id AS coverMediaId',
        'd.sub_title AS subTitle',
        'd.sort_order AS sortOrder',
        // 建设中态 + 招人文案（负责人 2026-10-05）：客户端据此决定「进建设中页」还是「进商品页」
        'd.under_construction AS underConstruction',
        'd.notice_text AS noticeText',
        // 真实在线：**该分部有接单权限**且在职的陪玩数（不写死、不造假）。
        // 2026-10-04 接单权限下沉到分部后，口径改为 worker_division_permission
        // （原先按 worker.division_id 统计 —— 只接手游的人也会被算进端游分部的"在线"）。
        `(SELECT COUNT(1) FROM worker w WHERE w.status = 1 AND w.can_take_order = 1
            AND EXISTS (SELECT 1 FROM worker_division_permission p
                        WHERE p.worker_id = w.id AND p.division_id = d.id AND p.can_take_order = 1)) AS onlineCount`,
      ])
      .where('d.status = 1')
      .andWhere('(g.status IS NULL OR g.status = 1)')
      .orderBy('g.sort_order', 'ASC')
      .addOrderBy('d.sort_order', 'ASC')
      .getRawMany<Record<string, unknown>>();
    return rows.map((r) => this.toView(r));
  }

  /** 按游戏分组（客户端首页「选择分部」直接渲染，含是否需要平台筛选） */
  async listGrouped(): Promise<DivisionGroupView[]> {
    const list = await this.listActive();
    const groups = new Map<string, DivisionGroupView>();
    for (const d of list) {
      let g = groups.get(d.gameId);
      if (!g) {
        g = { gameId: d.gameId, gameName: d.gameName, platformCount: 0, divisions: [] };
        groups.set(d.gameId, g);
      }
      g.divisions.push(d);
      g.platformCount = g.divisions.length;
    }
    return [...groups.values()];
  }

  /** 全部（含下架）—— 管理端用 */
  async listAll(): Promise<DivisionView[]> {
    const rows = await this.repo
      .createQueryBuilder('d')
      .leftJoin('game', 'g', 'g.id = d.game_id')
      .select([
        'd.id AS id',
        'd.code AS code',
        'd.game_id AS gameId',
        'g.name AS gameName',
        'd.platform AS platform',
        'd.platform_label AS platformLabel',
        'd.name AS name',
        'd.short_name AS shortName',
        'd.online_desc AS onlineDesc',
        'd.price_note AS priceNote',
        'd.theme_color AS themeColor',
        'd.icon_media_id AS iconMediaId',
        'd.cover_media_id AS coverMediaId',
        'd.sub_title AS subTitle',
        'd.sort_order AS sortOrder',
        'd.status AS status',
        // 管理端也要能看见/编辑这两项（列表里直接显示「建设中」并回填文案）
        'd.under_construction AS underConstruction',
        'd.notice_text AS noticeText',
      ])
      .orderBy('d.sort_order', 'ASC')
      .getRawMany<Record<string, unknown>>();
    return rows.map((r) => ({ ...this.toView(r), ...(r.status !== undefined ? { status: Number(r.status) } : {}) }));
  }

  async findById(id: string): Promise<Division | null> {
    return this.repo.findOne({ where: { id } });
  }

  /** 校验 id 是否有效上架分部（下单/接单/榜单写入前调用） */
  async assertActive(id: string): Promise<Division> {
    const d = await this.repo.findOne({ where: { id: String(id), status: 1 } });
    if (!d) throw new Error('DIVISION_NOT_FOUND');
    return d;
  }

  private toView(r: Record<string, unknown>): DivisionView {
    return {
      id: String(r.id),
      code: String(r.code ?? ''),
      gameId: String(r.gameId ?? ''),
      gameName: String(r.gameName ?? ''),
      platform: String(r.platform ?? 'mobile'),
      platformLabel: String(r.platformLabel ?? ''),
      name: String(r.name ?? ''),
      shortName: String(r.shortName ?? ''),
      onlineDesc: String(r.onlineDesc ?? ''),
      priceNote: String(r.priceNote ?? ''),
      themeColor: String(r.themeColor ?? ''),
      iconMediaId: r.iconMediaId == null ? null : String(r.iconMediaId),
      coverMediaId: r.coverMediaId == null ? null : String(r.coverMediaId),
      subTitle: String(r.subTitle ?? ''),
      sortOrder: Number(r.sortOrder ?? 0),
      // tinyint(0/1) → 布尔（客户端 Dart 侧同时兼容 bool 与 0/1，见 services_page._Division.fromJson）
      underConstruction: Number(r.underConstruction ?? 0) === 1,
      noticeText: String(r.noticeText ?? ''),
      onlineCount: Number(r.onlineCount ?? 0),
    };
  }

  /**
   * 分部是否建设中（下单链路防误单用；找不到该分部时按 false 处理，由既有校验负责报错）
   *
   * 用独立的轻量查询（只取三列）而不是复用 [assertActive]：调用点在订单事务里，
   * 只关心「这个分部的商品能不能下单」，不关心其余字段。
   */
  async isUnderConstruction(id?: string | null): Promise<boolean> {
    const target = String(id ?? '');
    if (!target) return false;
    const found = await this.repo.findOne({ where: { id: target }, select: ['id', 'underConstruction'] });
    return Number(found?.underConstruction ?? 0) === 1;
  }
}
