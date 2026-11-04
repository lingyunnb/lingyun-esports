import { BadRequestException, ConflictException, Injectable, NotFoundException } from '@nestjs/common';
import { InjectDataSource, InjectRepository } from '@nestjs/typeorm';
import { DataSource, Repository } from 'typeorm';
import { PublicCacheInterceptor } from '../../common/interceptors/public-cache.interceptor';
import { Product } from '../product/product.entity';
import { Category } from './category.entity';
import { GameConfig } from './game-config.entity';
import { Game } from './game.entity';

/** 公开接口路径（写路径失效钩子必须与 `PublicCacheInterceptor` 登记的前缀逐字一致） */
const GAMES_PUBLIC_PATH = '/api/v1/public/games';
const CATEGORIES_PUBLIC_PATH = '/api/v1/public/categories';

/** 游戏/分类/配置服务（docs/13：全部后台动态配置，客户端零硬编码） */
@Injectable()
export class GameService {
  constructor(
    @InjectRepository(Game) private readonly gameRepo: Repository<Game>,
    @InjectRepository(GameConfig) private readonly configRepo: Repository<GameConfig>,
    @InjectRepository(Category) private readonly categoryRepo: Repository<Category>,
    @InjectDataSource() private readonly dataSource: DataSource,
  ) {}

  /**
   * 游戏/分类写入后立刻失效公开接口的进程内微缓存（**2026-10-08 缺口修复**）
   *
   * `/public/games`（含 `/public/games/:code/config`）与 `/public/categories` 都挂在
   * `PublicCacheInterceptor` 的 30s 微缓存下，而本模块此前**没有写入侧失效钩子** ——
   * 管理端新增游戏/改分类/切上下架后，客户端最长 30s 还是旧目录（"改了像没生效"）。
   *
   * 口径与 `division` / `product` / `banner` / `recharge` 四处既有实现完全一致：
   * **内容随管理端配置变化的数据，写入时必须配失效钩子**（唯一入口 `PublicCacheInterceptor.invalidate`）。
   *
   * 本模块写路径有 7 个（游戏增/改/删/配置替换 + 分类增/改/删），故收敛到这一个函数：
   * ⚠️ **新增任何游戏/分类写路径都必须调用它**，不要各写一遍路径常量。
   */
  private invalidatePublicCatalogCache(): void {
    PublicCacheInterceptor.invalidate(GAMES_PUBLIC_PATH);
    PublicCacheInterceptor.invalidate(CATEGORIES_PUBLIC_PATH);
  }

  // ---------- 管理端 ----------

  async listGames() {
    return this.gameRepo.find({ order: { sortOrder: 'ASC', id: 'ASC' } });
  }

  async createGame(dto: { code: string; name: string; sortOrder?: number; status?: number }) {
    const exists = await this.gameRepo.findOne({ where: { code: dto.code } });
    if (exists) {
      throw new ConflictException('游戏标识已存在');
    }
    const saved = await this.gameRepo.save(this.gameRepo.create({ ...dto }));
    this.invalidatePublicCatalogCache();
    return saved;
  }

  async updateGame(id: string, dto: { name?: string; status?: number; sortOrder?: number }) {
    const game = await this.gameRepo.findOne({ where: { id } });
    if (!game) {
      throw new NotFoundException('游戏不存在');
    }
    Object.assign(game, dto);
    const saved = await this.gameRepo.save(game);
    this.invalidatePublicCatalogCache();
    return saved;
  }

  /** 删除游戏（负责人需求：引用保护——有分类/商品时拒绝，提示先删下级；事务内清理游戏配置） */
  async deleteGame(id: string) {
    const game = await this.gameRepo.findOne({ where: { id } });
    if (!game) throw new NotFoundException('游戏不存在');
    const catCount = await this.categoryRepo.count({ where: { gameId: id } });
    if (catCount > 0) throw new BadRequestException(`该游戏下还有 ${catCount} 个分类，请先删除分类`);
    const prodCount = await this.dataSource.getRepository(Product).count({ where: { gameId: id } });
    if (prodCount > 0) throw new BadRequestException(`该游戏下还有 ${prodCount} 个商品，请先删除商品`);
    await this.dataSource.transaction(async (em) => {
      await em.delete(GameConfig, { gameId: id });
      await em.delete(Game, { id });
    });
    this.invalidatePublicCatalogCache();
    return { ok: true };
  }

  /** 删除分类（引用保护：有商品时拒绝） */
  async deleteCategory(id: string) {
    const category = await this.categoryRepo.findOne({ where: { id } });
    if (!category) throw new NotFoundException('分类不存在');
    const prodCount = await this.dataSource.getRepository(Product).count({ where: { categoryId: id } });
    if (prodCount > 0) throw new BadRequestException(`该分类下还有 ${prodCount} 个商品，请先删除或转移商品`);
    await this.categoryRepo.delete(id);
    this.invalidatePublicCatalogCache();
    return { ok: true };
  }

  /** 游戏配置整体替换（事务，docs/13） */
  async setGameConfig(id: string, configs: { key: string; value: unknown; remark?: string }[]) {
    const game = await this.gameRepo.findOne({ where: { id } });
    if (!game) {
      throw new NotFoundException('游戏不存在');
    }
    await this.dataSource.transaction(async (em) => {
      await em.delete(GameConfig, { gameId: id });
      if (configs.length > 0) {
        await em.save(
          configs.map((c) =>
            em.create(GameConfig, { gameId: id, cfgKey: c.key, cfgValue: c.value, remark: c.remark ?? null }),
          ),
        );
      }
    });
    // 段位/区服/模式等配置就是 `GET /public/games/:code/config` 的全部内容
    this.invalidatePublicCatalogCache();
    return { ok: true };
  }

  async listCategories(gameId?: string) {
    const where = gameId ? { gameId } : {};
    return this.categoryRepo.find({ where, order: { sortOrder: 'ASC', id: 'ASC' } });
  }

  async createCategory(dto: { gameId: string; name: string; sortOrder?: number }) {
    const game = await this.gameRepo.findOne({ where: { id: dto.gameId } });
    if (!game) {
      throw new NotFoundException('游戏不存在');
    }
    const saved = await this.categoryRepo.save(this.categoryRepo.create({ ...dto, status: 1 }));
    this.invalidatePublicCatalogCache();
    return saved;
  }

  async updateCategory(id: string, dto: { name?: string; status?: number; sortOrder?: number }) {
    const category = await this.categoryRepo.findOne({ where: { id } });
    if (!category) {
      throw new NotFoundException('分类不存在');
    }
    Object.assign(category, dto);
    const saved = await this.categoryRepo.save(category);
    this.invalidatePublicCatalogCache();
    return saved;
  }

  // ---------- 公开接口（仅上架数据） ----------

  async publicGames() {
    return this.gameRepo.find({ where: { status: 1 }, order: { sortOrder: 'ASC', id: 'ASC' } });
  }

  async publicGameConfig(code: string) {
    const game = await this.gameRepo.findOne({ where: { code, status: 1 } });
    if (!game) {
      throw new NotFoundException('游戏不存在或已下架');
    }
    const configs = await this.configRepo.find({ where: { gameId: game.id } });
    const configMap: Record<string, unknown> = {};
    for (const c of configs) {
      configMap[c.cfgKey] = c.cfgValue;
    }
    return { game: { id: game.id, code: game.code, name: game.name }, configs: configMap };
  }

  async publicCategories(gameId?: string) {
    const where: Record<string, unknown> = { status: 1 };
    if (gameId) {
      where.gameId = gameId;
    }
    return this.categoryRepo.find({ where, order: { sortOrder: 'ASC', id: 'ASC' } });
  }
}
