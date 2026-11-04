import { Body, Controller, Delete, Get, Param, Post, Put, Query, Req, UseGuards } from '@nestjs/common';
import { ApiBearerAuth, ApiOperation, ApiTags } from '@nestjs/swagger';
import type { Request } from 'express';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { Roles } from '../../common/decorators/roles.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { PermissionsGuard } from '../../common/guards/permissions.guard';
import { RolesGuard } from '../../common/guards/roles.guard';
import { OperationLogService } from '../log/operation-log.service';
import { CreateCategoryDto, CreateGameDto, SetGameConfigDto, UpdateCategoryDto, UpdateGameDto } from './dto/catalog.dto';
import { GameService } from './game.service';

/** 游戏/分类管理（RBAC，docs/13） */
@ApiTags('admin/games')
@Controller('admin')
@UseGuards(JwtAuthGuard, RolesGuard, PermissionsGuard)
@Roles('admin')
@ApiBearerAuth()
export class GameAdminController {
  constructor(
    private readonly service: GameService,
    private readonly opLog: OperationLogService,
  ) {}

  /**
   * 审计留痕（负责人铁律：管理端任何会改变库内容的接口，成功后必须写 `operation_log`）。
   *
   * 为什么收口成一个私有方法：本控制器有 7 个写接口，逐个手写 `opLog.log({...})`
   * 必然出现"某个接口漏了 module/action 或写错字段"的漂移。收口后每个接口只传差异部分。
   * 口径与 `division.controller.ts` / `wallet-admin.controller.ts` 完全一致
   * （`adminUserId` 从 JWT 的 `CurrentUser` 取，**绝不从请求体取**）。
   */
  private audit(
    user: { userId: string },
    req: Request,
    action: string,
    requestBody: Record<string, unknown>,
    result: 'success' | 'fail' = 'success',
    errorMsg: string | null = null,
  ): void {
    this.opLog.log({
      adminUserId: user.userId,
      adminName: '',
      module: 'game',
      action,
      method: req.method,
      path: req.path,
      requestBody: JSON.stringify(requestBody),
      ip: req.ip ?? null,
      requestId: (req as Request & { requestId?: string }).requestId ?? null,
      result,
      errorMsg,
    });
  }

  @Get('games')
  @RequirePermission('admin:game:write')
  @ApiOperation({ summary: '权限点 admin:game:write：游戏列表' })
  listGames() {
    return this.service.listGames();
  }

  @Post('games')
  @RequirePermission('admin:game:write')
  @ApiOperation({ summary: '权限点 admin:game:write：新增游戏（操作日志留痕）' })
  async createGame(@Body() dto: CreateGameDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const saved = await this.service.createGame(dto);
    this.audit(user, req, 'game:create', { id: String((saved as { id?: unknown })?.id ?? ''), code: dto.code, name: dto.name });
    return saved;
  }

  @Put('games/:id')
  @RequirePermission('admin:game:write')
  @ApiOperation({ summary: '权限点 admin:game:write：编辑游戏（未知字段忽略不报错；操作日志留痕）' })
  async updateGame(
    @Param('id') id: string,
    @Body() dto: UpdateGameDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateGame(id, dto);
    this.audit(user, req, 'game:update', { id: String(id), ...(dto as Record<string, unknown>) });
    return result;
  }

  @Delete('games/:id')
  @RequirePermission('admin:game:write')
  @ApiOperation({ summary: '权限点 admin:game:write：删除游戏（有分类/商品时拒绝；操作日志留痕）' })
  async deleteGame(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteGame(id);
    this.audit(user, req, 'game:delete', { id: String(id) });
    return result;
  }

  @Post('games/:id/config')
  @RequirePermission('admin:game:write')
  @ApiOperation({ summary: '权限点 admin:game:write：游戏配置整体替换（段位/区服/模式等；操作日志留痕）' })
  async setConfig(
    @Param('id') id: string,
    @Body() dto: SetGameConfigDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.setGameConfig(id, dto.configs);
    this.audit(user, req, 'game:config', { id: String(id), configCount: Array.isArray(dto.configs) ? dto.configs.length : null });
    return result;
  }

  @Get('categories')
  @RequirePermission('admin:category:write')
  @ApiOperation({ summary: '权限点 admin:category:write：分类列表（可按 gameId 过滤）' })
  listCategories(@Query('gameId') gameId?: string) {
    return this.service.listCategories(gameId);
  }

  @Post('categories')
  @RequirePermission('admin:category:write')
  @ApiOperation({ summary: '权限点 admin:category:write：新增分类（操作日志留痕）' })
  async createCategory(@Body() dto: CreateCategoryDto, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const saved = await this.service.createCategory(dto);
    this.audit(user, req, 'category:create', {
      id: String((saved as { id?: unknown })?.id ?? ''),
      name: dto.name,
      gameId: dto.gameId,
    });
    return saved;
  }

  @Put('categories/:id')
  @RequirePermission('admin:category:write')
  @ApiOperation({ summary: '权限点 admin:category:write：编辑分类（未知字段忽略不报错；操作日志留痕）' })
  async updateCategory(
    @Param('id') id: string,
    @Body() dto: UpdateCategoryDto,
    @CurrentUser() user: { userId: string },
    @Req() req: Request,
  ) {
    const result = await this.service.updateCategory(id, dto);
    this.audit(user, req, 'category:update', { id: String(id), ...(dto as Record<string, unknown>) });
    return result;
  }

  @Delete('categories/:id')
  @RequirePermission('admin:category:write')
  @ApiOperation({ summary: '权限点 admin:category:write：删除分类（有商品时拒绝；操作日志留痕）' })
  async deleteCategory(@Param('id') id: string, @CurrentUser() user: { userId: string }, @Req() req: Request) {
    const result = await this.service.deleteCategory(id);
    this.audit(user, req, 'category:delete', { id: String(id) });
    return result;
  }
}
