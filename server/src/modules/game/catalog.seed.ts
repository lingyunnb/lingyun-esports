import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Product } from '../product/product.entity';
import { Category } from './category.entity';
import { GameConfig } from './game-config.entity';
import { Game } from './game.entity';

/**
 * 游戏目录种子（幂等，docs/13）。
 *
 * **2026-10-04 负责人定案：不再种 CODM。**
 * 平台只做「和平精英」与「三角洲行动」，且三角洲**不再往下一层分平台**——
 * 游戏列表扁平三条：和平精英 / 三角洲行动（手游）/ 三角洲行动（端游）。
 *
 * 历史遗留问题：此前这里无条件按 `code='codm'` 补种游戏 + 分类 + 示例商品，
 * 导致管理端删掉 CODM 后**下次重启又会冒出来**（负责人报障「为啥还有使命召唤」）。
 * 现在这里只做引用完整性巡检，**不再创建任何游戏行**；游戏/分类/商品一律由管理端维护。
 */
@Injectable()
export class CatalogSeedService implements OnApplicationBootstrap {
  private readonly logger = new Logger('CatalogSeed');

  constructor(
    @InjectRepository(Game) private readonly gameRepo: Repository<Game>,
    @InjectRepository(GameConfig) private readonly configRepo: Repository<GameConfig>,
    @InjectRepository(Category) private readonly categoryRepo: Repository<Category>,
    @InjectRepository(Product) private readonly productRepo: Repository<Product>,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    // 只读巡检：确认没有残留的 CODM 目录数据（不再创建，只报告）
    const codm = await this.gameRepo.findOne({ where: { code: 'codm' } });
    if (codm) {
      const cats = await this.categoryRepo.count({ where: { gameId: codm.id } });
      const prods = await this.productRepo.count({ where: { gameId: codm.id } });
      this.logger.warn(
        `检测到残留 CODM 游戏（id=${codm.id}，分类 ${cats} 个 / 商品 ${prods} 个）——` +
          `平台已定案只做「和平精英 / 三角洲行动」，请在管理端删除该游戏。`,
      );
    }
  }
}

