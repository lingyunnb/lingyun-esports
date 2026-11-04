import { Controller, Get, Param, Query } from '@nestjs/common';
import { ApiOperation, ApiTags } from '@nestjs/swagger';
import { GameService } from '../game/game.service';
import { ProductService } from './product.service';
import { parsePage, parsePageSize } from '../../common/pagination';

/** 公开浏览接口（docs/03、docs/13）：无需登录，仅返回上架数据 */
@ApiTags('public')
@Controller('public')
export class PublicCatalogController {
  constructor(
    private readonly gameService: GameService,
    private readonly productService: ProductService,
  ) {}

  @Get('games')
  @ApiOperation({ summary: '公开：上架游戏列表' })
  games() {
    return this.gameService.publicGames();
  }

  @Get('games/:code/config')
  @ApiOperation({ summary: '公开：游戏配置（段位/区服/模式等，客户端按 key 渲染）' })
  gameConfig(@Param('code') code: string) {
    return this.gameService.publicGameConfig(code);
  }

  @Get('categories')
  @ApiOperation({ summary: '公开：分类列表（可按 gameId 过滤）' })
  categories(@Query('gameId') gameId?: string) {
    return this.gameService.publicCategories(gameId);
  }

  @Get('products')
  @ApiOperation({ summary: '公开：商品列表（仅上架，分页；支持分部筛选）' })
  products(
    @Query('gameId') gameId?: string,
    @Query('categoryId') categoryId?: string,
    @Query('divisionId') divisionId?: string,
    @Query('page') page?: string,
    @Query('pageSize') pageSize?: string,
  ) {
    return this.productService.publicList({
      gameId,
      categoryId,
      divisionId,
      page: parsePage(page),
      pageSize: parsePageSize(pageSize),
    });
  }

  @Get('products/:id')
  @ApiOperation({ summary: '公开：商品详情（含媒体列表、服务规则等）' })
  productDetail(@Param('id') id: string) {
    return this.productService.publicDetail(id);
  }
}
